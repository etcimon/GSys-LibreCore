#!/usr/bin/env python3
"""Tally Verilator warnings from TH_DATA_DIR/build.log or a path arg."""
from collections import Counter
from pathlib import Path
import os
import re
import sys

p = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if p is None:
    d = Path(os.environ.get("TH_DATA_DIR", "."))
    cands = list(d.rglob("build.log"))
    p = cands[0] if cands else Path("/opt/testharness/work/work-ver-smt2-fw64-B/build.log")
text = p.read_text(errors="replace").splitlines()
pat = re.compile(r"%Warning-([A-Z0-9]+):\s+([^:]+):(\d+)")
c_type, c_file, c_pair = Counter(), Counter(), Counter()
for ln in text:
    m = pat.search(ln)
    if not m:
        continue
    t, f, n = m.group(1), m.group(2), m.group(3)
    f = f.replace("/opt/testharness/repo/", "")
    c_type[t] += 1
    c_file[f] += 1
    c_pair[(t, f, n)] += 1
print("TOTAL", sum(c_type.values()), "file", p)
print("--- by type ---")
for k, v in c_type.most_common():
    print(f"{v:5d} {k}")
print("--- by file ---")
for k, v in c_file.most_common(30):
    print(f"{v:5d} {k}")
print("--- loci ---")
for (t, f, n), v in c_pair.most_common(50):
    print(f"{v:3d} {t} {f}:{n}")
