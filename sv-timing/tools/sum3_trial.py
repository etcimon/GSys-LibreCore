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
                                     result.stdout, re.MULTILINE) or re.search(
        r"Creating black box|No paths found", result.stdout, re.IGNORECASE
    ):
        raise RuntimeError(f"tool failed: {log}")
    return result.stdout


def screen_cases(cases: list[dict], target_ps: float | None) -> list[dict]:
    """Within one fixed experiment, retain timing/area/state tradeoffs by width.

    Gate area excludes redundant flip-flops, so state count is a separate cost.
    Missing area cannot establish dominance. This is screening, not promotion.
    """
    result = []
    for case in cases:
        peers = [p for p in cases if p["width"] == case["width"]]
        baseline = next(p for p in peers if p["implementation"] == "serial")
        known_area = case.get("area") is not None
        dominated = False
        if known_area:
            costs = (case["delay"], case["area"], case.get("redundant_state_bits", 0))
            for peer in peers:
                if peer.get("area") is None:
                    continue
                other = (peer["delay"], peer["area"], peer.get("redundant_state_bits", 0))
                if all(a <= b for a, b in zip(other, costs)) and any(
                    a < b for a, b in zip(other, costs)
                ):
                    dominated = True
        result.append({
            "width": case["width"], "implementation": case["implementation"],
            "delay_gain_percent": 100 * (1 - case["delay"] / baseline["delay"])
            if baseline["delay"] > 0 else None,
            "pareto": not dominated if known_area else None,
            "target_met": case["delay"] * 1000 <= target_ps if target_ps else None,
            "note": ("registered timing; placement/routing still required"
                     if case.get("registered") else
                     "transition logic only; register and routed timing still required"),
        })
    return result


