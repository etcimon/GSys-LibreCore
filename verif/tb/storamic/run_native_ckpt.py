#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""native-ckpt stage: native checkpoint composition on the full harness.

Design of record: g6lc_storamic/architecture/native-composition.md.

Builds ariane_testharness with the bounded checkpoint profile and runs the
storamic_ckpt firmware from the checkpointed RAM. Every case is judged on the
firmware verdict AND on the platform's final STORAMIC_CKPT_STATE line; mutants
are full harness rebuilds from a patched copy of the frozen source tree and
must be rejected with the named firmware code or platform marker. A missing
tool, build, marker or anchor is reported as incomplete, never as a pass.
"""
import json
import os
import re
import shutil
from pathlib import Path

import run_native_c2 as c2

FW_CKPT = "verif/tests/custom/storamic/storamic_ckpt.c"
FW_VIO = "verif/tests/custom/storamic/storamic_ckpt_vio.c"
HARNESS = "corev_apu/tb/ariane_testharness.sv"
DEFS_CKPT = ("G6LC_STORAMIC+G6LC_STORAMIC_MODEL+G6LC_STORAMIC_ORIGIN_PROBE"
             "+G6LC_STORAMIC_CKPT+G6LC_AI_EXCL_MULTI")
CKPT_WORDS = 2 ** 15
CKPT_BYTES = CKPT_WORDS * 8
SIM_BUDGET = int(os.environ.get("CKPT_BUDGET", "12000000"))

STATE_RE = re.compile(r"STORAMIC_CKPT_STATE final (.*)")
REFUSAL = "STORAMIC_CHECKPOINT_NATIVE_BINDING_REQUIRED"

# Firmware fail codes (storamic_ckpt.c).
FAIL_DATA_RESTORED = 16
FAIL_CODE_RESTORED = 17
FAIL_SC_SUCCEEDED = 18
FAIL_TRIGGER_OK = 22

# Bench trigger offsets (ariane_testharness.sv, CTRL-relative).
TRIG_PRESENCE_DROP = 0x3040
TRIG_PGOOD_DROP = 0x3050
TRIG_HOT_SWAP = 0x3070
# Second positive point of the RAM/flash response-delay sweep (0 is the
# default build).
RSP_DELAY = 2
DEFS_CKPT_RSP = DEFS_CKPT + f"+G6LC_STORAMIC_CKPT_RSP={RSP_DELAY}"
# Provider negatives end with the hart stalled on sealed RAM, so they run on a
# short budget; the platform's final state is the verdict.
NEG_BUDGET = int(os.environ.get("CKPT_NEG_BUDGET", "600000"))

VIOLATION = "STORAMIC_CKPT_VIOLATION"
PROVIDERS_ANCHOR = "    ckpt_in.providers_ready    = ckpt_providers;\n"

# (name, [(relpath, anchor, replacement), ...], firmware key, expectation)
# expectation: ("fail", code)    firmware must fail with that code;
#              ("marker", text)  the sim log must carry that fatal marker;
#              ("build-missing", member)  the model must fail to build only
#                  because the testbench cannot find that hierarchy member.
MUTANTS = [
    # Without NativeBound the composition is not instantiated at all (the
    # runtime refusal marker itself is covered by the integration stage's
    # component bench).
    ("n1-unbound",
     [(HARNESS,
       ".Enable(1'b1), .CheckpointRequested(1'b1), .NativeBound(1'b1),",
       ".Enable(1'b1), .CheckpointRequested(1'b1), .NativeBound(1'b0),")],
     "flow", ("build-missing", "gen_native_ckpt")),
    ("n2-no-dcache-resync",
     [("core/cva6.sv",
       "storamic_resync_state_q <= RESYNC_FLUSH_D;",
       "storamic_resync_state_q <= RESYNC_WAIT_HEAD;")],
     "flow", ("fail", FAIL_DATA_RESTORED)),
    ("n3-no-icache-resync",
     [("core/controller.sv",
       "      flush_ex_o             = 1'b1;\n"
       "      flush_icache_o         = 1'b1;\n"
       "    end\n  end",
       "      flush_ex_o             = 1'b1;\n"
       "      flush_icache_o         = 1'b0;\n"
       "    end\n  end")],
     "flow", ("fail", FAIL_CODE_RESTORED)),
    ("n4-no-reservation-clear",
     [(HARNESS,
       ".res_clr_i ( ckpt_res_clr          ),",
       ".res_clr_i ( 1'b0                  ),")],
     "flow", ("fail", FAIL_SC_SUCCEEDED)),
    # The endpoint is told the CPU is paused before the sequencer says so.
    ("n5-cpu-paused-tied",
     [(HARNESS,
       "{ckpt_virtio_paused, ckpt_dbg_closed, ckpt_cpu_paused};\n"
       "    ckpt_in.producer_error",
       "{ckpt_virtio_paused, ckpt_dbg_closed, 1'b1};\n"
       "    ckpt_in.producer_error")],
     "flow", ("marker", VIOLATION)),
    # Provider facts forced ready: a withdrawn stick must then be caught by
    # nothing, and the presence-drop firmware sees a CP_OK save.
    ("n6-providers-tied",
     [(HARNESS, PROVIDERS_ANCHOR,
       "    ckpt_in.providers_ready    = 5'h1f;\n"),
      (HARNESS,
       "    ckpt_in.present            = ckpt_present;\n"
       "    ckpt_in.identity_valid     = ckpt_identity_valid;\n"
       "    ckpt_in.protection_ok      = ckpt_protection_ok;\n",
       "    ckpt_in.present            = 1'b1;\n"
       "    ckpt_in.identity_valid     = 1'b1;\n"
       "    ckpt_in.protection_ok      = 1'b1;\n"),
      # The captured module identity is a provider fact too: left live, its
      # change on withdrawal still locks the endpoint (observed, run
      # storamic-64ece5236e29), so the synthetic set must freeze it as well.
      (HARNESS,
       "    ckpt_in.module_id          = ckpt_module_id;\n",
       "    ckpt_in.module_id          = 160'hC0DE;\n")],
     "presence", ("fail", FAIL_TRIGGER_OK)),
    # No boot recovery agent: after the power cycle the endpoint comes up
    # locked on its checkpoint and nothing can issue the RESTORE.
    ("n7-no-boot-recovery",
     [(HARNESS, "    .CkptBootRecovery(1'b1),", "    .CkptBootRecovery(1'b0),")],
     "cold", ("locked-stall", None)),
    # The endpoint is told the VirtIO writer is paused while its accepted job
    # is still running.
    ("n8-virtio-paused-tied",
     [(HARNESS,
       "{ckpt_virtio_paused, ckpt_dbg_closed, ckpt_cpu_paused};\n"
       "    ckpt_in.producer_error",
       "{1'b1, ckpt_dbg_closed, ckpt_cpu_paused};\n"
       "    ckpt_in.producer_error")],
     "vio", ("marker", VIOLATION)),
]


def parse_state(text):
    """Return the final STORAMIC_CKPT_STATE fields as a dict of strings."""
    m = None
    for m in STATE_RE.finditer(text):
        pass
    if m is None:
        return None
    out = {}
    for tok in m.group(1).split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def state_ok(state, expect):
    """Check exact (str) and minimum (('>=', n)) expectations."""
    if state is None:
        return False, "no STORAMIC_CKPT_STATE final line"
    for key, want in expect.items():
        got = state.get(key)
        if got is None:
            return False, f"state field {key} missing"
        if isinstance(want, tuple):
            op, n = want
            if op == ">=" and not int(got) >= n:
                return False, f"{key}={got} < {n}"
        elif got != str(want):
            return False, f"{key}={got} != {want}"
    return True, ""


def judge_mutant(expectation, sim):
    """A mutant is killed only by its named symptom; anything else survives
    (an unrelated crash is not evidence for the mechanism)."""
    kind, want = expectation
    if kind == "fail":
        return sim.get("fail_code") == str(want)
    if kind == "marker":
        return want in sim.get("text_markers", "")
    if kind == "locked-stall":
        # Power cycle happened, the checkpoint is still published, nothing
        # restored it and the hart never ran the restored image.
        st = sim.get("state") or {}
        return (not sim.get("success") and st.get("locked") == "1" and
                st.get("valid") == "1" and st.get("reset_gen") == "1")
    return False


def judge_build_missing(member, build_ok, log_text):
    """build-missing: the SV elaborated (no Verilator %Error) and the only
    failure is the testbench not finding ``member`` in the hierarchy."""
    return (not build_ok and log_text.count("%Error") == 0 and
            "no member named" in log_text and member in log_text)


def run_sim(ctx, tag, elf, extra=(), budget=None, debug=False):
    sim = ctx.model(tag)
    th = c2.tohost_addr(elf)
    argv = [str(sim), f"+time_out={budget or SIM_BUDGET}"]
    if not debug:
        argv.append("+debug_disable")
    argv += ["+storamic_ckpt_report", "+storamic_ckpt_trace", "+quiet_axi",
             "+storamic_c2_report",
             f"+preload_bytes={CKPT_BYTES}", *extra,
             f"+tohost_addr=0x{th:x}", str(elf)]
    name = f"sim-{tag}-{Path(elf).stem}.log"
    rc, dt, txt = c2.sh(argv, ctx.src, ctx.env, ctx.out / name,
                        timeout=c2.SIM_TIMEOUT)
    success = "*** SUCCESS ***" in txt and "cycle budget reached" not in txt
    failed = re.findall(r"\*\*\* FAILED \*\*\* \(tohost\s*=\s*(\d+)", txt)
    markers = " ".join(sorted(set(re.findall(
        r"STORAMIC_[A-Z0-9_]+(?:REQUIRED|UNSUPPORTED|CONFIG|VIOLATION)", txt))))
    return {"rc": rc, "seconds": round(dt, 1), "success": success,
            "fail_code": failed[0] if failed else None,
            "sba": c2.parse_sba(txt), "native": c2.parse_native(txt),
            "state": parse_state(txt), "text_markers": markers,
            "preloads": len(re.findall(r"\[preload\] ckpt boot_ready load", txt)),
            "errors": txt.count("%Error"), "log": name, "tail": txt[-400:]}


def execute(ctx):
    rep = {"defines": DEFS_CKPT, "cases": {}, "mutants": {},
           "builds": ctx.builds, "incomplete": []}

    def fw(tag, flags):
        elf = ctx.compile_fw(FW_CKPT, tag, flags)
        if elf is None:
            rep["incomplete"].append(f"firmware {tag} failed to compile")
        return elf

    ok, _ = ctx.ensure_model("ckpt", DEFS_CKPT)
    if not ok:
        rep["incomplete"].append("ckpt harness build failed")
        return rep
    boot_elf = fw("ckpt-boot", ["-DCKPT_BOOT_ONLY"])
    flow_elf = fw("ckpt-flow", [])
    neg_elf = fw("ckpt-neg", ["-DCKPT_ORACLE_EXPECT_B"])
    sba_elf = fw("ckpt-sba", ["-DCKPT_BOOT_ONLY", "-DCKPT_DELAY_EARLY"])
    presence_elf = fw("ckpt-presence",
                      [f"-DCKPT_TRIGGER=0x{TRIG_PRESENCE_DROP:x}UL"])
    pgood_elf = fw("ckpt-pgood", [f"-DCKPT_TRIGGER=0x{TRIG_PGOOD_DROP:x}UL"])
    swap_elf = fw("ckpt-swap", [f"-DCKPT_TRIGGER=0x{TRIG_HOT_SWAP:x}UL"])
    cold_elf = fw("ckpt-cold", ["-DCKPT_COLD"])
    cold_neg_elf = fw("ckpt-cold-neg", ["-DCKPT_COLD", "-DCKPT_ORACLE_EXPECT_B"])
    vio_elf = ctx.compile_fw(FW_VIO, "ckpt-vio", ["-DSTORAMIC_COHERENT_DMA"])
    if vio_elf is None:
        rep["incomplete"].append("firmware ckpt-vio failed to compile")
    if rep["incomplete"]:
        return rep
    fw_by_key = {"flow": flow_elf, "presence": presence_elf, "cold": cold_elf,
                 "vio": vio_elf}

    def case(name, elf, want_success, want_fail, expect_state):
        sim = run_sim(ctx, "ckpt", elf)
        s_ok, why = state_ok(sim["state"], expect_state)
        if want_success:
            v_ok = sim["success"] and sim["errors"] == 0
        else:
            v_ok = (not sim["success"]) and sim["fail_code"] == str(want_fail)
        sim["pass"] = bool(v_ok and s_ok and sim["preloads"] >= 1)
        sim["why"] = why if not s_ok else ("" if v_ok else "firmware verdict")
        rep["cases"][name] = sim
        return sim

    common = {"initialized": "1", "locked": "0", "busy": "0",
              "providers": "1f", "policy_ready": "1", "errors": "000",
              "present": "1"}
    case("boot", boot_elf, True, None,
         dict(common, valid="0", pauses=(">=", 1), releases=(">=", 1),
              done="0", error="0"))
    case("flow", flow_elf, True, None,
         dict(common, valid="1", generation="1", pauses=(">=", 3),
              releases=(">=", 3), done=(">=", 2), error="0"))
    case("oracle-expect-b", neg_elf, False, FAIL_DATA_RESTORED,
         dict(common, valid="1", generation="1", done=(">=", 2)))

    # Debug-master command: a real DMI System Bus Access write to the SAVE
    # register must be refused (port 1 is not the trusted source) and must not
    # start a checkpoint.
    sim = run_sim(ctx, "ckpt", sba_elf, debug=True,
                  extra=("+storamic_sba_probe", "+storamic_sba_ctrl"))
    s_ok, why = state_ok(sim["state"], dict(
        common, valid="0", generation="0", issue="0", done="0"))
    # The refusal is taken at the checkpoint route (port 1 never reaches the
    # endpoint's policy, so its refuse counter stays 0): both debug beats must
    # be seen on port 1, answered with an error, and never source-qualified.
    sba = sim.get("sba") or {}
    nat = sim.get("native") or {}
    sba_ok = (sba.get("reads") == 1 and sba.get("writes") == 1 and
              nat.get("p1_aw") == 1 and nat.get("p1_ar") == 1 and
              nat.get("p0_aw") == 0 and nat.get("src_ok_aw") == 0 and
              nat.get("err_resp", 0) >= 2 and nat.get("violations") == 0)
    sim["pass"] = bool(sim["success"] and sim["errors"] == 0 and s_ok and sba_ok)
    sim["why"] = why or ("" if sba_ok else f"sba probe {sba} native {nat.get('line')}")
    rep["cases"]["debug-command-refused"] = sim

    # Provider negatives: the stick is withdrawn / loses power-good before
    # SAVE. No checkpoint may appear and no result may be fabricated; the
    # firmware verdict is irrelevant (the hart normally stalls on sealed RAM).
    for name, elf in (("presence-drop", presence_elf),
                      ("power-good-drop", pgood_elf)):
        sim = run_sim(ctx, "ckpt", elf, budget=NEG_BUDGET)
        st = sim["state"] or {}
        s_ok, why = state_ok(sim["state"], {
            "valid": "0", "generation": "0", "issue": "0", "done": "0",
            "errors": "000"})
        withdrawn = st.get("providers") not in (None, "1f")
        no_fake_ok = sim["fail_code"] != str(FAIL_TRIGGER_OK)
        sim["pass"] = bool(s_ok and withdrawn and no_fake_ok and
                           sim["errors"] == 0)
        sim["why"] = why or ("" if withdrawn else "providers still 1f") or (
            "" if no_fake_ok else "CP_OK under withdrawn provider")
        rep["cases"][name] = sim

    # Hot swap: the stick is withdrawn and a different one (other identity,
    # same geometry) is inserted. Discovery must really re-qualify it (mapping
    # generation 2, all provider facts ready again) and the endpoint must stay
    # locked on the identity it captured: no command result, no checkpoint.
    sim = run_sim(ctx, "ckpt", swap_elf, budget=NEG_BUDGET)
    s_ok, why = state_ok(sim["state"], {
        "valid": "0", "generation": "0", "issue": "0", "done": "0",
        "locked": "1", "map_gen": "2", "providers": "1f", "present": "1"})
    no_fake_ok = (not sim["success"]) and sim["fail_code"] != str(FAIL_TRIGGER_OK)
    sim["pass"] = bool(s_ok and no_fake_ok and sim["errors"] == 0)
    sim["why"] = why or ("" if no_fake_ok else "firmware ran on a swapped stick")
    rep["cases"]["hot-swap"] = sim

    # Cold recovery (C6b): SAVE, mutate, power cycle. The boot recovery agent
    # must restore the saved image before the hart is released; the second
    # boot checks it. One preload only: the bench never reloads the ELF.
    cold_state = dict(common, valid="1", generation="1", reset_gen="1",
                      rec_active="0", rec_failed="0", done=(">=", 2), error="0")
    sim = case("cold-recovery", cold_elf, True, None, cold_state)
    sim["pass"] = bool(sim["pass"] and sim["preloads"] == 1)
    sim = case("cold-oracle-expect-b", cold_neg_elf, False, FAIL_DATA_RESTORED,
               cold_state)
    sim["pass"] = bool(sim["pass"] and sim["preloads"] == 1)

    # C4 with a VirtIO job in flight: SAVE is issued right behind a notified
    # virtio-blk request. The pause must find the writer busy (non-vacuity
    # counter), the job must retire exactly once before the image is taken.
    case("virtio-inflight", vio_elf, True, None,
         dict(common, valid="1", generation="1", done=(">=", 2), error="0",
              vio_busy_pauses=(">=", 1)))

    # Positive flow again with delayed RAM/flash responses.
    ok, _ = ctx.ensure_model("ckpt-rsp", DEFS_CKPT_RSP)
    if not ok:
        rep["incomplete"].append("ckpt-rsp harness build failed")
        return rep
    sim = run_sim(ctx, "ckpt-rsp", flow_elf, budget=4 * SIM_BUDGET)
    s_ok, why = state_ok(sim["state"], dict(
        common, valid="1", generation="1", pauses=(">=", 3),
        releases=(">=", 3), done=(">=", 2), error="0"))
    sim["pass"] = bool(sim["success"] and sim["errors"] == 0 and s_ok and
                       sim["preloads"] >= 1)
    sim["why"] = why if not s_ok else ("" if sim["pass"] else "firmware verdict")
    rep["cases"][f"flow-rsp{RSP_DELAY}"] = sim

    base_ok = all(c["pass"] for c in rep["cases"].values())
    if not base_ok:
        # Mutant kills are only meaningful against a passing baseline.
        rep["incomplete"].append("positive cases failed; mutants not run")
        return rep

    for name, patches, fw_key, expectation in MUTANTS:
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
        ok, _ = mctx.ensure_model(name, DEFS_CKPT)
        ctx.builds.extend(mctx.builds)
        if expectation[0] == "build-missing":
            log = ctx.out / f"verilate-{name}.log"
            text = log.read_text(errors="replace") if log.is_file() else ""
            rep["mutants"][name] = {
                "killed": bool(judge_build_missing(expectation[1], ok, text)),
                "expect": list(expectation), "build_ok": ok}
            continue
        if not ok:
            rep["incomplete"].append(f"{name}: mutant build failed")
            rep["mutants"][name] = {"killed": False, "reason": "build"}
            continue
        sim = run_sim(mctx, name, fw_by_key[fw_key],
                      budget=NEG_BUDGET * 6 if fw_key == "presence" else None)
        killed = judge_mutant(expectation, sim)
        rep["mutants"][name] = {"killed": bool(killed),
                                "expect": list(expectation),
                                "fail_code": sim["fail_code"],
                                "success": sim["success"],
                                "markers": sim["text_markers"],
                                "state": sim["state"], "log": sim["log"]}
    return rep


def verdict(rep):
    if rep.get("incomplete"):
        return "incomplete"
    cases_ok = bool(rep["cases"]) and all(c["pass"] for c in rep["cases"].values())
    mutants_ok = (len(rep["mutants"]) == len(MUTANTS) and
                  all(m["killed"] for m in rep["mutants"].values()))
    return "pass" if cases_ok and mutants_ok else "fail"


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    """run_leaf.py stage entry for ``native-ckpt``."""
    data = Path(data)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    src_tar = data / c2.SRC_TAR_NAME
    expected = (manifest.get("sources") or {}).get(c2.SRC_TAR_NAME)
    rep = {"stage": "native-ckpt", "src_tar": str(src_tar)}

    def _inc(reason):
        rep["verdict"] = "incomplete"
        rep["reason"] = reason
        (out / "native-ckpt.json").write_text(json.dumps(rep, indent=2))
        outcomes.append({"native_ckpt": "incomplete", "reason": reason,
                         "pass": False})
        raise c2._Incomplete(reason)

    if not src_tar.is_file():
        _inc(f"missing {c2.SRC_TAR_NAME} in run data")
    actual = c2.sha256_file(src_tar)
    rep["src_tar_sha256"] = actual
    if expected and actual != expected:
        _inc("source tar sha256 mismatch vs manifest")
    run_dir = Path(os.environ.get("TH_RUN_DIR") or out.parent)
    work = run_dir / "work" / "native-ckpt"
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
    (out / "native-ckpt.json").write_text(json.dumps(rep, indent=2))
    for name, c in rep["cases"].items():
        outcomes.append({"native_ckpt": name, "pass": bool(c["pass"]),
                         "fail_code": c["fail_code"], "state": c["state"]})
    for name, m in rep["mutants"].items():
        outcomes.append({"native_ckpt": "mutant-" + name,
                         "killed": bool(m["killed"]), "pass": bool(m["killed"])})
    outcomes.append({"native_ckpt": rep["verdict"], "verdict": rep["verdict"],
                     "incomplete": rep.get("incomplete", []),
                     "pass": rep["verdict"] == "pass"})
    if rep["verdict"] == "pass":
        return
    if rep["verdict"] == "fail":
        bad = [k for k, v in rep["cases"].items() if not v["pass"]]
        bad += [k for k, v in rep["mutants"].items() if not v["killed"]]
        raise RuntimeError("native-ckpt FAIL: " + ", ".join(bad or ["unknown"]))
    raise c2._Incomplete("; ".join(rep.get("incomplete") or ["incomplete"]))
