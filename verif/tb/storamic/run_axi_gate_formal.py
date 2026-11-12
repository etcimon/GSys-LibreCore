# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""axi-gate-formal: bounded formal for the C4 CPU pause/drain provider.

Remote leaf for the two small formal wrappers added for the CPU producer
pause/drain provider, run through the owned yosys-smtbmc/yices toolchain
(same frontend as run_checkpoint_route.py::_formal): read_slang with
-DSYNTHESIS -DFORMAL, prep/flatten/async2sync/dffunmap/write_smt2, then
yosys-smtbmc -s yices.

Two designs are qualified:
  * formal_g6lc_storamic_axi_gate  (P1..P6 + covers; mutants m-a/m-b/m-c)
  * formal_g6lc_storamic_cpu_pause (Q1..Q4 + covers; mutant m-d)

Golden designs must PASS the assertion BMC and reach every cover. Each
patched mutant must FAIL the assertion proof — a surviving mutant, an
unreached cover, or a solver result that is neither PASSED nor FAILED fails
the stage (RuntimeError -> incomplete), never silently passes.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

GATE_DUT = "corev_apu/storamic/g6lc_storamic_axi_gate.sv"
PAUSE_DUT = "corev_apu/storamic/g6lc_storamic_cpu_pause.sv"
GATE_WRAP = "verif/tb/storamic/formal_g6lc_storamic_axi_gate.sv"
PAUSE_WRAP = "verif/tb/storamic/formal_g6lc_storamic_cpu_pause.sv"
FILES = [GATE_DUT, PAUSE_DUT, GATE_WRAP, PAUSE_WRAP]

DESIGNS = [
    {"tag": "axi-gate", "top": "formal_g6lc_storamic_axi_gate",
     "dut": GATE_DUT, "wrapper": GATE_WRAP,
     "depth": 28, "cover_depth": 56},
    {"tag": "cpu-pause", "top": "formal_g6lc_storamic_cpu_pause",
     "dut": PAUSE_DUT, "wrapper": PAUSE_WRAP,
     "depth": 28, "cover_depth": 36},
]

# Patched-copy mutants: (tag, design tag, old source, new source). `old` must
# occur exactly once in the DUT source or the patch is rejected (incomplete).
MUTANTS = [
    # m-a: closed_o drops the w_owed (w_cnt_q==0) term -> can assert while W
    # beats are still owed -> P1/P2 violated.
    ("m-a", "axi-gate",
     "  assign closed_o   = close_i && !aw_commit_q && !ar_commit_q && !overflow_q &&\n"
     "                      (wr_cnt_q == '0) && (rd_cnt_q == '0) && (w_cnt_q == '0);",
     "  assign closed_o   = close_i && !aw_commit_q && !ar_commit_q && !overflow_q &&\n"
     "                      (wr_cnt_q == '0) && (rd_cnt_q == '0);"),
    # m-b: new AR admitted while close_i (drop the !close_i term on ar_ready)
    # -> a downstream AR handshake can start after closed_o -> P4 violated.
    ("m-b", "axi-gate",
     "    up_resp_o.ar_ready = !close_i && !ar_commit_q && !overflow_q;",
     "    up_resp_o.ar_ready = !ar_commit_q && !overflow_q;"),
    # m-c: W passes downstream when w_owed==0 (drop the w_cnt_q!=0 term on
    # dn w_valid) -> a W handshake with no outstanding write -> legality oracle.
    ("m-c", "axi-gate",
     "    dn_req_o.w_valid  = up_req_i.w_valid && (w_cnt_q != '0);",
     "    dn_req_o.w_valid  = up_req_i.w_valid;"),
    # m-d: pause sequencer skips Close (S_HALT -> S_PAUSED) -> paused_o reached
    # without the Close phase -> Q4 violated.
    ("m-d", "cpu-pause",
     "          else if (core_drained_i) state_q <= S_CLOSE;",
     "          else if (core_drained_i) state_q <= S_PAUSED;"),
]


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _build_tree(data, out):
    """Copy the flat basename uploads into a repo-relative tree and hash them."""
    tree = out / "axi-gate-formal-src"
    hashes = {}
    for rel in FILES:
        dest = tree / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data / Path(rel).name, dest)
        hashes[rel] = _sha(dest)
    return tree, hashes


def _patch_exact(src, old, new, tag):
    count = src.count(old)
    if count != 1:
        raise RuntimeError(
            f"axi-gate-formal mutant {tag}: patch anchor occurs {count}x "
            f"(expected exactly 1); stage incomplete")
    return src.replace(old, new)


