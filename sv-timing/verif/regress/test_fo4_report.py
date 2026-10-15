# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Reporting gates must not turn a failed emit or excluded path into closure."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from fo4_report import analysis_evidence, residual_summary


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


if __name__ == "__main__":
    unittest.main()
