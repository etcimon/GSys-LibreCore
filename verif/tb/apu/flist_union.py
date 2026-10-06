#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Emit the union of SystemVerilog -f flists with duplicate files removed.

Each entry (file or +incdir+) appears once, in first-seen order; nested
-f includes are expanded recursively.  ${VAR} references resolve from the
environment (CVA6_REPO_DIR etc.).  Usage:

    flist_union.py OUT.f base.f extra.f [...]

Lets one command line combine core/Flist.cva6 (which already carries
config_pkg, axi_pkg, the common cells and fpnew) with
corev_apu/apu/Flist.apu_soc without double-compiling packages.
"""
import os
import re
import sys

VAR = re.compile(r"\$\{(\w+)\}|\$(\w+)")


def subst(s):
    def rep(m):
        name = m.group(1) or m.group(2)
        if name not in os.environ:
            raise KeyError(f"flist references unset ${name}")
        return os.environ[name]
    return VAR.sub(rep, s)


def emit(path, seen, out):
    for raw in open(path, encoding="utf-8"):
        line = raw.split("//", 1)[0].strip() if not raw.strip().startswith(
            ("+incdir+", "-f", "-F")) else raw.strip()
        if not line:
            continue
        line = subst(line)
        if line.startswith(("-f", "-F")):
            emit(line[2:].strip(), seen, out)
            continue
        key = os.path.abspath(line.split("+", 1)[1]) \
            if line.startswith("+incdir+") else os.path.abspath(line)
        if key in seen:
            continue
        seen.add(key)
        out.append(line)


def main():
    outp, seen, out = sys.argv[1], set(), []
    for f in sys.argv[2:]:
        emit(f, seen, out)
    with open(outp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"flist_union: {len(out)} entries -> {outp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
