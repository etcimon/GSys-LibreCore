# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Real decoder/front/reply execution with native aperture and borrowed memory."""
import copy
import struct
import unittest

from native_test_wire import NativeWire
from vn_memory import ApertureState
from vn_memory_blobs import MemoryBlobs
from vn_native_execution import LinearExecution, MemoryWords, StreamFault


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.state = ApertureState(65536, 32768)
        self.blobs = MemoryBlobs(self.state)
        self.blobs.create(7, 4096)
        self.mapping = self.blobs.map(7, 0)
        self.execution = LinearExecution(self.state, self.blobs)
        self.wire = NativeWire()

    def boot(self, memory_type=1):
        payload = self.wire.boot(memory_type=memory_type)
        self.assertEqual(self.execution.execute(1, payload), len(payload))
        return self.execution.memory(1, self.wire.MEMORY)

    def test_word_view_observes_guest_writes_and_never_uses_stale_shadow(self):
        words = MemoryWords(self.state.aperture)
        self.state.aperture.write(0, b'abcd')
        self.assertEqual(words[0], int.from_bytes(b'abcd', 'little'))
        words[1] = 0xFEDCBA98
        self.assertEqual(self.state.aperture.read(4, 4), b'\x98\xba\xdc\xfe')
        self.assertEqual(words.pop(1), 0xFEDCBA98)
        self.assertEqual(words[1], 0)
        with self.assertRaises(ValueError):
            words[-1]

    def test_real_queries_allocate_and_publish_reply(self):
        owner = self.boot()
        self.assertIsNone(owner.base)
        self.assertEqual(owner.size, 8192)
        reply = self.blobs.read(self.mapping, 0, 24)
        self.assertEqual(struct.unpack_from('<II', reply), (0, 0))
        self.assertEqual(struct.unpack_from('<Q', reply, 16)[0], self.wire.INSTANCE)
        self.assertGreater(self.execution.contexts[1].reply[3], 24)

    def test_context_reply_and_object_namespaces_are_independent(self):
        first = self.boot()
        second_payload = self.wire.boot()
        self.execution.execute(2, second_payload)
        second = self.execution.memory(2, self.wire.MEMORY)
        self.assertIsNot(first.entry, second.entry)
        self.execution.execute(2, self.wire.command('vkSeekReplyCommandStreamMESA', position=0))
        self.assertNotEqual(self.execution.contexts[1].reply[3],
                            self.execution.contexts[2].reply[3])

    def test_malformed_stream_fault_is_sticky_until_context_retirement(self):
        with self.assertRaises(StreamFault):
            self.execution.execute(1, struct.pack('<II', 0xFFFFFFFF, 0))
        with self.assertRaises(StreamFault):
            self.execution.execute(1, self.wire.reply())
        self.execution.retire_context(1)
        self.execution.execute(1, self.wire.reply())
        self.assertFalse(self.execution.contexts[1].faulted)

    def test_reply_mapping_generation_is_checked_before_object_side_effect(self):
        self.execution.execute(1, self.wire.reply())
        self.blobs.unmap(7)
        self.blobs.map(7, 4096)
        with self.assertRaises(KeyError):
            self.execution.execute(1, self.wire.command(
                'vkCreateInstance', pInstance=self.wire.INSTANCE))
        frontend = self.execution.contexts[1].frontend
        self.assertNotIn(self.wire.INSTANCE, frontend.idmap)

    def test_byte_command_and_reply_bounds_fail_closed(self):
        self.execution.max_bytes = 8
        with self.assertRaises(StreamFault):
            self.execution.execute(1, self.wire.reply())
        self.execution.retire_context(1)
        self.execution.max_bytes = 65536
        self.execution.execute(1, self.wire.reply())
        self.execution.max_commands = 1
        seek = self.wire.command('vkSeekReplyCommandStreamMESA', position=0)
        with self.assertRaises(StreamFault):
            self.execution.execute(1, seek + seek)
        self.execution.retire_context(1)
        self.execution.max_commands = 256
        self.execution.execute(1, self.wire.reply(size=0))
        with self.assertRaises(StreamFault):
            self.execution.execute(1, self.wire.command(
                'vkCreateInstance', pInstance=self.wire.INSTANCE))
        self.assertTrue(self.execution.contexts[1].faulted)

    def test_nested_blob_stream_and_shared_work_budget(self):
        self.blobs.create(8, 4096)
        source = self.blobs.map(8, 4096)
        child = self.wire.command('vkCreateInstance', pInstance=self.wire.INSTANCE)
        self.blobs.write(source, 0, child)
        command = self.wire.command(
            'vkExecuteCommandStreamsMESA', streamCount=1,
            pStreams=[{'_ty': None, 'resourceId': 8, 'offset': 0, 'size': len(child)}],
            pReplyPositions=[0], dependencyCount=0, pDependencies=[], flags=0)
        self.execution.execute(1, self.wire.reply() + command)
        self.assertIn(self.wire.INSTANCE, self.execution.contexts[1].frontend.idmap)
        self.execution.max_commands = 1
        with self.assertRaises(StreamFault):
            self.execution.execute(1, command)

    def test_gpu_submission_is_refused_without_running_unbounded_work(self):
        self.boot()
        submit = self.wire.command('vkQueueSubmit', queue=0x400080001008,
                                   submitCount=0, pSubmits=[], fence=0)
        with self.assertRaisesRegex(StreamFault, 'work submission'):
            self.execution.execute(1, submit)

    def test_lazy_memory_rounding_mapping_and_unref_do_not_free_owner(self):
        owner = self.boot()
        self.blobs.create_alias(20, 8192, owner)
        self.assertEqual(owner.entry['pins'], 1)
        mapping = self.blobs.map(20, 8192)
        self.blobs.write(mapping, 0, b'borrowed')
        self.blobs.unref(20)
        self.assertEqual(owner.entry['pins'], 0)
        self.assertTrue(all(self.state.ap_pages[2:4]))
        self.assertEqual(self.state.aperture.read(8192, 8), b'borrowed')
        self.execution.execute(1, self.wire.free())
        self.assertFalse(any(self.state.ap_pages[2:4]))

    def test_eager_private_memory_alias_relocates_full_owner(self):
        owner = self.boot(memory_type=0)
        self.assertGreaterEqual(owner.base, self.state.guest_bytes)
        self.state.aperture.write(owner.base + 4096, b'tail')
        self.blobs.create_alias(20, 4096, owner)
        self.blobs.map(20, 8192)
        self.assertEqual(self.state.aperture.read(12288, 4), b'tail')
        self.assertTrue(all(self.state.ap_pages[2:4]))
        self.blobs.unmap(20)
        self.assertGreaterEqual(owner.base, self.state.guest_bytes)
        self.assertEqual(self.state.aperture.read(owner.base + 4096, 4), b'tail')

    def test_shared_aliases_cannot_silently_diverge(self):
        owner = self.boot()
        for resource in (20, 21):
            self.blobs.create_alias(resource, 8192, owner)
            self.blobs.map(resource, 8192)
        first, second = self.blobs.mapping(20), self.blobs.mapping(21)
        with self.assertRaises(ValueError):
            self.blobs.map(21, 16384)
        self.blobs.write(first, 0, b'share')
        self.assertEqual(self.blobs.read(second, 0, 5), b'share')
        with self.blobs.pin(first):
            with self.assertRaises(BlockingIOError):
                self.blobs.unmap(21)
        self.blobs.unmap(20)
        self.assertEqual(owner.base, 8192)
        self.assertIs(self.blobs.mapping(21), second)

    def test_context_teardown_retains_borrowed_backing_until_last_unref(self):
        owner = self.boot()
        self.blobs.create_alias(20, 8192, owner)
        mapping = self.blobs.map(20, 8192)
        self.blobs.write(mapping, 0, b'alive')
        self.execution.retire_context(1)
        self.assertEqual(self.blobs.read(mapping, 0, 5), b'alive')
        self.blobs.unref(20)
        self.assertFalse(any(self.state.ap_pages[2:4]))
        with self.assertRaises(KeyError):
            owner._live()

    def test_free_is_deferred_while_exported_alias_is_alive(self):
        owner = self.boot()
        self.blobs.create_alias(20, 8192, owner)
        mapping = self.blobs.map(20, 8192)
        self.execution.execute(1, self.wire.free())
        with self.assertRaises(KeyError):
            self.execution.memory(1, self.wire.MEMORY)
        self.blobs.write(mapping, 0, b'held')
        self.assertTrue(all(self.state.ap_pages[2:4]))
        self.blobs.unref(20)
        self.assertFalse(any(self.state.ap_pages[2:4]))
        with self.assertRaises(KeyError):
            owner._live()

    def test_forged_foreign_and_oversized_owners_are_rejected(self):
        owner = self.boot()
        with self.assertRaises(KeyError):
            self.blobs.create_alias(20, 8192, copy.copy(owner))
        with self.assertRaises(ValueError):
            self.blobs.create_alias(20, 8193, owner)
        foreign = MemoryBlobs(ApertureState(65536, 32768))
        with self.assertRaises(KeyError):
            foreign.create_alias(20, 8192, owner)
        self.assertNotIn(20, self.blobs.blobs)
        self.assertEqual(owner.refs, 0)
