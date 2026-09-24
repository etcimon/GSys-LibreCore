// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Bounded TGSI text compiler. Host-testable and freestanding (no libc).
// Not linked into apu_fw.elf (TID+IADD) or apu_tgsi_fw.elf (pre-encoded
// MOV job). Linked into apu_tgsi_cc.elf for the CVA6 compositor TB.

#include "g6lc_apu_tgsi.h"
#include "g6lc_apu_exec.h"

#define APU_TGSI_MAX_IMM 4
#define TGSI_LEAF static inline __attribute__((always_inline))

typedef struct {
  unsigned reg;
  int neg;
  int is_imm;
  uint32_t bits;
} tgsi_src_t;

static inline __attribute__((always_inline)) void
set_err(char *err, unsigned err_len, const char *msg)
{
  unsigned i;
  if (err == NULL || err_len == 0)
    return;
  for (i = 0; i + 1u < err_len && msg[i] != '\0'; i++)
    err[i] = msg[i];
  err[i] = '\0';
}

static inline __attribute__((always_inline)) int is_ident(char c)
{
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

/* 0x9000xxxx is a negative i32. gcc emits addw/addiw for p+n and
 * sign-extends to 0xffffffff9000xxxx. Force 64-bit add. */
static inline __attribute__((always_inline)) const char *
pinc(const char *s, unsigned n)
{
  uintptr_t p = (uintptr_t)s;
  uintptr_t o = (uintptr_t)n;
#ifdef __riscv
  p = (uintptr_t)(uint32_t)p;
  __asm__ volatile ("add %0, %0, %1" : "+r"(p) : "r"(o));
#else
  p += o;
#endif
  return (const char *)p;
}

static inline __attribute__((always_inline)) const char *
tptr(const char *s, unsigned i)
{
  return pinc(s, i);
}

static inline __attribute__((always_inline)) char tch(const char *s, unsigned i)
{
  return *tptr(s, i);
}

static inline __attribute__((always_inline)) const char *skip_ws(const char *s)
{
  unsigned n = 0;
  while (n < APU_TGSI_TEXT_CAP) {
    char c = tch(s, 0);
    if (c != ' ' && c != '\t' && c != '\r')
      break;
    s = pinc(s, 1);
    n++;
  }
  return s;
}

TGSI_LEAF int parse_u(const char **ps, unsigned *v)
{
  const char *s = *ps;
  unsigned n = 0;
  unsigned k = 0;
  if (tch(s, 0) < '0' || tch(s, 0) > '9')
    return -1;
  /* Cap iterations, not n: if tch stays '0', n stays 0 and n<100000
   * never trips (cookie=0 @200k on TEMP[0]). */
  while (k < 10u) {
    char c = tch(s, 0);
    if (c < '0' || c > '9')
      break;
    n = n * 10u + (unsigned)(c - '0');
    s = pinc(s, 1);
    k++;
  }
  *v = n;
  *ps = s;
  return 0;
}

static inline __attribute__((always_inline)) int is_half(unsigned frac,
                                                         unsigned nd)
{
  unsigned p = 1;
  unsigned i;
  for (i = 0; i < nd; i++) {
    if (p > 429496729u)
      return 0;
    p *= 10u;
  }
  return frac * 2u == p;
}

// Closed gles2-min literals: 0, 0.5, 1, 2. No libc strtof.
static inline __attribute__((always_inline)) int
parse_f32_bits(const char **ps, uint32_t *bits)
{
  const char *s = skip_ws(*ps);
  int neg = 0;
  unsigned ip = 0;
  unsigned frac = 0;
  unsigned nd = 0;
  uint32_t b;
  if (tch(s, 0) == '-') {
    neg = 1;
    s = pinc(s, 1);
  }
  if (tch(s, 0) < '0' || tch(s, 0) > '9')
    return -1;
  while (nd < 10u) {
    char c = tch(s, 0);
    if (c < '0' || c > '9')
      break;
    ip = ip * 10u + (unsigned)(c - '0');
    s = pinc(s, 1);
    nd++;
  }
  nd = 0;
  if (tch(s, 0) == '.') {
    s = pinc(s, 1);
    while (nd < 10u) {
      char c = tch(s, 0);
      if (c < '0' || c > '9')
        break;
      frac = frac * 10u + (unsigned)(c - '0');
      nd++;
      s = pinc(s, 1);
    }
  }
  if (ip == 0 && frac == 0)
    b = 0;
  else if (ip == 1 && frac == 0)
    b = APU_EX_F32_ONE;
  else if (ip == 2 && frac == 0)
    b = 0x40000000u;
  else if (ip == 0 && is_half(frac, nd))
    b = 0x3f000000u;
  else
    return -1;
  if (neg)
    b ^= 0x80000000u;
  *bits = b;
  *ps = s;
  return 0;
}

// 0 = none/.xyzw, 1..4 = .xxxx/.yyyy/.zzzz/.wwww, -1 = reject.
TGSI_LEAF int parse_swizzle(const char **ps)
{
  const char *s = *ps;
  if (tch(s, 0) != '.')
    return 0;
  s = pinc(s, 1);
  if (tch(s, 0) == 'x' && tch(s, 1) == 'y' && tch(s, 2) == 'z' && tch(s, 3) == 'w') {
    *ps = pinc(s, 4);
    return 0;
  }
  if (tch(s, 0) == 'x' && tch(s, 1) == 'x' && tch(s, 2) == 'x' && tch(s, 3) == 'x') {
    *ps = pinc(s, 4);
    return 1;
  }
  if (tch(s, 0) == 'y' && tch(s, 1) == 'y' && tch(s, 2) == 'y' && tch(s, 3) == 'y') {
    *ps = pinc(s, 4);
    return 2;
  }
  if (tch(s, 0) == 'z' && tch(s, 1) == 'z' && tch(s, 2) == 'z' && tch(s, 3) == 'z') {
    *ps = pinc(s, 4);
    return 3;
  }
  if (tch(s, 0) == 'w' && tch(s, 1) == 'w' && tch(s, 2) == 'w' && tch(s, 3) == 'w') {
    *ps = pinc(s, 4);
    return 4;
  }
  return -1;
}

TGSI_LEAF int parse_reg(const char **ps, unsigned *reg)
{
  const char *s = skip_ws(*ps);
  unsigned idx;
  unsigned base;
  int sw;
  if (tch(s, 0) == 'I' && tch(s, 1) == 'N' && tch(s, 2) == '[') {
    base = 0;
    s = pinc(s, 3);
  } else if (tch(s, 0) == 'O' && tch(s, 1) == 'U' && tch(s, 2) == 'T' && tch(s, 3) == '[') {
    base = 0;
    s = pinc(s, 4);
  } else if (tch(s, 0) == 'C' && tch(s, 1) == 'O' && tch(s, 2) == 'N' && tch(s, 3) == 'S' &&
             tch(s, 4) == 'T' && tch(s, 5) == '[') {
    base = 0;
    s = pinc(s, 6);
  } else if (tch(s, 0) == 'T' && tch(s, 1) == 'E' && tch(s, 2) == 'M' && tch(s, 3) == 'P' &&
             tch(s, 4) == '[') {
    base = 4;
    s = pinc(s, 5);
  } else {
    return -1;
  }
  if (parse_u(&s, &idx) != 0 || tch(s, 0) != ']')
    return -1;
  s = pinc(s, 1);
  sw = parse_swizzle(&s);
  if (sw < 0)
    return -1;
  if (base + idx >= APU_TGSI_MAX_REGS)
    return -1;
  *reg = base + idx;
  *ps = s;
  return 0;
}

TGSI_LEAF int parse_src(const char **ps, uint32_t imm[][4], unsigned imm_mask,
                        tgsi_src_t *o)
{
  const char *s = skip_ws(*ps);
  unsigned idx;
  int sw;
  o->reg = 0;
  o->neg = 0;
  o->is_imm = 0;
  o->bits = 0;
  if (tch(s, 0) == '-' && !(tch(s, 1) >= '0' && tch(s, 1) <= '9') && tch(s, 1) != '.') {
    o->neg = 1;
    s = pinc(s, 1);
    s = skip_ws(s);
  }
  if (tch(s, 0) == 'I' && tch(s, 1) == 'M' && tch(s, 2) == 'M' && tch(s, 3) == '[') {
    s = pinc(s, 4);
    if (parse_u(&s, &idx) != 0 || tch(s, 0) != ']' || idx >= APU_TGSI_MAX_IMM)
      return -1;
    s = pinc(s, 1);
    if ((imm_mask & (1u << idx)) == 0)
      return -1;
    sw = parse_swizzle(&s);
    if (sw < 0)
      return -1;
    if (sw == 0) {
      if (imm[idx][0] != imm[idx][1] || imm[idx][0] != imm[idx][2] ||
          imm[idx][0] != imm[idx][3])
        return -1;
      o->bits = imm[idx][0];
    } else
      o->bits = imm[idx][sw - 1];
    o->is_imm = 1;
    if (o->neg)
      o->bits ^= 0x80000000u;
    o->neg = 0;
    *ps = s;
    return 0;
  }
  if ((tch(s, 0) >= '0' && tch(s, 0) <= '9') || tch(s, 0) == '-' || tch(s, 0) == '.') {
    if (parse_f32_bits(&s, &o->bits) != 0)
      return -1;
    o->is_imm = 1;
    if (o->neg)
      o->bits ^= 0x80000000u;
    o->neg = 0;
    *ps = s;
    return 0;
  }
  if (parse_reg(&s, &o->reg) != 0)
    return -1;
  *ps = s;
  return 0;
}

static inline __attribute__((always_inline)) uint32_t *
wptr(uint32_t *out, unsigned n)
{
  uintptr_t p = (uintptr_t)out;
  uintptr_t o = (uintptr_t)n << 2;
#ifdef __riscv
  p = (uintptr_t)(uint32_t)p;
  __asm__ volatile ("add %0, %0, %1" : "+r"(p) : "r"(o));
#else
  p += o;
#endif
  return (uint32_t *)p;
}

TGSI_LEAF int emit(uint32_t *out, unsigned max, unsigned *n, uint32_t inst)
{
  if (*n >= max)
    return -1;
  *wptr(out, *n) = inst;
  (*n)++;
  return 0;
}

TGSI_LEAF int emit_ldc(uint32_t *out, unsigned max, unsigned *n, unsigned rd,
                       uint32_t bits)
{
  if (rd == 0 || rd >= APU_TGSI_MAX_REGS)
    return -1;
  if (emit(out, max, n, APU_EX_ENC(APU_EX_LDC, rd, 0, 0, 0, 0, 0, 0)) != 0)
    return -1;
  return emit(out, max, n, bits);
}

static inline __attribute__((always_inline)) unsigned
scratch_reg(unsigned dst, unsigned a, unsigned b, unsigned c)
{
  if (dst != 7 && a != 7 && b != 7 && c != 7)
    return 7;
  if (dst != 6 && a != 6 && b != 6 && c != 6)
    return 6;
  return 5;
}

static inline __attribute__((always_inline)) int
materialize(uint32_t *out, unsigned max, unsigned *n, unsigned dst,
                       unsigned a, unsigned b, unsigned c, const tgsi_src_t *src,
                       unsigned *reg)
{
  unsigned sc;
  if (!src->is_imm) {
    *reg = src->reg;
    return 0;
  }
  sc = scratch_reg(dst, a, b, c);
  if (emit_ldc(out, max, n, sc, src->bits) != 0)
    return -1;
  *reg = sc;
  return 0;
}

static inline __attribute__((always_inline)) int
parse_imm_decl(const char **pp, uint32_t imm[][4], unsigned *mask)
{
  const char *p = skip_ws(*pp);
  unsigned idx;
  unsigned k;
  uint32_t bits;
  if (!(tch(p, 0) == 'I' && tch(p, 1) == 'M' && tch(p, 2) == 'M' && tch(p, 3) == '['))
    return 0;
  p = pinc(p, 4);
  if (parse_u(&p, &idx) != 0 || tch(p, 0) != ']' || idx >= APU_TGSI_MAX_IMM)
    return -1;
  p = skip_ws(pinc(p, 1));
  if (tch(p, 0) == ',')
    p = skip_ws(pinc(p, 1));
  if (!(tch(p, 0) == 'F' && tch(p, 1) == 'L' && tch(p, 2) == 'T' && tch(p, 3) == '3' &&
        tch(p, 4) == '2'))
    return -1;
  p = skip_ws(pinc(p, 5));
  if (tch(p, 0) != '{')
    return -1;
  p = pinc(p, 1);
  for (k = 0; k < 4; k++) {
    if (parse_f32_bits(&p, &bits) != 0)
      return -1;
    imm[idx][k] = bits;
    p = skip_ws(p);
    if (k < 3) {
      if (tch(p, 0) != ',')
        return -1;
      p = pinc(p, 1);
    }
  }
  p = skip_ws(p);
  if (tch(p, 0) != '}')
    return -1;
  *mask |= 1u << idx;
  *pp = skip_ws(pinc(p, 1));
  return 1;
}

int g6lc_apu_tgsi_compile(const char *text, uint32_t *out, unsigned max,
                          unsigned *n_out, char *err, unsigned err_len)
{
#ifdef __riscv
  /* 32-bit spills at 4(mod 8) are high-half sw; fwram dropped them so
   * i/saw_header never stuck and FRAG was parsed forever (cookie=0
   * @200k). Nested volatile-n (likely 8-aligned) and s2-only line-walk
   * both C3'd. sd of aligned uint64_t matches IMM zeroing. */
  volatile uint64_t i;
  volatile uint64_t saw_header;
#else
  unsigned i;
  int saw_header;
#endif
  unsigned n = 0;
#ifdef __riscv
  text = (const char *)(uintptr_t)(uint32_t)(uintptr_t)text;
  out = (uint32_t *)(uintptr_t)(uint32_t)(uintptr_t)out;
  n_out = (unsigned *)(uintptr_t)(uint32_t)(uintptr_t)n_out;
  if (err != NULL)
    err = (char *)(uintptr_t)(uint32_t)(uintptr_t)err;
#endif
  uint32_t imm[APU_TGSI_MAX_IMM][4];
  unsigned imm_mask = 0;
  unsigned zi, zj;

  if (text == NULL || out == NULL || n_out == NULL || max == 0 ||
      max > APU_TGSI_MAX_INST) {
    set_err(err, err_len, "bad args");
    return -1;
  }
  if ((const char *)out == text)
    return -16;
  if (err == (char *)text)
    return -15;
  if ((const char *)n_out == text)
    return -17;
  {
    unsigned t0 = (unsigned)(uint8_t)text[0];
    if (t0 != 'F' && t0 != 'V' && t0 != '\0')
      return -13;
  }
  for (zi = 0; zi < APU_TGSI_MAX_IMM; zi++)
    for (zj = 0; zj < 4; zj++)
      imm[zi][zj] = 0;
  i = 0;
  saw_header = 0;
  while (tch(text, i) != '\0') {
    unsigned start = (unsigned)i;
    if (i > APU_TGSI_TEXT_CAP)
      return -18;
    for (;;) {
      char c = tch(text, i);
      if (c == '\0' || c == '\n')
        break;
      i = i + 1u;
      if (i > APU_TGSI_TEXT_CAP)
        return -18;
    }
    {
      const char *p;
      int decl;
      if (tch(text, i) == '\n')
        i = i + 1u;
      /* One parser on host and CVA6. tptr/tch so 0x9000xxxx + i is add. */
      p = tptr(text, start);
      p = skip_ws(p);
      if ((uint8_t)tch(text, 0) != 'F' && (uint8_t)tch(text, 0) != 'V' &&
          tch(text, 0) != '\0')
        return -14;
      if (tch(p, 0) == '\0' || tch(p, 0) == '#')
        continue;
      if (!saw_header) {
        if ((tch(p, 0) == 'F' && tch(p, 1) == 'R' && tch(p, 2) == 'A' && tch(p, 3) == 'G') ||
            (tch(p, 0) == 'V' && tch(p, 1) == 'E' && tch(p, 2) == 'R' && tch(p, 3) == 'T')) {
          saw_header = 1;
          continue;
        }
        set_err(err, err_len, "expected VERT or FRAG");
        return -20;
      }
      if (tch(p, 0) == 'D' && tch(p, 1) == 'C' && tch(p, 2) == 'L' &&
          (tch(p, 3) == ' ' || tch(p, 3) == '\t'))
        continue;
      unsigned dst, a, b, c;
      tgsi_src_t sa, sb, sc;
      decl = parse_imm_decl(&p, imm, &imm_mask);
      if (decl < 0) {
        set_err(err, err_len, "IMM decl");
        return -1;
      }
      if (decl > 0)
        continue;
      if (tch(p, 0) >= '0' && tch(p, 0) <= '9') {
        unsigned lk = 0;
        while (lk < 10u && tch(p, 0) >= '0' && tch(p, 0) <= '9') {
          p = pinc(p, 1);
          lk++;
        }
        p = skip_ws(p);
        if (tch(p, 0) != ':') {
          set_err(err, err_len, "bad label");
          return -1;
        }
        p = skip_ws(pinc(p, 1));
      }
      if (tch(p, 0) == 'E' && tch(p, 1) == 'N' && tch(p, 2) == 'D' && !is_ident(tch(p, 3))) {
        if (emit(out, max, &n, APU_EX_HALT_I) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        *n_out = n;
        return 0;
      }
      if (tch(p, 0) == 'M' && tch(p, 1) == 'O' && tch(p, 2) == 'V' && !is_ident(tch(p, 3))) {
        p = skip_ws(pinc(p, 3));
        if (parse_reg(&p, &dst) != 0) {
          set_err(err, err_len, "MOV dst");
          return -24;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sa) != 0) {
          set_err(err, err_len, "MOV src");
          return -25;
        }
        if (sa.is_imm) {
          unsigned rd = dst == 0 ? 7 : dst;
          if (emit_ldc(out, max, &n, rd, sa.bits) != 0) {
            set_err(err, err_len, "imem full");
            return -1;
          }
          if (dst == 0 &&
              emit(out, max, &n, APU_EX_ENC(APU_EX_MOV, 0, 7, 0, 0, 0, 0, 0)) !=
                  0) {
            set_err(err, err_len, "imem full");
            return -1;
          }
        } else if (emit(out, max, &n,
                        APU_EX_ENC(sa.neg ? APU_EX_FNEG : APU_EX_MOV, dst,
                                   sa.reg, 0, 0, 0, 0, 0)) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        continue;
      }
      if (tch(p, 0) == 'A' && tch(p, 1) == 'D' && tch(p, 2) == 'D' && !is_ident(tch(p, 3))) {
        p = skip_ws(pinc(p, 3));
        if (parse_reg(&p, &dst) != 0) {
          set_err(err, err_len, "ADD dst");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sa) != 0) {
          set_err(err, err_len, "ADD src0");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sb) != 0) {
          set_err(err, err_len, "ADD src1");
          return -1;
        }
        if (sa.neg) {
          set_err(err, err_len, "ADD src0 negate");
          return -1;
        }
        if (materialize(out, max, &n, dst, 0, 0, 0, &sa, &a) != 0 ||
            materialize(out, max, &n, dst, a, 0, 0, &sb, &b) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        if (emit(out, max, &n,
                 APU_EX_ENC(sb.neg ? APU_EX_FSUB : APU_EX_FADD, dst, a, b, 0, 0,
                            0, 0)) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        continue;
      }
      if (tch(p, 0) == 'S' && tch(p, 1) == 'U' && tch(p, 2) == 'B' && !is_ident(tch(p, 3))) {
        p = skip_ws(pinc(p, 3));
        if (parse_reg(&p, &dst) != 0) {
          set_err(err, err_len, "SUB dst");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sa) != 0) {
          set_err(err, err_len, "SUB src0");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sb) != 0) {
          set_err(err, err_len, "SUB src1");
          return -1;
        }
        if (sa.neg) {
          set_err(err, err_len, "SUB src0 negate");
          return -1;
        }
        if (materialize(out, max, &n, dst, 0, 0, 0, &sa, &a) != 0 ||
            materialize(out, max, &n, dst, a, 0, 0, &sb, &b) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        if (emit(out, max, &n,
                 APU_EX_ENC(sb.neg ? APU_EX_FADD : APU_EX_FSUB, dst, a, b, 0, 0,
                            0, 0)) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        continue;
      }
      if (tch(p, 0) == 'M' && tch(p, 1) == 'U' && tch(p, 2) == 'L' && !is_ident(tch(p, 3))) {
        p = skip_ws(pinc(p, 3));
        if (parse_reg(&p, &dst) != 0) {
          set_err(err, err_len, "MUL dst");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sa) != 0) {
          set_err(err, err_len, "MUL src0");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sb) != 0) {
          set_err(err, err_len, "MUL src1");
          return -1;
        }
        if (sa.neg || sb.neg) {
          set_err(err, err_len, "MUL negate");
          return -1;
        }
        if (materialize(out, max, &n, dst, 0, 0, 0, &sa, &a) != 0 ||
            materialize(out, max, &n, dst, a, 0, 0, &sb, &b) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        if (emit(out, max, &n,
                 APU_EX_ENC(APU_EX_FMUL, dst, a, b, 0, 0, 0, 0)) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        continue;
      }
      if (tch(p, 0) == 'M' && tch(p, 1) == 'A' && tch(p, 2) == 'D' && !is_ident(tch(p, 3))) {
        p = skip_ws(pinc(p, 3));
        if (parse_reg(&p, &dst) != 0) {
          set_err(err, err_len, "MAD dst");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sa) != 0) {
          set_err(err, err_len, "MAD src0");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sb) != 0) {
          set_err(err, err_len, "MAD src1");
          return -1;
        }
        p = skip_ws(p);
        if (tch(p, 0) == ',')
          p = pinc(p, 1);
        if (parse_src(&p, imm, imm_mask, &sc) != 0) {
          set_err(err, err_len, "MAD src2");
          return -1;
        }
        if (sa.neg || sb.neg || sc.neg) {
          set_err(err, err_len, "MAD negate");
          return -1;
        }
        if (materialize(out, max, &n, dst, 0, 0, 0, &sa, &a) != 0 ||
            materialize(out, max, &n, dst, a, 0, 0, &sb, &b) != 0 ||
            materialize(out, max, &n, dst, a, b, 0, &sc, &c) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        if (emit(out, max, &n,
                 APU_EX_ENC(APU_EX_FMADD, dst, a, b, c, 0, 0, 0)) != 0) {
          set_err(err, err_len, "imem full");
          return -1;
        }
        continue;
      }
      set_err(err, err_len, "unsupported TGSI");
      return -26;
    }
  }
  set_err(err, err_len, "missing END");
  return -27;
}
