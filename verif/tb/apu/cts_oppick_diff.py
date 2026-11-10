#!/usr/bin/env python3
"""Diff a deqp-vk OPPICK stderr log against the Python FSM reproduction.

Usage:
    python3 cts_oppick_diff.py <deqp-stderr.log> [--hc <0|1>] [--usage <mask>]

Parses "OPPICK-SEED <seed>" blocks and "OPPICK <where> stage=N chosen=N
avail=[...]" lines emitted by the instrumented vktMemoryPipelineBarrierTests.cpp,
then regenerates the same pick stream with cts_barrier_repro.gen_tree_seed and
reports per-seed match / first-divergence.
"""
import re
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cts_barrier_repro as R

OPPICK_RE = re.compile(
    r"^OPPICK (\S+) stage=(\d+) chosen=(\d+) avail=\[([^\]]*)\]\s*$")
SEED_RE = re.compile(r"^OPPICK-SEED (\d+)\s*$")


def parse_cpp_log(path):
    """Return ordered list of (seed, [(where,stage,chosen,avail_tuple),...])."""
    blocks = []
    seed = None
    cur = None
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = SEED_RE.match(line)
            if m:
                seed = int(m.group(1))
                cur = []
                blocks.append((seed, cur))
                continue
            m = OPPICK_RE.match(line)
            if m and cur is not None:
                avail = tuple(int(x) for x in m.group(4).split(",") if x != "")
                cur.append((m.group(1), int(m.group(2)), int(m.group(3)), avail))
    return blocks


def py_oppicks(seed, hc, usage, opCount=50):
    """Run the FSM and return [(where,stage,chosen,avail_tuple),...]."""
    R.OPPICKS = []
    R.gen_tree_seed(seed, usage, hc, opCount)
    return [(w, s, c, a) for (w, s, c, a) in R.OPPICKS]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    logpath = sys.argv[1]
    hc = None
    usage = R.USAGE_ALL_DEVICE
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--hc" and i + 1 < len(args):
            hc = bool(int(args[i + 1])); i += 2
        elif args[i] == "--usage" and i + 1 < len(args):
            usage = int(args[i + 1], 0); i += 2
        else:
            i += 1

    blocks = parse_cpp_log(logpath)
    print("parsed %d seed-block(s) from %s" % (len(blocks), logpath))
    if not blocks:
        print("no OPPICK data found")
        return 1

    allmatch = True
    for seed, cpp_picks in blocks:
        # try requested hc, else both
        hcs = [hc] if hc is not None else [False, True]
        best = None
        for h in hcs:
            py = py_oppicks(seed, h, usage)
            # compare
            n = min(len(py), len(cpp_picks))
            div = None
            for k in range(n):
                if py[k] != cpp_picks[k]:
                    div = k
                    break
            if div is None and len(py) == len(cpp_picks):
                best = (h, True, -1, len(py))
                break
            if div is not None and (best is None or div > best[2]):
                best = (h, False, div, len(py))
        h, ok, div, npy = best
        status = "MATCH" if ok else "DIFF@pick%d" % div
        print("seed=%u hc=%s cpp=%d py=%d -> %s" %
              (seed, h, len(cpp_picks), npy, status))
        if not ok:
            allmatch = False
            k = div
            print("   first divergence at pick %d:" % k)
            if k < len(cpp_picks):
                print("     cpp: %r" % (cpp_picks[k],))
            if k < npy:
                print("     py : %r" % (py_oppicks(seed, h, usage)[k],))
            # show a few surrounding picks for context
            for j in range(max(0, k - 2), min(len(cpp_picks), k + 3)):
                print("     cpp[%d] %r" % (j, cpp_picks[j]))
            py = py_oppicks(seed, h, usage)
            for j in range(max(0, k - 2), min(len(py), k + 3)):
                print("     py [%d] %r" % (j, py[j]))
    print("RESULT:", "ALL MATCH" if allmatch else "MISMATCH")
    return 0 if allmatch else 1


if __name__ == "__main__":
    sys.exit(main())
