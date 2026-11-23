#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""native-ckpt-w2 stage: Storamic W2 in-order multi-hart (SMT2 + multi-core).

Covers both axes of W2:
  - SMT2 (g6lc64_smt2, NrHarts=2 L2En=1) and SMT2+L3 (g6lc64_smt2_l3,
    NrHarts=2 L2En=1 L3En=1): single-hart-main flow, cold recovery, and
    dual-active storamic_ckpt_mh (both harts live across SAVE/RESTORE).
  - Multi-core (cv64a6_imafdc_sv39 + G6LC_STORAMIC_MC2, NrCores=2 + coherence
    hub + L2): dual-active storamic_ckpt_mh where core 1 warms its own private
    L1 D$ and I$ with B before RESTORE and verifies A afterward with no flush,
    plus negative oracle (expects B -> FAIL_PEER_DATA = 25) and cold recovery.
  - Mutants:
      w4-no-core1-pause: pauses core 0 only on MC2 -> killed by
        STORAMIC_CKPT_VIOLATION or FAIL_PEER_DATA (25).
      w5-no-smt-l2-inval: suppresses L2 invalidation on g6lc64_smt2 -> killed
        by FAIL_DATA_RESTORED (16).
"""
import json
import os
import shutil
from pathlib import Path

import run_native_c2 as c2
import run_native_ckpt as ck

FW_MH = "verif/tests/custom/storamic/storamic_ckpt_mh.c"
CLUSTER = "corev_apu/src/g6lc_cluster.sv"

T_SMT2 = "g6lc64_smt2"
T_SMT2_L3 = "g6lc64_smt2_l3"
DEFS_MC2 = ck.DEFS_CKPT + "+G6LC_STORAMIC_MC2"

FAIL_PEER_DATA = 25
FAIL_PEER_CODE = 26

MUTANTS = [
    ("w4-no-core1-pause", c2.TARGET, DEFS_MC2,
     [(CLUSTER,
       "        .storamic_pause_i       (core_sto_pause),\n"
       "        .storamic_drained_o     (core_sto_drained_w[c])",
       "        .storamic_pause_i       ((c == 0) ? core_sto_pause : 1'b0),\n"
       "        .storamic_drained_o     (core_sto_drained_w[c])"),
      (CLUSTER,
       "  assign all_cores_drained = &core_sto_drained_w;",
       "  assign all_cores_drained = core_sto_drained_w[0];")],
     "mh", ("fail-or-violation", (FAIL_PEER_DATA, FAIL_PEER_CODE))),
    ("w5-no-smt-l2-inval", T_SMT2, ck.DEFS_CKPT,
     [(CLUSTER,
       "        .l2_inval_all_i        (llc_inval_q),\n"
       "        .l2_inval_all_done_o   (l2_inval_all_done)\n"
       "    );",
       "        .l2_inval_all_i        (1'b0),\n"
       "        .l2_inval_all_done_o   ()\n"
       "    );\n    assign l2_inval_all_done = llc_inval_q;")],
     "flow", ("fail", ck.FAIL_DATA_RESTORED)),
]


def compile_mh(ctx, tag, flags):
    """Compile standalone dual-hart firmware (no crt.S/syscalls.c)."""
    elf = ctx.src / f"native_{tag}.elf"
    argv = [f"{c2.RISCV}/bin/riscv-none-elf-gcc", "-static",
            "-mcmodel=medany", "-march=rv64imafdc", "-mabi=lp64d",
            "-fvisibility=hidden", "-nostdlib", "-nostartfiles", "-O2",
            "-T", f"{c2.COMMON}/link_verilator.ld", FW_MH,
            "-lgcc", *flags, "-o", str(elf)]
    rc, _, _ = c2.sh(argv, ctx.src, ctx.env, ctx.out / f"gcc-{tag}.log")
    return elf if rc == 0 else None


def judge_mutant(expectation, sim):
    kind, want = expectation
    if kind == "fail":
        return sim.get("fail_code") == str(want)
    if kind == "fail-or-violation":
        codes = {str(x) for x in want}
        return (sim.get("fail_code") in codes or
                ck.VIOLATION in sim.get("text_markers", ""))
    return False


def verdict(rep):
    if rep.get("incomplete"):
        return "incomplete"
    cases_ok = bool(rep["cases"]) and all(c["pass"] for c in rep["cases"].values())
    mutants_ok = (len(rep["mutants"]) == len(MUTANTS) and
                  all(m["killed"] for m in rep["mutants"].values()))
    return "pass" if cases_ok and mutants_ok else "fail"


def execute(ctx):
    rep = {"cases": {}, "mutants": {}, "builds": ctx.builds, "incomplete": []}

    for tag, target, defs in (
        ("ckpt-smt2", T_SMT2, ck.DEFS_CKPT),
        ("ckpt-smt2-l3", T_SMT2_L3, ck.DEFS_CKPT),
        ("ckpt-mc2", c2.TARGET, DEFS_MC2),
    ):
        ok, _ = ctx.ensure_model(tag, defs, target=target)
        if not ok:
            rep["incomplete"].append(f"{tag} ({target}) harness build failed")
    if rep["incomplete"]:
        return rep

    flow_elf = ctx.compile_fw(ck.FW_CKPT, "w2-flow", [])
    cold_elf = ctx.compile_fw(ck.FW_CKPT, "w2-cold", ["-DCKPT_COLD"])
    mh_elf = compile_mh(ctx, "w2-mh", [])
    mh_neg_elf = compile_mh(ctx, "w2-mh-neg", ["-DCKPT_ORACLE_EXPECT_B"])
    if None in (flow_elf, cold_elf, mh_elf, mh_neg_elf):
        rep["incomplete"].append("W2 firmware failed to compile")
        return rep
    fw_by_key = {"flow": flow_elf, "mh": mh_elf}

    def case(name, tag, elf, want_success, want_fail, expect_state,
             want_profile, exact_preloads=None):
        sim = ck.run_sim(ctx, tag, elf)
        s_ok, why = ck.state_ok(sim["state"], expect_state)
        prof = c2.parse_profile((ctx.out / sim["log"]).read_text(errors="replace"))
        sim["profile"] = prof
        p_ok = bool(prof) and all(prof.get(k) == v for k, v in want_profile.items())
        if want_success:
            v_ok = sim["success"] and sim["errors"] == 0
        else:
            v_ok = (not sim["success"]) and sim["fail_code"] == str(want_fail)
        pre_ok = (sim["preloads"] == exact_preloads
                  if exact_preloads is not None else sim["preloads"] >= 1)
        sim["pass"] = bool(v_ok and s_ok and p_ok and pre_ok)
        sim["why"] = (why if not s_ok else
                      ("" if p_ok else f"profile {prof} != {want_profile}") or
                      ("" if pre_ok else f"preloads={sim['preloads']}") or
                      ("" if v_ok else "firmware verdict"))
        rep["cases"][name] = sim
        return sim

    common = {"initialized": "1", "locked": "0", "busy": "0",
              "providers": "1f", "policy_ready": "1", "errors": "000",
              "present": "1"}
    p_smt2 = {"ooo": 0, "harts": 2, "cores": 1, "l2": 1, "l3": 0, "supported": 1}
    p_smt2l3 = {"ooo": 0, "harts": 2, "cores": 1, "l2": 1, "l3": 1, "supported": 1}
    p_mc2 = {"ooo": 0, "harts": 1, "cores": 2, "l2": 1, "l3": 0, "supported": 1}

    # ---- SMT2 (NrHarts=2, L2En=1) ----
    case("smt2-flow", "ckpt-smt2", flow_elf, True, None,
         dict(common, valid="1", generation="1", pauses=(">=", 3),
              releases=(">=", 3), done=(">=", 2), error="0",
              llc_invals=(">=", 3), l2_hits=(">=", 1)), p_smt2)
    case("smt2-dual-active", "ckpt-smt2", mh_elf, True, None,
         dict(common, valid="1", generation="1", done=(">=", 2), error="0",
              llc_invals=(">=", 3), l2_hits=(">=", 1)), p_smt2)
    case("smt2-cold-recovery", "ckpt-smt2", cold_elf, True, None,
         dict(common, valid="1", generation="1", reset_gen="1",
              rec_active="0", rec_failed="0", done=(">=", 2), error="0",
              llc_invals=(">=", 3)), p_smt2, exact_preloads=1)

    # ---- SMT2 + L3 (NrHarts=2, L2En=1, L3En=1) ----
    case("smt2l3-dual-active", "ckpt-smt2-l3", mh_elf, True, None,
         dict(common, valid="1", generation="1", done=(">=", 2), error="0",
              llc_invals=(">=", 3), l2_hits=(">=", 1)), p_smt2l3)

    # ---- Multi-core (NrCores=2, coherence hub + L2) ----
    case("mc2-dual-active", "ckpt-mc2", mh_elf, True, None,
         dict(common, valid="1", generation="1", done=(">=", 2), error="0",
              llc_invals=(">=", 3), l2_hits=(">=", 1)), p_mc2)
    case("mc2-oracle-peer-b", "ckpt-mc2", mh_neg_elf, False, FAIL_PEER_DATA,
         dict(common, valid="1", generation="1", done=(">=", 2),
              llc_invals=(">=", 3)), p_mc2)
    case("mc2-cold-recovery", "ckpt-mc2", cold_elf, True, None,
         dict(common, valid="1", generation="1", reset_gen="1",
              rec_active="0", rec_failed="0", done=(">=", 2), error="0",
              llc_invals=(">=", 3)), p_mc2, exact_preloads=1)

    if not all(c["pass"] for c in rep["cases"].values()):
        rep["incomplete"].append("positive cases failed; mutants not run")
        return rep

    # ---- W2 mutants ---------------------------------------------------------
    for name, target, defs, patches, fw_key, expectation in MUTANTS:
        mtree = ctx.src.parent / f"src-{name}"
        if not mtree.exists():
            shutil.copytree(ctx.src, mtree, symlinks=True,
                            ignore=shutil.ignore_patterns("work-ver-*"))
        bad_anchor = None
        for rel, anchor, repl in patches:
            mpath = mtree / rel
            text = mpath.read_text()
            if text.count(anchor) != 1:
                bad_anchor = f"{rel}: anchor count={text.count(anchor)}"
                break
            mpath.write_text(text.replace(anchor, repl))
        if bad_anchor:
            rep["incomplete"].append(f"{name}: {bad_anchor} (want 1)")
            rep["mutants"][name] = {"killed": False, "reason": "anchor"}
            continue
        mctx = c2.Ctx(mtree, ctx.out, ctx.verilator, ctx.vroot, ctx.env)
        ok, _ = mctx.ensure_model(name, defs, target=target)
        ctx.builds.extend(mctx.builds)
        if not ok:
            rep["incomplete"].append(f"{name}: mutant build failed")
            rep["mutants"][name] = {"killed": False, "reason": "build"}
            continue
        sim = ck.run_sim(mctx, name, fw_by_key[fw_key])
        killed = judge_mutant(expectation, sim)
        rep["mutants"][name] = {"killed": bool(killed),
                                "expect": [expectation[0],
                                           list(expectation[1]) if isinstance(expectation[1], tuple)
                                           else expectation[1]],
                                "fail_code": sim["fail_code"],
                                "success": sim["success"],
                                "markers": sim["text_markers"],
                                "state": sim["state"], "log": sim["log"]}
    return rep


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    """run_leaf.py stage entry for ``native-ckpt-w2``."""
    data = Path(data)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rep = {"cases": {}, "mutants": {}, "incomplete": []}

    def _inc(msg):
        rep["incomplete"].append(msg)
        rep["verdict"] = "incomplete"
        (out / "native-ckpt-w2.json").write_text(json.dumps(rep, indent=2))
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
    work = run_dir / "work" / "native-ckpt-w2"
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
    (out / "native-ckpt-w2.json").write_text(json.dumps(rep, indent=2))
    for name, c in rep["cases"].items():
        outcomes.append({"native_ckpt_w2": name, "pass": bool(c["pass"]),
                         "fail_code": c["fail_code"], "state": c["state"]})
    for name, m in rep["mutants"].items():
        outcomes.append({"native_ckpt_w2": "mutant-" + name,
                         "killed": bool(m["killed"]), "pass": bool(m["killed"])})
    outcomes.append({"native_ckpt_w2": rep["verdict"], "verdict": rep["verdict"],
                     "incomplete": rep.get("incomplete", []),
                     "pass": rep["verdict"] == "pass"})
    if rep["verdict"] == "pass":
        return
    if rep["verdict"] == "fail":
        bad = [k for k, v in rep["cases"].items() if not v["pass"]]
        bad += [k for k, v in rep["mutants"].items() if not v["killed"]]
        raise RuntimeError("native-ckpt-w2 FAIL: " + ", ".join(bad or ["unknown"]))
    raise c2._Incomplete("; ".join(rep.get("incomplete") or ["incomplete"]))
