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
from g6lc_pack_generated_rows import lower


OUTPUT = "hyp8-packed-tiled"
PREFIX = "Vg6lc_testharness"
TOOLS = ("g6lc_hyp8_tuning.py", "g6lc_pack_columns.py", "g6lc_pack_generated_rows.py",
         "g6lc_column_tile.h")


class UnsupportedLayout(ValueError):
    """Safe to keep the original makefile on a fresh automatic build."""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(model):
    tools = Path(__file__).resolve().parent
    dest = model/OUTPUT
    verfiles = model/f"{PREFIX}__verFiles.dat"
    commands = re.findall(r'^C "(.*)"$', verfiles.read_text(), re.M)
    if (len(commands) != 1 or "-DG6LC_HYP8_MC" not in commands[0].split() or
            re.findall(r"(?:^| )--threads (\d+)(?= |$)", commands[0]) != ["2"]):
        raise ValueError("generated model is not the requested two-lane Hyp8 MC schedule")
    classes = model/f"{PREFIX}_classes.mk"
    text = classes.read_text()
    if not re.search(r"^VM_PARALLEL_BUILDS\s*=\s*1\s*$", text, re.M):
        raise UnsupportedLayout("expected separate generated translation units")
    # Use only active make targets, not stale TUs left in an incremental Mdir.
    names = sorted(set(re.findall(rf"^\s*({PREFIX}_g6lc_core(?:__pi\d+)?__DepSet_\w+)"
                                  r"[ \t]*\\?[ \t]*$", text, re.M)))
    headers = {n.split("__DepSet_")[0] for n in names}
    inputs = [classes, *(model/f"{h}.h" for h in sorted(headers)), *(model/f"{n}.cpp" for n in names)]
    identity = {"inputs": {f.name: digest(f) for f in inputs},
                "verilatorCommand": commands[0],
                "tools": {n: digest(tools/n) for n in TOOLS}}
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
        for name in names:
            source = (model/f"{name}.cpp").read_text()
            if "u_recover__DOT__" not in source:
                continue
            h = header[name.split("__DepSet_")[0]]
            packed, rows = lower(source, h)
            result, columns = lower_columns(packed, h)
            if not (rows or columns):
                continue
            (stage/f"{name}.cpp").write_text(result)
            counts[name] = [rows, columns]
            cpp = f"{OUTPUT}/{name}.cpp"
            rules.extend([f"{name}.o: {cpp} {OUTPUT}/g6lc_column_tile.h",
                          "\t$(OBJCACHE) $(CXX) $(CXXFLAGS) $(CPPFLAGS) "
                          "$(if $(filter $@,$(VK_SLOW_OBJS)),$(OPT_SLOW),$(OPT_FAST)) "
                          f"-c -o $@ {cpp}"])
        (stage/"g6lc_column_tile.h").write_bytes((tools/"g6lc_column_tile.h").read_bytes())
        (stage/"rules.mk").write_text("\n".join(rules) + "\n")
        summary = dict(profile="packed-tiled", translationUnits=len(counts),
                       packedRows=sum(x for x, _ in counts.values()),
                       tiledColumns=sum(y for _, y in counts.values()))
        if not summary["packedRows"] or not summary["tiledColumns"]:
            raise UnsupportedLayout("missing row or column matches")
        receipt = dict(identity=identity, summary=summary, counts=counts,
                       outputs={f.name: digest(f) for f in stage.iterdir()})
        (stage/"manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
        stage.rename(dest)
    return summary


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("model", type=Path)
    args = ap.parse_args()
    try:
        print(json.dumps(prepare(args.model.resolve()), sort_keys=True))
    except UnsupportedLayout as exc:
        print(f"unsupported packed-tiled layout: {exc}", file=sys.stderr)
        sys.exit(3)
