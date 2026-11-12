# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Textual instantiation closure of a top module over a remote-closure flist.

A SUPERSET of the elaborated hierarchy (every instantiation statement that
appears in the text is followed, whatever generate condition guards it), so
a module absent from the result is certainly not instantiated under that
top. Used where the local Verilator cannot dump the SoC hierarchy.

  python inst_closure.py <closure-dir> <flist-relative-to-closure> <top> [out.txt]
"""
import os
import re
import sys


def main():
    root, flist, top = sys.argv[1], sys.argv[2], sys.argv[3]
    files = []
    for line in open(os.path.join(root, flist), encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith(("+", "-", "//", "#")):
            continue
        p = line.replace("${CVA6_REPO_DIR}", root)
        if p.endswith((".sv", ".v")) and os.path.isfile(p):
            files.append(p)
    body = {}
    for p in files:
        t = open(p, encoding="utf-8", errors="replace").read()
        t = re.sub(r"//[^\n]*", "", t)
        t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
        for m in re.finditer(r"\bmodule\s+(?:automatic\s+)?(\w+)(.*?)\bendmodule\b", t, re.S):
            body[m.group(1)] = m.group(2)
    names = set(body)
    inst = {}
    for n, b in body.items():
        used = set()
        for m in re.finditer(r"(?m)^\s*(\w+)\s*(?:#\s*\(|\s+\w+\s*(?:\[[^\]]*\]\s*)?\()", b):
            if m.group(1) in names and m.group(1) != n:
                used.add(m.group(1))
        inst[n] = used
    live, todo = set(), [top]
    while todo:
        n = todo.pop()
        if n in live or n not in inst:
            continue
        live.add(n)
        todo.extend(inst[n])
    out = sys.argv[4] if len(sys.argv) > 4 else None
    if out:
        open(out, "w", encoding="utf-8", newline="\n").write("".join(f"{n}\n" for n in sorted(live)))
    print(f"files={len(files)} modules={len(names)} reachable-from-{top}={len(live)}")


if __name__ == "__main__":
    main()