def trial(args: argparse.Namespace, out: Path) -> dict:
    fixture_name = "bounded_step_counter.sv" if args.cached_counter else "sum3_carry_save.sv"
    source = Path(__file__).resolve().parents[1] / "fixtures/auto_correct" / fixture_name
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
    cases, proofs = [], []
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
        implementations = ("serial", "balanced-popcount", "carry-select",
                           "late-carry", "parallel-prefix")
    if args.queue_count:
        top, miter = "queue_count_trial", "queue_count_miter"
        extra = f"-set N {args.queue_count} "
        implementations = ("serial", "pre-admission-count")
    if args.cached_counter:
        top, miter = "bounded_step_counter_trial", "bounded_step_counter_miter"
        extra = f"-set N {args.cached_counter} -set BLOCK {args.block_bits} "
        implementations = ("serial", "cached-carry", "cached-thermometer")
        provenance["scope"] = (
            "binary-input one-step counter/cache invariant including reset; "
            "no X/Z or whole-core equivalence proof"
        )
        if args.registered:
            top = "bounded_counter_registered"
    provenance["registered"] = args.registered
    selected = [(i, name) for i, name in enumerate(implementations)
                if args.variants is None or name in args.variants]
    if args.variants and set(args.variants) - set(implementations):
        raise ValueError(f"unknown variants for {top}: {args.variants}")
    if not any(i == 0 for i, _ in selected):
        selected.insert(0, (0, "serial"))
    provenance["shape"] = top
    provenance["commit_ports"] = args.commit_ports
    provenance["popcount_inputs"] = args.popcount
    provenance["queue_slots"] = args.queue_count
    provenance["cached_counter_inputs"] = args.cached_counter
    provenance["block_bits"] = args.block_bits if args.cached_counter else None
    provenance["abc_delay_ps"] = args.abc_delay_ps
    provenance["abc_driving_cell"] = args.abc_driving_cell
    provenance["variants"] = [name for _, name in selected]
    abc_constraints = ""
    if args.abc_driving_cell:
        constr = out / "mapping.constr"
        # ABC's load is in fF; the fixed STA study uses 0.005 pF.
        constr.write_text(f"set_driving_cell {args.abc_driving_cell}\nset_load 5\n")
        abc_constraints = f" -constr {quoted(constr)}"
    for width in args.widths:
        for impl, _ in selected:
            if impl == 0:
                continue
            proof = out / f"w{width}-impl{impl}-proof.log"
            impl_arg = f"-set IMPL {impl} " if (
                args.commit_ports or args.popcount or args.cached_counter
            ) else ""
            script = "; ".join([
                f"read_verilog -sv {quoted(fixture)}",
                f"chparam -set W {width} {extra}{impl_arg}{miter}",
                f"prep -top {miter} -flatten",
                "sat -verify -prove equal 1 -show-inputs",
            ])
            text = run([args.yosys, "-p", script], proof)
            if "SAT proof finished - no model found: SUCCESS!" not in text:
                raise RuntimeError(f"missing proof completion: {proof}")
            proofs.append({"width": width, "implementation": implementations[impl],
                           "status": "pass", "log": proof.name})
        if args.proof_only:
            continue
        for impl, name in selected:
            tag = f"w{width}-{name}"
            netlist = out / f"{tag}.v"
            script = "; ".join([
                f"read_verilog -sv {quoted(fixture)}",
                f"chparam -set W {width} -set IMPL {impl} {extra}{top}",
                f"synth -top {top} -flatten -noabc",
                *([f"dfflibmap -liberty {quoted(lib)}"] if args.registered else []),
                f"abc -liberty {quoted(lib)}" +
                (f" -D {args.abc_delay_ps:g}" if args.abc_delay_ps else "") + abc_constraints,
                "clean",
                f"stat -liberty {quoted(lib)}",
                f"write_verilog -noattr -noexpr {quoted(netlist)}",
            ])
            mapping = run([args.yosys, "-p", script], out / f"{tag}-map.log")
            area = re.findall(r"Chip area for module .*?:\s*([\d.]+)", mapping)
            tcl = out / f"{tag}.tcl"
            tcl.write_text("\n".join([
                f"read_liberty {quoted(lib)}",
                "set_cmd_units -time ns -capacitance pF",
                f"read_verilog {quoted(netlist)}",
                f"link_design -no_black_boxes {top}",
                "create_clock -name trial -period 1.0" +
                (" [get_ports clk_i]" if args.registered else ""),
                "set_input_delay 0 -clock trial " +
                ("[delete_from_list [all_inputs] [get_ports clk_i]]"
                 if args.registered else "[all_inputs]"),
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
            if not match or not math.isfinite(float(match[1])) or abs(float(match[1])) >= 1e30:
                raise RuntimeError(f"missing finite STA result: {tag}")
            cases.append({
                "width": width, "implementation": name, "binary_equivalent": True,
                "registered": args.registered,
                "worst_slack": float(match[1]), "delay": 1.0 - float(match[1]),
                "area": float(area[-1]) if area else None,
                "netlist_sha256": hashlib.sha256(netlist.read_bytes()).hexdigest(),
                "redundant_state_bits": max(0, (width - 1) // args.block_bits) * args.cached_counter
                if args.cached_counter and impl else 0,
            })
    return {"provenance": provenance, "proofs": proofs, "cases": cases,
            "screen": screen_cases(cases, args.abc_delay_ps)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--yosys", required=True)
    ap.add_argument("--sta", required=True, help="OpenSTA binary from the OpenROAD fork")
    ap.add_argument("--liberty", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--widths", nargs="+", type=int, default=[1, 2, 5, 6, 8, 16])
    ap.add_argument("--variants", nargs="+", help="screen named variants; serial baseline always included")
    ap.add_argument("--proof-only", action="store_true", help="check parameter edges without mapping them")
    ap.add_argument("--registered", action="store_true", help="map cached-counter registers too; delay includes FF timing")
    ap.add_argument("--abc-delay-ps", type=float, help="ABC mapping target, recorded independently of STA constraints")
    ap.add_argument("--abc-driving-cell", help="enable ABC timing-constrained mapping with this library driver")
    shape = ap.add_mutually_exclusive_group()
    shape.add_argument("--commit-ports", type=int, help="prove/map bounded acknowledge count + constant offset")
    shape.add_argument("--count-delta", action="store_true", help="prove/map count + push - pop")
    shape.add_argument("--popcount", type=int, help="prove/map pointer + popcount(N inputs)")
    shape.add_argument("--cached-counter", type=int, help="prove counter/cache transition invariant for N inputs")
    shape.add_argument("--queue-count", type=int, help="prove/map count factoring across FIFO admission")
    ap.add_argument("--block-bits", type=int, default=4, help="segment width for the cached-carry counter")
    args = ap.parse_args()
    if args.registered and not args.cached_counter:
        ap.error("registered requires cached-counter")
    if any(w < 1 for w in args.widths):
        ap.error("widths must be positive")
    if args.commit_ports is not None and args.commit_ports < 1:
        ap.error("commit-ports must be positive")
    if args.popcount is not None and args.popcount < 1:
        ap.error("popcount must be positive")
    if args.queue_count is not None and (
        args.queue_count < 2 or args.queue_count & (args.queue_count - 1)
    ):
        ap.error("queue-count must be a power of two >= 2")
    if args.block_bits < 1 or args.block_bits > 16:
        ap.error("block-bits must be in 1..16")
    if args.cached_counter is not None and not 1 <= args.cached_counter < (1 << args.block_bits):
        ap.error("cached-counter must be positive and less than 2**block-bits")
    if args.abc_delay_ps is not None and (
        not math.isfinite(args.abc_delay_ps) or args.abc_delay_ps <= 0
    ):
        ap.error("abc-delay-ps must be positive and finite")
    if args.abc_driving_cell and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", args.abc_driving_cell):
        ap.error("abc-driving-cell must be a simple library cell name")
    args.out.mkdir(parents=True, exist_ok=True)
    # Never reuse reports from another invocation.
    out = Path(tempfile.mkdtemp(prefix="sum3-", dir=args.out)).resolve()
    try:
        result = trial(args, out)
    except (OSError, RuntimeError, ValueError) as exc:
        (out / "result.json").write_text(json.dumps({"ok": False, "error": str(exc)}))
        raise
    result["ok"] = True
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"out": str(out), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
