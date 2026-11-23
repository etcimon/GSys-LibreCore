#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""hyp8 fix-validation gate.

Drives the post-build fix-validation campaigns for an already-built hyp8
integration model (``run_hyp8_integration.py`` tag) with explicit, auditable
state instead of the shell ``fixval-chain.sh`` loop. One JSON status record
per campaign run is written atomically under
``build-platform/workspace/build/fixval-status/`` so a later ``after`` hook can
be authorised by exactly one nonce-scoped record — an older campaign's record
can never release a dependent job.

Subcommands:

  job-state --tag <runs-tag>
      One proxy ``shell --allow-overlap`` probe reporting whether a process
      whose argv contains ``/opt/testharness/runs/<tag>/`` exists, whether
      ``output/results.json`` exists (status + build.modelSha256) and whether a
      directed ``mc-directed-results.json`` exists. Prints one classification
      word plus a JSON detail. Exit 0 passed / 1 failed / 2 running /
      3 lost / 4 transport_error.

  run --campaign <name> --int <intTag> \
      --suite <runTag>:<maxCycles>:<t1,t2,...> [--suite ...] \
      [--plusargs "..."] [--model-timeout 14400]
      Waits for the int tag's model to reach build_complete, records
      expectedModelSha256 (+ native tuning / native-ISA receipt, recorded not
      gated), launches every suite as a proxy ``py`` job in parallel, grades
      each pulled ``mc-directed-results.json`` with the same rule as
      ``run_hyp8_mc_directed.py``, runs the tracedb ingest, and writes the
      campaign state. On SIGTERM the record is closed as failed/terminated.

  after --status <record.json> --expect-int <tag> --expect-suites a,b \
        [--expect-sha <sha>] --launch-id <name> [--timeout N] -- <command...>
      Waits on THAT record only. When it is ``passed`` with the expected suite
      set (and sha when given) it claims ``<record>.launched.<launch-id>``
      exactly once (O_EXCL) and spawns the command detached, recording the
      pid. Exits 1 on failed/transport_error, 3 on lost, 0 when already
      launched or after a successful spawn.

  status --status <record.json>
      Pretty-print a record.

