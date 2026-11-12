# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Unit tests for run_axi_gate_formal.py verdict semantics.

The remote leaf itself is exercised end-to-end on the owned toolchain; these
tests pin the runner's fail-closed contract locally with the yosys/smtbmc
process boundary mocked: a golden design whose cover is unreached and a
mutant whose assertion proof survives must both fail the stage.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SPEC = importlib.util.spec_from_file_location(
    "run_axi_gate_formal", HERE / "run_axi_gate_formal.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

SOURCES = {
    "g6lc_storamic_axi_gate.sv": HERE.parents[2] / "corev_apu/storamic/g6lc_storamic_axi_gate.sv",
    "g6lc_storamic_cpu_pause.sv": HERE.parents[2] / "corev_apu/storamic/g6lc_storamic_cpu_pause.sv",
    "formal_g6lc_storamic_axi_gate.sv": HERE / "formal_g6lc_storamic_axi_gate.sv",
    "formal_g6lc_storamic_cpu_pause.sv": HERE / "formal_g6lc_storamic_cpu_pause.sv",
}


def _completed(args, rc, out="", err=""):
    return subprocess.CompletedProcess(args, rc, stdout=out, stderr=err)


class VerdictTests(unittest.TestCase):
    """Drive run() with the process boundary mocked.

    smtbmc_response(key, cover) -> (rc, text). key is the design/mutant tag
    parsed from the .smt2 filename; cover is True for the -c cover run.
    """

    def _invoke(self, tmp, smtbmc_response):
        data = Path(tmp) / "data"
        out = Path(tmp) / "out"
        data.mkdir(); out.mkdir()
        for name, src in SOURCES.items():
            (data / name).write_bytes(src.read_bytes())
        fakebin = Path(tmp) / "bin"
        fakebin.mkdir()
        for tool in ("yosys", "yosys-smtbmc", "yices-smt2"):
            (fakebin / tool).write_bytes(b"fake")

        def which(name):
            return str(fakebin / name) if name in (
                "yosys-smtbmc", "yices-smt2") else None

        def run_side_effect(cmd, **kw):
            name = Path(cmd[0]).name
            if name == "yosys":
                return _completed(cmd, 0)
            if name == "yosys-smtbmc":
                smt = Path(cmd[-1]).name
                key = smt.replace("axi-gate-formal-", "").replace(".smt2", "")
                cover = "-c" in cmd
                rc, text = smtbmc_response(key, cover)
                return _completed(cmd, rc, out=text, err="")
            raise AssertionError(f"unexpected subprocess {cmd[0]}")

        fake_yosys_bin = types.ModuleType("yosys_bin")
        fake_yosys_bin.yosys_bin = lambda: str(fakebin / "yosys")
        manifest = {}
        outcomes = []
        with mock.patch.dict(sys.modules, {"yosys_bin": fake_yosys_bin}), \
                mock.patch.object(RUNNER.shutil, "which", side_effect=which), \
                mock.patch.object(RUNNER.subprocess, "check_output",
                                  return_value="yices 2.6\n"), \
                mock.patch.object(RUNNER.subprocess, "run",
                                  side_effect=run_side_effect):
            RUNNER.run(data, out, ["axi-gate-formal"], manifest, [],
                       outcomes, None, None)
        return manifest, outcomes

    @staticmethod
    def _all_pass(key, cover):
        # Golden assertions + covers PASS; every mutant is killed (FAILED).
        if key.startswith("m-"):
            return 1, "Status: FAILED"
        return 0, "Status: PASSED"

    def test_golden_pass_and_all_mutants_killed(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT / "build-platform/workspace") as tmp:
            manifest, outcomes = self._invoke(Path(tmp), self._all_pass)
        self.assertTrue(all(o["pass"] for o in outcomes), outcomes)
        self.assertEqual(
            {o["axi_gate_formal"] for o in outcomes},
            {"axi-gate", "axi-gate-cover", "cpu-pause", "cpu-pause-cover",
             "m-a", "m-b", "m-c", "m-d"})
        self.assertIn("axi_gate_formal", manifest)
        self.assertEqual(manifest["axi_gate_formal"]["mutants"],
                         ["m-a", "m-b", "m-c", "m-d"])

    def test_surviving_mutant_fails_the_stage(self):
        def resp(key, cover):
            if key == "m-a":
                return 0, "Status: PASSED"   # mutant not killed -> fail
            return self._all_pass(key, cover)
        with tempfile.TemporaryDirectory(
                dir=ROOT / "build-platform/workspace") as tmp:
            with self.assertRaises(RuntimeError) as ctx:
                self._invoke(Path(tmp), resp)
        self.assertIn("m-a", str(ctx.exception))
        self.assertIn("survived", str(ctx.exception))

    def test_unreached_cover_is_incomplete_not_pass(self):
        def resp(key, cover):
            if key == "axi-gate" and cover:
                return 1, "Status: FAILED"    # cover goal not reached
            return self._all_pass(key, cover)
        with tempfile.TemporaryDirectory(
                dir=ROOT / "build-platform/workspace") as tmp:
            with self.assertRaises(RuntimeError) as ctx:
                self._invoke(Path(tmp), resp)
        self.assertIn("cover", str(ctx.exception))

    def test_mutant_patch_anchor_must_be_unique(self):
        src = SOURCES["g6lc_storamic_axi_gate.sv"].read_text()
        for _tag, _d, old, new in RUNNER.MUTANTS:
            if "closed_o" in old or "ar_ready" in old or "w_valid" in old:
                self.assertEqual(src.count(old), 1)
        pause = SOURCES["g6lc_storamic_cpu_pause.sv"].read_text()
        self.assertEqual(pause.count(RUNNER.MUTANTS[-1][2]), 1)


if __name__ == "__main__":
    unittest.main()
