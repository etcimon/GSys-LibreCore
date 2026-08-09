#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Generate mini_fdt_opensbi_blob.c from an OpenSBI payload ELF FDT.

from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[4]
ELF = ROOT / "software/smt2-linux/soft-ladder/build/fw_payload_diag.elf"
OUT = Path(__file__).resolve().parent / "mini_fdt_opensbi_blob.c"


def main() -> int:
    if not ELF.is_file():
        print("missing", ELF, file=sys.stderr)
        return 1
    elf = ELF.read_bytes()
    mag = bytes([0xD0, 0x0D, 0xFE, 0xED])
    j = elf.find(mag)
    if j < 0:
        print("no FDT magic", file=sys.stderr)
        return 1
    tsz = struct.unpack(">I", elf[j + 4 : j + 8])[0]
    dtb = elf[j : j + tsz]
    print(f"FDT off=0x{j:x} tsz=0x{tsz:x}")

    body = r'''
static inline uint32_t fdt32_ld(const void *p) {
  const uint8_t *bp = (const uint8_t *)p;
  return ((uint32_t)bp[0] << 24) | ((uint32_t)bp[1] << 16) |
         ((uint32_t)bp[2] << 8) | (uint32_t)bp[3];
}
static inline uint32_t fdt_off_struct(const void *fdt) {
  return fdt32_ld((const uint8_t *)fdt + 8);
}
static inline uint32_t fdt_totalsize(const void *fdt) {
  return fdt32_ld((const uint8_t *)fdt + 4);
}

static const void *fdt_offset_ptr(const void *fdt, int offset, unsigned len) {
  uint32_t absoff = fdt_off_struct(fdt) + (uint32_t)offset;
  if (absoff + len > fdt_totalsize(fdt))
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
    const uint32_t *lp = fdt_offset_ptr(fdt, offset, 8);
    uint32_t len;
    if (!lp)
      goto fail;
    len = fdt32_ld(lp);
    offset += 8 + (int)((len + 3) & ~3u);
  } else if (tag != FDT_END && tag != FDT_END_NODE) {
    tag = FDT_END;
  }
  if (nextoffset)
    *nextoffset = (offset <= start) ? -11 : offset;
  return (int)tag;
fail:
  if (nextoffset)
    *nextoffset = -11;
  return -11;
}

static int fdt_check_node_offset_(const void *fdt, int offset) {
  int nextoffset;
  if (offset < 0 || (offset & 3))
    return -4;
  if (fdt_next_tag(fdt, offset, &nextoffset) != (int)FDT_BEGIN_NODE)
    return -4;
  (void)nextoffset;
  return offset;
}

static int fdt_check_prop_offset_(const void *fdt, int offset) {
  int nextoffset;
  if (offset < 0 || (offset & 3))
    return -4;
  if (fdt_next_tag(fdt, offset, &nextoffset) != (int)FDT_PROP)
    return -4;
  (void)nextoffset;
  return offset;
}

/* OpenSBI shape: lenp stack; fail path *lenp = err must not target code. */
static const void *fdt_get_property_by_offset_(const void *fdt, int offset, int *lenp) {
  int err = fdt_check_prop_offset_(fdt, offset);
  if (err < 0) {
    if (lenp)
      *lenp = err;
    return 0;
  }
  {
    const uint32_t *prop = fdt_offset_ptr(fdt, offset, 12);
    if (!prop) {
      if (lenp)
        *lenp = -4;
      return 0;
    }
    if (lenp)
      *lenp = (int)fdt32_ld(prop + 1);
    return prop;
  }
}

static int strn_eq(const char *a, const char *b, int n) {
  int i;
  for (i = 0; i < n; i++)
    if (a[i] != b[i])
      return 0;
  return 1;
}

static const void *fdt_get_property_namelen_(const void *fdt, int offset, const char *name,
                                            int namelen, int *lenp) {
  int nextoff;
  int tag;
  int off;
  const void *prop;
  int l;
  const uint8_t *strtab;
  uint32_t off_strings = fdt32_ld((const uint8_t *)fdt + 12);

  off = fdt_check_node_offset_(fdt, offset);
  if (off < 0) {
    if (lenp)
      *lenp = off;
    return 0;
  }

  strtab = (const uint8_t *)fdt + off_strings;
  for (;;) {
    tag = fdt_next_tag(fdt, off, &nextoff);
    if (tag == (int)FDT_PROP) {
      l = 0xdead;
      prop = fdt_get_property_by_offset_(fdt, off, &l);
      if (prop) {
        uint32_t nameoff = fdt32_ld((const uint32_t *)prop + 2);
        const char *pname = (const char *)(strtab + nameoff);
        if (strn_eq(pname, name, namelen) && pname[namelen] == 0) {
          if (lenp)
            *lenp = l;
          return prop;
        }
      } else if (l >= 0) {
        if (lenp)
          *lenp = -13;
        return 0;
      }
    } else if (tag == (int)FDT_END || tag == (int)FDT_BEGIN_NODE || tag < 0 ||
               tag == (int)FDT_END_NODE) {
      break;
    }
    if (nextoff <= off)
      break;
    off = nextoff;
  }
  if (lenp)
    *lenp = -1;
  return 0;
}

static int find_cpu0_offset(const void *fdt) {
  int offset = 0, nextoff = 0, tag, i;
  for (i = 0; i < 256; i++) {
    tag = fdt_next_tag(fdt, offset, &nextoff);
    if (tag < 0 || tag == (int)FDT_END)
      return -1;
    if (tag == (int)FDT_BEGIN_NODE) {
      const char *nm = fdt_offset_ptr(fdt, offset + 4, 1);
      if (nm && nm[0] == 'c' && nm[1] == 'p' && nm[2] == 'u' && nm[3] == '@' &&
          nm[4] == '0' && nm[5] == 0)
        return offset;
    }
    if (nextoff <= offset)
      return -1;
    offset = nextoff;
  }
  return -1;
}

void _start(void) {
  int len = 0xface;
  const void *p;
  int cpu0;
  int i;

  __asm__ volatile("li sp, 0x80008000");

  if (fdt32_ld(fdt_blob) != 0xd00dfeedu)
    fail();
  if (fdt_totalsize(fdt_blob) != FDT_BLOB_LEN)
    fail();

  p = fdt_get_property_namelen_(fdt_blob, 0, "compatible", 10, &len);
  if (!p || len < 4)
    fail();

  for (i = 0; i < 32; i++) {
    int l = 0xbeef;
    p = fdt_get_property_namelen_(fdt_blob, 1, "compatible", 10, &l);
    if (p || l >= 0)
      fail();
  }

  cpu0 = find_cpu0_offset(fdt_blob);
  if (cpu0 < 0)
    fail();

  len = 0;
  p = fdt_get_property_namelen_(fdt_blob, cpu0, "device_type", 11, &len);
  if (!p || len < 3)
    fail();

  len = 0;
  p = fdt_get_property_namelen_(fdt_blob, cpu0, "compatible", 10, &len);
  if (!p || len < 4)
    fail();

  for (i = 0; i < 64; i++) {
    int l = 0;
    p = fdt_get_property_namelen_(fdt_blob, 0, "compatible", 10, &l);
    if (!p || l < 4)
      fail();
    p = fdt_get_property_namelen_(fdt_blob, cpu0, "reg", 3, &l);
    if (!p || l < 4)
      fail();
    p = fdt_get_property_namelen_(fdt_blob, cpu0, "no-such-prop", 12, &l);
    if (p)
      fail();
  }

  pass();
}
'''

    lines = [
        "// SPDX-License-Identifier: MIT",
        "// Copyright (c) 2026 Etienne Cimon",
        "//",
        "// Soft-ladder P1: real OpenSBI smt2 FDT blob (from fw_payload_diag.elf)",
        "// + namelen_/by_offset_ stack-lenp shape (PEEL pin 12eb2 / mtval 12b2a).",
        f"// Auto-generated by {Path(__file__).name}; re-run after payload FDT changes.",
        "// tohost=1 pass, 3 fail. sp=0x80008000.",
        "//",
        "#include <stdint.h>",
        "",
        'volatile uint64_t tohost __attribute__((section(".tohost"))) = 0;',
        'volatile uint64_t fromhost __attribute__((section(".tohost"))) = 0;',
        "static void pass(void) { tohost = 1; for (;;) ; }",
        "static void fail(void) { tohost = 3; for (;;) ; }",
        "",
        "#define FDT_BEGIN_NODE 1u",
        "#define FDT_END_NODE 2u",
        "#define FDT_PROP 3u",
        "#define FDT_END 9u",
        f"#define FDT_BLOB_LEN {len(dtb)}",
        "static const uint8_t fdt_blob[FDT_BLOB_LEN] __attribute__((aligned(8))) = {",
    ]
    for i in range(0, len(dtb), 16):
        chunk = dtb[i : i + 16]
        lines.append("  " + ", ".join(f"0x{b:02x}" for b in chunk) + ",")
    lines.append("};")
    lines.append(body)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("wrote", OUT, "size", OUT.stat().st_size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
