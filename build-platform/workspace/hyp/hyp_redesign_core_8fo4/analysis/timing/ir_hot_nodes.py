# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Hot-node census of an sv-timing --ir-out dump: per module, the highest
fo4_cost nodes with locus, lhs, op class and rhs text."""
import argparse, json, sys
ap = argparse.ArgumentParser(); ap.add_argument('ir'); ap.add_argument('--top', type=int, default=20)
ap.add_argument('--module', default=None); ap.add_argument('--min', type=float, default=5.0)
a = ap.parse_args(); sys.stdout.reconfigure(encoding='utf-8', errors='replace')
ir = json.load(open(a.ir, encoding='utf-8'))
for k, m in ir['modules'].items():
    if a.module and m['name'] != a.module: continue
    nodes = m['nodes']
    if isinstance(nodes, dict): nodes = list(nodes.values())
    ns = sorted(nodes, key=lambda n: -(n.get('fo4_cost') or 0))
    print(f"== {m['name']} nodes={len(nodes)} launch_fo4={m.get('launch_fo4')}")
    for n in ns[:a.top]:
        if (n.get('fo4_cost') or 0) < a.min: break
        loc = n.get('loc') or {}
        print(f"  {n['fo4_cost']:7.1f} L{loc.get('start_line'):<5} w={n.get('width'):<4} {n.get('op_class'):10s} {str(n.get('lhs'))[:34]:34s} <= {str(n.get('rhs'))[:110]}")
