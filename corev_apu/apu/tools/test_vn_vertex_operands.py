# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Recorded buffer generations/bindings remain guarded without admitting drawing."""
import unittest
from unittest.mock import patch

import test_vn_replay as replay_fixture
from vn_native_execution import StreamFault
from vn_vertex_operands import operand


class VertexOperandTests(unittest.TestCase):
    def setUp(self):
        self.f = replay_fixture.ReplayTests()
        self.f.native_profile = True
        self.f.setUp()
        self.e, self.w = self.f.engine, self.f.wire
        self.buffer()
        self.f.begin()

    def buffer(self, usage=0xC3):
        self.f.command('vkDestroyBuffer', device=self.w.DEVICE, buffer=self.f.BUFFER)
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.f.BUFFER,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=4096, usage=usage, sharingMode=0,
                queueFamilyIndexCount=0, pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.f.BUFFER,
                       memory=self.w.MEMORY, memoryOffset=0)

    def snapshot(self):
        return self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs'][-1]['native_graphics_buffers']

    def vertex(self, *, first=3, offsets=(16,), count=None):
        self.f.command('vkCmdBindVertexBuffers', commandBuffer=self.f.CB, firstBinding=first,
            bindingCount=len(offsets) if count is None else count,
            pBuffers=[self.f.BUFFER] * len(offsets), pOffsets=list(offsets))
        return self.snapshot()

    def index(self, *, offset=16, index_type=0):
        self.f.command('vkCmdBindIndexBuffer', commandBuffer=self.f.CB, buffer=self.f.BUFFER,
                       offset=offset, indexType=index_type)
        return self.snapshot().sources[0]

    def test_vertex_capture_and_owned_span_do_not_acquire_leases(self):
        snapshot = self.vertex()
        self.assertEqual(snapshot.first, 3)
        source, = snapshot.sources
        span = operand(self.e, 1, source)
        self.assertIs(span.owner, self.f.owner)
        self.assertEqual((span.offset, span.size, span.index_bytes), (16, 4080, 0))
        self.assertEqual(len(span.references), 3)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(any(e['pins'] for e in self.f.front.ent if e))

    def test_multiple_bindings_keep_independent_offsets(self):
        snapshot = self.vertex(first=14, offsets=(16, 64))
        self.assertEqual([s.offset for s in snapshot.sources], [16, 64])
        self.assertEqual([operand(self.e, 1, s, 4).offset for s in snapshot.sources], [16, 64])

    def test_uint16_and_uint32_index_spans_are_typed(self):
        source = self.index()
        self.assertEqual(operand(self.e, 1, source, 6).index_bytes, 2)
        source = self.index(index_type=1)
        self.assertEqual(operand(self.e, 1, source, 12).index_bytes, 4)
        with self.assertRaises(ValueError):
            operand(self.e, 1, source, 6)

    def test_buffer_wire_id_reuse_cannot_redirect_source(self):
        source = self.vertex().sources[0]
        self.buffer()
        with self.assertRaises(KeyError):
            operand(self.e, 1, source)

    def test_memory_rebinding_cannot_redirect_source(self):
        source = self.vertex().sources[0]
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.f.BUFFER,
                       memory=self.w.MEMORY, memoryOffset=64)
        with self.assertRaises(KeyError):
            operand(self.e, 1, source)

    def test_validator_rechecks_late_usage_mutation(self):
        span = operand(self.e, 1, self.vertex().sources[0])
        self.f.entry(self.f.BUFFER)['native_usage'] = 3
        with self.assertRaises(KeyError):
            span.validate()

    def test_logical_range_and_deferred_free_refuse_new_work(self):
        source = self.vertex().sources[0]
        for length in (0, -1, 4081):
            with self.assertRaises(ValueError):
                operand(self.e, 1, source, length)
        with patch.object(self.f.owner, 'deferred_free', object()):
            with self.assertRaises(KeyError):
                operand(self.e, 1, source)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_vertex_count_and_first_binding_cannot_truncate(self):
        for values in (dict(first=16), dict(first=65536), dict(first=15, offsets=(0, 0)),
                       dict(offsets=()), dict(count=2)):
            with self.subTest(values=values):
                case = VertexOperandTests()
                case.setUp()
                with self.assertRaisesRegex(StreamFault, 'vertex binding count/payload'):
                    case.vertex(**values)
                self.assertEqual(case.f.owner.work_refs, 0)

    def test_index_alignment_type_and_u64_offset_are_not_truncated(self):
        for values in (dict(offset=1), dict(offset=4096), dict(offset=0x100000004),
                       dict(index_type=1000265000)):
            with self.subTest(values=values):
                case = VertexOperandTests()
                case.setUp()
                with self.assertRaises(StreamFault):
                    case.index(**values)
                self.assertEqual(case.f.owner.work_refs, 0)

    def test_buffer_usage_is_checked_before_recording(self):
        self.buffer(usage=3)
        with self.assertRaisesRegex(StreamFault, 'usage/device'):
            self.vertex()

    def test_retired_context_invalidates_operand_guard(self):
        span = operand(self.e, 1, self.vertex().sources[0])
        self.f.context.retired = True
        with self.assertRaises(KeyError):
            span.validate()

    def test_bindings_admit_state_only_replay_without_work(self):
        self.vertex()
        self.f.end()
        job = self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.assertEqual(job.size, 0)
        self.assertEqual(job.operations, ())
        self.assertTrue(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
