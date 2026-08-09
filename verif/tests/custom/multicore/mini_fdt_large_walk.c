// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Soft-ladder residual scaffold P1 (iter-012): large multi-node BE FDT walk.
// Builds an in-memory OpenSBI-ish tree (root + cpus + N cpu@k + props) and
// walks with libfdt-shaped next_tag / check_prop / by_offset_ (stack lenp).
// Goal: closer stress than mini_fdt_libfdt_shape; if PASS on DI, PEEL residual
// remains full OpenSBI path (not multi-node walk alone).
//
// tohost=1 pass, 3 fail. Stack at 0x80008000. No CRT.
//
#include <stdint.h>

volatile uint64_t tohost __attribute__((section(".tohost"))) = 0;
volatile uint64_t fromhost __attribute__((section(".tohost"))) = 0;

static void pass(void) {
  tohost = 1;
  for (;;)
    ;
}
static void fail(void) {
  tohost = 3;
  for (;;)
    ;
}

#define FDT_MAGIC 0xd00dfeedu
#define FDT_BEGIN_NODE 1u
#define FDT_END_NODE 2u
#define FDT_PROP 3u
#define FDT_END 9u

// ~4 KiB blob budget (fits below typical mini stack)
#define FDT_CAP 4096
#define NR_CPU_NODES 16

static uint8_t fdt_mem[FDT_CAP] __attribute__((aligned(8)));
static uint32_t fdt_len;

