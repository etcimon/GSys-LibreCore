# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Dump sv-timing paths from an --ir-out JSON (carries per-path node lists)
or an analyze --json-out board (path summaries only).

Usage:
  path_dump.py <ir.json|board.json> [--module NAME] [--path-id N] [--top K]
"""
import argparse, json, sys
ap = argparse.ArgumentParser()
ap.add_argument('json')
ap.add_argument('--module', default=None)
ap.add_argument('--path-id', type=int, default=None)
ap.add_argument('--top', type=int, default=3)
a = ap.parse_args()
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
ir = json.load(open(a.json, encoding='utf-8'))

# modules may be a dict keyed by id or a list
mods = ir.get('modules', {})
if isinstance(mods, dict):
    mod_by_id = {int(k): v for k, v in mods.items() if str(k).lstrip('-').isdigit()}
    if not mod_by_id:
        mod_by_id = {i: v for i, v in enumerate(mods.values())}
else:
    mod_by_id = {m.get('id', i): m for i, m in enumerate(mods)}

def nodes_of(m):
    ns = m.get('nodes', {})
    return ns if isinstance(ns, dict) else {n.get('id'): n for n in ns}

# --ir-out paths use `module`/`id`; board JSONs use `module_id`/`path_id`.
paths = [p for p in ir.get('paths', [])
         if p.get('total_fo4') is not None]
for p in paths:
    p.setdefault('module_id', p.get('module'))
    p.setdefault('path_id', p.get('id'))
if a.path_id is not None:
    paths = [p for p in paths if p.get('path_id') == a.path_id]
if a.module:
    mids = {i for i, m in mod_by_id.items() if m.get('name') == a.module}
    paths = [p for p in paths if p.get('module_id') in mids]
paths.sort(key=lambda p: -(p.get('total_fo4') or 0))

for p in paths[:a.top]:
    m = mod_by_id.get(p.get('module_id'), {})
    print(f"path_id={p.get('path_id')} fo4={p.get('total_fo4'):.1f} "
          f"{p.get('path_kind')} class={p.get('path_class')} "
          f"{p.get('startpoint')} -> {p.get('endpoint')}")
    loc = p.get('primary_loc') or {}
    print(f"  L{loc.get('start_line')} {loc.get('file','').split('/')[-1]}")
    note = (p.get('class_note') or '')
    if note:
        print(f"  note: {note[:160]}")
    nmap = nodes_of(m)
    for nid in (p.get('nodes') or []):
        n = nmap.get(nid) or nmap.get(str(nid)) or {}
        l = n.get('loc') or {}
        print(f"  n{nid} L{l.get('start_line'):<5} fo4={n.get('fo4_cost',0):5.1f} "
              f"{str(n.get('lhs'))[:30]:30s} <= {str(n.get('rhs'))[:90]}")
    if not p.get('nodes'):
        print('  (no node list — board JSONs strip nodes; use --ir-out dump)')
