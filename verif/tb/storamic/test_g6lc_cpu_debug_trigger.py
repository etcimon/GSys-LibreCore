# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Tdata-trigger firmware structure checks, not CPU trigger qualification."""
import hashlib
import unittest

import g6lc_cpu_debug_trigger_program as trigger
import run_cpu_debug_trigger as runner
from test_g6lc_cpu_debug_program import branch_offset


def words(image):
    return [int(w, 16) for w in image.decode("ascii").split()]


class TriggerProgramTests(unittest.TestCase):
    def test_image_sizes_and_targets(self):
        for mechanism in ("exec", "store", "load"):
            for privilege in (0, 3):
                with self.subTest(mechanism=mechanism, privilege=privilege):
                    normal, debug = (words(i) for i in
                                     trigger.build_trigger_program(privilege, mechanism))
                    self.assertEqual((len(normal), len(debug)), (1024, 1024))
                    self.assertEqual(normal[0x800 // 4] if False else debug[0x800 // 4],
                                     0x0400006f)
                    self.assertEqual(debug[0x808 // 4], 0x500002b7)

    def test_firmware_target_per_mechanism(self):
        # exec: sw x6,48(x5) at T (Boot+0x140); store/load: the same access is
        # delayed to Boot+SL_PC_OFF (Boot+0x2c0) by NOPs that drain the
        # post-DRET frontend transient; the instruction after the access hangs.
        for mechanism, expected in (("exec", 0x0262a823), ("store", 0x0262a823),
                                    ("load", 0x0342a303)):
            with self.subTest(mechanism=mechanism):
                normal, _ = (words(i) for i in
                             trigger.build_trigger_program(3, mechanism))
                off = (trigger.FIRMWARE_TARGET if mechanism == "exec"
                       else trigger.SL_PC_OFF)
                self.assertEqual(normal[off // 4], expected)
                self.assertEqual(normal[off // 4 + 1], 0x0000006f)

    def test_debug_programs_tselect_tdata2_tdata1_then_dret(self):
        for mechanism in ("exec", "store", "load"):
            for privilege in (0, 3):
                with self.subTest(mechanism=mechanism, privilege=privilege):
                    _, debug = (words(i) for i in
                                trigger.build_trigger_program(privilege, mechanism))
                    # CSR writes: tselect(0x7A0), tdata2(0x7A2), tdata1(0x7A1).
                    csr = [(w >> 20, (w >> 15) & 31, (w >> 12) & 7)
                           for w in debug if w & 127 == 0x73]
                    numbers = [n for n, _, f3 in csr if f3 == 1]
                    self.assertIn(0x7A0, numbers)   # tselect
                    self.assertIn(0x7A2, numbers)   # tdata2
                    self.assertIn(0x7A1, numbers)   # tdata1 (arm + disarm)
                    self.assertIn(0x7b200073, debug)  # DRET present

    def test_dispatch_branches_target_failure(self):
        for mechanism in ("exec", "store", "load"):
            _, debug = (words(i) for i in
                        trigger.build_trigger_program(3, mechanism))
            bne_count = 0
            for index, word in enumerate(debug):
                if word & 127 == 0x63:
                    funct3 = (word >> 12) & 7
                    target = index * 4 + branch_offset(word)
                    if funct3 == 1:      # BNE fail branches -> 0x300
                        self.assertEqual(target, 0x300)
                        bne_count += 1
                    else:                # BEQ dispatch -> first-entry path
                        self.assertGreater(target, 0x840)
            self.assertGreaterEqual(bne_count, 3)

    def test_second_entry_records_dpc_at_probe56(self):
        _, debug = (words(i) for i in trigger.build_trigger_program(3, "exec"))
        # Probe+56 store offset encoding appears (sw x6,56(x5)).
        self.assertTrue(any(((w >> 25) << 5) | ((w >> 7) & 31) == 56
                            for w in debug if w & 127 == 0x23))

    def test_denial_program_uses_tselect_and_mcause_handler(self):
        normal, debug = (words(i) for i in trigger.build_denial_program(3))
        self.assertEqual(normal[0x100 // 4], 0x7a002373)   # csrr x6,tselect
        self.assertEqual(normal[0x300 // 4], 0x34202373)   # csrr x6,mcause
        self.assertEqual(normal[0x104 // 4], 0x2200313)    # resume: addi x6,0,0x22
        # no debug vectors used: debug image is only fail stubs
        self.assertEqual(debug[0x800 // 4], 0x0400006f)

    def test_validation(self):
        for priv, mech in ((1, "exec"), (2, "exec"), (3, "bogus"), (0, "deny")):
            with self.subTest(priv=priv, mech=mech):
                with self.assertRaises(ValueError):
                    if mech == "deny":
                        trigger.build_denial_program(priv)
                    else:
                        trigger.build_trigger_program(priv, mech)

    def test_metadata_counts(self):
        meta = trigger.program_metadata(3, "exec")
        self.assertEqual(meta["mechanism_id"], 3)
        self.assertEqual(meta["expected_writes"], 8)
        self.assertEqual(meta["csr_checks"], 2)
        meta6 = trigger.program_metadata(3, "deny")
        self.assertEqual(meta6["expected_writes"], 4)
        self.assertEqual(meta6["expected_reads"], 0)


class TriggerRunnerTests(unittest.TestCase):
    def test_case_inventory(self):
        cases = runner._case_list()
        positives = [c for c in cases
                     if not c["program_mutant"] and not c["mutant"]
                     and not c["negative_firmware"]]
        negatives = [c for c in cases
                     if c["program_mutant"] or c["mutant"]
                     or c["negative_firmware"]]
        # exec 8 + store 3 + load 3 + deny 2 = 16 positives; 3 negatives.
        self.assertEqual(len(positives), 16)
        self.assertEqual(len(negatives), 3)
        by_mech = {}
        for c in positives:
            by_mech.setdefault(c["mechanism"], []).append(c)
        self.assertEqual(len(by_mech[3]), 8)
        self.assertEqual(len(by_mech[4]), 3)
        self.assertEqual(len(by_mech[5]), 3)
        self.assertEqual(len(by_mech[6]), 2)
        # negatives: pm+x1 on exec, fw on store
        self.assertEqual(sum(c["program_mutant"] for c in negatives), 1)
        self.assertEqual(sum(c["mutant"] for c in negatives), 1)
        self.assertEqual(sum(c["negative_firmware"] for c in negatives), 1)

    def test_arm_slot_detection(self):
        _, debug = trigger.build_trigger_program(3, "exec")
        words_list, slot = runner._arm_slot(debug)
        self.assertEqual(words_list[slot], runner.TDATA1_CSR_WORD)
        self.assertEqual(words_list[slot + 1], runner.DPC_T_SETUP_WORD)
        # NOP'ing it must change exactly one word
        words_list[slot] = 0x00000013
        self.assertNotEqual(
            hashlib.sha256(debug).hexdigest(),
            hashlib.sha256(
                "".join(f"{w:08x}\n" for w in words_list).encode()).hexdigest())

    def test_mechanism_counts_cover_optional_slots(self):
        # store/load have optional AXI slots -> None sentinel for the
        # interpreter-checked variable count.
        self.assertIsNone(runner.MECHANISM_COUNTS[4][0])
        self.assertIsNone(runner.MECHANISM_COUNTS[5][1])
        self.assertEqual(runner.MECHANISM_COUNTS[6], (4, 0, 0, 0, 0, 0))


if __name__ == "__main__":
    unittest.main()
