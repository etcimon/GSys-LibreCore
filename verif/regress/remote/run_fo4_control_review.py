#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Isolated, paired control-cone proof and mapping review.

Local: python run_fo4_control_review.py --snapshot DIR --baseline REV
Remote: testharness_proxy.py py run_fo4_control_review.py --data DIR/inputs.tar.gz
        --tag fo4-control-<unique> --pull
Selection round: --profile selection --baseline 36bbe0114. Its directed
leaf mode also uploads tb_g6lc_lsq.sv and tb_g6lc_iq_store_age.sv and sets
CONTROL_MODE=selection-leaf.
The precompute profile replays the archived A120 trial snapshot, including
the IQ bank and store gather later rejected from production. Use the cited
inputs.tar.gz for those experiments; the retained tree uses final-widths.
CONTROL_MODE=precompute-leaf uploads store_buffer_sbs for asserted comparison.
CONTROL_MODE=placed-iq reads a completed paired run from CONTROL_REFERENCE
and an uploaded openroad-module-place-study.tcl; it never overwrites the
reference artifacts. PLACEMENT_GDB=1 captures a tool crash when needed.

Uses the host's existing portable flist; captures every source and include
header, with hashes. No shared checkout sync, cache overwrite, or source edit
on the builder. Mapped studies use identical recipes and source snapshots.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile


CHANGED = ("core/ooo/g6lc_ooo_pkg.sv", "core/ooo/g6lc_rename.sv",
           "core/store_buffer.sv", "core/alu.sv", "core/mult.sv",
           "core/fetch_B/frontend.sv", "core/scoreboard.sv")
MODULES = {"g6lc_rename", "store_buffer", "frontend", "g6lc_iq", "multiplier",
           "g6lc_lsq", "scoreboard", "instr_realign", "wt_dcache_wbuffer",
           "issue_read_operands", "alu", "mult"}


def snapshot(dest: Path, baseline: str, profile: str = "control") -> None:
    root = Path(__file__).resolve().parents[3]
    flist = root / "build-platform/workspace/build/sta-rtl/g6lc64_ooo/svt/portable.f"
    text = flist.read_text(encoding="utf-8")
    files: dict[str, bytes] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("+define+"):
            continue
        if line.startswith("+incdir+"):
            for inc in line[len("+incdir+"):].split("+"):
                for p in Path(inc).rglob("*.svh"):
                    files[p.relative_to(root).as_posix()] = p.read_bytes()
        elif not line.startswith(("+", "-")):
            p = Path(line)
            files[p.relative_to(root).as_posix()] = p.read_bytes()
    for name in ("sv-timing/tools/rtlil_width_map.py",
                 "build-platform/scripts/openroad-module-board.tcl",
                 "build-platform/scripts/openroad-module-place-study.tcl",
                 "build-platform/scripts/tc_sram_timing_stub.sv",
                 "verif/tb/core/multiplier_sbs/tb_mul_sbs.sv"):
        files[name] = (root / name).read_bytes()
    files["portable.f"] = text.replace(root.as_posix(), "@ROOT@").encode()
    files["host-param-map.json"] = (flist.parent / "param-map.json").read_bytes()
    fo4 = flist.parent.parent / "platform-fo4.json"
    if fo4.exists():
        files["platform-fo4.json"] = fo4.read_bytes()
    profile_files = {
        "control": CHANGED,
        "selection": ("core/ooo/g6lc_iq.sv", "core/ooo/g6lc_lsq.sv"),
        "precompute": ("core/ooo/g6lc_iq.sv", "core/ooo/g6lc_rename.sv", "core/store_buffer.sv"),
        "multiplier": ("core/multiplier.sv",),
        "boundary": ("core/store_buffer.sv", "core/ooo/g6lc_rename.sv", "core/fetch_B/instr_realign.sv"),
        "statcor": ("core/frontend/g6lc_bp_statcor.sv",),
        "loop-emit": ("core/frontend/g6lc_bp_loop.sv",),
        "lbuf": ("core/frontend/g6lc_loop_buffer.sv", "core/ooo/g6lc_rob.sv"),
        "ckpt": ("core/frontend/g6lc_bp_ckpt.sv",),
        "stq": ("core/store_buffer.sv",),
        "step1": ("core/cache_subsystem/wt_dcache_mem.sv", "core/frontend/g6lc_bp_loop.sv",
                  "core/frontend/g6lc_loop_buffer.sv"),
        "sbhead": ("core/scoreboard.sv",),
    }
    changed = profile_files[profile]
    if profile == "statcor":
        name = "verif/tb/core/tb_g6lc_bp_statcor.sv"
        files[name] = (root / name).read_bytes()
    if profile == "loop-emit":
        name = "verif/tb/core/tb_g6lc_bp_loop_emit.sv"
        files[name] = (root / name).read_bytes()
    if profile == "lbuf":
        for name in ("verif/tb/core/tb_g6lc_loop_buffer_sbs.sv", "verif/tb/core/tb_g6lc_rob.sv"):
            files[name] = (root / name).read_bytes()
    if profile == "ckpt":
        name = "verif/tb/core/tb_g6lc_rtl_review.sv"
        files[name] = (root / name).read_bytes()
    if profile == "stq":
        for p in (root / "verif/tb/core/store_buffer_sbs").glob("*.sv"):
            files[p.relative_to(root).as_posix()] = p.read_bytes()
    if profile == "step1":
        for name in ("verif/tb/core/tb_g6lc_loop_buffer_sbs.sv", "verif/tb/core/tb_g6lc_bp_loop_emit.sv",
                     "vendor/pulp-platform/common_cells/src/lzc.sv",
                     "vendor/pulp-platform/common_cells/src/rr_arb_tree.sv",
                     "common/local/util/sram.sv", "common/local/util/sram_cache.sv",
                     "common/local/util/tc_sram_wrapper.sv",
                     "common/local/util/tc_sram_wrapper_cache_techno.sv"):
            files[name] = (root / name).read_bytes()
    if profile == "boundary":
        for folder in ("store_buffer_sbs", "instr_realign_sbs"):
            for p in (root / "verif/tb/core" / folder).glob("*.sv"):
                files[p.relative_to(root).as_posix()] = p.read_bytes()
    measured = MODULES if profile == "control" else {Path(p).stem for p in changed}
    files["review.json"] = json.dumps({"profile": profile, "changed_files": changed,
                                      "modules": sorted(measured)}).encode()
    for name in changed:
        files["baseline/" + name] = subprocess.check_output(
            ["git", "show", f"{baseline}:{name}"], cwd=root)
    identity = {n: hashlib.sha256(b).hexdigest() for n, b in sorted(files.items())}
    identity["baseline_revision"] = subprocess.check_output(
        ["git", "rev-parse", baseline], cwd=root, text=True).strip()
    files["sources.json"] = json.dumps(identity, indent=2).encode()
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(dest / "inputs.tar.gz", "w:gz") as tar:
        for name, content in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size = len(content)
            tar.addfile(info, io.BytesIO(content))
    print(f"SNAPSHOT {len(files)} files -> {dest / 'inputs.tar.gz'}", flush=True)


def analyze_results(results: Path) -> None:
    """Fresh structural reports of the mapped snapshots, plus a review emit."""
    root = Path(__file__).resolve().parents[3]
    results = results.resolve()
    source = results / "source"
    review_path = source / "review.json"
    if review_path.exists() and json.loads(review_path.read_text())["profile"] == "multiplier":
        analyze_multiplier_results(root, results)
        return
    portable = (source / "portable.f").read_text(encoding="utf-8").replace("@ROOT@", source.as_posix())
    params = source / "host-param-map.json"
    # Use snapshot cfg values, not a newer host run's parameter map. The
    # first A118 archives predate this capture and retain the exact map used
    # for analysis directly in the results directory.
    captured = results / "analysis-param-map.json"
    if params.exists():
        captured.write_bytes(params.read_bytes())
    elif not captured.exists():
        raise ValueError("snapshot lacks a captured parameter map")
    cfg = json.loads(captured.read_text(encoding="utf-8"))
    if cfg.get("CVA6Cfg.XLEN") != 64 or cfg.get("CVA6Cfg.MultStages") != 2:
        raise ValueError("expected g6lc64_ooo XLEN=64/MultStages=2 parameter snapshot")
    review = source / "review.json"
    changed = json.loads(review.read_text())["changed_files"] if review.exists() else CHANGED
    if not (results / "candidate/width-map.json").exists():
        raise ValueError("candidate elaborated widths are required")
    for variant in ("baseline", "candidate"):
        if not (results / variant / "width-map.json").exists():
            continue
        flist = portable
        if variant == "baseline":
            for name in changed:
                old = source / "baseline" / name
                if old.exists():
                    flist = flist.replace((source / name).as_posix(), old.as_posix())
        path = results / f"{variant}-structural.f"
        path.write_text(flist, encoding="utf-8")
        command = [sys.executable, str(root / "sv-timing/tools/svt.py"), "run", "--release", "--",
                   "analyze", "--files-from", str(path), "--all-modules", "--target-mhz", "4000",
                   "--fo4-ps", "20", "--budget-margin", "0.2", "--param-map", str(captured),
                   "--width-map", str(results / variant / "width-map.json"),
                   "--assume-xlen", "64", "--package-mode", "packages",
                   "--json-out", str(results / f"{variant}-structural.json")]
        with (results / f"{variant}-structural.log").open("w") as log:
            subprocess.run(command, cwd=root / "sv-timing", check=True, stdout=log,
                           stderr=subprocess.STDOUT, env=dict(os.environ, RUST_MIN_STACK="16777216"))
    command = [sys.executable, str(root / "sv-timing/tools/svt.py"), "run", "--release", "--",
               "correct", "--files-from", str(results / "candidate-structural.f"),
               "--all-modules", "--target-mhz", "4000", "--fo4-ps", "20",
               "--budget-margin", "0.2", "--param-map", str(captured),
               "--width-map", str(results / "candidate/width-map.json"),
               "--assume-xlen", "64", "--package-mode", "packages", "--opt-level", "3",
               "--emit", "--real-cut-feeds", "--out-dir", str(results / "review-corrected"),
               "--json-out", str(results / "correct.json"), "--tradeoffs", "16"]
    # Deliberately no --allow-latency: arithmetic/data cuts without an
    # acceptance/identity contract are not implementations of a pipeline.
    with (results / "correct.log").open("w") as log:
        subprocess.run(command, cwd=root / "sv-timing", check=True, stdout=log,
                       stderr=subprocess.STDOUT, env=dict(os.environ, RUST_MIN_STACK="16777216"))


