#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Reduce tb_g6lc_ai_gemm_backend MEASURE records to a cycles-per-operation report.

    python3 ai_bench_report.py <dir-with-simulation-measure*.log> [--json out.json]

Per (format, m, n, k, ar_depth, dpf) record it derives, from the measured phase counters:

  mac_ideal   m*n*ceil(k/elems_per_step) with elems_per_step = PeLanes bytes / element
              bytes (INT4: 2*PeLanes) — the byte-lane model of the PE
  mac_eff     mac_ideal / mac_cycles (1.0 = every cycle issues one full step)
  la_per_beat, lb_per_beat   load-phase cycles per read beat delivered (1.0 = one beat/cycle)
  load_share  (la+lb)/cycles, mac_share, store_share (STC, trail stores overlap => 0)
  macs_per_cycle   useful MACs / total cycles
  bottleneck  the largest phase, or "latency" when loads dominate at >2 cycles/beat, or
              "bandwidth" when loads dominate near 1 cycle/beat

Nothing here is a live-geometry or timing claim; it is the reduced bench's own arithmetic.
"""
import argparse
import collections
import glob
import json
import math
import os
import re
import sys

ELEM_BYTES = {0: 1, 1: 0.5, 3: 1, 4: 1, 5: 2, 6: 2, 7: 4}
FMT_NAME = {0: "int8", 1: "int4", 3: "fp8e4m3", 4: "fp8e5m2", 5: "fp16", 6: "bf16", 7: "fp32"}


T0_ROWS = []


def parse_soc(root, lanes):
    """AI_JOB records from the island's +ai_pmu_trace, grouped under BENCH headers
    (verif/regress/ai-matrix-veri.sh AI_MATRIX_BENCH=1). Each job carries its bench
    point (path, reuse) and its index within the point; with a residency flag the
    point runs two passes, so jobs [0, n/2) are the cold pass and [n/2, n) the
    resident pass. BENCH_T0 lines are collected into T0_ROWS."""
    rows = []
    for path in sorted(glob.glob(os.path.join(root, "**", "ai_bench.log"), recursive=True)):
        head, pending = {}, []

        def flush():
            n = len(pending)
            for i, d in enumerate(pending):
                d["job"] = i
                d["pass"] = 1 if (int(head.get("reuse", 0)) and n > 1 and i >= n // 2) else 0
                rows.append(d)
            pending.clear()

        for line in open(path, errors="replace"):
            if line.startswith("BENCH "):
                flush()
                head = dict(kv.split("=", 1) for kv in line.split()[1:])
            elif line.startswith("BENCH_T0 "):
                d = dict(kv.split("=", 1) for kv in line.split()[1:])
                T0_ROWS.append({"op": d["op"], "iter": int(d["iter"]), "cycles": int(d["cycles"]),
                                "cycles_per_op": round(int(d["cycles"]) / int(d["iter"]), 2)})
            elif line.startswith("AI_JOB "):
                d = {k: (int(v) if re.fullmatch(r"-?\d+", v) else v) for k, v in
                     (kv.split("=", 1) for kv in line.split()[1:])}
                if d.get("status") != 0:
                    continue
                d["macs"] = d["m"] * d["n"] * d["k"]
                d["ar"] = 0
                d["dpf"] = 0
                d["lanes"] = lanes
                d["acc"] = 1 if (int(str(d["flags"]), 16) >> 10) & 3 == 1 else 0
                d["path"] = int(head.get("path", 0))
                d["reuse"] = int(head.get("reuse", 0))
                d["shape"] = f"{head.get('m', d['m'])}x{head.get('n', d['n'])}x{head.get('k', d['k'])}"
                d["kbox"] = int(head.get("kbox", 512))   # K per job (flat-panel island: whole row)
                d["source"] = os.path.relpath(path, root)
                pending.append(d)
        flush()
    return rows


def parse(root):
    rows = []
    for path in sorted(glob.glob(os.path.join(root, "**", "simulation-measure*.log"), recursive=True)):
        lanes = None
        dpf = None
        for line in open(path, errors="replace"):
            if line.startswith("MEASURE_BEGIN"):
                d = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
                lanes = int(d.get("lanes", 8))
                dpf = int(d.get("dpf", 0))
            elif line.startswith("MEASURE fmt"):
                d = {k: (int(v) if re.fullmatch(r"-?\d+", v) else v) for k, v in
                     (kv.split("=", 1) for kv in line.split()[1:])}
                d["lanes"] = lanes or 8
                d["dpf"] = dpf if dpf is not None else 0
                d["source"] = os.path.relpath(path, root)
                d.setdefault("reuse", "-")
                rows.append(d)
    return rows


def derive(d):
    lanes = d["lanes"]
    fmt = d["fmt"]
    m, n, k = d["m"], d["n"], d["k"]
    elems_per_step = int(lanes / ELEM_BYTES[fmt])
    mac_ideal = m * n * math.ceil(k / elems_per_step)
    cycles = d["cycles"]
    la, lb, mac, stc = d["la"], d["lb"], d["mac"], d["stc"]
    a_beats = m * math.ceil(k * ELEM_BYTES[fmt] / 8)
    b_beats = n * math.ceil(k * ELEM_BYTES[fmt] / 8)
    out = {
        "fmt": FMT_NAME.get(fmt, str(fmt)), "m": m, "n": n, "k": k, "ar": d["ar"], "dpf": d["dpf"],
        "cycles": cycles, "macs": d["macs"], "macs_per_cycle": round(d["macs"] / cycles, 3),
        "mac_cycles": mac, "mac_ideal": mac_ideal, "mac_eff": round(mac_ideal / mac, 3) if mac else None,
        "la": la, "lb": lb, "stc": stc,
        "la_per_beat": round(la / a_beats, 2) if a_beats else None,
        "lb_per_beat": round(lb / b_beats, 2) if b_beats else None,
        "load_share": round((la + lb) / cycles, 3), "mac_share": round(mac / cycles, 3),
        "other_share": round(max(0, cycles - la - lb - mac - stc) / cycles, 3),
        "r_beats": d["r_beats"], "w_beats": d["w_beats"],
        "stall_ar": d["stall_ar"], "stall_r": d["stall_r"], "stall_w": d["stall_w"],
    }
    load = la + lb
    if load > mac and load > stc:
        per_beat = load / max(1, a_beats + b_beats)
        out["bottleneck"] = "load-latency" if per_beat > 2.0 else "load-bandwidth"
    elif mac >= load and mac >= stc:
        out["bottleneck"] = "mac" if (out["mac_eff"] or 0) > 0.9 else "mac-underfed"
    else:
        out["bottleneck"] = "store"
    return out


def report_soc(rows, args):
    """Per bench point: total cycles of the operation (sum of its tile jobs), MAC/cycle at
    the built geometry, and for residency points the cold vs resident pass side by side."""
    import itertools
    key = lambda r: (r["fmt"], r["shape"], r["path"], r["reuse"], r.get("kbox", 512))
    points = []
    for k, grp in itertools.groupby(sorted(rows, key=key), key=key):
        grp = list(grp)
        by_pass = {p: [r for r in grp if r["pass"] == p] for p in (0, 1)}
        pt = {"fmt": k[0], "shape": k[1], "path": k[2], "reuse": k[3], "kbox": k[4], "jobs_per_pass": len(by_pass[0])}
        for p, name in ((0, "cold"), (1, "resident")):
            js = by_pass[p]
            if not js:
                continue
            cyc = sum(r["cycles"] for r in js)
            pt[name] = {"cycles": cyc, "la": sum(r["la"] for r in js), "lb": sum(r["lb"] for r in js),
                        "mac": sum(r["mac_cycles"] for r in js), "stc": sum(r["stc"] for r in js),
                        "r_beats": sum(r["r_beats"] for r in js), "w_beats": sum(r["w_beats"] for r in js),
                        "macs_per_cycle": round(sum(r["macs"] for r in js) / cyc, 2) if cyc else None,
                        "mac_eff": round(sum(r["mac_ideal"] for r in js) / sum(r["mac_cycles"] for r in js), 3)
                        if sum(r["mac_cycles"] for r in js) else None}
        if "resident" in pt:
            pt["resident_speedup"] = round(pt["cold"]["cycles"] / pt["resident"]["cycles"], 2) if pt["resident"]["cycles"] else None
        points.append(pt)
    path_name = {0: "mmio", 1: "ai.enq"}
    reuse_name = {0: "cold", 1: "reuse_a", 2: "reuse_b"}
    print(f"{'fmt':8} {'shape':>13} {'path':>6} {'resid':>7} {'kbox':>5} {'jobs':>4} | {'cycles':>8} {'MAC/cy':>7} {'mac_eff':>7} {'la':>7} {'lb':>7} {'mac':>7} | resident: cycles  lb  speedup")
    for pt in points:
        c = pt.get("cold") or {}
        res = pt.get("resident")
        tail = (f"{res['cycles']:>8} {res['lb']:>6} {pt['resident_speedup']:>6}x" if res else "")
        print(f"{pt['fmt']:8} {pt['shape']:>13} {path_name[pt['path']]:>6} {reuse_name[pt['reuse']]:>7} {pt['kbox']:>5} {pt['jobs_per_pass']:>4} | "
              f"{c.get('cycles', 0):>8} {c.get('macs_per_cycle') or 0:>7.2f} {c.get('mac_eff') or 0:>7.3f} "
              f"{c.get('la', 0):>7} {c.get('lb', 0):>7} {c.get('mac', 0):>7} | {tail}")
    if T0_ROWS:
        print("\nT0/T1 instruction bench (cycles per issued op, ITER back-to-back):")
        for t in T0_ROWS:
            print(f"  {t['op']:12} iter={t['iter']:<5} cycles={t['cycles']:<8} -> {t['cycles_per_op']} cycles/op")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"schema": "g6lc.ai-ops-bench-soc.v1", "lanes": args.lanes, "points": points, "jobs": rows,
                       "t0": T0_ROWS,
                       "evidence": "SoC model (g6lc64_ai bench SKU) per-job PMU records and rdcycle; cycles of the built island/core geometry, not silicon timing"},
                      f, indent=2)
    return 0


# Scaling ladder (architecture/ai-matrix/scaling-100tops.md; g6lc_ai_island_cfg_pkg
# AiIslandV1WidePort..V4Octo). Nameplates from the literals; tb_g6lc_ai_scale_ladder pins
# them at elaboration. Every cycle figure below is DERIVED from measured per-beat and
# per-issue costs at a smaller geometry, never a measurement of the SKU.
LADDER = [
    # name, clusters, MAC/cycle/cluster, bytes/cycle (port), GHz, memory class
    ("live", 1, 512, 8, 2.0, "class 0 sim, 64-bit"),
    ("V1 wide port", 1, 512, 64, 2.0, "class 0 sim, 512-bit channel"),
    ("V2 column array", 1, 4096, 64, 2.0, "class 0 sim, 512-bit channel"),
    ("V3 quad", 4, 4096, 64, 1.5, "class 2 nameplate 400 GB/s"),
    ("V4 octo", 8, 4096, 64, 1.5, "class 2 nameplate 400 GB/s"),
]
# Canonical archetype shapes (m, n, k, element bytes): A1 decode, A2 prefill, A3 conv im2col.
LADDER_SHAPES = [
    ("A1 decode 1x4096x4096 INT8", 1, 4096, 4096, 1),
    ("A1 decode 1x4096x4096 BF16", 1, 4096, 4096, 2),
    ("A2 prefill 512x4096x4096 INT8", 512, 4096, 4096, 1),
    ("A3 conv 4096x256x1152 INT8", 4096, 256, 1152, 1),
]


def report_sku(cy_per_beat, store_bytes_per_cycle):
    """Derived ladder: cold cycles = A+B operand beats x measured cycles/beat + MAC issue cycles
    (outputs x K steps / columns) + the C store tail (4 bytes per output at the store rate),
    with load and MAC overlapping only through the trail store (i.e. summed, an upper bound).
    Clusters split N. Resident (VA) drops the B beats. Reported per SKU as TOPS nameplate,
    balance and cycles; tok/s at batch 1 is the A1 row and is never converted to TOPS."""
    print(f"ladder (derived from cycles/beat={cy_per_beat:.3f} measured on the SoC bench SKU; store {store_bytes_per_cycle} B/cycle)")
    print(f"{'SKU':18} {'TOPS':>7} {'MAC/B':>6} | " + " | ".join(f"{n[:22]:>22}" for n, *_ in LADDER_SHAPES))
    for name, clusters, macs, bpc, ghz, mem in LADDER:
        tops = 2 * clusters * macs * ghz / 1000.0
        cols = [f"{tops:7.2f}", f"{clusters * macs // bpc:6d}"]
        cells = []
        for _, m, n, k, eb in LADDER_SHAPES:
            lanes = 512 if macs >= 512 else macs
            out_cols = max(1, macs // lanes)
            n_cl = -(-n // clusters)
            a_bytes, b_bytes = m * k * eb, n_cl * k * eb
            beats = (a_bytes + b_bytes) / bpc
            ksteps = -(-(k * eb) // lanes)
            mac = m * (-(-n_cl // out_cols)) * ksteps
            store = m * n_cl * 4 / min(bpc, store_bytes_per_cycle)
            cold = beats * cy_per_beat + mac + store
            resident = (a_bytes / bpc) * cy_per_beat + mac + store
            us = cold / (ghz * 1000.0)
            cells.append(f"{int(cold):>10d}/{int(resident):>8d} {us:6.1f}us")
        print(f"{name:18} {cols[0]} {cols[1]} | " + " | ".join(f"{c:>22}" for c in cells))
    print("cells: cold/resident cycles, cold wall time at the SKU clock; A1 rows are the batch-1 regime "
          "(bytes-bound: only bytes/cycle moves them); derived, not measured; class-2 memory is a nameplate.")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=None)
    ap.add_argument("--json")
    ap.add_argument("--soc", action="store_true", help="read AI_JOB records from ai_bench.log (SoC bench)")
    ap.add_argument("--lanes", type=int, default=512, help="PE lanes of the SoC model (live 512)")
    ap.add_argument("--sku", action="store_true", help="derived scaling-ladder table (no records needed)")
    ap.add_argument("--cy-per-beat", type=float, default=1.005, help="measured B-stream cycles/beat (SoC bench SKU: 1.002-1.008)")
    ap.add_argument("--store-bpc", type=int, default=8, help="C store bytes/cycle (8-byte pairs today)")
    args = ap.parse_args()
    if args.sku:
        return report_sku(args.cy_per_beat, args.store_bpc)
    if not args.root:
        ap.error("root is required unless --sku")
    raw = parse_soc(args.root, args.lanes) if args.soc else parse(args.root)
    extra = ("acc", "path", "reuse", "pass", "job", "shape", "hit_b", "hit_a")
    rows = [dict(derive(d), **{k: d[k] for k in extra if k in d}) for d in raw]
    if not rows and not T0_ROWS:
        print("no MEASURE records under", args.root, file=sys.stderr)
        return 1
    if args.soc:
        return report_soc(rows, args)
    # Dedupe identical (fmt, m, n, k, ar, dpf) across files: keep the first.
    seen = {}
    for r in rows:
        seen.setdefault((r["fmt"], r["m"], r["n"], r["k"], r["ar"], r["dpf"], r.get("acc", 0), r.get("reuse", "-")), r)
    rows = list(seen.values())
    print(f"{'fmt':8} {'m':>3} {'n':>3} {'k':>3} ar dpf {'reuse':>5} | {'cycles':>6} {'MAC/cy':>6} {'mac_eff':>7} "
          f"{'la/beat':>7} {'lb/beat':>7} {'load%':>5} {'mac%':>5} | bottleneck")
    for r in sorted(rows, key=lambda r: (r["fmt"], r["m"], r["n"], r["k"], r["ar"], r["dpf"], str(r.get("reuse", "-")))):
        print(f"{r['fmt']:8} {r['m']:>3} {r['n']:>3} {r['k']:>3} {r['ar']:>2} {r['dpf']:>3} {str(r.get('reuse', '-')):>5} | {r['cycles']:>6} "
              f"{r['macs_per_cycle']:>6.2f} {r['mac_eff'] or 0:>7.3f} {r['la_per_beat'] or 0:>7.2f} "
              f"{r['lb_per_beat'] or 0:>7.2f} {100*r['load_share']:>4.0f}% {100*r['mac_share']:>4.0f}% | {r['bottleneck']}")
    # Per-format summary at the deepest AR and each dpf: best MAC/cycle and the phase mix.
    summary = collections.defaultdict(dict)
    for r in rows:
        key = (r["fmt"], r["dpf"])
        best = summary[key].get("best")
        if best is None or r["macs_per_cycle"] > best["macs_per_cycle"]:
            summary[key]["best"] = r
    print("\nper format (best MAC/cycle record): fmt dpf -> MAC/cycle @ shape, mac_eff, bottleneck")
    for (fmt, dpf), s in sorted(summary.items()):
        b = s["best"]
        print(f"  {fmt:8} dpf={dpf} -> {b['macs_per_cycle']:5.2f} @ {b['m']}x{b['n']}x{b['k']} ar{b['ar']} "
              f"mac_eff={b['mac_eff']} {b['bottleneck']}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"schema": "g6lc.ai-ops-bench.v1", "records": rows, "lanes": args.lanes, "soc": args.soc,
                       "evidence": ("SoC model (g6lc64_ai) per-job PMU records; cycles of the built island geometry, not silicon timing"
                                    if args.soc else
                                    "reduced 8-lane backend bench on the simulated stripe; sequencer behaviour, not live geometry or timing")},
                      f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
