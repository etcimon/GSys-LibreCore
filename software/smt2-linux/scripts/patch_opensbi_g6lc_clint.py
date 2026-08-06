#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply GSys LibreCore OpenSBI dual-hart / CLINT bring-up patches.

Idempotent. Targets OpenSBI 1.5 (PLATFORM=generic) tree used by
software/smt2-linux. Called from build-opensbi-smt2.sh after fetch.

Fixes:
  1. ROOT_REGION_MAX 16 -> 512
     64 MiB PLIC + large CLINT reg ranges exhaust 16 domain regions.
  2. CLINT mtime_size = ACLINT_DEFAULT_MTIME_SIZE (8 B)
     Upstream uses (reg_size - mtimecmp_size) which for a 0xc0000 CLINT
     maps ~hundreds of domain regions and hangs domain_finalize.
  3. Cap mtimecmp_size to hart_count * 8 for small hart counts.
  4. fdt_ipi_mswi: single-init guard (dual-compatible clint0 nodes).
  5. fdt_timer: break after first successful timer driver (same reason).
  6. Strip residual G6LC_STEP / G6LC_DEBUG sbi_printf probes if present.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def _write_if_changed(path: Path, text: str, label: str) -> bool:
    old = path.read_text(encoding="utf-8")
    if old == text:
        print(f"[patch-g6lc] ok {label} (already applied)")
        return False
    path.write_text(text, encoding="utf-8")
    print(f"[patch-g6lc] patched {label}")
    return True


def patch_domain(src: Path) -> None:
    p = src / "lib/sbi/sbi_domain.c"
    t = p.read_text(encoding="utf-8")
    t2, n = re.subn(
        r"#define\s+ROOT_REGION_MAX\s+\d+",
        "#define ROOT_REGION_MAX\t512",
        t,
        count=1,
    )
    if n == 0:
        raise SystemExit(f"ROOT_REGION_MAX not found in {p}")
    _write_if_changed(p, t2, "sbi_domain.c ROOT_REGION_MAX=512")


def patch_mtimer(src: Path) -> None:
    p = src / "lib/utils/timer/fdt_timer_mtimer.c"
    t = p.read_text(encoding="utf-8")

    # Already patched?
    if "G6LC_MTIMECMP_CAP" in t and "ACLINT_DEFAULT_MTIME_SIZE" in t and "exhaust ROOT_REGION" in t:
        print("[patch-g6lc] ok fdt_timer_mtimer.c (already applied)")
        return

    # Upstream CLINT block (OpenSBI 1.5).
    old = """\tif (is_clint) { /* SiFive CLINT */
\t\t/* Set CLINT addresses */
\t\tmt->mtimecmp_addr = addr[0] + ACLINT_DEFAULT_MTIMECMP_OFFSET;
\t\tmt->mtimecmp_size = ACLINT_DEFAULT_MTIMECMP_SIZE;
\t\tif (!quirks->clint_without_mtime) {
\t\t\tmt->mtime_addr = addr[0] + ACLINT_DEFAULT_MTIME_OFFSET;
\t\t\tmt->mtime_size = size[0] - mt->mtimecmp_size;
\t\t\t/* Adjust MTIMER address and size for CLINT device */
\t\t\tmt->mtime_addr += quirks->clint_mtime_offset;
\t\t\tmt->mtime_size -= quirks->clint_mtime_offset;
\t\t} else {
\t\t\tmt->mtime_addr = mt->mtime_size = 0;
\t\t}
\t\tmt->mtimecmp_addr += quirks->clint_mtime_offset;
\t} else { /* RISC-V ACLINT MTIMER */"""

    new = """\tif (is_clint) { /* SiFive CLINT */
\t\t/* Set CLINT addresses */
\t\tmt->mtimecmp_addr = addr[0] + ACLINT_DEFAULT_MTIMECMP_OFFSET;
\t\t/* Default size covers 4095 harts; for small systems use hart_count. */
\t\tmt->mtimecmp_size = ACLINT_DEFAULT_MTIMECMP_SIZE;
\t\tif (mt->hart_count && mt->hart_count < 64)
\t\t\tmt->mtimecmp_size = mt->hart_count * sizeof(u64); /* G6LC_MTIMECMP_CAP */

\t\tif (!quirks->clint_without_mtime) {
\t\t\tmt->mtime_addr = addr[0] + ACLINT_DEFAULT_MTIME_OFFSET;
\t\t\t/* CLINT mtime is a fixed 8-byte register at 0xbff8, not
\t\t\t * (reg_size - mtimecmp_size). Using the remainder makes
\t\t\t * OpenSBI map hundreds of domain regions for a 0xc0000 CLINT
\t\t\t * (CVA6/Ariane) and exhaust ROOT_REGION_MAX / hang.
\t\t\t */
\t\t\tmt->mtime_size = ACLINT_DEFAULT_MTIME_SIZE;
\t\t\t/* Adjust MTIMER address for CLINT device */
\t\t\tmt->mtime_addr += quirks->clint_mtime_offset;
\t\t} else {
\t\t\tmt->mtime_addr = mt->mtime_size = 0;
\t\t}
\t\tmt->mtimecmp_addr += quirks->clint_mtime_offset;
\t} else { /* RISC-V ACLINT MTIMER */"""

    if old not in t:
        # Partial / already-touched trees: ensure critical assignment exists.
        if "mt->mtime_size = ACLINT_DEFAULT_MTIME_SIZE" in t:
            print("[patch-g6lc] ok fdt_timer_mtimer.c (mtime_size already fixed)")
            return
        raise SystemExit(
            f"CLINT mtimer block not found in {p}; OpenSBI version mismatch?"
        )
    t2 = t.replace(old, new, 1)
    _write_if_changed(p, t2, "fdt_timer_mtimer.c mtime/mtimecmp")


