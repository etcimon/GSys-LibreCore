#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""native-ckpt-l2l3 stage: Storamic W1 checkpointing with L2 and L2+L3 caches.

Exercises the single-hart, single-core, in-order WT profile with L2 (flop tags,
posted writes, write-update, L2 prefetcher, CMO) and L2+L3 (SRAM tags,
inclusive L3, posted writes, write-update, L2+L3 prefetchers, CMO) overlays.
Proves save/restore flow, negative oracle, cold recovery, VirtIO in flight,
debug SBA refusal (with sberror), and three mutants:
  - w1-no-l2-inval: suppresses L2 whole-cache invalidation -> stale pattern B
    served from L2 after L1 flush (FAIL_DATA_RESTORED = 16).
  - w2-no-l3-inval: keeps L2 invalidation, suppresses L3 invalidation -> stale
    pattern B served from L3 after L1+L2 flush (FAIL_DATA_RESTORED = 16).
  - w3-no-l2-prot: drops bypass AxPROT in g6lc_l2_top -> control-page access
    loses CPU origin and is refused with zero commands issued.
"""
import json
import os
import shutil
from pathlib import Path

import run_native_c2 as c2
import run_native_ckpt as ck

CLUSTER = "corev_apu/src/g6lc_cluster.sv"
L2_TOP = "corev_apu/l2_cache/g6lc_l2_top.sv"

DEFS_L2 = ck.DEFS_CKPT + "+G6LC_STORAMIC_L2"
DEFS_L3 = ck.DEFS_CKPT + "+G6LC_STORAMIC_L3"

# (name, defines, [(relpath, anchor, replacement), ...], fw_key, expectation)
MUTANTS = [
    ("w1-no-l2-inval", DEFS_L2,
     [(CLUSTER,
       "        .l2_inval_all_i        (llc_inval_q),\n"
       "        .l2_inval_all_done_o   (l2_inval_all_done)\n"
       "    );",
       "        .l2_inval_all_i        (1'b0),\n"
       "        .l2_inval_all_done_o   ()\n"
       "    );\n    assign l2_inval_all_done = llc_inval_q;")],
     "flow", ("fail", ck.FAIL_DATA_RESTORED)),
    ("w2-no-l3-inval", DEFS_L3,
     [(CLUSTER,
       "        .l3_inval_all_i        (llc_inval_q),\n"
       "        .l3_inval_all_done_o   (l3_inval_all_done)\n"
       "    );",
       "        .l3_inval_all_i        (1'b0),\n"
       "        .l3_inval_all_done_o   ()\n"
       "    );\n    assign l3_inval_all_done = llc_inval_q;")],
     "flow", ("fail", ck.FAIL_DATA_RESTORED)),
    ("w3-no-l2-prot", DEFS_L2,
     [(L2_TOP,
       "        mst_req_o.ar.prot  = prot_q;",
       "        mst_req_o.ar.prot  = 3'b000;"),
      (L2_TOP,
       "        mst_req_o.aw.prot  = prot_q;",
       "        mst_req_o.aw.prot  = 3'b000;")],
     "flow", ("refused-no-issue", None)),
]


def judge_mutant(expectation, sim):
    kind, want = expectation
    if kind == "fail":
        return sim.get("fail_code") == str(want)
    if kind == "refused-no-issue":
        st = sim.get("state") or {}
        return (not sim.get("success") and sim.get("fail_code") is not None and
                st.get("issue") == "0" and st.get("done") == "0" and
                st.get("valid") == "0")
    return False


def verdict(rep):
    if rep.get("incomplete"):
        return "incomplete"
    cases_ok = bool(rep["cases"]) and all(c["pass"] for c in rep["cases"].values())
    mutants_ok = (len(rep["mutants"]) == len(MUTANTS) and
                  all(m["killed"] for m in rep["mutants"].values()))
    return "pass" if cases_ok and mutants_ok else "fail"


def execute(ctx):
    rep = {"defines": {"l2": DEFS_L2, "l3": DEFS_L3},
           "cases": {}, "mutants": {}, "builds": ctx.builds, "incomplete": []}

    def fw(src, tag, flags):
        elf = ctx.compile_fw(src, tag, flags)
        if elf is None:
            rep["incomplete"].append(f"firmware {tag} failed to compile")
        return elf

    for tag, defs in (("ckpt-l2", DEFS_L2), ("ckpt-l3", DEFS_L3)):
        ok, _ = ctx.ensure_model(tag, defs)
        if not ok:
            rep["incomplete"].append(f"{tag} harness build failed")
    if rep["incomplete"]:
        return rep

    flow_elf = fw(ck.FW_CKPT, "ckpt-l2l3-flow", [])
    neg_elf = fw(ck.FW_CKPT, "ckpt-l2l3-neg", ["-DCKPT_ORACLE_EXPECT_B"])
    cold_elf = fw(ck.FW_CKPT, "ckpt-l2l3-cold", ["-DCKPT_COLD"])
    sba_elf = fw(ck.FW_CKPT, "ckpt-l2l3-sba",
                 ["-DCKPT_BOOT_ONLY", "-DCKPT_DELAY_EARLY"])
    vio_elf = fw(ck.FW_VIO, "ckpt-l2l3-vio", ["-DSTORAMIC_COHERENT_DMA"])
    if rep["incomplete"]:
        return rep
    fw_by_key = {"flow": flow_elf}

    def case(name, tag, elf, want_success, want_fail, expect_state,
             want_profile, exact_preloads=None, debug=False, extra=()):
        sim = ck.run_sim(ctx, tag, elf, debug=debug, extra=extra)
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
    prof_l2 = {"ooo": 0, "harts": 1, "cores": 1, "l2": 1, "l3": 0, "supported": 1}
    prof_l3 = {"ooo": 0, "harts": 1, "cores": 1, "l2": 1, "l3": 1, "supported": 1}

    # ---- L2 (flop tags, posted writes, write-update, L2 prefetcher, CMO) ----
    case("l2-flow", "ckpt-l2", flow_elf, True, None,
         dict(common, valid="1", generation="1", pauses=(">=", 3),
              releases=(">=", 3), done=(">=", 2), error="0",
              llc_invals=(">=", 3), l2_hits=(">=", 1)), prof_l2)
    case("l2-oracle-expect-b", "ckpt-l2", neg_elf, False, ck.FAIL_DATA_RESTORED,
         dict(common, valid="1", generation="1", done=(">=", 2),
              llc_invals=(">=", 3)), prof_l2)
    case("l2-cold-recovery", "ckpt-l2", cold_elf, True, None,
         dict(common, valid="1", generation="1", reset_gen="1",
              rec_active="0", rec_failed="0", done=(">=", 2), error="0",
              llc_invals=(">=", 3), l2_hits=(">=", 1)), prof_l2,
         exact_preloads=1)
    case("l2-virtio-inflight", "ckpt-l2", vio_elf, True, None,
         dict(common, valid="1", generation="1", done=(">=", 2), error="0",
              vio_busy_pauses=(">=", 1), llc_invals=(">=", 3)), prof_l2)

    # ---- L2+L3 (SRAM tags, inclusive L3, posted writes, L2+L3 prefetchers) --
    case("l3-flow", "ckpt-l3", flow_elf, True, None,
         dict(common, valid="1", generation="1", pauses=(">=", 3),
              releases=(">=", 3), done=(">=", 2), error="0",
              llc_invals=(">=", 3), l2_hits=(">=", 1)), prof_l3)
    case("l3-cold-recovery", "ckpt-l3", cold_elf, True, None,
         dict(common, valid="1", generation="1", reset_gen="1",
              rec_active="0", rec_failed="0", done=(">=", 2), error="0",
              llc_invals=(">=", 3), l2_hits=(">=", 1)), prof_l3,
         exact_preloads=1)
    sim = case("l3-debug-refused", "ckpt-l3", sba_elf, True, None,
               dict(common, valid="0", generation="0", issue="0", done="0",
                    llc_invals=(">=", 1)), prof_l3,
               debug=True, extra=("+storamic_sba_probe", "+storamic_sba_ctrl"))
    sba = sim.get("sba") or {}
    nat = sim.get("native") or {}
    sba_ok = (sba.get("reads") == 1 and sba.get("writes") == 1 and
              sba.get("rd_sberror") == 2 and sba.get("wr_sberror") == 2 and
              sba.get("blocked_sberror") == 2 and sba.get("cleared_sberror") == 0 and
              nat.get("p1_aw") == 1 and nat.get("p1_ar") == 1 and
              nat.get("p0_aw") == 0 and nat.get("src_ok_aw") == 0 and
              nat.get("err_resp", 0) >= 2 and nat.get("violations") == 0)
    sim["pass"] = bool(sim["pass"] and sba_ok)
    if not sba_ok and not sim["why"]:
        sim["why"] = f"sba probe {sba} native {nat.get('line')}"

    if not all(c["pass"] for c in rep["cases"].values()):
        rep["incomplete"].append("positive cases failed; mutants not run")
        return rep

    # ---- W1 mutants ---------------------------------------------------------
    for name, defs, patches, fw_key, expectation in MUTANTS:
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
        ok, _ = mctx.ensure_model(name, defs)
        ctx.builds.extend(mctx.builds)
        if not ok:
            rep["incomplete"].append(f"{name}: mutant build failed")
            rep["mutants"][name] = {"killed": False, "reason": "build"}
            continue
        sim = ck.run_sim(mctx, name, fw_by_key[fw_key])
        killed = judge_mutant(expectation, sim)
        rep["mutants"][name] = {"killed": bool(killed),
                                "expect": list(expectation),
                                "fail_code": sim["fail_code"],
                                "success": sim["success"],
                                "state": sim["state"], "log": sim["log"]}
    return rep


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    """run_leaf.py stage entry for ``native-ckpt-l2l3``."""
    data = Path(data)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rep = {"cases": {}, "mutants": {}, "incomplete": []}

    def _inc(msg):
        rep["incomplete"].append(msg)
        rep["verdict"] = "incomplete"
        (out / "native-ckpt-l2l3.json").write_text(json.dumps(rep, indent=2))
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
    work = run_dir / "work" / "native-ckpt-l2l3"
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
    (out / "native-ckpt-l2l3.json").write_text(json.dumps(rep, indent=2))
    for name, c in rep["cases"].items():
        outcomes.append({"native_ckpt_l2l3": name, "pass": bool(c["pass"]),
                         "fail_code": c["fail_code"], "state": c["state"]})
    for name, m in rep["mutants"].items():
        outcomes.append({"native_ckpt_l2l3": "mutant-" + name,
                         "killed": bool(m["killed"]), "pass": bool(m["killed"])})
    outcomes.append({"native_ckpt_l2l3": rep["verdict"], "verdict": rep["verdict"],
                     "incomplete": rep.get("incomplete", []),
                     "pass": rep["verdict"] == "pass"})
    if rep["verdict"] == "pass":
        return
    if rep["verdict"] == "fail":
        bad = [k for k, v in rep["cases"].items() if not v["pass"]]
        bad += [k for k, v in rep["mutants"].items() if not v["killed"]]
        raise RuntimeError("native-ckpt-l2l3 FAIL: " + ", ".join(bad or ["unknown"]))
    raise c2._Incomplete("; ".join(rep.get("incomplete") or ["incomplete"]))