def analyze_multiplier_results(root: Path, results: Path) -> None:
    """Correct the isolated source using its own elaborated widths and latency."""
    source = results / "source"
    portable = (source / "portable.f").read_text().replace("@ROOT@", source.as_posix())
    packages = [l for l in portable.splitlines()
                if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
    flist = results / "multiplier-analysis.f"
    flist.write_text("\n".join(packages + [(source / "core/multiplier.sv").as_posix()]) + "\n")
    params = json.loads((source / "host-param-map.json").read_text())
    # The measurement wrapper explicitly overrides this field; all other
    # configuration values come from the captured package/host snapshot.
    params["CVA6Cfg.MultStages"] = 3
    params["cva6_cfg.MultStages"] = 3
    param_file = results / "multiplier-analysis-params.json"
    param_file.write_text(json.dumps(params, indent=2))
    widths = results / "candidate3-width-map.json"
    assert widths.exists(), "run mult-pipeline mapping before correction"
    width_data = json.loads(widths.read_text())
    if "multiplier" not in width_data["modules"]:
        # read_slang may flatten the known study wrapper. Peel only that
        # instance prefix, preserving generate scopes and the original map.
        instance = width_data["modules"].get("g6lc_mul_timing", {})
        peeled = {name[len("dut."):]: width for name, width in instance.items()
                  if name.startswith("dut.")}
        assert peeled, "missing elaborated multiplier instance widths"
        width_data["modules"] = {"multiplier": peeled}
        widths = results / "multiplier-analysis-width-map.json"
        widths.write_text(json.dumps(width_data, indent=2))
    command = [sys.executable, str(root / "sv-timing/tools/svt.py"), "run", "--release", "--",
               "correct", "--files-from", str(flist), "--modules-allow", "multiplier",
               "--param-map", str(param_file), "--width-map", str(widths),
               "--assume-xlen", "64", "--package-mode", "packages",
               "--target-mhz", "4000", "--fo4-ps", "20", "--budget-margin", "0.2",
               "--opt-level", "3", "--allow-latency", "--real-cut-feeds", "--assume-clk",
               "--emit", "--out-dir", str(results / "corrected"),
               "--json-out", str(results / "correct.json"),
               "--trace-log", str(results / "correct.jsonl")]
    with (results / "correct.log").open("w") as log:
        subprocess.run(command, cwd=root / "sv-timing", check=True,
                       stdout=log, stderr=subprocess.STDOUT,
                       env=dict(os.environ, RUST_MIN_STACK="16777216"))


def remote() -> None:
    data, out = Path(os.environ["TH_DATA_DIR"]), Path(os.environ["TH_OUT_DIR"])
    src = out / "source"
    src.mkdir()
    with tarfile.open(data / "inputs.tar.gz") as tar:
        tar.extractall(src, filter="data")
    identity = json.loads((src / "sources.json").read_text())
    for name, sha in identity.items():
        if name != "baseline_revision":
            assert hashlib.sha256((src / name).read_bytes()).hexdigest() == sha, name
    (out / "sources.json").write_text(json.dumps(identity, indent=2))
    ys = "/opt/testharness/toolchains/formal/bin/yosys"
    sta = "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/sta"
    lib = "/opt/testharness/src/openroad-g6lc/test/Nangate45/Nangate45_typ.lib"
    abc = f"abc -liberty {lib} -D 250 -script +&get,-n;&st;&syn2;&dch,-f;&nf,-D,250;&put"
    evidence: dict = {"sources": identity, "recipe": abc, "proofs": {}, "maps": {}}
    evidence["liberty_sha256"] = hashlib.sha256(Path(lib).read_bytes()).hexdigest()

    def run(name, argv, *, timeout=600, env=None):
        log = out / f"{name}.log"
        with log.open("w") as f:
            p = subprocess.run(argv, cwd=src, stdout=f, stderr=subprocess.STDOUT,
                               timeout=timeout, env=env)
        if p.returncode:
            print(log.read_text()[-3000:], flush=True)
            raise RuntimeError(f"{name}: rc={p.returncode}")
        return log.read_text()

    def yosys(name, commands, timeout=600):
        path = out / f"{name}.ys"
        path.write_text(commands)
        return run(name, [ys, "-Q", "-T", "-s", str(path)], timeout=timeout)

    if os.environ.get("CONTROL_MODE") == "mult-pipeline":
        # Same snapshot, config, recipe and latency on both sides. Optional
        # corrected SV is tested and mapped as a third, independent variant.
        portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
        packages = [l for l in portable.splitlines()
                    if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
        variants = {"baseline": (src / "baseline/core/multiplier.sv", 3),
                    "candidate3": (src / "core/multiplier.sv", 3)}
        emitted = data / "multiplier__svt.sv"
        if emitted.exists():
            variants["emitted"] = (emitted, 3)
            evidence["sources"]["emitted"] = hashlib.sha256(emitted.read_bytes()).hexdigest()
        vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
        evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
        wrapper = out / "mul_timing.sv"
        wrapper.write_text("""
module g6lc_mul_timing
  import ariane_pkg::*;
  import config_pkg::*;
#(parameter cva6_cfg_t Base = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg)) (
  input logic clk_i, rst_ni, mult_valid_i,
  input logic [Base.TRANS_ID_BITS-1:0] trans_id_i,
  input fu_op operation_i,
  input logic [Base.XLEN-1:0] operand_a_i, operand_b_i,
  output logic [Base.XLEN-1:0] result_o,
  output logic mult_valid_o,
  output logic [Base.TRANS_ID_BITS-1:0] mult_trans_id_o
);
  function automatic cva6_cfg_t cfg();
    cfg = Base;
    cfg.MultStages = `SVT_MUL_STAGES;
  endfunction
  multiplier #(.CVA6Cfg(cfg())) dut (.*);
endmodule
""")
        timing = out / "boundary.tcl"
        board = (src / "build-platform/scripts/openroad-module-board.tcl").read_text()
        assert board.rstrip().endswith("\nexit")
        timing.write_text(
            board.rstrip()[:-len("exit")] + r"""
# Each boundary owns its own path report; do not attach the r2r trace to any_ns.
foreach kind {in_reg reg_reg reg_out in_out} {
  switch $kind {
    in_reg  {set from $ins; set to [all_registers -data_pins]}
    reg_reg {set from [all_registers -clock_pins]; set to [all_registers -data_pins]}
    reg_out {set from [all_registers -clock_pins]; set to [all_outputs]}
    in_out  {set from $ins; set to [all_outputs]}
  }
  set paths [find_timing_paths -path_delay max -path_group mclk -group_path_count 1 -sort_by_slack -from $from -to $to]
  if {[llength $paths] == 0} {continue}
  set pe [lindex $paths 0]
  set ns [expr {[$pe data_arrival_time] * 1e9}]
  puts "BOUNDARY\t$kind\t$ns"
  report_checks -path_delay max -path_group mclk -group_path_count 1 -from $from -to $to -fields {slew cap fanout} \
    > "$::env(BOUNDARY_PREFIX)-$kind.rpt"
}
""")
        for variant, (module, stages) in variants.items():
            defines = [f"+define+SVT_MUL_STAGES={stages}"]
            flist = out / f"mul-{variant}.f"
            flist.write_text("\n".join(packages + defines + [str(module), str(wrapper)]) + "\n")
            netlist = out / f"mul-{variant}.v"
            text = yosys(f"mul-map-{variant}",
                         f"read_slang -f {flist} --top g6lc_mul_timing --single-unit\n"
                         "hierarchy -check -top g6lc_mul_timing\n"
                         f"write_rtlil {out / f'{variant}-elaborated.il'}\n"
                         "proc\nflatten\nopt_clean\nwreduce\nalumacc\nopt_clean\n"
                         "memory -nomap\nmemory_map\nopt_clean\nopt_dff\nbooth\n"
                         "techmap\nopt_clean\n"
                         f"dfflibmap -liberty {lib}\n{abc}\nopt_clean -purge\n"
                         f"stat -liberty {lib}\nwrite_verilog -noattr -noexpr {netlist}\n")
            area = re.findall(r"Chip area for module .*?:\s*([\d.]+)", text)
            assert area, "missing mapped area"
            evidence["maps"][variant] = {"stages": stages, "area_um2": float(area[-1]), "boundaries": {}}
            run(f"widths-{variant}", [sys.executable, str(src / "sv-timing/tools/rtlil_width_map.py"),
                                    str(out / f"{variant}-elaborated.il"),
                                    "-o", str(out / f"{variant}-width-map.json")])
            for fanout in (0, 64):
                env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                           OR_TOP="g6lc_mul_timing", OR_PERIOD_NS="0.25",
                           OR_IGNORE_FANOUT_ABOVE=str(fanout),
                           BOUNDARY_PREFIX=str(out / f"{variant}-fanout{fanout}"))
                report = run(f"mul-sta-{variant}-{fanout}", [sta, "-exit", str(timing)], env=env)
                assert "ROW\t" in report and "link failed" not in report
                boundary = {m[0]: float(m[1]) for m in
                            re.findall(r"^BOUNDARY\t(\w+)\t([\d.eE+-]+)$", report, re.M)}
                assert "reg_reg" in boundary and "in_reg" in boundary, report[-1000:]
                evidence["maps"][variant]["boundaries"][str(fanout)] = boundary
            if os.environ.get("CONTROL_PLACE") == "1":
                env = dict(os.environ,
                           STUDY_PLATFORM=str(Path(lib).parent), OR_VERILOG=str(netlist),
                           OR_TOP="g6lc_mul_timing", STUDY_OUTPUT=str(out / f"placed-{variant}"),
                           STUDY_VARIANT=variant)
                report = run(f"place-{variant}", [
                    "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad", "-exit",
                    str(src / "build-platform/scripts/openroad-module-place-study.tcl"),
                ], env=env, timeout=900)
                row = next(l for l in report.splitlines() if l.startswith("PLACE_STUDY "))
                evidence["maps"][variant]["placement"] = dict(
                    item.split("=", 1) for item in row.split()[1:])
            simlist = out / f"sim-{variant}.f"
            simlist.write_text("\n".join(packages + [
                str(src / "vendor/pulp-platform/common_cells/src/lzc.sv"),
                str(src / "core/serdiv.sv"), str(module), str(src / "core/mult.sv"),
                str(src / "verif/tb/core/multiplier_sbs/tb_mul_sbs.sv"),
            ]) + "\n")
            for top in ("tb_mul_sbs", "tb_mul_lifetime"):
                obj = out / f"obj-{variant}-{top}"
                run(f"build-{variant}-{top}", [
                    vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
                    "-Wno-WIDTH", "-Wno-UNOPTFLAT", *defines,
                    "--top-module", top, "-f", str(simlist), "--Mdir", str(obj), "-j", "4"])
                log = run(f"sim-{variant}-{top}", [str(obj / f"V{top}"), "+seed=17", f"+lag={stages-1}"])
                assert f"PASS {top}" in log, log
                evidence["proofs"][f"{variant}-{top}"] = log.strip()
            if variant == "candidate3":
                # Surface coverage of the partial top tile and the feature-off
                # branch. Corrected SV is qualified only for its specialization.
                for label, depth, extra in [
                    ("rv32", 3, ["+define+SVT_MUL_XLEN=32"]),
                    ("no-rvb", 3, ["+define+SVT_MUL_RVB=0"]),
                    ("two-stage", 2, []),
                ]:
                    obj = out / f"obj-{label}"
                    run(f"build-{label}", [
                        vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
                        "-Wno-WIDTH", "-Wno-UNOPTFLAT", f"+define+SVT_MUL_STAGES={depth}",
                        *extra, "--top-module", "tb_mul_sbs", "-f", str(simlist),
                        "--Mdir", str(obj), "-j", "4"])
                    log = run(f"sim-{label}", [str(obj / "Vtb_mul_sbs"), "+seed=23", f"+lag={depth-1}"])
                    assert "PASS tb_mul_sbs" in log and "errors=0" in log
                    evidence["proofs"][label] = log.strip()
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print(json.dumps(evidence["maps"], indent=2), flush=True)
        return

    if os.environ.get("CONTROL_MODE") == "final-widths":
        # Widths and live specializations are elaboration facts. No gate
        # mapping is needed to refresh them after selecting the retained RTL.
        work = out / "candidate"
        work.mkdir()
        flist = (src / "portable.f").read_text().replace("@ROOT@", str(src))
        (work / "core.f").write_text(flist)
        yosys("final-elaboration",
              f"read_slang -f {work}/core.f --top cva6 --single-unit --best-effort-hierarchy\n"
              f"hierarchy -check -top cva6\nwrite_rtlil {work}/wordlevel.il\n", timeout=300)
        run("final-widths", ["python3", str(src / "sv-timing/tools/rtlil_width_map.py"),
                            str(work / "wordlevel.il"), "-o", str(work / "width-map.json")])
        evidence["width_mode"] = "elaboration-only; no timing result inferred"
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print("PASS retained-source elaboration and width extraction", flush=True)
        return

    if os.environ.get("CONTROL_MODE") == "offset-fixture":
        # Any auto-correct fixture: CONTROL_FIXTURE names the module/file
        # (default select_offsets); gold is the fixture, gate its emitted twin.
        fx = os.environ.get("CONTROL_FIXTURE", "select_offsets")
        sources = {"gold": data / f"{fx}.sv", "gate": data / f"{fx}__svt.sv"}
        commands = []
        for name, path in sources.items():
            evidence["sources"][path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
            commands += [f"read_slang --top {fx} {path}", "proc", "async2sync", "memory_map",
                         "opt_clean", f"rename {fx} {name}", f"design -stash {name}"]
        commands += ["design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                     "equiv_make gold gate equiv", "hierarchy -top equiv",
                     "equiv_simple -seq 1", "equiv_status -assert"]
        log = yosys("offset-equivalence", "\n".join(commands))
        assert "Equivalence successfully proven!" in log
        evidence["proofs"][fx] = "emitted RTL equivalence PASS"
        for name, path in sources.items():
            netlist, stats = out / f"{name}.v", out / f"{name}.stat"
            yosys(f"offset-map-{name}",
                  f"read_slang --top {fx} {path}\nproc\nasync2sync\nopt_clean\nwreduce\nalumacc\n"
                  f"booth\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
                  f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
                  f"write_verilog -noattr -noexpr {netlist}\n")
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP=fx, OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE="0")
            text = run(f"offset-sta-{name}", [sta, "-exit",
                       str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env)
            row = next(l for l in text.splitlines() if l.startswith("ROW\t"))
            evidence["maps"][name] = {"row": row,
                "area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1])}
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print(json.dumps(evidence["maps"]), flush=True)
        return

    if os.environ.get("CONTROL_MODE") in ("pipe-fixture", "pipe-representation"):
        # A123 protocol witness: the svt-pipe fixture and its emitted twin,
        # each under the latency-agnostic testbench, three seeds. The twin's
        # `pipe_contract` module is renamed so the same testbench selects it.
        vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
        evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
        representation = os.environ.get("CONTROL_MODE") == "pipe-representation"
        module = "pipe_representation" if representation else "pipe_contract"
        gold = data / f"{module}.sv"
        twin_src = data / f"{module}__svt.sv"
        tb = data / "tb_pipe_contract.sv"
        for f in (gold, twin_src, tb):
            evidence["sources"][f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
        twin = out / f"{module}_svt.sv"
        text = twin_src.read_text()
        assert text.count(f"module {module} (") == 1
        twin.write_text(text.replace(f"module {module} (", f"module {module}_svt (", 1)
                        .replace("module pipe_contract_side (", "module pipe_contract_side_svt (", 1))
        for name, srcs, defs in (("gold", [gold, tb], []), ("twin", [twin, tb], ["+define+SVT_TWIN"])):
            if representation:
                defs = defs + ["+define+SVT_REPRESENTATION"]
            obj = out / f"obj-{name}"
            run(f"pipe-build-{name}", [vl, "-O0", "--binary", "--timing", "--assert", "-Wno-fatal",
                "-Wno-WIDTH", "-Wno-UNOPTFLAT", *defs, *map(str, srcs),
                "--top-module", "tb_pipe_contract", "--Mdir", str(obj), "-j", "4"], timeout=600)
            for seed in (7, 19, 23):
                log = run(f"pipe-sim-{name}-{seed}", [str(obj / "Vtb_pipe_contract"), f"+seed={seed}"], timeout=300)
                assert "PASS" in log and "errors=0" in log, f"{name} seed {seed}"
                evidence["proofs"][f"pipe-{name}-{seed}"] = log.strip().splitlines()[-2][:200]
        if representation:
            # Discriminator: retain the data cut but read its unstaged companion.
            # Failure must be a value mismatch, not an elaboration error.
            bad = out / "misaligned.sv"
            bad_text, n = re.subn(r"assign res_d\s*=[^;]+;",
                                  "assign res_d = sum_row + carry_row;", twin.read_text())
            assert n == 1
            bad.write_text(bad_text)
            obj = out / "obj-bad"
            run("pipe-build-bad", [vl, "-O0", "--binary", "--timing", "--assert", "-Wno-fatal",
                "-Wno-WIDTH", "-Wno-UNOPTFLAT", "+define+SVT_TWIN", "+define+SVT_REPRESENTATION",
                str(bad), str(tb), "--top-module", "tb_pipe_contract", "--Mdir", str(obj), "-j", "4"])
            result = subprocess.run([str(obj / "Vtb_pipe_contract"), "+seed=7"], cwd=out,
                                    capture_output=True, text=True, timeout=300)
            (out / "pipe-bad.log").write_text(result.stdout + result.stderr)
            assert result.returncode != 0 and "value" in result.stdout and "expected" in result.stdout
            evidence["proofs"]["negative-control"] = "unstaged companion rejected by value witness"
        # mapped twin: the stage count and the data path it leaves on Nangate45
        for name, path, top in (("gold", gold, module), ("twin", twin, f"{module}_svt")):
            netlist, stats = out / f"{name}.v", out / f"{name}.stat"
            yosys(f"pipe-map-{name}",
                  f"read_slang --top {top} {path}\nproc\nasync2sync\nopt_clean\nwreduce\nalumacc\n"
                  f"booth\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
                  f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
                  f"write_verilog -noattr -noexpr {netlist}\n")
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP=top, OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE="0")
            text = run(f"pipe-sta-{name}", [sta, "-exit",
                       str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env)
            row = next(l for l in text.splitlines() if l.startswith("ROW\t"))
            evidence["maps"][name] = {"row": row,
                "area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1])}
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print(json.dumps(evidence["maps"]), flush=True)
        return

    if os.environ.get("CONTROL_MODE") == "mult-svt":
        # A125: the emitted multiplier (its gen_two_stage branch carries the
        # third stage) against the one-stage reference two cycles later, on
        # the stock tool, three seeds; then both mapped on Nangate45.
        portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
        packages = [l for l in portable.splitlines()
                    if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
        vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
        evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
        twin = data / "multiplier__svt.sv"
        evidence["sources"]["multiplier__svt.sv"] = hashlib.sha256(twin.read_bytes()).hexdigest()
        for variant, mult_src, lag in (("stock", src / "core/multiplier.sv", 1), ("svt", twin, 2)):
            flist = out / f"mul-{variant}.f"
            flist.write_text("\n".join(packages + [
                str(src / "vendor/pulp-platform/common_cells/src/lzc.sv"),
                str(mult_src),
                str(src / "verif/tb/core/multiplier_sbs/tb_mul_sbs.sv"),
            ]) + "\n")
            obj = out / f"obj-{variant}"
            run(f"mul-build-{variant}",
                [vl, "-O0", "--binary", "--timing", "--assert", "-Wno-fatal", "-Wno-WIDTH",
                 "-Wno-UNOPTFLAT", "--top-module", "tb_mul_sbs", "-f", str(flist),
                 "--Mdir", str(obj), "-j", "4"], timeout=900)
            for seed in (1, 17, 23):
                log = run(f"mul-sbs-{variant}-{seed}", [str(obj / "Vtb_mul_sbs"), f"+seed={seed}", f"+lag={lag}"], timeout=600)
                assert "PASS" in log and "errors=0" in log, f"{variant} seed {seed}"
                evidence["proofs"][f"mul-{variant}-{seed}"] = log.strip().splitlines()[-2][:200]
        # the standalone module takes its CVA6Cfg from the elaborating top:
        # the mapped reading comes from the full sta-rtl route, not here
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print(json.dumps(evidence["proofs"]), flush=True)
        return

    if os.environ.get("CONTROL_MODE") == "precompute-leaf":
        vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
        evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
        portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
        packages = [l for l in portable.splitlines()
                    if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
        old = (src / "baseline/core/store_buffer.sv").read_text()
        assert old.count("module store_buffer\n") == 1
        golden = out / "store_buffer_old.sv"
        golden.write_text(old.replace("module store_buffer\n", "module store_buffer_old\n", 1))
        harness = data / "store_buffer_sbs"
        for p in harness.glob("*.sv"):
            evidence["sources"][p.name] = hashlib.sha256(p.read_bytes()).hexdigest()
        flist = out / "store.f"
        flist.write_text("\n".join(packages + [
            str(src / "core/store_buffer.sv"), str(golden),
            str(harness / "wrap.sv"), str(harness / "tb_sb_sbs.sv")]) + "\n")
        obj = out / "obj-store"
        run("store-build", [vl, "-O0", "--binary", "--timing", "--assert",
            "-Wno-fatal", "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-f", str(flist),
            "--top-module", "tb_sb_sbs", "--Mdir", str(obj), "-j", "4"], timeout=600)
        log = run("store-sbs", [str(obj / "Vtb_sb_sbs"), "+seed=17"], timeout=180)
        assert "PASS" in log and "errors=0" in log
        evidence["proofs"]["store-sbs"] = log
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print(log, flush=True)
        return

    if os.environ.get("CONTROL_MODE") == "placed-iq":
        reference = Path(os.environ["CONTROL_REFERENCE"])
        paired = json.loads((reference / "result.json").read_text())
        study = data / "openroad-module-place-study.tcl"
        platform = Path("/opt/testharness/src/openroad-g6lc/test/Nangate45")
        binary = "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad"
        evidence["openroad_version"] = subprocess.check_output([binary, "-version"], text=True).strip()
        evidence["placement_script_sha256"] = hashlib.sha256(study.read_bytes()).hexdigest()
        evidence["placement_inputs"] = {}
        module = os.environ.get("CONTROL_MODULE", "g6lc_iq")
        if module not in {"g6lc_iq", "g6lc_rename", "store_buffer", "instr_realign"}:
            raise ValueError(f"unsupported standalone placement module: {module}")
        evidence["placement_module"] = module
        for variant in ("baseline", "candidate"):
            names = [n for n in paired["maps"][variant] if n.split("$")[0] == module]
            assert len(names) == 1
            top = names[0]
            entries = (reference / variant / "il/modules.tsv").read_text().splitlines()
            entry = next(l.split("\t") for l in entries if l.split("\t")[2].lstrip("\\") == top)
            netlist = reference / variant / Path(entry[1]).with_suffix(".v")
            evidence["placement_inputs"][variant] = hashlib.sha256(netlist.read_bytes()).hexdigest()
            env = dict(os.environ, STUDY_PLATFORM=str(platform), OR_TOP=top,
                       OR_VERILOG=str(netlist), STUDY_OUTPUT=str(out / variant),
                       STUDY_VARIANT=variant)
            command = [binary, "-no_init", "-exit", str(study)]
            if os.environ.get("PLACEMENT_GDB") == "1":
                command = ["gdb", "--batch", "-ex", "run", "-ex", "bt", "--args", *command]
            log = run(f"placed-{variant}", command,
                      timeout=900, env=env)
            row = next((l for l in log.splitlines() if l.startswith("PLACE_STUDY ")), None)
            if not row:
                raise RuntimeError(f"{variant}: placement did not complete")
            evidence["maps"][variant] = dict(re.findall(r"(\w+)=(\S+)", row))
            (out / "result.json").write_text(json.dumps(evidence, indent=2))
            print(row, flush=True)
        return

    if (src / "review.json").exists():
        review = json.loads((src / "review.json").read_text())
        if review["profile"] == "sbhead" and not os.environ.get("CONTROL_MODE"):
            review_sbhead(src, out, evidence, yosys)
            (out / "result.json").write_text(json.dumps(evidence, indent=2))
            return
        if review["profile"] == "step1" and not os.environ.get("CONTROL_MODE"):
            review_step1(src, out, sta, lib, abc, evidence, yosys, run)
            (out / "result.json").write_text(json.dumps(evidence, indent=2))
            return
        if review["profile"] == "stq" and not os.environ.get("CONTROL_MODE"):
            review_stq(src, out, sta, lib, abc, evidence, yosys, run)
            (out / "result.json").write_text(json.dumps(evidence, indent=2))
            return
        if review["profile"] == "ckpt" and not os.environ.get("CONTROL_MODE"):
            review_ckpt(src, out, sta, lib, abc, evidence, yosys, run)
            (out / "result.json").write_text(json.dumps(evidence, indent=2))
            return
        if review["profile"] == "lbuf" and not os.environ.get("CONTROL_MODE"):
            if os.environ.get("A136_ONLY") != "rob":
                review_lbuf(src, out, sta, lib, abc, evidence, yosys, run)
            review_rob(src, out, sta, lib, abc, evidence, yosys, run)
            (out / "result.json").write_text(json.dumps(evidence, indent=2))
            return
        if review["profile"] == "loop-emit" and not os.environ.get("CONTROL_MODE"):
            review_loop_emit(src, out, data, sta, lib, abc, evidence, yosys, run)
            (out / "result.json").write_text(json.dumps(evidence, indent=2))
            return
        if review["profile"] == "statcor" and not os.environ.get("CONTROL_MODE"):
            review_statcor(src, out, sta, lib, abc, evidence, yosys, run)
            (out / "result.json").write_text(json.dumps(evidence, indent=2))
            return
        if review["profile"] == "boundary" and os.environ.get("CONTROL_MODE") in (None, "boundary-surface"):
            if os.environ.get("CONTROL_MODE") == "boundary-surface":
                prove_boundary_surface(src, out, evidence, yosys, run)
                (out / "result.json").write_text(json.dumps(evidence, indent=2))
                return
            map_snapshots(src, out, sta, lib, abc, evidence, yosys, run,
                          changed=review["changed_files"], modules=set(review["modules"]))
            return
        if review["profile"] == "precompute" and not os.environ.get("CONTROL_MODE"):
            prove_precompute(src, out, yosys, evidence)
            map_snapshots(src, out, sta, lib, abc, evidence, yosys, run,
                          changed=review["changed_files"], modules=set(review["modules"]))
            return
        if review["profile"] == "selection" and os.environ.get("CONTROL_MODE", "selection") in (
            "selection", "selection-leaf"
        ):
            if os.environ.get("CONTROL_MODE") == "selection-leaf":
                vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
                evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
                packages = ["core/include/config_pkg.sv", "core/include/g6lc64_ooo_config_pkg.sv",
                            "core/include/riscv_pkg.sv", "core/include/ariane_pkg.sv",
                            "core/ooo/g6lc_ooo_pkg.sv"]
                for top, dut, verdict in (
                    ("tb_g6lc_lsq", "core/ooo/g6lc_lsq.sv", "LSQ_HART_PASS"),
                    ("tb_g6lc_iq_store_age", "core/ooo/g6lc_iq.sv", "PASS tb_g6lc_iq_store_age"),
                ):
                    bench = data / f"{top}.sv"
                    evidence["sources"][bench.name] = hashlib.sha256(bench.read_bytes()).hexdigest()
                    obj = out / top
                    run(top + "-build", [vl, "-O0", "--binary", "--timing", "--assert",
                        "-Wno-fatal", "-Wno-WIDTH", "-Wno-UNOPTFLAT",
                        "-I" + str(src / "core/include"), "--top-module", top,
                        *[str(src / p) for p in packages], str(src / dut), str(bench),
                        "--Mdir", str(obj), "-j", "4"])
                    log = run(top, [str(obj / ("V" + top))], timeout=60)
                    assert verdict in log
                    negative = subprocess.run([str(obj / ("V" + top)), "+oracle_negative"],
                        cwd=out, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        timeout=60)
                    (out / (top + "-negative.log")).write_text(negative.stdout)
                    assert negative.returncode != 0 and (
                        "LSQ_" in negative.stdout if top == "tb_g6lc_lsq" else
                        "IQ_ST_AGE" in negative.stdout or "ORACLE_NEGATIVE" in negative.stdout)
                    evidence["proofs"][top] = "directed PASS; oracle-negative detected"
                (out / "result.json").write_text(json.dumps(evidence, indent=2))
                print("PASS selection leaf checks and negative controls", flush=True)
                return
            prove_selections(src, out, yosys, evidence)
            map_snapshots(src, out, sta, lib, abc, evidence, yosys, run,
                          changed=review["changed_files"], modules=set(review["modules"]))
            return

    if os.environ.get("CONTROL_MODE") == "source-elab":
        # the snapshot's own tree (no emit): whole-core slang elaboration
        portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
        flist = out / "source.f"
        flist.write_text(portable + "\n")
        yosys("source-elaboration",
              f"read_slang -f {flist} --top cva6 --single-unit --best-effort-hierarchy\n"
              "hierarchy -check -top cva6\n", timeout=300)
        evidence["source_elaboration"] = "PASS"
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print("PASS source whole-core elaboration", flush=True)
        return

    if os.environ.get("CONTROL_MODE") == "emit-elab":
        portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
        emitted = data / "review-corrected"
        lines = [l for l in portable.splitlines() if l.startswith("+")]
        for line in (emitted / "svt_corrected.f").read_text().splitlines():
            line = line.strip()
            if line and not line.startswith(("#", "+", "-")):
                lines.append(str(emitted / line))
        flist = out / "emitted.f"
        flist.write_text("\n".join(lines) + "\n")
        yosys("emitted-elaboration",
              f"read_slang -f {flist} --top cva6 --single-unit --best-effort-hierarchy\n"
              "hierarchy -check -top cva6\n", timeout=300)
        evidence["emitted_elaboration"] = "PASS (not mapped timing or equivalence)"
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print("PASS emitted whole-core elaboration", flush=True)
        return

    if os.environ.get("CONTROL_MODE") == "lifetime":
        portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
        packages = [l for l in portable.splitlines()
                    if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
        vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
        evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
        for variant, module in (("candidate", "core/mult.sv"),
                                ("baseline", "baseline/core/mult.sv")):
            flist = out / f"mul-{variant}.f"
            flist.write_text("\n".join(packages + [
                str(src / "vendor/pulp-platform/common_cells/src/lzc.sv"),
                str(src / "core/serdiv.sv"), str(src / "core/multiplier.sv"),
                str(src / module),
                str(src / "verif/tb/core/multiplier_sbs/tb_mul_sbs.sv"),
            ]) + "\n")
            obj = out / f"obj-{variant}"
            run(f"mul-build-{variant}",
                # Use the stock tool for this semantic witness. The A fork
                # failed the fixture's stimulus check before observing DUT
                # behavior. Keep the failing RTL baseline as an oracle check.
                [vl, "-O0", "--binary", "--timing", "--assert", "-Wno-fatal", "-Wno-WIDTH",
                 "-Wno-UNOPTFLAT", "--top-module", "tb_mul_lifetime", "-f", str(flist),
                 "--Mdir", str(obj), "-j", "4"], timeout=600)
            result = subprocess.run([str(obj / "Vtb_mul_lifetime")], cwd=out,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=60)
            (out / f"mul-{variant}.log").write_text(result.stdout)
            if variant == "candidate":
                assert result.returncode == 0 and "PASS tb_mul_lifetime" in result.stdout
            else:
                assert result.returncode != 0 and "MUL_LIFETIME step=5 valid=1 tid=3" in result.stdout
            evidence["proofs"][variant] = {"rc": result.returncode, "output": result.stdout}
        obj = out / "obj-arithmetic"
        run("mul-build-arithmetic",
            [vl, "-O0", "--binary", "--timing", "--assert", "-Wno-fatal", "-Wno-WIDTH",
             "-Wno-UNOPTFLAT", "--top-module", "tb_mul_sbs",
             "-f", str(out / "mul-candidate.f"), "--Mdir", str(obj), "-j", "4"])
        arithmetic = run("mul-arithmetic", [str(obj / "Vtb_mul_sbs"), "+seed=17"])
        assert "PASS tb_mul_sbs" in arithmetic and "errors=0" in arithmetic
        evidence["proofs"]["arithmetic"] = arithmetic
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print("PASS multiplier lifetime, baseline defect reproduced", flush=True)
        return

    # Prove the actual new age helper against the previous masked distance.
    # All 32-bit inputs are unconstrained, including their unused upper bits.
    for width in (0, 1, 5, 6, 32):
        fixture = out / f"age-{width}.sv"
        fixture.write_text(f"""
module age_eq(input logic [31:0] a, b, cp, output logic ok);
  localparam logic [31:0] MASK = (32'd1 << {width}) - 32'd1;
  assign ok = g6lc_ooo_pkg::ooo_age_older({width}, a, b, cp) ==
              (((a-cp) & MASK) < ((b-cp) & MASK));
endmodule
""")
        log = yosys(f"age-{width}",
                    f"read_slang --top age_eq core/include/config_pkg.sv "
                    f"core/ooo/g6lc_ooo_pkg.sv {fixture}\nprep -top age_eq\n"
                    "flatten\nsat -prove ok 1 -verify\n")
        assert "SUCCESS!" in log
        evidence["proofs"][f"age-{width}"] = "combinational SAT PASS"

    # Compile the changed predecessor loop itself, and the former position
    # builder/comparison loop, in a small combinational proof. Keep bits
    # outside the live window are masked just as in the production queue.
    gold = (src / "baseline/core/store_buffer.sv").read_text()
    gate = (src / "core/store_buffer.sv").read_text()
    pos = gold[gold.index("        // position after the insertion:"):
               gold.index("        // keep verdict per entry:")]
    old_rank = gold[gold.index("        // final slot = kept entries placed"):
                    gold.index("        live = ($clog2(DEPTH_SPEC) + 1)'($countones(keep));")]
    new_rank = gate[gate.index("        // Direct predecessor relation"):
                    gate.index("        live = ($clog2(DEPTH_SPEC) + 1)'($countones(keep));")]
    for depth in (4, 8, 16):
        fixture = out / f"rank-{depth}.sv"
        prefix = f"""
module rank_eq(input logic [4:0] nlive, nins, input logic ins_active,
               input logic [{depth-1}:0] keep_i, output logic ok);
  localparam int DEPTH_SPEC={depth};
  logic [DEPTH_SPEC-1:0] keep;
  logic [$clog2(DEPTH_SPEC):0] ins;
  logic [DEPTH_SPEC-1:0][$clog2(DEPTH_SPEC):0] pos_ins, old_slot, new_slot;
  assign ins = ($clog2(DEPTH_SPEC)+1)'(nins);
  for (genvar k=0;k<DEPTH_SPEC;k++) assign keep[k]=keep_i[k] && k<nlive;
  always_comb begin
"""
        suffix = """
  end
  assign ok = (nlive > DEPTH_SPEC || nins >= nlive) ||
              (old_slot == new_slot);
endmodule
"""
        fixture.write_text(prefix + pos + old_rank.replace("final_slot", "old_slot")
                           + new_rank.replace("final_slot", "new_slot") + suffix)
        log = yosys(f"rank-{depth}", f"read_slang --top rank_eq {fixture}\n"
                    "prep -top rank_eq\nflatten\nsat -prove ok 1 -verify\n")
        assert "SUCCESS!" in log
        evidence["proofs"][f"rank-{depth}"] = "extracted-source SAT PASS"
    for width in (32, 64):
        fixture = out / f"equality-{width}.sv"
        fixture.write_text(f"""
module equality_eq(input logic [{width-1}:0] a, b, output logic ok);
  logic [{width+1}:0] extended;
  assign extended = {{a, 1'b1}} + ({{b, 1'b0}} ^ {{{width+1}{{1'b1}}}});
  assign ok = (~|extended[{width}:1]) == (a==b);
endmodule
""")
        log = yosys(f"equality-{width}", f"read_slang --top equality_eq {fixture}\n"
                    "prep -top equality_eq\nflatten\nsat -prove ok 1 -verify\n")
        assert "SUCCESS!" in log
        evidence["proofs"][f"equality-{width}"] = "subtraction-zero SAT PASS"
        fixture = out / f"target-{width}.sv"
        fixture.write_text(f"""
module target_eq(input logic [{width-1}:0] base, off, rvi, rvc,
                 input logic taken_rvc, output logic ok);
  logic [{width-1}:0] old_target, rvi_target, rvc_target, new_target;
  assign old_target = base + off + (taken_rvc ? rvc : rvi);
  assign rvi_target = base + off + rvi;
  assign rvc_target = base + off + rvc;
  assign new_target = taken_rvc ? rvc_target : rvi_target;
  assign ok = old_target == new_target;
endmodule
""")
        log = yosys(f"target-{width}", f"read_slang --top target_eq {fixture}\n"
                    "prep -top target_eq\nflatten\nsat -prove ok 1 -verify\n")
        assert "SUCCESS!" in log
        evidence["proofs"][f"target-{width}"] = "selected-target SAT PASS"

    # Rename: match state by name, then prove the changed read cones. Both
    # designs share arbitrary matched state; this is not only reset testing.
    for harts in (1, 2):
        entries = 40 if harts == 1 else 80
        tag_width = (entries-1).bit_length()
        commands = []
        for variant, source in (("gold", "baseline/core/ooo/g6lc_rename.sv"),
                                ("gate", "core/ooo/g6lc_rename.sv")):
            commands += [
                f"read_slang --top g6lc_rename -G NR_HARTS={harts} "
                f"-G PRF_ENTRIES={entries} -G FPRF_ENTRIES={entries} "
                f"-G PRF_W={tag_width} -G FPRF_W={tag_width} -G CKPT_DEPTH=4 "
                f"--ignore-assertions {source}",
                "proc", "memory_map", "async2sync", "opt_clean",
                f"rename g6lc_rename {variant}", f"design -stash {variant}",
            ]
        commands += ["design -copy-from gold -as gold gold",
                     "design -copy-from gate -as gate gate",
                     "equiv_make gold gate equiv", "hierarchy -top equiv",
                     "equiv_simple -seq 1", "equiv_status -assert"]
        log = yosys(f"rename-{harts}", "\n".join(commands), timeout=600)
        assert "Equivalence successfully proven!" in log
        evidence["proofs"][f"rename-{harts}h"] = "matched-state equivalence PASS"
    print("PROOFS " + json.dumps(evidence["proofs"]), flush=True)
    map_snapshots(src, out, sta, lib, abc, evidence, yosys, run)


def review_lbuf(src, out, sta, lib, abc, evidence, yosys, run):
    """Loop buffer: registered expectation addresses vs the baseline source.
    Side-by-side cycle-exact witness (with the new module's own invariant
    assertions on), a bounded output miter from reset, and paired mapping /
    placement of the shipped geometry."""
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    packages = [l for l in portable.splitlines()
                if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
    bench = src / "verif/tb/core/tb_g6lc_loop_buffer_sbs.sv"
    old = (src / "baseline/core/frontend/g6lc_loop_buffer.sv").read_text()
    assert old.count("module g6lc_loop_buffer\n") == 1
    golden = out / "g6lc_loop_buffer_old.sv"
    golden.write_text(old.replace("module g6lc_loop_buffer\n", "module g6lc_loop_buffer_old\n", 1))
    vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
    evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
    flist = out / "lbuf-sbs.f"
    flist.write_text("\n".join(packages + [str(src / "core/frontend/g6lc_loop_buffer.sv"),
                                           str(golden), str(bench)]) + "\n")
    for label, defs in (("8x64", []), ("4x32", ["-GENTRIES=4", "-GDATA_W=32", "-GALIGN=2"]),
                        ("6x128", ["-GENTRIES=6", "-GDATA_W=128", "-GALIGN=4"])):
        obj = out / f"obj-lbuf-{label}"
        run(f"lbuf-build-{label}", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
            "-Wno-WIDTH", "-Wno-UNOPTFLAT", *defs, "-f", str(flist),
            "--top-module", "tb_g6lc_loop_buffer_sbs", "--Mdir", str(obj), "-j", "4"], timeout=600)
        for seed in (1, 17):
            log = run(f"lbuf-sbs-{label}-{seed}", [str(obj / "Vtb_g6lc_loop_buffer_sbs"), f"+seed={seed}"], timeout=300)
            assert "PASS tb_g6lc_loop_buffer_sbs" in log and "errors=0" in log, log[-800:]
            assert "%Error" not in log and "lost the" not in log
            evidence["proofs"][f"lbuf-sbs-{label}-{seed}"] = next(
                l for l in log.splitlines() if "PASS tb_g6lc_loop_buffer_sbs" in l)
    # Bounded miter from reset on the shipped geometry: both variants driven
    # by the same free inputs; outputs must agree for every reachable prefix.
    miter = out / "lbuf_miter.sv"
    miter.write_text("""
module lbuf_miter import ariane_pkg::*; (
  input logic clk_i, rst_ni, flush_i, enable_i, cf_valid_i, cf_taken_i, fill_valid_i, lookup_ready_i,
  input logic [63:0] cf_pc_i, cf_target_i, fill_vaddr_i, lookup_vaddr_i,
  input logic [63:0] fill_data_i,
  output logic ok);
  function automatic config_pkg::cva6_cfg_t cfg();
    cfg = config_pkg::cva6_cfg_empty; cfg.XLEN = 64; cfg.VLEN = 64;
    cfg.FETCH_WIDTH = 64; cfg.FETCH_ALIGN_BITS = 3;
  endfunction
  logic ho, hn, ao, an, co, cn; logic [63:0] dato, datn;
  g6lc_loop_buffer_old #(.CVA6Cfg(cfg()), .NR_ENTRIES(8), .DATA_W(64)) a (.*, .hit_o(ho), .data_o(dato), .active_o(ao), .consume_o(co));
  g6lc_loop_buffer     #(.CVA6Cfg(cfg()), .NR_ENTRIES(8), .DATA_W(64)) b (.*, .hit_o(hn), .data_o(datn), .active_o(an), .consume_o(cn));
  assign ok = (ho == hn) && (ao == an) && (co == cn) && (!ho || dato == datn);
endmodule
""")
    mflist = out / "lbuf-miter.f"
    mflist.write_text("\n".join(packages + [str(src / "core/frontend/g6lc_loop_buffer.sv"),
                                            str(golden), str(miter)]) + "\n")
    # A 12-step bound exceeded 25 minutes on the shipped widths (1.4 M
    # variables). Use a short bound with a hard time limit; a timeout is
    # recorded as inconclusive, never as a pass.
    script = out / "lbuf-miter.ys"
    script.write_text(f"read_slang -f {mflist} --top lbuf_miter --single-unit --ignore-assertions\n"
                      "hierarchy -top lbuf_miter\nproc\nflatten\nasync2sync\nopt_clean\n"
                      "sat -seq 6 -set-init-zero -set rst_ni 1 -prove ok 1 -verify\n")
    ys = "/opt/testharness/toolchains/formal/bin/yosys"
    try:
        res = subprocess.run([ys, "-Q", "-T", "-s", str(script)], cwd=src, capture_output=True,
                             text=True, timeout=600)
        (out / "lbuf-miter.log").write_text(res.stdout + res.stderr)
        if res.returncode == 0 and "SUCCESS!" in res.stdout:
            evidence["proofs"]["lbuf-miter-6"] = "6-step output miter from reset PASS"
        else:
            assert "FAIL!" not in res.stdout, res.stdout[-1500:]
            evidence["proofs"]["lbuf-miter-6"] = "INCONCLUSIVE (solver did not finish)"
    except subprocess.TimeoutExpired as e:
        (out / "lbuf-miter.log").write_text(str(e.stdout or "") + "\nTIMEOUT")
        evidence["proofs"]["lbuf-miter-6"] = "INCONCLUSIVE (600 s timeout)"
    for variant, path in (("baseline", src / "baseline/core/frontend/g6lc_loop_buffer.sv"),
                          ("candidate", src / "core/frontend/g6lc_loop_buffer.sv")):
        vflist = out / f"lbuf-{variant}.f"
        vflist.write_text("\n".join(packages + [str(path), str(bench)]) + "\n")
        netlist, stats = out / f"{variant}.v", out / f"{variant}.stat"
        yosys("lbuf-map-" + variant,
              f"read_slang -f {vflist} --top g6lc_lbuf_timing --single-unit\n"
              "proc\nflatten\nopt_clean\nwreduce\nalumacc\nopt_clean\nmemory_map\n"
              f"opt_dff\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
              f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
              f"write_verilog -noattr -noexpr {netlist}\n")
        evidence["maps"][variant] = {
            "area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1]),
            "board": {},
        }
        for fan in (0, 64):
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP="g6lc_lbuf_timing", OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE=str(fan))
            text = run(f"lbuf-sta-{variant}-{fan}", [sta, "-exit",
                str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env)
            row = next(l for l in text.splitlines() if l.startswith("ROW\t"))
            assert "failed" not in row
            evidence["maps"][variant]["board"][str(fan)] = row
        env = dict(os.environ, STUDY_PLATFORM=str(Path(lib).parent),
                   OR_VERILOG=str(netlist), OR_TOP="g6lc_lbuf_timing",
                   STUDY_OUTPUT=str(out / variant), STUDY_VARIANT=variant)
        text = run("lbuf-place-" + variant, [
            "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad", "-exit",
            str(src / "build-platform/scripts/openroad-module-place-study.tcl")], env=env, timeout=900)
        row = next(l for l in text.splitlines() if l.startswith("PLACE_STUDY "))
        evidence["maps"][variant]["placement"] = dict(re.findall(r"(\w+)=(\S+)", row))
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence["maps"], indent=2), flush=True)


def pair_module(src, out, sta, lib, abc, evidence, yosys, run, key, top, flists, place_timeout=900):
    """Map, module-board and placement study of a baseline/candidate pair."""
    for variant, flist in flists.items():
        netlist, stats = out / f"{key}-{variant}.v", out / f"{key}-{variant}.stat"
        yosys(f"{key}-map-{variant}",
              f"read_slang -f {flist} --top {top} --single-unit\n"
              "proc\nflatten\nopt_clean\nwreduce\nalumacc\nopt_clean\nmemory_map\n"
              f"opt_dff\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
              f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
              f"write_verilog -noattr -noexpr {netlist}\n", timeout=3600)
        entry = {"area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1]),
                 "board": {}}
        for fan in (0, 64):
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP=top, OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE=str(fan))
            text = run(f"{key}-sta-{variant}-{fan}", [sta, "-exit",
                str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env, timeout=1800)
            row = next(l for l in text.splitlines() if l.startswith("ROW\t"))
            assert "failed" not in row
            entry["board"][str(fan)] = row
        env = dict(os.environ, STUDY_PLATFORM=str(Path(lib).parent),
                   OR_VERILOG=str(netlist), OR_TOP=top,
                   STUDY_OUTPUT=str(out / f"{key}-{variant}"), STUDY_VARIANT=f"{key}-{variant}")
        text = run(f"{key}-place-{variant}", [
            "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad", "-exit",
            str(src / "build-platform/scripts/openroad-module-place-study.tcl")], env=env, timeout=place_timeout)
        row = next(l for l in text.splitlines() if l.startswith("PLACE_STUDY "))
        entry["placement"] = dict(re.findall(r"(\w+)=(\S+)", row))
        evidence["maps"][f"{key}-{variant}"] = entry
        (out / "result.json").write_text(json.dumps(evidence, indent=2))


def review_sbhead(src, out, evidence, yosys):
    """A140: the scoreboard's per-hart head scan in absolute slot order vs the
    previous rotated form, extracted by text into standalone modules and
    proven combinationally equivalent (slot, validity, PC) by SAT."""
    live = (src / "core/scoreboard.sv").read_text()
    base = (src / "baseline/core/scoreboard.sv").read_text()

    def block(text):
        a = text.index("  always_comb begin : sb_head_scan\n")
        b = text.index("\n  end\n", a) + len("\n  end\n")
        return text[a:b]
    subs = [("CVA6Cfg.NR_SB_ENTRIES", "N"), ("CVA6Cfg.TRANS_ID_BITS", "TW"), ("CVA6Cfg.VLEN", "64"),
            ("SB_NH", "NH")]
    old_block, new_block = block(base), block(live)
    for a, b in subs:
        old_block = old_block.replace(a, b)
        new_block = new_block.replace(a, b)
    pkg = ("package sbhead_pkg;\n  typedef struct packed { logic [1:0] hart_id; logic [63:0] pc; } sbe_t;\n"
           "  typedef struct packed { logic issued; sbe_t sbe; } sb_entry_t;\nendpackage\n")
    header = ("import sbhead_pkg::*; #(parameter int unsigned N = 32, parameter int unsigned TW = 5,"
              " parameter int unsigned NH = 2) (\n"
              "  input sb_entry_t [N-1:0] mem_q, input logic [0:0][TW-1:0] commit_pointer_q,\n"
              "  output logic [NH-1:0] sb_head_valid_o, output logic [NH-1:0][63:0] sb_head_pc_o,\n"
              "  output logic [NH-1:0][TW-1:0] head_slot_o, output logic [NH-1:0] head_valid);\n"
              "  logic [NH-1:0][TW-1:0] head_slot;\n")
    # head_slot is consumed only under head_valid in scoreboard.sv (priv[h],
    # hdist[h], the port-1 search), so the slot is compared under that guard;
    # the rotated form left the pointer there, the absolute form leaves zero.
    footer = ("  for (genvar h = 0; h < NH; h++) begin : gen_mask\n"
              "    assign head_slot_o[h] = head_valid[h] ? head_slot[h] : '0;\n  end\nendmodule\n")
    (out / "sbhead.sv").write_text(pkg + "module sbhead_old " + header + old_block + footer +
                                   "module sbhead_new " + header + new_block + footer)
    evidence["sources"]["sbhead.sv"] = hashlib.sha256((out / "sbhead.sv").read_bytes()).hexdigest()
    for n, tw, nh in ((32, 5, 2), (16, 4, 1), (8, 3, 2), (64, 6, 4), (32, 5, 1)):
        key = f"sbhead-eq-{n}-{tw}-{nh}"
        text = yosys(key,
                     f"read_slang {out}/sbhead.sv --top sbhead_old --top sbhead_new "
                     f"-G N={n} -G TW={tw} -G NH={nh}\nproc\n"
                     "miter -equiv -flatten -make_assert sbhead_old sbhead_new m\n"
                     "hierarchy -top m\nsat -verify -prove-asserts m\n", timeout=1800)
        assert "SUCCESS!" in text, text[-1500:]
        evidence["proofs"][key] = "combinational equivalence of the head scan (slot, valid, pc) PASS"


def review_step1(src, out, sta, lib, abc, evidence, yosys, run):
    """A140 step-1 (latency-neutral) RTL: the D$ per-byte forwarding tree,
    the loop predictor's row-local training and the loop buffer's bounded
    address add. Equivalence per change, then paired mapping / placement."""
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    packages = [l for l in portable.splitlines()
                if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
    vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
    evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()

    # ---- 1. D$ forwarding merge: the live block, tied by text to a standalone
    # module, against the previous serial scan from the baseline file.
    live = (src / "core/cache_subsystem/wt_dcache_mem.sv").read_text()
    base = (src / "baseline/core/cache_subsystem/wt_dcache_mem.sv").read_text()
    new_block = live[live.index("  typedef struct packed {\n    logic       v;"):
                     live.index("`endif\n  // Complete-word forward")]
    old_block = base[base.index("  logic [(CVA6Cfg.XLEN/8)-1:0][$clog2(WbufferAllDepth+1)-1:0] wbuffer_sel;"):
                     base.index("`endif\n  // Complete-word forward")]
    subs = [("CVA6Cfg.XLEN / 8", "B"), ("CVA6Cfg.XLEN/8", "B"), ("WbufferAllDepth", "D"),
            ("CVA6Cfg.DCACHE_USER_WIDTH / 8", "U"), ("CVA6Cfg.DCACHE_USER_WIDTH", "(8*U)"),
            ("wbuffer_hit_oh", "hit_i"), ("wbuffer_all[e].valid", "valid_i[e]"),
            ("wbuffer_all[e].data", "data_i[e]"), ("wbuffer_all[e].user", "user_i[e]"),
            ("wbuffer_all[wbuffer_sel[k]].user", "user_i[wbuffer_sel[k]]"),
            ("wbuffer_be", "be_o"), ("wbuffer_rdata", "rdata_o"), ("wbuffer_ruser", "ruser_o")]
    for a, b in subs:
        new_block = new_block.replace(a, b)
        old_block = old_block.replace(a, b)
    header = ("#(parameter int unsigned D = 16, parameter int unsigned B = 8, parameter int unsigned U = 8) (\n"
              "  input logic [D-1:0] hit_i, input logic [D-1:0][B-1:0] valid_i,\n"
              "  input logic [D-1:0][8*B-1:0] data_i, input logic [D-1:0][8*U-1:0] user_i,\n"
              "  output logic [B-1:0] be_o, output logic [8*B-1:0] rdata_o, output logic [8*U-1:0] ruser_o);\n")
    (out / "fwd_merge.sv").write_text(
        "module fwd_merge_old " + header + old_block + "endmodule\n"
        "module fwd_merge_new " + header + new_block + "endmodule\n")
    evidence["sources"]["fwd_merge.sv"] = hashlib.sha256((out / "fwd_merge.sv").read_bytes()).hexdigest()
    for d, b, u in ((16, 8, 8), (8, 8, 4), (4, 4, 1), (2, 8, 8), (1, 8, 8)):
        key = f"dmem-fwd-eq-{d}-{b}-{u}"
        text = yosys(key,
                     f"read_slang {out}/fwd_merge.sv --top fwd_merge_old --top fwd_merge_new "
                     f"-G D={d} -G B={b} -G U={u}\nproc\n"
                     "miter -equiv -flatten -make_assert fwd_merge_old fwd_merge_new m\n"
                     "hierarchy -top m\nsat -verify -prove-asserts m\n", timeout=900)
        assert "SUCCESS!" in text, text[-1500:]
        evidence["proofs"][key] = "combinational equivalence of the per-byte merge PASS"
    # paired module timing of wt_dcache_mem through a wrapper giving it the
    # OoO configuration's wbuffer_t (as wt_dcache.sv does)
    ports = live[live.index("    input logic clk_i,"):live.index(");\n", live.index("    input logic clk_i,"))]
    wrapper = out / "dmem_timing.sv"
    wrapper.write_text("""
module g6lc_dmem_timing
  import ariane_pkg::*;
  import wt_cache_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg),
    localparam int unsigned NumPorts = 3,
    localparam DCACHE_CL_IDX_WIDTH = $clog2(CVA6Cfg.DCACHE_NUM_WORDS),
    localparam type wbuffer_t = struct packed {
      logic [CVA6Cfg.DCACHE_TAG_WIDTH+(CVA6Cfg.DCACHE_INDEX_WIDTH-CVA6Cfg.XLEN_ALIGN_BYTES)-1:0] wtag;
      logic [CVA6Cfg.XLEN-1:0] data;
      logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] user;
      logic [(CVA6Cfg.XLEN/8)-1:0] dirty;
      logic [(CVA6Cfg.XLEN/8)-1:0] valid;
      logic [(CVA6Cfg.XLEN/8)-1:0] txblock;
      logic checked;
      logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] hit_oh;
    }
) (
""" + ports + """);
  wt_dcache_mem #(.CVA6Cfg(CVA6Cfg), .DCACHE_CL_IDX_WIDTH(DCACHE_CL_IDX_WIDTH), .wbuffer_t(wbuffer_t), .NumPorts(NumPorts)) u (.*);
endmodule
""")
    common = [str(src / n) for n in ("vendor/pulp-platform/common_cells/src/lzc.sv",
                                    "vendor/pulp-platform/common_cells/src/rr_arb_tree.sv",
                                    "common/local/util/sram.sv", "common/local/util/sram_cache.sv",
                                    "common/local/util/tc_sram_wrapper.sv",
                                    "common/local/util/tc_sram_wrapper_cache_techno.sv",
                                    "build-platform/scripts/tc_sram_timing_stub.sv")]
    flists = {}
    for variant, path in (("baseline", src / "baseline/core/cache_subsystem/wt_dcache_mem.sv"),
                          ("candidate", src / "core/cache_subsystem/wt_dcache_mem.sv")):
        flist = out / f"dmem-{variant}.f"
        flist.write_text("\n".join(packages + common + [str(path), str(wrapper)]) + "\n")
        flists[variant] = flist
    pair_module(src, out, sta, lib, abc, evidence, yosys, run, "dmem", "g6lc_dmem_timing", flists, place_timeout=2400)

    # ---- 2. Loop predictor: row-local training in the shipped RTL vs the
    # baseline's indexed form (matched-state equivalence, model, pair).
    bench = src / "verif/tb/core/tb_g6lc_bp_loop_emit.sv"
    flists = {}
    for variant, path in (("baseline", src / "baseline/core/frontend/g6lc_bp_loop.sv"),
                          ("candidate", src / "core/frontend/g6lc_bp_loop.sv")):
        flist = out / f"loop-{variant}.f"
        flist.write_text("\n".join(packages + [str(path), str(bench)]) + "\n")
        flists[variant] = flist
    for entries, slots, rvc in ((16, 4, 1), (8, 1, 0), (32, 2, 1)):
        commands = []
        for variant, name in (("baseline", "gold"), ("candidate", "gate")):
            commands += [
                f"read_slang -f {flists[variant]} --top g6lc_loop_timing --single-unit "
                f"-G ENTRIES={entries} -G SLOTS={slots} -G RVC={rvc} --ignore-assertions",
                "proc", "flatten", "memory_map", "async2sync", "opt_clean",
                f"rename g6lc_loop_timing {name}", f"design -stash {name}",
            ]
        commands += ["design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                     "equiv_make gold gate equiv", "hierarchy -top equiv",
                     "equiv_simple -seq 1", "equiv_status -assert"]
        key = f"loop-eq-{entries}-{slots}-{rvc}"
        text = yosys(key, "\n".join(commands), timeout=300)
        assert "Equivalence successfully proven!" in text
        evidence["proofs"][key] = "matched-state equivalence PASS"
    key = "loop-model-candidate"
    obj = out / f"obj-{key}"
    run(key + "-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
        "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-f", str(flists["candidate"]), "--top-module", "tb_g6lc_bp_loop",
        "--Mdir", str(obj), "-j", "4"])
    for seed in (1, 17):
        log = run(f"{key}-{seed}", [str(obj / "Vtb_g6lc_bp_loop"), f"+seed={seed}"])
        assert "LOOP_PASS" in log
        evidence["proofs"][f"{key}-{seed}"] = next(l for l in log.splitlines() if "LOOP_PASS" in l)
    bad = subprocess.run([str(obj / "Vtb_g6lc_bp_loop"), "+oracle_negative"],
                         cwd=out, capture_output=True, text=True, timeout=120)
    (out / (key + "-negative.log")).write_text(bad.stdout + bad.stderr)
    assert bad.returncode != 0 and "LOOP_MISMATCH" in bad.stdout
    evidence["proofs"]["loop-negative"] = "model negative control fails as required"
    pair_module(src, out, sta, lib, abc, evidence, yosys, run, "loop", "g6lc_loop_timing", flists)

    # ---- 3. Loop buffer: the existing side-by-side witness (its invariant
    # assertions on), the bounded miter and the pair, through review_lbuf.
    sub = {"proofs": {}, "maps": {}, "sources": {}}
    review_lbuf(src, out, sta, lib, abc, sub, yosys, run)
    evidence["proofs"].update(sub["proofs"])
    for variant, entry in sub["maps"].items():
        evidence["maps"][f"lbuf-{variant}"] = entry
    (out / "result.json").write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence["maps"], indent=2), flush=True)


def review_stq(src, out, sta, lib, abc, evidence, yosys, run):
    """A138 store-buffer input stage: gate-off equivalence against the baseline,
    the shift witness (staged design == delayed reference state; previous
    semantics bound the outputs), a negative control and the paired mapping /
    placement of stage off vs on at the g6lc64_ooo geometry."""
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    packages = [l for l in portable.splitlines()
                if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
    sbs = src / "verif/tb/core/store_buffer_sbs"
    baseline = src / "baseline/core/store_buffer.sv"
    new = src / "core/store_buffer.sv"
    old = baseline.read_text()
    assert old.count("module store_buffer\n") == 1
    golden = out / "store_buffer_old.sv"
    golden.write_text(old.replace("module store_buffer\n", "module store_buffer_old\n", 1))
    # Timing / equivalence top: sb_wrap_new's ports around a config whose
    # StqInputStage bit is the STAGE parameter.
    wrap_text = (sbs / "wrap.sv").read_text()
    body = wrap_text[wrap_text.index("module sb_wrap_new"):]
    body = body[:body.index("endmodule") + len("endmodule")]
    body = body.replace("module sb_wrap_new", "module g6lc_stq_timing", 1)
    body = body.replace("    parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg),",
                        "    parameter bit STAGE = 1'b0,\n"
                        "    parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(stq_timing_pkg::user_cfg(STAGE)),", 1)
    tail = body[body.index("  logic [CVA6Cfg.PLEN-1:0] paddr_raw;"):]
    body = body.replace(tail,
        "  store_buffer #(.CVA6Cfg(CVA6Cfg), .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t), .cbo_t(cbo_t)) u (.*);\nendmodule")
    wrapper = out / "stq_timing.sv"
    wrapper.write_text("""
package stq_timing_pkg;
  function automatic config_pkg::cva6_user_cfg_t user_cfg(input bit stage);
    user_cfg = cva6_config_pkg::cva6_cfg;
    user_cfg.StqInputStage = stage;
  endfunction
endpackage
""" + body + "\n")
    old_wrapper = out / "stq_timing_old.sv"
    old_wrapper.write_text(wrapper.read_text().replace("g6lc_stq_timing", "g6lc_stq_timing_old")
                           .replace("  store_buffer #(", "  store_buffer_old #(").replace("stq_timing_pkg", "stq_timing_old_pkg"))
    # 2. shift witness
    vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
    tb_flist = out / "stq-tb.f"
    tb_flist.write_text("\n".join(packages + [str(new), str(golden), str(sbs / "wrap.sv"),
                                              str(sbs / "wrap_stage.sv"), str(sbs / "tb_sb_stage.sv")]) + "\n")
    obj = out / "obj-stq-stage"
    run("stq-stage-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal", "-Wno-lint", "-Wno-style",
        "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-f", str(tb_flist), "--top-module", "tb_sb_stage",
        "--Mdir", str(obj), "-j", "8"], timeout=1800)
    for label, args in (("plain-1", ["+seed=1"]), ("plain-17", ["+seed=17"]), ("cbo-1", ["+seed=1", "+cbo"]), ("cbo-5", ["+seed=5", "+cbo"])):
        log = run(f"stq-stage-{label}", [str(obj / "Vtb_sb_stage"), *args], timeout=1800)
        line = next((l for l in log.splitlines() if l.startswith("PASS tb_sb_stage")), "")
        assert line and "%Error" not in log, log[-1500:]
        evidence["proofs"][f"stq-stage-{label}"] = line
    # 3. negative control: the staged store no longer forwards -> FWD check fails
    mutant = out / "store_buffer_mut.sv"
    mut_text = new.read_text()
    needle = "if (pass == 1 && in_live && spec_visible(in_q.trans_id) &&"
    assert mut_text.count(needle) == 1
    mutant.write_text(mut_text.replace(needle, "if (pass == 1 && 1'b0 && spec_visible(in_q.trans_id) &&"))
    mflist = out / "stq-mut.f"
    mflist.write_text("\n".join(packages + [str(mutant), str(golden), str(sbs / "wrap.sv"),
                                            str(sbs / "wrap_stage.sv"), str(sbs / "tb_sb_stage.sv")]) + "\n")
    mobj = out / "obj-stq-mutant"
    run("stq-mutant-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal", "-Wno-lint", "-Wno-style",
        "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-f", str(mflist), "--top-module", "tb_sb_stage",
        "--Mdir", str(mobj), "-j", "8"], timeout=1800)
    bad = subprocess.run([str(mobj / "Vtb_sb_stage"), "+seed=1"], cwd=out, capture_output=True, text=True, timeout=1800)
    (out / "stq-mutant.log").write_text(bad.stdout + bad.stderr)
    assert bad.returncode != 0 and "FWD" in bad.stdout, "mutant was not caught"
    evidence["proofs"]["stq-negative"] = "staged store removed from forwarding: FWD check fails"
    # 1. gate off == previous RTL. equiv_simple did not finish in 20 minutes
    # on this module (46 k instances); the established evidence form for the
    # store buffer is the cycle-exact side-by-side harness (A109/A120):
    # previous RTL vs live RTL with the gate off, every output every cycle.
    flist_gate = out / "stq-gate.f"
    flist_gate.write_text("\n".join(packages + [str(new), str(wrapper)]) + "\n")
    sbs_flist = out / "stq-sbs.f"
    sbs_flist.write_text("\n".join(packages + [str(new), str(golden), str(sbs / "wrap.sv"),
                                               str(sbs / "tb_sb_sbs.sv")]) + "\n")
    sobj = out / "obj-stq-sbs"
    run("stq-sbs-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal", "-Wno-lint", "-Wno-style",
        "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-f", str(sbs_flist), "--top-module", "tb_sb_sbs",
        "--Mdir", str(sobj), "-j", "8"], timeout=1800)
    for seed in (1, 17):
        log = run(f"stq-sbs-{seed}", [str(sobj / "Vtb_sb_sbs"), f"+seed={seed}"], timeout=1800)
        line = next((l for l in log.splitlines() if "PASS" in l and "errors=0" in l), "")
        assert line and "%Error" not in log, log[-1500:]
        evidence["proofs"][f"stq-sbs-off-{seed}"] = line.strip()
    # 4. paired mapping / placement: stage off vs on
    for variant, stage in (("stq-off", 0), ("stq-on", 1)):
        netlist, stats = out / f"{variant}.v", out / f"{variant}.stat"
        yosys("map-" + variant,
              f"read_slang -f {flist_gate} --top g6lc_stq_timing --single-unit -G STAGE={stage}\n"
              "proc\nflatten\nopt_clean\nwreduce\nalumacc\nopt_clean\nmemory_map\n"
              f"opt_dff\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
              f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
              f"write_verilog -noattr -noexpr {netlist}\n", timeout=3600)
        evidence["maps"][variant] = {
            "area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1]),
            "board": {},
        }
        for fan in (0, 64):
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP="g6lc_stq_timing", OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE=str(fan))
            text = run(f"sta-{variant}-{fan}", [sta, "-exit",
                str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env, timeout=1800)
            row = next(l for l in text.splitlines() if l.startswith("ROW\t"))
            assert "failed" not in row
            evidence["maps"][variant]["board"][str(fan)] = row
        env = dict(os.environ, STUDY_PLATFORM=str(Path(lib).parent),
                   OR_VERILOG=str(netlist), OR_TOP="g6lc_stq_timing",
                   STUDY_OUTPUT=str(out / variant), STUDY_VARIANT=variant)
        text = run("place-" + variant, [
            "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad", "-exit",
            str(src / "build-platform/scripts/openroad-module-place-study.tcl")], env=env, timeout=2400)
        row = next(l for l in text.splitlines() if l.startswith("PLACE_STUDY "))
        evidence["maps"][variant]["placement"] = dict(re.findall(r"(\w+)=(\S+)", row))
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence["maps"], indent=2), flush=True)