def patch_mswi(src: Path) -> None:
    p = src / "lib/utils/ipi/fdt_ipi_mswi.c"
    t = p.read_text(encoding="utf-8")

    # Strip debug probes first.
    t = re.sub(
        r'\tsbi_printf\("G6LC_DEBUG:[^"]*"\s*,[^;]*\);\n',
        "",
        t,
    )
    t = re.sub(
        r'\tsbi_printf\("G6LC_DEBUG:[^"]*"\);\n',
        "",
        t,
    )
    # Drop unused console include if no remaining sbi_printf.
    if "sbi_printf" not in t and "#include <sbi/sbi_console.h>" in t:
        t = t.replace("#include <sbi/sbi_console.h>\n", "")

    if "mswi_inited" not in t:
        # Insert single-init guard (dual-compatible riscv,clint0 + sifive,clint0).
        t = t.replace(
            "#include <sbi_utils/ipi/aclint_mswi.h>\n",
            "#include <sbi_utils/ipi/aclint_mswi.h>\n\n\nstatic int mswi_inited;\n",
            1,
        )
        # After zalloc of ms is too late for early return; guard at top of fn.
        t = t.replace(
            "\tstruct aclint_mswi_data *ms;\n\n\tms = sbi_zalloc",
            "\tstruct aclint_mswi_data *ms;\n\n"
            "\tif (mswi_inited)\n"
            "\t\treturn 0;\n\n"
            "\tms = sbi_zalloc",
            1,
        )
        # Free on size-check failure (upstream leaks) + mark inited on success.
        t = t.replace(
            "\t\tif ((ms->size - offset) < ACLINT_MSWI_SIZE)\n"
            "\t\t\treturn SBI_EINVAL;\n",
            "\t\tif ((ms->size - offset) < ACLINT_MSWI_SIZE) {\n"
            "\t\t\tsbi_free(ms);\n"
            "\t\t\treturn SBI_EINVAL;\n"
            "\t\t}\n",
            1,
        )
        t = t.replace(
            "\trc = aclint_mswi_cold_init(ms);\n"
            "\tif (rc) {\n"
            "\t\tsbi_free(ms);\n"
            "\t\treturn rc;\n"
            "\t}\n\n"
            "\treturn 0;\n",
            "\trc = aclint_mswi_cold_init(ms);\n"
            "\tif (rc) {\n"
            "\t\tsbi_free(ms);\n"
            "\t\treturn rc;\n"
            "\t}\n"
            "\tmswi_inited = 1;\n\n"
            "\treturn 0;\n",
            1,
        )
    _write_if_changed(p, t, "fdt_ipi_mswi.c mswi_inited")


def patch_fdt_timer(src: Path) -> None:
    p = src / "lib/utils/timer/fdt_timer.c"
    t = p.read_text(encoding="utf-8")
    if "if (current_driver)\n\t\tbreak;" in t or "if (current_driver)\n\tbreak;" in t:
        # Already has break-after-first.
        if "multi-die or" not in t:
            print("[patch-g6lc] ok fdt_timer.c (already applied)")
            return

    # Upstream iterates all drivers without breaking; dual-compatible CLINT
    # nodes then double-init MTIMER. Prefer first successful driver.
    old = """\t\t\tif (rc)
\t\t\t\treturn rc;
\t\t\tcurrent_driver = drv;

\t\t\t/*
\t\t\t * We will have multiple timer devices on multi-die or
\t\t\t * multi-socket systems so we cannot break here.
\t\t\t */
\t\t}
\t}

\t/*
\t * We can't fail here since systems with Sstc might not provide
\t * mtimer/clint DT node in the device tree.
\t */
\treturn 0;"""

    new = """\t\t\tif (rc)
\t\t\t\treturn rc;
\t\t\tcurrent_driver = drv;
\t\t\tbreak;
\t\t}
\t\tif (current_driver)
\t\t\tbreak;
\t}

\treturn 0;"""

    if old not in t:
        if "current_driver = drv;\n\t\t\tbreak;" in t:
            print("[patch-g6lc] ok fdt_timer.c (already applied)")
            return
        print(f"[patch-g6lc] WARN fdt_timer.c block not found — leave as-is")
        return
    t2 = t.replace(old, new, 1)
    _write_if_changed(p, t2, "fdt_timer.c first-driver break")


def strip_g6lc_debug(src: Path) -> None:
    p = src / "lib/sbi/sbi_init.c"
    if not p.is_file():
        return
    t = p.read_text(encoding="utf-8")
    t2 = re.sub(r'\tsbi_printf\("G6LC_STEP:[^"]*"\);\n', "", t)
    t2 = re.sub(r'\tsbi_printf\("G6LC_STEP:[^"]*",[^;]*\);\n', "", t2)
    if t2 != t:
        p.write_text(t2, encoding="utf-8")
        print("[patch-g6lc] stripped G6LC_STEP probes from sbi_init.c")
    else:
        print("[patch-g6lc] ok sbi_init.c (no G6LC_STEP probes)")


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <opensbi-src-dir>", file=sys.stderr)
        return 2
    src = Path(sys.argv[1]).resolve()
    if not (src / "lib/sbi/sbi_domain.c").is_file():
        raise SystemExit(f"not an OpenSBI tree: {src}")
    print(f"[patch-g6lc] OpenSBI src: {src}")
    patch_domain(src)
    patch_mtimer(src)
    patch_mswi(src)
    patch_fdt_timer(src)
    strip_g6lc_debug(src)
    print("[patch-g6lc] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
