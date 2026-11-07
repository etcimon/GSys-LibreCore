# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline safety checks for the local-only origin runner."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
RUNNER = Path(__file__).with_name("run_origin.py")
WORKSPACE = ROOT / "build-platform/workspace"


class OriginRunnerSafety(unittest.TestCase):
    def invoke(self, output, profiles="shim"):
        return subprocess.run(
            [sys.executable, str(RUNNER), "--profiles", profiles,
             "--output-root", str(output)], capture_output=True, text=True, timeout=10)

    def test_outside_workspace_refused(self):
        result = self.invoke(ROOT / "origin-output-must-not-exist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output must be contained", result.stderr)
        self.assertFalse((ROOT / "origin-output-must-not-exist").exists())

    def test_unknown_profile_refused(self):
        with tempfile.TemporaryDirectory(dir=WORKSPACE) as folder:
            output = Path(folder) / "output"
            result = self.invoke(output, "unknown")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown or duplicate profile", result.stderr)
            self.assertFalse(output.exists())

    def test_duplicate_profile_refused(self):
        with tempfile.TemporaryDirectory(dir=WORKSPACE) as folder:
            output = Path(folder) / "output"
            result = self.invoke(output, "shim,shim")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown or duplicate profile", result.stderr)
            self.assertFalse(output.exists())

    def test_existing_output_not_overwritten(self):
        with tempfile.TemporaryDirectory(dir=WORKSPACE) as folder:
            sentinel = Path(folder) / "sentinel"
            sentinel.write_bytes(b"preserve")
            result = self.invoke(folder)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_bytes(), b"preserve")
            self.assertEqual(list(Path(folder).iterdir()), [sentinel])


if __name__ == "__main__":
    unittest.main()
