# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline workspace containment/evidence preservation for the route tools."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
WORKSPACE = ROOT / "build-platform/workspace"


class RouteToolSafety(unittest.TestCase):
    def run_tool(self, name, *arguments):
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name(name)), *map(str, arguments)],
            capture_output=True, text=True, timeout=10)

    def test_runner_refuses_external_output(self):
        result = self.run_tool("run_route.py", "--output-root", ROOT / "route-output-must-not-exist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be contained", result.stderr)
        self.assertFalse((ROOT / "route-output-must-not-exist").exists())

    def test_runner_preserves_existing_evidence(self):
        with tempfile.TemporaryDirectory(dir=WORKSPACE) as folder:
            marker = Path(folder) / "preserve"
            marker.write_bytes(b"evidence")
            result = self.run_tool("run_route.py", "--output-root", folder)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_bytes(), b"evidence")
            self.assertEqual(list(Path(folder).iterdir()), [marker])

    def test_checker_refuses_external_snapshot(self):
        result = self.run_tool("check_route.py", "--snapshot", ROOT,
                               "--output-root", ROOT / "route-check-must-not-exist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be contained", result.stderr)
        self.assertFalse((ROOT / "route-check-must-not-exist").exists())

    def test_checker_rejects_changed_source_before_tools(self):
        with tempfile.TemporaryDirectory(dir=WORKSPACE) as folder:
            snapshot = Path(folder) / "snapshot"
            (snapshot / "source").mkdir(parents=True)
            (snapshot / "source/input.sv").write_bytes(b"modified")
            (snapshot / "result.json").write_text(json.dumps({
                "sources": {"input.sv": hashlib.sha256(b"original").hexdigest()}}), encoding="utf-8")
            output = Path(folder) / "checks"
            result = self.run_tool("check_route.py", "--snapshot", snapshot, "--output-root", output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("snapshot source changed", result.stderr)
            self.assertFalse(output.exists())


class CheckpointRouteUnoptflatPins(unittest.TestCase):
    """Unit tests for run_checkpoint_route's crossbar UNOPTFLAT pin-check."""

    LEGACY = [
        "top.gen.crossbar.g_legacy_xbar.slv.err_resp[82]",
        "top.gen.crossbar.g_legacy_xbar.mst.__Vcellout__x.i_id_prepend__slv_aw_readies_o",
    ]
    NATIVE = [
        "top.gen.crossbar.g_native_xbar.slv.err_resp[82]",
        "top.gen.crossbar.g_native_xbar.mst.__Vcellout__x.i_id_prepend__slv_aw_readies_o",
    ]

    def setUp(self):
        import run_checkpoint_route as rcr
        self.rcr = rcr
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data = self.root / "data"
        self.data.mkdir()
        self.out = self.root / "out"
        self.out.mkdir()
        (self.data / rcr.PINS_FILE).write_text(json.dumps({"flavors": {
            "legacy": {"identities": self.LEGACY},
            "native": {"identities": self.NATIVE},
        }}), encoding="utf-8")

    def _log(self, name, text):
        path = self.out / name
        path.write_text(text, encoding="utf-8")
        return path

    def _ident(self, sig):
        return f"%Warning-UNOPTFLAT: f.sv:1:1: Circular combinational logic: '{sig}'\n"

    def _check(self, log, flavor="legacy"):
        return self.rcr._check_unoptflat_pins(
            self.data, self.out, "crossbar", log, flavor)

    def test_missing_pins_file_is_an_error(self):
        (self.data / self.rcr.PINS_FILE).unlink()
        log = self._log("b.log", self._ident(self.LEGACY[0]))
        with self.assertRaises(RuntimeError):
            self._check(log)

    def test_missing_flavour_is_an_error(self):
        log = self._log("b.log", self._ident(self.LEGACY[0]))
        with self.assertRaises(RuntimeError):
            self._check(log, flavor="nosuch")

    def test_all_pinned_identities_pass(self):
        log = self._log("b.log",
                        self._ident(self.LEGACY[0]) + self._ident(self.LEGACY[1]))
        result = self._check(log)
        self.assertEqual(result["flavor"], "legacy")
        self.assertEqual(result["observed"], 2)
        self.assertEqual(result["pinned"], 2)
        self.assertEqual(result["stale_pins"], [])

    def test_flavours_are_independent(self):
        # A native-flavour identity must NOT satisfy the legacy pin set.
        log = self._log("b.log", self._ident(self.NATIVE[0]))
        with self.assertRaises(RuntimeError) as ctx:
            self._check(log, flavor="legacy")
        self.assertIn(self.NATIVE[0], str(ctx.exception))
        # ...but it is pinned under the native flavour.
        result = self._check(log, flavor="native")
        self.assertEqual(result["observed"], 1)
        self.assertEqual(result["stale_pins"], [self.NATIVE[1]])

    def test_unpinned_identity_fails_naming_it(self):
        extra = "top.gen.crossbar.brand_new_loop.sig"
        log = self._log("b.log",
                        self._ident(self.LEGACY[0]) + self._ident(extra))
        with self.assertRaises(RuntimeError) as ctx:
            self._check(log)
        self.assertIn(extra, str(ctx.exception))

    def test_stale_pin_is_reported_not_failed(self):
        log = self._log("b.log", self._ident(self.LEGACY[0]))
        result = self._check(log)
        self.assertEqual(result["stale_pins"], [self.LEGACY[1]])
        self.assertEqual(result["observed"], 1)

    def test_shipped_pins_file_parses_both_flavours(self):
        flavors = self.rcr._unoptflat_pins(Path(__file__).resolve().parent)
        self.assertIsNotNone(flavors)
        self.assertEqual(set(flavors), {"legacy", "native"})
        for flavor in flavors.values():
            self.assertEqual(len(flavor["identities"]), 3)


if __name__ == "__main__":
    unittest.main()
