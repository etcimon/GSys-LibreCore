# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Synthetic identity rejection tests, not runtime or native qualification."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

if sys.platform == "win32":
    # The execution runner is Linux-only; identity parsing itself is portable.
    with patch.dict(sys.modules, {"resource": types.ModuleType("resource")}):
        from run_leaf import build_environment, runtime_identity
else:
    from run_leaf import build_environment, runtime_identity


class ForkRuntimeIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.runtime = self.base / "runtime"
        (self.runtime / "include").mkdir(parents=True)
        (self.runtime / "bin").mkdir()
        self.header = self.runtime / "include/verilated_funcs.h"
        self.header.write_text("synthetic header fixture\n")
        self.driver = self.runtime / "bin/verilator"
        self.driver.write_text("synthetic driver fixture\n")
        self.binary = self.runtime / "bin/verilator_bin"
        self.binary.write_bytes(b"synthetic compiler identity")
        self.provenance = self.base / "provenance.json"
        self.provenance.write_text('{"fixture":true}')
        self.evidence = self.base / "canary-execution.txt"
        self.evidence.write_text("synthetic evidence fixture")
        self.record = {
            "kind": "g6lc-fork-native", "privateRoot": str(self.runtime),
            "originalRoot": str(self.runtime), "fixedHeaderSha256": self.sha(self.header),
            "compilerSha256": self.sha(self.binary),
            "runtimeFiles": {p.relative_to(self.runtime).as_posix(): self.sha(p)
                             for p in self.runtime.rglob("*") if p.is_file()},
            "provenance": str(self.provenance), "provenanceSha256": self.sha(self.provenance),
            "simulatorPgo": True, "verilatorOptions": ["--unroll-count", "256", "--unroll-stmts", "131072"],
        }
        self.canaries = [
            {"tag": "assertion-positive", "rc": 0, "text": "STORAMIC_RUNTIME_PASS",
             "artifacts": {str(self.evidence): self.sha(self.evidence)}},
            {"tag": "assertion-negative", "rc": 1, "text": "STORAMIC_RUNTIME_NEGATIVE",
             "artifacts": {str(self.evidence): self.sha(self.evidence)}},
        ]
        self.record_path = self.base / "runtime.json"
        self.out = self.base / "output"
        self.out.mkdir()
        self.env = {"STORAMIC_RUNTIME_JSON": str(self.record_path),
                    "STORAMIC_RUNTIME_HEADER_SHA256": self.sha(self.header),
                    "VERILATOR": str(self.driver)}

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def collect(self):
        self.record_path.write_text(json.dumps(self.record))
        (self.base / "canaries.json").write_text(json.dumps(self.canaries))
        with patch.dict(os.environ, self.env):
            return runtime_identity(self.out)

    def test_native_fork_does_not_require_fabricated_legacy_failure(self):
        result = self.collect()
        self.assertEqual(result["kind"], "g6lc-fork-native")
        self.assertTrue(result["simulator_pgo"])
        self.assertEqual(result["verilator_options"], self.record["verilatorOptions"])

    def test_missing_negative_rejects(self):
        self.canaries[1]["rc"] = 0
        with self.assertRaisesRegex(RuntimeError, "FORK_RUNTIME_IDENTITY"):
            self.collect()

    def test_unrelated_failure_rejects(self):
        self.canaries[1]["text"] = "some unrelated failure"
        with self.assertRaisesRegex(RuntimeError, "FORK_RUNTIME_IDENTITY"):
            self.collect()

    def test_changed_runtime_rejects(self):
        self.header.write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "FORK_RUNTIME_IDENTITY"):
            self.collect()

    def test_changed_canary_artifact_rejects(self):
        self.evidence.write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "CANARY_ARTIFACTS"):
            self.collect()

    def test_changed_provenance_rejects(self):
        self.provenance.write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "PROVENANCE"):
            self.collect()

    def test_legacy_cannot_use_native_root_exception(self):
        del self.record["kind"]
        with self.assertRaisesRegex(RuntimeError, "STORAMIC_RUNTIME_IDENTITY"):
            self.collect()

    def test_native_generation_keeps_validated_relocated_root(self):
        with patch.dict(os.environ, {"VERILATOR_ROOT": "/unrelated/shared/root"}):
            env = build_environment({"kind": "g6lc-fork-native", "root": str(self.runtime)})
        self.assertEqual(env["VERILATOR_ROOT"], str(self.runtime))

    def test_legacy_generation_does_not_inherit_arbitrary_root(self):
        with patch.dict(os.environ, {"VERILATOR_ROOT": "/unrelated/shared/root"}):
            env = build_environment({"root": str(self.runtime)})
        self.assertNotIn("VERILATOR_ROOT", env)

    def test_external_compile_flags_do_not_contaminate_builds(self):
        keys = ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VPATH")
        with patch.dict(os.environ, {key: "untrusted flags" for key in keys}):
            env = build_environment({"kind": "g6lc-fork-native", "root": str(self.runtime)})
        self.assertTrue(all(key not in env for key in keys))


if __name__ == "__main__":
    unittest.main()
