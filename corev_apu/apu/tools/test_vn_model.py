#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Device-state checks independent of Venus encoding and shader tooling."""
import random
import unittest

from vn_model import ObjectTable, PAY_CHUNK, PayloadMemory


class ObjectTests(unittest.TestCase):
    def test_handle_generation_and_duplicate(self):
        table = ObjectTable(2)
        status, handle, slot = table.alloc(0x400000001000, 1, 0)
        self.assertEqual((status, handle, slot), ('OK', 0x10000, 0))
        self.assertEqual(table.alloc(0x400000001000, 1, 0)[0], 'DUP')
        self.assertEqual(table.resolve(handle, 2)[0], 'KIND')
        self.assertEqual(table.retire(handle, 1), ('OK', 0))
        self.assertEqual(table.resolve(handle, 1)[0], 'GEN')
        self.assertEqual(table.alloc(0x400000002000, 1, 0),
                         ('OK', 0x20000, 0))

    def test_parent_and_pin_lifetimes(self):
        table = ObjectTable()
        _, parent, _ = table.alloc(0x400000001000, 1, 0)
        _, child, slot = table.alloc(0x400000002000, 2, parent)
        self.assertEqual(table.retire(parent, 1)[0], 'BUSY_CHILDREN')
        table.ent[slot]['pins'] = 1
        self.assertEqual(table.retire(child, 2)[0], 'PINNED')
        table.ent[slot]['pins'] = 0
        self.assertEqual(table.retire(child, 2)[0], 'OK')
        self.assertEqual(table.retire(parent, 1)[0], 'OK')
        self.assertEqual(table.live_cnt, 0)

    def test_zombie_resolution_and_generation_wrap(self):
        table = ObjectTable(1)
        table.gens[0] = 0xFFFF
        _, handle, slot = table.alloc(0x400000001000, 1, 0)
        self.assertEqual(handle, 0x10000)
        table.ent[slot]['zomb'] = 1
        self.assertEqual(table.resolve(handle, 1)[0], 'GEN')
        self.assertEqual(table.resolve(0x400000001000, 1)[0], 'MISS')
        self.assertEqual(table.resolve(handle, 1, allow_zomb=True)[0], 'OK')

    def test_retire_kids_reuses_oldest_first_after_newest_first_walk(self):
        table = ObjectTable(3)
        table.ctx = 7
        _, parent, _ = table.alloc(0x400000001000, 1, 0)
        table.alloc(0x400000002000, 2, parent)
        table.alloc(0x400000003000, 2, parent)
        self.assertEqual(table.alloc(0x400000004000, 2, parent)[0], 'FULL')
        self.assertEqual(table.retire_kids(parent, 0), ('OK', 2))
        self.assertEqual(table.ctxorder[7], [0])
        self.assertEqual(table.alloc(0x400000004000, 2, parent)[2], 1)

    def test_masked_state_and_aux_updates(self):
        table = ObjectTable()
        _, handle, slot = table.alloc(0x400000001000, 1, 0)
        table.setstate(handle, 0xFFFF, 0x1234)
        table.setstate(handle, 0xFF, 0xAB)
        table.setaux(handle, 0xFFFFFFFF, 0x87654321)
        table.setauxhi(handle, 0x12345678)
        self.assertEqual(table.ent[slot]['state'], 0x12AB)
        self.assertEqual(table.ent[slot]['aux'], 0x1234567887654321)
        table.reset_objects()
        self.assertEqual((table.live_cnt, table.ctx, table.idmap), (0, 0, {}))


class PayloadTests(unittest.TestCase):
    def test_reset_and_zero_allocation(self):
        mem = PayloadMemory(8192)
        self.assertEqual(mem.pay_alloc(0), 0)
        self.assertEqual((mem.pay_bits, mem.pay_cur, mem.pay), (1, 0, {}))
        mem.pay_alloc(100)
        mem.pay[64] = 0x1234
        mem.reset_payload()
        self.assertEqual((mem.pay_bits, mem.pay_cur, mem.pay), (1, 0, {}))

    def test_full_and_free_preserves_cursor(self):
        mem = PayloadMemory(8192)
        self.assertEqual(mem.pay_alloc(127 * PAY_CHUNK), PAY_CHUNK)
        self.assertIsNone(mem.pay_alloc(1))
        cursor = mem.pay_cur
        mem.pay_free(PAY_CHUNK, 127 * PAY_CHUNK)
        self.assertEqual((mem.pay_bits, mem.pay_cur), (1, cursor))
        self.assertIsNone(mem.pay_alloc(8193))

    def test_next_fit_not_global_first_fit(self):
        mem = PayloadMemory(8192)
        self.assertEqual(mem.pay_alloc(63 * PAY_CHUNK), PAY_CHUNK)
        self.assertEqual(mem.pay_cur, 1)
        mem.pay_free(PAY_CHUNK, 63 * PAY_CHUNK)
        self.assertEqual(mem.pay_alloc(PAY_CHUNK), 64 * PAY_CHUNK)

    def test_aux_extent_free_leaves_sparse_content(self):
        mem = PayloadMemory(8192)
        base = mem.pay_alloc(65)
        mem.pay[base] = 42
        mem.pay_free_of({'aux': ((base // PAY_CHUNK) << 48) | (65 << 32)})
        self.assertEqual(mem.pay_bits, 1)
        self.assertEqual(mem.pay[base], 42)

    def test_randomized_against_scalar_bitmap_oracle(self):
        # Two and four bitmap words cover cross-word runs, exhaustion,
        # fragmentation, cursor wrap, and reuse without a shared search loop.
        for chunks in (128, 256):
            rng = random.Random(chunks)
            mem = PayloadMemory(chunks * PAY_CHUNK)
            occupied = {0}
            live = []
            cursor = 0
            for _ in range(500):
                if live and rng.randrange(3) == 0:
                    base, count = live.pop(rng.randrange(len(live)))
                    mem.pay_free(base * PAY_CHUNK, count * PAY_CHUNK)
                    occupied.difference_update(range(base, base + count))
                else:
                    count = rng.randrange(1, 100)
                    expected = None
                    start = cursor * 64
                    for lo, hi in ((start, chunks), (0, start)):
                        for base in range(lo, hi - count + 1):
                            if occupied.isdisjoint(range(base, base + count)):
                                expected = base
                                break
                        if expected is not None:
                            break
                    actual = mem.pay_alloc(count * PAY_CHUNK)
                    self.assertEqual(actual, None if expected is None
                                     else expected * PAY_CHUNK)
                    if expected is not None:
                        live.append((expected, count))
                        occupied.update(range(expected, expected + count))
                        cursor = ((expected + count) // 64) % (chunks // 64)
                self.assertEqual(mem.pay_cur, cursor)
                self.assertEqual(mem.pay_bits, sum(1 << i for i in occupied))


if __name__ == '__main__':
    unittest.main()
