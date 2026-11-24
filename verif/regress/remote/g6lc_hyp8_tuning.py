#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Prepare an isolated native make overlay; never edit Verilator's emitted sources."""
import argparse
from collections import Counter
import concurrent.futures
from fnmatch import fnmatchcase
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

from g6lc_pack_age_compare import lower_age_compare
from g6lc_pack_assert_cone import compute_assert_only_vars, lower_assert_cone
from g6lc_pack_assert_guard import lower_assert_guard
from g6lc_pack_bit_columns import lower_bit_columns
from g6lc_pack_columns import lower_columns
from g6lc_pack_generated_rows import lower, lower_mux_rows
from g6lc_pack_predicates import lower as lower_predicates
from g6lc_pack_scatter_mask import lower_scatter_mask
from g6lc_pack_wide_mux import lower_wide_mux
from g6lc_pack_wrapped_columns import lower_wrapped
from g6lc_sentinel_dataflow import dataflow_index
from g6lc_tuning_policy import PASSES, class_rules, select_policy


OUTPUT = "hyp8-packed-tiled"
PREFIX = "Vg6lc_testharness"
TOOLS = (
    "g6lc_hyp8_tuning.py",
    "g6lc_pack_columns.py",
    "g6lc_pack_bit_columns.py",
    "g6lc_pack_age_compare.py",
    "g6lc_pack_assert_cone.py",
    "g6lc_pack_assert_guard.py",
    "g6lc_pack_scatter_mask.py",
    "g6lc_pack_wide_mux.py",
    "g6lc_pack_generated_rows.py",
    "g6lc_pack_predicates.py",
    "g6lc_pack_wrapped_columns.py",
    "g6lc_column_tile.h",
    "g6lc_age_compare.h",
    "g6lc_sentinel_dataflow.py",
    "g6lc_tuning_policy.py",
)
# Structural markers pre-scanned across active TUs for Lua policy introspection.
KNOWN_MARKERS = (
    "u_recover__DOT__",
    "i_sb_commit_bundle__DOT__mem_col",
    "i_vio_red__DOT__age_col",
    "gen_gm__BRA__",
    "__Vfunc_ooo_age_older__",
    "i_stl_red__DOT__dwait_d",
    "i_release__DOT__t1_alloc_older",
    "i_rob__DOT__rob_d",
    "i_sb_lifecycle__DOT__mem_n",
    "i_rs1_last_raw__DOT__same_rd_as_rs",
    "VL_ONEHOT",
    "->assertOn()",
)


class UnsupportedLayout(ValueError):
    """Safe to keep the original makefile on a fresh automatic build."""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _parse_vlt_stats(stats_file):
    if not stats_file.is_file():
        return {}
    st = stats_file.read_text(errors="replace")
    out = {}
    for key, pat in (
        ("mtask_count", r"MTask graph, final, mtask count\s+(\d+)"),
        ("edge_count", r"MTask graph, final, edge count\s+(\d+)"),
        ("parallelism_factor", r"MTask graph, final, parallelism factor\s+(\d+)"),
        ("clock_skip_sink_groups", r"Clock skip sink groups\s+(\d+)"),
        ("clock_skip_sink_deferred", r"Clock skip sink deferred calls\s+(\d+)"),
        ("clock_skip_sink_dropped", r"Clock skip sink triggers dropped\s+(\d+)"),
        ("clock_skip_causal_scopes", r"Clock skip scopes\s+(\d+)"),
        ("clock_skip_causal_edges", r"Clock skip invalidation edges\s+(\d+)"),
    ):
        m = re.search(pat, st)
        if m:
            out[key] = int(m.group(1))
    return out


