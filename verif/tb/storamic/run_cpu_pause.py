# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cpu-pause regression: real-CPU pause/drain provider stage.

Builds tb_g6lc_storamic_cpu_pause (real cva6 + g6lc_storamic_axi_gate +
g6lc_storamic_cpu_pause + bench AXI memory) against the frozen cpu-36 source
closure plus cva6_rvfi/gate/pause. Generates the store/load/AMO/SC/call program
via g6lc_cpu_pause_program, runs >=2 fixed seeds at delay 0/16 plus a
never-paused reference, and must-fail mutants k1/k2/k3."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

PASS_RE = re.compile(
    r"CPU_PAUSE_PASS pauses=(\d+) max_drain_cycles=(\d+) seed=(\d+) "
    r"delay=(\d+) sig=([0-9a-f]+)")
REF_RE = re.compile(r"CPU_PAUSE_REF sig=([0-9a-f]+) cycles=(\d+)")
DIRTY_RE = re.compile(r"CPU_PAUSE_FAIL dirty addr=([0-9a-f]+)")
BENCH_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_pause.sv"
# Extra first-party / wrapper-level sources not in the cpu_origin_plan closure.
EXTRA_SV = [
    "core/cva6_rvfi.sv",
    "corev_apu/storamic/g6lc_storamic_axi_gate.sv",
    "corev_apu/storamic/g6lc_storamic_cpu_pause.sv",
]
SEEDS = (1, 7)
DELAYS = (0, 16)
MIN_PAUSES = 40
# Bus back-pressure magnitudes: +wstall stalls downstream aw_ready/w_ready,
# +rstall stalls ar_ready, in pseudo-random 0..N stretches seeded per case.
# Committed stores then linger in the commit queue / D$ write buffer, so a
# drain term that drops no_st_pending_commit (mutant k1) closes the gate over
# a pending write and o2/o4 must observe the dirty image.
WSTALL, RSTALL = 24, 8
WSTALL_HI = 48   # deeper write back-pressure: each write stays outstanding
                 # longer so the commit queue (DEPTH_COMMIT=4) stays full and
                 # committed stores sit without AW-valid across a B return.
# (seed, delay, wstall, rstall, name-tag): all four unstalled seeds/delays
# plus the same matrix under write+read back-pressure at two depths.
CASES = tuple(
    (seed, delay, w, r, ("" if w == 0 else f"-w{w}r{r}"))
    for (w, r) in ((0, 0), (WSTALL, RSTALL), (WSTALL_HI, RSTALL))
    for seed in SEEDS for delay in DELAYS)


def _maxcycles(wstall):
    """Liveness watchdog budget per stall tier. Deep +wstall legitimately
    stretches a correct pause/resume stream; the o1-o4 oracles are unchanged,
    only the wall-clock cap grows. Unstalled keeps the historical 400k."""
    return {0: 400000, WSTALL: 600000, WSTALL_HI: 1000000}.get(
        wstall, 400000 + wstall * 10000)

