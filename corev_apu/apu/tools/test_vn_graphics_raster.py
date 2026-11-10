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

    def test_rasterizer_discard_emits_no_records(self):
        # rasterizerDiscardEnable discards every primitive before
        # rasterization: triangles are still counted, but zero fragment
        # records are emitted so writeback keeps the attachment clear.
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        job, runtime = self.execute(self.raster(verts, discard=1))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 1)
        self.assertEqual(stats['degenerate'], 0)
        self.assertEqual(stats['culled'], 0)
        self.assertEqual(stats['records'], 0)
        self.assertEqual(bytes(runtime.records), b'')
        self.assertEqual(self.owner.work_refs, 0)

    def _zmap(self, runtime):
        out = {}
        for i in range(0, len(runtime.records), ATTR_STRIDE):
            x, y, z = struct.unpack_from('<3f', runtime.records, i)
            out[(int(x - 0.5), int(y - 0.5))] = z
        return out

    def test_depth_bias_shifts_window_depth(self):
        # depthBiasEnable with only the constant factor (slope=0, clamp=1)
        # mirrors the RTL dbias oracle: bias = constantFactor*r with r=1.0
        # for D32, added to every fragment's window depth.  All vertices at
        # z_ndc=0 -> unbiased z_win=0 -> biased z_win=0.25 everywhere.
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        job, runtime = self.execute(self.raster(
            verts, depth_bias=(0.25, 1.0, 0.0)))
        stats = job.raster_stats[0]
        self.assertGreater(stats['records'], 0)
        for z in self._zmap(runtime).values():
            self.assertAlmostEqual(z, 0.25, places=6)

    def test_depth_bias_slope_is_per_triangle_constant(self):
        # slopeFactor adds slopeFactor*max|dz|/span once per triangle; the
        # delta against the unbiased run is the same constant for every
        # fragment.  z_ndc=(0,1,0) -> window dz=1.0, span=8 -> bias=0.125.
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 1.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        _job, plain = self.execute(self.raster(verts))
        job, biased = self.execute(self.raster(
            verts, depth_bias=(0.0, 10.0, 1.0)))
        base, shifted = self._zmap(plain), self._zmap(biased)
        self.assertEqual(set(base), set(shifted))
        self.assertTrue(shifted)
        for coord in base:
            self.assertAlmostEqual(shifted[coord] - base[coord],
                                   0.125, places=6)

    def test_depth_bias_admission_refusals(self):
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        for bad in ((0.25,), (0.25, 1.0), (0.25, 1.0, 0.0, 0.0),
                    (0.25, float('nan'), 0.0), (0.25, 1.0, 'x'),
                    'bias', 0.25):
            with self.assertRaises(ValueError):
                self.execute(self.raster(verts, depth_bias=bad))

    def test_depth_clamp_off_drops_out_of_range_fragments(self):
        # depthClampEnable=0 keeps the near/far clip: every vertex at
        # z_ndc=2.0 (beyond far, maxz=1) -> window depth 2.0 outside
        # [0,1] -> every fragment dropped -> zero records (the dclampoff
        # oracle's empty framebuffer).
        verts = [((-1.0, -1.0, 2.0, 1.0), None),
                 ((1.0, -1.0, 2.0, 1.0), None),
                 ((-1.0, 1.0, 2.0, 1.0), None)]
        job, runtime = self.execute(self.raster(verts, depth_clamp=0))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 1)
        self.assertEqual(stats['records'], 0)
        self.assertEqual(bytes(runtime.records), b'')

    def test_depth_clamp_on_clamps_window_depth(self):
        # depthClampEnable=1 skips the clip and clamps the window depth
        # into [0,1]: the same z_ndc=2.0 triangle rasterizes and every
        # fragment's z_win is clamped to the far plane 1.0.
        verts = [((-1.0, -1.0, 2.0, 1.0), None),
                 ((1.0, -1.0, 2.0, 1.0), None),
                 ((-1.0, 1.0, 2.0, 1.0), None)]
        job, runtime = self.execute(self.raster(verts, depth_clamp=1))
        stats = job.raster_stats[0]
        self.assertGreater(stats['records'], 0)
        for z in self._zmap(runtime).values():
            self.assertAlmostEqual(z, 1.0, places=6)

    def test_depth_clamp_admission_refusal(self):
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        with self.assertRaises(ValueError):
            self.execute(self.raster(verts, depth_clamp=2))

    def test_polygon_mode_line_matches_golden_oracle(self):
        # polygonMode=LINE rasterizes the triangle's three edges as
        # independent Bresenhams; coverage is the union of the per-edge
        # gfx_line_coverage footprints (the polyln oracle).
        clip = [(-0.5, -0.5, 0.0, 1.0), (0.75, -0.25, 0.0, 1.0),
                (-0.25, 0.75, 0.0, 1.0)]
        verts = [(p, None) for p in clip]
        job, runtime = self.execute(self.raster(verts, poly_mode=1))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 1)
        self.assertGreater(stats['records'], 0)
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                          (0, 0, 8, 8), 8, 8)
        expected = set()
        for i in range(3):
            expected |= vn_golden.gfx_line_coverage(
                [clip[i], clip[(i + 1) % 3]], vp, sc, cw, ch)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_polygon_mode_point_matches_golden_oracle(self):
        # polygonMode=POINT emits one fragment per vertex at that
        # vertex's pixel — the union of degenerate point Bresenhams
        # (the polypnt oracle).
        clip = [(-0.5, -0.5, 0.0, 1.0), (0.75, -0.25, 0.0, 1.0),
                (-0.25, 0.75, 0.0, 1.0)]
        verts = [(p, None) for p in clip]
        job, runtime = self.execute(self.raster(verts, poly_mode=2))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 1)
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                          (0, 0, 8, 8), 8, 8)
        expected = set()
        for i in range(3):
            expected |= vn_golden.gfx_line_coverage(
                [clip[i], clip[i]], vp, sc, cw, ch)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)
        # point fragments carry the vertex's own window depth (z_ndc=0
        # -> z_win=0) at the vertex pixel.
        for i in range(0, len(runtime.records), ATTR_STRIDE):
            _x, _y, z, w = struct.unpack_from('<4f', runtime.records, i)
            self.assertAlmostEqual(z, 0.0, places=6)

    def test_polygon_mode_admission_refusal(self):
        verts = [((-1.0, -1.0, 0.0, 1.0), None),
                 ((1.0, -1.0, 0.0, 1.0), None),
                 ((-1.0, 1.0, 0.0, 1.0), None)]
        with self.assertRaises(ValueError):
            self.execute(self.raster(verts, poly_mode=3))

    def test_line_list_topology_matches_golden_oracle(self):
        # topology=LINE_LIST groups vertex records by two and rasterizes
        # each segment's Bresenham coverage (the line oracle); polygonMode
        # does not apply to line primitives.
        segs = [[(-0.75, -0.5, 0.0, 1.0), (0.75, -0.25, 0.0, 1.0)],
                [(-0.25, 0.75, 0.0, 1.0), (0.5, 0.75, 0.0, 1.0)]]
        verts = [(p, None) for seg in segs for p in seg]
        job, runtime = self.execute(self.raster(verts, topology=1))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 2)
        self.assertGreater(stats['records'], 0)
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                          (0, 0, 8, 8), 8, 8)
        expected = set()
        for seg in segs:
            expected |= vn_golden.gfx_line_coverage(seg, vp, sc, cw, ch)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)
        # line fragments carry interpolated window depth like polygonMode
        # LINE: z_ndc=0 -> z_win=0 across the segment.
        for i in range(0, len(runtime.records), ATTR_STRIDE):
            _x, _y, z, w = struct.unpack_from('<4f', runtime.records, i)
            self.assertAlmostEqual(z, 0.0, places=6)

    def test_line_list_admission_and_degenerate(self):
        # an odd vertex count is not segment-aligned; a zero-length
        # segment is degenerate; out-of-profile topologies refuse.
        odd = [((-1.0, -1.0, 0.0, 1.0), None),
               ((1.0, -1.0, 0.0, 1.0), None),
               ((-1.0, 1.0, 0.0, 1.0), None)]
        with self.assertRaises(ValueError):
            self.execute(self.raster(odd, topology=1))
        for bad in (6, 7):
            with self.subTest(topology=bad):
                with self.assertRaises(ValueError):
                    self.execute(self.raster(odd, topology=bad))
        # zero-length segment: both endpoints map to the same pixel.
        same = [((-0.25, -0.25, 0.0, 1.0), None),
                ((-0.25, -0.25, 0.0, 1.0), None)]
        job, runtime = self.execute(self.raster(same, topology=1))
        stats = job.raster_stats[0]
        self.assertEqual(stats['records'], 0)
        self.assertEqual(stats['degenerate'], 1)

    def test_line_strip_topology_matches_golden_oracle(self):
        # topology=LINE_STRIP chains consecutive vertex pairs: three
        # records give two segments v0-v1 and v1-v2 sharing the middle
        # vertex — coverage is the union of the two segment Bresenhams
        # (the lstrip oracle).
        pts = [(-0.75, -0.5, 0.0, 1.0), (0.75, -0.25, 0.0, 1.0),
               (-0.25, 0.75, 0.0, 1.0)]
        verts = [(p, None) for p in pts]
        job, runtime = self.execute(self.raster(verts, topology=2))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 2)
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                          (0, 0, 8, 8), 8, 8)
        expected = set()
        for i in range(2):
            expected |= vn_golden.gfx_line_coverage(
                [pts[i], pts[i + 1]], vp, sc, cw, ch)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_point_list_topology_matches_golden_oracle(self):
        # topology=POINT_LIST emits one fragment per vertex at that
        # vertex's pixel — the union of degenerate point coverage (the
        # polypnt oracle applied per-vertex).
        pts = [(-0.5, -0.5, 0.0, 1.0), (0.75, -0.25, 0.0, 1.0),
               (-0.25, 0.75, 0.0, 1.0)]
        verts = [(p, None) for p in pts]
        job, runtime = self.execute(self.raster(verts, topology=0))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 3)
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                          (0, 0, 8, 8), 8, 8)
        expected = set()
        for p in pts:
            expected |= vn_golden.gfx_line_coverage([p, p], vp, sc, cw, ch)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_triangle_strip_topology_matches_golden_oracle(self):
        # topology=TRIANGLE_STRIP slides one vertex per primitive and swaps
        # slots 1/2 on odd prims to hold winding: four records give two
        # triangles (v0,v1,v2) and (v1,v3,v2) sharing the v1-v2 edge — the
        # strip oracle decomposes the same winding-corrected window.
        pts = [(-1.0, -1.0, 0.0, 1.0), (-1.0, 1.0, 0.0, 1.0),
               (1.0, -1.0, 0.0, 1.0), (1.0, 1.0, 0.0, 1.0)]
        verts = [(p, None) for p in pts]
        job, runtime = self.execute(self.raster(verts, topology=4))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 2)
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                          (0, 0, 8, 8), 8, 8)
        expected = vn_golden.gfx_strip_coverage(
            pts, vp, sc, cw, ch, True, 0)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_triangle_strip_polygon_mode_line_matches_oracle(self):
        # polygonMode=LINE on a TRIANGLE_STRIP: each winding-corrected
        # sliding-window triangle rasterizes its three edges as
        # Bresenhams; shared edges emit twice but fragcoords dedups.
        # Coverage is the union over each triangle's cyclic edges.
        pts = [(-0.5, -0.5, 0.0, 1.0), (-0.5, 0.5, 0.0, 1.0),
               (0.5, -0.5, 0.0, 1.0), (0.5, 0.5, 0.0, 1.0)]
        verts = [(p, None) for p in pts]
        job, runtime = self.execute(self.raster(verts, topology=4,
                                                poly_mode=1))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 2)
        self.assertGreater(stats['records'], 0)
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                          (0, 0, 8, 8), 8, 8)
        expected = set()
        for t in range(len(pts) - 2):
            tri = ([pts[t], pts[t + 2], pts[t + 1]] if t & 1 else
                   [pts[t], pts[t + 1], pts[t + 2]])
            for i in range(3):
                expected |= vn_golden.gfx_line_coverage(
                    [tri[i], tri[(i + 1) % 3]], vp, sc, cw, ch)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_triangle_fan_topology_matches_golden_oracle(self):
        # topology=TRIANGLE_FAN anchors every triangle's slot 0 at vertex 0
        # and slides the (t+1,t+2) pair: four records give (v0,v1,v2) and
        # (v0,v2,v3) — the fan oracle decomposes the same anchored window.
        pts = [(-1.0, -1.0, 0.0, 1.0), (-1.0, 1.0, 0.0, 1.0),
               (1.0, 1.0, 0.0, 1.0), (1.0, -1.0, 0.0, 1.0)]
        verts = [(p, None) for p in pts]
        job, runtime = self.execute(self.raster(verts, topology=5))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 2)
        vp, sc, cw, ch = ((0.0, 0.0, 8.0, 8.0, 0.0, 1.0),
                          (0, 0, 8, 8), 8, 8)
        expected = vn_golden.gfx_fan_coverage(
            pts, vp, sc, cw, ch, True, 0)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_triangle_list_restart_splits_primitives(self):
        # TRIANGLE_LIST [v0,v1,v2] SENT [v3,v4,v5]: the sentinel record is
        # a break, so the two triangles assemble independently and no
        # primitive straddles it.  The seven-record stream is not
        # globally primitive-aligned — only break-aware assembly admits it.
        vp, sc = (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8)
        left = [(-1.0, -1.0, 0.0, 1.0), (0.0, -1.0, 0.0, 1.0),
                (-1.0, 1.0, 0.0, 1.0)]
        right = [(0.0, -1.0, 0.0, 1.0), (1.0, -1.0, 0.0, 1.0),
                 (0.0, 1.0, 0.0, 1.0)]
        slots = left + [(0.5, 0.5, 0.0, 1.0)] + right
        stream = left + [None] + right
        job, runtime = self.execute(self.raster(
            [(p, None) for p in slots], vp, sc, topology=3, restarts={3}))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 2)
        expected = vn_golden.gfx_restart_coverage(
            stream, 3, vp, sc, 8, 8, True, 0)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_triangle_strip_restart_resets_window(self):
        # TRIANGLE_STRIP [a,b,c] SENT [d,e,f]: the break resets the sliding
        # vertex window, so each three-vertex run emits exactly one
        # triangle.  Concatenating the runs would wrongly emit four
        # cross-break triangles — the oracle only credits the two runs.
        vp, sc = (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8)
        a = [(-1.0, -1.0, 0.0, 1.0), (-1.0, 1.0, 0.0, 1.0),
             (0.0, -1.0, 0.0, 1.0)]
        b = [(1.0, -1.0, 0.0, 1.0), (1.0, 1.0, 0.0, 1.0),
             (0.0, 1.0, 0.0, 1.0)]
        slots = a + [(0.5, 0.5, 0.0, 1.0)] + b
        stream = a + [None] + b
        job, runtime = self.execute(self.raster(
            [(p, None) for p in slots], vp, sc, topology=4, restarts={3}))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 2)
        expected = vn_golden.gfx_restart_coverage(
            stream, 4, vp, sc, 8, 8, True, 0)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_triangle_fan_restart_reanchors(self):
        # TRIANGLE_FAN [a,b,c] SENT [d,e,f]: each run re-anchors slot 0 at
        # its own first vertex — the post-break fan must not reuse the
        # pre-break anchor vertex.
        vp, sc = (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8)
        a = [(-1.0, -1.0, 0.0, 1.0), (-1.0, 1.0, 0.0, 1.0),
             (1.0, -1.0, 0.0, 1.0)]
        b = [(0.0, -1.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0),
             (1.0, 1.0, 0.0, 1.0)]
        slots = a + [(0.5, 0.5, 0.0, 1.0)] + b
        stream = a + [None] + b
        job, runtime = self.execute(self.raster(
            [(p, None) for p in slots], vp, sc, topology=5, restarts={3}))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 2)
        expected = vn_golden.gfx_restart_coverage(
            stream, 5, vp, sc, 8, 8, True, 0)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_line_list_restart_splits_segments(self):
        # LINE_LIST [v0,v1] SENT [v2,v3]: the break splits the stream into
        # two independent two-vertex runs, each one Bresenham segment.
        # The five-record stream is not globally even-aligned.
        vp, sc = (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8)
        run1 = [(-1.0, -1.0, 0.0, 1.0), (1.0, -1.0, 0.0, 1.0)]
        run2 = [(-1.0, 1.0, 0.0, 1.0), (1.0, 1.0, 0.0, 1.0)]
        slots = run1 + [(0.5, 0.5, 0.0, 1.0)] + run2
        stream = run1 + [None] + run2
        job, runtime = self.execute(self.raster(
            [(p, None) for p in slots], vp, sc, topology=1, restarts={2}))
        stats = job.raster_stats[0]
        self.assertGreater(stats['records'], 0)
        expected = vn_golden.gfx_restart_coverage(
            stream, 1, vp, sc, 8, 8, True, 0)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_restart_incomplete_run_tail_is_dropped(self):
        # TRIANGLE_LIST [v0,v1,v2,v3] SENT: the post-break run has a
        # single leftover vertex that forms no complete triangle, so only
        # the first run's triangle emits.
        vp, sc = (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8)
        tri = [(-1.0, -1.0, 0.0, 1.0), (1.0, -1.0, 0.0, 1.0),
               (-1.0, 1.0, 0.0, 1.0)]
        # index3 is the sentinel placeholder (skipped); indices 4,5 are a
        # two-vertex run tail that forms no complete triangle.
        slots = tri + [(9.0, 9.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0),
                       (1.0, 1.0, 0.0, 1.0)]
        stream = tri + [None, (0.0, 1.0, 0.0, 1.0), (1.0, 1.0, 0.0, 1.0)]
        job, runtime = self.execute(self.raster(
            [(p, None) for p in slots], vp, sc, topology=3, restarts={3}))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 1)
        expected = vn_golden.gfx_restart_coverage(
            stream, 3, vp, sc, 8, 8, True, 0)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_instanced_strip_resets_at_instance_boundary(self):
        # instanceCount=2 TRIANGLE_STRIP: eight records are two independent
        # 4-vertex strips (instance_stride=4).  Without per-instance
        # assembly the sliding window emits cross-instance triangles;
        # with it each instance yields exactly its own two triangles.
        vp, sc = (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8)
        left = [(-1.0, -1.0, 0.0, 1.0), (-1.0, 1.0, 0.0, 1.0),
                (0.0, -1.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0)]
        right = [(0.0, -1.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0),
                 (1.0, -1.0, 0.0, 1.0), (1.0, 1.0, 0.0, 1.0)]
        slots = left + right
        job, runtime = self.execute(self.raster(
            [(p, None) for p in slots], vp, sc, topology=4,
            instance_stride=4))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 4)
        expected = (vn_golden.gfx_strip_coverage(left, vp, sc, 8, 8, True, 0)
                    | vn_golden.gfx_strip_coverage(right, vp, sc, 8, 8,
                                                   True, 0))
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_instanced_misaligned_per_instance_count_refuses(self):
        # per-instance vertexCount=4 TRIANGLE_LIST is malformed (4%3!=0);
        # each instance assembles independently so the draw refuses rather
        # than emit cross-instance triangles — even though the concatenated
        # stream's total could coincidentally align.
        slots = [((-1.0 + i * 0.1, -1.0 + (i % 2), 0.0, 1.0), None)
                 for i in range(12)]
        with self.assertRaises(ValueError):
            self.execute(self.raster(
                slots, (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8),
                topology=3, instance_stride=4))

    def test_instanced_triangle_list_groups_per_instance(self):
        # instanceCount=2 TRIANGLE_LIST, six aligned vertices per instance:
        # instance0 covers the bottom half, instance1 the top half.  Each
        # instance emits its own two triangles (four total) with no
        # primitive straddling the boundary — a concatenated grouping
        # would mix bottom/top vertices into cross-instance triangles.
        vp, sc = (0.0, 0.0, 8.0, 8.0, 0.0, 1.0), (0, 0, 8, 8)
        inst0 = [(-1.0, -1.0, 0.0, 1.0), (1.0, -1.0, 0.0, 1.0),
                 (-1.0, 0.0, 0.0, 1.0), (1.0, -1.0, 0.0, 1.0),
                 (1.0, 0.0, 0.0, 1.0), (-1.0, 0.0, 0.0, 1.0)]
        inst1 = [(-1.0, 0.0, 0.0, 1.0), (1.0, 0.0, 0.0, 1.0),
                 (-1.0, 1.0, 0.0, 1.0), (1.0, 0.0, 0.0, 1.0),
                 (1.0, 1.0, 0.0, 1.0), (-1.0, 1.0, 0.0, 1.0)]
        slots = inst0 + inst1   # two 6-vert instances, stride 6
        job, runtime = self.execute(self.raster(
            [(p, None) for p in slots], vp, sc, topology=3,
            instance_stride=6))
        stats = job.raster_stats[0]
        self.assertEqual(stats['triangles'], 4)
        cov = lambda v: (vn_golden.gfx_tri_coverage(v[:3], vp, sc, 8, 8,
                                                    True, 0)
                         | vn_golden.gfx_tri_coverage(v[3:], vp, sc, 8, 8,
                                                      True, 0))
        expected = cov(inst0) | cov(inst1)
        self.assertEqual(fragcoords(bytes(runtime.records)), expected)

    def test_strip_point_admission_refusals(self):
        # POINT_LIST needs >=1 vertex (count>=1 always true here); a
        # single-vertex LINE_STRIP yields zero segments but stays valid;
        # out-of-profile topologies still refuse.
        one = [((-0.5, -0.5, 0.0, 1.0), None)]
        job, runtime = self.execute(self.raster(one, topology=0))
        self.assertEqual(job.raster_stats[0]['records'], 1)
        job, runtime = self.execute(self.raster(one, topology=2))
        self.assertEqual(job.raster_stats[0]['records'], 0)
        tri = [((-1.0, -1.0, 0.0, 1.0), None),
               ((1.0, -1.0, 0.0, 1.0), None),
               ((-1.0, 1.0, 0.0, 1.0), None)]
        for bad in (6, 7):
            with self.subTest(topology=bad):
                with self.assertRaises(ValueError):
                    self.execute(self.raster(tri, topology=bad))
        # TRIANGLE_STRIP/FAN need >=3 vertices (count-2 primitives); a
        # two-vertex strip/fan has no complete triangle and refuses.
        two = [((-1.0, -1.0, 0.0, 1.0), None),
               ((1.0, -1.0, 0.0, 1.0), None)]
        for bad in (4, 5):
            with self.subTest(topology=bad, count=2):
                with self.assertRaises(ValueError):
                    self.execute(self.raster(two, topology=bad))

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
            Raster(good, **{**base, 'discard': 2}),
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
