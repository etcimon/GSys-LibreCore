#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Prove and map arithmetic candidates without changing a host's RTL.

Example (on a builder with the OpenROAD fork installed):
  python3 tools/sum3_trial.py --yosys /prefix/bin/yosys --sta /prefix/bin/sta \
    --liberty /pdk/typ.lib --out /workspace/sum3-trial

SAT covers all binary inputs, including flush and overflow, at each width.
STA uses the same virtual clock, input transition and output load for both
implementations. A lower source-level FO4 estimate alone is not acceptance.
--commit-ports N specializes the sum to an acknowledge count and constant offset.
--count-delta tests count + push - pop; --popcount N tests pointer + popcount(push).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def quoted(path: Path | str) -> str:
    """One Tcl/Yosys double-quoted word; no shell participates."""
    return '"' + str(path).replace("\\", "/").replace('"', '\\"').replace(
        "$", "\\$"
    ).replace("[", "\\[").replace("]", "\\]") + '"'


def run(argv: list[str], log: Path) -> str:
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, check=False)
    log.write_text(result.stdout, encoding="utf-8")
    if result.returncode or re.search(r"^\s*(?:ERROR:|Error:|\[ERROR )",
                                     result.stdout, re.MULTILINE):
        raise RuntimeError(f"tool failed: {log}")
    return result.stdout


def trial(args: argparse.Namespace, out: Path) -> dict:
    source = Path(__file__).resolve().parents[1] / "fixtures/auto_correct/sum3_carry_save.sv"
    fixture = out / "input.sv"
    shutil.copyfile(source, fixture)
    shutil.copyfile(Path(__file__), out / "driver.py")
    lib = args.liberty.resolve()
    provenance = {
        "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "driver_sha256": hashlib.sha256((out / "driver.py").read_bytes()).hexdigest(),
        "liberty_sha256": hashlib.sha256(lib.read_bytes()).hexdigest(),
        "yosys": run([args.yosys, "-V"], out / "yosys-version.log").strip(),
        "sta": run([args.sta, "-version"], out / "sta-version.log").strip(),
        "constraint": {"period": 1.0, "input_transition": 0.01, "output_load": 0.005},
        "scope": "combinational binary-input equivalence; no sequential or X/Z proof",
    }
    for name in ("yosys", "sta"):
        binary = Path(shutil.which(getattr(args, name)) or getattr(args, name)).resolve()
        provenance[f"{name}_binary"] = str(binary)
        provenance[f"{name}_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    cases = []
    top = "commit_pointer_trial" if args.commit_ports else "sum3_carry_save"
    miter = "commit_pointer_miter" if args.commit_ports else "sum3_miter"
    extra = f"-set PORTS {args.commit_ports} " if args.commit_ports else ""
    implementations = ("serial", "carry-save", "parallel-increment") if args.commit_ports else (
        "serial", "carry-save"
    )
    if args.count_delta:
        top, miter = "count_delta_trial", "count_delta_miter"
        implementations = ("serial", "decoded-delta")
    if args.popcount:
        top, miter = "popcount_step_trial", "popcount_step_miter"
        extra = f"-set N {args.popcount} "
        implementations = ("serial", "balanced-popcount", "carry-select")
    provenance["shape"] = top
    provenance["commit_ports"] = args.commit_ports
    provenance["popcount_inputs"] = args.popcount
    for width in args.widths:
        for impl in range(1, len(implementations)):
            proof = out / f"w{width}-impl{impl}-proof.log"
            impl_arg = f"-set IMPL {impl} " if args.commit_ports or args.popcount else ""
            script = "; ".join([
                f"read_verilog -sv {quoted(fixture)}",
                f"chparam -set W {width} {extra}{impl_arg}{miter}",
                f"prep -top {miter} -flatten",
                "sat -verify -prove equal 1 -show-inputs",
            ])
            text = run([args.yosys, "-p", script], proof)
            if "SAT proof finished - no model found: SUCCESS!" not in text:
                raise RuntimeError(f"missing proof completion: {proof}")
        for impl, name in enumerate(implementations):
            tag = f"w{width}-{name}"
            netlist = out / f"{tag}.v"
            script = "; ".join([
                f"read_verilog -sv {quoted(fixture)}",
                f"chparam -set W {width} -set IMPL {impl} {extra}{top}",
                f"synth -top {top} -flatten -noabc",
                f"abc -liberty {quoted(lib)}",
                "clean",
                f"stat -liberty {quoted(lib)}",
                f"write_verilog -noattr -noexpr {quoted(netlist)}",
            ])
            mapping = run([args.yosys, "-p", script], out / f"{tag}-map.log")
            area = re.findall(r"Chip area for module .*?:\s*([\d.]+)", mapping)
            tcl = out / f"{tag}.tcl"
            tcl.write_text("\n".join([
                f"read_liberty {quoted(lib)}",
                f"read_verilog {quoted(netlist)}",
                f"link_design {top}",
                "create_clock -name trial -period 1.0",
                "set_input_delay 0 -clock trial [all_inputs]",
                "set_output_delay 0 -clock trial [all_outputs]",
                "set_input_transition 0.01 [all_inputs]",
                "set_load 0.005 [all_outputs]",
                "check_setup -verbose",
                "report_checks -path_delay max -group_count 3 -digits 6",
                'puts "SUM3_RESULT slack=[sta::worst_slack -max]"',
                "exit",
            ]) + "\n", encoding="utf-8")
            timing = run([args.sta, "-exit", str(tcl)], out / f"{tag}-sta.log")
            match = re.search(r"^SUM3_RESULT slack=(\S+)$", timing, re.MULTILINE)
            if not match or not math.isfinite(float(match[1])):
                raise RuntimeError(f"missing finite STA result: {tag}")
            cases.append({
                "width": width, "implementation": name, "binary_equivalent": True,
                "worst_slack": float(match[1]), "delay": 1.0 - float(match[1]),
                "area": float(area[-1]) if area else None,
                "netlist_sha256": hashlib.sha256(netlist.read_bytes()).hexdigest(),
            })
    return {"provenance": provenance, "cases": cases}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--yosys", required=True)
    ap.add_argument("--sta", required=True, help="OpenSTA binary from the OpenROAD fork")
    ap.add_argument("--liberty", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--widths", nargs="+", type=int, default=[1, 2, 5, 6, 8, 16])
    shape = ap.add_mutually_exclusive_group()
    shape.add_argument("--commit-ports", type=int, help="prove/map bounded acknowledge count + constant offset")
    shape.add_argument("--count-delta", action="store_true", help="prove/map count + push - pop")
    shape.add_argument("--popcount", type=int, help="prove/map pointer + popcount(N inputs)")
    args = ap.parse_args()
    if any(w < 1 for w in args.widths):
        ap.error("widths must be positive")
    if args.commit_ports is not None and args.commit_ports < 1:
        ap.error("commit-ports must be positive")
    if args.popcount is not None and args.popcount < 1:
        ap.error("popcount must be positive")
    args.out.mkdir(parents=True, exist_ok=True)
    # Never reuse reports from another invocation.
    out = Path(tempfile.mkdtemp(prefix="sum3-", dir=args.out)).resolve()
    try:
        result = trial(args, out)
    except (OSError, RuntimeError) as exc:
        (out / "result.json").write_text(json.dumps({"ok": False, "error": str(exc)}))
        raise
    result["ok"] = True
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"out": str(out), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
