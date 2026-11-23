#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline checks for the native-ckpt-l2l3 stage judge (no simulation)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_native_ckpt_l2l3 as L2CK

ROOT = Path(__file__).resolve().parents[3]


class NativeCkptL2L3Judge(unittest.TestCase):
    def test_mutant_anchors_exist_exactly_once(self):
        for name, defs, patches, fw_key, _ in L2CK.MUTANTS:
            self.assertIn("G6LC_STORAMIC_CKPT", defs, name)
            self.assertEqual(fw_key, "flow", name)
            for rel, anchor, repl in patches:
                text = (ROOT / rel).read_text().replace("\r\n", "\n")
                self.assertEqual(text.count(anchor), 1, f"{name}: {rel}")
                self.assertNotEqual(anchor, repl, name)

    def test_judge_fail_requires_named_code(self):
        self.assertTrue(L2CK.judge_mutant(("fail", 16), {"fail_code": "16"}))
        self.assertFalse(L2CK.judge_mutant(("fail", 16), {"fail_code": "17"}))
        self.assertFalse(L2CK.judge_mutant(("fail", 16), {"fail_code": None}))

    def test_judge_refused_no_issue(self):
        st = {"issue": "0", "done": "0", "valid": "0"}
        exp = ("refused-no-issue", None)
        self.assertTrue(L2CK.judge_mutant(
            exp, {"success": False, "fail_code": "2", "state": st}))
        self.assertFalse(L2CK.judge_mutant(
            exp, {"success": True, "fail_code": None, "state": st}))
        self.assertFalse(L2CK.judge_mutant(
            exp, {"success": False, "fail_code": None, "state": st}))
        for k in st:
            self.assertFalse(L2CK.judge_mutant(
                exp, {"success": False, "fail_code": "2",
                      "state": dict(st, **{k: "1"})}))

    def test_verdict_requires_cases_and_all_mutants(self):
        good = {"cases": {"a": {"pass": True}},
                "mutants": {m[0]: {"killed": True} for m in L2CK.MUTANTS},
                "incomplete": []}
        self.assertEqual(L2CK.verdict(good), "pass")
        self.assertEqual(L2CK.verdict(dict(good, incomplete=["x"])), "incomplete")
        self.assertEqual(L2CK.verdict(dict(good, mutants={})), "fail")

    def test_stage_is_registered(self):
        self.assertIn('"native-ckpt-l2l3"',
                      (ROOT / "verif/tb/storamic/run_remote.py").read_text())
        self.assertIn("run_native_ckpt_l2l3",
                      (ROOT / "verif/tb/storamic/run_leaf.py").read_text())


if __name__ == "__main__":
    unittest.main()