The command runner is injectable (``Runner``) so the whole flow is unit
testable without network or the remote host.
"""

import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
PROXY = REPO_ROOT / "verif" / "regress" / "remote" / "testharness_proxy.py"
DIRECTED_RUNNER = "verif/regress/remote/run_hyp8_mc_directed.py"
DEFAULT_STATUS_DIR = REPO_ROOT / "build-platform" / "workspace" / "build" / "fixval-status"
REMOTE_RUNS_PREFIX = "/opt/testharness/runs/"
PULL_ROOT = "/home/etcim/cva6-remote-runs"
INGEST_CMD = ("python3 /opt/testharness/tracedb/ingest.py "
              "--db /opt/testharness/tracedb/hyp8-trace.sqlite")
SCHEMA = "hyp8-fixval-1"
PROBE_MARKER = "__GATE_PROBE__"
DEFAULT_PLUSARGS = "+rvfi_cycle_stamp +hang_dump=8000 +stall_census +smt_stats"

# results.json top-level statuses that are a definitive build failure.
FAIL_STATUSES = {
    "build_failed", "lint_failed", "tohost_missing",
    "resume_overlay_rejected", "input_hash_mismatch",
    "build_blocked_by_overlap",
}
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class GateError(Exception):
    pass


class TransportError(GateError):
    pass


class Proc:
    """Minimal completed-process value object (mirrors subprocess.CompletedProcess)."""
    __slots__ = ("returncode", "stdout", "stderr")

    def __init__(self, returncode, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class Runner:
    """Executes local commands. Injectable: tests substitute a fake."""

    def run(self, argv, *, input_text=None, timeout=None, cwd=None) -> Proc:
        try:
            p = subprocess.run(
                [str(a) for a in argv],
                input=input_text,
                capture_output=True, text=True,
                timeout=timeout, cwd=str(cwd) if cwd else None)
        except subprocess.TimeoutExpired as exc:
            return Proc(124, exc.stdout or "", (exc.stderr or "") + "\n<gate timeout>")
        return Proc(p.returncode, p.stdout or "", p.stderr or "")

    def popen(self, argv, *, cwd=None, stdout_path=None):
        out = open(stdout_path, "w") if stdout_path else None
        try:
            return subprocess.Popen(
                [str(a) for a in argv], cwd=str(cwd) if cwd else None,
                stdin=subprocess.DEVNULL,
                stdout=out if out else subprocess.DEVNULL,
                stderr=subprocess.STDOUT,
                text=True, start_new_session=True)
        finally:
            if out is not None:
                out.close()


# ---------------------------------------------------------------------------
# records
# ---------------------------------------------------------------------------

def now_iso():
    return datetime.now(timezone.utc).isoformat()


def iso_epoch(text):
    try:
        return datetime.fromisoformat(text).timestamp()
    except Exception:
        return 0.0


def new_record(campaign, int_tag, status_dir):
    nonce = uuid.uuid4().hex[:12]
    rec = {
        "schema": SCHEMA,
        "campaign": campaign,
        "nonce": nonce,
        "intTag": int_tag,
        "expectedModelSha256": None,
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "started": now_iso(),
        "updated": now_iso(),
        "finished": None,
        "state": "waiting_model",
        "suites": {},
        "ingest": {"rc": None, "tags": []},
        "reason": None,
        "model": {},
    }
    path = Path(status_dir) / f"{campaign}-{nonce}.json"
    return rec, path


def write_record(path, rec):
    rec["updated"] = now_iso()
    path = Path(path)
    tmp = path.with_name(path.name + f".tmp-{os.getpid()}")
    tmp.write_text(json.dumps(rec, indent=2) + "\n")
    os.replace(tmp, path)


def load_record(path):
    return json.loads(Path(path).read_text())


# ---------------------------------------------------------------------------
# job-state probe
# ---------------------------------------------------------------------------

def _tag_ok(tag):
    return bool(TAG_RE.match(tag or ""))


def probe_script(tag):
    """Remote one-shot probe. Builds the run dir from the tag argument so the
    literal ``/opt/testharness/runs/<tag>/`` never appears expanded in this
    process's own argv (avoids pgrep self-match); the marker is still echoed
    and filtered locally per the gate contract."""
    if not _tag_ok(tag):
        raise GateError(f"bad tag: {tag!r}")
    program = r'''
import json, os, re, subprocess, sys
from datetime import datetime, timezone
tag = sys.argv[1]
r = "/opt/testharness/runs/" + tag
out = r + "/output"
res_path = out + "/results.json"
dr_path = out + "/mc-directed-results.json"
mk_path = out + "/model/Vg6lc_testharness.mk"
try:
    pr = subprocess.run(["pgrep", "-af", "--", r + "/"],
                        capture_output=True, text=True, timeout=25)
    procs = pr.stdout.splitlines()
except Exception:
    procs = []
results = None
if os.path.isfile(res_path):
    try:
        d = json.load(open(res_path))
        b = d.get("build") or {}
        results = {"status": d.get("status"),
                   "modelSha256": b.get("modelSha256"),
                   "nativeTuning": b.get("nativeTuning")}
    except Exception as exc:
        results = {"status": "unparseable", "error": str(exc)}
march_native = native_isa = False
isa_include = ""
if os.path.isfile(mk_path):
    try:
        txt = open(mk_path, errors="replace").read()
        march_native = "-march=native" in txt
        native_isa = "g6lc_native_isa.h" in txt
        m = re.search(r"-include\s+\S*g6lc_native_isa\.h", txt)
        isa_include = m.group(0) if m else ""
    except Exception:
        pass
if results is not None:
    results["marchNative"] = march_native
    results["nativeIsa"] = native_isa
    results["nativeIsaInclude"] = isa_include
directed = None
if os.path.isfile(dr_path):
    try:
        d = json.load(open(dr_path))
        tests = {}
        for name, t in (d.get("tests") or {}).items():
            tests[name] = {"state": t.get("state"), "kind": t.get("kind"),
                           "oracle": t.get("oracle")}
        directed = {"intTag": d.get("intTag"),
                    "modelSha256": d.get("modelSha256"), "tests": tests}
    except Exception as exc:
        directed = {"error": str(exc)}
obj = {"tag": tag, "time": datetime.now(timezone.utc).isoformat(),
       "marker": "__GATE_PROBE__", "procs": procs,
       "results": results, "directed": directed}
print("GATE_JSON=" + json.dumps(obj, separators=(",", ":")))
'''
    return ("python3 - " + tag + " <<'__GATE_PY__'\n" + program + "__GATE_PY__\n")


def _proxy_base(timeout):
    return [sys.executable, str(PROXY), "--timeout", str(timeout)]


def run_probe(tag, runner, timeout=90):
    """Run the remote probe; return the parsed GATE_JSON object."""
    argv = (_proxy_base(timeout) +
            ["shell", "--allow-overlap", "--no-hang", "--cmd-file", "-"])
    proc = runner.run(argv, input_text=probe_script(tag), timeout=timeout + 30)
    if proc.returncode != 0:
        raise TransportError(
            f"probe rc={proc.returncode}: {(proc.stderr or proc.stdout or '')[-400:]}")
    m = re.search(r"^GATE_JSON=(\{.*\})\s*$", proc.stdout, re.M)
    if not m:
        raise TransportError(
            f"probe produced no GATE_JSON (rc={proc.returncode}): "
            f"{(proc.stdout or '')[-400:]}")
    try:
        return json.loads(m.group(1))
    except Exception as exc:
        raise TransportError(f"probe JSON unparseable: {exc}")


def _alive(obj):
    """True if any pgrep line survives the self/marker filter."""
    for line in obj.get("procs") or []:
        if not line.strip():
            continue
        if "pgrep" in line or PROBE_MARKER in line:
            continue
        return True
    return False


def gating_failures(tests):
    """Replicate run_hyp8_mc_directed.py's `bad` rule. Returns list of bad
    {test,state,kind,oracle} or None when the tests map is unusable."""
    if not isinstance(tests, dict) or not tests:
        return None
    bad = []
    for name, t in tests.items():
        t = t or {}
        kind = t.get("kind")
        state = t.get("state")
        oracle = t.get("oracle")
        is_bad = ((kind == "pass" and state != "pass") or
                  (kind == "oracle_neg" and oracle != "oracle_ok"))
        if is_bad:
            bad.append({"test": name, "state": state,
                        "kind": kind, "oracle": oracle})
    return bad


def classify(obj, alive):
    """Return (state, detail). state in passed|failed|running|quiet."""
    res = obj.get("results")
    if res and res.get("status") == "build_complete" and res.get("modelSha256"):
        return "passed", res
    if res and res.get("status") in FAIL_STATUSES:
        return "failed", res
    dr = obj.get("directed")
    if dr and isinstance(dr.get("tests"), dict) and dr["tests"]:
        bad = gating_failures(dr["tests"])
        if bad is not None:
            return ("failed" if bad else "passed"), dr
    if alive:
        return "running", obj
    return "quiet", obj


def job_state(tag, runner, grace=120.0, detail_out=None):
    """Probe once; on a quiet result (no process, no final result) re-probe
    after `grace` seconds before declaring lost. Returns (state, obj)."""
    obj = run_probe(tag, runner)
    alive = _alive(obj)
    state, detail = classify(obj, alive)
    if state != "quiet":
        if detail_out is not None:
            detail_out.update({"obj": obj, "alive": alive, "detail": detail})
        return state, obj
    if grace and grace > 0:
        time.sleep(grace)
    obj2 = run_probe(tag, runner)
    alive2 = _alive(obj2)
    state2, detail2 = classify(obj2, alive2)
    final = "lost" if state2 == "quiet" else state2
    if detail_out is not None:
        detail_out.update({"obj": obj2, "alive": alive2,
                           "detail": detail2, "reprobed": True})
    return final, obj2


# ---------------------------------------------------------------------------
# suite launch + grading
# ---------------------------------------------------------------------------

def parse_suite(spec):
    parts = spec.split(":", 2)
    if len(parts) != 3:
        raise GateError(f"bad --suite {spec!r}: want runTag:maxCycles:t1,t2,...")
    tag, cyc, tests = parts
    if not _tag_ok(tag):
        raise GateError(f"bad suite tag: {tag!r}")
    try:
        max_cycles = int(cyc)
    except ValueError:
        raise GateError(f"bad maxCycles in {spec!r}")
    test_list = [t for t in tests.split(",") if t]
    if not test_list:
        raise GateError(f"empty test list in {spec!r}")
    return {"tag": tag, "maxCycles": max_cycles, "tests": test_list}


def suite_py_argv(suite, int_tag, plusargs):
    envs = [
        "HYP8_ALLOW_OVERLAP=1",
        f"HYP8_INT_TAG={int_tag}",
        "HYP8_MC_TESTS=" + " ".join(suite["tests"]),
        f"HYP8_MAX_CYCLES={suite['maxCycles']}",
        "HYP8_TEST_DEFINES=NHARTS=8",
        f"HYP8_PLUSARGS={plusargs}",
    ]
    argv = (_proxy_base(0) +
            ["py", "--tag", suite["tag"], "--threads", "1"])
    for e in envs:
        argv += ["--env", e]
    argv += ["--data", "verif/tests/custom/multicore",
             "--data", "verif/tests/custom/common",
             "--pull", "--dest", f"{PULL_ROOT}/{suite['tag']}",
             DIRECTED_RUNNER]
    return argv


def results_path_for(tag):
    return Path(PULL_ROOT) / tag / "mc-directed-results.json"


def eval_suite(suite, proxy_rc, start_epoch, int_tag, expected_sha):
    """Grade one suite's pulled mc-directed-results.json. Returns the suite
    record dict."""
    tag = suite["tag"]
    entry = {
        "tests": list(suite["tests"]),
        "maxCycles": suite["maxCycles"],
        "proxyRc": proxy_rc,
        "resultsPath": str(results_path_for(tag)),
        "resultsMtime": None,
        "modelSha256": None,
        "intTag": None,
        "state": "transport_error",
        "failures": [],
    }
    path = results_path_for(tag)
    valid = False
    parsed = None
    reason = "missing"
    if path.is_file():
        try:
            mtime = path.stat().st_mtime
            entry["resultsMtime"] = mtime
            parsed = json.loads(path.read_text())
            entry["modelSha256"] = parsed.get("modelSha256")
            entry["intTag"] = parsed.get("intTag")
            tests = parsed.get("tests") or {}
            requested = set(suite["tests"])
            got = set(tests.keys())
            checks = []
            checks.append(("mtime", mtime >= start_epoch))
            checks.append(("intTag", parsed.get("intTag") == int_tag))
            checks.append(("modelSha", parsed.get("modelSha256") == expected_sha))
            checks.append(("testset", got == requested))
            bad_checks = [n for n, ok in checks if not ok]
            if bad_checks:
                reason = "mismatch:" + ",".join(bad_checks)
            else:
                valid = True
        except Exception as exc:
            reason = f"unreadable:{exc}"
    else:
        reason = "missing"

    if not valid:
        entry["state"] = "transport_error"
        entry["reason"] = reason
        return entry

    # file is valid: a proxy rc outside {0,1} is a transport failure regardless
    # of what the pulled results say.
    if proxy_rc not in (0, 1):
        entry["state"] = "transport_error"
        entry["reason"] = f"proxyRc={proxy_rc}"
        return entry
    bad = gating_failures(parsed.get("tests") or {})
    entry["failures"] = bad or []
    if bad or proxy_rc == 1:
        entry["state"] = "failed"
    else:
        entry["state"] = "passed"
    return entry


# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------

def cmd_job_state(args, runner):
    tag = args.tag
    grace = getattr(args, "grace", 120.0)
    try:
        state, obj = job_state(tag, runner, grace=grace)
    except TransportError as exc:
        state, obj = "transport_error", {"error": str(exc)}
    alive = _alive(obj) if isinstance(obj, dict) else False
    detail = {"tag": tag, "state": state, "alive": alive, "probe": obj}
    print(state)
    print(json.dumps(detail, indent=2))
    return {"passed": 0, "failed": 1, "running": 2, "lost": 3,
            "transport_error": 4}.get(state, 4)


def _wait_model(rec, path, args, runner):
    """Poll job-state for the int tag until a terminal state. Returns
    (ok, reason)."""
    deadline = time.time() + args.model_timeout
    transport_retries = 0
    while True:
        try:
            state, obj = job_state(args.int_tag, runner, grace=args.grace)
        except TransportError as exc:
            transport_retries += 1
            rec["reason"] = f"transport_error: {exc}"
            write_record(path, rec)
            if transport_retries >= 5:
                rec["state"] = "transport_error"
                rec["finished"] = now_iso()
                write_record(path, rec)
                return False, "transport_error"
            time.sleep(min(60, 5 * transport_retries))
            continue
        transport_retries = 0
        if state == "passed":
            res = (obj.get("results") or {})
            rec["expectedModelSha256"] = res.get("modelSha256")
            rec["model"] = {
                "nativeTuning": res.get("nativeTuning"),
                "nativeIsa": res.get("nativeIsa"),
                "marchNative": res.get("marchNative"),
                "nativeIsaInclude": res.get("nativeIsaInclude"),
            }
            rec["state"] = "running"
            write_record(path, rec)
            return True, "model_ready"
        if state in ("failed", "lost"):
            rec["state"] = "failed"
            rec["reason"] = f"model_{state}"
            rec["finished"] = now_iso()
            write_record(path, rec)
            return False, f"model_{state}"
        # running / waiting_model
        if time.time() > deadline:
            rec["state"] = "failed"
            rec["reason"] = "model_wait_timeout"
            rec["finished"] = now_iso()
            write_record(path, rec)
            return False, "model_wait_timeout"
        rec["state"] = "waiting_model"
        write_record(path, rec)
        time.sleep(args.poll_interval)


def cmd_run(args, runner):
    status_dir = Path(args.status_dir)
    status_dir.mkdir(parents=True, exist_ok=True)
    suites = [parse_suite(s) for s in args.suite]
    plusargs = args.plusargs if args.plusargs is not None else DEFAULT_PLUSARGS
    rec, path = new_record(args.campaign, args.int_tag, status_dir)
    rec["suites"] = {s["tag"]: {"tests": s["tests"], "maxCycles": s["maxCycles"],
                                "state": "waiting_model"} for s in suites}
    write_record(path, rec)
    print(f"[gate] record {path}", flush=True)

    def on_term(signum, frame):
        rec["state"] = "failed"
        rec["reason"] = "terminated"
        rec["finished"] = now_iso()
        try:
            write_record(path, rec)
        except Exception:
            pass
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, on_term)

    start_epoch = time.time()
    ok, reason = _wait_model(rec, path, args, runner)
    if not ok:
        print(f"[gate] model not ready: {reason}", flush=True)
        return 4 if reason == "transport_error" else 1

    # launch every suite in parallel
    procs = {}
    for s in suites:
        argv = suite_py_argv(s, args.int_tag, plusargs)
        log_path = status_dir / f"{args.campaign}-{s['tag']}.log"
        p = runner.popen(argv, cwd=REPO_ROOT, stdout_path=log_path)
        procs[s["tag"]] = (p, log_path)
        rec["suites"][s["tag"]]["state"] = "running"
        rec["suites"][s["tag"]]["proxyLog"] = str(log_path)
        write_record(path, rec)
        print(f"[gate] launched {s['tag']} pid={p.pid}", flush=True)

    for s in suites:
        p, _ = procs[s["tag"]]
        rc = p.wait()
        entry = eval_suite(s, rc, start_epoch, args.int_tag,
                           rec["expectedModelSha256"])
        rec["suites"][s["tag"]].update(entry)
        write_record(path, rec)
        print(f"[gate] {s['tag']}: {entry['state']} proxyRc={rc} "
              f"failures={len(entry['failures'])}", flush=True)

    # ingest all suite tags
    tags = [s["tag"] for s in suites]
    ingest_argv = (_proxy_base(args.ingest_timeout) +
                   ["shell", "--allow-overlap", "--no-hang", "--cmd-file", "-"])
    ingest_input = INGEST_CMD + " " + " ".join(tags)
    ip = runner.run(ingest_argv, input_text=ingest_input,
                    timeout=args.ingest_timeout + 30)
    rec["ingest"] = {"rc": ip.returncode, "tags": tags}

    states = [rec["suites"][t]["state"] for t in tags]
    if all(st == "passed" for st in states) and ip.returncode == 0:
        rec["state"] = "passed"
        rec["reason"] = None
    elif any(st == "transport_error" for st in states):
        rec["state"] = "transport_error"
        rec["reason"] = "suite_transport_error"
    else:
        rec["state"] = "failed"
        rec["reason"] = "suite_failures"
    rec["finished"] = now_iso()
    write_record(path, rec)
    print(f"[gate] campaign {rec['state']} -> {path}", flush=True)
    return 0 if rec["state"] == "passed" else (4 if rec["state"] == "transport_error" else 1)


def _record_authorized(rec, expect_int, expect_suites, expect_sha):
    if rec.get("state") != "passed":
        return False, f"state={rec.get('state')}"
    if expect_int and rec.get("intTag") != expect_int:
        return False, f"intTag {rec.get('intTag')} != {expect_int}"
    suites = rec.get("suites") or {}
    if set(suites.keys()) != set(expect_suites):
        return False, f"suite set {sorted(suites)} != {sorted(expect_suites)}"
    for tag, s in suites.items():
        if s.get("state") != "passed":
            return False, f"suite {tag} state={s.get('state')}"
    if expect_sha and rec.get("expectedModelSha256") != expect_sha:
        return False, "modelSha256 mismatch"
    return True, "ok"


def _pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def _spawn_detached(command, log_path):
    """Spawn `command` detached (new session) with output to log_path.
    Returns the child pid. Isolated so tests can substitute a recorder."""
    out = open(log_path, "w")
    try:
        proc = subprocess.Popen(
            [str(c) for c in command], cwd=str(REPO_ROOT),
            stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
            text=True, start_new_session=True)
    finally:
        out.close()
    return proc.pid


def cmd_after(args, runner):
    rec_path = Path(args.status)
    expect_suites = [s for s in args.expect_suites.split(",") if s]
    deadline = time.time() + args.timeout
    launched = rec_path.with_name(rec_path.name + f".launched.{args.launch_id}")
    while True:
        rec = None
        if rec_path.is_file():
            try:
                rec = load_record(rec_path)
            except Exception:
                rec = None
        if rec is not None:
            state = rec.get("state")
            if state in ("failed", "transport_error", "lost"):
                print(f"[after] record state={state}; not launching", flush=True)
                return 1 if state != "lost" else 3
            ok, why = _record_authorized(rec, args.expect_int,
                                         expect_suites, args.expect_sha)
            if ok:
                # claim exactly once
                try:
                    fd = os.open(str(launched), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                except FileExistsError:
                    print(f"[after] already launched ({launched})", flush=True)
                    return 0
                log_path = launched.with_name(launched.name + ".out")
                try:
                    pid = _spawn_detached(args.command, log_path)
                except Exception as exc:
                    os.close(fd)
                    print(f"[after] spawn failed: {exc}", flush=True)
                    return 1
                payload = {"pid": pid, "command": args.command,
                           "launched": now_iso(), "log": str(log_path)}
                os.write(fd, (json.dumps(payload, indent=2) + "\n").encode())
                os.close(fd)
                print(f"[after] launched pid={pid} -> {launched}", flush=True)
                return 0
            if state == "passed":
                # passed but not the expected shape: never going to match
                print(f"[after] record passed but not authorised: {why}", flush=True)
                return 1
            # running / waiting_model: check the owning run is alive
            if not _pid_alive(rec.get("pid")):
                # The owner writes its terminal state before exiting: re-read
                # once so a pass/fail written between the two reads wins.
                try:
                    if load_record(rec_path).get("state") not in ("running", "waiting_model"):
                        continue
                except Exception:
                    pass
                print(f"[after] record pid {rec.get('pid')} dead; treating as lost",
                      flush=True)
                return 3
        if time.time() > deadline:
            print("[after] timeout waiting for authorised record", flush=True)
            return 1
        time.sleep(args.interval)


def cmd_status(args, runner):
    rec = load_record(args.status)
    print(json.dumps(rec, indent=2))
    return 0


# ---------------------------------------------------------------------------
# cli
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="hyp8_fixval_gate.py",
        description="hyp8 fix-validation gate (nonce-scoped campaign records).")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("job-state", help="probe one runs tag once")
    sp.add_argument("--tag", required=True)
    sp.add_argument("--grace", type=float, default=120.0,
                    help="re-probe delay before declaring lost (default 120)")
    sp.set_defaults(fn=cmd_job_state)

    sp = sub.add_parser("run", help="run a fix-validation campaign")
    sp.add_argument("--campaign", required=True)
    sp.add_argument("--int", dest="int_tag", required=True)
    sp.add_argument("--suite", action="append", required=True,
                    help="runTag:maxCycles:t1,t2,... (repeatable)")
    sp.add_argument("--plusargs", default=None,
                    help="HYP8_PLUSARGS (default the fixval diagnostic set)")
    sp.add_argument("--model-timeout", type=float, default=14400)
    sp.add_argument("--poll-interval", type=float, default=30.0)
    sp.add_argument("--grace", type=float, default=120.0)
    sp.add_argument("--ingest-timeout", type=float, default=900)
    sp.add_argument("--status-dir", default=str(DEFAULT_STATUS_DIR))
    sp.set_defaults(fn=cmd_run)

    sp = sub.add_parser("after", help="launch a command once a record passes")
    sp.add_argument("--status", required=True, help="record json path")
    sp.add_argument("--expect-int", dest="expect_int", default=None)
    sp.add_argument("--expect-suites", required=True)
    sp.add_argument("--expect-sha", default=None)
    sp.add_argument("--launch-id", required=True)
    sp.add_argument("--timeout", type=float, default=14400)
    sp.add_argument("--interval", type=float, default=30.0)
    sp.add_argument("command", nargs=argparse.REMAINDER,
                    help="command after '--'")
    sp.set_defaults(fn=cmd_after)

    sp = sub.add_parser("status", help="pretty-print a record")
    sp.add_argument("--status", required=True)
    sp.set_defaults(fn=cmd_status)
    return p


def main(argv=None, runner=None):
    args = build_parser().parse_args(argv)
    # argparse.REMAINDER keeps a leading '--' token; strip it for the command.
    if getattr(args, "command", None) and args.command[0] == "--":
        args.command = args.command[1:]
    if getattr(args, "command", None) is not None and not args.command:
        raise SystemExit("after: empty command")
    runner = runner or Runner()
    return args.fn(args, runner)


if __name__ == "__main__":
    raise SystemExit(main())
