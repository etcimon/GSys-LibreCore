#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Nop leftover sim $display in already-verilated C++.

Unconditional always_comb $display ([sb-alloc], [iq-dbg]) compiled into
VL_WRITEF that SIGSEGV'd the -O0 g6lc64_ai testharness around t=2662,
mid-print of a packed issue_q extract. Used on AI_MATRIX_SKIP_VERILATE
so we do not re-verilate (~30 min, OOM at -j2). Next full verilate picks
up the plusarg-gated RTL instead.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

TAGS = ("sb-alloc", "iq-dbg")


def _strip_one(text: str) -> tuple[str, int]:
    nsubs = 0
    i = 0
    out: list[str] = []
    needles = [f'VL_WRITEF("[{tag}]' for tag in TAGS]
    while i < len(text):
        hit = -1
        tag = ""
        for needle, t in zip(needles, TAGS):
            j = text.find(needle, i)
            if j != -1 and (hit < 0 or j < hit):
                hit = j
                tag = t
        if hit < 0:
            out.append(text[i:])
            break
        out.append(text[i:hit])
        k = text.find("(", hit)
        if k < 0:
            out.append(text[hit:])
            break
        depth = 0
        while k < len(text):
            ch = text[k]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    k += 1
                    if k < len(text) and text[k] == ";":
                        k += 1
                    break
            k += 1
        out.append(f"/* stripped leftover [{tag}] display */")
        nsubs += 1
        i = k
    return "".join(out), nsubs


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <verilator-Mdir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"no such Mdir: {root}", file=sys.stderr)
        return 2
    files = 0
    subs = 0
    # Do not slurp every DepSet_*.cpp (tens–hundreds of MiB). grep -l stops at
    # the first hit; the previous full-read pass sat on the 30 Gi builder.
    grep = subprocess.run(
        [
            "grep",
            "-l",
            "-E",
            r"\[sb-alloc\]|\[iq-dbg\]",
            "-r",
            "--include=*.cpp",
            str(root),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    hits = [Path(line) for line in grep.stdout.splitlines() if line.strip()]
    print(f"[ai-strip-display] grep hits={len(hits)}", flush=True)
    for p in hits:
        text = p.read_text(encoding="utf-8", errors="replace")
        new, n = _strip_one(text)
        if n:
            p.write_text(new, encoding="utf-8")
            obj = p.with_suffix(".o")
            if obj.exists():
                obj.unlink()
                print(f"[ai-strip-display] rm {obj.name}", flush=True)
            files += 1
            subs += n
            print(f"[ai-strip-display] {p.name}: {n} VL_WRITEF", flush=True)
    print(
        f"[ai-strip-display] stripped {subs} leftover $display in {files} files under {root}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
