// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Soft-ladder iter-012: freestanding libfdt-shaped walk (OpenSBI-like).
// Mirrors fdt_next_tag / fdt_check_prop_offset_ / fdt_get_property_by_offset_
// stack + lenp discipline against a real BE FDT blob.
//
// Build: see verif/regress or manual gcc command in soft-ladder ITERATION.
// tohost=1 pass, 3 fail. No git commit (user commits manually).
//
#include <stdint.h>

// HTIF tohost (link script places .tohost)
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

// --- minimal BE helpers (libfdt style) ---
static inline uint32_t fdt32_ld(const void *p) {
  const uint8_t *bp = (const uint8_t *)p;
  return ((uint32_t)bp[0] << 24) | ((uint32_t)bp[1] << 16) | ((uint32_t)bp[2] << 8) |
         (uint32_t)bp[3];
}

#define FDT_MAGIC 0xd00dfeed
#define FDT_BEGIN_NODE 1
#define FDT_END_NODE 2
#define FDT_PROP 3
#define FDT_END 9

// Real minimal FDT: root { compatible = "test"; } (same as mini_fdt_walk_prop.S)
static const uint8_t fdt_blob[] __attribute__((aligned(8))) = {
    0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x00, 0x70, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x60,
    0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // structure @ 0x38
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x05,
    0x00, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00,
    // strings @ 0x60
    'c',  'o',  'm',  'p',  'a',  't',  'i',  'b',  'l',  'e',  0,    't',  'e',  's',  't',  0,
    0,    0};

static inline uint32_t fdt_off_dt_struct(const void *fdt) {
  return fdt32_ld((const uint8_t *)fdt + 8);
}

static const void *fdt_offset_ptr(const void *fdt, int offset, unsigned len) {
  uint32_t absoff = fdt_off_dt_struct(fdt) + (uint32_t)offset;
  if (absoff + len > sizeof(fdt_blob))
    return 0;
  return (const uint8_t *)fdt + absoff;
}

// libfdt-shaped next_tag: many BE loads + *nextoffset stores (s3 in OpenSBI)
static int fdt_next_tag(const void *fdt, int offset, int *nextoffset) {
  const uint32_t *tagp;
  uint32_t tag;
  int start = offset;

  if (nextoffset)
    *nextoffset = -8; // OpenSBI sets -8 first

  if (offset < 0 || (offset & 3))
    goto fail;

  tagp = fdt_offset_ptr(fdt, offset, 4);
  if (!tagp)
    goto fail;
  tag = fdt32_ld(tagp);
  offset += 4;

  if (tag == FDT_BEGIN_NODE) {
    // skip name including NUL, then align (libfdt)
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
    offset += 8; // len + nameoff
    offset += (int)((len + 3) & ~3u);
  } else if (tag == FDT_END || tag == FDT_END_NODE) {
    /* offset already +4 */
  } else {
    tag = FDT_END; // treat unknown as end-ish for mini
  }

  if (nextoffset) {
    if (offset <= start)
      *nextoffset = -11; // BADSTRUCTURE-ish
    else
      *nextoffset = offset;
  }
  return (int)tag;

fail:
  if (nextoffset)
    *nextoffset = -11;
  return -11;
}

// OpenSBI fdt_check_prop_offset_ shape
static int fdt_check_prop_offset_(const void *fdt, int offset) {
  int nextoffset;
  int tag;

  if (offset < 0 || (offset & 3))
    return -4;
  tag = fdt_next_tag(fdt, offset, &nextoffset);
  if (tag != FDT_PROP)
    return -4;
  (void)nextoffset;
  return offset;
}

// OpenSBI fdt_get_property_by_offset_ shape (s2 = lenp)
static const void *fdt_get_property_by_offset_(const void *fdt, int offset, int *lenp) {
  int err;
  const uint32_t *prop;

  // OpenSBI: mv s2, a2
  err = fdt_check_prop_offset_(fdt, offset);
  if (err < 0) {
    if (lenp)
      *lenp = err; // sw a0,0(s2) on error
    return 0;
  }
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

// namelen_-like: walk tags then by_offset_ for each PROP
static int walk_and_get_compatible(const void *fdt, int *out_len) {
  int offset = 0;
  int nextoff = 0;
  int tag;
  int found = 0;
  int len = -1;
  const void *p;

  for (int i = 0; i < 32; i++) {
    tag = fdt_next_tag(fdt, offset, &nextoff);
    if (tag < 0)
      return -1;
    if (tag == FDT_END)
      break;
    if (tag == FDT_PROP) {
      // poison then call (OpenSBI pattern stress)
      int *lenp = out_len;
      volatile uintptr_t poison = 0x80012b2aULL;
      (void)poison;
      p = fdt_get_property_by_offset_(fdt, offset, lenp);
      if (p && lenp && *lenp == 5)
        found = 1;
    }
    if (nextoff <= offset)
      return -2;
    offset = nextoff;
  }
  return found ? 0 : -3;
}

void _start(void) {
  int len = 0xdeadbeef;
  int rc;
  int i;

  // No CRT: set stack (same as mini_*.S)
  __asm__ volatile("li sp, 0x80008000");

  // magic
  if (fdt32_ld(fdt_blob) != FDT_MAGIC)
    fail();

  // single by_offset success
  {
    int l = 0xfeed;
    const void *p = fdt_get_property_by_offset_(fdt_blob, 8, &l);
    if (!p || l != 5)
      fail();
  }

  // by_offset fail path (misaligned): *lenp must be stack, not code
  {
    int l = 0xface;
    const void *p = fdt_get_property_by_offset_(fdt_blob, 4, &l);
    if (p || l >= 0)
      fail();
  }

  // full walk
  rc = walk_and_get_compatible(fdt_blob, &len);
  if (rc != 0 || len != 5)
    fail();

  // thrash
  for (i = 0; i < 64; i++) {
    int l = 0;
    const void *p;
    volatile int dummy = i;
    p = fdt_get_property_by_offset_(fdt_blob, 8, &l);
    if (!p || l != 5)
      fail();
    p = fdt_get_property_by_offset_(fdt_blob, 1, &l);
    if (p || l >= 0)
      fail();
    (void)dummy;
  }

  pass();
}
