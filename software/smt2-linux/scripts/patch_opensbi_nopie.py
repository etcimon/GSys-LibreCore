#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Patch OpenSBI Makefile to allow non-PIE bare-metal toolchains."""
from __future__ import annotations
import sys
from pathlib import Path


def patch(makefile: Path) -> None:
    t = makefile.read_text(encoding="utf-8")
    if "OPENSBI_ALLOW_NO_PIE" not in t:
        old = (
            "ifneq ($(OPENSBI_LD_PIE),y)\n"
            "$(error Your linker does not support creating PIEs, opensbi requires this.)\n"
            "endif"
        )
        new = (
            "ifneq ($(OPENSBI_LD_PIE),y)\n"
            "ifneq ($(OPENSBI_ALLOW_NO_PIE),y)\n"
            "$(error Your linker does not support creating PIEs, opensbi requires this.)\n"
            "endif\n"
            "$(info *** OpenSBI: non-PIE build (OPENSBI_ALLOW_NO_PIE=y) ***)\n"
            "endif"
        )
        if old not in t:
            raise SystemExit(f"PIE error block not found in {makefile}")
        t = t.replace(old, new, 1)
        print("[patch] ALLOW_NO_PIE guard added")

    reps = [
        ("CFLAGS+=-fPIE -pie\n", "ifeq ($(OPENSBI_LD_PIE),y)\nCFLAGS+=-fPIE -pie\nendif\n"),
        ("ASFLAGS+=-fPIE\n", "ifeq ($(OPENSBI_LD_PIE),y)\nASFLAGS+=-fPIE\nendif\n"),
        (
            "ELFFLAGS+=-Wl,--no-dynamic-linker -Wl,-pie\n",
            "ifeq ($(OPENSBI_LD_PIE),y)\nELFFLAGS+=-Wl,--no-dynamic-linker -Wl,-pie\nendif\n",
        ),
    ]
    for a, b in reps:
        if a in t and b not in t:
            t = t.replace(a, b, 1)
            print(f"[patch] wrapped {a.strip()}")
    makefile.write_text(t, encoding="utf-8")
    print(f"[patch] wrote {makefile}")


if __name__ == "__main__":
    mk = Path(sys.argv[1] if len(sys.argv) > 1 else "Makefile")
    patch(mk)
