#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Unit tests for hyp8_fixval_gate.py — fake runner, tmp dirs, no network."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE / "hyp8"))
import hyp8_fixval_gate as g  # noqa: E402

INT = "int-build-tag"
SHA = "a" * 64
CAS = "mc-casack2-cas-t1"
AMO = "mc-casack2-amo-t1"


def probe_obj(tag, *, status=None, sha=None, procs=None, directed=None,
              tuning=None, march=True, nisa=True):
    results = None
    if status is not None:
        results = {"status": status, "modelSha256": sha,
                   "nativeTuning": tuning or {"profile": "packed-tiled"},
                   "marchNative": march, "nativeIsa": nisa,
                   "nativeIsaInclude": "-include x/g6lc_native_isa.h"}
    return {"tag": tag, "time": "2026-01-01T00:00:00+00:00",
            "marker": "__GATE_PROBE__",
            "procs": procs if procs is not None else ["1 python3 /opt/testharness/runs/%s/x.py" % tag],
            "results": results, "directed": directed}


def directed_obj(int_tag=INT, sha=SHA, tests=None):
    return {"intTag": int_tag, "modelSha256": sha,
            "tests": tests if tests is not None else {}}


class FakePopen:
    def __init__(self, tag, rc, results, pull_root):
        self._tag = tag
        self._rc = rc
        self._results = results
        self._pull_root = pull_root
        self.pid = 40000 + (hash(tag) % 1000)
        self.returncode = None

    def wait(self):
        if self._results is not None:
            d = Path(self._pull_root) / self._tag
            d.mkdir(parents=True, exist_ok=True)
            (d / "mc-directed-results.json").write_text(
                json.dumps(self._results))
        self.returncode = self._rc
        return self._rc


class FakeRunner:
    """Drives probes (runner.run with --cmd-file), suite py jobs (popen) and
    ingest. `probe` may be a single obj, a list (consumed in order, last
    repeats), the string 'transport', or a callable(tag)->obj."""

    def __init__(self, probe=None, suite_results=None, ingest_rc=0):
        self.probe = probe if probe is not None else probe_obj(INT, status="build_complete", sha=SHA)
        self.suite_results = suite_results or {}
        self.ingest_rc = ingest_rc
        self._probe_i = 0
        self.probe_inputs = []
        self.py_argvs = []
        self.ingest_inputs = []
        self.pull_root = None  # set by test

    def _next_probe(self, tag):
        p = self.probe
        if callable(p):
            return p(tag)
        if isinstance(p, list):
            item = p[min(self._probe_i, len(p) - 1)]
            self._probe_i += 1
            return item
        return p

    def run(self, argv, *, input_text=None, timeout=None, cwd=None):
        argv = [str(a) for a in argv]
        if "--cmd-file" in argv:
            if input_text and "ingest.py" in input_text:
                self.ingest_inputs.append(input_text)
                return g.Proc(self.ingest_rc, "ingest ok", "")
            # job-state probe: tag is embedded as `python3 - <tag>`
            tag = ""
            m = __import__("re").search(r"python3 - (\S+)", input_text or "")
            if m:
                tag = m.group(1)
            self.probe_inputs.append(tag)
            item = self._next_probe(tag)
            if item == "transport":
                return g.Proc(255, "", "ssh: connect failed")
            return g.Proc(0, "GATE_MARKER __GATE_PROBE__\nGATE_JSON=" +
                          json.dumps(item, separators=(",", ":")), "")
        return g.Proc(0, "", "")

    def popen(self, argv, *, cwd=None, stdout_path=None):
        argv = [str(a) for a in argv]
        self.py_argvs.append(argv)
        tag = argv[argv.index("--tag") + 1]
        rc, results = self.suite_results.get(tag, (0, None))
        return FakePopen(tag, rc, results, self.pull_root)


