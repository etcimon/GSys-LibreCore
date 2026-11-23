#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline checks for the native-ckpt-w2 stage judge (no simulation)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_native_ckpt_w2 as W2

ROOT = Path(__file__).resolve().parents[3]


class NativeCkptW2Judge(unittest.TestCase):
    def test_mutant_anchors_exist_exactly_once(self):
        for name, _target, defs, patches, fw_key, _ in W2.MUTANTS:
            self.assertIn("G6LC_STORAMIC_CKPT", defs, name)
            self.assertIn(fw_key, ("flow", "mh"), name)
            for rel, anchor, repl in patches:
                text = (ROOT / rel).read_text().replace("\r\n", "\n")
                self.assertEqual(text.count(anchor), 1, f"{name}: {rel}")
                self.assertNotEqual(anchor, repl, name)

    def test_judge_fail_or_violation(self):
        exp = ("fail-or-violation", (25, 26))
        self.assertTrue(W2.judge_mutant(exp, {"fail_code": "25", "text_markers": ""}))
        self.assertTrue(W2.judge_mutant(exp, {"fail_code": "26", "text_markers": ""}))
        self.assertTrue(W2.judge_mutant(
            exp, {"fail_code": None, "text_markers": "STORAMIC_CKPT_VIOLATION"}))
        self.assertFalse(W2.judge_mutant(exp, {"fail_code": "16", "text_markers": ""}))
        self.assertFalse(W2.judge_mutant(exp, {"fail_code": None, "text_markers": ""}))

    def test_firmware_codes_match_source(self):
        text = (ROOT / W2.FW_MH).read_text()
        for sym, val in (("FAIL_PEER_DATA", W2.FAIL_PEER_DATA),
                         ("FAIL_PEER_CODE", W2.FAIL_PEER_CODE)):
            m = re.search(rf"\b{sym}\s*=\s*(\d+)", text)
            self.assertIsNotNone(m, sym)
            self.assertEqual(int(m.group(1)), val, sym)

    def test_verdict_requires_cases_and_all_mutants(self):
        good = {"cases": {"a": {"pass": True}},
                "mutants": {m[0]: {"killed": True} for m in W2.MUTANTS},
                "incomplete": []}
        self.assertEqual(W2.verdict(good), "pass")
        self.assertEqual(W2.verdict(dict(good, incomplete=["x"])), "incomplete")
        self.assertEqual(W2.verdict(dict(good, mutants={})), "fail")

    def test_stage_is_registered(self):
        self.assertIn('"native-ckpt-w2"',
                      (ROOT / "verif/tb/storamic/run_remote.py").read_text())
        self.assertIn("run_native_ckpt_w2",
                      (ROOT / "verif/tb/storamic/run_leaf.py").read_text())


if __name__ == "__main__":
    unittest.main()
