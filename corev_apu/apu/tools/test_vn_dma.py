# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Authorization checks are independent of the Venus/shader generators."""
import unittest

from vn_dma import DmaPolicy, GuestDma
from vn_memory import ApertureState, SparseMemory


class GuestDmaTests(unittest.TestCase):
    def setUp(self):
        self.words = {0: 0x44332211, 1: 0x88776655}
        self.memory = SparseMemory(self.words, 64)
        self.policy = DmaPolicy(64)
        self.dma = GuestDma(self.memory, self.policy)

    def test_default_denies_nonempty_access(self):
        for dma in (self.dma, GuestDma(self.memory)):
            with self.assertRaises(PermissionError):
                dma.read(0, 1)
            with self.assertRaises(PermissionError):
                dma.write(0, b'x')
        self.assertEqual(self.dma.read(64, 0), b'')

    def test_readonly_and_revocation(self):
        self.policy.grant(1, 4)
        self.assertEqual(self.dma.read(1, 4), bytes.fromhex('22334455'))
        with self.assertRaises(PermissionError):
            self.dma.write(1, b'abcd')
        self.policy.revoke(1, 4)
        with self.assertRaises(PermissionError):
            self.dma.read(1, 1)

    def test_adjacent_grants_and_partial_words(self):
        self.policy.grant(0, 4, write=True)
        self.policy.grant(4, 4, write=True)
        self.dma.write(3, b'\xaa\xbb')
        self.assertEqual(self.dma.read(0, 8), bytes.fromhex('112233aabb667788'))

    def test_crossing_readonly_or_gap_has_no_partial_write(self):
        self.policy.grant(0, 4, write=True)
        self.policy.grant(4, 4)
        before = dict(self.words)
        with self.assertRaises(PermissionError):
            self.dma.write(2, b'abcdef')
        self.assertEqual(self.words, before)
        self.policy.revoke(4, 4)
        self.policy.grant(5, 3, write=True)
        with self.assertRaises(PermissionError):
            self.dma.write(2, b'abcdef')
        self.assertEqual(self.words, before)

    def test_write_only_does_not_allow_reads(self):
        self.policy.grant(0, 8, read=False, write=True)
        self.dma.write(1, b'x')
        with self.assertRaises(PermissionError):
            self.dma.read(0, 8)

    def test_grant_validation_is_atomic(self):
        self.policy.grant(4, 4)
        before = self.policy.regions
        for base, size in ((3, 2), (4, 4), (7, 2), (-1, 2), (63, 2), (0, 0)):
            with self.assertRaises(ValueError):
                self.policy.grant(base, size)
            self.assertEqual(self.policy.regions, before)
        with self.assertRaises(TypeError):
            self.policy.grant(16, 4, write='false')
        with self.assertRaises(TypeError):
            self.policy.check(4, 1, write='false')
        with self.assertRaises(KeyError):
            self.policy.revoke(4, 3)
        self.assertEqual(self.policy.regions, before)

    def test_u64_boundary_and_invalid_types(self):
        state = ApertureState(8192, 4096, dma_policy=DmaPolicy())
        state.dma.policy.grant((1 << 64) - 1, 1, write=True)
        state.dma_write((1 << 64) - 1, b'z')
        self.assertEqual(state.dma_read((1 << 64) - 1, 1), b'z')
        for address, size in (((1 << 64) - 1, 2), (-1, 1)):
            with self.assertRaises(ValueError):
                state.dma_read(address, size)
        with self.assertRaises(TypeError):
            state.dma_read(True, 1)

    def test_aperture_stream_fetch_uses_policy(self):
        state = ApertureState(8192, 4096, dma_policy=DmaPolicy())
        state.gmem[0] = 0x44332211  # trusted preload, not a guest DMA write
        with self.assertRaises(PermissionError):
            state.gmem_slice(0, 4)
        state.dma.policy.grant(0, 4)
        self.assertEqual(state.gmem_slice(0, 4), [0x44332211])
        with self.assertRaises(ValueError):
            state.gmem_slice(1, 3)
        legacy = ApertureState(8192, 4096)
        legacy.dma_write(1, b'abcd')
        self.assertEqual(legacy.dma_read(1, 4), b'abcd')


if __name__ == '__main__':
    unittest.main()