static inline void be32_store(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

static inline uint32_t fdt32_ld(const void *p) {
  const uint8_t *bp = (const uint8_t *)p;
  return ((uint32_t)bp[0] << 24) | ((uint32_t)bp[1] << 16) | ((uint32_t)bp[2] << 8) |
         (uint32_t)bp[3];
}

static uint32_t emit_u32(uint32_t off, uint32_t v) {
  if (off + 4 > FDT_CAP)
    fail();
  be32_store(fdt_mem + off, v);
  return off + 4;
}

static uint32_t emit_name(uint32_t off, const char *s) {
  // NUL-terminated, then pad to 4
  while (*s) {
    if (off >= FDT_CAP)
      fail();
    fdt_mem[off++] = (uint8_t)*s++;
  }
  if (off >= FDT_CAP)
    fail();
  fdt_mem[off++] = 0;
  while (off & 3u) {
    if (off >= FDT_CAP)
      fail();
    fdt_mem[off++] = 0;
  }
  return off;
}

static uint32_t emit_prop(uint32_t off, uint32_t nameoff, const void *val, uint32_t len) {
  const uint8_t *vp = (const uint8_t *)val;
  uint32_t i;
  off = emit_u32(off, FDT_PROP);
  off = emit_u32(off, len);
  off = emit_u32(off, nameoff);
  for (i = 0; i < len; i++) {
    if (off >= FDT_CAP)
      fail();
    fdt_mem[off++] = vp[i];
  }
  while (off & 3u) {
    if (off >= FDT_CAP)
      fail();
    fdt_mem[off++] = 0;
  }
  return off;
}

// Header layout (libfdt):
// 0 magic, 4 totalsize, 8 off_dt_struct, 12 off_dt_strings,
// 16 off_mem_rsvmap, 20 version, 24 last_comp, 28 boot_cpuid,
// 32 size_dt_strings, 36 size_dt_struct
static void build_large_fdt(void) {
  // strings first at fixed place; structure after header+rsv
  const uint32_t off_rsv = 0x28;
  const uint32_t off_struct = 0x38;
  // string table: "compatible\0reg\0device_type\0riscv\0cpu\0"
  const uint32_t off_strings = 0x800; // leave room for structure growth
  uint32_t so = off_strings;
  uint32_t name_compatible, name_reg, name_dtype;
  uint32_t o;
  int k;
  char nodename[16];
  uint8_t regv[8];
  const char *risc = "riscv";
  const char *cpu = "cpu";

  // clear
  for (o = 0; o < FDT_CAP; o++)
    fdt_mem[o] = 0;

  // string table
  name_compatible = 0;
  {
    const char *s = "compatible";
    while (*s)
      fdt_mem[so++] = (uint8_t)*s++;
    fdt_mem[so++] = 0;
  }
  name_reg = so - off_strings;
  {
    const char *s = "reg";
    while (*s)
      fdt_mem[so++] = (uint8_t)*s++;
    fdt_mem[so++] = 0;
  }
  name_dtype = so - off_strings;
  {
    const char *s = "device_type";
    while (*s)
      fdt_mem[so++] = (uint8_t)*s++;
    fdt_mem[so++] = 0;
  }
  while (so & 3u)
    fdt_mem[so++] = 0;

  // structure
  o = off_struct;
  o = emit_u32(o, FDT_BEGIN_NODE);
  o = emit_name(o, ""); // root
  o = emit_prop(o, name_compatible, "test-root", 10);

  o = emit_u32(o, FDT_BEGIN_NODE);
  o = emit_name(o, "cpus");
  o = emit_prop(o, name_compatible, "cpus", 5);

  for (k = 0; k < NR_CPU_NODES; k++) {
    // name "cpu@N"
    int i = 0;
    const char *p = "cpu@";
    while (*p)
      nodename[i++] = *p++;
    if (k >= 10)
      nodename[i++] = (char)('0' + (k / 10));
    nodename[i++] = (char)('0' + (k % 10));
    nodename[i] = 0;

    o = emit_u32(o, FDT_BEGIN_NODE);
    o = emit_name(o, nodename);
    o = emit_prop(o, name_compatible, risc, 6);
    o = emit_prop(o, name_dtype, cpu, 4);
    // reg = <0 k> as two BE words
    be32_store(regv, 0);
    be32_store(regv + 4, (uint32_t)k);
    o = emit_prop(o, name_reg, regv, 8);
    o = emit_u32(o, FDT_END_NODE);
  }

  o = emit_u32(o, FDT_END_NODE); // cpus
  o = emit_u32(o, FDT_END_NODE); // root
  o = emit_u32(o, FDT_END);

  if (o > off_strings)
    fail(); // structure collided with strings

  // empty mem_rsvmap terminator at off_rsv
  be32_store(fdt_mem + off_rsv, 0);
  be32_store(fdt_mem + off_rsv + 4, 0);
  be32_store(fdt_mem + off_rsv + 8, 0);
  be32_store(fdt_mem + off_rsv + 12, 0);

  fdt_len = so;
  be32_store(fdt_mem + 0, FDT_MAGIC);
  be32_store(fdt_mem + 4, fdt_len);
  be32_store(fdt_mem + 8, off_struct);
  be32_store(fdt_mem + 12, off_strings);
  be32_store(fdt_mem + 16, off_rsv);
  be32_store(fdt_mem + 20, 17); // version
  be32_store(fdt_mem + 24, 16); // last_comp_version
  be32_store(fdt_mem + 28, 0);
  be32_store(fdt_mem + 32, fdt_len - off_strings);
  be32_store(fdt_mem + 36, o - off_struct);
}

static inline uint32_t fdt_off_dt_struct(const void *fdt) {
  return fdt32_ld((const uint8_t *)fdt + 8);
}

static const void *fdt_offset_ptr(const void *fdt, int offset, unsigned len) {
  uint32_t absoff = fdt_off_dt_struct(fdt) + (uint32_t)offset;
  uint32_t totalsz = fdt32_ld((const uint8_t *)fdt + 4);
  if (absoff + len > totalsz)
    return 0;
  return (const uint8_t *)fdt + absoff;
}

static int fdt_next_tag(const void *fdt, int offset, int *nextoffset) {
  const uint32_t *tagp;
  uint32_t tag;
  int start = offset;

  if (nextoffset)
    *nextoffset = -8;
  if (offset < 0 || (offset & 3))
    goto fail;

  tagp = fdt_offset_ptr(fdt, offset, 4);
  if (!tagp)
    goto fail;
  tag = fdt32_ld(tagp);
  offset += 4;

  if (tag == FDT_BEGIN_NODE) {
    const char *p = fdt_offset_ptr(fdt, offset, 1);
    if (!p)
      goto fail;
    for (;;) {
      char c = *p++;
      offset++;
      if (c == 0)
        break;
    }
    offset = (offset + 3) & ~3;
  } else if (tag == FDT_PROP) {
    const uint32_t *lenp = fdt_offset_ptr(fdt, offset, 8);
    uint32_t len;
    if (!lenp)
      goto fail;
    len = fdt32_ld(lenp);
    offset += 8;
    offset += (int)((len + 3) & ~3u);
  } else if (tag == FDT_END || tag == FDT_END_NODE) {
    /* ok */
  } else {
    tag = FDT_END;
  }

  if (nextoffset) {
    if (offset <= start)
      *nextoffset = -11;
    else
      *nextoffset = offset;
  }
  return (int)tag;

fail:
  if (nextoffset)
    *nextoffset = -11;
  return -11;
}

static int fdt_check_prop_offset_(const void *fdt, int offset) {
  int nextoffset;
  int tag;
  if (offset < 0 || (offset & 3))
    return -4;
  tag = fdt_next_tag(fdt, offset, &nextoffset);
  if (tag != (int)FDT_PROP)
    return -4;
  (void)nextoffset;
  return offset;
}

static const void *fdt_get_property_by_offset_(const void *fdt, int offset, int *lenp) {
  int err;
  const uint32_t *prop;
  err = fdt_check_prop_offset_(fdt, offset);
  if (err < 0) {
    if (lenp)
      *lenp = err;
    return 0;
  }
  // offset at PROP tag: words [tag, len, nameoff, data...]
  prop = fdt_offset_ptr(fdt, offset, 12);
  if (!prop) {
    if (lenp)
      *lenp = -4;
    return 0;
  }
  if (lenp)
    *lenp = (int)fdt32_ld(prop + 1); // length field
  return prop;
}

// Full tree walk: count PROP success/fail via stack lenp (OpenSBI shape)
static int walk_count_props(const void *fdt) {
  int offset = 0;
  int nextoff = 0;
  int tag;
  int props = 0;
  int fails = 0;
  int i;

  for (i = 0; i < 512; i++) {
    int len = 0xdeadbeef;
    tag = fdt_next_tag(fdt, offset, &nextoff);
    if (tag < 0)
      return -1;
    if (tag == (int)FDT_END)
      break;
    if (tag == (int)FDT_PROP) {
      const void *p = fdt_get_property_by_offset_(fdt, offset, &len);
      if (!p || len < 0)
        fails++;
      else
        props++;
    }
    // intentional fail-path stress (misaligned offset) between nodes
    {
      int l2 = 0xface;
      const void *p2 = fdt_get_property_by_offset_(fdt, offset + 1, &l2);
      if (p2 || l2 >= 0)
        return -4;
    }
    if (nextoff <= offset)
      return -2;
    offset = nextoff;
  }
  if (fails)
    return -5;
  // root compat + cpus compat + 16*(compat+dtype+reg) = 2 + 48 = 50
  if (props < 50)
    return -3;
  return props;
}

void _start(void) {
  int n;
  int r;

  __asm__ volatile("li sp, 0x80008000");

  build_large_fdt();
  if (fdt32_ld(fdt_mem) != FDT_MAGIC)
    fail();

  n = walk_count_props(fdt_mem);
  if (n < 50)
    fail();

  // second full walk (stability)
  r = walk_count_props(fdt_mem);
  if (r != n)
    fail();

  pass();
}
