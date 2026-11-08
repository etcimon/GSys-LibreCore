# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""IQ admission/metadata regressions promoted from the storamic-cpu-36 gate."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def _fixture(path):
    text = path.read_text()
    pattern = re.compile(r"verilator\s+lint_(?:off|on)\s+(?:UNOPTFLAT|LATCH)")
    matches = list(pattern.finditer(text))
    if matches:
        raise RuntimeError("FETCH_QUEUE_WAIVER")


def _run(command, out, name, timeout):
    (out / (name + "-command.json")).write_text(json.dumps(command))
    with (out / (name + ".log")).open("w") as log:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=timeout)
        text = result.stdout + result.stderr
        log.write(text)
    errors = [s for s in text.splitlines() if s.startswith("%Error")]
    return result.returncode, text, errors


def _mutate(src, dest):
    """Textually revert the promoted push_address admission (old form)."""
    text = src.read_text()
    old = "push_instr[f] & (cf_type_i[s] != ariane_pkg::NoCF)"
    new = "push_instr[f] & (instr_data_in[f].cf != ariane_pkg::NoCF)"
    count = text.count(old)
    if count != 1:
        raise RuntimeError("FETCH_QUEUE_MUTATION_INVENTORY")
    dest.write_text(text.replace(old, new))


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    names = [
        "config_pkg.sv", "g6lc64_smt2_config_pkg.sv", "riscv_pkg.sv",
        "ariane_pkg.sv", "g6lc_fetch_pkg.sv", "cva6_fifo_v3.sv",
        "instr_queue.sv",
    ]
    inputs = [str(data / name) for name in names]
    bench = data / "tb_g6lc_fetch_queue.sv"
    _fixture(data / "instr_queue.sv")
    _fixture(bench)
    split = out / "fetch-queue-representation.vlt"
    split.write_text("// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n"
                     '`verilator_config\n'
                     'split_var -module "instr_queue" -var "fire_prefix"\n'
                     'split_var -module "instr_queue" -var "fetch_entry_valid_o"\n')
    generated = [split]
    top = "tb_g6lc_fetch_queue"
    strict = ["-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
              "-Werror-PINMISSING"]
    lint_opts = manifest.get("runtime", {}).get("verilator_options", [])
    params = "SLOTS=4 ISSUE=2 HARTS=2 RVC=1 CHECKPOINT_FEEDBACK=1"
    if "fetch-queue" in stages:
        # (a) Real-loop canaries for the two split vars.
        fixtures = {
            "fire_prefix": ("logic [1:0] fire_prefix;\n"
                            "  assign fire_prefix[0] = gate_i & ~fire_prefix[1];\n"
                            "  assign fire_prefix[1] = gate_i & fire_prefix[0];\n"
                            "  assign fetch_entry_valid_o = fire_prefix;\n"),
            "fetch_entry_valid_o": ("assign fetch_entry_valid_o[0] = gate_i & ~fetch_entry_valid_o[1];\n"
                                    "  assign fetch_entry_valid_o[1] = gate_i & fetch_entry_valid_o[0];\n"),
        }
        for var, body in fixtures.items():
            fixture = out / ("negative-" + var + ".sv")
            fixture.write_text(
                "// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n"
                "module instr_queue(input logic gate_i, "
                "output logic [1:0] fetch_entry_valid_o);\n" + body + "\nendmodule\n")
            generated.append(fixture)
            command = [str(verilator), "--lint-only", "--timing", "--assert",
                       "--threads", "1", "--top-module", "instr_queue",
                       "--Mdir", str(out / ("obj-" + var)), *strict, *lint_opts,
                       str(fixture), str(split)]
            rc, text, errors = _run(command, out, "negative-" + var, 20)
            if rc == 0 or "%Error-UNOPTFLAT:" not in text or not all(
                    s.startswith(("%Error-UNOPTFLAT:", "%Error: Exiting due"))
                    for s in errors):
                raise RuntimeError("FETCH_QUEUE_LOOP_ORACLE")
            outcomes.append({"fetch_queue": "real-loop-" + var, "pass": True})
        # (b) Regression-mutation oracle: the old admitted form must re-trip.
        mutant = out / "instr_queue_mutant.sv"
        _mutate(data / "instr_queue.sv", mutant)
        generated.append(mutant)
        mutant_inputs = [str(mutant) if p.endswith("instr_queue.sv") else p
                         for p in inputs]
        command = [str(verilator), "--lint-only", "--timing", "--assert",
                   "--threads", "1", "--top-module", top,
                   "--Mdir", str(out / "mutant-admission"), *strict, *lint_opts,
                   *[f"-G{k}={v}" for k, v in
                     dict(SLOTS=4, ISSUE=2, HARTS=2, RVC=1,
                          CHECKPOINT_FEEDBACK=1).items()],
                   *mutant_inputs, str(bench), str(split)]
        rc, text, errors = _run(command, out, "mutant-admission", 60)
        if rc == 0 or "%Error-UNOPTFLAT:" not in text or not all(
                s.startswith(("%Error-UNOPTFLAT:", "%Error: Exiting due"))
                for s in errors):
            raise RuntimeError("FETCH_QUEUE_ADMISSION_ORACLE")
        outcomes.append({"fetch_queue": "admission-mutation", "pass": True})
        # (c) Production profiles via build_model (sequential).
        profiles = [
            (4, 2, 2, 1, 180), (2, 1, 1, 1, 180), (2, 1, 1, 0, 180),
            (2, 2, 2, 0, 180), (8, 2, 2, 1, 900),
        ]
        for slots, issue, harts, rvc, pgo in profiles:
            label = f"s{slots}-i{issue}-h{harts}-c{rvc}"
            model = out / ("fetch-queue-" + label)
            command = [str(verilator), "--binary", "--timing", "--assert",
                       "--threads", "1", *strict, "--top-module", top,
                       "--Mdir", str(model), "-o", "queue-test",
                       *[f"-G{k}={v}" for k, v in
                         dict(SLOTS=slots, ISSUE=issue, HARTS=harts, RVC=rvc,
                              CHECKPOINT_FEEDBACK=1).items()],
                       *inputs, str(bench), str(split)]
            identity = build_model(command, model, out / ("fetch-queue-" + label + "-build.log"),
                                   manifest, pgo_compile_timeout=pgo)
            builds.append(identity)
            exe = Path(identity["executable"])
            for oracle, token in (("", "FETCH_QUEUE_PASS"),
                                  ("checkpoint_negative",
                                   "FETCH_QUEUE_CHECKPOINT_MISMATCH"),
                                  ("oracle_negative", "order/data mismatch")):
                command = [str(exe), *(["+" + oracle] if oracle else [])]
                try:
                    result = subprocess.run(command, capture_output=True,
                                            text=True, timeout=20)
                    text = result.stdout + result.stderr
                except subprocess.TimeoutExpired:
                    raise RuntimeError(f"fetch-queue-{label}-{oracle or 'positive'}: timeout")
                log = out / ("fetch-queue-" + label + "-" +
                             (oracle or "positive") + ".log")
                log.write_text(text)
                if not oracle:
                    ok = (result.returncode == 0 and text.count(token) == 1 and
                          int(re.search(r"checkpoints=(\d+)", text)[1]) > 0)
                else:
                    ok = (result.returncode != 0 and token in text and
                          "FETCH_QUEUE_PASS" not in text)
                if not ok:
                    raise RuntimeError(f"fetch-queue-{label}-{oracle or 'positive'}: verdict")
                outcomes.append({"fetch_queue": label + "/" + (oracle or "positive"),
                                 "pass": True})
            if harts == 2:
                try:
                    result = subprocess.run([str(exe), "+iq_oldest_neg"],
                                            capture_output=True, text=True,
                                            timeout=20)
                    text = result.stdout + result.stderr
                except subprocess.TimeoutExpired:
                    raise RuntimeError(f"fetch-queue-{label}-iq_oldest_neg: timeout")
                log = out / ("fetch-queue-" + label + "-iq_oldest_neg.log")
                log.write_text(text)
                if (result.returncode == 0 or "IQ_OLDEST_H1" not in text
                        or "FETCH_QUEUE_PASS" in text):
                    raise RuntimeError(f"fetch-queue-{label}-iq_oldest_neg: verdict")
                outcomes.append({"fetch_queue": label + "/iq_oldest_neg", "pass": True})
    if "fetch-queue-synth" in stages:
        from yosys_bin import yosys_bin
        yosys = Path(yosys_bin())
        manifest["yosys"], manifest["yosys_sha256"] = str(yosys), sha(yosys)
        text = bench.read_text()
        body = text.split("module tb_g6lc_fetch_queue;", 1)[1]
        definitions = body[:body.index("  logic clk")]
        ports = (data / "instr_queue.sv").read_text().split(") (", 1)[1].split("\n);", 1)[0]
        ports = ports.replace("CVA6Cfg", "C").replace("fetch_entry_t", "entry_t")
        wrapper = out / "g6lc_iq_admission_synth.sv"
        wrapper.write_text(
            "// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n"
            "package g6lc_iq_types;\n" + definitions +
            "\nlocalparam config_pkg::cva6_cfg_t C=cfg();\nendpackage\n"
            "module g6lc_iq_admission_synth import ariane_pkg::*; "
            "import g6lc_iq_types::*; (\n" + ports +
            "\n);\ninstr_queue #(.CVA6Cfg(C), .fetch_entry_t(entry_t)) dut(.*);\nendmodule\n")
        generated += [wrapper]
        script = out / "fetch-queue-synth.ys"
        netlist = out / "fetch-queue-synth.json"
        script.write_text(
            "read_slang --std 1800-2017 --top g6lc_iq_admission_synth " +
            " ".join([*inputs, str(wrapper)]) +
            "\nsynth -top g6lc_iq_admission_synth -noabc\ncheck -assert\n"
            "select -assert-none t:$dlatch t:$_DLATCH_*\nscc -expect 0\n"
            f"write_json {netlist}\n")
        with (out / "fetch-queue-synth.log").open("w") as log:
            subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=1200)
        modules = json.loads(netlist.read_text())["modules"]
        cells = [c for m in modules.values() for c in m.get("cells", {}).values()]
        if not cells or any("latch" in c["type"].lower() for c in cells):
            raise RuntimeError("FETCH_QUEUE_SYNTH_EMPTY_OR_LATCH")
        outcomes.append({"fetch_queue_synth": True, "cells": len(cells),
                         "latches": 0, "scc": 0, "pass": True})
    manifest["fetch_queue_generated"] = {str(p): sha(p) for p in generated}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
