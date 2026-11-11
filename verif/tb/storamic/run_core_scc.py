# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""core-scc: full-core gate-level combinational-loop/latch proof.

Runs the CPU41-style owned-Yosys flow over the complete cva6 core under the
cpu-origin bench configuration (g6lc_core_scc_top wrapper, cv64a6 via
cva6_config_pkg, OriginEnabled=1):

    read_slang -> hierarchy -check -> proc -> flatten -> techmap -> scc

Requires exactly 0 combinational SCCs and 0 latches on the production
closure. The result is the gate-level `basis` for every identity pinned in
cpu_strict_pins.json: a pinned UNOPTFLAT identity is a known, proof-backed
residual diagnostic, not an undetected loop.

cpu-strict-pins reads manifest["core_scc"] (written here) and is `incomplete`
unless this stage passed on the identical source manifest. The csr_regfile
mask/DirVecOnly revert oracle is covered by the existing csr-scc stage's
admission-mutant, which reintroduces the fixed loop in isolation.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

TOP = "g6lc_core_scc_top"
WRAPPER = "g6lc_core_scc_top.sv"
# package cva6_config_pkg is provided by cv64a6_imafdc_sv39_config_pkg.sv,
# already inside plan["files"]. g6lc64_smt2_config_pkg.sv is a dormant
# alternate declaring the same package and must NOT be compiled (it would
# duplicate the package). .svh support headers resolve via -I incdirs.
EXTRA_SV = []
SCC_TIMEOUT = 5400


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _rebuild_tree(data, out, plan):
    """Rebuild the repo-relative source tree from flat basename uploads.

    Copies every closure entry (compile units + .svh support headers + the
    dormant config package) so -I include resolution sees the same layout as
    the cpu-origin bench. Only plan["files"] are passed to read_slang."""
    tree = out / "core-scc-src"
    for rel in list(plan["files"]) + list(plan.get("support_files", [])):
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data / Path(rel).name, dst)
    return tree


def _scc_script(tree, plan, wrapper_path):
    incs = " ".join("-I" + str(tree / d) for d in plan["incdirs"])
    defs = " ".join("-D" + d.removeprefix("+define+")
                    for d in plan["defines"])
    files = " ".join(str(tree / rel) for rel in
                     list(plan["files"]) + EXTRA_SV)
    return ("read_slang --std 1800-2017 --threads 4 --top " + TOP + " " +
            incs + " " + defs + " " + files + " " + str(wrapper_path) + "\n"
            "hierarchy -check -top " + TOP + "\n"
            "proc\nflatten\ntechmap\n"
            "scc\n"
            "select -assert-none t:$dlatch t:$_DLATCH_*\n")


def _run_yosys(yosys, script, log_path, timeout):
    started = time.monotonic()
    with log_path.open("w") as log:
        result = subprocess.run([str(yosys), "-s", str(script)],
                                stdout=log, stderr=subprocess.STDOUT,
                                timeout=timeout)
    text = log_path.read_text(errors="replace")
    found = re.findall(r"Found (\d+) SCCs", text)
    sccs = max((int(n) for n in found), default=None)
    latch_hits = len(re.findall(r"t:\$dlatch|t:\$_DLATCH_", text))
    return result.returncode, sccs, latch_hits, text, \
        round(time.monotonic() - started, 1)


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "core-scc" not in stages:
        return
    from yosys_bin import yosys_bin
    plan = json.loads((data / "cpu_origin_plan.json").read_text())
    yosys = Path(yosys_bin())
    manifest["yosys"], manifest["yosys_sha256"] = str(yosys), _sha(yosys)

    tree = _rebuild_tree(data, out, plan)
    wrapper = out / WRAPPER
    shutil.copyfile(data / WRAPPER, wrapper)

    script = out / "core-scc.ys"
    script.write_text(_scc_script(tree, plan, wrapper))
    log = out / "core-scc.log"
    rc, sccs, latch_hits, text, seconds = _run_yosys(
        yosys, script, log, SCC_TIMEOUT)

    sources_sha = hashlib.sha256(json.dumps(
        manifest.get("sources", {}), sort_keys=True).encode()).hexdigest()
    result = {
        "stage": "core-scc", "top": TOP, "origin_enabled": 1,
        "files": len(plan["files"]) + len(EXTRA_SV),
        "sccs": sccs, "latches": latch_hits, "rc": rc,
        "seconds": seconds, "yosys": str(yosys),
        "yosys_sha256": manifest["yosys_sha256"],
        "sources_sha256": sources_sha,
        "log_sha256": _sha(log),
    }
    (out / "core-scc-result.json").write_text(json.dumps(result, indent=2))

    if rc != 0:
        raise RuntimeError(f"CORE_SCC_FLOW rc={rc} "
                           f"tail={text[-400:]!r}")
    if sccs != 0:
        raise RuntimeError(f"CORE_SCC_PRODUCTION sccs={sccs} "
                           f"latches={latch_hits}")
    # `select -assert-none` already gates latches; rc==0 above means 0.
    result["pass"] = True
    (out / "core-scc-result.json").write_text(json.dumps(result, indent=2))
    manifest["core_scc"] = result
    outcomes.append({"core_scc": "production", "sccs": 0,
                     "latches": 0, "seconds": seconds, "pass": True})
    manifest["core_scc_generated"] = {
        str(p): _sha(p) for p in (wrapper, script, log)}
