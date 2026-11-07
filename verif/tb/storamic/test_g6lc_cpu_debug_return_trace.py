# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Synthetic return-direction temporal predicates, not CPU qualification."""
import unittest

from g6lc_cpu_debug_queue_trace import TRACKED
from g6lc_cpu_debug_return_trace import analyze_states, TARGET


def states(privilege=3, enabled=1, late=False, relabel=False):
    exit_cycle, resumed = (410, 420) if late else (30, 400)
    for cycle in range(450):
        pre = {name: 0 for name in TRACKED}
        pre.update({
            "clk": 0, "rst_n": 1, "cycles": cycle,
            "hold_started": int(cycle >= 7), "hold_finished": int(cycle >= 391),
            "q_debug_req": int(cycle <= 2), "q_debug_active": int(2 < cycle <= exit_cycle),
            "q_aw_valid": int(cycle in (5, resumed)), "q_aw_ready": 1,
            "q_aw_addr": 0x50000020 if cycle == resumed else TARGET,
            "q_aw_prot": ({0: 2, 1: 3, 3: 1}[privilege] if enabled else 0)
                         if cycle == resumed else int(relabel),
            "q_w_valid": int(cycle == 6), "q_w_ready": 1, "q_write_addr": TARGET,
            "q_w_data": 0x6600000000, "q_w_strb": 0xf0, "q_w_last": 1,
            "q_b_pending": int(7 <= cycle < 392), "q_b_valid": int(cycle == 393), "q_b_ready": 1,
        })
        yield pre
        yield {**pre, "clk": 1, "q_debug_active": int(2 <= cycle < exit_cycle)}


class ReturnTraceTests(unittest.TestCase):
    def test_actual_exit_crosses_held_debug_response(self):
        for p in (0, 1, 3):
            for enabled in (0, 1):
                result = analyze_states(states(p, enabled), enabled, p)
                self.assertEqual(result["classification"], "crossed")
                self.assertEqual(result["bound_debug_origin"], 0)
                self.assertFalse(result["qualification"])

    def test_drain_before_exit_cannot_be_promoted_as_crossing(self):
        result = analyze_states(states(late=True), 1)
        self.assertEqual(result["classification"], "not-crossed")

    def test_relabeling_debug_transaction_rejected(self):
        with self.assertRaisesRegex(ValueError, "relabeled trusted"):
            analyze_states(states(relabel=True), 1)

    def test_wrong_live_return_oracle_rejects_all_enabled_modes(self):
        for p in (0, 1, 3):
            with self.assertRaisesRegex(ValueError, "live-return oracle"):
                analyze_states(states(p), 1, p, wrong_live_origin=True)

    def test_incomplete_program_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing real"):
            analyze_states(list(states())[:200], 1)