def _collect_sentinel_info(model):
    """Summarize any --dumpi-sentinel 1 JSON snapshots present in Mdir."""
    dfg_counts = Counter()
    dfg_regions = []
    sched_info = {}
    for dfg_path in sorted(model.glob("*_sentinel_dfg*.json")):
        try:
            raw = json.loads(dfg_path.read_text())
            idx = dataflow_index(raw)
        except Exception:
            continue
        for reg in idx.get("regions", ()):
            op = reg.get("operation")
            if op:
                dfg_counts[op] += 1
            for pr in reg.get("probe_candidates", ()):
                dfg_counts[pr] += 1
            dfg_regions.append(dict(module=idx.get("module", ""), **reg))
    for sch_path in sorted(model.glob("*_sentinel_sched*.json")):
        try:
            raw = json.loads(sch_path.read_text())
        except Exception:
            continue
        tasks = raw.get("tasks", ())
        if tasks:
            sched_info = {
                "tasks": len(tasks),
                "edges": sum(len(t.get("deps", ())) for t in tasks),
                "lanes": len({t.get("lane") for t in tasks}),
            }
            break
    info = {}
    if dfg_counts:
        info["dfg"] = dict(dfg_counts)
    if sched_info:
        info["sched"] = sched_info
    return info, dfg_regions


def _scan_tu_markers(model, all_names):
    found = set()
    remaining = set(KNOWN_MARKERS)
    for name in all_names:
        if not remaining:
            break
        p = model / f"{name}.cpp"
        if not p.is_file():
            continue
        txt = p.read_text(errors="replace")
        hit = {m for m in remaining if m in txt}
        found |= hit
        remaining -= hit
    return sorted(found)


def _lower_one_tu(args):
    name, source, h, ops, dead_vars = args
    cur = source
    hits = {op: 0 for op in PASSES}
    if "packed-rows" in ops:
        cur, hits["packed-rows"] = lower(cur, h)
    if "packed-mux-rows" in ops:
        cur, hits["packed-mux-rows"] = lower_mux_rows(cur, h)
    if "packed-predicates" in ops:
        cur, hits["packed-predicates"] = lower_predicates(cur, h)
    if "tiled-columns" in ops:
        cur, hits["tiled-columns"] = lower_columns(cur, h)
    if "wrapped-columns" in ops:
        cur, hits["wrapped-columns"] = lower_wrapped(cur, h)
    if "strided-bit-columns" in ops:
        cur, hits["strided-bit-columns"] = lower_bit_columns(cur, h)
    if "circular-age-compare" in ops:
        cur, hits["circular-age-compare"] = lower_age_compare(cur, h)
    if "scatter-eq-mask" in ops:
        cur, hits["scatter-eq-mask"] = lower_scatter_mask(cur, h)
    if "wide-mux-guard" in ops:
        cur, hits["wide-mux-guard"] = lower_wide_mux(cur, h)
    if "assert-guard-hoist" in ops:
        cur, hits["assert-guard-hoist"] = lower_assert_guard(cur, h)
    if "assert-cone-gate" in ops and dead_vars:
        cur, hits["assert-cone-gate"] = lower_assert_cone(cur, dead_vars)
    if not any(hits.values()):
        return None
    return name, cur, hits