def review_ckpt(src, out, sta, lib, abc, evidence, yosys, run):
    """Checkpoint stack oldest-live search in slot order: matched-state
    equivalence against the baseline (no new state), the directed and the
    randomized model benches with the rotated-reference assertion on, and
    paired mapping / placement at the shipped g6lc64_ooo geometry."""
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    packages = [l for l in portable.splitlines()
                if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
    common = [l for l in portable.splitlines() if l.endswith("/lzc.sv")]
    # The review bench file holds many leaves; mirror the audit runner's
    # companion set so every module it names elaborates (the ckpt tops
    # themselves need only the packages, lzc and the stack).
    companions = ("g6lc_iq.sv", "g6lc_bp_tage_table.sv", "g6lc_bp_tage.sv", "g6lc_bp_ghist.sv",
                  "g6lc_bp_ittage.sv", "g6lc_l2_mshr.sv", "g6lc_coherence_pkg.sv",
                  "g6lc_l3_inclusive_inv.sv", "g6lc_cluster.sv")
    bench_files = [l for l in portable.splitlines() if l.rsplit("/", 1)[-1] in companions]
    baseline = src / "baseline/core/frontend/g6lc_bp_ckpt.sv"
    new = src / "core/frontend/g6lc_bp_ckpt.sv"
    bench = src / "verif/tb/core/tb_g6lc_rtl_review.sv"
    skip_equiv = os.environ.get("A137_SKIP_EQUIV") == "1"
    wrapper = out / "ckpt_timing.sv"
    wrapper.write_text("""
module g6lc_ckpt_timing import ariane_pkg::*; #(
  parameter int unsigned NH = 1, parameter int unsigned DEPTH = 32, parameter int unsigned NR_PUSH = 4,
  parameter int unsigned GL = 24, parameter int unsigned TAGW = 8) (
  input logic clk_i, rst_ni, flush_i, clear_i, pop_i, pop_v_i, restore_i,
  input logic [$clog2(NH > 1 ? NH : 2)-1:0] push_hart_i, pop_hart_i,
  input logic [NR_PUSH-1:0] push_i,
  input logic [GL-1:0] push_ghist_i,
  input logic [0:0] push_ras_tos_i,
  input logic [1:0] push_ras_cnt_i,
  input logic [63:0] push_ras_top_i,
  input logic [TAGW-1:0] pop_idx_i,
  output logic clear_restore_o, alloc_v_o, entry_valid_o, restore_valid_o, empty_o, full_o,
  output logic [0:0] clear_ras_tos_o, entry_ras_tos_o,
  output logic [1:0] clear_ras_cnt_o, entry_ras_cnt_o,
  output logic [63:0] clear_ras_top_o, entry_ras_top_o,
  output logic [NR_PUSH-1:0][TAGW-1:0] alloc_idx_o,
  output logic [GL-1:0] entry_ghist_o);
  function automatic config_pkg::cva6_cfg_t cfg();
    cfg = config_pkg::cva6_cfg_empty; cfg.XLEN = 64; cfg.VLEN = 64; cfg.RVC = 1;
    cfg.INSTR_PER_FETCH = NR_PUSH; cfg.NrHarts = NH; cfg.RASDepth = 2;
  endfunction
  g6lc_bp_ckpt #(.CVA6Cfg(cfg()), .GHIST_LEN(GL), .DEPTH(DEPTH), .RAS_DEPTH(2), .RAS_PTR_W(1),
                 .RAS_CNT_W(2), .RAS_VLEN(64), .NR_PUSH(NR_PUSH), .TAG_W(TAGW)) dut (.*);
endmodule
""")
    # 2 x 64 x 4 (7.4 k payload cells) did not finish in 15 minutes; the
    # identity is per bank, so a second two-hart geometry at 16 covers it.
    for nh, depth, np_, tagw in () if skip_equiv else ((1, 32, 4, 8), (2, 8, 2, 7), (2, 16, 4, 8)):
        commands = []
        for path, name in ((baseline, "gold"), (new, "gate")):
            flist = out / f"ckpt-{name}.f"
            flist.write_text("\n".join(packages + common + [str(path), str(wrapper)]) + "\n")
            commands += [
                f"read_slang -f {flist} --top g6lc_ckpt_timing --single-unit --ignore-assertions "
                f"-G NH={nh} -G DEPTH={depth} -G NR_PUSH={np_} -G TAGW={tagw}",
                "proc", "flatten", "memory_map", "async2sync", "opt_clean",
                f"rename g6lc_ckpt_timing {name}", f"design -stash {name}",
            ]
        commands += ["design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                     "equiv_make gold gate equiv", "hierarchy -top equiv",
                     "equiv_simple -seq 1", "equiv_status -assert"]
        key = f"ckpt-eq-{nh}-{depth}-{np_}"
        text = yosys(key, "\n".join(commands), timeout=900)
        assert "Equivalence successfully proven!" in text
        evidence["proofs"][key] = "matched-state equivalence PASS"
    vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
    tb_flist = out / "ckpt-tb.f"
    tb_flist.write_text("\n".join(packages + common + bench_files + [str(new), str(bench)]) + "\n")
    obj = out / "obj-ckpt-directed"
    run("ckpt-directed-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
        "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-f", str(tb_flist), "--top-module", "tb_g6lc_review_ckpt",
        "--Mdir", str(obj), "-j", "4"], timeout=900)
    for scenario in range(7):
        log = run(f"ckpt-directed-{scenario}", [str(obj / "Vtb_g6lc_review_ckpt"), f"+scenario={scenario}"], timeout=120)
        assert "RTL_REVIEW_PASS ckpt" in log and "%Error" not in log and "rotated reference" not in log, log[-600:]
    evidence["proofs"]["ckpt-directed"] = "tb_g6lc_review_ckpt scenarios 0-6 PASS, reference assertion quiet"
    for label, defs, seeds in (("nh2-d64-np4", ["-GNH=2", "-GDEPTH=64", "-GNR_PUSH=4"], (1, 2, 3)),
                               ("nh1-d32-np4", ["-GNH=1", "-GDEPTH=32", "-GNR_PUSH=4"], (1, 2)),
                               ("nh2-d4-np2", ["-GNH=2", "-GDEPTH=4", "-GNR_PUSH=2"], (1, 2))):
        robj = out / f"obj-ckptrand-{label}"
        run(f"ckptrand-build-{label}", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
            "-Wno-WIDTH", "-Wno-UNOPTFLAT", *defs, "-f", str(tb_flist),
            "--top-module", "tb_g6lc_review_ckptrand", "--Mdir", str(robj), "-j", "4"], timeout=900)
        for seed in seeds:
            log = run(f"ckptrand-{label}-{seed}", [str(robj / "Vtb_g6lc_review_ckptrand"),
                                                    f"+seed={seed}", "+cycles=20000"], timeout=600)
            line = next((l for l in log.splitlines() if "RTL_REVIEW_" in l and "ckptrand" in l), "")
            assert line.startswith("RTL_REVIEW_PASS") and "errors=0" in line and "rotated reference" not in log, log[-800:]
            evidence["proofs"][f"ckptrand-{label}-{seed}"] = line
    # Negative control on the reference assertion: a shifted reference offset
    # must be reported by the randomized bench.
    mutant = out / "g6lc_bp_ckpt_mut.sv"
    mutant.write_text(new.read_text().replace("if (valid_rot[j]) ref_off = IDX_W'(j);",
                                              "if (valid_rot[j]) ref_off = IDX_W'(j + 1);"))
    mflist = out / "ckpt-mut.f"
    mflist.write_text("\n".join(packages + common + bench_files + [str(mutant), str(bench)]) + "\n")
    mobj = out / "obj-ckpt-mutant"
    run("ckpt-mutant-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
        "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-GNH=1", "-GDEPTH=32", "-GNR_PUSH=4", "-f", str(mflist),
        "--top-module", "tb_g6lc_review_ckptrand", "--Mdir", str(mobj), "-j", "4"], timeout=900)
    bad = subprocess.run([str(mobj / "Vtb_g6lc_review_ckptrand"), "+seed=1", "+cycles=2000"], cwd=out,
                         capture_output=True, text=True, timeout=300)
    (out / "ckpt-mutant.log").write_text(bad.stdout + bad.stderr)
    assert "rotated reference" in bad.stdout + bad.stderr, "mutated reference was not reported"
    evidence["proofs"]["ckpt-assertion-negative"] = "mutated rotated reference is reported"
    for variant, path in (("ckpt-baseline", baseline), ("ckpt-candidate", new)):
        vflist = out / f"{variant}.f"
        vflist.write_text("\n".join(packages + common + [str(path), str(wrapper)]) + "\n")
        netlist, stats = out / f"{variant}.v", out / f"{variant}.stat"
        yosys("map-" + variant,
              f"read_slang -f {vflist} --top g6lc_ckpt_timing --single-unit\n"
              "proc\nflatten\nopt_clean\nwreduce\nalumacc\nopt_clean\nmemory_map\n"
              f"opt_dff\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
              f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
              f"write_verilog -noattr -noexpr {netlist}\n")
        evidence["maps"][variant] = {
            "area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1]),
            "board": {},
        }
        for fan in (0, 64):
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP="g6lc_ckpt_timing", OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE=str(fan))
            text = run(f"sta-{variant}-{fan}", [sta, "-exit",
                str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env)
            row = next(l for l in text.splitlines() if l.startswith("ROW\t"))
            assert "failed" not in row
            evidence["maps"][variant]["board"][str(fan)] = row
        env = dict(os.environ, STUDY_PLATFORM=str(Path(lib).parent),
                   OR_VERILOG=str(netlist), OR_TOP="g6lc_ckpt_timing",
                   STUDY_OUTPUT=str(out / variant), STUDY_VARIANT=variant)
        text = run("place-" + variant, [
            "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad", "-exit",
            str(src / "build-platform/scripts/openroad-module-place-study.tcl")], env=env, timeout=900)
        row = next(l for l in text.splitlines() if l.startswith("PLACE_STUDY "))
        evidence["maps"][variant]["placement"] = dict(re.findall(r"(\w+)=(\S+)", row))
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence["maps"], indent=2), flush=True)