# Mutant patches: (name, relpath, anchor, replacement). Each anchor must occur
# exactly once or the stage is incomplete.
MUTANTS = [
    ("k1", "core/cva6.sv",
     "storamic_drained_o <= storamic_pause_q && halt_ctrl &&\n"
     "                            no_st_pending_commit &&\n",
     "storamic_drained_o <= storamic_pause_q && halt_ctrl &&\n"),
    ("k2", "corev_apu/storamic/g6lc_storamic_axi_gate.sv",
     "assign closed_o   = close_i && !aw_commit_q && !ar_commit_q && !overflow_q &&\n"
     "                      (wr_cnt_q == '0) && (rd_cnt_q == '0) && (w_cnt_q == '0);",
     "assign closed_o   = close_i && !aw_commit_q && !ar_commit_q && !overflow_q;"),
    ("k3", "corev_apu/storamic/g6lc_storamic_cpu_pause.sv",
     "else if (core_drained_i) state_q <= S_CLOSE;",
     "else if (core_drained_i) state_q <= S_PAUSED;"),
    # k4 reverts the AMO-head guard: halt begins immediately on pause_gated,
    # so a pause landing while an AMO/LR/SC is the commit head withdraws
    # amo_req from a miss unit already in AMO_WAIT -> orphaned ack -> the
    # observed post-release deadlock (CPU_PAUSE_FAIL timeout).
    ("k4", "core/cva6.sv",
     "assign storamic_halt = storamic_pause_gated && storamic_halt_q;",
     "assign storamic_halt = storamic_pause_gated;"),
    # k5 reverts the load_unit WAIT_PAGE_OFFSET interlock for the in-order
    # single-hart config: an uncovered load (page_offset_matches set, no STQ
    # forward -- non-cacheable) falls through to WAIT_GNT after one cycle and
    # re-issues to the D$ while the older matching store is still speculative.
    # Pause-independent: also reproduced by the +nopause directed program.
    ("k5", "core/load_unit.sv",
     "!CVA6Cfg.OoOEn && CVA6Cfg.NrHarts == 1 && page_offset_matches_i",
     "1'b0"),
]


def _sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def _identities(paths):
    return {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths)}


def _build_env(manifest):
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VERILATOR_ROOT", "VPATH"):
        env.pop(key, None)
    runtime = manifest["runtime"]
    if runtime.get("kind") == "g6lc-fork-native":
        env["VERILATOR_ROOT"] = runtime["root"]
    return env


def _model_identity(model, executable, manifest):
    dependencies = set()
    for depfile in model.rglob("*.d"):
        for rule in depfile.read_text().replace("\\\n", "").splitlines():
            if ":" not in rule:
                continue
            for value in shlex.split(rule.split(":", 1)[1]):
                path = Path(value.replace("$$", "$"))
                dependencies.add((path if path.is_absolute()
                                  else model / path).resolve())
    private_header = Path(manifest["runtime"]["root"]) / "include/verilated_funcs.h"
    original_header = (Path(manifest["runtime"]["original_root"]) /
                       "include/verilated_funcs.h")
    if private_header not in dependencies or (
            original_header != private_header and
            original_header in dependencies):
        raise RuntimeError("STORAMIC_COMPILED_RUNTIME_IDENTITY")
    generated = {p for p in model.iterdir() if p.is_file() and
                 p.suffix in {".cpp", ".h", ".mk", ".dat", ".d"}}
    return {"files": _identities(dependencies | generated | {executable}),
            "executable": str(executable), "private_runtime_verified": True}


