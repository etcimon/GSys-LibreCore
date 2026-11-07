# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded typed clear patterns and exact per-record payload bounds."""
import struct
import unittest

import test_vn_images as image_fixture
from vn_transfer_executor import Transfer


class ClearTests(unittest.TestCase):
    def setUp(self):
        self.images = image_fixture.ImageTests()
        self.images.setUp()
        self.f, self.w, self.e = self.images.f, self.images.w, self.images.e

    def clear(self, color, ranges=None, declared=None):
        ranges = ranges or [self.w.structure('VkImageSubresourceRange', aspectMask=1,
            baseMipLevel=0, levelCount=0xFFFFFFFF, baseArrayLayer=0, layerCount=0xFFFFFFFF)]
        self.f.command('vkCmdClearColorImage', commandBuffer=self.f.CB,
            image=self.images.IMAGE, imageLayout=7, pColor={'uint32': list(color)},
            rangeCount=len(ranges) if declared is None else declared, pRanges=ranges)

    def record(self, color, **kwargs):
        self.f.begin()
        self.clear(color, **kwargs)
        self.f.end()

    @staticmethod
    def float_bits(*values):
        return struct.unpack('<4I', struct.pack('<4f', *values))

    def test_unorm_clear_preserves_padding_and_uses_small_pattern(self):
        self.images.create(initial_layout=7)
        base = self.f.owner.base
        self.f.state.aperture.write(base + 4096, b'P' * 256)
        self.record(self.float_bits(1, .5, 0, 1))
        job = self.f.enqueue()
        self.assertEqual([len(op.data) for op in job.operations], [4] * 4)
        self.f.drain()
        for row in range(4):
            self.assertEqual(self.f.state.aperture.read(base + 4096 + row * 64, 32),
                             b'\xff\x80\0\xff' * 8)
            self.assertEqual(self.f.state.aperture.read(base + 4128 + row * 64, 32),
                             b'P' * 32)

    def test_half_texels_use_pinned_float_conversion(self):
        self.images.create(fmt=97, initial_layout=7)  # R16G16B16A16_SFLOAT.
        self.record(self.float_bits(1, .5, -2, 0))
        self.f.enqueue()
        self.f.drain()
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 4096, 64),
                         struct.pack('<4e', 1, .5, -2, 0) * 8)

    def test_uint_texels_preserve_all_128_bits(self):
        self.images.create(fmt=107, initial_layout=7)  # R32G32B32A32_UINT.
        color = (1, 2, 3, 0xFEDCBA98)
        self.record(color)
        self.f.enqueue()
        self.f.drain()
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 4096, 128),
                         struct.pack('<4I', *color) * 8)

    def test_bgra_and_srgb_conversion(self):
        for fmt, color, expected in (
                (44, self.float_bits(1, .5, 0, 1), b'\0\x80\xff\xff'),
                (43, self.float_bits(.5, 0, 1, 1), b'\xbc\0\xff\xff')):
            self.images.create(fmt=fmt, initial_layout=7)
            self.record(color)
            self.f.enqueue()
            self.f.drain()
            self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 4096, 32),
                             expected * 8)
            self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.images.IMAGE)

    def test_remaining_mips_and_layers_clear_only_texel_rows(self):
        self.images.create(mips=2, layers=2, initial_layout=7)
        self.record(self.float_bits(1, 0, 0, 1))
        job = self.f.enqueue()
        self.assertEqual(len(job.operations), 12)
        self.f.drain()
        for layer in range(2):
            address = self.f.owner.base + 4096 + layer * 384 + 256
            self.assertEqual(self.f.state.aperture.read(address, 16), b'\xff\0\0\xff' * 4)
            self.assertEqual(self.f.state.aperture.read(address + 16, 48), b'\0' * 48)

    def test_chunk_smaller_than_texel_preserves_pattern_phase(self):
        color = bytes(range(16))
        self.e.transfers.chunk_bytes = 4
        job = self.e.transfers.enqueue(self.f.context, [
            Transfer('pattern', self.f.owner, 0, 32, data=color)])
        self.e.transfers.poll()
        self.assertEqual(job.position, 4)
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base, 4), color[:4])
        self.f.drain()
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base, 32), color * 2)

    def test_clear_count_cannot_read_neighboring_record_payload(self):
        self.images.create(initial_layout=7)
        self.f.begin()
        self.clear(self.float_bits(1, 0, 0, 1), declared=2)
        self.f.command('vkCmdUpdateBuffer', commandBuffer=self.f.CB, dstBuffer=self.f.BUFFER,
                       dstOffset=0, dataSize=64, pData=b'x' * 64)
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_update_subpayload_cannot_borrow_words_after_its_end(self):
        self.f.begin()
        self.f.command('vkCmdUpdateBuffer', commandBuffer=self.f.CB, dstBuffer=self.f.BUFFER,
                       dstOffset=0, dataSize=8, pData=b'abcd')
        self.f.fill()
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base, 8), b'\0' * 8)

    def test_payload_length_metadata_does_not_change_rtl_record_words(self):
        self.images.create(initial_layout=7)
        self.record(self.float_bits(1, 0, 0, 1))
        descriptor = self.f.front.cbd[self.f.front.idmap[self.f.CB]]
        record = descriptor['recs'][0]
        self.assertEqual(record['payload_words'], 9)
        without = {k: v for k, v in record.items() if k != 'payload_words'}
        self.assertEqual(self.e.golden.sess_rec_words(record),
                         self.e.golden.sess_rec_words(without))
        self.assertEqual(len(self.e.golden.sess_rec_words(record)), 16)

    def test_overlapping_ranges_and_malformed_patterns_reject(self):
        self.images.create(initial_layout=7)
        r = self.w.structure('VkImageSubresourceRange', aspectMask=1, baseMipLevel=0,
                             levelCount=1, baseArrayLayer=0, layerCount=1)
        self.record(self.float_bits(1, 0, 0, 1), ranges=[r, r])
        with self.assertRaises(ValueError):
            self.f.enqueue()
        for size, color in ((0, b'a'), (4, b''), (4, b'abc'), (3, b'ab')):
            with self.assertRaises(ValueError):
                self.e.transfers.enqueue(self.f.context, [
                    Transfer('pattern', self.f.owner, 0, size, data=color)])
        self.assertFalse(self.e.transfers.active)


if __name__ == '__main__':
    unittest.main()
