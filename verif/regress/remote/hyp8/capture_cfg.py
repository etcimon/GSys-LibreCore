#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Capture elaborated scalar config fields for hyp8 timing analysis.

The simulator evaluates build_config; this script does not reimplement its
derived fields. Packed arrays are explicitly excluded from this scalar map.
This is a configuration probe, not execution or timing evidence for the CPU.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


RUNTIME = Path("/opt/testharness/runs/review-private-runtime-20260915/runtime")
RUNTIME_HASH = "dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166"
DRIVER = Path("/opt/testharness/src/verilator-causal/bin/verilator")
SOURCES = ("config_pkg.sv", "g6lc_hyp_pkg.sv",
           "g6lc64_hyp8_config_pkg.sv", "build_config_pkg.sv")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def members(text, typename):
    end = text.index("} " + typename + ";")
    start = text.rfind("typedef struct packed {", 0, end)
    if start < 0:
        raise ValueError(f"missing packed struct {typename}")
    body = text[start + len("typedef struct packed {"):end]
    enums = set(re.findall(r"typedef\s+enum\b[^}]*}\s*(\w+)\s*;", text))
    result, skipped = [], []
    for line in body.splitlines():
        line = line.split("//", 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r"(int(?:\s+unsigned)?|bit|\w+_t)\s+(\w+)\s*;", line)
        if match and (match[1] in {"int", "int unsigned", "bit"} or match[1] in enums):
            result.append(match[2])
        else:
            skipped.append(line)
    if not result or len(set(result)) != len(result):
        raise ValueError(f"invalid field extraction for {typename}")
    return result, skipped


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    src = out / "source"
    src.mkdir(exist_ok=True)
    hashes = {}
    for name in SOURCES:
        found = [p for p in data.rglob(name) if p.is_file()]
        if len(found) != 1:
            raise ValueError(f"expected one {name}, found {len(found)}")
        shutil.copy2(found[0], src / name)
        hashes[name] = sha(src / name)
    cfg_text = (src / "config_pkg.sv").read_text()
    fields, skipped = members(cfg_text, "g6lc_cfg_t")
    ai, ai_skipped = members(cfg_text, "ai_cfg_t")
    hyp, hyp_skipped = members((src / "g6lc_hyp_pkg.sv").read_text(), "g6lc_hyp_cfg_t")
    expressions = [(f"G6LCCfg.{field}", f"C.{field}") for field in fields]
    expressions += [(f"G6LCCfg.AiCfg.{field}", f"C.AiCfg.{field}") for field in ai]
    expressions += [(f"HypCfg.{field}", f"H.{field}") for field in hyp]
    fmt = "HYP8_CFG {" + ",".join(f'"{key}":%0d' for key, _ in expressions) + "}"
    args = ", ".join(f"64'({expression})" for _, expression in expressions)
    probe = src / "g6lc_hyp8_cfg_probe.sv"
    probe.write_text(
        "// Copyright (c) 2026 Etienne Cimon\n"
        "// SPDX-License-Identifier: MIT\n"
        "module g6lc_hyp8_cfg_probe;\n"
        "localparam config_pkg::g6lc_cfg_t C = "
        "build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);\n"
        "localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;\n"
        "initial begin\n"
        f"  $display({json.dumps(fmt)}, {args});\n"
        "  $finish;\nend\nendmodule\n")
    if sha(RUNTIME / "include/verilated_funcs.h") != RUNTIME_HASH:
        raise ValueError("runtime identity changed")
    env = dict(os.environ, VERILATOR_ROOT=str(RUNTIME),
               VPATH=str(RUNTIME / "include"))
    report = {"sourceHashes": hashes, "probeSha256": sha(probe),
              "runnerSha256": sha(Path(__file__)),
              "scope": "scalar fields evaluated by the configured elaborator; no CPU execution",
              "excludedDeclarations": {"G6LCCfg": skipped,
                                       "G6LCCfg.AiCfg": ai_skipped, "HypCfg": hyp_skipped},
              "profiles": {}}
    selected = os.environ.get("HYP8_CFG_PROFILE", "both")
    if selected not in {"both", "scalar", "smt2"}:
        raise ValueError("HYP8_CFG_PROFILE must be both, scalar, or smt2")
    for name, harts, defines in (("scalar", 1, []), ("smt2", 2, ["-DG6LC_HYP8_SMT2"])):
        if selected not in {"both", name}:
            continue
        model = out / ("model-" + name)
        cmd = [str(DRIVER), "--binary", "--timing", "--threads", "1", "-j", "2",
               "-Wno-fatal", "--top-module", "g6lc_hyp8_cfg_probe",
               "--Mdir", str(model), *defines,
               *(str(src / source) for source in SOURCES), str(probe)]
        with (out / (name + "-build.log")).open("w") as log:
            subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=300)
        exe = model / "Vg6lc_hyp8_cfg_probe"
        execution = subprocess.run([str(exe)], capture_output=True, text=True,
                                   check=True, timeout=30)
        (out / (name + "-probe.log")).write_text(execution.stdout + execution.stderr)
        rows = [line[len("HYP8_CFG "):] for line in execution.stdout.splitlines()
                if line.startswith("HYP8_CFG ")]
        if len(rows) != 1:
            raise ValueError("configuration probe did not emit exactly one record")
        values = json.loads(rows[0])
        if set(values) != {key for key, _ in expressions}:
            raise ValueError("configuration probe omitted or added fields")
        for key, expected in {"G6LCCfg.XLEN": 64, "G6LCCfg.NrHarts": harts,
                              "G6LCCfg.NrIssuePorts": 2, "G6LCCfg.NR_SB_ENTRIES": 32,
                              "G6LCCfg.MultStages": 8, "HypCfg.AluStages": 3,
                              "HypCfg.IqSpecWakeup": 0, "HypCfg.CsrReadStages": 2}.items():
            if values[key] != expected:
                raise ValueError(f"unexpected configured value {key}={values[key]}")
        (out / (name + "-param-map.json")).write_text(json.dumps(values, indent=2) + "\n")
        report["profiles"][name] = {"harts": harts, "fields": len(values),
                                    "command": cmd, "modelSha256": sha(exe)}
    (out / "cfg-capture.json").write_text(json.dumps(report, indent=2) + "\n")
    print("HYP8_CFG_CAPTURED")


if __name__ == "__main__":
    main()