def review_rob(src, out, sta, lib, abc, evidence, yosys, run):
    """ROB head re-anchor in absolute slot order: matched-state equivalence
    against the baseline (no new state), the directed ROB witness with the
    rotated-reference assertion on, and paired mapping / placement."""
    old = (src / "baseline/core/ooo/g6lc_rob.sv").read_text()
    assert old.count("module g6lc_rob\n") == 1 or old.count("module g6lc_rob ") == 1
    golden = out / "g6lc_rob_old.sv"
    golden.write_text(old.replace("module g6lc_rob", "module g6lc_rob_old", 1))
    new = src / "core/ooo/g6lc_rob.sv"
    wrapper = out / "rob_timing.sv"
    wrapper.write_text("""
module g6lc_rob_timing #(parameter int unsigned ENTRIES = 32, parameter int unsigned W = 5,
                         parameter int unsigned NA = 2, parameter int unsigned NR = 2,
                         parameter int unsigned NC = 4, parameter int unsigned TID_W = 5,
                         parameter int unsigned NR_SB = 32, parameter int unsigned PW = 64) (
  input logic clk_i, rst_ni, flush_i,
  input logic [NR_SB-1:0] cancelled_mask_i,
  input logic [NA-1:0] alloc_valid_i,
  input logic [NA-1:0][PW-1:0] alloc_entry_i,
  input logic [NA-1:0][TID_W-1:0] alloc_tid_i,
  output logic [NA-1:0][W-1:0] alloc_id_o,
  output logic full_o, empty_o,
  input logic [NC-1:0] complete_valid_i,
  input logic [NC-1:0][TID_W-1:0] complete_tid_i,
  input logic [NC-1:0] complete_exc_i,
  output logic [NR-1:0] retire_valid_o,
  output logic [NR-1:0][PW-1:0] retire_entry_o,
  output logic [NR-1:0][W-1:0] retire_id_o,
  input logic [NR-1:0] retire_ack_i,
  input logic [NR-1:0][TID_W-1:0] retire_tid_i);
  g6lc_rob #(.ROB_ENTRIES(ENTRIES), .ROB_W(W), .NR_ALLOC(NA), .NR_RETIRE(NR), .NR_COMPLETE(NC),
             .TID_W(TID_W), .NR_SB(NR_SB), .entry_t(logic [PW-1:0])) dut (.*);
endmodule
""")
    # The gold side reads the unrenamed baseline file: the renamed copy only
    # serves a possible combined simulation; both must stay byte-equal in body.
    baseline = src / "baseline/core/ooo/g6lc_rob.sv"
    for entries, w, nc in ((8, 3, 2), (16, 4, 3), (32, 5, 4)):
        commands = []
        for path, name in ((baseline, "gold"), (new, "gate")):
            flist = out / f"rob-{name}.f"
            flist.write_text(f"{path}\n{wrapper}\n")
            commands += [
                f"read_slang -f {flist} --top g6lc_rob_timing --single-unit --ignore-assertions "
                f"-G ENTRIES={entries} -G W={w} -G NC={nc} -G TID_W={w} -G NR_SB={entries}",
                "proc", "flatten", "memory_map", "async2sync", "opt_clean",
                f"rename g6lc_rob_timing {name}", f"design -stash {name}",
            ]
        commands += ["design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                     "equiv_make gold gate equiv", "hierarchy -top equiv",
                     "equiv_simple -seq 1", "equiv_status -assert"]
        key = f"rob-eq-{entries}"
        text = yosys(key, "\n".join(commands), timeout=600)
        assert "Equivalence successfully proven!" in text
        evidence["proofs"][key] = "matched-state equivalence PASS"
    vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
    obj = out / "obj-rob-directed"
    run("rob-directed-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
        "-Wno-WIDTH", "-Wno-UNOPTFLAT", str(new), str(src / "verif/tb/core/tb_g6lc_rob.sv"),
        "--top-module", "tb_g6lc_rob", "--Mdir", str(obj), "-j", "4"], timeout=600)
    for scenario in (0, 1):
        log = run(f"rob-directed-{scenario}", [str(obj / "Vtb_g6lc_rob"), f"+scenario={scenario}"], timeout=120)
        assert "RTL_REVIEW_PASS" in log and "%Error" not in log and "re-anchor" not in log, log[-600:]
    evidence["proofs"]["rob-directed"] = "tb_g6lc_rob scenarios 0 and 1 PASS, rotated-reference assertion quiet"
    # Negative control on the new assertion itself: a wrong reference head
    # must be reported. Forced through a define-free textual mutant copy.
    mutant = out / "g6lc_rob_mut.sv"
    mutant.write_text(new.read_text().replace("ref_head = head_q + ref_steps;",
                                              "ref_head = head_q + ref_steps + ROB_W'(1);"))
    mobj = out / "obj-rob-mutant"
    run("rob-mutant-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
        "-Wno-WIDTH", "-Wno-UNOPTFLAT", str(mutant), str(src / "verif/tb/core/tb_g6lc_rob.sv"),
        "--top-module", "tb_g6lc_rob", "--Mdir", str(mobj), "-j", "4"], timeout=600)
    bad = subprocess.run([str(mobj / "Vtb_g6lc_rob"), "+scenario=0"], cwd=out,
                         capture_output=True, text=True, timeout=120)
    (out / "rob-mutant.log").write_text(bad.stdout + bad.stderr)
    assert "re-anchor" in bad.stdout + bad.stderr, "mutated reference was not reported"
    evidence["proofs"]["rob-assertion-negative"] = "mutated rotated reference is reported"
    for variant, path in (("rob-baseline", src / "baseline/core/ooo/g6lc_rob.sv"),
                          ("rob-candidate", new)):
        vflist = out / f"{variant}.f"
        vflist.write_text(f"{path}\n{wrapper}\n")
        netlist, stats = out / f"{variant}.v", out / f"{variant}.stat"
        yosys("map-" + variant,
              f"read_slang -f {vflist} --top g6lc_rob_timing --single-unit\n"
              "proc\nflatten\nopt_clean\nwreduce\nalumacc\nopt_clean\nmemory_map\n"
              f"opt_dff\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
              f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
              f"write_verilog -noattr -noexpr {netlist}\n")
        evidence["maps"][variant] = {
            "area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1]),
            "board": {},
        }
        for fan in (0, 64):
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP="g6lc_rob_timing", OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE=str(fan))
            text = run(f"sta-{variant}-{fan}", [sta, "-exit",
                str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env)
            row = next(l for l in text.splitlines() if l.startswith("ROW\t"))
            assert "failed" not in row
            evidence["maps"][variant]["board"][str(fan)] = row
        env = dict(os.environ, STUDY_PLATFORM=str(Path(lib).parent),
                   OR_VERILOG=str(netlist), OR_TOP="g6lc_rob_timing",
                   STUDY_OUTPUT=str(out / variant), STUDY_VARIANT=variant)
        text = run("place-" + variant, [
            "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad", "-exit",
            str(src / "build-platform/scripts/openroad-module-place-study.tcl")], env=env, timeout=900)
        row = next(l for l in text.splitlines() if l.startswith("PLACE_STUDY "))
        evidence["maps"][variant]["placement"] = dict(re.findall(r"(\w+)=(\S+)", row))
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence["maps"], indent=2), flush=True)


