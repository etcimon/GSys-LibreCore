# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded fragment writeback: colour, optional late-z depth, bounded
UNORM8 RGBA blend; no multi-attachment scope."""
import struct
import unittest

import test_vn_transfers as transfer_fixture
import vn_golden
from vn_graphics_fetch import ATTR_STRIDE
from vn_graphics_writeback import Writeback, WritebackRuntime, WRITE_QUANTUM


def fsin_record(x, y):
    rec = bytearray(ATTR_STRIDE)
    struct.pack_into('<4f', rec, 0, x + 0.5, y + 0.5, 0.0, 1.0)
    return bytes(rec)


def fsin_record_z(x, y, z):
    rec = bytearray(ATTR_STRIDE)
    struct.pack_into('<4f', rec, 0, x + 0.5, y + 0.5, z, 1.0)
    return bytes(rec)


def color_record(rgba):
    rec = bytearray(ATTR_STRIDE)
    struct.pack_into('<4f', rec, 0, *rgba)
    return bytes(rec)


def color_record_mrt(c0, c1):
    # two fragment outputs: loc0 at byte 0, loc1 at byte 16 (location*16)
    rec = bytearray(ATTR_STRIDE)
    struct.pack_into('<4f', rec, 0, *c0)
    struct.pack_into('<4f', rec, 16, *c1)
    return bytes(rec)


def color_record_dead(rgba, dead):
    # FS-out record: loc0 colour at byte 0; slot-8 flags word at byte 132
    # carries bit0 = discarded for fs_late (kill/demote) modules.
    rec = bytearray(color_record(rgba))
    struct.pack_into('<I', rec, 132, 1 if dead else 0)
    return bytes(rec)


class WritebackTests(unittest.TestCase):
    def setUp(self):
        self.f = transfer_fixture.TransferTests()
        self.f.setUp()
        self.e, self.executor, self.context = (
            self.f.engine, self.f.executor, self.f.context)
        self.owner, self.state = self.f.owner, self.f.state
        self.model = self.executor.execution.model
        self.bpp_table = self.model.img_fmt_tables()[2]

    def drain(self):
        for _ in range(512):
            if not self.executor.active:
                return
            self.executor.poll()
        self.fail('bounded writeback cohort did not drain')

    def fmt_id(self, vkfmt):
        did = vn_golden.img_fmt_id(self.model, vkfmt)
        self.assertNotEqual(did, 0xFF)
        return did

    def op(self, pixels, colors, *, vkfmt=37, width=8, height=8,
           pitch=None, offset=0, location=0, owner=None):
        did = self.fmt_id(vkfmt)
        bpp = self.bpp_table[did]
        if pitch is None:
            pitch = ((width * bpp + 63) // 64) * 64
        inputs = b''.join(fsin_record(x, y) for x, y in pixels)
        cols = b''.join(color_record(c) for c in colors)
        return Writeback(inputs, cols, len(pixels), owner or self.owner,
                         offset, pitch, width, height, did, location)

    def test_rgba32f_writes_raw_fragments(self):
        # VK_FORMAT_R32G32B32A32_SFLOAT = 109 -> raw f32 texels
        did = self.fmt_id(109)
        self.assertEqual(self.bpp_table[did], 16)
        pixels = [(0, 0), (3, 2), (7, 7)]
        colors = [(1.0, 0.5, -0.25, 1.0)] * 3
        pitch = 64 * 4  # 16bpp * 16 px rows padded to 64
        job = self.executor.enqueue(self.context, [self.op(
            pixels, colors, vkfmt=109, pitch=pitch)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.writeback_stats[0]
        self.assertEqual((stats['records'], stats['dropped']), (3, 0))
        data = self.state.aperture.read(self.owner.base, pitch * 8)
        expected = vn_golden.img_clear_texel(self.model, did,
                                             struct.unpack('<4I',
                                             struct.pack('<4f', *colors[0])))
        for px, py in pixels:
            got = data[py * pitch + px * 16: py * pitch + px * 16 + 16]
            self.assertEqual(got, expected)
        # untouched texel stays zero
        self.assertEqual(data[1 * pitch + 1 * 16: 1 * pitch + 1 * 16 + 16],
                         b'\0' * 16)
        self.assertEqual(self.owner.work_refs, 0)

    def test_rgba8unorm_converts_and_bounds_drop(self):
        did = self.fmt_id(37)          # R8G8B8A8_UNORM
        self.assertEqual(self.bpp_table[did], 4)
        pixels = [(1, 1), (9, 1), (-1, 0), (0, 99)]
        colors = [(1.0, 0.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0),
                  (0.0, 0.0, 1.0, 1.0), (1.0, 1.0, 1.0, 1.0)]
        pitch = 64
        job = self.executor.enqueue(self.context, [self.op(
            pixels, colors, vkfmt=37, pitch=pitch)])
        runtime = job.runtimes[0]
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.writeback_stats[0]
        self.assertEqual((stats['records'], stats['dropped']), (1, 3))
        data = self.state.aperture.read(self.owner.base, pitch * 8)
        texel = vn_golden.img_clear_texel(
            self.model, did, struct.unpack('<4I', struct.pack(
                '<4f', 1.0, 0.0, 0.0, 1.0)))
        self.assertEqual(data[1 * pitch + 1 * 4: 1 * pitch + 1 * 4 + 4],
                         texel)
        # out-of-bounds fragments wrote nothing around the valid texel
        self.assertEqual(data[1 * pitch + 2 * 4: 1 * pitch + 2 * 4 + 4],
                         b'\0' * 4)
        self.assertEqual(self.owner.work_refs, 0)

    def test_location_selects_color_slot(self):
        did = self.fmt_id(109)
        rec = bytearray(ATTR_STRIDE)
        struct.pack_into('<4f', rec, 0, 1.5, 1.5, 0.0, 1.0)   # FragCoord
        struct.pack_into('<4f', rec, 16 * 1, 9.0, 9.0, 9.0, 9.0)  # loc1
        pitch = 64 * 4
        op = Writeback(bytes(rec), bytes(rec), 1, self.owner, 0, pitch,
                       8, 8, did, 1)
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'done')
        data = self.state.aperture.read(self.owner.base, pitch * 8)
        got = data[1 * pitch + 1 * 16: 1 * pitch + 1 * 16 + 16]
        expected = vn_golden.img_clear_texel(
            self.model, did, struct.unpack('<4I', struct.pack(
                '<4f', 9.0, 9.0, 9.0, 9.0)))
        self.assertEqual(got, expected)

    def _depth_op(self, pixels, zin, *, compare=1, write=1, d_off=2048):
        """RGBA32F colour at offset 0 + float32 depth (pitch 32) at d_off."""
        did = self.fmt_id(109)
        inputs = b''.join(fsin_record_z(x, y, z)
                          for (x, y), z in zip(pixels, zin))
        cols = b''.join(color_record((1.0, 0.0, 0.0, 1.0)) for _ in pixels)
        depth = (self.owner, d_off, 32, compare, write)
        return Writeback(inputs, cols, len(pixels), self.owner, 0,
                         64 * 4, 8, 8, did, 0, depth)

    def _seed_depth(self, stored):
        # stored: {(px,py): float}; every other texel stays 1.0
        buf = bytearray(struct.pack('<64f', *([1.0] * 64)))
        for (px, py), z in stored.items():
            struct.pack_into('<f', buf, py * 32 + px * 4, z)
        self.state.aperture.write(self.owner.base + 2048, bytes(buf))

    def _depth_at(self, px, py):
        return struct.unpack('<f', self.state.aperture.read(
            self.owner.base + 2048 + py * 32 + px * 4, 4))[0]

    def test_depth_compare_gates_and_writes(self):
        # LESS against stored depth: (1,1) 0.25<0.5 pass, (2,2) 0.75<0.5
        # fail, (3,3) 0.9<1.0 pass.  A fail drops BOTH colour and depth.
        self._seed_depth({(1, 1): 0.5, (2, 2): 0.5})
        pixels = [(1, 1), (2, 2), (3, 3)]
        zin = [0.25, 0.75, 0.9]
        job = self.executor.enqueue(self.context, [
            self._depth_op(pixels, zin)])
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.writeback_stats[0]
        self.assertEqual((stats['records'], stats['dropped']), (2, 1))
        data = self.state.aperture.read(self.owner.base, 64 * 4 * 8)
        expected = vn_golden.img_clear_texel(
            self.model, self.fmt_id(109),
            struct.unpack('<4I', struct.pack('<4f', 1.0, 0.0, 0.0, 1.0)))
        for px, py in ((1, 1), (3, 3)):
            got = data[py * 256 + px * 16: py * 256 + px * 16 + 16]
            self.assertEqual(got, expected)
        # the failed fragment left its colour texel untouched
        self.assertEqual(data[2 * 256 + 2 * 16: 2 * 256 + 2 * 16 + 16],
                         b'\0' * 16)
        f32 = lambda v: struct.unpack('<f', struct.pack('<f', v))[0]
        self.assertEqual([self._depth_at(*p) for p in pixels],
                         [f32(v) for v in (0.25, 0.5, 0.9)])
        self.assertEqual(self._depth_at(0, 0), 1.0)
        self.assertEqual(self.owner.work_refs, 0)

    def test_depth_write_disabled_is_read_only(self):
        # write_enable=0: compare still gates colour, stored depth kept.
        self._seed_depth({(1, 1): 0.5})
        pixels = [(1, 1)]
        job = self.executor.enqueue(self.context, [
            self._depth_op(pixels, [0.25], write=0)])
        self.drain()
        self.assertEqual(job.state, 'done')
        data = self.state.aperture.read(self.owner.base, 64 * 4 * 8)
        got = data[1 * 256 + 1 * 16: 1 * 256 + 1 * 16 + 16]
        self.assertNotEqual(got, b'\0' * 16)      # colour written
        self.assertEqual(self._depth_at(1, 1), 0.5)  # depth untouched

    def test_mrt_depth_gates_all_targets_atomically(self):
        # MRT + late-z: ONE Writeback carries the primary (loc0) plus an
        # extra (loc1) target under a SINGLE depth test — a fragment
        # either writes every colour attachment and depth or none.  LESS
        # against stored depth: (1,1) 0.25<0.5 pass, (2,2) 0.75<0.5 fail,
        # (3,3) 0.9<1.0 pass.
        did = self.fmt_id(109)                    # RGBA32F, bpp 16
        pixels = [(1, 1), (2, 2), (3, 3)]
        zin = [0.25, 0.75, 0.9]
        self._seed_depth({(1, 1): 0.5, (2, 2): 0.5})
        inputs = b''.join(fsin_record_z(x, y, z)
                          for (x, y), z in zip(pixels, zin))
        cols = b''.join(color_record_mrt((1.0, 0.0, 0.0, 1.0),
                                         (0.0, 1.0, 0.0, 1.0))
                        for _ in pixels)
        depth = (self.owner, 2048, 32, 1, 1)      # LESS, write_enable
        # primary colour: offset 0 pitch 128; extra: offset 1024 pitch 128
        extra = (self.owner, 1024, 128, did, 1, 15)
        op = Writeback(inputs, cols, len(pixels), self.owner, 0, 128, 8, 8,
                       did, 0, depth, None, 15, None, None, (extra,))
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.writeback_stats[0]
        self.assertEqual((stats['records'], stats['dropped']), (2, 1))
        c0tex = vn_golden.img_clear_texel(
            self.model, did, struct.unpack('<4I', struct.pack('<4f',
                1.0, 0.0, 0.0, 1.0)))
        c1tex = vn_golden.img_clear_texel(
            self.model, did, struct.unpack('<4I', struct.pack('<4f',
                0.0, 1.0, 0.0, 1.0)))
        for off, want in ((0, c0tex), (1024, c1tex)):
            data = self.state.aperture.read(self.owner.base + off, 128 * 8)
            for px, py in ((1, 1), (3, 3)):
                self.assertEqual(
                    data[py * 128 + px * 16: py * 128 + px * 16 + 16],
                    want, 'target@%d (%d,%d)' % (off, px, py))
            # the depth-failed fragment left BOTH targets untouched
            self.assertEqual(data[2 * 128 + 2 * 16: 2 * 128 + 2 * 16 + 16],
                             b'\0' * 16)
        # depth written exactly once for the passing fragments
        f32 = lambda v: struct.unpack('<f', struct.pack('<f', v))[0]
        self.assertEqual([self._depth_at(*p) for p in pixels],
                         [f32(v) for v in (0.25, 0.5, 0.9)])
        self.assertEqual(self.owner.work_refs, 0)

    def test_fs_kill_flag_discards_color_and_depth(self):
        # FS-out slot-8 flags bit0 marks a lane dead (OpKill /
        # TerminateInvocation / DemoteToHelperInvocation in an fs_late
        # module).  The flagged fragment writes no colour AND no depth,
        # even though its depth test would pass — discard precedes the
        # whole writeback.  (1,1) and (3,3) live; (2,2) killed.
        did = self.fmt_id(109)                    # RGBA32F, bpp 16
        self._seed_depth({(2, 2): 0.5})
        pixels = [(1, 1), (2, 2), (3, 3)]
        zin = [0.25, 0.4, 0.9]
        inputs = b''.join(fsin_record_z(x, y, z)
                          for (x, y), z in zip(pixels, zin))
        cols = b''.join(
            color_record_dead((1.0, 0.0, 0.0, 1.0), dead=(k == 1))
            for k in range(len(pixels)))
        depth = (self.owner, 2048, 32, 1, 1)      # LESS, write_enable
        op = Writeback(inputs, cols, len(pixels), self.owner, 0, 128, 8, 8,
                       did, 0, depth)
        job = self.executor.enqueue(self.context, [op])
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.writeback_stats[0]
        self.assertEqual((stats['records'], stats['dropped']), (2, 1))
        data = self.state.aperture.read(self.owner.base, 128 * 8)
        expected = vn_golden.img_clear_texel(
            self.model, did,
            struct.unpack('<4I', struct.pack('<4f', 1.0, 0.0, 0.0, 1.0)))
        for px, py in ((1, 1), (3, 3)):
            self.assertEqual(
                data[py * 128 + px * 16: py * 128 + px * 16 + 16],
                expected, 'live fragment (%d,%d)' % (px, py))
        # the killed fragment left colour AND depth untouched
        self.assertEqual(data[2 * 128 + 2 * 16: 2 * 128 + 2 * 16 + 16],
                         b'\0' * 16)
        f32 = lambda v: struct.unpack('<f', struct.pack('<f', v))[0]
        self.assertEqual([self._depth_at(*p) for p in pixels],
                         [f32(v) for v in (0.25, 0.5, 0.9)])
        self.assertEqual(self.owner.work_refs, 0)

    def test_depth_admission_refusals(self):
        good = self._depth_op([(0, 0)], [0.5])
        base = dict(inputs=good.inputs, colors=good.colors, count=1,
                    owner=self.owner, offset=0, pitch=64 * 4, width=8,
                    height=8, fmt=good.fmt)
        bad_depth = [
            ('short', (self.owner, 2048, 32, 1)),
            ('long', (self.owner, 2048, 32, 1, 1, 0)),
            ('neg_off', (self.owner, -1, 32, 1, 1)),
            ('zero_pitch', (self.owner, 2048, 0, 1, 1)),
            ('thin_pitch', (self.owner, 2048, 16, 1, 1)),  # < width*4
            ('bad_op', (self.owner, 2048, 32, 9, 1)),
            ('bad_write', (self.owner, 2048, 32, 1, 2)),
            ('forged', (object(), 2048, 32, 1, 1)),
        ]
        for _name, depth in bad_depth:
            with self.assertRaises((ValueError, KeyError, AttributeError)):
                WritebackRuntime(self.executor, self.context,
                                 Writeback(**base, depth=depth))

    def _bounds_op(self, pixels, zin, *, bounds, depth=None):
        """RGBA32F colour + optional depth + a depth-bounds window."""
        did = self.fmt_id(109)
        inputs = b''.join(fsin_record_z(x, y, z)
                          for (x, y), z in zip(pixels, zin))
        cols = b''.join(color_record((1.0, 0.0, 0.0, 1.0)) for _ in pixels)
        return Writeback(inputs, cols, len(pixels), self.owner, 0,
                         64 * 4, 8, 8, did, 0, depth, None, 15, None,
                         bounds)

    def test_depth_bounds_window_rejects_outside_fragments(self):
        # bounds=[0.3,0.7] with no depth attachment: z=0.25 drops below
        # min, z=0.5 keeps, z=0.75 drops above max.  Colour only.
        pixels = [(0, 0), (1, 0), (2, 0)]
        zin = [0.25, 0.5, 0.75]
        job = self.executor.enqueue(self.context, [
            self._bounds_op(pixels, zin, bounds=(0.3, 0.7))])
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.writeback_stats[0]
        self.assertEqual((stats['records'], stats['dropped']), (1, 2))
        data = self.state.aperture.read(self.owner.base, 64 * 4 * 8)
        expected = vn_golden.img_clear_texel(
            self.model, self.fmt_id(109),
            struct.unpack('<4I', struct.pack('<4f', 1.0, 0.0, 0.0, 1.0)))
        # only (1,0) is written; the out-of-window texels stay untouched
        for px, want in ((0, b'\0' * 16), (1, expected), (2, b'\0' * 16)):
            got = data[0 * 256 + px * 16: 0 * 256 + px * 16 + 16]
            self.assertEqual(got, want)
        self.assertEqual(self.owner.work_refs, 0)

    def test_depth_bounds_composes_with_depth_test(self):
        # bounds=[0.4,0.9] AND LESS depth (stored 0.6): a fragment must
        # pass BOTH gates.  z=0.5 passes both -> write; z=0.3 fails the
        # window (depth would pass); z=0.7 passes the window but fails
        # the LESS compare.
        pixels = [(0, 0), (1, 0), (2, 0)]
        zin = [0.5, 0.3, 0.7]
        self._seed_depth({p: 0.6 for p in pixels})
        depth = (self.owner, 2048, 32, 1, 1)   # LESS, write
        job = self.executor.enqueue(self.context, [
            self._bounds_op(pixels, zin, bounds=(0.4, 0.9), depth=depth)])
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.writeback_stats[0]
        self.assertEqual((stats['records'], stats['dropped']), (1, 2))
        data = self.state.aperture.read(self.owner.base, 64 * 4 * 8)
        expected = vn_golden.img_clear_texel(
            self.model, self.fmt_id(109),
            struct.unpack('<4I', struct.pack('<4f', 1.0, 0.0, 0.0, 1.0)))
        for px, want in ((0, expected), (1, b'\0' * 16), (2, b'\0' * 16)):
            got = data[0 * 256 + px * 16: 0 * 256 + px * 16 + 16]
            self.assertEqual(got, want)
        f32 = lambda v: struct.unpack('<f', struct.pack('<f', v))[0]
        # only (0,0) committed depth=0.5; the dropped texels keep 0.6
        self.assertEqual([self._depth_at(*p) for p in pixels],
                         [f32(v) for v in (0.5, 0.6, 0.6)])

    def test_depth_bounds_admission_refusals(self):
        good = self._bounds_op([(0, 0)], [0.5], bounds=(0.0, 1.0))
        base = dict(inputs=good.inputs, colors=good.colors, count=1,
                    owner=self.owner, offset=0, pitch=64 * 4, width=8,
                    height=8, fmt=good.fmt)
        for bounds in ((0.7, 0.3), (float('nan'), 0.5),
                       (0.0,), (0.0, 0.5, 1.0), 'x'):
            with self.assertRaises(ValueError):
                WritebackRuntime(self.executor, self.context,
                                 Writeback(**base, bounds=bounds))

    def _blend_op(self, pixels, colors, *, blend=None, write_mask=15,
                  logic_op=None, vkfmt=37, width=8, height=8, pitch=64,
                  offset=0):
        did = self.fmt_id(vkfmt)
        inputs = b''.join(fsin_record(x, y) for x, y in pixels)
        cols = b''.join(color_record(c) for c in colors)
        return Writeback(inputs, cols, len(pixels), self.owner, offset,
                         pitch, width, height, did, 0, None, blend,
                         write_mask, logic_op)

    def _seed_unorm8(self, texels, pitch=64):
        # texels: {(px,py): 4-byte UNORM8 RGBA}; every other texel stays 0
        buf = bytearray(pitch * 8)
        for (px, py), b in texels.items():
            buf[py * pitch + px * 4: py * pitch + px * 4 + 4] = b
        self.state.aperture.write(self.owner.base, bytes(buf))

    def _unorm8_at(self, px, py, pitch=64):
        return self.state.aperture.read(
            self.owner.base + py * pitch + px * 4, 4)

    def test_blend_src_alpha_over_dst(self):
        # SRC_ALPHA/1M_SRC_ALPHA colour + ONE/ZERO alpha, ADD.  dst texel
        # [200,100,50,255] dequantizes u8*K255; src (0.5,0,0,0.5).
        self._seed_unorm8({(1, 1): bytes([200, 100, 50, 255])})
        blend = (6, 7, 0, 1, 0, 0, 15, 0, 0, 0, 0)
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(1, 1)], [(0.5, 0.0, 0.0, 0.5)], blend=blend)])
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.writeback_stats[0]['records'], 1)
        # oracle: [164,50,25,128] -> 0x801932a4
        self.assertEqual(self._unorm8_at(1, 1),
                         bytes([164, 50, 25, 128]))
        self.assertEqual(self._unorm8_at(2, 2), b'\0' * 4)
        self.assertEqual(self.owner.work_refs, 0)

    def test_blend_over_cleared_black(self):
        # classic alpha-over on a cleared (0,0,0,0) target.
        blend = (6, 7, 0, 1, 0, 0, 15, 0, 0, 0, 0)
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(0, 0), (3, 3)], [(1.0, 0.0, 0.0, 0.5)] * 2, blend=blend)])
        self.drain()
        self.assertEqual(job.state, 'done')
        # src.rgb*0.5 + dst*0.5 = [0.5,0,0] -> [128,0,0]; alpha=0.5 -> 128
        for px, py in ((0, 0), (3, 3)):
            self.assertEqual(self._unorm8_at(px, py),
                             bytes([128, 0, 0, 128]))
        self.assertEqual(self.owner.work_refs, 0)

    def test_blend_write_mask_keeps_dst_channel(self):
        # mask=7 enables RGB, disables alpha: the alpha byte keeps dst.
        self._seed_unorm8({(1, 1): bytes([200, 100, 50, 255])})
        blend = (6, 7, 0, 1, 0, 0, 7, 0, 0, 0, 0)
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(1, 1)], [(0.5, 0.0, 0.0, 0.5)], blend=blend)])
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self._unorm8_at(1, 1),
                         bytes([164, 50, 25, 255]))
        self.assertEqual(self.owner.work_refs, 0)

    def test_blend_bgra_permutation(self):
        # device fmt 4 (VK_FORMAT_B8G8R8A8_UNORM) stores bytes [B,G,R,A].
        # dst [200,100,50,255] = B=200,G=100,R=50,A=255; blend src
        # (0.5,0,0,0.5) SRC_ALPHA/1M_SRC_ALPHA + ONE/ZERO alpha must
        # permute through the component map and land logical R at byte 2.
        self._seed_unorm8({(1, 1): bytes([200, 100, 50, 255])})
        blend = (6, 7, 0, 1, 0, 0, 15, 0, 0, 0, 0)
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(1, 1)], [(0.5, 0.0, 0.0, 0.5)], blend=blend, vkfmt=44)])
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.writeback_stats[0]['records'], 1)
        # oracle: logical (R,G,B,A)=(89,50,100,128) -> BGRA bytes [100,50,89,128]
        self.assertEqual(self._unorm8_at(1, 1),
                         bytes([100, 50, 89, 128]))
        self.assertEqual(self.owner.work_refs, 0)

    def test_write_mask_keeps_dst_channels(self):
        # standalone colourWriteMask=7 (RGB on, alpha off), blendEnable=0:
        # src (1,0,0,1) -> [255,0,0,255] but the alpha byte keeps dst=200.
        self._seed_unorm8({(1, 1): bytes([200, 100, 50, 200])})
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(1, 1)], [(1.0, 0.0, 0.0, 1.0)], write_mask=7)])
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.writeback_stats[0]['records'], 1)
        self.assertEqual(self._unorm8_at(1, 1),
                         bytes([255, 0, 0, 200]))
        self.assertEqual(self.owner.work_refs, 0)

    def test_write_mask_bgra_keeps_dst_channel(self):
        # BGRA (fmt 4): mask=7 clears the alpha bit; alpha sits at byte 3
        # in both RGBA and BGRA storage so it still keeps dst=200, while
        # the permuted RGB bytes come from src.
        self._seed_unorm8({(1, 1): bytes([200, 100, 50, 200])})
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(1, 1)], [(1.0, 0.0, 0.0, 1.0)], write_mask=7, vkfmt=44)])
        self.drain()
        self.assertEqual(job.state, 'done')
        # src logical (R,G,B,A)=(1,0,0,1)->BGRA bytes [B,G,R,A]=[0,0,255,255];
        # alpha masked -> keeps dst byte3=200 => [0,0,255,200]
        self.assertEqual(self._unorm8_at(1, 1),
                         bytes([0, 0, 255, 200]))
        self.assertEqual(self.owner.work_refs, 0)

    def test_write_mask_format_refusal(self):
        # writeMask<15 on a non-UNORM8 format (vkfmt=109 -> RGBA32F) has
        # no byte-merge oracle: must refuse at admission.
        op = self._blend_op([(0, 0)], [(1, 1, 1, 1)], write_mask=7,
                            vkfmt=109)
        with self.assertRaises(ValueError):
            WritebackRuntime(self.executor, self.context, op)
        # writeMask=15 (unmasked) on the same format stays admitted.
        ok = self._blend_op([(0, 0)], [(1, 1, 1, 1)], write_mask=15,
                            vkfmt=109)
        WritebackRuntime(self.executor, self.context, ok)

    def test_logicop_xor_and_and(self):
        # logicOp on UNORM8 bytes: XOR(6) src^dst, AND(1) src&dst per
        # channel.  dst [200,100,50,255], src (1,0,0,1)->[255,0,0,255].
        self._seed_unorm8({(1, 1): bytes([200, 100, 50, 255])})
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(1, 1)], [(1.0, 0.0, 0.0, 1.0)], logic_op=6)])
        self.drain()
        self.assertEqual(job.state, 'done')
        # XOR: [255^200, 0^100, 0^50, 255^255] = [55,100,50,0]
        self.assertEqual(self._unorm8_at(1, 1), bytes([55, 100, 50, 0]))
        self.assertEqual(self.owner.work_refs, 0)

    def test_logicop_and_keeps_dst_bits(self):
        self._seed_unorm8({(1, 1): bytes([200, 100, 50, 255])})
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(1, 1)], [(1.0, 0.0, 0.0, 1.0)], logic_op=1)])
        self.drain()
        self.assertEqual(job.state, 'done')
        # AND: [255&200, 0&100, 0&50, 255&255] = [200,0,0,255]
        self.assertEqual(self._unorm8_at(1, 1), bytes([200, 0, 0, 255]))
        self.assertEqual(self.owner.work_refs, 0)

    def test_logicop_write_mask_and_format_bounds(self):
        # logicOp composes with writeMask: mask=7 clears alpha -> dst byte3
        # kept even though XOR would have produced 0 there.
        self._seed_unorm8({(1, 1): bytes([200, 100, 50, 255])})
        job = self.executor.enqueue(self.context, [self._blend_op(
            [(1, 1)], [(1.0, 0.0, 0.0, 1.0)], logic_op=6, write_mask=7)])
        self.drain()
        self.assertEqual(job.state, 'done')
        # XOR RGB [55,100,50] + dst alpha 255 -> [55,100,50,255]
        self.assertEqual(self._unorm8_at(1, 1), bytes([55, 100, 50, 255]))
        self.assertEqual(self.owner.work_refs, 0)
        # logicOp on a non-UNORM8 format refuses at admission.
        bad = self._blend_op([(0, 0)], [(1, 1, 1, 1)], logic_op=6, vkfmt=109)
        with self.assertRaises(ValueError):
            WritebackRuntime(self.executor, self.context, bad)

    def test_blend_admission_refusals(self):
        good = self._blend_op([(0, 0)], [(1, 1, 1, 1)],
                              blend=(1, 0, 0, 1, 0, 0, 15, 0, 0, 0, 0))
        base = dict(inputs=good.inputs, colors=good.colors, count=1,
                    owner=self.owner, offset=0, pitch=64, width=8,
                    height=8, fmt=good.fmt)
        bad_blend = [
            ('short', (1, 0, 0, 1, 0, 0, 15, 0, 0, 0)),
            ('long', (1, 0, 0, 1, 0, 0, 15, 0, 0, 0, 0, 0)),
            ('bad_sf', (15, 0, 0, 1, 0, 0, 15, 0, 0, 0, 0)),
            ('bad_cop', (1, 0, 5, 1, 0, 0, 15, 0, 0, 0, 0)),
            ('bad_mask', (1, 0, 0, 1, 0, 0, 16, 0, 0, 0, 0)),
            ('neg_k', (1, 0, 0, 1, 0, 0, 15, -1, 0, 0, 0)),
            ('float_k', (1, 0, 0, 1, 0, 0, 15, 0.5, 0, 0, 0)),
            ('not_tuple', [1, 0, 0, 1, 0, 0, 15, 0, 0, 0, 0]),
        ]
        for _name, blend in bad_blend:
            with self.assertRaises(ValueError):
                WritebackRuntime(self.executor, self.context,
                                 Writeback(**base, blend=blend))
        # blend on a non-UNORM8-RGBA format must refuse (bounded profile)
        rgba32f = Writeback(good.inputs, good.colors, 1, self.owner, 0,
                            64 * 4, 8, 8, self.fmt_id(109), 0, None,
                            (1, 0, 0, 1, 0, 0, 15, 0, 0, 0, 0))
        with self.assertRaises(ValueError):
            WritebackRuntime(self.executor, self.context, rgba32f)

    def test_multi_turn_and_extent_bounds(self):
        count = WRITE_QUANTUM + 8
        did = self.fmt_id(109)
        pixels = [(i % 8, (i // 8) % 8) for i in range(count)]
        colors = [(0.25, 0.5, 0.75, 1.0)] * count
        pitch = 64 * 4
        job = self.executor.enqueue(self.context, [self.op(
            pixels, colors, vkfmt=109, pitch=pitch)])
        self.drain()
        self.assertEqual(job.state, 'done')
        stats = job.writeback_stats[0]
        self.assertEqual(stats['records'], count)
        self.assertEqual(stats['steps'], count)
        # offset near the owner end must refuse the whole operation
        bad = Writeback(b''.join(fsin_record(0, 0) for _ in range(2)),
                        b''.join(color_record((1, 1, 1, 1)) for _ in range(2)),
                        2, self.owner, self.owner.size - 8, 64, 8, 8, did)
        with self.assertRaises((ValueError, KeyError)):
            WritebackRuntime(self.executor, self.context, bad)
        self.assertEqual(self.owner.work_refs, 0)

    def test_admission_refusals(self):
        good_in = fsin_record(0, 0)
        good_col = color_record((1, 1, 1, 1))
        did = self.fmt_id(109)
        base = dict(inputs=good_in, colors=good_col, count=1,
                    owner=self.owner, offset=0, pitch=64, width=8,
                    height=8, fmt=did)
        bad = [
            Writeback(good_in * 2, good_col, 1, self.owner, 0, 64, 8, 8,
                      did),                      # input/output size mismatch
            Writeback(good_in[:-4], good_col[:-4], 1, self.owner, 0, 64, 8,
                      8, did),                    # truncated records
            Writeback(good_in, good_col, 0, self.owner, 0, 64, 8, 8, did),
            Writeback(good_in, good_col, 1, self.owner, 0, 0, 8, 8, did),
            Writeback(good_in, good_col, 1, self.owner, 0, 64, 0, 8, did),
            Writeback(good_in, good_col, 1, self.owner, 0, 64, 8, 8, 16),
            Writeback(good_in, good_col, 1, self.owner, 0, 64, 8, 8, did,
                      8),                          # location out of range
        ]
        for op in bad:
            with self.assertRaises(ValueError):
                WritebackRuntime(self.executor, self.context, op)
        # unbacked/forged owner must refuse through _extent
        forged = Writeback(good_in, good_col, 1, object(), 0, 64, 8, 8,
                           did)
        with self.assertRaises((ValueError, KeyError, AttributeError)):
            WritebackRuntime(self.executor, self.context, forged)


if __name__ == '__main__':
    unittest.main()
