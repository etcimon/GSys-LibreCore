# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Unit tests for the remote unittest launcher's semaphore/init/verdict logic.

Imports ``run_unittests_leaf`` (Linux-only ``fcntl`` is fine: the suite runs on
the testharness) and exercises the pure/isolated pieces against temp dirs.
"""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
LEAF_PATH = Path(__file__).with_name("run_unittests_leaf.py")
SPEC = importlib.util.spec_from_file_location("storamic_unittests_leaf", LEAF_PATH)
LEAF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LEAF)


def _write(path, data=b"x"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _make_tree(root, files):
    for rel, data in files.items():
        _write(root / rel, data)


def _make_tar(root, files, tar_path):
    with tarfile.open(tar_path, "w:gz") as archive:
        for rel in files:
            archive.add(root / rel, arcname=rel, recursive=False)


def _manifest(root, files):
    return {rel: hashlib.sha256((root / rel).read_bytes()).hexdigest()
            for rel in files}


class SemaphoreTests(unittest.TestCase):
    def test_second_acquire_times_out_while_slot_held(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock_root = Path(tmp) / "locks"
            idx, handle, waited = LEAF.acquire_slot(lock_root, slots=1, wait_seconds=5)
            self.assertEqual(idx, 0)
            self.assertGreaterEqual(waited, 0.0)
            try:
                with self.assertRaises(TimeoutError):
                    LEAF.acquire_slot(lock_root, slots=1, wait_seconds=0.3,
                                      poll=0.05)
            finally:
                LEAF.release_slot(handle)
            # After release the slot is acquirable again.
            idx2, handle2, _ = LEAF.acquire_slot(lock_root, slots=1,
                                                 wait_seconds=2, poll=0.05)
            self.assertEqual(idx2, 0)
            LEAF.release_slot(handle2)

    def test_two_slots_allow_two_holders(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock_root = Path(tmp) / "locks"
            _, h1, _ = LEAF.acquire_slot(lock_root, slots=2, wait_seconds=2,
                                         poll=0.05)
            _, h2, _ = LEAF.acquire_slot(lock_root, slots=2, wait_seconds=2,
                                         poll=0.05)
            try:
                with self.assertRaises(TimeoutError):
                    LEAF.acquire_slot(lock_root, slots=2, wait_seconds=0.3,
                                      poll=0.05)
            finally:
                LEAF.release_slot(h1)
                LEAF.release_slot(h2)


class InitCacheTests(unittest.TestCase):
    def _setup(self, tmp):
        src = Path(tmp) / "src"
        files = {"a/x.txt": b"alpha", "b/y.sv": b"module m; endmodule"}
        _make_tree(src, files)
        manifest = _manifest(src, files)
        agg = LEAF.aggregate_sha(manifest)
        tar_path = Path(tmp) / "codebase.tar.gz"
        _make_tar(src, files, tar_path)
        cache_root = Path(tmp) / "cache"
        lock = Path(tmp) / "locks" / "init.lock"
        return src, files, manifest, agg, tar_path, cache_root, lock

    def test_created_then_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, files, manifest, agg, tar, cache, lock = self._setup(tmp)
            status1, root1 = LEAF.init_cache(cache, agg, manifest, tar, lock)
            self.assertEqual(status1, "created")
            self.assertTrue((root1 / "a/x.txt").is_file())
            status2, root2 = LEAF.init_cache(cache, agg, manifest, tar, lock)
            self.assertEqual(status2, "reused")
            self.assertEqual(root1, root2)

    def test_corruption_is_repaired(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, files, manifest, agg, tar, cache, lock = self._setup(tmp)
            status, root = LEAF.init_cache(cache, agg, manifest, tar, lock)
            self.assertEqual(status, "created")
            # Corrupt one cached file, then re-init: must detect + repair.
            (root / "a/x.txt").write_bytes(b"corrupted")
            status2, root2 = LEAF.init_cache(cache, agg, manifest, tar, lock)
            self.assertEqual(status2, "repaired")
            self.assertEqual((root2 / "a/x.txt").read_bytes(), b"alpha")

    def test_manifest_mismatch_is_repaired(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, files, manifest, agg, tar, cache, lock = self._setup(tmp)
            LEAF.init_cache(cache, agg, manifest, tar, lock)
            # A different manifest for the same agg is impossible (agg derives
            # from manifest), so simulate drift by editing complete.json's
            # recorded manifest -> verification fails -> repaired.
            dest = cache / agg
            complete = json.loads((dest / "complete.json").read_text())
            complete["manifest"] = dict(complete["manifest"])
            complete["manifest"]["a/x.txt"] = "0" * 64
            (dest / "complete.json").write_text(json.dumps(complete))
            status, _ = LEAF.init_cache(cache, agg, manifest, tar, lock)
            self.assertEqual(status, "repaired")


class ParseOutputTests(unittest.TestCase):
    """``parse_unittest_output`` must count every summary key regardless of
    order and never let a ``FAILED (...)`` variant parse as clean."""

    def test_failed_errors_only(self):
        s = LEAF.parse_unittest_output(
            "test_x ... ok\n\n----------------------------------------------------------------------\n"
            "Ran 2 tests in 0.001s\n\nFAILED (errors=1)\n")
        self.assertEqual(s["ran"], 2)
        self.assertEqual(s["errors"], 1)
        self.assertEqual(s["failures"], 0)
        self.assertFalse(s["ok"])
        self.assertEqual(s["status"], "FAILED")

    def test_failed_reordered_multi_key(self):
        s = LEAF.parse_unittest_output(
            "Ran 3 tests in 0.002s\n\nFAILED (failures=1, errors=2, skipped=1)\n")
        self.assertEqual(s["failures"], 1)
        self.assertEqual(s["errors"], 2)
        self.assertEqual(s["skipped"], 1)
        self.assertFalse(s["ok"])

    def test_ok_with_skips(self):
        s = LEAF.parse_unittest_output(
            "test_a ... ok\ntest_b ... skipped 'no linux'\n\n"
            "Ran 2 tests in 0.001s\n\nOK (skipped=1)\n")
        self.assertTrue(s["ok"])
        self.assertEqual(s["status"], "OK")
        self.assertEqual(s["skipped"], 1)
        self.assertEqual(s["skip_reasons"], ["no linux"])

    def test_failed_unexpected_successes(self):
        s = LEAF.parse_unittest_output(
            "Ran 1 test in 0.001s\n\nFAILED (unexpected successes=1)\n")
        self.assertEqual(s["unexpected_successes"], 1)
        self.assertFalse(s["ok"])

    def test_unparsable_output_is_not_ok(self):
        s = LEAF.parse_unittest_output("garbage with no summary\n")
        self.assertFalse(s["ok"])
        self.assertIsNone(s["status"])


class VerdictTests(unittest.TestCase):
    def _file(self, ran=3, failures=0, errors=0, skipped=0, ok=True,
              timed_out=False, skip_reasons=None, returncode=0,
              unexpected_successes=0):
        return {"ran": ran, "failures": failures, "errors": errors,
                "skipped": skipped, "unexpected_successes": unexpected_successes,
                "expected_failures": 0, "ok": ok, "status": "OK" if ok else "FAILED",
                "returncode": returncode, "timed_out": timed_out,
                "skip_reasons": skip_reasons or []}

    def test_all_pass(self):
        expected = ["test_a.py", "test_b.py"]
        per = {"test_a.py": self._file(ran=3), "test_b.py": self._file(ran=4)}
        full = self._file(ran=7)
        v = LEAF.compute_verdict(expected, expected, per, full, [], "reused")
        self.assertEqual(v["status"], "pass")
        self.assertEqual(v["total_tests"], 7)

    def test_failure_is_incomplete(self):
        expected = ["test_a.py"]
        per = {"test_a.py": self._file(ran=3, failures=1, ok=False)}
        v = LEAF.compute_verdict(expected, expected, per,
                                 self._file(ran=3), [], "created")
        self.assertEqual(v["status"], "incomplete")
        self.assertTrue(any(r.startswith("failed:") for r in v["reasons"]))

    def test_set_mismatch_and_drift_and_skip(self):
        expected = ["test_a.py"]
        per = {"test_a.py": self._file(ran=2, skipped=1,
                                       skip_reasons=["needs linux only"])}
        v = LEAF.compute_verdict(expected, ["test_a.py", "test_b.py"], per,
                                 self._file(ran=2), ["x.sv"], "created")
        self.assertEqual(v["status"], "incomplete")
        for needle in ("test-set-mismatch", "source-drift", "unlisted-skip"):
            self.assertTrue(any(needle in r for r in v["reasons"]), needle)

    def test_full_total_mismatch_is_incomplete(self):
        expected = ["test_a.py"]
        per = {"test_a.py": self._file(ran=3)}
        v = LEAF.compute_verdict(expected, expected, per,
                                 self._file(ran=5), [], "created")
        self.assertEqual(v["status"], "incomplete")
        self.assertTrue(any("total-mismatch" in r for r in v["reasons"]))

    def test_nonzero_returncode_is_incomplete(self):
        expected = ["test_a.py"]
        # Counts look clean but the process exited non-zero (e.g. crashed
        # after printing a partial summary): must not pass.
        per = {"test_a.py": self._file(ran=3, ok=True, returncode=1)}
        v = LEAF.compute_verdict(expected, expected, per,
                                 self._file(ran=3, returncode=1), [], "created")
        self.assertEqual(v["status"], "incomplete")
        self.assertTrue(any(r.startswith("rc:") for r in v["reasons"]))
        self.assertTrue(any(r == "full-rc" for r in v["reasons"]))

    def test_not_ok_with_zero_counts_is_incomplete(self):
        expected = ["test_a.py"]
        # FAILED (errors=1) used to parse as failures=0/errors=0; now ok=False
        # and errors=1 both gate the verdict.
        per = {"test_a.py": self._file(ran=2, errors=1, ok=False,
                                       returncode=1)}
        v = LEAF.compute_verdict(expected, expected, per,
                                 self._file(ran=2, ok=False, returncode=1),
                                 [], "created")
        self.assertEqual(v["status"], "incomplete")
        self.assertTrue(any(r.startswith("not-ok:") for r in v["reasons"]))
        self.assertTrue(any(r.startswith("failed:") for r in v["reasons"]))

    def test_unexpected_successes_is_incomplete(self):
        expected = ["test_a.py"]
        per = {"test_a.py": self._file(ran=2, unexpected_successes=1,
                                       ok=False, returncode=1)}
        v = LEAF.compute_verdict(expected, expected, per,
                                 self._file(ran=2), [], "created")
        self.assertEqual(v["status"], "incomplete")
        self.assertTrue(any(r.startswith("failed:") for r in v["reasons"]))


if __name__ == "__main__":
    unittest.main()