def review_loop_emit(src, out, data, sta, lib, abc, evidence, yosys, run):
    """Source vs sv-timing emitted row-local loop predictor: equivalence,
    independent model witness with negative control, mapping and placement.
    The emitted file is an uploaded artifact; its hash is recorded."""
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    packages = [l for l in portable.splitlines()
                if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
    bench = src / "verif/tb/core/tb_g6lc_bp_loop_emit.sv"
    emitted = data / "g6lc_bp_loop__svt.sv"
    evidence["sources"]["g6lc_bp_loop__svt.sv"] = hashlib.sha256(emitted.read_bytes()).hexdigest()
    text = emitted.read_text()
    assert "row-local-applied train" in text and "__svt_row_train" in text, "emit lacks the prepared form"
    assert "svt-pipe: row-local train" not in text
    variants = {"source": src / "core/frontend/g6lc_bp_loop.sv", "emitted": emitted}
    flists = {}
    for variant, path in variants.items():
        flist = out / f"loop-{variant}.f"
        flist.write_text("\n".join(packages + [str(path), str(bench)]) + "\n")
        flists[variant] = flist
    for entries, slots, rvc in ((16, 4, 1), (8, 1, 0), (32, 2, 1)):
        commands = []
        for variant, name in (("source", "gold"), ("emitted", "gate")):
            commands += [
                f"read_slang -f {flists[variant]} --top g6lc_loop_timing --single-unit "
                f"-G ENTRIES={entries} -G SLOTS={slots} -G RVC={rvc} --ignore-assertions",
                "proc", "flatten", "memory_map", "async2sync", "opt_clean",
                f"rename g6lc_loop_timing {name}", f"design -stash {name}",
            ]
        commands += ["design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                     "equiv_make gold gate equiv", "hierarchy -top equiv",
                     "equiv_simple -seq 1", "equiv_status -assert"]
        key = f"loop-eq-{entries}-{slots}-{rvc}"
        out_text = yosys(key, "\n".join(commands), timeout=300)
        assert "Equivalence successfully proven!" in out_text
        evidence["proofs"][key] = "matched-state equivalence PASS"
    vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
    for variant, flist in flists.items():
        key = f"loop-model-{variant}"
        obj = out / f"obj-{key}"
        run(key + "-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
            "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-f", str(flist), "--top-module", "tb_g6lc_bp_loop",
            "--Mdir", str(obj), "-j", "4"])
        for seed in (1, 17):
            log = run(f"{key}-{seed}", [str(obj / "Vtb_g6lc_bp_loop"), f"+seed={seed}"])
            assert "LOOP_PASS" in log
            evidence["proofs"][f"{key}-{seed}"] = next(l for l in log.splitlines() if "LOOP_PASS" in l)
        bad = subprocess.run([str(obj / "Vtb_g6lc_bp_loop"), "+oracle_negative"],
                             cwd=out, capture_output=True, text=True, timeout=120)
        (out / (key + "-negative.log")).write_text(bad.stdout + bad.stderr)
        assert bad.returncode != 0 and "LOOP_MISMATCH" in bad.stdout
    for variant, flist in flists.items():
        netlist, stats = out / f"{variant}.v", out / f"{variant}.stat"
        yosys("loop-map-" + variant,
              f"read_slang -f {flist} --top g6lc_loop_timing --single-unit\n"
              "proc\nflatten\nopt_clean\nwreduce\nalumacc\nopt_clean\nmemory_map\n"
              f"opt_dff\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
              f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
              f"write_verilog -noattr -noexpr {netlist}\n")
        evidence["maps"][variant] = {
            "area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1]),
            "board": {},
        }
        for fan in (0, 64):
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP="g6lc_loop_timing", OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE=str(fan))
            out_text = run(f"loop-sta-{variant}-{fan}", [sta, "-exit",
                str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env)
            row = next(l for l in out_text.splitlines() if l.startswith("ROW\t"))
            assert "failed" not in row
            evidence["maps"][variant]["board"][str(fan)] = row
        env = dict(os.environ, STUDY_PLATFORM=str(Path(lib).parent),
                   OR_VERILOG=str(netlist), OR_TOP="g6lc_loop_timing",
                   STUDY_OUTPUT=str(out / variant), STUDY_VARIANT=variant)
        out_text = run("loop-place-" + variant, [
            "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad", "-exit",
            str(src / "build-platform/scripts/openroad-module-place-study.tcl")], env=env, timeout=900)
        row = next(l for l in out_text.splitlines() if l.startswith("PLACE_STUDY "))
        evidence["maps"][variant]["placement"] = dict(re.findall(r"(\w+)=(\S+)", row))
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence["maps"], indent=2), flush=True)


