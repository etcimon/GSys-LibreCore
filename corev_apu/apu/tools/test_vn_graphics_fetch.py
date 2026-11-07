# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded vertex/index fetch stage; record images only, no draw admission."""
import struct
import unittest

import test_vn_transfers as transfer_fixture
from vn_graphics_fetch import ATTR_STRIDE, Fetch, FetchVertex, FORMATS
from vn_transfer_executor import Transfer
from vn_vertex_operands import BufferOperand


def f32bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def record(records, index, word):
    return struct.unpack_from('<I', records, index * ATTR_STRIDE + word * 4)[0]


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.f = transfer_fixture.TransferTests()
        self.f.setUp()
        self.e, self.executor, self.context = self.f.engine, self.f.executor, self.f.context
        self.owner, self.state = self.f.owner, self.f.state
        self.aperture = self.state.aperture

    def span(self, offset=0, size=4096, index_bytes=0, owner=None):
        return BufferOperand(owner or self.owner, offset, size, index_bytes, (), lambda: None)

    def vertex(self, location, fmt, offset, stride=24, rate=0, span=None):
        return FetchVertex(location, fmt, offset, stride, rate, span or self.span())

    def drain(self):
        for _ in range(256):
            if not self.executor.active:
                return
            self.executor.poll()
        self.fail('bounded fetch cohort did not drain')

    def job(self, op):
        return self.executor.enqueue(self.context, [op])

    def write(self, offset, data):
        self.aperture.write(self.owner.base + offset, data)

    def records_of(self, job):
        """Keep the runtime alive past retirement and return its record image."""
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        return bytes(runtime.records)

    def test_rg32_positions_and_rgba32_colors_decode(self):
        # stride 24: pos RG32_SFLOAT @0 (loc0), color RGBA32_SFLOAT @8 (loc1)
        verts = bytearray()
        for i in range(3):
            verts += struct.pack('<2f', float(i), float(i + 10))
            verts += struct.pack('<4f', 1.0, 0.5, 0.25, 1.0)
        self.write(0, bytes(verts))
        fetch = Fetch(False, None, (
            self.vertex(0, 103, 0), self.vertex(1, 109, 8)),
            (3, 1, 0, 0, 0), None)
        job = self.job(fetch)
        image = self.records_of(job)
        stats = job.fetch_stats[0]
        self.assertEqual((stats['records'], stats['robust']), (3, 0))
        for i in range(3):
            base = i * ATTR_STRIDE
            # loc0 slot: x=i, y=i+10 as f32 bits; loc1 slot: RGBA color
            self.assertEqual(struct.unpack_from('<2I', image, base)[0:2],
                             (f32bits(float(i)), f32bits(float(i + 10))))
            self.assertEqual(struct.unpack_from('<4I', image, base + 16),
                             tuple(f32bits(v) for v in (1.0, 0.5, 0.25, 1.0)))
            # builtin slot 8: {VertexIndex, InstanceIndex, 0, 0}
            self.assertEqual(struct.unpack_from('<4I', image, base + 128),
                             (i, 0, 0, 0))
        self.assertEqual(self.owner.work_refs, 0)

    def test_indexed_fetch_reorders_and_applies_vertex_offset(self):
        # positions: vertex k has x=k; indices {2,0,1} + vertexOffset 10
        verts = bytearray()
        for i in range(13):
            verts += struct.pack('<2f', float(i), 0.0)
        self.write(0, bytes(verts))
        indices = struct.pack('<3I', 2, 0, 1)
        self.write(512, indices)
        fetch = Fetch(True, self.span(512, 64, index_bytes=4), (
            self.vertex(0, 103, 0, stride=8),),
            (3, 1, 0, 10, 5), None)
        job = self.job(fetch)
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.fetch_stats[0]['robust'], 0)

    def test_instance_rate_attribute_uses_instance_index(self):
        # per-instance color at stride 16 offset 0, fmt R32_SFLOAT (100)
        inst = struct.pack('<4f', 0.0, 1.0, 2.0, 3.0)
        self.write(0, inst)
        fetch = Fetch(False, None, (
            self.vertex(0, 100, 0, stride=16, rate=1),),
            (1, 4, 0, 0, 7), None)
        job = self.job(fetch)
        self.drain()
        self.assertEqual(job.fetch_stats[0]['records'], 4)
        self.assertEqual(job.fetch_stats[0]['robust'], 0)

    def test_unorm_uint_and_float16_component_decode(self):
        raw = bytes([255, 128]) + struct.pack('<H', 0x3C00) + bytes([7])
        self.write(0, raw)
        fetch = Fetch(False, None, (
            self.vertex(0, 9, 0, stride=8),    # R8_UNORM -> 1.0
            self.vertex(1, 13, 1, stride=8),   # R8_UINT -> 128
            self.vertex(2, 76, 2, stride=8),   # R16_SFLOAT 1.0 -> 1.0
            self.vertex(3, 14, 4, stride=8)),  # R8_SINT 7 -> 7
            (1, 1, 0, 0, 0), None)
        job = self.job(fetch)
        image = self.records_of(job)
        self.assertEqual(job.fetch_stats[0]['robust'], 0)
        self.assertEqual(struct.unpack_from('<I', image, 0)[0], f32bits(1.0))
        self.assertEqual(struct.unpack_from('<I', image, 16)[0], 128)
        self.assertEqual(struct.unpack_from('<I', image, 32)[0], f32bits(1.0))
        self.assertEqual(struct.unpack_from('<I', image, 48)[0], 7)
        for n, width, cls in FORMATS.values():
            self.assertIn(cls, ('unorm', 'snorm', 'uint', 'sint', 'f16', 'f32'))
            self.assertGreater(n * width, 0)

    def test_out_of_bounds_index_and_attributes_are_robust(self):
        self.write(0, struct.pack('<2f', 1.0, 2.0))
        self.write(64, struct.pack('<I', 0))
        # firstIndex=100 reads past the 4-byte index extent; vertexOffset
        # 5000 pushes the attribute gather past the vertex span.
        fetch = Fetch(True, self.span(64, 4, index_bytes=4), (
            self.vertex(0, 103, 0, stride=8),),
            (1, 1, 100, 5000, 0), None)
        job = self.job(fetch)
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.fetch_stats[0]
        self.assertEqual(stats['records'], 1)
        self.assertEqual(stats['robust'], 2)

    def test_indirect_arguments_are_read_after_prior_transfer(self):
        # DrawIndirectCommand {vertexCount=2, instanceCount=1,
        #                      firstVertex=0, firstInstance=0}
        self.write(0, struct.pack('<2f', 5.0, 6.0) * 2)
        args = struct.pack('<4I', 2, 1, 0, 0)
        self.write(256, args)
        ops = [Transfer('update', self.owner, 256, 16, data=args),
               Fetch(False, None, (self.vertex(0, 103, 0, stride=8),),
                     None, self.span(256, 16))]
        job = self.executor.enqueue(self.context, ops)
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.fetch_stats[1]['records'], 2)
        self.assertEqual(job.fetch_stats[1]['robust'], 0)

    def test_indexed_indirect_command_layout(self):
        # DrawIndexedIndirectCommand {indexCount,instanceCount,firstIndex,
        #                             vertexOffset,firstInstance}
        self.write(0, struct.pack('<2f', 1.0, 1.0) * 4)
        self.write(128, struct.pack('<I', 0))
        self.write(256, struct.pack('<5I', 2, 1, 0, 3, 0))
        ops = [Fetch(True, self.span(128, 8, index_bytes=4),
                     (self.vertex(0, 103, 0, stride=8),), None,
                     self.span(256, 20))]
        job = self.executor.enqueue(self.context, ops)
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.fetch_stats[0]['robust'], 0)

    def test_leases_held_until_retirement_and_context_cancel(self):
        self.write(0, struct.pack('<2f', 1.0, 2.0))
        fetch = Fetch(False, None, (self.vertex(0, 103, 0, stride=8),),
                      (1, 1, 0, 0, 0), None)
        job = self.job(fetch)
        self.assertEqual(self.owner.work_refs, 1)
        self.executor.cancel_context(self.context)
        self.assertEqual(job.state, 'cancelled')
        self.assertEqual(self.owner.work_refs, 0)

    def test_record_budget_and_argument_validation(self):
        with self.assertRaises(MemoryError):
            self.job(Fetch(False, None, (self.vertex(0, 103, 0, stride=8),),
                           (1025, 1, 0, 0, 0), None))
        with self.assertRaises(ValueError):
            self.job(Fetch(False, None, (self.vertex(0, 999, 0, stride=8),),
                           (1, 1, 0, 0, 0), None))
        with self.assertRaises(ValueError):
            # attribute tuple must be a tuple, not a list
            self.job(Fetch(False, None, [self.vertex(0, 103, 0, stride=8)],
                           (1, 1, 0, 0, 0), None))
        with self.assertRaises(ValueError):
            # both direct and indirect set
            self.job(Fetch(False, None, (self.vertex(0, 103, 0, stride=8),),
                           (1, 1, 0, 0, 0), self.span(0, 16)))

    def test_builtin_only_fetch_emits_index_records(self):
        # no attributes: records carry only the {VertexIndex,InstanceIndex} slot
        fetch = Fetch(False, None, (), (2, 3, 4, 0, 9), None)
        job = self.job(fetch)
        image = self.records_of(job)
        stats = job.fetch_stats[0]
        self.assertEqual((stats['records'], stats['robust']), (6, 0))
        for rec in range(6):
            instance, i = divmod(rec, 2)
            self.assertEqual(struct.unpack_from('<4I', image,
                             rec * ATTR_STRIDE + 128),
                             (4 + i, 9 + instance, 0, 0))

    def test_partial_budget_advances_and_resumes(self):
        verts = b''.join(struct.pack('<2f', float(i), 0.0) for i in range(64))
        self.write(0, verts)
        self.executor.poll_bytes = 300     # less than one full 64-record pass
        fetch = Fetch(False, None, (self.vertex(0, 103, 0, stride=8),),
                      (64, 1, 0, 0, 0), None)
        job = self.job(fetch)
        self.executor.poll()
        self.assertEqual(job.state, 'running')
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.fetch_stats[0]['records'], 64)


if __name__ == '__main__':
    unittest.main()
