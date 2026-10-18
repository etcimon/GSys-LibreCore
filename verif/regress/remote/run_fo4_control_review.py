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
                 "build-platform/scripts/tc_sram_timing_stub.sv",
                 "verif/tb/core/multiplier_sbs/tb_mul_sbs.sv"):
        files[name] = (root / name).read_bytes()
    files["portable.f"] = text.replace(root.as_posix(), "@ROOT@").encode()
    files["host-param-map.json"] = (flist.parent / "param-map.json").read_bytes()
    profile_files = {
        "control": CHANGED,
        "selection": ("core/ooo/g6lc_iq.sv", "core/ooo/g6lc_lsq.sv"),
        "precompute": ("core/ooo/g6lc_iq.sv", "core/ooo/g6lc_rename.sv", "core/store_buffer.sv"),
    }
    changed = profile_files[profile]
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

    if os.environ.get("CONTROL_MODE") == "pipe-fixture":
        # A123 protocol witness: the svt-pipe fixture and its emitted twin,
        # each under the latency-agnostic testbench, three seeds. The twin's
        # `pipe_contract` module is renamed so the same testbench selects it.
        vl = "/opt/testharness/toolchains/verilator-v5.008/bin/verilator"
        evidence["simulator"] = subprocess.check_output([vl, "--version"], text=True).strip()
        gold = data / "pipe_contract.sv"
        twin_src = data / "pipe_contract__svt.sv"
        tb = data / "tb_pipe_contract.sv"
        for f in (gold, twin_src, tb):
            evidence["sources"][f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
        twin = out / "pipe_contract_svt.sv"
        text = twin_src.read_text()
        assert text.count("module pipe_contract (") == 1
        twin.write_text(text.replace("module pipe_contract (", "module pipe_contract_svt (", 1)
                        .replace("module pipe_contract_side (", "module pipe_contract_side_svt (", 1))
        for name, srcs, defs in (("gold", [gold, tb], []), ("twin", [twin, tb], ["+define+SVT_TWIN"])):
            obj = out / f"obj-{name}"
            run(f"pipe-build-{name}", [vl, "-O0", "--binary", "--timing", "--assert", "-Wno-fatal",
                "-Wno-WIDTH", "-Wno-UNOPTFLAT", *defs, *map(str, srcs),
                "--top-module", "tb_pipe_contract", "--Mdir", str(obj), "-j", "4"], timeout=600)
            for seed in (7, 19, 23):
                log = run(f"pipe-sim-{name}-{seed}", [str(obj / "Vtb_pipe_contract"), f"+seed={seed}"], timeout=300)
                assert "PASS" in log and "errors=0" in log, f"{name} seed {seed}"
                evidence["proofs"][f"pipe-{name}-{seed}"] = log.strip().splitlines()[-2][:200]
        # mapped twin: the stage count and the data path it leaves on Nangate45
        for name, path, top in (("gold", gold, "pipe_contract"), ("twin", twin, "pipe_contract_svt")):
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
        if module not in {"g6lc_iq", "g6lc_rename", "store_buffer"}:
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
        parser.add_argument("--profile", choices=("control", "selection", "precompute"), default="control")
        args = parser.parse_args()
        if args.snapshot:
            if not args.baseline:
                parser.error("--snapshot requires --baseline (A118 uses bfea01481)")
            snapshot(args.snapshot, args.baseline, args.profile)
        else:
            analyze_results(args.analyze_results)