def _apply_patch(path, anchor, replacement, tag):
    text = path.read_text()
    n = text.count(anchor)
    if n != 1:
        raise RuntimeError(f"{tag}: patch anchor count={n} (want 1)")
    path.write_text(text.replace(anchor, replacement, 1))


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "cpu-pause" not in set(stages):
        return
    sha = _sha
    plan = json.loads((data / "cpu_origin_plan.json").read_text())
    tree = out / "cpu-src"
    closure = plan["files"] + plan.get("support_files", [])
    for rel in closure + [BENCH_REL] + EXTRA_SV:
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data / Path(rel).name, dst)
    spec = importlib.util.spec_from_file_location(
        "g6lc_cpu_pause_program", data / "g6lc_cpu_pause_program.py")
    program = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(program)
    rom = out / "program.hex"
    rom.write_bytes(program.build_program())
    drom = out / "program_directed.hex"
    drom.write_bytes(program.build_directed_program())
    manifest["cpu_pause"] = {
        "plan": "cpu_origin_plan.json",
        "files": len(plan["files"]),
        "extra_sv": EXTRA_SV,
        "program_sha256": sha(rom),
        "directed_sha256": sha(drom),
        "bench_sha256": sha(tree / BENCH_REL),
        "seeds": list(SEEDS), "delays": list(DELAYS),
        "min_pauses": MIN_PAUSES,
        "stall_tiers": [[0, 0], [WSTALL, RSTALL], [WSTALL_HI, RSTALL]],
        "cases": [list(c[:4]) + [c[4]] for c in CASES],
        "o2_source": "formatted RVFI retire stream via cva6_rvfi "
                     "(core/cva6_rvfi.sv mem_wmask/mem_addr/mem_wdata), "
                     "fed by cpu.rvfi_probes_o",
    }
    env = _build_env(manifest)

    def _build(label, src_root=None):
        src = src_root if src_root is not None else tree
        model = out / ("model-" + label)
        model.mkdir()
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "--threads", "1", "-Wno-fatal",
                   "--top-module", "tb_g6lc_storamic_cpu_pause",
                   "--Mdir", str(model), "-o", "test",
                   "--exe", str(data / "g6lc_dram_peek64_stub.cpp"),
                   str(data / "origin_cache.vlt"),
                   *["-I" + str(src / d) for d in plan["incdirs"]],
                   *plan["defines"],
                   *[str(src / f) for f in plan["files"]],
                   *[str(src / f) for f in EXTRA_SV],
                   str(src / BENCH_REL)]
        command += manifest["runtime"].get("verilator_options", [])
        (out / (label + "-command.json")).write_text(json.dumps(command))
        started = time.monotonic()
        with (out / (label + "-build.log")).open("w") as log:
            try:
                subprocess.run(command, env=env, cwd=model, stdout=log,
                               stderr=subprocess.STDOUT, check=True,
                               timeout=2400)
            except (subprocess.SubprocessError, subprocess.TimeoutExpired) as e:
                raise RuntimeError(f"{label}: build failed: {e}")
        seconds = round(time.monotonic() - started, 1)
        executable = model / "test"
        builds.append(_model_identity(model, executable, manifest) |
                      {"cpu_pause": label, "seconds": seconds,
                       "log_sha256": sha(out / (label + "-build.log"))})
        outcomes.append({"cpu_pause": label + "-build", "seconds": seconds,
                         "executable": str(executable), "pass": True})
        return executable

    def _sim(executable, case, args, timeout=600):
        try:
            result = subprocess.run(args, env=env, cwd=executable.parent,
                                    capture_output=True, text=True,
                                    timeout=timeout)
            text = result.stdout + result.stderr
            rc = result.returncode
        except subprocess.TimeoutExpired:
            text, rc = "TIMEOUT", None
        (out / (case + ".log")).write_text(text)
        return text, rc

    # ---- reference run (never paused) for the o4 signature ----
    ref_exe = _build("cpu-pause")
    ref_text, ref_rc = _sim(ref_exe, "cpu-pause-ref",
                            [str(ref_exe), f"+rom={rom}", "+delay=0",
                             "+nopause"])
    ref_m = REF_RE.search(ref_text)
    ref_sig = ref_m.group(1) if ref_m else None
    outcomes.append({"cpu_pause": "cpu-pause-ref", "rc": ref_rc,
                     "reference": True, "sig": ref_sig,
                     "log_sha256": sha(out / "cpu-pause-ref.log"),
                     "pass": bool(ref_m and ref_rc == 0)})
    if not (ref_m and ref_rc == 0):
        raise RuntimeError("cpu-pause-ref: no reference signature")

    # ---- positive runs: seeds x delays x bus back-pressure ----
    ref_sigs = set()
    for seed, delay, wstall, rstall, tag in CASES:
        case = f"cpu-pause-s{seed}-d{delay}{tag}"
        args = [str(ref_exe), f"+rom={rom}", f"+delay={delay}",
                f"+seed={seed}", f"+maxcycles={_maxcycles(wstall)}"]
        if wstall:
            args.append(f"+wstall={wstall}")
        if rstall:
            args.append(f"+rstall={rstall}")
        text, rc = _sim(ref_exe, case, args)
        m = PASS_RE.search(text)
        ok = (rc == 0 and m and int(m.group(1)) >= MIN_PAUSES and
              int(m.group(3)) == seed and int(m.group(4)) == delay and
              m.group(5) == ref_sig and
              "CPU_PAUSE_FAIL" not in text and
              "error_o" not in text)
        outcomes.append({
            "cpu_pause": case, "seed": seed, "delay": delay, "rc": rc,
            "wstall": wstall, "rstall": rstall,
            "pass_marker": m.group(0) if m else None,
            "pauses": int(m.group(1)) if m else None,
            "max_drain_cycles": int(m.group(2)) if m else None,
            "sig": m.group(5) if m else None,
            "sig_match_ref": bool(m and m.group(5) == ref_sig),
            "log_sha256": sha(out / (case + ".log")), "pass": bool(ok)})
        if m:
            ref_sigs.add(m.group(5))
        if not ok:
            raise RuntimeError(f"{case}: verdict rc={rc}")
    manifest["cpu_pause"]["positive_sigs"] = sorted(ref_sigs)

    # ---- pause-independent load_unit regression (+nopause directed) ----
    # The store->load defect is a latent core bug: a slow older instruction at
    # the commit head (here a ~61-iteration serial divu) holds the narrow store
    # speculative while the wider load issues to the D$. Must PASS on the fixed
    # RTL with no pause at all; the k5 copy must FAIL it (checked below).
    for ddelay in (0, 16):
        case = f"cpu-pause-directed-d{ddelay}"
        d_text, d_rc = _sim(ref_exe, case,
                            [str(ref_exe), f"+rom={drom}",
                             f"+delay={ddelay}", "+nopause"])
        d_m = REF_RE.search(d_text)
        d_ok = (d_rc == 0 and d_m is not None and
                "CPU_PAUSE_FAIL" not in d_text)
        outcomes.append({
            "cpu_pause": case, "delay": ddelay, "rc": d_rc,
            "pass_marker": d_m.group(0) if d_m else None,
            "sig": d_m.group(1) if d_m else None,
            "log_sha256": sha(out / (case + ".log")), "pass": bool(d_ok)})
        if not d_ok:
            raise RuntimeError(f"{case}: fixed RTL failed the "
                               "pause-independent load_unit hazard")

    # ---- must-fail mutants k1..k5 ----
    # Every mutant is evaluated on EVERY case (unstalled + stalled) and the
    # loop never aborts at the first survivor: a mutant is killed by the first
    # case whose oracle rejects it; only a mutant surviving all cases fails
    # the stage, and that is raised only after every mutant AND the directed
    # k5 proof below have run.
    mutant_results = {}
    mutant_exes = {}
    mutant_survivors = []
    for name, rel, anchor, repl in MUTANTS:
        # Each mutant builds from its own patched source-tree copy (spec:
        # "patched copies in the run dir"). The shared cpu-src tree is never
        # modified, so every build's recorded file identities remain truthful
        # through run_leaf's post-build integrity re-check (a patched-then-
        # restored shared file would read as changed -> INCOMPLETE).
        mtree = out / ("cpu-src-" + name)
        if mtree.exists():
            shutil.rmtree(mtree)
        shutil.copytree(tree, mtree)
        mpath = mtree / rel
        killed = False
        kill_reason = None
        kill_case = None
        _apply_patch(mpath, anchor, repl, name)
        mexe = _build("cpu-pause-" + name, src_root=mtree)
        mutant_exes[name] = mexe
        # each mutant must be rejected by an oracle on >=1 case
        for seed, delay, wstall, rstall, tag in CASES:
            case = f"cpu-pause-{name}-s{seed}-d{delay}{tag}"
            args = [str(mexe), f"+rom={rom}", f"+delay={delay}",
                    f"+seed={seed}", f"+maxcycles={_maxcycles(wstall)}"]
            if wstall:
                args.append(f"+wstall={wstall}")
            if rstall:
                args.append(f"+rstall={rstall}")
            text, rc = _sim(mexe, case, args)
            m = PASS_RE.search(text)
            survived = (rc == 0 and m and int(m.group(1)) >= MIN_PAUSES)
            rejected = (not survived) and (
                "CPU_PAUSE_FAIL" in text or "error_o" in text or
                DIRTY_RE.search(text) is not None or rc != 0)
            outcomes.append({
                "cpu_pause": case, "mutant": name, "seed": seed,
                "delay": delay, "wstall": wstall, "rstall": rstall,
                "rc": rc, "survived": bool(survived),
                "rejected": bool(rejected),
                "pass_marker": m.group(0) if m else None,
                "log_sha256": sha(out / (case + ".log")),
                "pass": bool(rejected)})
            if rejected and not killed:
                killed = True
                kill_case = case
                if "dirty" in text:
                    kill_reason = "o2-dirty " + (DIRTY_RE.search(text).group(0)
                                                 if DIRTY_RE.search(text) else "")
                elif "stuck" in text:
                    kill_reason = "watchdog-stuck"
                elif "timeout" in text:
                    kill_reason = "timeout-deadlock"
                elif "error_o" in text:
                    kill_reason = "o3-error_o"
                elif "o1" in text:
                    kill_reason = "o1-dn-valid"
                elif "o4" in text or "final-mismatch" in text:
                    kill_reason = "o4-final"
                else:
                    kill_reason = f"rc={rc}"
            if killed:
                break   # first rejecting case is the kill evidence
        mutant_results[name] = {"killed": killed, "reason": kill_reason,
                                "case": kill_case}
        outcomes.append({"cpu_pause": "mutant-" + name, "killed": killed,
                         "case": kill_case, "reason": kill_reason,
                         "pass": bool(killed)})
        if not killed:
            mutant_survivors.append(name)
    manifest["cpu_pause"]["mutants"] = mutant_results
    manifest["cpu_pause"]["mutant_survivors"] = mutant_survivors

    # ---- k5 pause-independent proof: the load_unit revert must ALSO fail the
    # +nopause directed hazard program (no pause involved) -> the defect is
    # pre-existing, not pause-induced. Runs regardless of mutant outcomes; a
    # survival is collected and raised together with any mutant survivors.
    directed_failures = []
    k5exe = mutant_exes.get("k5")
    if k5exe is not None:
        for ddelay in (0, 16):
            case = f"cpu-pause-directed-k5-d{ddelay}"
            kd_text, kd_rc = _sim(k5exe, case,
                                 [str(k5exe), f"+rom={drom}",
                                  f"+delay={ddelay}", "+nopause"])
            kd_rej = (kd_rc != 0 or "CPU_PAUSE_FAIL" in kd_text or
                      REF_RE.search(kd_text) is None)
            outcomes.append({
                "cpu_pause": case, "mutant": "k5", "delay": ddelay,
                "rc": kd_rc, "rejected": bool(kd_rej),
                "log_sha256": sha(out / (case + ".log")),
                "pass": bool(kd_rej)})
            manifest["cpu_pause"].setdefault(
                "directed_k5_rejected", {})[str(ddelay)] = bool(kd_rej)
            if not kd_rej:
                directed_failures.append(case)
    # ---- stage verdict: fail only now that every mutant and the directed
    # k5 proof have been evaluated ----
    failures = []
    if mutant_survivors:
        failures.append("mutants survived all cases: "
                        + ", ".join(mutant_survivors))
    if directed_failures:
        failures.append("k5 survived pause-independent directed hazard: "
                        + ", ".join(directed_failures))
    if failures:
        raise RuntimeError("cpu-pause stage fail: " + "; ".join(failures))
