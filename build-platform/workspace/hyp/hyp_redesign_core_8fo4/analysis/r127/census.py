# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Read-only census over an sv-timing board (--json-out) and its IR (--ir-out).

  census.py top   <board.json> [--live live-modules.txt] [--n 70] [--all]
  census.py path  <board.json> <ir.json> <module> [--k 3] [--min 2.0] [--kind K]
  census.py cross <board.json> [--live live-modules.txt] [--n 30]
  census.py reloc <board.json> <module> [--n 12]
  census.py hot   <ir.json> <module> [--n 25] [--min 5.0]

`top` prints, per module, the worst single-cycle path of any kind and the
per-kind maxima (rr = reg->reg, the clock rule; ir/ro/io = presentation).
A module is `live` when the elaborated hierarchy (elab_hierarchy.sh) holds at
least one cell of it; rows of other modules are board floor, not clock.
"""
import argparse
import json
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
KIND = {"regtoreg": "rr", "intoreg": "ir", "regtoout": "ro", "intoout": "io",
        "reg_to_reg": "rr", "in_to_reg": "ir", "reg_to_out": "ro", "in_to_out": "io"}


def load(p):
    return json.load(open(p, encoding="utf-8"))


def live_set(p):
    if not p:
        return None
    return {l.split()[0] for l in open(p, encoding="utf-8") if l.strip()}


def names(d):
    m = d["modules"]
    if isinstance(m, dict):
        return {v["id"]: v["name"] for v in m.values()}
    return {x["id"]: x["name"] for x in m}


def per_module(d):
    nm = names(d)
    out = {}
    for p in d["paths"]:
        if p.get("multi_cycle"):
            continue
        n = nm[p.get("module_id", p.get("module"))]
        k = KIND.get(p["path_kind"], p["path_kind"])
        e = out.setdefault(n, {})
        if p["total_fo4"] > e.get(k, (0,))[0]:
            e[k] = (p["total_fo4"], p["path_class"], p["primary_loc"]["start_line"],
                    p.get("path_id", p.get("id")))
    return out


def cmd_top(a):
    d = load(a.board)
    live = live_set(a.live)
    t = per_module(d)
    rows = []
    for n, e in t.items():
        if not e:
            continue
        k, v = max(e.items(), key=lambda kv: kv[1][0])
        rows.append((v[0], n, k, v, e))
    rows.sort(reverse=True)
    fc = d["frequency_closure"]
    print(f"# {d['versions']['measurement']} budget={d['budget_fo4']} fo4_ps={d['fo4_ps']} "
          f"modules={len(t)} board-worst={fc['worst_path_fo4']:.1f} ({fc['worst_path_kind']})")
    print(f"{'module':28s} {'live':4s} {'any':>6s} k  {'class':22s} {'line':>6s} | "
          f"{'rr':>5s} {'ir':>5s} {'ro':>5s} {'io':>5s}")
    shown = 0
    for w, n, k, v, e in rows:
        is_live = live is None or n in live
        if not a.all and live is not None and not is_live:
            continue
        g = lambda x: f"{e[x][0]:5.1f}" if x in e else "    -"
        print(f"{n:28s} {'Y' if is_live else '-':4s} {w:6.1f} {k} {v[1]:22s} L{v[2]:<5d} | "
              f"{g('rr')} {g('ir')} {g('ro')} {g('io')}")
        shown += 1
        if shown >= a.n:
            break
    if live is not None:
        rr = sorted(((e["rr"][0], n, e["rr"][2]) for n, e in t.items()
                     if "rr" in e and n in live), reverse=True)
        print("\n# clock rule (live reg->reg): " +
              ", ".join(f"{n} {v:.1f} L{l}" for v, n, l in rr[:14]))
        dead = sorted(((max(x[0] for x in e.values()), n) for n, e in t.items()
                       if e and n not in live), reverse=True)
        print("# not elaborated (board floor): " +
              ", ".join(f"{n} {v:.1f}" for v, n in dead[:24]))


def cmd_path(a):
    d = load(a.board)
    ir = load(a.ir)
    nm = names(d)
    mid = [i for i, n in nm.items() if n == a.module]
    if not mid:
        raise SystemExit("no such module on the board")
    irm = next(m for m in ir["modules"].values() if m["name"] == a.module)
    nodes = irm["nodes"]
    nodes = nodes if isinstance(nodes, dict) else {str(n["id"]): n for n in nodes}
    irp = {p.get("id", p.get("path_id")): p for p in ir["paths"]}
    ps = [p for p in d["paths"] if p["module_id"] == mid[0] and not p.get("multi_cycle")]
    if a.kind:
        ps = [p for p in ps if KIND.get(p["path_kind"], p["path_kind"]) == a.kind]
    ps.sort(key=lambda p: -p["total_fo4"])
    seen = set()
    shown = 0
    for p in ps:
        key = (p["primary_loc"]["start_line"], p["path_kind"], round(p["total_fo4"], 1))
        if key in seen:
            continue
        seen.add(key)
        raw = p.get('total_fo4_raw')
        print(f"--- path {p['path_id']} {p['total_fo4']:.1f} FO4 (raw {raw if raw is None else round(raw, 1)}) "
              f"{KIND.get(p['path_kind'], p['path_kind'])} {p['path_class']} "
              f"L{p['primary_loc']['start_line']} nodes={p['node_count']} "
              f"stage {p.get('stage_start')}->{p.get('stage_end')}")
        print(f"    {p['startpoint']} -> {p['endpoint']}")
        note = p.get("class_note") or ""
        for i in range(0, len(note), 150):
            print("    | " + note[i:i + 150])
        ip = irp.get(p["path_id"]) or {}
        for nid in ip.get("nodes") or []:
            n = nodes.get(str(nid)) or nodes.get(nid) or {}
            c = n.get("fo4_cost") or 0
            if c < a.min:
                continue
            rhs = re.sub(r"\s+", " ", str(n.get("rhs")))[:120]
            print(f"    L{(n.get('loc') or {}).get('start_line'):<5} {c:6.1f} "
                  f"{str(n.get('op_class')):9s} w={str(n.get('width')):<4} "
                  f"{str(n.get('lhs'))[:30]:30s} <= {rhs}")
        shown += 1
        if shown >= a.k:
            break


def cmd_cross(a):
    d = load(a.board)
    live = live_set(a.live)
    xs = sorted(d.get("cross_module_paths") or [], key=lambda x: -x["total_fo4"])
    shown = 0
    for x in xs:
        if live is not None and (x["parent_module"] not in live or x["child_module"] not in live):
            continue
        print(f"{x['total_fo4']:6.1f} {x['parent_module']}.{x['instance_name']}:{x['child_module']} "
              f"{x['stitch_kind']} via {','.join(x.get('via_ports') or [])[:60]}")
        print(f"        {x['rationale'][:170]}")
        shown += 1
        if shown >= a.n:
            break


def cmd_reloc(a):
    d = load(a.board)
    rp = d.get("relocation_plan") or {}
    cards = rp.get("cards") if isinstance(rp, dict) else rp
    nm = names(d)
    mid = {i for i, n in nm.items() if n == a.module}
    pid = {p["path_id"] for p in d["paths"] if p["module_id"] in mid}
    shown = 0
    for c in cards or []:
        if c.get("path_id") in pid or c.get("module") == a.module:
            print(json.dumps(c)[:700])
            shown += 1
            if shown >= a.n:
                break
    ops = {}
    for o in d.get("opportunities") or []:
        if o.get("path_id") in pid:
            ops[o["kind"]] = ops.get(o["kind"], 0) + 1
    print("opportunities by kind:", ops)
    sp = d.get("structural_patterns") or []
    for s in sp:
        if a.module in json.dumps(s):
            print("pattern:", json.dumps(s)[:400])


def cmd_hot(a):
    ir = load(a.ir)
    m = next(m for m in ir["modules"].values() if m["name"] == a.module)
    ns = m["nodes"]
    ns = list(ns.values()) if isinstance(ns, dict) else ns
    ns.sort(key=lambda n: -(n.get("fo4_cost") or 0))
    for n in ns[:a.n]:
        if (n.get("fo4_cost") or 0) < a.min:
            break
        rhs = re.sub(r"\s+", " ", str(n.get("rhs")))[:120]
        print(f"L{(n.get('loc') or {}).get('start_line'):<5} {n['fo4_cost']:6.1f} "
              f"{str(n.get('op_class')):9s} w={str(n.get('width')):<4} "
              f"{str(n.get('lhs'))[:30]:30s} <= {rhs}")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("top"); p.add_argument("board"); p.add_argument("--live")
    p.add_argument("--n", type=int, default=70); p.add_argument("--all", action="store_true")
    p = sp.add_parser("path"); p.add_argument("board"); p.add_argument("ir"); p.add_argument("module")
    p.add_argument("--k", type=int, default=3); p.add_argument("--min", type=float, default=2.0)
    p.add_argument("--kind")
    p = sp.add_parser("cross"); p.add_argument("board"); p.add_argument("--live")
    p.add_argument("--n", type=int, default=30)
    p = sp.add_parser("reloc"); p.add_argument("board"); p.add_argument("module")
    p.add_argument("--n", type=int, default=12)
    p = sp.add_parser("hot"); p.add_argument("ir"); p.add_argument("module")
    p.add_argument("--n", type=int, default=25); p.add_argument("--min", type=float, default=5.0)
    a = ap.parse_args()
    {"top": cmd_top, "path": cmd_path, "cross": cmd_cross, "reloc": cmd_reloc,
     "hot": cmd_hot}[a.cmd](a)


if __name__ == "__main__":
    main()