def _solve_all(data, out, manifest, tree, outcomes):
    from yosys_bin import yosys_bin
    tools = [Path(shutil.which(n) or "")
             for n in ("yosys-smtbmc", "yices-smt2")]
    if not all(t.is_file() for t in tools):
        raise FileNotFoundError("axi-gate-formal requires "
                                "yosys-smtbmc and yices-smt2")
    smtbmc, solver = tools
    deps = list((smtbmc.resolve().parent.parent / "share/yosys/python3")
                .glob("*.py"))
    files = {str(p.resolve()): _sha(p)
             for p in sorted([smtbmc, solver, *deps, Path(sys.executable)])}
    if "axi_gate_formal_tools" in manifest and \
            files != manifest["axi_gate_formal_tools"]["files"]:
        raise RuntimeError("STORAMIC_AXI_GATE_FORMAL_TOOL_IDENTITY")
    manifest["axi_gate_formal_tools"] = {
        "files": files, "engine": "yosys-smtbmc/yices",
        "solver_version": subprocess.check_output(
            [str(solver), "--version"], text=True).strip(),
        "smtbmc_sha256": _sha(smtbmc), "yices_sha256": _sha(solver)}
    yosys = Path(yosys_bin())
    env = dict(os.environ)
    env["PATH"] = str(solver.parent) + os.pathsep + env.get("PATH", "")

    def frontend(top, dut_path, wrapper_path, tag):
        inputs = " ".join(str(p) for p in (dut_path, wrapper_path))
        return (f"read_slang --top {top} -DSYNTHESIS -DFORMAL "
                f"-I{tree} " + inputs +
                f"; prep -top {top}; flatten; async2sync; "
                f"dffunmap; write_smt2 -wires ")

    def smt_for(design, dut_path, tag):
        smt = out / f"axi-gate-formal-{tag}.smt2"
        command = frontend(design["top"], dut_path,
                           tree / design["wrapper"], tag) + str(smt)
        (out / f"axi-gate-formal-{tag}.ys").write_text(command)
        log = out / f"axi-gate-formal-{tag}-frontend.log"
        with log.open("w") as fh:
            subprocess.run([str(yosys), "-p", command], stdout=fh,
                           stderr=subprocess.STDOUT, check=True, timeout=300)
        return smt

    def solve(smt, tag, depth, cover=False):
        command = [str(smtbmc), "-s", "yices", "-t", str(depth), "--noprogress"]
        if cover:
            command.append("-c")
        command.append(str(smt))
        result = subprocess.run(command, env=env, capture_output=True,
                                text=True, timeout=900)
        (out / f"axi-gate-formal-{tag}-smtbmc.log").write_text(
            result.stdout + result.stderr)
        return result.returncode, result.stdout + result.stderr

    results = []
    designs = {d["tag"]: d for d in DESIGNS}

    # ---- golden designs: assertions must PASS, every cover must be reached --
    for design in DESIGNS:
        tag = design["tag"]
        smt = smt_for(design, tree / design["dut"], tag)
        rc, text = solve(smt, tag, design["depth"])
        ok = rc == 0 and "Status: PASSED" in text
        results.append({"case": f"axi-gate-formal-{tag}",
                        "pass": bool(ok), "rc": rc})
        outcomes.append({"axi_gate_formal": tag, "pass": bool(ok)})
        if not ok:
            raise RuntimeError(f"axi-gate-formal {tag} assertions rc={rc}")
        rc, text = solve(smt, tag + "-cover", design["cover_depth"],
                         cover=True)
        ok = rc == 0 and "Status: PASSED" in text
        results.append({"case": f"axi-gate-formal-{tag}-cover",
                        "pass": bool(ok), "rc": rc})
        outcomes.append({"axi_gate_formal": tag + "-cover",
                                "pass": bool(ok)})
        if not ok:
            raise RuntimeError(
                f"axi-gate-formal {tag} cover unreached/incomplete rc={rc}")

    # ---- mutants: patched DUT copy must FAIL the assertion proof ----------
    mut_dir = out / "axi-gate-formal-mut-src"
    mut_dir.mkdir(exist_ok=True)
    for mtag, dtag, old, new in MUTANTS:
        design = designs[dtag]
        src = (tree / design["dut"]).read_text(encoding="utf-8")
        patched = _patch_exact(src, old, new, mtag)
        mut_file = mut_dir / f"{dtag}-{mtag}-{Path(design['dut']).name}"
        mut_file.write_text(patched, encoding="utf-8")
        smt = smt_for(design, mut_file, mtag)
        rc, text = solve(smt, mtag, design["depth"])
        # A killed mutant yields Status: FAILED (assertion violated). rc!=0 or
        # a PASSED/timeout/incomplete result means the mutant survived -> fail.
        ok = rc != 0 and "Status: FAILED" in text
        results.append({"case": f"axi-gate-formal-{mtag}",
                        "pass": bool(ok), "rc": rc})
        outcomes.append({"axi_gate_formal": mtag, "pass": bool(ok)})
        if not ok:
            raise RuntimeError(
                f"axi-gate-formal mutant {mtag} survived rc={rc}")

    manifest["axi_gate_formal"] = {
        "engine": "yosys-smtbmc/yices",
        "yosys": str(yosys), "yosys_sha256": _sha(yosys),
        "designs": [{"tag": d["tag"], "depth": d["depth"],
                     "cover_depth": d["cover_depth"]} for d in DESIGNS],
        "mutants": [m[0] for m in MUTANTS],
        "results": results}
    (out / "axi-gate-formal-result.json").write_text(json.dumps(
        {"stage": "axi-gate-formal", "results": results}, indent=2))



def run(data, out, stages, manifest, builds, outcomes, verilator,
        build_model):
    if "axi-gate-formal" not in stages:
        return
    tree, hashes = _build_tree(data, out)
    manifest["axi_gate_formal_sources"] = hashes
    _solve_all(data, out, manifest, tree, outcomes)