def review_statcor(src, out, sta, lib, abc, evidence, yosys, run):
    """Small tagged-table study: row-local training, unchanged read/clock contract."""
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    packages = [l for l in portable.splitlines()
                if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
    bench = src / "verif/tb/core/tb_g6lc_bp_statcor.sv"
    flists = {}
    for variant, path in (("baseline", src / "baseline/core/frontend/g6lc_bp_statcor.sv"),
                          ("candidate", src / "core/frontend/g6lc_bp_statcor.sv")):
        flist = out / f"statcor-{variant}.f"
        flist.write_text("\n".join(packages + [str(path), str(bench)]) + "\n")
        flists[variant] = flist
    for entries, slots, rvc in ((64, 4, 1), (8, 1, 0), (24, 4, 1)):
        commands = []
        for variant, name in (("baseline", "gold"), ("candidate", "gate")):
            commands += [
                f"read_slang -f {flists[variant]} --top g6lc_sc_timing --single-unit "
                f"-G ENTRIES={entries} -G SLOTS={slots} -G RVC={rvc} --ignore-assertions",
                "proc", "flatten", "memory_map", "async2sync", "opt_clean",
                f"rename g6lc_sc_timing {name}", f"design -stash {name}",
            ]
        commands += ["design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                     "equiv_make gold gate equiv", "hierarchy -top equiv",
                     "equiv_simple -seq 1", "equiv_status -assert"]
        key = f"statcor-eq-{entries}-{slots}-{rvc}"
        text = yosys(key, "\n".join(commands), timeout=300)
        assert "Equivalence successfully proven!" in text
        evidence["proofs"][key] = "matched-state equivalence PASS"
    vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
    for slots, rvc in ((4, 1), (1, 0)):
        key = f"statcor-model-{slots}-{rvc}"
        obj = out / f"obj-{key}"
        run(key + "-build", [vl, "-O1", "--binary", "--timing", "--assert", "-Wno-fatal",
            "-Wno-WIDTH", "-Wno-UNOPTFLAT", f"-GSLOTS={slots}", f"-GRVC={rvc}",
            "-f", str(flists["candidate"]), "--top-module", "tb_g6lc_bp_statcor",
            "--Mdir", str(obj), "-j", "4"])
        log = run(key, [str(obj / "Vtb_g6lc_bp_statcor")])
        assert "STATCOR_PASS" in log
        evidence["proofs"][key] = next(l for l in log.splitlines() if "STATCOR_PASS" in l)
        bad = subprocess.run([str(obj / "Vtb_g6lc_bp_statcor"), "+oracle_negative"],
                             cwd=out, capture_output=True, text=True, timeout=60)
        (out / (key + "-negative.log")).write_text(bad.stdout + bad.stderr)
        assert bad.returncode != 0 and "STATCOR_MISMATCH" in bad.stdout
    for variant, flist in flists.items():
        netlist, stats = out / f"{variant}.v", out / f"{variant}.stat"
        yosys("statcor-map-" + variant,
              f"read_slang -f {flist} --top g6lc_sc_timing --single-unit\n"
              "proc\nflatten\nopt_clean\nwreduce\nalumacc\nopt_clean\nmemory_map\n"
              f"opt_dff\ntechmap\nopt_clean\ndfflibmap -liberty {lib}\n{abc}\n"
              f"opt_clean -purge\ntee -o {stats} stat -liberty {lib}\n"
              f"write_verilog -noattr -noexpr {netlist}\n")
        evidence["maps"][variant] = {
            "area_um2": float(re.search(r"Chip area for module .*?:\s*([\d.]+)", stats.read_text())[1]),
            "board": {},
        }
        for fan in (0, 64):
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP="g6lc_sc_timing", OR_PERIOD_NS="0.25", OR_IGNORE_FANOUT_ABOVE=str(fan))
            text = run(f"statcor-sta-{variant}-{fan}", [sta, "-exit",
                str(src / "build-platform/scripts/openroad-module-board.tcl")], env=env)
            row = next(l for l in text.splitlines() if l.startswith("ROW\t"))
            assert "failed" not in row
            evidence["maps"][variant]["board"][str(fan)] = row
        env = dict(os.environ, STUDY_PLATFORM=str(Path(lib).parent),
                   OR_VERILOG=str(netlist), OR_TOP="g6lc_sc_timing",
                   STUDY_OUTPUT=str(out / variant), STUDY_VARIANT=variant)
        text = run("statcor-place-" + variant, [
            "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/openroad", "-exit",
            str(src / "build-platform/scripts/openroad-module-place-study.tcl")], env=env, timeout=900)
        row = next(l for l in text.splitlines() if l.startswith("PLACE_STUDY "))
        evidence["maps"][variant]["placement"] = dict(re.findall(r"(\w+)=(\S+)", row))
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence["maps"], indent=2), flush=True)


