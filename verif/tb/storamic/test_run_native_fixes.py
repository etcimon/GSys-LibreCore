#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline checks for the native-fixes stage judge (no simulation)."""
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_native_fixes as FX

ROOT = Path(__file__).resolve().parents[3]


class NativeFixesJudge(unittest.TestCase):
    def test_lu_pass_needs_success_and_no_fatal(self):
        self.assertTrue(FX.judge_lu({"success": True}, "pass")[0])
        self.assertFalse(FX.judge_lu({"success": False, "fail_code": "33"}, "pass")[0])
        self.assertFalse(FX.judge_lu({"success": True, "fatal": True}, "pass")[0])

    def test_lu_hazard_needs_a_hazard_code(self):
        for code in ("33", "34"):
            self.assertTrue(FX.judge_lu({"success": False, "fail_code": code}, "hazard")[0])
        self.assertFalse(FX.judge_lu({"success": False, "fail_code": "126"}, "hazard")[0])
        self.assertFalse(FX.judge_lu({"success": False, "fail_code": None}, "hazard")[0])
        self.assertFalse(FX.judge_lu({"success": True}, "hazard")[0])

    def test_verdict(self):
        good = {"cases": {"a": {"pass": True}}, "mutants": {"m": {"killed": True}},
                "incomplete": []}
        self.assertEqual(FX.verdict(good), "pass")
        self.assertEqual(FX.verdict(dict(good, incomplete=["x"])), "incomplete")
        self.assertEqual(FX.verdict(dict(good, mutants={})), "fail")
        self.assertEqual(FX.verdict(dict(good, mutants={"m": {"killed": False}})), "fail")
        self.assertEqual(FX.verdict(dict(good, cases={"a": {"pass": False}})), "fail")

    def test_symbol_scan(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a.cpp").write_text("x__DOT__gen_dmi_sberror__DOT__y")
            (Path(tmp) / "b.log").write_text("gen_other")
            self.assertTrue(FX.has_symbol(tmp, FX.SHIM_SYMBOL))
            self.assertFalse(FX.has_symbol(tmp, "gen_other"))

    def test_mutant_anchor_and_gate_exist_once(self):
        _name, rel, anchor, repl = FX.LU_MUTANT
        text = (ROOT / rel).read_text().replace("\r\n", "\n")
        self.assertEqual(text.count(anchor), 1)
        self.assertNotEqual(anchor, repl)
        harness = (ROOT / "corev_apu/tb/ariane_testharness.sv").read_text()
        self.assertEqual(harness.count("begin : " + FX.SHIM_SYMBOL), 1)

    def test_firmware_codes_match_source(self):
        text = (ROOT / FX.FW_LU).read_text()
        m = re.search(r"FAIL_MMIO = (\d+), FAIL_PARTIAL = (\d+)", text)
        self.assertEqual((int(m.group(1)), int(m.group(2))),
                         (FX.FAIL_MMIO, FX.FAIL_PARTIAL))

    def test_storamic_builds_are_flagged(self):
        for tag, _target, defines, storamic in FX.BUILDS:
            self.assertEqual("G6LC_STORAMIC" in defines, storamic, tag)

    def test_stage_is_registered(self):
        self.assertIn('"native-fixes"', (ROOT / "verif/tb/storamic/run_remote.py").read_text())
        self.assertIn("run_native_fixes", (ROOT / "verif/tb/storamic/run_leaf.py").read_text())


if __name__ == "__main__":
    unittest.main()
