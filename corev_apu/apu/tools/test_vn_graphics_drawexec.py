# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Full draw chain fetch->VS->raster->FS->writeback; no descriptors/blend."""
import struct
import unittest

import test_vn_transfers as transfer_fixture
import vn_golden
from test_vn_graphics_pshade import fs_program
from test_vn_graphics_shade import vs_program
from vn_graphics_drawexec import DrawExec, DrawExecRuntime
from vn_graphics_fetch import Fetch, FetchVertex
from vn_vertex_operands import BufferOperand


def texel_words(*rgba):
    return struct.unpack('<4I', struct.pack('<4f', *rgba))


class DrawExecTests(unittest.TestCase):
    def setUp(self):
        self.f = transfer_fixture.TransferTests()
        self.f.setUp()
        self.e, self.executor, self.context = (
            self.f.engine, self.f.executor, self.f.context)
        self.owner, self.state = self.f.owner, self.f.state
        self.aperture = self.state.aperture
        self.model = self.executor.execution.model

    def drain(self):
        for _ in range(512):
            if not self.executor.active:
                return
            self.executor.poll()
        self.fail('bounded draw exec cohort did not drain')

    def span(self, offset=0, size=4096):
        return BufferOperand(self.owner, offset, size, 0, (), lambda: None)

    def vertex(self, location, fmt, offset, stride=24):
        return FetchVertex(location, fmt, offset, stride, 0, self.span())

    def upload(self, verts):
        data = bytearray()
        for pos, col in verts:
            data += struct.pack('<2f', *pos)
            data += struct.pack('<4f', *col)
        self.aperture.write(self.owner.base, bytes(data))

    def fetch(self, count=3):
        return Fetch(False, None,
                     (self.vertex(0, 103, 0), self.vertex(1, 109, 8)),
                     (count, 1, 0, 0, 0), None)

    def op(self, count=3, **kw):
        args = dict(fetch=self.fetch(count), vs=vs_program(),
                    fs=fs_program('color'),
                    viewport=(0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                    scissor=(0, 0, 8, 8), owner=self.owner, offset=2048,
                    pitch=64 * 4, width=8, height=8,
                    fmt=vn_golden.img_fmt_id(self.model, 109))
        args.update(kw)
        return DrawExec(**args)

    def ndc_triangle(self, count=3):
        verts = [((-1.0, -1.0), (0.25, 0.5, 0.75, 1.0)),
                 ((1.0, -1.0), (0.25, 0.5, 0.75, 1.0)),
                 ((-1.0, 1.0), (0.25, 0.5, 0.75, 1.0))]
        while len(verts) < count:
            verts.append(((-1.0, -1.0), (0.0, 0.0, 0.0, 1.0)))
        return verts[:count]

    def test_end_to_end_triangle_writes_texels(self):
        self.upload(self.ndc_triangle())
        job = self.executor.enqueue(self.context, [self.op()])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[0]
        self.assertGreater(stats['records'], 0)
        self.assertEqual(stats['triangles'], 1)
        self.assertEqual(stats['vary'], 3 * 144)
        self.assertEqual(stats['color'], stats['records'] * 144)
        # pixel (0,0): lam=(0.875,0.0625,0.0625); col.rgb constant,
        # vcol.a = interpolated VertexIndex = 0.875*0+0.0625*1+0.0625*2
        expected = vn_golden.img_clear_texel(
            self.model, vn_golden.img_fmt_id(self.model, 109),
            texel_words(0.25, 0.5, 0.75, 0.1875))
        data = self.aperture.read(self.owner.base + 2048, 64 * 4 * 8)
        got = data[0 * 256 + 0 * 16: 0 * 256 + 0 * 16 + 16]
        self.assertEqual(got, expected)
        # a covered interior pixel differs from the untouched zero texel
        self.assertNotEqual(data[1 * 256 + 1 * 16: 1 * 256 + 1 * 16 + 16],
                            b'\0' * 16)
        self.assertEqual(self.owner.work_refs, 0)

    def test_multi_triangle_and_stats(self):
        # two same-facing triangles -> 6 vertices, 2 raster triangles
        verts = self.ndc_triangle(3) + self.ndc_triangle(3)
        # shift second triangle right so it lands in x>=0 half
        verts = verts[:3] + [((1.0, -1.0), c) for _, c in verts[3:6]]
        self.upload(verts)
        job = self.executor.enqueue(self.context, [self.op(count=6)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.drawexec_stats[0]
        self.assertEqual(stats['triangles'], 2)
        self.assertGreater(stats['records'], 0)
        self.assertEqual(self.owner.work_refs, 0)

    def test_admission_refusals(self):
        self.upload(self.ndc_triangle())
        base = self.op()
        bad = [
            DrawExec(base.fetch, vs_program(), fs_program('color'),
                     base.viewport, base.scissor, self.owner, 2048, 256,
                     8, 8, vn_golden.img_fmt_id(self.model, 999)),
            DrawExec(base.fetch, vs_program(), vs_program(),
                     base.viewport, base.scissor, self.owner, 2048, 256,
                     8, 8, base.fmt),
            DrawExec(base.fetch, vs_program(desc=True),
                     fs_program('color'), base.viewport, base.scissor,
                     self.owner, 2048, 256, 8, 8, base.fmt),
            DrawExec(base.fetch, vs_program(), fs_program('color', desc=True),
                     base.viewport, base.scissor, self.owner, 2048, 256,
                     8, 8, base.fmt),
            DrawExec(base.fetch, vs_program(), fs_program('color'),
                     (0.0, 0.0, 8.0), base.scissor, self.owner, 2048, 256,
                     8, 8, base.fmt),
            DrawExec(base.fetch, vs_program(), fs_program('color'),
                     base.viewport, (0, 0, 9999, 8), self.owner, 4096,
                     256, 8, 8, base.fmt),
        ]
        for op in bad:
            with self.assertRaises(ValueError):
                DrawExecRuntime(self.executor, self.context, op)
        self.assertEqual(self.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
