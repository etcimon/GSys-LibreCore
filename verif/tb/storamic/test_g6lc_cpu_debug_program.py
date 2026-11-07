# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Debug firmware structure checks, not CPU debug qualification."""
import hashlib
import unittest

from g6lc_cpu_debug_program import build_debug_program
from test_g6lc_cpu_origin_program import branch_offset


class DebugProgramTests(unittest.TestCase):
    def setUp(self):
        self.normal, self.debug = ([int(w, 16) for w in image.splitlines()]
                                   for image in build_debug_program())

    def test_image_sizes(self):
        self.assertEqual((len(self.normal), len(self.debug)), (1024, 1024))

    def test_configured_halt_and_exception_entries(self):
        self.assertEqual(self.debug[0x800 // 4], 0x0400006f)
        self.assertEqual(self.debug[0x808 // 4], 0x500002b7)
        self.assertEqual(self.debug[0x300 // 4], 0x500002b7)

    def test_all_readback_branches_target_failure_entry(self):
        counts = []
        for image in (self.normal, self.debug):
            branches = 0
            for index, word in enumerate(image):
                if word & 127 == 0x63:
                    self.assertEqual(index * 4 + branch_offset(word), 0x300)
                    branches += 1
            counts.append(branches)
        self.assertEqual(counts, [2, 3])

    def test_debug_reads_and_real_resume_csr_write(self):
        accesses = [word for word in self.debug if word & 127 == 0x73]
        self.assertEqual([(word >> 20, (word >> 12) & 7) for word in accesses],
                         [(0x7b0, 2), (0x7b1, 2), (0x7b1, 1), (0x7b2, 0)])
        self.assertEqual((accesses[-2] >> 15) & 31, 10)
        self.assertEqual(accesses[-1], 0x7b200073)

    def test_no_debug_csr_access_or_resume_branch_in_boot(self):
        self.assertEqual(self.normal[8], 0x0000006f)
        for word in self.normal:
            if word & 127 == 0x73:
                self.assertNotIn(word >> 20, (0x7b0, 0x7b1, 0x7b2))

    def test_store_order_and_failure_markers(self):
        offsets = []
        for image in (self.normal, self.debug):
            writes = []
            for word in image:
                if word & 127 == 0x23:
                    writes.append(((word >> 25) << 5) | ((word >> 7) & 31))
            offsets.append(writes)
        self.assertEqual(offsets, [[0, 32, 40, 36], [36, 36, 8, 24, 16]])

    def test_original_default_images_remain_byte_identical(self):
        normal, debug = build_debug_program()
        self.assertEqual(hashlib.sha256(normal).hexdigest(),
                         "b725b9899f46cc4e219da7b271fa4e89a0cb958f10a3226d480b6bde49e67b52")
        self.assertEqual(hashlib.sha256(debug).hexdigest(),
                         "fc1e97cf711201b745acaf121f54cd16375fd7d7957d851e7ec6681659ffec30")

    def test_invalid_privilege_rejected(self):
        with self.assertRaisesRegex(ValueError, "privilege"):
            build_debug_program(2)

    def test_lower_privilege_boot_uses_actual_mret_and_pmp(self):
        for privilege in (0, 1):
            with self.subTest(privilege=privilege):
                normal, _ = ([int(w, 16) for w in image.splitlines()]
                             for image in build_debug_program(privilege))
                registers, csrs = [0] * 32, {}
                for index, word in enumerate(normal[:64]):
                    opcode, rd, rs = word & 127, (word >> 7) & 31, (word >> 15) & 31
                    if word == 0x30200073:
                        break
                    if opcode == 0x17:
                        registers[rd] = 0x80000000 + index * 4 + (word & 0xfffff000)
                    elif opcode == 0x37:
                        registers[rd] = word & 0xfffff000
                    elif opcode == 0x13:
                        immediate = (word >> 20) - (0x1000 if word >> 31 else 0)
                        if (word >> 12) & 7 == 0:
                            registers[rd] = (registers[rs] + immediate) & ((1 << 64) - 1)
                        else:
                            self.assertEqual((word >> 12) & 7, 5)
                            registers[rd] = registers[rs] >> (word >> 20)
                    elif opcode == 0x73:
                        self.assertEqual((word >> 12) & 7, 1)
                        csrs[word >> 20] = registers[rs]
                    else:
                        self.fail(f"unexpected boot instruction {word:x}")
                else:
                    self.fail("no MRET before resume code")
                self.assertEqual(csrs[0x341], 0x80000180)
                self.assertEqual(csrs[0x300], privilege << 11)
                self.assertEqual(csrs[0x3b0], ((1 << 64) - 1) >> 2)
                self.assertEqual(csrs[0x3a0], 0x1f)
                self.assertEqual(registers[5], 0x50000000)
                self.assertEqual(registers[10], 0x80000100)
                self.assertEqual(normal[0x180 // 4 + 1] & 127, 0x23)

    def test_saved_privilege_and_failure_branch_for_all_contexts(self):
        for privilege in (0, 1, 3):
            normal, debug = ([int(w, 16) for w in image.splitlines()]
                             for image in build_debug_program(privilege))
            expected = ((0xc0 | privilege) << 20) | (6 << 7) | 0x13
            self.assertIn(expected, debug)
            for code in (normal, debug):
                for index, word in enumerate(code):
                    if word & 127 == 0x63:
                        self.assertEqual(index * 4 + branch_offset(word), 0x300)


if __name__ == "__main__":
    unittest.main()