class GateTestBase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.status_dir = self.tmp / "status"
        self.pull_root = self.tmp / "pulled"
        self.pull_root.mkdir(parents=True, exist_ok=True)
        self._p1 = patch.object(g, "PULL_ROOT", str(self.pull_root))
        self._p1.start()
        self.addCleanup(self._p1.stop)
        self.runner = FakeRunner()
        self.runner.pull_root = str(self.pull_root)
        # keep `after` launches off the real subprocess
        self.spawned = []
        self._p2 = patch.object(g, "_spawn_detached",
                                side_effect=lambda cmd, log: self._fake_spawn(cmd, log))
        self._p2.start()
        self.addCleanup(self._p2.stop)

    def _fake_spawn(self, cmd, log):
        self.spawned.append(list(cmd))
        return 50000 + len(self.spawned)

    def records(self, campaign):
        return sorted(self.status_dir.glob(f"{campaign}-*.json"))

    def only_record(self, campaign):
        recs = self.records(campaign)
        self.assertEqual(len(recs), 1, f"expected 1 record, got {recs}")
        return recs[0]

    def write_record(self, campaign, nonce, rec):
        self.status_dir.mkdir(parents=True, exist_ok=True)
        p = self.status_dir / f"{campaign}-{nonce}.json"
        p.write_text(json.dumps(rec))
        return p


def suite_result(int_tag=INT, sha=SHA, tests=None):
    return {"intTag": int_tag, "modelSha256": sha,
            "nativeTuning": {"profile": "packed-tiled"},
            "tests": tests if tests is not None else {}}


def pass_tests(*names):
    return {n: {"state": "pass", "kind": "pass", "oracle": ""} for n in names}


CAS_TESTS = ["zacas_amocas_d", "zacas_amocas_w", "mini_amocas_d",
             "mc_cas_lock_handoff", "mc_spo_cas_stream"]
AMO_TESTS = ["mini_amoadd_w_spin", "mini_lrsc_d", "mc_lrsc_set_zombie",
             "mc_za64rs_independence"]