def prove_boundary_surface(src, out, evidence, yosys, run):
    """Focused equivalence and stateful witnesses for the A134 boundary batch."""
    vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
    evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
    requested = os.environ.get("CONTROL_SURFACE_MODULE", "all")
    if requested not in {"all", "g6lc_rename", "store_buffer", "instr_realign"}:
        raise ValueError(requested)
    rename_cases = ((1, 40, 2, 40), (2, 80, 2, 80), (1, 40, 3, 40), (1, 40, 2, 0))
    for harts, entries, ports, fp in (rename_cases if requested in {"all", "g6lc_rename"} else ()):
        width = (entries - 1).bit_length()
        commands = []
        for variant, path in (("gold", "baseline/core/ooo/g6lc_rename.sv"),
                              ("gate", "core/ooo/g6lc_rename.sv")):
            commands += [
                f"read_slang --top g6lc_rename -G NR_HARTS={harts} -G NR_PORTS={ports} "
                f"-G PRF_ENTRIES={entries} -G FPRF_ENTRIES={fp} "
                f"-G PRF_W={width} -G FPRF_W={width} -G CKPT_DEPTH=4 "
                f"--ignore-assertions {path}",
                "proc", "memory_map", "async2sync", "opt_clean",
                f"rename g6lc_rename {variant}", f"design -stash {variant}",
            ]
        commands += ["design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                     "equiv_make gold gate equiv", "hierarchy -top equiv",
                     "equiv_simple -seq 1", "equiv_status -assert"]
        key = f"rename-{harts}h-{ports}p-fp{fp}"
        text = yosys(key, "\n".join(commands), timeout=600)
        assert "Equivalence successfully proven!" in text
        evidence["proofs"][key] = "matched-state equivalence PASS"
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    packages = [l for l in portable.splitlines()
                if l.startswith("+") or l.endswith("_pkg.sv") or "/include/" in l]
    for module, file, bench, top in (
        ("store_buffer", "core/store_buffer.sv", "store_buffer_sbs", "tb_sb_sbs"),
        ("instr_realign", "core/fetch_B/instr_realign.sv", "instr_realign_sbs", "tb_rl_sbs"),
    ):
        if requested not in {"all", module}:
            continue
        old = (src / "baseline" / file).read_text()
        golden = out / f"{module}_old.sv"
        assert old.count(f"module {module}\n") == 1
        golden.write_text(old.replace(f"module {module}\n", f"module {module}_old\n", 1))
        flist = out / f"{module}.f"
        harness = sorted((src / "verif/tb/core" / bench).glob("*.sv"))
        flist.write_text("\n".join(packages + [str(src / file), str(golden)] + list(map(str, harness))) + "\n")
        matrix = [("default", [])]
        if module == "instr_realign":
            matrix += [
                ("32b-2h-32va", ["+define+SVT_RL_WIDTH=32", "+define+SVT_RL_HARTS=2", "+define+SVT_RL_VLEN=32"]),
                ("128b-2h-64va", ["+define+SVT_RL_WIDTH=128", "+define+SVT_RL_HARTS=2", "+define+SVT_RL_VLEN=64"]),
                ("128b-4h-fewslots", ["+define+SVT_RL_WIDTH=128", "+define+SVT_RL_HARTS=4", "+define+SVT_RL_SLOTS=2"]),
                ("no-rvc", ["+define+SVT_RL_RVC=0"]),
            ]
        for label, defs in matrix:
            key = f"{module}-{label}"
            obj = out / f"obj-{key}"
            run(key + "-build", [vl, "-O1", "--binary", "--timing", "--assert",
                "-Wno-fatal", "-Wno-WIDTH", "-Wno-UNOPTFLAT", *defs, "-f", str(flist),
                "--top-module", top, "--Mdir", str(obj), "-j", "4"], timeout=600)
            log = run(key + "-sim", [str(obj / f"V{top}"), "+seed=17"], timeout=180)
            assert f"PASS {top}" in log and "errors=0" in log, log[-1200:]
            evidence["proofs"][key] = next(l for l in log.splitlines() if f"PASS {top}" in l)
        if module == "instr_realign":
            text = (src / file).read_text()
            needle = "carry_next_bank_q[hart_i] <= window_next_pc;"
            assert text.count(needle) == 1
            bad = out / "realign_truncated.sv"
            bad.write_text(text.replace(needle,
                "carry_next_bank_q[hart_i] <= 64'(CVA6Cfg.VLEN'(window_next_pc));"))
            bad_flist = out / "realign-negative.f"
            bad_flist.write_text(flist.read_text().replace(str(src / file), str(bad)))
            obj = out / "obj-realign-negative"
            # Disable RTL assertions here: the interface comparison itself
            # must detect the narrow-VLEN wrap error.
            run("realign-negative-build", [vl, "-O1", "--binary", "--timing",
                "-Wno-fatal", "-Wno-WIDTH", "-Wno-UNOPTFLAT",
                "+define+SVT_RL_VLEN=32", "+define+SVT_RL_RVC=1",
                "-f", str(bad_flist), "--top-module", top, "--Mdir", str(obj), "-j", "4"])
            result = subprocess.run([str(obj / f"V{top}"), "+seed=17"], cwd=out,
                                    capture_output=True, text=True, timeout=180)
            (out / "realign-negative.log").write_text(result.stdout + result.stderr)
            assert result.returncode != 0 and "MISMATCH" in result.stdout
            evidence["proofs"]["realign-negative"] = "truncated successor rejected by interface witness"
    print(json.dumps(evidence["proofs"], indent=2), flush=True)


