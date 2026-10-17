#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Isolated, paired control-cone proof and mapping review.

Local: python run_fo4_control_review.py --snapshot DIR --baseline REV
Remote: testharness_proxy.py py run_fo4_control_review.py --data DIR/inputs.tar.gz
        --tag fo4-control-<unique> --pull

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
           "core/fetch_B/frontend.sv")
MODULES = {"g6lc_rename", "store_buffer", "frontend", "g6lc_iq", "multiplier",
           "g6lc_lsq", "scoreboard", "instr_realign", "wt_dcache_wbuffer",
           "issue_read_operands", "alu", "mult"}


def snapshot(dest: Path, baseline: str) -> None:
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
    for name in CHANGED:
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
    for variant in ("baseline", "candidate"):
        flist = portable
        if variant == "baseline":
            for name in CHANGED:
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
        commands = []
        for variant, source in (("gold", "baseline/core/ooo/g6lc_rename.sv"),
                                ("gate", "core/ooo/g6lc_rename.sv")):
            commands += [
                f"read_slang --top g6lc_rename -G NR_HARTS={harts} "
                "-G PRF_ENTRIES=40 -G FPRF_ENTRIES=40 -G CKPT_DEPTH=4 "
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

    # Map both snapshots with identical options. The old/new package and
    # three consumers are switched by filelist, not by editing the snapshot.
    portable = (src / "portable.f").read_text().replace("@ROOT@", str(src))
    for variant in ("baseline", "candidate"):
        work = out / variant
        work.mkdir()
        flist = portable
        if variant == "baseline":
            for name in CHANGED:
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
        entries = [e for e in entries if e[2].lstrip("\\").split("$")[0] in MODULES]

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


if __name__ == "__main__":
    if "TH_DATA_DIR" in os.environ:
        remote()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        mode = parser.add_mutually_exclusive_group(required=True)
        mode.add_argument("--snapshot", type=Path)
        mode.add_argument("--analyze-results", type=Path)
        parser.add_argument("--baseline", help="revision containing the pre-A118 RTL")
        args = parser.parse_args()
        if args.snapshot:
            if not args.baseline:
                parser.error("--snapshot requires --baseline (A118 uses bfea01481)")
            snapshot(args.snapshot, args.baseline)
        else:
            analyze_results(args.analyze_results)
