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

    def test_mprv_zero_images_match_head_for_every_privilege(self):
        # Verified byte-identical against `git show HEAD:` generated images.
        expected = {
            0: ("2f3cb8aea1bed8725a93252ef32199dec13f6f3ce9f9b2cac22de23384b6aace",
                "45ceb22379e7d2919ee9b09dd7b5f0ae3d2a5a3a3e12b071a4800e9cae071d22"),
            1: ("755ca9cedef7b2af561bcf5b60a0d8175cf24f294045a9fddda36e08db475074",
                "4fe49b4a880697d6b66f4f1e25c5c7cb7520cc00f4274ce8cdaabade05f5a587"),
            3: ("b725b9899f46cc4e219da7b271fa4e89a0cb958f10a3226d480b6bde49e67b52",
                "fc1e97cf711201b745acaf121f54cd16375fd7d7957d851e7ec6681659ffec30"),
        }
        for privilege, (normal_sha, debug_sha) in expected.items():
            with self.subTest(privilege=privilege):
                normal, debug = build_debug_program(privilege, 0)
                self.assertEqual(hashlib.sha256(normal).hexdigest(), normal_sha)
                self.assertEqual(hashlib.sha256(debug).hexdigest(), debug_sha)

    def test_mprv_variants_emit_mstatus_and_debugger_dcsr_write(self):
        normal, debug = ([int(w, 16) for w in image.splitlines()]
                         for image in build_debug_program(3, 1))
        self.assertIn(0x20e37, normal)   # LUI x28, 0x20 -> 0x20000
        self.assertIn(0xe0e13, normal)   # ADDI x28, x28, 0
        mstatus_writes = [w for w in normal
                          if w & 127 == 0x73 and (w >> 20) == 0x300]
        self.assertEqual(len(mstatus_writes), 1)
        self.assertNotIn(0x7b086073, debug)  # CSRRSI DCSR.mprven is mprv=2 only
        _, debug2 = ([int(w, 16) for w in image.splitlines()]
                     for image in build_debug_program(3, 2))
        self.assertIn(0x7b086073, debug2)    # CSRRSI dcsr, x16 (mprven=bit4)
        self.assertEqual(hashlib.sha256(
            build_debug_program(3, 1)[1]).hexdigest(),
            hashlib.sha256(build_debug_program(3, 0)[1]).hexdigest())

    def test_mprv_validation(self):
        for privilege, mprv in ((3, 3), (3, -1), (0, 1), (1, 2), (2, 0)):
            with self.subTest(privilege=privilege, mprv=mprv):
                with self.assertRaises(ValueError):
                    build_debug_program(privilege, mprv)

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
