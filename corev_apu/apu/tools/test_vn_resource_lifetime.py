# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Global backing versus context access; host-only, no RTL qualification."""
from dataclasses import replace
import unittest

from vn_dma import DmaRegion
from vn_memory import ApertureState
from vn_resource_lifetime import ResourceState


class ResourceLifetimeTests(unittest.TestCase):
    def setUp(self):
        self.memory = ApertureState(16384, 8192)
        self.state = ResourceState(self.memory.guest_ram)
        self.context = self.state.create_context(1)
        self.backing = self.state.register_resource(7, [DmaRegion(0, 8, True, True)])
        self.access = self.state.attach(self.context, self.backing, write=True)

    def test_shared_backing_survives_context_destroy(self):
        other = self.state.create_context(2)
        shared = self.state.attach(other, self.backing)
        self.state.write(self.access, 0, b'abcd')
        self.assertEqual(self.state.destroy_context(self.context), 1)
        with self.assertRaises(KeyError):
            self.state.read(self.access, 0, 4)
        self.assertEqual(self.state.read(shared, 0, 4), b'abcd')
        self.assertEqual(self.memory.dma_read(0, 4), b'abcd')

    def test_last_detach_keeps_backing_until_unref(self):
        self.state.detach(self.access)
        replacement = self.state.attach(self.context, self.backing)
        with self.assertRaises(KeyError):
            self.state.read(self.access, 0, 0)
        self.assertEqual(self.state.read(replacement, 0, 1), b'\0')
        self.state.unref_resource(self.backing)
        with self.assertRaises(KeyError):
            self.state.read(replacement, 0, 1)

    def test_unref_invalidates_all_contexts_and_stale_resource(self):
        other = self.state.create_context(2)
        shared = self.state.attach(other, self.backing)
        self.state.unref_resource(self.backing)
        new = self.state.register_resource(7, [DmaRegion(0, 8, True, True)])
        for old in (self.access, shared):
            with self.assertRaises(KeyError):
                self.state.read(old, 0, 1)
        with self.assertRaises(KeyError):
            self.state.unref_resource(self.backing)
        fresh = self.state.attach(other, new)
        self.assertEqual(self.state.read(fresh, 0, 1), b'\0')

    def test_reused_context_and_forged_tokens_fail(self):
        self.state.destroy_context(self.context)
        current = self.state.create_context(1)
        with self.assertRaises(KeyError):
            self.state.attach(self.context, self.backing)
        with self.assertRaises(KeyError):
            self.state.attach(replace(current), self.backing)
        with self.assertRaises(KeyError):
            self.state.attach(current, replace(self.backing))
        fresh = self.state.attach(current, self.backing)
        with self.assertRaises(KeyError):
            self.state.read(replace(fresh), 0, 1)

    def test_attachment_permissions_do_not_expand_backing(self):
        readonly = self.state.attach(self.state.create_context(2), self.backing)
        with self.assertRaises(PermissionError):
            self.state.write(readonly, 0, b'x')
        writeonly = self.state.attach(self.state.create_context(3), self.backing,
                                      read=False, write=True)
        with self.assertRaises(PermissionError):
            self.state.read(writeonly, 0, 1)
        restricted = self.state.register_resource(8, [DmaRegion(16, 4, True, False)])
        extra = self.state.attach(self.context, restricted, write=True)
        with self.assertRaises(PermissionError):
            self.state.write(extra, 16, b'x')
        self.assertEqual(self.memory.guest_ram.read(16, 1), b'\0')

    def test_cross_resource_write_is_atomic(self):
        self.state.register_resource(8, [DmaRegion(8, 4, True, True)])
        before = dict(self.memory.gmem)
        with self.assertRaises(PermissionError):
            self.state.write(self.access, 4, b'abcdefgh')
        self.assertEqual(self.memory.gmem, before)

    def test_invalid_registration_rolls_back_without_losing_attachment(self):
        with self.assertRaises(ValueError):
            self.state.register_resource(8, [DmaRegion(16, 4, True, True),
                                              DmaRegion(4, 4, True, True)])
        fresh = self.state.register_resource(8, [DmaRegion(16, 4, True, True)])
        self.assertEqual(fresh.resource, 8)
        self.assertEqual(self.state.read(self.access, 0, 1), b'\0')

    def test_invalid_and_duplicate_context_or_attachment(self):
        for value in (0, -1, True, 1 << 32):
            with self.assertRaises(ValueError):
                self.state.create_context(value)
        with self.assertRaises(KeyError):
            self.state.create_context(1)
        with self.assertRaises(KeyError):
            self.state.attach(self.context, self.backing)
        other = self.state.create_context(2)
        for rights in ({'read': False, 'write': False}, {'write': 1}):
            with self.assertRaises(ValueError):
                self.state.attach(other, self.backing, **rights)


if __name__ == '__main__':
    unittest.main()
