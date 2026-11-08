# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Actual load-unit scheduling/ownership regressions for the open C0 gate."""
import hashlib
import json
from pathlib import Path
import re
import subprocess


def fixture(text):
    """Select the actual load fixture, excluding unrelated review modules."""
    matches = list(re.finditer(
        r"(?ms)^module tb_g6lc_review_load_cancel;\n.*?^endmodule\b", text))
    if len(matches) != 1:
        raise RuntimeError("LOAD_TRANSLATION_FIXTURE_INVENTORY")
    return text[:text.index("module ")] + matches[0].group() + "\n"


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    names = [
        "config_pkg.sv", "cv64a6_imafdc_sv39_config_pkg.sv", "riscv_pkg.sv",
        "ariane_pkg.sv", "cf_math_pkg.sv", "lzc.sv", "lsu_bypass.sv", "load_unit.sv",
    ]
    inputs = [str(data / name) for name in names]
    bench = out / "load-translation-bench.sv"
    bench.write_text(fixture((data / "tb_g6lc_rtl_review.sv").read_text()))
    if re.search(r"lint_off\s+(?:UNOPTFLAT|LATCH)", (data / "lzc.sv").read_text()):
        raise RuntimeError("LOAD_TRANSLATION_LZC_WAIVER")
    split = out / "load-translation-representation.vlt"
    split.write_text("// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n"
                     '`verilator_config\nsplit_var -module "lzc" -var "*_nodes"\n')
    generated = [bench, split]
    top = "tb_g6lc_review_load_cancel"
    strict = ["-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT", "-Werror-PINMISSING"]
    if "load-translation" in stages:
        # The exact LZC representation rule must still reject real feedback.
        canary = out / "load-translation-loop-canary.sv"
        canary.write_text("""// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module lzc(input logic gate_i, output logic [1:0] result_o);
  logic [1:0] index_nodes;
  assign index_nodes[0] = gate_i ? ~index_nodes[0] : 1'b0;
  assign index_nodes[1] = gate_i;
  assign result_o = index_nodes;
endmodule
""")
        generated.append(canary)
        command = [str(verilator), "--lint-only", "--top-module", "lzc",
                   "--Mdir", str(out / "load-translation-loop-canary"), *strict,
                   *manifest["runtime"].get("verilator_options", []), str(canary), str(split)]
        (out / "load-translation-loop-command.json").write_text(json.dumps(command))
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        text = result.stdout + result.stderr
        (out / "load-translation-loop-negative.log").write_text(text)
        if result.returncode == 0 or "%Error-UNOPTFLAT:" not in text:
            raise RuntimeError("LOAD_TRANSLATION_LOOP_ORACLE")
        outcomes.append({"load_translation": "real-loop-negative", "pass": True})
        profiles = [
            ("coupled", {"OOO": 1, "NLOAD": 1, "MMU": 1, "TRANSLATION_FEEDBACK": 1},
             [100], 100, "LOAD_TRANSLATION_FORWARD"),
            ("ooo", {"OOO": 1, "NLOAD": 4, "MMU": 1},
             list(range(14)) + [25], 25, "LOAD_FWD_FALLTHROUGH"),
            ("inorder", {"OOO": 0, "NLOAD": 4, "MMU": 1},
             [2, 3, 4, 5, 6, 13], 13, "LOAD_MISALIGN_EXCEPTION"),
            ("coherent", {"OOO": 1, "NLOAD": 4, "MMU": 1, "COH": 1},
             list(range(16, 25)), 22, "LOAD_EXKILL_TAG"),
        ]
        for label, params, cases, negative_case, negative_token in profiles:
            tag = "load-translation-" + label
            model = out / tag
            command = [
                str(verilator), "--binary", "--timing", "--assert", "--threads", "1",
                *strict, "-DG6LC_REVIEW_CANCEL_PORT", "-DG6LC_REVIEW_PHYS_PORT",
                "--top-module", top, "--Mdir", str(model), "-o", "load-test",
                *[f"-G{k}={v}" for k, v in params.items()], *inputs, str(bench), str(split),
            ]
            builds.append(build_model(command, model, out / (tag + "-build.log"),
                                      manifest, pgo_compile_timeout=120))
            for case, negative in [(n, False) for n in cases] + [(negative_case, True)]:
                label = f"{tag}-case{case}" + ("-negative" if negative else "")
                command = [str(model / "load-test"), f"+scenario={case}"]
                if negative:
                    command.append("+oracle_negative")
                result = subprocess.run(command, capture_output=True, text=True, timeout=10)
                text = result.stdout + result.stderr
                (out / (label + ".log")).write_text(text)
                passed = ((result.returncode != 0 and negative_token in text and
                           "LOAD_CANCEL_PASS" not in text) if negative else
                          (result.returncode == 0 and text.count("LOAD_CANCEL_PASS") == 1))
                if not passed:
                    raise RuntimeError(f"{label}: unexpected simulation verdict")
                outcomes.append({"load_translation": label, "negative_oracle": negative, "pass": True})
    if "load-translation-synth" in stages:
        from yosys_bin import yosys_bin
        yosys = Path(yosys_bin())
        manifest["yosys"], manifest["yosys_sha256"] = str(yosys), sha(yosys)
        text = bench.read_text()
        definitions = text[text.index("  parameter bit"):text.index("  logic clk=")]
        definitions = definitions.replace("parameter bit MMU=0", "parameter bit MMU=1")
        ports = (data / "load_unit.sv").read_text().split(") (", 1)[1].split("\n);", 1)[0]
        for old, new in (("CVA6Cfg", "C"), ("dcache_req_i_t", "req_t"),
                         ("dcache_req_o_t", "resp_t"), ("lsu_ctrl_t", "ctrl_t")):
            ports = ports.replace(old, new)
        wrapper = out / "g6lc_load_translation_synth.sv"
        wrapper.write_text(
            "// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n"
            "package g6lc_lu_types;\nimport ariane_pkg::*;\n" + definitions +
            "\nendpackage\nmodule g6lc_load_translation_synth import g6lc_lu_types::*; (\n" +
            ports + "\n);\nload_unit #(.CVA6Cfg(C),.dcache_req_i_t(req_t),"
            ".dcache_req_o_t(resp_t),.exception_t(exception_t),.lsu_ctrl_t(ctrl_t)) dut(.*);\nendmodule\n")
        generated.append(wrapper)
        script = out / "load-translation-synth.ys"
        netlist = out / "load-translation-synth.json"
        script.write_text(
            "read_slang --std 1800-2017 --top g6lc_load_translation_synth " +
            " ".join([*inputs, str(wrapper)]) +
            "\nsynth -top g6lc_load_translation_synth -noabc\ncheck -assert\nscc -expect 0\n"
            f"select -assert-none t:*dlatch*\nstat\nwrite_json {netlist}\n")
        with (out / "load-translation-synth.log").open("w") as log:
            subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=60)
        modules = json.loads(netlist.read_text())["modules"]
        cells = [cell for m in modules.values() for cell in m.get("cells", {}).values()]
        if not cells or any("latch" in c["type"].lower() for c in cells):
            raise RuntimeError("LOAD_TRANSLATION_SYNTH_EMPTY_OR_LATCH")
        outcomes.append({"load_translation_synth": True, "cells": len(cells), "latches": 0,
                         "scc": 0, "memories": sum(len(m.get("memories", {})) for m in modules.values()),
                         "pass": True})
    manifest["load_translation_generated"] = {str(p): sha(p) for p in generated}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
