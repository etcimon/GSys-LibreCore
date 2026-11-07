# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import itertools
import unittest

from vn_layout import descriptor_bindings, descriptor_rows, descriptor_row_words


def staged(bindings):
    return [word for binding, kind, count in bindings
            for word in (binding, kind, count, 0x20, 0)]


class DescriptorLayoutTests(unittest.TestCase):
    def test_immutable_array_boundaries(self):
        payload = [7, 1, 2, 0x20, 2, 0x1234, 0x4000, 0x5678, 0x4000]
        bindings = descriptor_bindings(payload, 1)
        self.assertEqual(bindings[0][4], [0x400000001234, 0x400000005678])
        row = descriptor_rows(payload, 1)[0]
        self.assertTrue(descriptor_row_words(row, True)[1] & 0x400)
        self.assertIsNone(descriptor_bindings(payload[:-1], 1))
        malformed = list(payload)
        malformed[2] = 1
        self.assertIsNone(descriptor_bindings(malformed, 1))

    def test_permutations_have_same_offsets_and_words(self):
        bindings = [(9, 8, 2), (1, 9, 1), (5, 6, 3)]
        expected = [(1, 9, 1, 0, 1, 0),
                    (5, 6, 3, 1, 0, 1),
                    (9, 8, 2, 4, 1, 1)]
        for perm in itertools.permutations(bindings):
            rows = descriptor_rows(staged(perm), 3)
            self.assertEqual(rows, expected)
            self.assertEqual([descriptor_row_words(r) for r in rows],
                             [descriptor_row_words(r) for r in expected])

    def test_high_binding_bits_are_not_offset_bits(self):
        rows = descriptor_rows(staged([(257, 8, 1), (1, 9, 1)]), 2)
        self.assertEqual([r[0] for r in rows], [1, 257])
        self.assertEqual(descriptor_row_words(rows[1]), (0x01080001, 0x01001801))

    def test_limits_and_duplicates(self):
        for bindings in ([(1, 8, 17)], [(1, 6, 2048)],
                         [(1, 6, 1), (1, 7, 1)]):
            self.assertIsNone(descriptor_rows(staged(bindings), len(bindings)))
        self.assertIsNone(descriptor_rows([], 17))
        self.assertEqual(descriptor_rows([], 0), [])

    def test_maximum_binding_and_dynamic_boundary(self):
        rows = descriptor_rows(staged([(65535, 8, 8), (0, 9, 8)]), 2)
        self.assertEqual(rows[-1], (65535, 8, 8, 8, 1, 8))
        self.assertEqual(descriptor_row_words(rows[-1]), (0xFF080008, 0xFF008808))
