# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Selected commit-stage regressions; never native/full-CPU qualification."""
import hashlib
import json
from pathlib import Path
import subprocess


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    inputs = [str(data / name) for name in [
        "config_pkg.sv", "cv64a6_imafdc_sv39_config_pkg.sv", "riscv_pkg.sv",
        "ariane_pkg.sv", "build_config_pkg.sv", "commit_stage.sv",
        "g6lc_commit_defaults_fixture.sv",
    ]]
    yosys = None
    if set(stages) & {"commit-defaults-formal", "commit-defaults-synth"}:
        from yosys_bin import yosys_bin
        yosys = Path(yosys_bin())
        manifest["yosys"] = str(yosys)
        manifest["yosys_sha256"] = hashlib.sha256(yosys.read_bytes()).hexdigest()
    for ports in (1, 2):
        tag = f"commit-defaults-ports{ports}"
        if "commit-defaults" in stages:
            model = out / tag
            command = [
                str(verilator), "--binary", "--timing", "--assert", "-j", "1",
                "--threads", "1", "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
                "-Werror-PINMISSING", "--top-module", "tb_g6lc_commit_defaults",
                f"-GPorts={ports}", "--Mdir", str(model), "-o", "commit-test",
                *inputs, str(data / "tb_g6lc_commit_defaults.sv"),
            ]
            builds.append(build_model(command, model, out / (tag + "-build.log"), manifest))
            for negative in (False, True):
                label = tag + ("-negative" if negative else "-sim")
                result = subprocess.run(
                    [str(model / "commit-test"), *(["+oracle_negative"] if negative else [])],
                    capture_output=True, text=True, timeout=30)
                text = result.stdout + result.stderr
                (out / (label + ".log")).write_text(text)
                expected = "COMMIT_DEFAULTS_FAIL negative-oracle" if negative else "COMMIT_DEFAULTS_PASS"
                if ((result.returncode != 0) != negative or text.count(expected) != 1):
                    raise RuntimeError(f"{label}: unexpected simulation verdict")
                outcomes.append({"commit_defaults": label, "negative_oracle": negative, "pass": True})
        if "commit-defaults-formal" in stages:
            top = "formal_g6lc_commit_defaults"
            prefix = (
                f"read_slang --top {top} -DFORMAL -GPorts={ports} " +
                " ".join(inputs + [str(data / "formal_g6lc_commit_defaults.sv")]) +
                f"\nprep -top {top}\nasync2sync\nchformal -lower\nflatten\n"
                "opt -full\ndffunmap\nopt_clean -purge\ncheck -assert\n")
            queries = [
                ("safety", "-prove-asserts -verify", False),
                ("retire-cover", "-prove cover_retire_o 0 -falsify", False),
                ("drop-cover", "-prove cover_drop_o 0 -falsify", False),
                ("negative", "-prove-asserts -verify", True),
            ]
            if ports == 2:
                queries.append(("dual-cover", "-prove cover_dual_o 0 -falsify", False))
            for name, goal, negative in queries:
                label = tag + "-formal-" + name
                script = out / (label + ".ys")
                script.write_text(
                    (prefix.replace(f"-GPorts={ports}", f"-GPorts={ports} -GNegative=1")
                     if negative else prefix) +
                    f"sat -seq 8 -set-init-zero -set-at 1 rst_ni 0 {goal} " +
                    f"-show-ports -dump_vcd {out}/{label}.vcd\n")
                with (out / (label + ".log")).open("w") as log:
                    result = subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                            stderr=subprocess.STDOUT, timeout=300)
                text = (out / (label + ".log")).read_text()
                if ((result.returncode != 0) != negative or
                        (negative and "model found: FAIL" not in text)):
                    raise RuntimeError(f"{label}: unexpected formal verdict")
                outcomes.append({"commit_defaults_formal": label, "depth": 8,
                                 "negative_oracle": negative, "pass": True})
        if "commit-defaults-synth" in stages:
            top = "g6lc_commit_defaults_dut"
            label = tag + "-synth"
            script = out / (label + ".ys")
            netlist = out / (label + ".json")
            script.write_text(
                f"read_slang --top {top} -GPorts={ports} " + " ".join(inputs) +
                f"\nsynth -top {top} -noabc\ncheck -assert\nscc -expect 0\n"
                f"select -assert-none t:*dlatch*\nstat\nwrite_json {netlist}\n")
            with (out / (label + ".log")).open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
            modules = json.loads(netlist.read_text())["modules"]
            cells = [c for m in modules.values() for c in m.get("cells", {}).values()]
            memories = sum(len(m.get("memories", {})) for m in modules.values())
            if not cells or any("latch" in c["type"].lower() for c in cells):
                raise RuntimeError(f"{label}: empty design or inferred latch")
            outcomes.append({"commit_defaults_synth": label, "cells": len(cells),
                             "memories": memories, "latches": 0, "scc": 0, "pass": True})
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
