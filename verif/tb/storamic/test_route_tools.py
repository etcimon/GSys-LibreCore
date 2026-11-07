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


if __name__ == "__main__":
    unittest.main()
