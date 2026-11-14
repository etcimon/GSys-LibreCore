#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""native-fixes: full-harness evidence for three non-checkpoint Storamic fixes.

Runs on the remote testharness from the same frozen source tar as native-c2
(``run_native_c2`` provides extraction, tools, builds and simulation).

  A. load_unit page-offset interlock on in-order multi-hart builds
     (``storamic_lu_hazard.c``): passes with a Storamic role, the mutant that
     removes the hold is killed, the out-of-order target passes unchanged, and
     the same target without a Storamic role still shows the hazard (the hold
     is deliberately limited to Storamic builds; that run is the isolation
     witness, not a pass/fail gate on the hazard itself).
  B. Storamic VirtIO storage with ``G6LC_AI_DRAM_ISLAND_PORT``: the device
     shares crossbar port 2 instead of being reported unusable. A build of the
     island port without a Storamic role must still elaborate and run.
  C. Debug ``sbcs.sberror`` shim isolation: present in Storamic builds, absent
     from every build without a Storamic role. (Its behaviour is scored by the
     native-c2 and native-ckpt SBA cases.)

A missing build, report or symptom is incomplete, never a pass.
"""
import json
import os
import shutil
from pathlib import Path

import run_native_c2 as c2

FW_LU = "verif/tests/custom/storamic/storamic_lu_hazard.c"
FAIL_MMIO = 33
FAIL_PARTIAL = 34
HAZARD_CODES = (str(FAIL_MMIO), str(FAIL_PARTIAL))

T_BASE = c2.TARGET
T_SMT = "g6lc64_smt2"
T_OOO = "g6lc64_ooo"
T_AI = "g6lc64_smt2_ai"
DEFS_IO = c2.DEFS_IO
DEFS_ISL = "G6LC_AI_DRAM_ISLAND_PORT"
DEFS_ISL_IO = DEFS_IO + "+" + DEFS_ISL

SHIM_SYMBOL = "gen_dmi_sberror"
LU_MUTANT = ("lu-smt-hold-off", "core/load_unit.sv",
             "  localparam bit LuSmtHold = !CVA6Cfg.OoOEn && CVA6Cfg.NrHarts > 1 &&\n",
             "  localparam bit LuSmtHold = 1'b0 && !CVA6Cfg.OoOEn && CVA6Cfg.NrHarts > 1 &&\n")

# (tag, target, defines, has Storamic role)
BUILDS = [
    ("fx-smt-io", T_SMT, DEFS_IO, True),
    ("fx-smt-def", T_SMT, "", False),
    ("fx-ooo-io", T_OOO, DEFS_IO, True),
    ("fx-isl-io", T_BASE, DEFS_ISL_IO, True),
    ("fx-isl-def", T_BASE, DEFS_ISL, False),
]
# Island actually present (AiCfg.MatrixEn). Optional: reported as omitted when
# no existing flow builds that target with g6lc_tb.cpp.
OPTIONAL_BUILD = ("fx-ai-isl-io", T_AI, DEFS_ISL_IO, True)


def has_symbol(model_dir, symbol):
    """True when any generated source of a Verilator model names ``symbol``."""
    exts = {".cpp", ".h", ".hpp", ".cc", ".mk", ".d"}
    for path in Path(model_dir).rglob("*"):
        if path.is_file() and path.suffix in exts:
            try:
                if symbol in path.read_text(errors="replace"):
                    return True
            except OSError:
                continue
    return False


def judge_lu(sim, want):
    """``want``: 'pass' (firmware success) or 'hazard' (one of its two codes)."""
    if sim.get("fatal"):
        return False, "fatal marker in log"
    if want == "pass":
        return bool(sim.get("success")), f"fail_code={sim.get('fail_code')}"
    return ((not sim.get("success")) and sim.get("fail_code") in HAZARD_CODES,
            f"success={sim.get('success')} fail_code={sim.get('fail_code')}")


def verdict(rep):
    if rep.get("incomplete"):
        return "incomplete"
    ok = bool(rep["cases"]) and all(c.get("pass") for c in rep["cases"].values())
    ok = ok and bool(rep["mutants"]) and all(
        m.get("killed") for m in rep["mutants"].values())
    return "pass" if ok else "fail"


def execute(ctx):
    rep = {"cases": {}, "mutants": {}, "builds": ctx.builds, "incomplete": [],
           "omitted": []}
    lu_elf = ctx.compile_fw(FW_LU, "lu-hazard", [])
    pos_elf = ctx.compile_fw(c2.FW_VIRTIO, "fx-virtio-pos",
                             ["-DSTORAMIC_COHERENT_DMA"])
    neg_elf = ctx.compile_fw(c2.FW_VIRTIO, "fx-virtio-neg",
                             ["-DSTORAMIC_COHERENT_DMA", "-DORACLE_NEGATIVE"])
    if None in (lu_elf, pos_elf, neg_elf):
        rep["incomplete"].append("firmware failed to compile")
        return rep

    for tag, target, defines, _ in BUILDS:
        ok, _dt = ctx.ensure_model(tag, defines, target=target)
        if not ok:
            rep["incomplete"].append(
                f"{tag}: build failed ({ctx.tb_flow_error(tag) or 'see log'})")
    if rep["incomplete"]:
        return rep

    def lu_case(name, tag, want):
        sim = ctx.run_sim(tag, lu_elf)
        ok, why = judge_lu(sim, want)
        rep["cases"][name] = {"pass": ok, "why": "" if ok else why,
                              "want": want, "success": sim.get("success"),
                              "fail_code": sim.get("fail_code"),
                              "seconds": sim.get("seconds"),
                              "log": f"sim-{tag}.log"}

    # ---- A. load_unit interlock ---------------------------------------------
    lu_case("lu-smt2-storamic", "fx-smt-io", "pass")
    lu_case("lu-ooo-storamic", "fx-ooo-io", "pass")
    lu_case("lu-base-island", "fx-isl-io", "pass")
    # Isolation witness: no Storamic role -> the hold is not elaborated and
    # the in-order multi-hart hazard is still there, exactly as before.
    lu_case("lu-smt2-no-storamic-unchanged", "fx-smt-def", "hazard")
    lu_case("lu-base-island-no-storamic", "fx-isl-def", "pass")

    # ---- B. VirtIO storage with the island port ------------------------------
    nat_sem = {"m2_aw": 0, "m2_ar": 0, "pending": 0, "violations": 0}
    rep["cases"]["island-virtio-pos"] = c2._case(
        ctx, "island-virtio-pos", "fx-isl-io", pos_elf, expect_fields=nat_sem,
        expect_gt={"beats2": 0}, expect_success=True, require_topo=False)
    rep["cases"]["island-virtio-neg"] = c2._case(
        ctx, "island-virtio-neg", "fx-isl-io", neg_elf,
        expect_fields={"violations": 0, "pending": 0}, expect_success=False,
        expect_fail_tohost=16, require_topo=False)

    tag, target, defines, _ = OPTIONAL_BUILD
    ok, _dt = ctx.ensure_model(tag, defines, target=target)
    if ok:
        rep["cases"]["ai-island-virtio-pos"] = c2._case(
            ctx, "ai-island-virtio-pos", tag, pos_elf, expect_fields=nat_sem,
            expect_gt={"beats2": 0}, expect_success=True, require_topo=False)
    else:
        why = ctx.tb_flow_error(tag)
        if why:
            rep["omitted"].append(f"{tag} ({target}): {why}")
        else:
            rep["incomplete"].append(f"{tag}: build failed (see log)")

    # ---- C. sberror shim isolation -------------------------------------------
    for tag, _target, _defines, storamic in BUILDS:
        present = has_symbol(ctx.src / f"work-ver-{tag}", SHIM_SYMBOL)
        rep["cases"][f"shim-{tag}"] = {
            "pass": present == storamic, "present": present, "want": storamic,
            "why": "" if present == storamic else "sberror shim presence"}

    if not all(c.get("pass") for c in rep["cases"].values()):
        rep["incomplete"].append("positive cases failed; mutant not run")
        return rep

    # ---- mutant: remove the multi-hart hold in a Storamic build --------------
    name, rel, anchor, repl = LU_MUTANT
    mtree = ctx.src.parent / f"src-{name}"
    if not mtree.exists():
        shutil.copytree(ctx.src, mtree, symlinks=True,
                        ignore=shutil.ignore_patterns("work-ver-*"))
    mpath = mtree / rel
    text = mpath.read_text()
    if text.count(anchor) != 1:
        rep["incomplete"].append(f"{name}: anchor count={text.count(anchor)}")
        return rep
    mpath.write_text(text.replace(anchor, repl))
    mctx = c2.Ctx(mtree, ctx.out, ctx.verilator, ctx.vroot, ctx.env)
    ok, _dt = mctx.ensure_model(name, DEFS_IO, target=T_SMT)
    ctx.builds.extend(mctx.builds)
    if not ok:
        rep["incomplete"].append(f"{name}: mutant build failed")
        return rep
    sim = mctx.run_sim(name, mctx.compile_fw(FW_LU, "lu-hazard-mut", []))
    killed, why = judge_lu(sim, "hazard")
    rep["mutants"][name] = {"killed": killed, "why": "" if killed else why,
                            "fail_code": sim.get("fail_code"),
                            "success": sim.get("success")}
    return rep


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    """run_leaf.py stage entry for ``native-fixes``."""
    data = Path(data)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rep = {"cases": {}, "mutants": {}, "incomplete": []}

    def _inc(msg):
        rep["incomplete"].append(msg)
        rep["verdict"] = "incomplete"
        (out / "native-fixes.json").write_text(json.dumps(rep, indent=2))
        raise c2._Incomplete(msg)

    src_tar = data / c2.SRC_TAR_NAME
    expected = (manifest.get("sources") or {}).get(c2.SRC_TAR_NAME)
    if not src_tar.is_file():
        _inc(f"missing {c2.SRC_TAR_NAME} in run data")
    actual = c2.sha256_file(src_tar)
    rep["src_tar_sha256"] = actual
    if expected and actual != expected:
        _inc("source tar sha256 mismatch vs manifest")
    run_dir = Path(os.environ.get("TH_RUN_DIR") or out.parent)
    work = run_dir / "work" / "native-fixes"
    try:
        src = c2._extract_tar(src_tar, work / "src")
    except Exception as exc:  # noqa: BLE001 - reported as incomplete
        _inc(f"source tar extract failed: {exc}")
    tools, verilator_use, vroot_use, terr = c2._tools(src)
    rep["tools"] = tools
    if terr:
        _inc(terr)
    env = c2.base_env(verilator_use, vroot_use)
    ctx = c2.Ctx(src, out, verilator_use, vroot_use, env)
    rep.update(execute(ctx))
    rep["verdict"] = verdict(rep)
    (out / "native-fixes.json").write_text(json.dumps(rep, indent=2))
    for name, case in rep["cases"].items():
        outcomes.append({"native_fixes": name, "pass": bool(case.get("pass"))})
    for name, mut in rep["mutants"].items():
        outcomes.append({"native_fixes": "mutant-" + name,
                         "killed": bool(mut["killed"]), "pass": bool(mut["killed"])})
    outcomes.append({"native_fixes": rep["verdict"], "verdict": rep["verdict"],
                     "omitted": rep.get("omitted", []),
                     "incomplete": rep.get("incomplete", []),
                     "pass": rep["verdict"] == "pass"})
    if rep["verdict"] == "pass":
        return
    if rep["verdict"] == "fail":
        bad = [k for k, v in rep["cases"].items() if not v.get("pass")]
        bad += [k for k, v in rep["mutants"].items() if not v.get("killed")]
        raise RuntimeError("native-fixes FAIL: " + ", ".join(bad or ["unknown"]))
    raise c2._Incomplete("; ".join(rep.get("incomplete") or ["incomplete"]))
