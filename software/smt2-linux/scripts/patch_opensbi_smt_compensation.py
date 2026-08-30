#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply GSys LibreCore SMT product-closeout FDT fixups to OpenSBI 1.5 generic.

Idempotent. Called from build-opensbi-smt2.{sh,ps1} after fetch. It reads the
`/soc/smt-product-closeout` node and removes FDT-advertised features that the
SMT2 RTL does not yet implement, so OpenSBI and Linux do not try to use them.

Current fixups:
  - `smt,zawrs = <0>`: drop `zawrs` from per-`cpu@` `riscv,isa` and
    `riscv,isa-extensions`. Restored automatically when the property is removed
    or set to <1>.

The properties themselves are left in the FDT so the product-closeout checklist
remains visible.
"""
from __future__ import annotations

import sys
from pathlib import Path


def _write_if_changed(path: Path, text: str, label: str) -> bool:
    old = path.read_text(encoding="utf-8", newline="")
    if old == text:
        print(f"[patch-smt] ok {label} (already applied)")
        return False
    path.write_text(text, encoding="utf-8", newline="")
    print(f"[patch-smt] patched {label}")
    return True


def patch_platform(src: Path) -> None:
    p = src / "platform" / "generic" / "platform.c"
    t = p.read_text(encoding="utf-8", newline="")

    # Preserve whatever line endings the source already uses.
    eol = "\r\n" if "\r\n" in t else "\n"

    if "g6lc_fdt_smt_compensation" in t:
        print("[patch-smt] ok platform.c (already applied)")
        return

    call_old = f"\tfw_platform_lookup_special(fdt, root_offset);{eol}"
    call_new = (
        f"\tfw_platform_lookup_special(fdt, root_offset);{eol}"
        f"\t/* G6LC: apply SMT product-closeout FDT fixups */{eol}"
        f"\tg6lc_fdt_smt_compensation(fdt);{eol}"
    )
    if call_old not in t:
        raise SystemExit(
            f"fw_platform_lookup_special() call not found in {p}; "
            "OpenSBI version mismatch?"
        )
    t = t.replace(call_old, call_new, 1)

    anchor = "static u32 fw_platform_calculate_heap_size(u32 hart_count)"
    if anchor not in t:
        raise SystemExit(
            f"fw_platform_calculate_heap_size() anchor not found in {p}; "
            "OpenSBI version mismatch?"
        )

    funcs = """\
/* G6LC SMT FDT compensation: read /soc/smt-product-closeout and fix up the FDT
 * so OpenSBI/Linux do not trust unimplemented SMT2 product features. Each fixup
 * is removed when its item is retired.
 */
static u32 g6lc_smt_zawrs = 1;
static u32 g6lc_smt_boot_crutches;

static void g6lc_fdt_remove_underscore_token(char *str, const char *tok)
{
\tsize_t sl = sbi_strlen(str);
\tsize_t tl = sbi_strlen(tok);
\tchar *p, *start, *end;

\tp = str;
\twhile (p) {
\t\tstart = p;
\t\tp = (char *)sbi_strchr(p, tok[0]);
\t\tif (!p)
\t\t\tbreak;
\t\tif (sbi_strncmp(p, tok, tl) != 0) {
\t\t\tp++;
\t\t\tcontinue;
\t\t}
\t\tif (p != str && p[-1] != '_') {
\t\t\tp++;
\t\t\tcontinue;
\t\t}
\t\t/* Token matches; remove it and one adjacent underscore. */
\t\tend = p + tl;
\t\tif (*end == '_')
\t\t\tend++;
\t\telse if (p != str)
\t\t\tstart--;
\t\tsbi_memmove(start, end, sl - (end - str) + 1);
\t\treturn;
\t}
}

