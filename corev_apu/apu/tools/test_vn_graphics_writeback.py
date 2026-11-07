# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded fragment writeback; no blend, depth or multi-attachment scope."""
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


def color_record(rgba):
    rec = bytearray(ATTR_STRIDE)
    struct.pack_into('<4f', rec, 0, *rgba)
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
