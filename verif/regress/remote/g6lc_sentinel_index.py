#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline NBA schedule index. Inputs: seq/pred JSON and stamp-LANE.txt captures.

Optional full_pred: complete compiler DAG (including intra-lane dependencies).
Optional idioms: list of {task, operation, layout, evidence} source observations.
Produces JSON; no model edits, executable dispatch or live scheduling.
"""
import argparse
from collections import Counter, defaultdict
from graphlib import CycleError, TopologicalSorter
import hashlib
import json
from pathlib import Path

from g6lc_sentinel_dataflow import dataflow_index


def schedule_input(raw):
    if "schema" not in raw:
        return raw  # Legacy emitted-wait capture, e.g. attrib.json.
    if raw["schema"] != "v3-sentinel-1":
        raise ValueError("unknown compiler sentinel schema")
    lanes, waits, full = defaultdict(list), {}, {}
    for task in raw["tasks"]:
        t = task["id"]
        if t in waits or not set(task["waits"]) <= set(task["deps"]):
            raise ValueError("duplicate task or non-dependency wait")
        lanes[str(task["lane"])].append(t)
        waits[str(t)], full[str(t)] = task["waits"], task["deps"]
    # The emitted graph (including serial lane order) must imply every
    # compiler dependency. Otherwise observed timestamps are not enough.
    deps = {int(t): ps for t, ps in waits.items()}
    previous, order = compile_plan(lanes, deps)
    ancestors = {}
    for t in order:
        ps = set(deps[t])
        if previous[t] is not None:
            ps.add(previous[t])
        ancestors[t] = ps.union(*(ancestors[p] for p in ps))
        if not set(full[str(t)]) <= ancestors[t]:
            raise ValueError(f"uncovered compiler dependency at task {t}")
    return dict(seq=dict(lanes), pred=waits, full_pred=full, idioms=raw.get("idioms", []))


def compile_plan(lanes, deps):
    previous = {t: p for lane in lanes.values() for p, t in zip([None, *lane], lane)}
    if len(previous) != sum(map(len, lanes.values())) or set(previous) != set(deps):
        raise ValueError("duplicate task or schedule/dependency task set mismatch")
    graph = {}
    for t, pred in deps.items():
        if set(pred) - previous.keys():
            raise ValueError(f"unknown predecessor of {t}")
        graph[t] = set(pred)
        if previous[t] is not None:
            graph[t].add(previous[t])
    return previous, tuple(TopologicalSorter(graph).static_order())


def read_rounds(directory, lanes):
    rounds = defaultdict(dict)
    files = {f.stem.removeprefix("stamp-"): f for f in directory.glob("stamp-*.txt")}
    if set(files) != set(lanes):
        raise ValueError("stamp files do not match schedule lanes")
    for lane, f in files.items():
        allowed = set(lanes[lane])
        for line in f.read_text().splitlines():
            seq, t, arrival, begin, end = map(int, line.split())
            if t not in allowed or t in rounds[seq] or not 0 <= arrival <= begin <= end:
                raise ValueError(f"inconsistent stamp: {f}: {line}")
            rounds[seq][t] = arrival, begin, end
    return rounds


def decompose(stamps, deps, plan):
    previous, order = plan
    if set(stamps) != set(order):
        raise ValueError("incomplete round")
    first = min(a for a, _, _ in stamps.values())
    work, late = {}, []
    for t in order:
        a, b, e = stamps[t]
        p = previous[t]
        gap = a - (stamps[p][2] if p is not None else first)
        last = max((stamps[x][2] for x in deps[t]), default=a)
        tail = b - max(a, last)
        if min(gap, tail) < 0:
            raise ValueError(f"timestamps contradict precedence at task {t}")
        work[t] = gap, tail, e - b
        if last > a:
            # Tied latest producers form one event: never double-charge it.
            blocking = tuple(sorted(x for x in deps[t] if stamps[x][2] == last))
            body = last - max(a, max(stamps[x][1] for x in blocking))
            late.append((blocking, t, body, last - a - body))
    return work, late, max(e for _, _, e in stamps.values()) - first


def replay(work, deps, plan, faster=None, gap_from=None, body_scale=None):
    previous, order = plan
    ends = {}
    for t in order:
        _, tail, body = work[t]
        # Preserve launch/inter-task overhead at its lane position, even
        # when a hypothetical swap changes which body occupies that slot.
        gap = work[gap_from.get(t, t) if gap_from else t][0]
        ready = ends.get(previous[t], 0) + gap
        for p in deps[t]:
            ready = max(ready, ends[p])
        scale = body_scale.get(t, 1) if body_scale is not None else (0.5 if t == faster else 1)
        ends[t] = ready + tail + body * scale
    return max(ends.values())


def scenario(schedule, capture, scales):
    """A fixed-schedule counterfactual; scale only payloads, jointly, per round."""
    deps = {int(t): ps for t, ps in schedule["pred"].items()}
    if (not capture or not scales or scales.keys() - deps.keys()
            or not all(0 <= x <= 1 for x in scales.values())):
        raise ValueError("expected known task(s), retained body fractions in [0,1], and stamps")
    plan = compile_plan(schedule["seq"], deps)
    total = projected = 0
    for stamps in capture.values():
        work, _, span = decompose(stamps, deps, plan)
        if span <= 0 or replay(work, deps, plan) != span:
            raise ValueError("baseline replay mismatch")
        projected += replay(work, deps, plan, body_scale=scales)
        total += span
    return dict(rounds=len(capture), measured_span_ns=total, projected_span_ns=projected,
                span_reduction_pct=100 * (total-projected) / total)


# Keys are structural assertions from a source adapter, not guesses from names.
PROBES = {
    ("bit_select_concat", "one_word"): ("BMI2 PEXT", "ascending source bits; constant extract mask"),
    ("bit_select_concat", "contiguous_bytes"): ("AVX512BW byte mask", "64 valid bytes; same bit plane"),
    ("bit_select_concat", "strided_words"): ("batched transpose", "common addresses and unchanged input epoch"),
    ("masked_or", "packed_rows"): ("set-bit iteration + row OR", "preserve zero and multiple enables"),
}


def index(schedule, captures):
    lanes = schedule["seq"]
    waits = {int(t): tuple(ps) for t, ps in schedule["pred"].items()}
    plan = compile_plan(lanes, waits)
    full = schedule.get("full_pred")
    legal = {}
    if full is not None:
        if {int(t) for t in full} != set(waits):
            raise ValueError("incomplete full_pred task set")
        legal = {t: set(full[str(t)]) | set(waits[t]) for t in waits}
        compile_plan(lanes, legal)
    if not captures or any(not rounds for rounds in captures):
        raise ValueError("empty capture")
    rounds, baseline, edges, bodies = [], [], defaultdict(Counter), Counter()
    for capture in captures:
        for _, stamps in sorted(capture.items()):
            work, late, span = decompose(stamps, waits, plan)
            if span <= 0 or replay(work, waits, plan) != span:
                raise ValueError("baseline replay mismatch")
            if full is not None and any(stamps[p][2] > stamps[t][1]
                                        for t in legal for p in legal[t]):
                raise ValueError("full DAG contradicts observed task start")
            if full is not None:
                # Under the full DAG, time previously attributed to the
                # post-wait residual may instead be a semantic predecessor.
                work_full, _, _ = decompose(stamps, legal, plan)
            else:
                work_full = work
            rounds.append((work, work_full))
            baseline.append(span)
            for t, (_, _, body) in work.items():
                bodies[t] += body
            for blocking, t, overlap, prefix in late:
                edges[blocking, t].update(body_ns=overlap, prefix_ns=prefix, count=1)
    total = sum(baseline)
    ranks = []
    for t in waits:
        saving = total - sum(replay(r, waits, plan, t) for r, _ in rounds)
        ranks.append(dict(task=t, body_ns=bodies[t], half_body_span_gain_pct=100 * saving / total))
    ranked = sorted(ranks, key=lambda r: (-r["half_body_span_gain_pct"], r["task"]))
    reorder = {"status": "blocked: emitted waits omit same-lane dependencies"}
    if full is not None and len(captures) < 2:
        reorder = {"status": "blocked: independent holdout capture required"}
    elif full is not None:
        # Select on the first capture only. Keep lane assignment, all semantic
        # dependencies and emitted waits. Predict only one adjacent swap.
        split = len(captures[0])
        best = 0
        reorder = {"status": "no beneficial legal adjacent swap on training capture"}
        for lane, seq in lanes.items():
            for i in range(len(seq) - 1):
                alt = seq[:i] + [seq[i+1], seq[i]] + seq[i+2:]
                try:
                    candidate = compile_plan({**lanes, lane: alt}, legal)
                except CycleError:
                    continue
                gap_from = {seq[i]: seq[i+1], seq[i+1]: seq[i]}
                gain = sum(baseline[:split]) - sum(
                    replay(r, legal, candidate, gap_from=gap_from) for _, r in rounds[:split])
                if gain > best:
                    best = gain
                    held = sum(baseline[split:])
                    delta = held - sum(replay(r, legal, candidate, gap_from=gap_from)
                                       for _, r in rounds[split:])
                    reorder = dict(status="prediction only", lane=lane, swap=seq[i:i+2],
                                   train_gain_pct=100 * gain / sum(baseline[:split]),
                                   holdout_gain_pct=100 * delta / held)
    probes = []
    for row in schedule.get("idioms", []):
        if row["task"] not in waits or not row["evidence"]:
            raise ValueError("idiom needs a known task and source evidence")
        probe = PROBES.get((row["operation"], row["layout"]))
        probes.append({**row, "probe": probe[0] if probe else None,
                       "guard": probe[1] if probe else None})
    return dict(schema=1, rounds=len(rounds), span_ns=total, tasks=ranked,
                blockers=[dict(producers=ps, consumer=t, **v) for (ps, t), v in
                          sorted(edges.items(), key=lambda item: -(
                              item[1]["body_ns"] + item[1]["prefix_ns"]))],
                reorder=reorder, intrinsic_probes=probes)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshot", type=Path, help="compiler DFG, schedule, or legacy seq/pred JSON")
    ap.add_argument("captures", nargs="*", type=Path, help="stamp directories (schedule only)")
    ap.add_argument("--write-controls", type=Path, metavar="NEW.f",
                    help="write an opt-in Verilator response file for a DFG experiment")
    ap.add_argument("--retain-body", action="append", default=[], metavar="TASK=FRACTION",
                    help="joint fixed-schedule scenario, reported separately per capture")
    args = ap.parse_args()
    if len(set(p.resolve() for p in args.captures)) != len(args.captures):
        ap.error("duplicate capture")
    raw = args.snapshot.read_bytes()
    source = json.loads(raw)
    if source.get("schema") == "v3-sentinel-dfg-1":
        if args.retain_body:
            ap.error("body timing scenarios require a schedule")
        if args.captures:
            ap.error("DFG IDs are not task IDs; do not join DFG and stamps by number")
        result = dataflow_index(source)
        result["source_sha256"] = hashlib.sha256(raw).hexdigest()
        sites = [r["vertex"] for r in result["regions"] if r.get("pack_byte_plane")]
        flag = ("-fdfg-peephole-" if sites else "-fno-dfg-peephole-") + "pack-byte-plane"
        result["control"] = dict(scope="build", flag=flag, candidate_vertices=sites)
        if args.write_controls:
            with args.write_controls.open("x") as stream:
                stream.write(flag + "\n")
        print(json.dumps(result, indent=2))
        return
    if args.write_controls:
        ap.error("control files are supported for DFG snapshots only")
    schedule = schedule_input(source)
    captures = [read_rounds(p, schedule["seq"]) for p in args.captures]
    result = index(schedule, captures)
    if args.retain_body:
        scales = {}
        for spec in args.retain_body:
            try:
                key, val = spec.split("=")
                t, x = int(key), float(val)
            except ValueError:
                ap.error("expected TASK=FRACTION")
            if t in scales:
                ap.error("duplicate task in scenario")
            scales[t] = x
        result["scenario"] = dict(retained_body=scales, by_capture=[
            dict(capture=str(p), **scenario(schedule, c, scales))
            for p, c in zip(args.captures, captures)])
    result.update(schedule_sha256=hashlib.sha256(raw).hexdigest(),
                  captures=[str(p) for p in args.captures])
    if "schema" in source:
        result.update(region=source["region"], compiler_tasks=source["tasks"])
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
