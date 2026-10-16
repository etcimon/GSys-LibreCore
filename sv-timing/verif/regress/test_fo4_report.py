# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Reporting gates must not turn a failed emit or excluded path into closure."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from fo4_report import analysis_evidence, residual_summary
from sum3_trial import screen_cases


class EvidenceTest(unittest.TestCase):
    def test_invalid_emit_cannot_fall_back_to_ir_closure(self):
        with self.assertRaisesRegex(ValueError, "INCONCLUSIVE"):
            analysis_evidence({
                "dry_run": False, "post_analyze_valid": False,
                "post_closure": {"closes": True, "worst_path_fo4": 9.0},
            })

    def test_read_emitted_result_even_when_ir_claims_closure(self):
        post = {"paths": [{"path_id": 1}], "frequency_closure": {"closes": False}}
        selected, _ = analysis_evidence({
            "dry_run": False, "post_analyze_valid": True,
            "integrity": dict.fromkeys(("joint_ok", "reparse_ok", "structural_ok"), True),
            "post_analyze": post, "post_closure": {"closes": True},
        })
        self.assertIs(selected, post)

    def test_primary_worklist_does_not_hide_io_or_multicycle_failures(self):
        def path(pid, fo4, kind, mc=False):
            return {
                "path_id": pid, "module_id": 1, "total_fo4": fo4,
                "slack_fo4": 10 - fo4, "path_kind": kind, "multi_cycle": mc,
                "primary_loc": {"file": "counter.sv", "start_line": pid},
            }
        rep = {"modules": [{"id": 1, "name": "counter"}], "paths": [
            path(1, 97.5, "regtoreg", True), path(2, 29, "intoout"),
            path(3, 23.5, "regtoreg"), path(4, 9, "regtoreg"),
        ]}
        summary = residual_summary(rep, 10)
        self.assertEqual(summary["failing_primary_paths"], 2)
        self.assertEqual(summary["failing_io_paths"], 1)
        self.assertEqual(summary["failing_multi_cycle_paths"], 1)
        self.assertEqual(summary["worst_loci"][0]["path_id"], 3)
        self.assertIn("inspect gate", summary["worst_loci"][0]["next_action"])


class TrialScreenTest(unittest.TestCase):
    def test_faster_logic_does_not_hide_area_state_or_target_miss(self):
        rows = [
            dict(width=16, implementation="serial", delay=0.5, area=74),
            dict(width=16, implementation="cached", delay=0.33, area=231,
                 redundant_state_bits=12),
            dict(width=16, implementation="bad", delay=0.6, area=80),
        ]
        screened = screen_cases(rows, 250)
        self.assertTrue(screened[0]["pareto"])
        self.assertTrue(screened[1]["pareto"])
        self.assertFalse(screened[1]["target_met"])
        self.assertFalse(screened[2]["pareto"])
        self.assertAlmostEqual(screened[1]["delay_gain_percent"], 34.0)

    def test_widths_and_unknown_area_cannot_supply_false_dominance(self):
        rows = [
            dict(width=2, implementation="serial", delay=0.1, area=2),
            dict(width=16, implementation="serial", delay=0.5, area=74),
            dict(width=16, implementation="unknown", delay=0.1, area=None),
        ]
        screened = screen_cases(rows, None)
        self.assertTrue(screened[1]["pareto"])
        self.assertIsNone(screened[2]["pareto"])
        self.assertIsNone(screened[1]["target_met"])


if __name__ == "__main__":
    unittest.main()
