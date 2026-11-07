# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Seven-write firmware encoding checks, not CPU qualification."""
import unittest

from g6lc_cpu_debug_program import build_debug_program
from g6lc_cpu_debug_return_program import build_return_program
from test_g6lc_cpu_origin_program import branch_offset


class ReturnProgramTests(unittest.TestCase):
    def test_normal_images_unchanged_for_all_privileges(self):
        for privilege in (0, 1, 3):
            self.assertEqual(build_return_program(privilege)[0], build_debug_program(privilege)[0])

    def test_added_debug_store_follows_last_load_and_precedes_dret(self):
        for privilege in (0, 1, 3):
            _, image = build_return_program(privilege)
            words = [int(w, 16) for w in image.splitlines()]
            i = words.index(0x7b151073)
            store = words[i - 1]
            self.assertEqual(store & 127, 0x23)
            self.assertEqual(((store >> 25) << 5) | ((store >> 7) & 31), 28)
            self.assertEqual((store >> 15) & 31, 5)
            self.assertEqual((store >> 20) & 31, 6)
            self.assertEqual(words[i - 2], 0x0ff0000f)
            self.assertEqual(words[i + 1], 0x7b200073)
            self.assertEqual(sum(w & 127 == 0x23 for w in words), 6)  # Four debug + two failure markers.
            self.assertEqual(len(words), 1024)
            for j, word in enumerate(words):
                if word & 127 == 0x63:
                    self.assertEqual(j * 4 + branch_offset(word), 0x300)

    def test_reserved_privilege_rejected(self):
        with self.assertRaises(ValueError):
            build_return_program(2)
