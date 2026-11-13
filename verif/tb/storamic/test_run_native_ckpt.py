# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline checks for the native-ckpt stage judge (no simulation)."""
import unittest
from pathlib import Path

import run_native_ckpt as CK

ROOT = Path(__file__).resolve().parents[3]
LINE = ("STORAMIC_CKPT_STATE final t=100 initialized=1 locked=0 busy=0 phase=0 "
        "valid=1 generation=1 policy_ready=1 policy_epoch=1 providers=1f "
        "present=1 paused=000 errors=000 map_gen=1 reset_gen=0 pauses=3 "
        "releases=3 issue=2 done=2 error=0 refuse=1")


class NativeCkptJudgeTest(unittest.TestCase):
    def test_parse_state_takes_last_final_line(self):
        text = LINE.replace("generation=1", "generation=0") + "\n" + LINE + "\n"
        st = CK.parse_state(text)
        self.assertEqual(st["generation"], "1")
        self.assertEqual(st["providers"], "1f")

    def test_missing_state_line_is_not_ok(self):
        ok, why = CK.state_ok(CK.parse_state("no marker"), {"initialized": "1"})
        self.assertFalse(ok)
        self.assertIn("no STORAMIC_CKPT_STATE", why)

    def test_state_expectations(self):
        st = CK.parse_state(LINE)
        self.assertTrue(CK.state_ok(st, {"valid": "1", "pauses": (">=", 3)})[0])
        self.assertFalse(CK.state_ok(st, {"pauses": (">=", 4)})[0])
        self.assertFalse(CK.state_ok(st, {"locked": "1"})[0])
        self.assertFalse(CK.state_ok(st, {"absent_field": "1"})[0])

    def test_mutant_killed_only_by_named_symptom(self):
        sim = {"fail_code": "16", "text_markers": ""}
        self.assertTrue(CK.judge_mutant(("fail", 16), sim))
        self.assertFalse(CK.judge_mutant(("fail", 17), sim))
        self.assertFalse(CK.judge_mutant(("fail", 16),
                                         {"fail_code": None, "text_markers": ""}))
        self.assertTrue(CK.judge_mutant(
            ("marker", CK.REFUSAL), {"fail_code": None,
                                     "text_markers": CK.REFUSAL}))
        self.assertFalse(CK.judge_mutant(
            ("marker", CK.REFUSAL), {"fail_code": "126", "text_markers": ""}))

    def test_verdict_requires_cases_and_all_mutants(self):
        good_case = {"pass": True}
        killed = {n[0]: {"killed": True} for n in CK.MUTANTS}
        self.assertEqual(CK.verdict({"cases": {"a": good_case},
                                     "mutants": killed, "incomplete": []}), "pass")
        self.assertEqual(CK.verdict({"cases": {}, "mutants": killed,
                                     "incomplete": []}), "fail")
        partial = dict(list(killed.items())[:-1])
        self.assertEqual(CK.verdict({"cases": {"a": good_case},
                                     "mutants": partial, "incomplete": []}), "fail")
        self.assertEqual(CK.verdict({"cases": {"a": good_case}, "mutants": killed,
                                     "incomplete": ["x"]}), "incomplete")

    def test_mutant_anchors_exist_exactly_once(self):
        for name, patches, fw_key, _ in CK.MUTANTS:
            self.assertIn(fw_key, ("flow", "presence", "cold"), name)
            for rel, anchor, repl in patches:
                text = (ROOT / rel).read_text().replace("\r\n", "\n")
                self.assertEqual(text.count(anchor), 1, name)
                self.assertNotEqual(anchor, repl, name)

    def test_locked_stall_needs_reset_checkpoint_and_lock(self):
        st = {"locked": "1", "valid": "1", "reset_gen": "1"}
        exp = ("locked-stall", None)
        self.assertTrue(CK.judge_mutant(exp, {"success": False, "state": st}))
        self.assertFalse(CK.judge_mutant(exp, {"success": True, "state": st}))
        for key in st:
            bad = dict(st, **{key: "0"})
            self.assertFalse(CK.judge_mutant(exp, {"success": False, "state": bad}))
        self.assertFalse(CK.judge_mutant(exp, {"success": False, "state": None}))

    def test_build_missing_needs_clean_elaboration_and_named_member(self):
        log = "g6lc_tb.cpp:1: error: has no member named 'x__gen_native_ckpt__y'"
        self.assertTrue(CK.judge_build_missing("gen_native_ckpt", False, log))
        self.assertFalse(CK.judge_build_missing("gen_native_ckpt", True, log))
        self.assertFalse(CK.judge_build_missing(
            "gen_native_ckpt", False, "%Error: syntax\n" + log))
        self.assertFalse(CK.judge_build_missing(
            "gen_native_ckpt", False, "error: has no member named 'other'"))

    def test_firmware_codes_match_source(self):
        src = (ROOT / CK.FW_CKPT).read_text()
        for name, val in (("FAIL_DATA_RESTORED", CK.FAIL_DATA_RESTORED),
                          ("FAIL_CODE_RESTORED", CK.FAIL_CODE_RESTORED),
                          ("FAIL_SC_SUCCEEDED", CK.FAIL_SC_SUCCEEDED),
                          ("FAIL_TRIGGER_OK", CK.FAIL_TRIGGER_OK)):
            self.assertIn(f"{name} = {val},", src)

    def test_stage_is_registered(self):
        self.assertIn('"native-ckpt"', (ROOT / "verif/tb/storamic/run_remote.py").read_text())
        self.assertIn("run_native_ckpt", (ROOT / "verif/tb/storamic/run_leaf.py").read_text())


if __name__ == "__main__":
    unittest.main()