static void g6lc_fdt_remove_stringlist_token(void *fdt, int node,
\t\t\t\t\t\t\t     const char *prop, const char *tok)
{
\tconst char *val, *s;
\tchar *newval, *dst;
\tint len, i, l, tl = (int)sbi_strlen(tok);

\tval = fdt_getprop(fdt, node, prop, &len);
\tif (!val || len <= 0)
\t\treturn;

\tnewval = sbi_malloc(len + 1);
\tif (!newval)
\t\treturn;

\tdst = newval;
\ti = 0;
\twhile (i < len) {
\t\ts = val + i;
\t\tl = 0;
\t\twhile (i + l < len && s[l] != '\\0')
\t\t\tl++;
\t\tif (l != tl || sbi_strncmp(s, tok, tl) != 0) {
\t\t\tif (dst != newval)
\t\t\t\t*dst++ = '\\0';
\t\t\tsbi_memcpy(dst, s, l);
\t\t\tdst += l;
\t\t}
\t\ti += l + 1;
\t}

\tif (dst == newval) {
\t\tfdt_delprop(fdt, node, prop);
\t} else {
\t\t*dst = '\\0';
\t\tfdt_setprop(fdt, node, prop, newval, dst - newval + 1);
\t}
\tsbi_free(newval);
}

static void g6lc_fdt_smt_compensation(void *fdt)
{
\tint node, cpus, cpu;
\tconst fdt32_t *val;
\tint len;
\tconst char *isa;
\tchar *newisa;

\tnode = fdt_path_offset(fdt, "/soc/smt-product-closeout");
\tif (node < 0)
\t\treturn;

\tval = fdt_getprop(fdt, node, "smt,zawrs", &len);
\tg6lc_smt_zawrs = (val && len >= 4) ? fdt32_to_cpu(*val) : 1;

\tval = fdt_getprop(fdt, node, "smt,boot-crutches", &len);
\tg6lc_smt_boot_crutches = (val && len >= 4) ? fdt32_to_cpu(*val) : 0;

\tif (!g6lc_smt_zawrs) {
\t\tcpus = fdt_path_offset(fdt, "/cpus");
\t\tif (cpus < 0)
\t\t\treturn;
\t\tfdt_for_each_subnode(cpu, fdt, cpus) {
\t\t\tisa = fdt_getprop(fdt, cpu, "riscv,isa", &len);
\t\t\tif (isa && len > 0) {
\t\t\t\tnewisa = sbi_malloc(len + 1);
\t\t\t\tif (newisa) {
\t\t\t\t\tsbi_memcpy(newisa, isa, len);
\t\t\t\t\tnewisa[len] = '\\0';
\t\t\t\t\tg6lc_fdt_remove_underscore_token(newisa, "zawrs");
\t\t\t\t\tif (sbi_strlen(newisa) < (size_t)len)
\t\t\t\t\t\tfdt_setprop_string(fdt, cpu,
\t\t\t\t\t\t\t\t  "riscv,isa", newisa);
\t\t\t\t\tsbi_free(newisa);
\t\t\t\t}
\t\t\t}
\t\t\tg6lc_fdt_remove_stringlist_token(fdt, cpu,
\t\t\t\t\t\t\t\t "riscv,isa-extensions", "zawrs");
\t\t}
\t}

\t/*
\t * TODO: g6lc_smt_boot_crutches consumption — when
\t * `SMT_COLD_EXCL` / `SMT_FIRST_ACT_EXCL` are retired, remove the
\t * `smt,boot-crutches` property and any secondary-hart gating here.
\t */
}

"""
    funcs = funcs.replace("\r\n", "\n").replace("\n", eol)
    t = t.replace(anchor, funcs + anchor, 1)
    _write_if_changed(p, t, "platform.c SMT FDT compensation")


def main() -> None:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        "build-platform/workspace/smt2-linux/opensbi"
    )
    if not (src / "Makefile").is_file():
        raise SystemExit(f"OpenSBI source not found at {src}")
    patch_platform(src)


if __name__ == "__main__":
    main()