class RunCampaignTest(GateTestBase):
    def _run(self, campaign="casack2-4a", runner=None):
        runner = runner or self.runner
        argv = ["run", "--campaign", campaign, "--int", INT,
                "--suite", f"{CAS}:300000:{','.join(CAS_TESTS)}",
                "--suite", f"{AMO}:300000:{','.join(AMO_TESTS)}",
                "--status-dir", str(self.status_dir),
                "--poll-interval", "0.01", "--grace", "0"]
        return g.main(argv, runner=runner)

    def test_4a_failing_pass_test_fails_campaign_and_blocks_after(self):
        amo_tests = pass_tests(*AMO_TESTS)
        amo_tests["mini_lrsc_d"] = {"state": "fail", "kind": "pass", "oracle": ""}
        self.runner.suite_results = {
            CAS: (0, suite_result(tests=pass_tests(*CAS_TESTS))),
            AMO: (1, suite_result(tests=amo_tests)),
        }
        rc = self._run()
        self.assertEqual(rc, 1)
        rec_path = self.only_record("casack2-4a")
        rec = json.loads(rec_path.read_text())
        self.assertEqual(rec["state"], "failed")
        self.assertEqual(rec["suites"][AMO]["state"], "failed")
        self.assertTrue(any(f["test"] == "mini_lrsc_d"
                            for f in rec["suites"][AMO]["failures"]))
        self.assertEqual(rec["suites"][CAS]["state"], "passed")
        # after must NOT launch on a failed record
        arc = g.main(["after", "--status", str(rec_path),
                      "--expect-int", INT,
                      "--expect-suites", f"{CAS},{AMO}",
                      "--launch-id", "boot", "--timeout", "1",
                      "--", "true"], runner=self.runner)
        self.assertEqual(arc, 1)
        self.assertEqual(self.spawned, [])

    def test_all_pass_campaign_then_after_launches_once(self):
        self.runner.suite_results = {
            CAS: (0, suite_result(tests=pass_tests(*CAS_TESTS))),
            AMO: (0, suite_result(tests=pass_tests(*AMO_TESTS))),
        }
        rc = self._run()
        self.assertEqual(rc, 0)
        rec_path = self.only_record("casack2-4a")
        rec = json.loads(rec_path.read_text())
        self.assertEqual(rec["state"], "passed")
        self.assertEqual(rec["expectedModelSha256"], SHA)
        self.assertEqual(rec["ingest"]["rc"], 0)
        # two after invocations -> exactly one spawn
        base = ["after", "--status", str(rec_path), "--expect-int", INT,
                "--expect-suites", f"{CAS},{AMO}", "--expect-sha", SHA,
                "--launch-id", "boot", "--timeout", "5", "--interval", "0.01",
                "--", "true"]
        self.assertEqual(g.main(base, runner=self.runner), 0)
        self.assertEqual(g.main(base, runner=self.runner), 0)
        self.assertEqual(len(self.spawned), 1)
        launched = rec_path.with_name(rec_path.name + ".launched.boot")
        self.assertTrue(launched.is_file())
        self.assertIn('"pid"', launched.read_text())

    def test_old_passed_record_does_not_authorize_fresh_record(self):
        # an old passed record for the same campaign name, different nonce
        old = {"schema": g.SCHEMA, "campaign": "casack2-4a", "nonce": "oldnonce00",
               "intTag": INT, "expectedModelSha256": SHA, "pid": 1,
               "state": "passed",
               "suites": {CAS: {"state": "passed"}, AMO: {"state": "passed"}},
               "started": "2020-01-01T00:00:00+00:00"}
        self.write_record("casack2-4a", "oldnonce00", old)
        # fresh record: running with a dead pid
        dead = __import__("subprocess").Popen(["true"])
        dead.wait()
        fresh = {"schema": g.SCHEMA, "campaign": "casack2-4a", "nonce": "newnonce00",
                 "intTag": INT, "expectedModelSha256": None, "pid": dead.pid,
                 "state": "running", "suites": {},
                 "started": "2026-01-01T00:00:00+00:00"}
        fresh_path = self.write_record("casack2-4a", "newnonce00", fresh)
        arc = g.main(["after", "--status", str(fresh_path),
                      "--expect-int", INT, "--expect-suites", f"{CAS},{AMO}",
                      "--launch-id", "l3", "--timeout", "2", "--interval", "0.01",
                      "--", "true"], runner=self.runner)
        self.assertEqual(arc, 3)  # running but owner pid dead -> lost
        self.assertEqual(self.spawned, [])
        # and a fresh *failed* record also blocks
        fresh["state"] = "failed"
        fresh_path.write_text(json.dumps(fresh))
        arc = g.main(["after", "--status", str(fresh_path),
                      "--expect-int", INT, "--expect-suites", f"{CAS},{AMO}",
                      "--launch-id", "l3", "--timeout", "2", "--interval", "0.01",
                      "--", "true"], runner=self.runner)
        self.assertEqual(arc, 1)
        self.assertEqual(self.spawned, [])

    def test_probe_transport_and_missing_results_are_transport_error(self):
        # (a) probe transport failure -> campaign transport_error, no launch
        bad = FakeRunner(probe="transport")
        bad.pull_root = str(self.pull_root)
        rc = self._run(runner=bad)
        self.assertEqual(rc, 4)
        rec = json.loads(self.only_record("casack2-4a").read_text())
        self.assertEqual(rec["state"], "transport_error")
        # (b) suite results file missing -> suite transport_error
        self.runner.suite_results = {
            CAS: (0, suite_result(tests=pass_tests(*CAS_TESTS))),
            AMO: (0, None),  # proxy rc 0 but never wrote mc-directed-results.json
        }
        rc = self._run(campaign="casack2-4b-x")
        self.assertEqual(rc, 4)
        rec = json.loads(self.only_record("casack2-4b-x").read_text())
        self.assertEqual(rec["state"], "transport_error")
        self.assertEqual(rec["suites"][AMO]["state"], "transport_error")


