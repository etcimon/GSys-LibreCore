# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bisecting window extractor for a hyp8 witness: RVFI records and printer
lines whose cycle stamp lies in [lo, hi]. Read-only on the run directory.
usage: win.py <tag> <lo> <hi> [max_lines]"""
import os, re, sys
tag, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
cap = int(sys.argv[4]) if len(sys.argv) > 4 else 400
run = f'/opt/testharness/runs/{tag}/output'

def bisect(path, pat, target):
    """Byte offset of (roughly) the first line stamped >= target."""
    size = os.path.getsize(path)
    a, b = 0, size
    with open(path, 'rb') as f:
        while b - a > 1 << 16:
            mid = (a + b) // 2
            f.seek(mid); f.readline()
            stamp = None
            for _ in range(4000):
                line = f.readline()
                if not line:
                    break
                m = pat.search(line)
                if m:
                    stamp = int(m.group(1)); break
            if stamp is None or stamp >= target:
                b = mid
            else:
                a = mid
    return a

def dump(name, pat, skip=()):
    path = f'{run}/{name}'
    off = bisect(path, pat, lo)
    n = 0
    print(f'== {name} [{lo},{hi}] from byte {off}')
    with open(path, 'rb') as f:
        f.seek(off); f.readline()
        inside = False
        for line in f:
            m = pat.search(line)
            if m:
                c = int(m.group(1))
                if c > hi:
                    break
                inside = c >= lo
            if inside and not line.startswith(skip):
                sys.stdout.write(line.decode('utf-8', 'replace')[:260].rstrip('\n') + '\n')
                n += 1
                if n >= cap:
                    print('...cap'); break

dump('trace_rvfi_hart_00.dasm', re.compile(rb'@(\d+)\s*$'))
dump('run-hyp8.log', re.compile(rb'(?:^\[|t=|cyc=)(\d{5,})'), skip=(b'[l1 dcache',))
