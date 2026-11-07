# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Synthetic temporal predicate checks, not CPU execution evidence."""
import unittest

from g6lc_cpu_debug_queue_trace import analyze_states, PROBE, TRACKED


def states(stage, *, late_entry=False, short_hold=False, changed_tag=False):
    aw, w, b = {1: (198, 199, 200), 2: (2, 198, 200), 3: (2, 3, 198)}[stage]
    entry = 205 if late_entry else 20
    for cycle in range(250):
        pre = {name: 0 for name in TRACKED}
        pre.update({
            "clk": 0, "rst_n": 1, "cycles": cycle,
            "hold_started": int(cycle >= 5), "hold_finished": int(cycle >= (100 if short_hold else 197)),
            "q_aw_addr": PROBE, "q_aw_prot": 0 if changed_tag and cycle > entry else 1,
            "q_aw_valid": int(1 <= cycle <= aw), "q_aw_ready": int(cycle == aw),
            "q_w_valid": int(aw < cycle <= w), "q_w_ready": int(cycle == w),
            "q_w_data": 0x11, "q_w_strb": 0x0f, "q_w_last": 1,
            "q_write_addr": PROBE, "q_write_owned": int(aw < cycle <= w),
            "q_b_valid": int(cycle == b), "q_b_ready": 1,
            "q_b_pending": int(stage == 3 and w < cycle < b),
            "q_debug_active": int(entry < cycle <= 220),
            "q_debug_req": int(2 <= cycle <= entry),
        })
        yield pre
        yield {**pre, "clk": 1, "q_debug_active": int(entry <= cycle < 220)}


class QueueTraceTests(unittest.TestCase):
    def test_actual_entry_must_land_between_stage_handshakes(self):
        for stage in (1, 2, 3):
            with self.subTest(stage=stage):
                result = analyze_states(states(stage), stage, 1)
                self.assertEqual(result["classification"], "crossed")
                self.assertEqual(result["hold_edges"], 192)
                self.assertFalse(result["qualification"])

    def test_late_debug_entry_is_not_cross_mode_evidence(self):
        for stage in (1, 2, 3):
            result = analyze_states(states(stage, late_entry=True), stage, 1)
            self.assertEqual(result["classification"], "not-crossed")

    def test_short_hold_rejected(self):
        with self.assertRaisesRegex(ValueError, "hold interval"):
            analyze_states(states(1, short_hold=True), 1, 1)

    def test_changed_firmware_aw_origin_rejected(self):
        with self.assertRaisesRegex(ValueError, "AW origin changed"):
            analyze_states(states(1, changed_tag=True), 1, 1)

    def test_wrong_live_origin_oracle_rejects_retained_firmware(self):
        for stage in (1, 2, 3):
            with self.assertRaisesRegex(ValueError, "live-origin oracle"):
                analyze_states(states(stage), stage, 1, wrong_live_origin=True)

    def test_incomplete_round_trip_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing firmware"):
            analyze_states(list(states(1))[:300], 1, 1)

    def test_missing_probe_rejected(self):
        samples = list(states(1))
        for sample in samples:
            sample.pop("q_debug_active")
        with self.assertRaisesRegex(ValueError, "missing queued-debug"):
            analyze_states(samples, 1, 1)


if __name__ == "__main__":
    unittest.main()
