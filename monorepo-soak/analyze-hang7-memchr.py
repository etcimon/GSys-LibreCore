#!/usr/bin/env python3
import re
from pathlib import Path
from collections import Counter

lines = [
    l
    for l in Path(__file__).with_name("hang7-fdtprobe.log").read_text(errors="replace").splitlines()
    if "[mc_pc]" in l
]

def g(l, p):
    m = re.search(p, l)
    return m.group(1) if m else None

pcs = Counter()
cpcs = Counter()
for l in lines:
    t = g(l, r"@([0-9a-f]+)")
    if not t or int(t, 16) < 130000:
        continue
    pcs[g(l, r"c0.npc=0x([0-9a-f]+)")] += 1
    cpcs[g(l, r"cpc=0x([0-9a-f]+)")] += 1

print("npc late (>=130k):")
for k, v in pcs.most_common(15):
    print(f"  {v:3d} {k}")
print("cpc late:")
for k, v in cpcs.most_common(15):
    print(f"  {v:3d} {k}")

print("\ntrue memchr loop npc in [4bf8,4c08], t>=100k:")
n = 0
for l in lines:
    pc = g(l, r"c0.npc=0x([0-9a-f]+)")
    if not pc:
        continue
    p = int(pc, 16)
    if not (0x80004BF8 <= p <= 0x80004C08):
        continue
    t = int(g(l, r"@([0-9a-f]+)"), 16)
    if t < 100000:
        continue
    print(
        f"t={t} npc={pc} cpc={g(l, r'cpc=0x([0-9a-f]+)')} "
        f"a0={g(l, r' a0=0x([0-9a-f]+)')} a1={g(l, r' a1=0x([0-9a-f]+)')} "
        f"a2={g(l, r' a2=0x([0-9a-f]+)')} a5={g(l, r' a5=0x([0-9a-f]+)')} "
        f"ra={g(l, r' ra=0x([0-9a-f]+)')} s1={g(l, r' s1=0x([0-9a-f]+)')}"
    )
    n += 1
    if n >= 15:
        break

# Recompute: if a0_cursor and a2_end, infer start = a0 when a5-a0 relationship
print("\nInfer start from a2_end - if a0 near a5-1:")
n = 0
for l in lines:
    pc = g(l, r"c0.npc=0x([0-9a-f]+)")
    if pc != "80004bfc":
        continue
    t = int(g(l, r"@([0-9a-f]+)"), 16)
    if t < 130000:
        continue
    a0 = int(g(l, r" a0=0x([0-9a-f]+)"), 16)
    a2 = int(g(l, r" a2=0x([0-9a-f]+)"), 16)
    a5 = int(g(l, r" a5=0x([0-9a-f]+)"), 16)
    a1 = g(l, r" a1=0x([0-9a-f]+)")
    ra = g(l, r" ra=0x([0-9a-f]+)")
    print(f"t={t} a0={a0:#x} a5={a5:#x} a2={a2:#x} a1={a1} ra={ra} span={a2-a0:#x}")
    n += 1
    if n >= 10:
        break

# Before hang: last healthy path_offset for /cpus
print("\nSamples with a1 pointing at /cpus path (8001f6c0) before 136k:")
for l in lines:
    t = int(g(l, r"@([0-9a-f]+)"), 16)
    if t > 136000:
        break
    a1 = g(l, r" a1=0x([0-9a-f]+)")
    if a1 == "8001f6c0":
        print(
            f"t={t} pc={g(l, r'c0.npc=0x([0-9a-f]+)')} "
            f"a0={g(l, r' a0=0x([0-9a-f]+)')} a1={a1} "
            f"a2={g(l, r' a2=0x([0-9a-f]+)')} ra={g(l, r' ra=0x([0-9a-f]+)')}"
        )