def prepare(model, plugin=None, prefix=PREFIX):
    tools = Path(__file__).resolve().parent
    dest = model / OUTPUT
    if not re.fullmatch(r"[A-Za-z_]\w*", prefix, re.ASCII):
        raise ValueError("invalid generated model prefix")
    verfiles = model / f"{prefix}__verFiles.dat"
    records = verfiles.read_text()
    commands = re.findall(r'^C "(.*)"$', records, re.M)
    if len(commands) != 1:
        raise ValueError("missing or ambiguous Verilator recipe")
    sources = sorted({p.replace("\\", "/").rsplit("/", 1)[-1] for p in
                      re.findall(r'^S [^"\n]*"([^"\r\n]+\.(?:svh?|vh?))"$', records, re.M)})
    classes = model / f"{prefix}_classes.mk"
    text = classes.read_text()
    if not re.search(r"^VM_PARALLEL_BUILDS\s*=\s*1\s*$", text, re.M):
        raise UnsupportedLayout("expected separate generated translation units")
    all_tu_names = sorted(set(re.findall(rf"^[ \t]*({prefix}\w*__DepSet_\w+)"
                                         r"[ \t]*\\?[ \t]*$", text, re.M | re.ASCII)))
    vlt_stats = _parse_vlt_stats(model / f"{prefix}__stats.txt")
    sentinel_info, sentinel_regions = _collect_sentinel_info(model) if plugin else ({}, [])
    tu_markers = _scan_tu_markers(model, all_tu_names) if plugin else ()
    policy, metadata = select_policy(
        prefix, commands[0], plugin, sources,
        markers=tu_markers, stats=vlt_stats, sentinel_info=sentinel_info,
    )
    # Use only active make targets, not stale TUs left in an incremental Mdir.
    names = sorted({n for n in all_tu_names
                    if class_rules(policy, n.split("__DepSet_")[0])})
    headers = {n.split("__DepSet_")[0] for n in names}
    inputs = [classes, *(model / f"{h}.h" for h in sorted(headers)), *(model / f"{n}.cpp" for n in names)]
    identity = {"inputs": {f.name: digest(f) for f in inputs},
                "verilatorCommand": commands[0],
                "tools": {n: digest(tools / n) for n in TOOLS},
                "policy": metadata, "rules": policy}
    if plugin:
        identity["tools"]["g6lc_tuning_driver.lua"] = digest(tools / "g6lc_tuning_driver.lua")
    if dest.exists():
        receipt = json.loads((dest / "manifest.json").read_text())
        if identity != receipt["identity"] or any(
                digest(dest / n) != h for n, h in receipt["outputs"].items()):
            raise ValueError("generated source, tuning tool or overlay changed; use a fresh Mdir")
        return receipt["summary"]
    if next(model.glob("*.o"), None) or (model / "Variane_testharness").exists():
        raise ValueError("cannot retrofit an existing native/PGO model; use a fresh Mdir")

    # Publish a complete overlay atomically. No half-rewritten source tree on failure.
    with tempfile.TemporaryDirectory(dir=model) as tmp:
        stage = Path(tmp) / OUTPUT
        stage.mkdir()
        header = {h: (model / f"{h}.h").read_text() for h in headers}
        # Precompute per-class proven assert-only dead cones if any Lua rule requests assert-cone-gate.
        dead_by_cls = {}
        need_cone_cls = {cls for cls in headers if any(op == "assert-cone-gate" for _, op in class_rules(policy, cls))}
        if need_cone_cls:
            ext_texts = [
                (model / f"{n}.cpp").read_text(errors="replace")
                for n in all_tu_names if n.split("__DepSet_")[0] not in need_cone_cls
            ]
            for cls in sorted(need_cone_cls):
                cls_texts = [
                    (model / f"{n}.cpp").read_text(errors="replace")
                    for n in names if n.split("__DepSet_")[0] == cls and "__Slow" not in n
                ]
                dead_by_cls[cls] = compute_assert_only_vars(header[cls], cls_texts, ext_texts)
        counts, rules = {}, []
        totals = {op: 0 for op in PASSES}
        work_items = []
        for name in names:
            source = (model / f"{name}.cpp").read_text()
            cls = name.split("__DepSet_")[0]
            ops = tuple(sorted({op for marker, op in class_rules(policy, cls) if marker in source}))
            if ops:
                work_items.append((name, source, header[cls], ops, dead_by_cls.get(cls)))
        # Use parallel workers for real multi-TU models while keeping tiny/mocked runs in-process.
        workers = min(8, os.cpu_count() or 1)
        if workers > 1 and len(work_items) >= 16:
            with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as ex:
                results = list(ex.map(_lower_one_tu, work_items, chunksize=8))
        else:
            results = [_lower_one_tu(item) for item in work_items]
        for res in results:
            if res is None:
                continue
            name, cur, hits = res
            (stage / f"{name}.cpp").write_text(cur)
            for op, val in hits.items():
                totals[op] += val
            extra_hits = any(hits[op] for op in PASSES if op not in ("packed-rows", "tiled-columns"))
            counts[name] = (
                [hits["packed-rows"], hits["tiled-columns"]]
                if not extra_hits else {op: val for op, val in hits.items() if val}
            )
            cpp = f"{OUTPUT}/{name}.cpp"
            dep_list = [cpp]
            if hits["tiled-columns"] or hits["wrapped-columns"] or hits["strided-bit-columns"]:
                dep_list.append(f"{OUTPUT}/g6lc_column_tile.h")
            if hits["circular-age-compare"] or hits["scatter-eq-mask"]:
                dep_list.append(f"{OUTPUT}/g6lc_age_compare.h")
            rules.extend([f"{name}.o: {' '.join(dep_list)}",
                          "\t$(OBJCACHE) $(CXX) $(CXXFLAGS) $(CPPFLAGS) "
                          "$(if $(filter $@,$(VK_SLOW_OBJS)),$(OPT_SLOW),$(OPT_FAST)) "
                          f"-c -o $@ {cpp}"])
        (stage / "g6lc_column_tile.h").write_bytes((tools / "g6lc_column_tile.h").read_bytes())
        (stage / "g6lc_age_compare.h").write_bytes((tools / "g6lc_age_compare.h").read_bytes())
        (stage / "rules.mk").write_text("\n".join(rules) + ("\n" if rules else ""))
        summary = dict(metadata, translationUnits=len(counts),
                       packedRows=totals["packed-rows"],
                       tiledColumns=totals["tiled-columns"])
        opt_fields = (
            ("packed-mux-rows", "packedMuxRows"),
            ("packed-predicates", "packedPredicates"),
            ("wrapped-columns", "wrappedColumns"),
            ("strided-bit-columns", "stridedBitColumns"),
            ("circular-age-compare", "circularAgeCompares"),
            ("scatter-eq-mask", "scatterEqMasks"),
            ("wide-mux-guard", "wideMuxGuards"),
            ("assert-guard-hoist", "assertGuardHoists"),
            ("assert-cone-gate", "assertConeGates"),
        )
        for op, field in opt_fields:
            if totals[op]:
                summary[field] = totals[op]
        if metadata.get("sentinelProbes"):
            probe_res = {}
            for pr in metadata["sentinelProbes"]:
                op = pr["op"]
                glob = pr["targetGlob"]
                if op in ("circular_age_compare", "scatter_eq_mask", "wide_mux_guard"):
                    mapped = {
                        "circular_age_compare": totals["circular-age-compare"],
                        "scatter_eq_mask": totals["scatter-eq-mask"],
                        "wide_mux_guard": totals["wide-mux-guard"],
                    }[op]
                    probe_res[pr["name"]] = mapped
                else:
                    matched = sum(
                        1 for r in sentinel_regions
                        if (r.get("operation") == op or op in r.get("probe_candidates", ()))
                        and fnmatchcase(r.get("module", ""), glob)
                    )
                    probe_res[pr["name"]] = matched
            summary["sentinelProbeCounts"] = probe_res
        # Record clock-skip statistics when declared by the policy and stats are present.
        if metadata.get("clockSkip") and vlt_stats:
            cs_stats = {}
            for dst_k, src_k in (
                ("sinkGroups", "clock_skip_sink_groups"),
                ("sinkDeferredCalls", "clock_skip_sink_deferred"),
                ("sinkTriggersDropped", "clock_skip_sink_dropped"),
                ("causalScopes", "clock_skip_causal_scopes"),
                ("causalEdges", "clock_skip_causal_edges"),
            ):
                if src_k in vlt_stats:
                    cs_stats[dst_k] = vlt_stats[src_k]
            summary["clockSkipStats"] = cs_stats
            for req in metadata["clockSkip"]:
                if req["policy"] == "required":
                    active = cs_stats.get("sinkGroups", 0) if req["mode"] == "sink" else cs_stats.get("causalScopes", 0)
                    if not active:
                        raise UnsupportedLayout(f"required clock-skip ({req['mode']}) matched 0 groups")
        if any(not totals[op] for _, _, op in policy):
            raise UnsupportedLayout("no matches for a requested transform")
        receipt = dict(identity=identity, summary=summary, counts=counts,
                       outputs={f.name: digest(f) for f in stage.iterdir()})
        (stage / "manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
        stage.rename(dest)
    return summary


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("model", type=Path)
    ap.add_argument("--plugin", type=Path, help="trusted Lua 5.3/5.4 model policy")
    ap.add_argument("--prefix", default=PREFIX, help="emitted model prefix")
    args = ap.parse_args()
    try:
        print(json.dumps(prepare(args.model.resolve(), args.plugin, args.prefix), sort_keys=True))
    except UnsupportedLayout as exc:
        print(f"unsupported packed-tiled layout: {exc}", file=sys.stderr)
        sys.exit(3)
