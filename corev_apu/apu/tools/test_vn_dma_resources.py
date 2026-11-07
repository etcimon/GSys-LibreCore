# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Owned-resource DMA lifecycle checks; no Venus/RTL execution."""
import unittest

from vn_dma import DmaRegion
from vn_dma_resources import DmaLease, ResourceDma
from vn_memory import SparseMemory


class ResourceDmaTests(unittest.TestCase):
    def setUp(self):
        self.words = {}
        self.resources = ResourceDma(SparseMemory(self.words, 64))

    def region(self, base, size=4, write=True):
        return DmaRegion(base, size, True, write)

    def test_resource_scopes_and_atomic_writes(self):
        first = self.resources.register(1, 1, [self.region(0)])
        second = self.resources.register(2, 1, [self.region(4)])
        self.resources.write(first, 0, b'abcd')
        self.resources.write(second, 4, b'efgh')
        with self.assertRaises(PermissionError):
            self.resources.read(first, 4, 4)
        before = dict(self.words)
        with self.assertRaises(PermissionError):
            self.resources.write(first, 2, b'XXXX')
        self.assertEqual(self.words, before)

    def test_revocation_resource_reuse_and_forged_token(self):
        first = self.resources.register(1, 2, [self.region(0)])
        self.resources.revoke(first)
        second = self.resources.register(1, 2, [self.region(0)])
        self.assertGreater(second.generation, first.generation)
        for stale in (first, DmaLease(second.context, second.resource,
                                      second.generation, second.regions)):
            with self.assertRaises(KeyError):
                self.resources.read(stale, 0, 0)
        self.assertEqual(self.resources.read(second, 0, 4), b'\0' * 4)

    def test_batch_overlap_rolls_back_only_new_grants(self):
        existing = self.resources.register(2, 1, [self.region(8)])
        before = self.resources.policy.regions
        with self.assertRaises(ValueError):
            self.resources.register(1, 1, [self.region(0), self.region(8)])
        self.assertEqual(self.resources.policy.regions, before)
        self.assertEqual(self.resources.read(existing, 8, 4), b'\0' * 4)
        # Failed registration did not claim the resource key.
        self.resources.register(1, 1, [self.region(0)])

    def test_context_teardown_leaves_other_context_live(self):
        first = self.resources.register(1, 1, [self.region(0)])
        self.resources.register(1, 2, [self.region(4)])
        other = self.resources.register(2, 1, [self.region(8)])
        self.assertEqual(self.resources.revoke_context(1), 2)
        self.assertEqual(self.resources.revoke_context(1), 0)
        with self.assertRaises(KeyError):
            self.resources.write(first, 0, b'a')
        self.assertEqual(self.resources.read(other, 8, 4), b'\0' * 4)

    def test_readonly_and_adjacent_owned_grants(self):
        lease = self.resources.register(0, 1, [self.region(0), self.region(4)])
        self.resources.write(lease, 2, b'abcd')
        self.assertEqual(self.resources.read(lease, 2, 4), b'abcd')
        readonly = self.resources.register(0, 2, [self.region(16, write=False)])
        with self.assertRaises(PermissionError):
            self.resources.write(readonly, 16, b'a')

    def test_external_policy_mutation_fails_closed(self):
        first = self.resources.register(1, 1, [self.region(0)])
        second = self.resources.register(1, 2, [self.region(4)])
        self.resources.policy.revoke(4, 4)
        self.resources.policy.grant(4, 4, write=True)
        with self.assertRaises(KeyError):
            self.resources.revoke_context(1)
        self.assertEqual(self.resources.read(first, 0, 4), b'\0' * 4)
        with self.assertRaises(KeyError):
            self.resources.read(second, 4, 4)

    def test_bad_registration_does_not_mutate_policy(self):
        for context, resource in ((-1, 1), (1, 0), (True, 1), (1, 1 << 32)):
            with self.assertRaises(ValueError):
                self.resources.register(context, resource, [self.region(0)])
        with self.assertRaises(TypeError):
            self.resources.register(1, 1, [self.region(0), 'bad'])
        with self.assertRaises(ValueError):
            self.resources.register(1, 1, [])
        self.assertEqual(self.resources.policy.regions, ())

    def test_interrupted_registration_rolls_back(self):
        def interrupted():
            yield self.region(0)
            raise KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            self.resources.register(1, 1, interrupted())
        self.assertEqual(self.resources.policy.regions, ())


if __name__ == '__main__':
    unittest.main()