def map_snapshots(src, out, sta, lib, abc, evidence, yosys, run,
                  *, changed=CHANGED, modules=MODULES):
    # Map both snapshots with identical options. The old/new package and
    # three consumers are switched by filelist, not by editing the snapshot.
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    for variant in ("baseline", "candidate"):
        work = out / variant
        work.mkdir()
        flist = portable
        if variant == "baseline":
            for name in changed:
                flist = flist.replace(str(src / name), str(src / "baseline" / name))
        flist = flist.replace(str(src / "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv"),
                              str(src / "build-platform/scripts/tc_sram_timing_stub.sv"))
        (work / "core.f").write_text(flist)
        yosys(f"{variant}-elab",
              f"read_slang -f {work}/core.f --top cva6 --single-unit --best-effort-hierarchy\n"
              "hierarchy -check -top cva6\nproc\nopt_clean\nwreduce\nalumacc\n"
              "opt_clean\nmemory -nomap\nmemory_map\nopt_clean\nopt_dff\n"
              f"write_rtlil {work}/wordlevel.il\n", timeout=1200)
        run(f"{variant}-split", ["python3", str(src / "sv-timing/tools/rtlil_width_map.py"),
                                str(work / "wordlevel.il"), "--split-dir", str(work / "il"),
                                "-o", str(work / "width-map.json")])
        entries = [l.split("\t") for l in (work / "il/modules.tsv").read_text().splitlines()]
        entries = [e for e in entries if e[2].lstrip("\\").split("$")[0] in modules]

        def map_one(entry):
            index, filename, escaped = entry
            top = escaped.lstrip("\\")
            stem = Path(filename).stem
            netlist, stats = work / f"{stem}.v", work / f"{stem}.stat"
            yosys(f"{variant}-{index}",
                  f"read_rtlil {work}/il/{filename}\nbooth\n"
                  f"async2sync t:$aldff t:$aldffe\ntechmap\nopt_clean\n"
                  f"dfflibmap -liberty {lib}\n{abc}\nopt_clean -purge\n"
                  f"tee -o {stats} stat -liberty {lib}\n"
                  f"write_verilog -noattr -noexpr {netlist}\n", timeout=1200)
            area = float(re.search(r"Chip area for module .*?:\s*([\d.]+)",
                                   stats.read_text())[1])
            env = dict(os.environ, OR_LIBERTY=lib, OR_VERILOG=str(netlist),
                       OR_TOP=top, OR_PERIOD_NS="0.25")
            board = src / "build-platform/scripts/openroad-module-board.tcl"
            # Keep the historical study row, plus the full timing graph
            # (0 disables the fanout cut). Neither is placement sign-off.
            rows = {}
            for fan in (64, 0):
                env["OR_IGNORE_FANOUT_ABOVE"] = str(fan)
                log = run(f"{variant}-{index}-sta-{fan}",
                          [sta, "-exit", str(board)], env=env)
                row = next((l for l in log.splitlines() if l.startswith("ROW\t")), None)
                if not row or "failed" in row:
                    raise RuntimeError(f"{variant} {top}: missing/failed board")
                rows[str(fan)] = row.split("\t")[1:]
            return top, {"area_um2": area, "board": rows,
                         "rtlil_sha256": hashlib.sha256((work / "il" / filename).read_bytes()).hexdigest()}

        with ThreadPoolExecutor(max_workers=4) as pool:
            evidence["maps"][variant] = dict(pool.map(map_one, entries))
        (out / "result.json").write_text(json.dumps(evidence, indent=2))
        print(f"MAP {variant}: {len(entries)} modules", flush=True)
    for top, new in evidence["maps"]["candidate"].items():
        old = evidence["maps"]["baseline"][top]
        print(f"DELTA {top.split('$')[0]} area={old['area_um2']:.3f}->{new['area_um2']:.3f} "
              f"study_ns={old['board']['64'][7]}->{new['board']['64'][7]} "
              f"full_ns={old['board']['0'][7]}->{new['board']['0'][7]}", flush=True)
    (out / "result.json").write_text(json.dumps(evidence, indent=2))


def prove_selections(src, out, yosys, evidence):
    """Prove extracted production selection logic, including padded/tied inputs."""
    iq_gold = (src / "baseline/core/ooo/g6lc_iq.sv").read_text()
    iq_gate = (src / "core/ooo/g6lc_iq.sv").read_text()
    start = iq_gold.index("  for (genvar p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin : gen_grant")
    old = iq_gold[start:iq_gold.index("  always_comb begin", start)]
    start = iq_gate.index("  // BEGIN A119 parallel first-two grant predicates")
    new = iq_gate[start:iq_gate.index("  always_comb begin", start)]

    def iq_module(name, body):
        return f"""
module {name} #(parameter DEPTH=5, PORTS=2) (
 input logic [DEPTH-1:0] ready,
 input logic [DEPTH-1:0][DEPTH-1:0] older_t,
 output logic [PORTS-1:0][DEPTH-1:0] grant);
{body.replace('CVA6Cfg.NrIssuePorts', 'PORTS')}
endmodule
"""
    for depth, ports in ((1, 1), (2, 2), (5, 2), (5, 3), (24, 2)):
        w = max(1, (depth-1).bit_length())
        fixture = out / f"iq-select-{depth}-{ports}.sv"
        comparison = f"""
module iq_eq(input logic [{depth-1}:0] ready,
             input logic [{depth-1}:0][{w-1}:0] age, output logic ok);
  logic [{depth-1}:0][{depth-1}:0] older_t;
  logic [{ports-1}:0][{depth-1}:0] a, b;
  for (genvar e=0;e<{depth};e++)
    for (genvar o=0;o<{depth};o++)
      assign older_t[e][o] = age[o]<age[e] || (age[o]==age[e] && o<e);
  gold #({depth}, {ports}) g(ready, older_t, a);
  gate #({depth}, {ports}) h(ready, older_t, b);
  assign ok = a == b;
endmodule
"""
        if depth == 24:
            # At production depth, prove the implemented grants directly
            # against their rank specification for arbitrary age matrices.
            # This avoids asking SAT to rediscover transitivity of 24
            # symbolic age values. The small total-order cases above
            # compare the cascade, including later ports, independently.
            comparison = f"""
module iq_eq(input logic [{depth-1}:0] ready,
             input logic [{depth-1}:0][{depth-1}:0] older_t, output logic ok);
  logic [1:0][{depth-1}:0] grant;
  gate #({depth}, 2) h(ready, older_t, grant);
  always_comb begin
    ok = 1'b1;
    for (int e=0;e<{depth};e++) begin
      ok &= grant[0][e] == (ready[e] && $countones(ready & older_t[e]) == 0);
      ok &= grant[1][e] == (ready[e] && $countones(ready & older_t[e]) == 1);
    end
  end
endmodule
"""
        fixture.write_text(iq_module("gold", old) + iq_module("gate", new) + comparison)
        log = yosys(f"iq-select-{depth}-{ports}",
                    f"read_slang --top iq_eq {fixture}\nprep -top iq_eq -flatten\n"
                    "sat -prove ok 1 -verify\n", timeout=600)
        assert "SUCCESS!" in log
        evidence["proofs"][f"iq-{depth}entries-{ports}ports"] = (
            "arbitrary-matrix rank SAT PASS" if depth == 24 else "total-order SAT PASS")

    lsq = (src / "core/ooo/g6lc_lsq.sv").read_text()
    st_tree = lsq.split("// BEGIN A119 stable youngest-store tournament", 1)[1].split(
        "// END A119 stable youngest-store tournament", 1)[0]
    ld_tree = lsq.split("// BEGIN A119 stable oldest-violation tournament", 1)[1].split(
        "// END A119 stable oldest-violation tournament", 1)[0]
    for depth in (1, 3, 8, 16):
        fixture = out / f"lsq-select-{depth}.sv"
        fixture.write_text(f"""
module lsq_eq(input logic [{depth-1}:0] stl_match, viol_cand,
              input logic [{depth-1}:0][4:0] stl_age,
              input logic [{depth-1}:0][31:0] viol_age, output logic ok);
  localparam ST_ENTRIES={depth}, LD_ENTRIES={depth};
  localparam StSelectLeaves=1<<$clog2(ST_ENTRIES), LdSelectLeaves=1<<$clog2(LD_ENTRIES);
  localparam StSelectWidth=ST_ENTRIES>1?$clog2(ST_ENTRIES):1;
  localparam LdSelectWidth=LD_ENTRIES>1?$clog2(LD_ENTRIES):1;
{st_tree.replace('CVA6Cfg.TRANS_ID_BITS', '5')}
{ld_tree}
  logic st_found, ld_found;
  logic [4:0] st_best;
  logic [31:0] ld_best;
  logic [StSelectWidth-1:0] st_slot;
  logic [LdSelectWidth-1:0] ld_slot;
  always_comb begin
    st_found=0; ld_found=0; st_best=0; ld_best='1; st_slot=0; ld_slot=0;
    for (int i=0;i<ST_ENTRIES;i++)
      if (stl_match[i] && (!st_found || stl_age[i]>st_best)) begin
        st_found=1; st_best=stl_age[i]; st_slot=StSelectWidth'(i);
      end
    for (int j=0;j<LD_ENTRIES;j++)
      if (viol_cand[j] && viol_age[j]<ld_best) begin
        ld_found=1; ld_best=viol_age[j]; ld_slot=LdSelectWidth'(j);
      end
  end
  assign ok = (st_found==stl_pick_valid[1]) && (ld_found==viol_pick_valid[1]) &&
              (!st_found || st_slot==stl_pick_slot[1]) &&
              (!ld_found || ld_slot==viol_pick_slot[1]);
endmodule
""")
        log = yosys(f"lsq-select-{depth}",
                    f"read_slang --top lsq_eq {fixture}\nprep -top lsq_eq -flatten\n"
                    "sat -prove ok 1 -verify\n", timeout=600)
        assert "SUCCESS!" in log
        evidence["proofs"][f"lsq-{depth}entries"] = "stable min/max SAT PASS"
    print("PROOFS " + json.dumps(evidence["proofs"]), flush=True)


def prove_precompute(src, out, yosys, evidence):
    iq = (src / "core/ooo/g6lc_iq.sv").read_text()
    bank = iq.split("// BEGIN A120 late issue-count select", 1)[1].split(
        "// END A120 late issue-count select", 1)[0].replace("CVA6Cfg.NrIssuePorts", "PORTS")
    for depth, ports in ((1, 1), (3, 2), (24, 2), (32, 4)):
        fixture = out / f"count-{depth}-{ports}.sv"
        fixture.write_text(f"""
module count_eq(
 input logic [$clog2({depth}+1)-1:0] count_q,
 input logic [{depth-1}:0] cancel_hit,
 input logic [{ports-1}:0] issue_valid_o, issue_ack_i, disp_ack_o,
 input logic flush_i, output logic ok);
 localparam DEPTH={depth}, PORTS={ports}, DW=$clog2(DEPTH+1);
 logic [DW-1:0] count_d, gold;
{bank}
 assign gold=flush_i ? '0 : count_q-DW'($countones(cancel_hit))
                   -DW'($countones(issue_valid_o & issue_ack_i))
                   +DW'($countones(disp_ack_o));
 assign ok=count_d==gold;
endmodule
""")
        text = yosys(f"count-{depth}-{ports}", f"read_slang --top count_eq {fixture}\n"
                     "prep -top count_eq -flatten\nsat -prove ok 1 -verify\n")
        assert "SUCCESS!" in text
        evidence["proofs"][f"count-{depth}-{ports}"] = "all-pattern modular SAT PASS"
    for harts, entries, ports in ((1, 40, 2), (2, 80, 2), (1, 40, 3)):
        tag_width = (entries-1).bit_length()
        commands = []
        for variant, path in (("gold", "baseline/core/ooo/g6lc_rename.sv"),
                              ("gate", "core/ooo/g6lc_rename.sv")):
            commands += [
                f"read_slang --top g6lc_rename -G NR_HARTS={harts} -G NR_PORTS={ports} "
                f"-G PRF_ENTRIES={entries} -G FPRF_ENTRIES={entries} "
                f"-G PRF_W={tag_width} -G FPRF_W={tag_width} -G CKPT_DEPTH=4 "
                f"--ignore-assertions {path}", "proc", "memory_map", "async2sync", "opt_clean",
                f"rename g6lc_rename {variant}", f"design -stash {variant}",
            ]
        commands += ["design -copy-from gold -as gold gold",
                     "design -copy-from gate -as gate gate", "equiv_make gold gate equiv",
                     "hierarchy -top equiv", "equiv_simple -seq 1", "equiv_status -assert"]
        text = yosys(f"rename-{harts}-{ports}", "\n".join(commands), timeout=600)
        assert "Equivalence successfully proven!" in text
        evidence["proofs"][f"rename-{harts}h-{ports}p"] = "matched-state equivalence PASS"
    # A118 established the stable-rank relation. Check that control region is
    # byte-identical, then prove the new gather for its one-hot-or-zero mask.
    def rank_region(text):
        return text.split("// Direct predecessor relation", 1)[1].split("// one gather:", 1)[0]
    old = (src / "baseline/core/store_buffer.sv").read_text()
    new = (src / "core/store_buffer.sv").read_text()
    assert rank_region(old) == rank_region(new)
    evidence["rank_control_sha256"] = hashlib.sha256(rank_region(new).encode()).hexdigest()
    for depth in (4, 8, 16):
        fixture = out / f"gather-{depth}.sv"
        fixture.write_text(f"""
module gather_eq(input logic [{depth-1}:0] selected,
 input logic [{depth-1}:0][146:0] payload, input logic [146:0] previous,
 output logic ok);
 logic [146:0] gold, combined, gate;
 always_comb begin
   gold=previous & ~147'(5); // clear valid and fwd_keep only
   combined='0;
   for(int k=0;k<{depth};k++) begin
     if(selected[k]) gold=payload[k] | 147'(4); // valid
     combined |= selected[k] ? payload[k] : '0;
   end
   gate=(|selected) ? (combined | 147'(4)) : (previous & ~147'(5));
 end
 assign ok=((selected & (selected-1'b1)) != '0) || (gold==gate);
endmodule
""")
        text = yosys(f"gather-{depth}", f"read_slang --top gather_eq {fixture}\n"
                     "prep -top gather_eq -flatten\nsat -prove ok 1 -verify\n")
        assert "SUCCESS!" in text
        evidence["proofs"][f"gather-{depth}"] = "one-hot/empty payload SAT PASS"
    print("PROOFS " + json.dumps(evidence["proofs"]), flush=True)


if __name__ == "__main__":
    if "TH_DATA_DIR" in os.environ:
        remote()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        mode = parser.add_mutually_exclusive_group(required=True)
        mode.add_argument("--snapshot", type=Path)
        mode.add_argument("--analyze-results", type=Path)
        parser.add_argument("--baseline", help="baseline revision for the selected review profile")
        parser.add_argument("--profile", choices=("control", "selection", "precompute", "multiplier", "boundary", "statcor", "loop-emit", "lbuf", "ckpt", "stq", "step1", "sbhead"), default="control")
        args = parser.parse_args()
        if args.snapshot:
            if not args.baseline:
                parser.error("--snapshot requires --baseline (A118 uses bfea01481)")
            snapshot(args.snapshot, args.baseline, args.profile)
        else:
            analyze_results(args.analyze_results)
