#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Prepare an isolated native make overlay; never edit Verilator's emitted sources."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile

from g6lc_pack_columns import lower_columns
from g6lc_pack_generated_rows import lower, lower_mux_rows
from g6lc_pack_predicates import lower as lower_predicates
from g6lc_pack_wrapped_columns import lower_wrapped
from g6lc_tuning_policy import class_rules, select_policy


OUTPUT = "hyp8-packed-tiled"
PREFIX = "Vg6lc_testharness"
TOOLS = ("g6lc_hyp8_tuning.py", "g6lc_pack_columns.py", "g6lc_pack_generated_rows.py",
         "g6lc_pack_predicates.py", "g6lc_pack_wrapped_columns.py",
         "g6lc_column_tile.h", "g6lc_tuning_policy.py")


class UnsupportedLayout(ValueError):
    """Safe to keep the original makefile on a fresh automatic build."""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(model, plugin=None, prefix=PREFIX):
    tools = Path(__file__).resolve().parent
    dest = model/OUTPUT
    if not re.fullmatch(r"[A-Za-z_]\w*", prefix, re.ASCII):
        raise ValueError("invalid generated model prefix")
    verfiles = model/f"{prefix}__verFiles.dat"
    records = verfiles.read_text()
    commands = re.findall(r'^C "(.*)"$', records, re.M)
    if len(commands) != 1:
        raise ValueError("missing or ambiguous Verilator recipe")
    sources = sorted({p.replace("\\", "/").rsplit("/", 1)[-1] for p in
                      re.findall(r'^S [^"\n]*"([^"\r\n]+\.(?:svh?|vh?))"$', records, re.M)})
    policy, metadata = select_policy(prefix, commands[0], plugin, sources)
    classes = model/f"{prefix}_classes.mk"
    text = classes.read_text()
    if not re.search(r"^VM_PARALLEL_BUILDS\s*=\s*1\s*$", text, re.M):
        raise UnsupportedLayout("expected separate generated translation units")
    # Use only active make targets, not stale TUs left in an incremental Mdir.
    names = sorted({n for n in re.findall(rf"^[ \t]*({prefix}\w*__DepSet_\w+)"
                                          r"[ \t]*\\?[ \t]*$", text, re.M | re.ASCII)
                    if class_rules(policy, n.split("__DepSet_")[0])})
    headers = {n.split("__DepSet_")[0] for n in names}
    inputs = [classes, *(model/f"{h}.h" for h in sorted(headers)), *(model/f"{n}.cpp" for n in names)]
    identity = {"inputs": {f.name: digest(f) for f in inputs},
                "verilatorCommand": commands[0],
                "tools": {n: digest(tools/n) for n in TOOLS},
                "policy": metadata, "rules": policy}
    if plugin:
        identity["tools"]["g6lc_tuning_driver.lua"] = digest(tools/"g6lc_tuning_driver.lua")
    if dest.exists():
        receipt = json.loads((dest/"manifest.json").read_text())
        if identity != receipt["identity"] or any(
                digest(dest/n) != h for n, h in receipt["outputs"].items()):
            raise ValueError("generated source, tuning tool or overlay changed; use a fresh Mdir")
        return receipt["summary"]
    if next(model.glob("*.o"), None) or (model/"Variane_testharness").exists():
        raise ValueError("cannot retrofit an existing native/PGO model; use a fresh Mdir")

    # Publish a complete overlay atomically. No half-rewritten source tree on failure.
    with tempfile.TemporaryDirectory(dir=model) as tmp:
        stage = Path(tmp)/OUTPUT
        stage.mkdir()
        header = {h: (model/f"{h}.h").read_text() for h in headers}
        counts, rules = {}, []
        totals = {"packed-rows": 0, "packed-mux-rows": 0, "packed-predicates": 0,
                  "tiled-columns": 0, "wrapped-columns": 0}
        for name in names:
            source = (model/f"{name}.cpp").read_text()
            cls = name.split("__DepSet_")[0]
            ops = {op for marker, op in class_rules(policy, cls) if marker in source}
            if not ops:
                continue
            h = header[cls]
            cur = source
            rows = mux_rows = preds = columns = wrapped = 0
            if "packed-rows" in ops:
                cur, rows = lower(cur, h)
            if "packed-mux-rows" in ops:
                cur, mux_rows = lower_mux_rows(cur, h)
            if "packed-predicates" in ops:
                cur, preds = lower_predicates(cur, h)
            if "tiled-columns" in ops:
                cur, columns = lower_columns(cur, h)
            if "wrapped-columns" in ops:
                cur, wrapped = lower_wrapped(cur, h)
            if not (rows or mux_rows or preds or columns or wrapped):
                continue
            (stage/f"{name}.cpp").write_text(cur)
            totals["packed-rows"] += rows
            totals["packed-mux-rows"] += mux_rows
            totals["packed-predicates"] += preds
            totals["tiled-columns"] += columns
            totals["wrapped-columns"] += wrapped
            counts[name] = [rows, columns] if not (mux_rows or preds or wrapped) else {
                "packedRows": rows, "packedMuxRows": mux_rows, "packedPredicates": preds,
                "tiledColumns": columns, "wrappedColumns": wrapped,
            }
            cpp = f"{OUTPUT}/{name}.cpp"
            deps = f"{cpp} {OUTPUT}/g6lc_column_tile.h" if (columns or wrapped) else cpp
            rules.extend([f"{name}.o: {deps}",
                          "\t$(OBJCACHE) $(CXX) $(CXXFLAGS) $(CPPFLAGS) "
                          "$(if $(filter $@,$(VK_SLOW_OBJS)),$(OPT_SLOW),$(OPT_FAST)) "
                          f"-c -o $@ {cpp}"])
        (stage/"g6lc_column_tile.h").write_bytes((tools/"g6lc_column_tile.h").read_bytes())
        (stage/"rules.mk").write_text("\n".join(rules) + ("\n" if rules else ""))
        summary = dict(metadata, translationUnits=len(counts),
                       packedRows=totals["packed-rows"],
                       tiledColumns=totals["tiled-columns"])
        if totals["packed-mux-rows"]:
            summary["packedMuxRows"] = totals["packed-mux-rows"]
        if totals["packed-predicates"]:
            summary["packedPredicates"] = totals["packed-predicates"]
        if totals["wrapped-columns"]:
            summary["wrappedColumns"] = totals["wrapped-columns"]
        # Record clock-skip statistics when declared by the policy and stats are present.
        stats_file = model / f"{prefix}__stats.txt"
        if metadata.get("clockSkip") and stats_file.is_file():
            st = stats_file.read_text(errors="replace")
            cs_stats = {}
            for key, pat in (
                ("sinkGroups", r"Clock skip sink groups\s+(\d+)"),
                ("sinkDeferredCalls", r"Clock skip sink deferred calls\s+(\d+)"),
                ("sinkTriggersDropped", r"Clock skip sink triggers dropped\s+(\d+)"),
                ("causalScopes", r"Clock skip scopes\s+(\d+)"),
                ("causalEdges", r"Clock skip invalidation edges\s+(\d+)"),
            ):
                m = re.search(pat, st)
                if m:
                    cs_stats[key] = int(m.group(1))
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
        (stage/"manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
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
