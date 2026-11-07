# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Vertex-shader stage over fetch records; no raster/FS/descriptor admission."""
import struct
import unittest

import test_vn_transfers as transfer_fixture
from vn_compute import ShaderBinding
from vn_graphics_fetch import ATTR_STRIDE, Fetch
from vn_graphics_shade import Shade
from vn_transfer_executor import Transfer
from vn_vertex_operands import BufferOperand


def f32bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def vs_program(desc=False, ubo=False):
    """Hand-assembled equivalent of corpus/vs_passthru.vert:
    pos=loc0 vec2, col=loc1 vec4 -> Position=vec4(pos.xy,.5,1),
    vcol=loc0 vec4(col.rgb, float(VertexIndex)).  Self-contained so the
    frozen cohort needs no corpus binaries.  desc=True adds an unused
    DescriptorSet/Binding-decorated UBO; ubo=True additionally loads it into
    Position.w so descriptor reads are observable in the vary records."""
    words = [0x07230203, 0x00010300, 0, 48, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    emit(15, 0, 22, 0x6E69616D, 0, 11, 12, 13, 14, 15)  # EntryPoint Vertex %main
    emit(71, 11, 30, 0)             # pos   Location 0
    emit(71, 12, 30, 1)             # col   Location 1
    emit(71, 15, 30, 0)             # vcol  Location 0
    emit(71, 13, 11, 42)            # vidx  BuiltIn VertexIndex
    emit(71, 14, 11, 0)             # glpos BuiltIn Position
    if desc or ubo:
        emit(71, 16, 34, 0)         # ubo   DescriptorSet 0
        emit(71, 16, 33, 0)         # ubo   Binding 0
    emit(19, 1)                     # %void
    emit(33, 2, 1)                  # %fnty = fn(void)
    emit(22, 3, 32)                 # %float
    emit(23, 4, 3, 2)               # %v2f
    emit(23, 5, 3, 4)               # %v4f
    emit(21, 6, 32, 1)              # %int
    emit(32, 7, 1, 4)               # ptr Input v2f
    emit(32, 8, 1, 5)               # ptr Input v4f
    emit(32, 9, 1, 6)               # ptr Input int
    emit(32, 10, 3, 5)              # ptr Output v4f
    if desc or ubo:
        emit(32, 17, 2, 6)          # ptr Uniform int
    emit(59, 7, 11, 1)              # pos
    emit(59, 8, 12, 1)              # col
    emit(59, 9, 13, 1)              # vidx
    emit(59, 10, 14, 3)             # glpos
    emit(59, 10, 15, 3)             # vcol
    if desc or ubo:
        emit(59, 17, 16, 2)         # ubo (Uniform)
    emit(43, 3, 18, 0)              # f0
    emit(43, 3, 19, 0x3F000000)     # f0.5
    emit(43, 3, 20, 0x3F800000)     # f1.0
    emit(43, 6, 21, 0)              # i0
    emit(54, 1, 22, 0, 2)           # main()
    emit(248, 23)                   # label
    emit(61, 4, 24, 11)             # p   = Load v2f pos
    emit(81, 3, 25, 24, 0)          # x   = p.x
    emit(81, 3, 26, 24, 1)          # y   = p.y
    if ubo:
        emit(61, 6, 35, 16)         # ui  = Load int ubo
        emit(111, 3, 36, 35)        # uf  = ConvertSToF ui
    emit(80, 5, 27, 25, 26, 19, 36 if ubo else 20)  # pos4=(x,y,.5,ubo|1)
    emit(62, 14, 27)                # Store glpos pos4
    emit(61, 5, 28, 12)             # c   = Load v4f col
    emit(61, 6, 29, 13)             # vi  = Load int vidx
    emit(111, 3, 30, 29)            # vf  = ConvertSToF vi
    emit(81, 3, 31, 28, 0)          # c0
    emit(81, 3, 32, 28, 1)          # c1
    emit(81, 3, 33, 28, 2)          # c2
    emit(80, 5, 34, 31, 32, 33, 30) # vc = (c0,c1,c2,vf)
    emit(62, 15, 34)                # Store vcol vc
    emit(253)                       # Return
    emit(56)                        # FunctionEnd
    return tuple(words)


class ShadeTests(unittest.TestCase):
    def setUp(self):
        self.f = transfer_fixture.TransferTests()
        self.f.setUp()
        self.e, self.executor, self.context = self.f.engine, self.f.executor, self.f.context
        self.owner, self.state = self.f.owner, self.f.state
        self.aperture = self.state.aperture
        self.code = vs_program()

    def span(self, offset=0, size=4096, index_bytes=0):
        return BufferOperand(self.owner, offset, size, index_bytes, (), lambda: None)

    def vertex(self, location, fmt, offset, stride=24, rate=0, span=None):
        from vn_graphics_fetch import FetchVertex
        return FetchVertex(location, fmt, offset, stride, rate, span or self.span())

    def fetch(self, count=3, first=5, indexed=False):
        verts = bytearray()
        for i in range(count + 8):
            verts += struct.pack('<2f', 100.0 + i, 200.0 + i)
            verts += struct.pack('<4f', 0.25, 0.5, 0.75, 1.0)
        self.aperture.write(self.owner.base, bytes(verts))
        indices = None
        if indexed:
            self.aperture.write(self.owner.base + 512,
                                struct.pack('<%dI' % count, *range(count)))
            indices = self.span(512, 64, index_bytes=4)
        # direct = (count, instances, firstVertex, vertexOffset, firstInstance)
        return Fetch(indexed, indices, (
            self.vertex(0, 103, 0), self.vertex(1, 109, 8)),
            (count, 1, first, 0, 0), None)

    def shade(self, **kwargs):
        return Shade(self.fetch(**kwargs), self.code)

    def drain(self):
        for _ in range(512):
            if not self.executor.active:
                return
            self.executor.poll()
        self.fail('bounded shade cohort did not drain')

    def test_vertex_index_attributes_and_varying_outputs(self):
        job = self.executor.enqueue(self.context, [self.shade(count=3)])
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.shade_stats[0]
        self.assertEqual((stats['records'], stats['batches']), (3, 1))
        self.assertGreater(stats['steps'], 0)
        self.assertEqual(self.owner.work_refs, 0)

    def test_vary_records_carry_position_and_vertex_index(self):
        job = self.executor.enqueue(self.context, [self.shade(count=3)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        vary = bytes(runtime.vary)
        self.assertEqual(len(vary), 3 * ATTR_STRIDE)
        # firstVertex=5 -> fetch rows 5,6,7 -> pos=(105,205),(106,206),(107,207)
        pos = [(105.0, 205.0), (106.0, 206.0), (107.0, 207.0)]
        for i in range(3):
            words = struct.unpack_from('<36I', vary, i * ATTR_STRIDE)
            flat = set(words)
            self.assertIn(f32bits(pos[i][0]), flat)
            self.assertIn(f32bits(pos[i][1]), flat)
            # vcol.a = float(VertexIndex) = 5 + i proves slot-8 builtin feed
            self.assertIn(f32bits(5.0 + i), flat)
            # col.rgb = (0.25, 0.5, 0.75) constant attribute
            self.assertIn(f32bits(0.25), flat)
            self.assertIn(f32bits(0.75), flat)

    def test_ubo_descriptor_read_reaches_position_w(self):
        ubo = 12345
        self.aperture.write(self.owner.base + 1024, struct.pack('<i', ubo))
        binding = ShaderBinding(self.owner, 1024, 4, binding=0,
                                descriptor_set=0, kind=6, element=0)
        job = self.executor.enqueue(self.context, [
            Shade(self.fetch(count=3), vs_program(ubo=True),
                  bindings=(binding,))])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        vary = bytes(runtime.vary)
        self.assertEqual(len(vary), 3 * ATTR_STRIDE)
        for i in range(3):
            words = struct.unpack_from('<36I', vary, i * ATTR_STRIDE)
            self.assertIn(f32bits(float(ubo)), set(words))

    def test_ubo_descriptor_requires_matching_binding(self):
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context, [
                Shade(self.fetch(count=3), vs_program(ubo=True))])
        wrong_set = ShaderBinding(self.owner, 1024, 4, binding=0,
                                  descriptor_set=1, kind=6, element=0)
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context, [
                Shade(self.fetch(count=3), vs_program(ubo=True),
                      bindings=(wrong_set,))])

    def test_indexed_fetch_feeds_vertex_index_builtin(self):
        # indices {0,1,2} at firstIndex=0 -> VertexIndex = index value
        job = self.executor.enqueue(self.context,
                                    [self.shade(count=3, first=0, indexed=True)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        vary = bytes(runtime.vary)
        for i in range(3):
            words = struct.unpack_from('<36I', vary, i * ATTR_STRIDE)
            self.assertIn(f32bits(float(i)), set(words))

    def test_batch_split_preserves_record_order(self):
        fetch = self.fetch(count=5)
        shade = Shade(fetch, self.code, batch=2)
        job = self.executor.enqueue(self.context, [shade])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.shade_stats[0]
        self.assertEqual((stats['records'], stats['batches']), (5, 3))
        vary = bytes(runtime.vary)
        self.assertEqual(len(vary), 5 * ATTR_STRIDE)
        for i in range(5):
            words = struct.unpack_from('<36I', vary, i * ATTR_STRIDE)
            self.assertIn(f32bits(5.0 + i), set(words))

    def test_wrong_stage_and_descriptor_are_refused(self):
        frag = tuple(__import__('test_vn_graphics_pipelines',
                                fromlist=['stage_program']).stage_program(4))
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context, [Shade(self.fetch(), frag)])
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.context,
                                  [Shade(self.fetch(), vs_program(desc=True))])

    def test_leases_and_indirect_arguments(self):
        args = struct.pack('<4I', 2, 1, 0, 0)
        self.aperture.write(self.owner.base + 256, args)
        fetch = Fetch(False, None, (
            self.vertex(0, 103, 0), self.vertex(1, 109, 8)),
            None, self.span(256, 16))
        job = self.executor.enqueue(self.context, [
            Transfer('update', self.owner, 256, 16, data=args),
            Shade(fetch, self.code)])
        self.assertEqual(self.owner.work_refs, 1)
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.shade_stats[1]['records'], 2)
        self.assertEqual(self.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