class EvalSuiteTest(GateTestBase):
    def _write(self, tag, obj, mtime=None):
        d = self.pull_root / tag
        d.mkdir(parents=True, exist_ok=True)
        p = d / "mc-directed-results.json"
        p.write_text(json.dumps(obj))
        if mtime is not None:
            os.utime(p, (mtime, mtime))
        return p

    def test_stale_or_sha_mismatch_not_passed(self):
        suite = {"tag": "t1", "maxCycles": 100, "tests": ["a", "b"]}
        good = suite_result(tests=pass_tests("a", "b"))
        start = g.time.time()
        # stale mtime (before campaign start)
        self._write("t1", good, mtime=start - 100)
        e = g.eval_suite(suite, 0, start, INT, SHA)
        self.assertEqual(e["state"], "transport_error")
        self.assertIn("mtime", e["reason"])
        # modelSha mismatch
        badsha = suite_result(sha="b" * 64, tests=pass_tests("a", "b"))
        self._write("t1", badsha)
        e = g.eval_suite(suite, 0, start, INT, SHA)
        self.assertEqual(e["state"], "transport_error")
        self.assertIn("modelSha", e["reason"])
        # intTag mismatch
        badint = suite_result(int_tag="other", tests=pass_tests("a", "b"))
        self._write("t1", badint)
        e = g.eval_suite(suite, 0, start, INT, SHA)
        self.assertEqual(e["state"], "transport_error")
        # valid control -> passed
        self._write("t1", good)
        e = g.eval_suite(suite, 0, start, INT, SHA)
        self.assertEqual(e["state"], "passed")
        # bad test -> failed
        badt = suite_result(tests={"a": {"state": "fail", "kind": "pass", "oracle": ""},
                                   "b": {"state": "pass", "kind": "pass", "oracle": ""}})
        self._write("t1", badt)
        e = g.eval_suite(suite, 1, start, INT, SHA)
        self.assertEqual(e["state"], "failed")
        self.assertEqual(e["failures"][0]["test"], "a")


class JobStateTest(GateTestBase):
    def _js(self, obj, grace=0):
        r = FakeRunner(probe=obj)
        return g.job_state("sometag", r, grace=grace)

    def test_alive_no_results_is_running(self):
        obj = probe_obj("sometag", procs=["77 python3 /opt/testharness/runs/sometag/scripts/x.py"],
                        status=None)
        state, _ = self._js(obj)
        self.assertEqual(state, "running")

    def test_no_process_no_results_is_lost(self):
        obj = probe_obj("sometag", procs=[], status=None)
        state, _ = self._js(obj, grace=0)
        self.assertEqual(state, "lost")
        # marker/pgrep-only lines also count as no process
        obj2 = probe_obj("sometag", procs=["1 pgrep -af -- /opt/testharness/runs/sometag/",
                                           "__GATE_PROBE__"], status=None)
        state2, _ = self._js(obj2, grace=0)
        self.assertEqual(state2, "lost")

    def test_build_failed_is_failed(self):
        obj = probe_obj("sometag", status="build_failed", sha=None, procs=[])
        state, _ = self._js(obj)
        self.assertEqual(state, "failed")

    def test_build_complete_is_passed(self):
        obj = probe_obj("sometag", status="build_complete", sha=SHA, procs=[])
        state, _ = self._js(obj)
        self.assertEqual(state, "passed")

    def test_directed_all_pass_is_passed(self):
        dr = directed_obj(tests=pass_tests("x", "y"))
        obj = probe_obj("sometag", procs=[], directed=dr)
        state, _ = self._js(obj)
        self.assertEqual(state, "passed")

    def test_directed_bad_test_is_failed(self):
        dr = directed_obj(tests={"x": {"state": "fail", "kind": "pass", "oracle": ""}})
        obj = probe_obj("sometag", procs=[], directed=dr)
        state, _ = self._js(obj)
        self.assertEqual(state, "failed")


if __name__ == "__main__":
    unittest.main()
