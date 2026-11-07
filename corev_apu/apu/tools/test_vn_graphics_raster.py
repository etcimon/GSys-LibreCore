# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded raster stage over VS-out records; no FS/ROP/writeback admission."""
import struct
import unittest

import test_vn_transfers as transfer_fixture
import vn_golden
from shader.spirv_scan import Scanner
from test_vn_graphics_pshade import fs_program
from vn_graphics_fetch import ATTR_STRIDE
from vn_graphics_raster import (MAX_FRAGMENTS, Raster, RasterRuntime,
                                 RasterShade, RasterShadeRuntime)


def vary_record(position, vcol=None):
    rec = bytearray(ATTR_STRIDE)
    struct.pack_into('<4f', rec, 0, *position)
    if vcol is not None:
        struct.pack_into('<4f', rec, 16, *vcol)
    return bytes(rec)


def vary_bytes(verts):
    return b''.join(vary_record(*v) for v in verts)


def fragcoords(records):
    out = set()
    for i in range(0, len(records), ATTR_STRIDE):
        x, y = struct.unpack_from('<2f', records, i)
        out.add((int(x - 0.5), int(y - 0.5)))
    return out


class RasterTests(unittest.TestCase):
    def setUp(self):
        self.f = transfer_fixture.TransferTests()
        self.f.setUp()
        self.e, self.executor, self.context = (
            self.f.engine, self.f.executor, self.f.context)
        self.owner, self.state = self.f.owner, self.f.state

    def drain(self):
        for _ in range(512):
            if not self.executor.active:
                return
            self.executor.poll()
        self.fail('bounded raster cohort did not drain')

    def raster(self, verts, vp=(0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
               scissor=(0, 0, 8, 8), **kw):
        return Raster(vary_bytes(verts), vp, scissor, len(verts), **kw)

    def execute(self, op):
        job = self.executor.enqueue(self.context, [op])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        return job, runtime

    def test_coverage_matches_golden_oracle(self):
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        job, runtime = self.execute(self.raster(verts))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 1)
        self.assertEqual(stats['degenerate'], 0)
        expected = vn_golden.gfx_tri_coverage(
            [v[0] for v in verts], (0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
            (0, 0, 8, 8), 8, 8, True, 0)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)
        self.assertEqual(stats['records'], len(expected))
        # FragCoord.z maps NDC z=0 through [minz,maxz]=[0,1] -> 0; w=1/clipw=1
        for i in range(0, len(runtime.records), ATTR_STRIDE):
            _x, _y, z, w = struct.unpack_from('<4f', runtime.records, i)
            self.assertEqual((z, w), (0.0, 1.0))
        self.assertEqual(self.owner.work_refs, 0)

    def test_varying_interpolates_perspective_correct(self):
        verts = [((-1.0, -1.0, 0.0, 1.0), (10.0, 0.0, 0.0, 1.0)),
                 ((1.0, -1.0, 0.0, 1.0), (20.0, 0.0, 0.0, 1.0)),
                 ((-1.0, 1.0, 0.0, 1.0), (30.0, 0.0, 0.0, 1.0))]
        job, runtime = self.execute(self.raster(verts))
        records = bytes(runtime.records)
        self.assertTrue(records)
        # pixel (0,0): screen (0.5,0.5) -> lam = (0.875, 0.0625, 0.0625)
        # value = 0.875*10 + 0.0625*20 + 0.0625*30 = 11.875
        found = False
        for i in range(0, len(records), ATTR_STRIDE):
            x, y = struct.unpack_from('<2f', records, i)
            if (int(x - 0.5), int(y - 0.5)) == (0, 0):
                val = struct.unpack_from('<f', records, i + 16)[0]
                self.assertAlmostEqual(val, 11.875, places=4)
                found = True
        self.assertTrue(found)

    def test_perspective_w_division_is_applied(self):
        # w=2 on every vertex halves NDC; viewport transform uses x/w so
        # screen positions land at the same place but clip w=2 -> FragCoord.w=0.5
        verts = [((-2.0, -2.0, 0.0, 2.0), None),
                 ((2.0, -2.0, 0.0, 2.0), None),
                 ((-2.0, 2.0, 0.0, 2.0), None)]
        job, runtime = self.execute(self.raster(verts))
        records = bytes(runtime.records)
        self.assertTrue(records)
        for i in range(0, len(records), ATTR_STRIDE):
            _x, _y, _z, w = struct.unpack_from('<4f', records, i)
            self.assertAlmostEqual(w, 0.5, places=5)

    def test_flat_varying_copies_vertex0_bits(self):
        marker = (0xDEADBEEF, 0x12345678, 7, 9)
        vary = bytearray()
        for pos, col in [((-1.0, -1.0, 0.0, 1.0), marker),
                         ((1.0, -1.0, 0.0, 1.0), (1.0, 2.0, 3.0, 4.0)),
                         ((-1.0, 1.0, 0.0, 1.0), (5.0, 6.0, 7.0, 8.0))]:
            rec = bytearray(ATTR_STRIDE)
            struct.pack_into('<4f', rec, 0, *pos)
            if col is marker:
                struct.pack_into('<4I', rec, 16, *col)
            else:
                struct.pack_into('<4f', rec, 16, *col)
            vary += rec
        job = self.executor.enqueue(self.context, [Raster(
            bytes(vary), (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8), 3,
            flat=1)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        records = bytes(runtime.records)
        self.assertTrue(records)
        for i in range(0, len(records), ATTR_STRIDE):
            self.assertEqual(struct.unpack_from('<4I', records, i + 16),
                             marker)

    def test_nopersp_varying_uses_screen_space_weights(self):
        # clip w varies per vertex while NDC is preserved by scaling x,y
        # by w, so coverage and screen-space lam match the w=1 triangle
        # but perspective-correct != nopersp interpolation.  Vertex NDC is
        # (-1,-1),(1,-1),(-1,1) -> clip records (-1,-1,0,1),(2,-2,0,2),
        # (-1,1,0,1) give w=[1,2,1].  pixel(0,0) lam=(0.875,0.0625,0.0625)
        # and vcol.x=(10,20,30):
        #   persp  = (0.875*10/1 + 0.0625*20/2 + 0.0625*30/1)
        #            / (0.875/1 + 0.0625/2 + 0.0625/1) = 11.25/0.96875
        #   nopersp= 0.875*10 + 0.0625*20 + 0.0625*30 = 11.875
        verts = [((-1.0, -1.0, 0.0, 1.0), (10.0, 0.0, 0.0, 1.0)),
                 ((2.0, -2.0, 0.0, 2.0), (20.0, 0.0, 0.0, 1.0)),
                 ((-1.0, 1.0, 0.0, 1.0), (30.0, 0.0, 0.0, 1.0))]

        def channel_at_pixel(nopersp):
            job, runtime = self.execute(self.raster(verts, nopersp=nopersp))
            records = bytes(runtime.records)
            self.assertTrue(records)
            for i in range(0, len(records), ATTR_STRIDE):
                x, y = struct.unpack_from('<2f', records, i)
                if (int(x - 0.5), int(y - 0.5)) == (0, 0):
                    return struct.unpack_from('<f', records, i + 16)[0]
            self.fail('pixel (0,0) not covered')

        persp = channel_at_pixel(0)
        nop = channel_at_pixel(1)
        self.assertAlmostEqual(persp, 11.25 / 0.96875, places=4)
        self.assertAlmostEqual(nop, 11.875, places=4)
        self.assertNotAlmostEqual(persp, nop, places=3)

    def test_nopersp_decoration_reaches_scan_mask(self):
        # the NoPerspective decoration on the vcol (loc0) input must surface
        # as nopersp_mask bit0 so GraphicsPipeline/DrawExec can forward it
        scan = Scanner(list(fs_program('color', nopersp=True))).scan()
        self.assertEqual(scan.nopersp_mask, 1)
        self.assertEqual(scan.flat_mask, 0)
        scan = Scanner(list(fs_program('color'))).scan()
        self.assertEqual(scan.nopersp_mask, 0)

    def test_scissor_and_cull_bound_coverage(self):
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        job, runtime = self.execute(self.raster(
            verts, scissor=(2, 2, 6, 6)))
        coords = fragcoords(bytes(runtime.records))
        self.assertTrue(coords)
        self.assertTrue(all(2 <= x < 8 and 2 <= y < 8 for x, y in coords))
        expected = vn_golden.gfx_tri_coverage(
            [v[0] for v in verts], (0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
            (2, 2, 6, 6), 8, 8, True, 0)
        self.assertEqual(coords, expected)
        # same winding is a back face under front_ccw=1: cull=2 drops it
        job, runtime = self.execute(self.raster(verts, cull=2))
        stats = job.raster_stats[0]
        self.assertEqual((stats['culled'], stats['records']), (1, 0))
        self.assertEqual(len(runtime.records), 0)

    def test_degenerate_and_nonpositive_w_are_skipped(self):
        line = [((-1.0, -1.0, 0.0, 1.0), None),
                ((0.0, 0.0, 0.0, 1.0), None),
                ((1.0, 1.0, 0.0, 1.0), None)]
        job, runtime = self.execute(self.raster(line + line))
        # six collinear vertices -> two degenerate triangles
        stats = job.raster_stats[0]
        self.assertEqual(stats['degenerate'], 2)
        self.assertEqual(stats['records'], 0)
        bad = [((-1.0, -1.0, 0.0, -1.0), None),
               ((1.0, -1.0, 0.0, 1.0), None),
               ((-1.0, 1.0, 0.0, 1.0), None)]
        job, runtime = self.execute(self.raster(bad))
        stats = job.raster_stats[0]
        self.assertEqual((stats['degenerate'], stats['records']), (1, 0))

    def test_multi_turn_bounded_progress(self):
        # 200x200 viewport, half-screen triangle -> ~20k fragments,
        # above the 16k pixel-test turn quantum but under the fragment cap
        n = 200
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        job = self.executor.enqueue(self.context, [self.raster(
            verts, vp=(0.0, 0.0, float(n), float(n), 0.0, 1.0),
            scissor=(0, 0, n, n))])
        runtime = job.runtimes[0]
        turns = 0
        while self.executor.active and turns < 512:
            self.executor.poll()
            turns += 1
        self.assertEqual(job.state, 'done')
        stats = job.raster_stats[0]
        self.assertGreater(stats['tests'], 16384)
        self.assertGreater(stats['records'], 10000)
        self.assertLessEqual(stats['records'], MAX_FRAGMENTS)
        expected = vn_golden.gfx_tri_coverage(
            [v[0] for v in verts], (0.0, 0.0, float(n), float(n), 0.0, 1.0),
            (0, 0, n, n), n, n, True, 0)
        self.assertEqual(stats['records'], len(expected))

    def test_fragment_budget_faults_the_job(self):
        # viewport larger than MAX_FRAGMENTS coverage -> admission-bounded
        # runtime must fault rather than publish a truncated image
        n = 512
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None),
                 ((1.0, 1.0, 0.0, 1.0), None),
                 ((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None)]
        op = Raster(vary_bytes(verts), (0.0, 0.0, float(n), float(n), 0.0, 1.0),
                    (0, 0, n, n), 6)
        # coverage exceeds MAX_FRAGMENTS mid-run: the runtime must fault the
        # job rather than publish a silently truncated fragment image
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'faulted')
        self.assertIn('fragment budget', job.error)
        self.assertEqual(self.owner.work_refs, 0)

    def test_admission_refusals(self):
        good = vary_bytes([((-1.0, -1.0, 0.0, 1.0), None)] * 3)
        base = dict(viewport=(0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                    scissor=(0, 0, 8, 8), count=3)
        bad = [
            Raster(good, **{**base, 'viewport': (0.0, 0.0, 8.0, 8.0, 0.0)}),
            Raster(good, **{**base, 'viewport': (0.0, 0.0, float('nan'),
                                                 8.0, 0.0, 1.0)}),
            Raster(good, **{**base, 'scissor': (0, 0, 8192, 8)}),
            Raster(good, **{**base, 'flat': 256}),
            Raster(good, **{**base, 'cull': 4}),
            Raster(good[:-4], **base),
            Raster(good, **{**base, 'count': 4}),
            Raster(good, **{**base, 'count': 2}),
        ]
        for op in bad:
            with self.assertRaises(ValueError):
                RasterRuntime(self.executor, self.context, op)


if __name__ == '__main__':
    unittest.main()


def front_program():
    """Fragment module declaring (but not reading) a FrontFacing input so
    the composite's uniform-facing guard engages."""
    words = [0x07230203, 0x00010300, 0, 30, 0]

    def emit(opcode, *values):
        words.extend(((len(values) + 1) << 16 | opcode, *values))

    emit(17, 1)                     # OpCapability Shader
    emit(14, 0, 1)                  # OpMemoryModel Logical GLSL450
    emit(15, 4, 9, 0x6E69616D, 0, 10, 11)  # EntryPoint Fragment
    emit(16, 9, 7)                  # OriginUpperLeft
    emit(71, 10, 11, 17)             # fc BuiltIn FrontFacing
    emit(71, 11, 30, 0)             # color Location 0
    emit(19, 1)                     # %void
    emit(20, 2)                     # %bool
    emit(22, 3, 32)                 # %float
    emit(23, 4, 3, 4)               # %v4f
    emit(32, 5, 1, 2)               # ptr Input bool
    emit(32, 6, 3, 4)               # ptr Output v4f
    emit(32, 7, 3, 4)               # ptr Function v4f
    emit(43, 3, 12, 0x3F800000)     # f1
    emit(59, 5, 10, 1)              # fc input
    emit(59, 6, 11, 3)              # color output
    emit(54, 1, 9, 0, 3)            # main()
    emit(248, 13)                   # label
    emit(80, 4, 14, 12, 12, 12, 12)  # vec4(1,1,1,1)
    emit(62, 11, 14)                # Store color
    emit(253)
    emit(56)
    return tuple(words)


class RasterShadeTests(unittest.TestCase):
    def setUp(self):
        self.f = transfer_fixture.TransferTests()
        self.f.setUp()
        self.e, self.executor, self.context = (
            self.f.engine, self.f.executor, self.f.context)
        self.owner, self.state = self.f.owner, self.f.state

    def drain(self):
        for _ in range(512):
            if not self.executor.active:
                return
            self.executor.poll()
        self.fail('bounded raster shade cohort did not drain')

    def shade_op(self, verts, code=None, **kw):
        args = dict(vary=vary_bytes(verts),
                    viewport=(0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                    scissor=(0, 0, 8, 8), count=len(verts),
                    code=code if code is not None else fs_program('color'))
        args.update(kw)
        return RasterShade(**args)

    def test_raster_to_fragment_color_passthrough(self):
        verts = [((-1.0, -1.0, 0.0, 1.0), (10.0, 0.0, 0.0, 1.0)),
                 ((1.0, -1.0, 0.0, 1.0), (20.0, 0.0, 0.0, 1.0)),
                 ((-1.0, 1.0, 0.0, 1.0), (30.0, 0.0, 0.0, 1.0))]
        job = self.executor.enqueue(self.context, [self.shade_op(verts)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.rastershade_stats[0]
        self.assertEqual(stats['records'], stats['color'] // ATTR_STRIDE)
        self.assertGreater(stats['records'], 0)
        self.assertEqual(stats['batches'], 1)
        # FS-out order matches raster emission order: find pixel (0,0)'s
        # FS-in index and check its color equals the interpolated 11.875
        fsin = bytes(runtime.raster.records)
        color = bytes(runtime.fs.color)
        target = None
        for i in range(0, len(fsin), ATTR_STRIDE):
            x, y = struct.unpack_from('<2f', fsin, i)
            if (int(x - 0.5), int(y - 0.5)) == (0, 0):
                target = i // ATTR_STRIDE
        self.assertIsNotNone(target)
        val = struct.unpack_from('<f', color, target * ATTR_STRIDE)[0]
        self.assertAlmostEqual(val, 11.875, places=4)
        self.assertEqual(self.owner.work_refs, 0)

    def test_mixed_front_facing_faults_when_shader_reads_it(self):
        ccw = [((-1.0, -1.0, 0.0, 1.0), None),
               ((1.0, -1.0, 0.0, 1.0), None),
               ((-1.0, 1.0, 0.0, 1.0), None)]
        cw = [((-1.0, -1.0, 0.0, 1.0), None),
              ((-1.0, 1.0, 0.0, 1.0), None),
              ((1.0, -1.0, 0.0, 1.0), None)]
        job = self.executor.enqueue(self.context, [self.shade_op(
            ccw + cw, code=front_program())])
        self.drain()
        self.assertEqual(job.state, 'faulted')
        self.assertIn('front-facing', job.error)
        # uniform facing passes even when the shader declares FrontFacing
        job = self.executor.enqueue(self.context, [self.shade_op(
            ccw, code=front_program())])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(len(runtime.fs.color),
                         len(runtime.raster.records))

    def test_stage_and_descriptor_refusals(self):
        verts = [((-1.0, -1.0, 0.0, 1.0), None)] * 3
        # a vertex module must be refused — the stage requires Fragment EM
        from test_vn_graphics_shade import vs_program
        with self.assertRaises(ValueError):
            RasterShadeRuntime(self.executor, self.context,
                               self.shade_op(verts, code=vs_program()))
        with self.assertRaises(ValueError):
            RasterShadeRuntime(self.executor, self.context,
                               self.shade_op(verts,
                                             code=fs_program('color',
                                                             desc=True)))
        with self.assertRaises(ValueError):
            RasterShadeRuntime(self.executor, self.context,
                               self.shade_op(verts, scissor=(0, 0, 9999, 8)))
        self.assertEqual(self.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
