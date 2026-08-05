#!/usr/bin/env python3
import re
from pathlib import Path

log = Path(__file__).with_name("hang7-fdtprobe.log")
lines = [l for l in log.read_text(errors="replace").splitlines() if "[mc_pc]" in l]

def g(l, p):
    m = re.search(p, l)
    return m.group(1) if m else None

print("=== samples with ra=80013788 (alias memchr) first 20 ===")
n = 0
for l in lines:
    if g(l, r"ra=0x([0-9a-f]+)") == "80013788":
        t = int(g(l, r"@([0-9a-f]+)"), 16)
        print(
            f"t={t} pc={g(l, r'c0.npc=0x([0-9a-f]+)')} "
            f"a0={g(l, r' a0=0x([0-9a-f]+)')} a1={g(l, r' a1=0x([0-9a-f]+)')} "
            f"a2={g(l, r' a2=0x([0-9a-f]+)')} s1={g(l, r' s1=0x([0-9a-f]+)')} "
            f"s0={g(l, r' s0=0x([0-9a-f]+)')}"
        )
        n += 1
        if n >= 20:
            break

print("\n=== first path_offset_namelen PCs (0x800136e8-0x80013820) ===")
for l in lines:
    pc = g(l, r"c0.npc=0x([0-9a-f]+)")
    if not pc:
        continue
    p = int(pc, 16)
    if 0x800136E8 <= p < 0x80013820:
        t = int(g(l, r"@([0-9a-f]+)"), 16)
        print(
            f"t={t} pc={pc} a0={g(l, r' a0=0x([0-9a-f]+)')} "
            f"a1={g(l, r' a1=0x([0-9a-f]+)')} a2={g(l, r' a2=0x([0-9a-f]+)')} "
            f"s1={g(l, r' s1=0x([0-9a-f]+)')} ra={g(l, r' ra=0x([0-9a-f]+)')}"
        )

print("\n=== platform_init window ===")
for l in lines:
    pc = g(l, r"c0.npc=0x([0-9a-f]+)")
    if pc and pc.startswith("80007"):
        t = int(g(l, r"@([0-9a-f]+)"), 16)
        print(
            f"t={t} pc={pc} a0={g(l, r' a0=0x([0-9a-f]+)')} "
            f"a1={g(l, r' a1=0x([0-9a-f]+)')} s2={g(l, r' s2=0x([0-9a-f]+)')} "
            f"ra={g(l, r' ra=0x([0-9a-f]+)')}"
        )

print("\n=== transition into permanent MEMCHR_LO (a1=64) ===")
prev = None
for l in lines:
    t_s = g(l, r"@([0-9a-f]+)")
    if not t_s:
        continue
    t = int(t_s, 16)
    a1 = g(l, r" a1=0x([0-9a-f]+)")
    ra = g(l, r" ra=0x([0-9a-f]+)")
    pc = g(l, r"c0.npc=0x([0-9a-f]+)")
    a0 = g(l, r" a0=0x([0-9a-f]+)")
    if ra == "80013788" and a1 == "64" and t >= 130000:
        if prev:
            print("prev:", prev)
        print(
            f"t={t} pc={pc} a0={a0} a1={a1} a2={g(l, r' a2=0x([0-9a-f]+)')} "
            f"s1={g(l, r' s1=0x([0-9a-f]+)')} ra={ra}"
        )
        break
    prev = f"t={t} pc={pc} a0={a0} a1={a1} ra={ra} s1={g(l, r' s1=0x([0-9a-f]+)')}"

# Count unique (ra, a1) for memchr PCs
print("\n=== memchr PC with a1/ra pairs ===")
from collections import Counter
c = Counter()
for l in lines:
    pc = g(l, r"c0.npc=0x([0-9a-f]+)")
    if not pc:
        continue
    p = int(pc, 16)
    if 0x80004BE4 <= p < 0x80004C1A:
        a1 = g(l, r" a1=0x([0-9a-f]+)")
        ra = g(l, r" ra=0x([0-9a-f]+)")
        a0 = g(l, r" a0=0x([0-9a-f]+)")
        c[(ra, a1)] += 1
for (ra, a1), n in c.most_common(15):
    print(f"  n={n:3d} ra={ra} a1={a1}")
