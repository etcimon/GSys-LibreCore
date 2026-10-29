# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Per-module worst-path table from an analyze --json-out board.
Usage: top_table.py <board.json> [--top N] [--modules a,b,c] [--out file]"""
import argparse, json, sys
ap = argparse.ArgumentParser(); ap.add_argument('board'); ap.add_argument('--top', type=int, default=40)
ap.add_argument('--modules', default=None); ap.add_argument('--out', default=None)
a = ap.parse_args()
d = json.load(open(a.board, encoding='utf-8'))
names = {m['id']: m['name'] for m in d['modules']}
best = {}
for p in d['paths']:
    n = names[p['module_id']]
    if p['total_fo4'] > best.get(n, (0,))[0]:
        best[n] = (p['total_fo4'], p['path_kind'], p['path_class'], p['primary_loc']['start_line'])
rows = sorted(best.items(), key=lambda kv: -kv[1][0])
if a.modules:
    want = a.modules.split(','); rows = [(k, best.get(k, (0.0, '-', '-', 0))) for k in want]
lines = [f"{'module':30s} {'fo4':>6s} {'kind':9s} {'class':24s} line"]
lines += [f"{k:30s} {v[0]:6.1f} {v[1]:9s} {v[2]:24s} L{v[3]}" for k, v in rows[:a.top]]
text = '\n'.join(lines)
if a.out: open(a.out, 'w', encoding='utf-8').write(text + '\n')
sys.stdout.reconfigure(encoding='utf-8', errors='replace'); print(text)
