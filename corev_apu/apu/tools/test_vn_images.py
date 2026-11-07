# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Real recorded image regions, padded rows, shared leases and fail-closed bounds."""
import unittest

import test_vn_replay as replay_fixture


class ImageTests(unittest.TestCase):
    IMAGE, SECOND = 0x700000007000, 0x700010007001

    def setUp(self):
        self.f = replay_fixture.ReplayTests()
        self.f.native_profile = getattr(self, 'native_profile', False)
        self.f.setUp()
        self.w, self.e = self.f.wire, self.f.engine

    def create(self, handle=None, *, offset=4096, mips=1, layers=1, fmt=37,
               usage=3, initial_layout=0):
        handle = handle or self.IMAGE
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=handle,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0,
                imageType=1, format=fmt,
                extent=self.w.structure('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=mips, arrayLayers=layers, samples=1, tiling=0, usage=usage,
                sharingMode=0, queueFamilyIndexCount=0, pQueueFamilyIndices=[],
                initialLayout=initial_layout))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=handle,
                       memory=self.w.MEMORY, memoryOffset=offset)

    def region(self, *, buffer=0, row=0, stride=0, mip=0, layer=0, layers=1,
               x=0, y=0, width=3, height=2, aspect=1):
        return self.w.structure('VkBufferImageCopy', bufferOffset=buffer,
            bufferRowLength=row, bufferImageHeight=stride,
            imageSubresource=self.w.structure('VkImageSubresourceLayers',
                aspectMask=aspect, mipLevel=mip, baseArrayLayer=layer, layerCount=layers),
            imageOffset=self.w.structure('VkOffset3D', x=x, y=y, z=0),
            imageExtent=self.w.structure('VkExtent3D', width=width, height=height, depth=1))

    def copy(self, regions=None, *, readback=False, image=None, layout=1):
        values = dict(commandBuffer=self.f.CB, regionCount=len(regions or [0]),
                      pRegions=regions or [self.region()])
        if readback:
            self.f.command('vkCmdCopyImageToBuffer', **values,
                srcImage=image or self.IMAGE, srcImageLayout=layout, dstBuffer=self.f.BUFFER)
        else:
            self.f.command('vkCmdCopyBufferToImage', **values,
                srcBuffer=self.f.BUFFER, dstImage=image or self.IMAGE, dstImageLayout=layout)

    def test_round_trip_preserves_image_and_buffer_row_padding(self):
        self.create(initial_layout=1)
        base = self.f.owner.base
        source = bytes(range(64))
        self.f.state.aperture.write(base, source)
        self.f.state.aperture.write(base + 4096, b'P' * 256)
        self.f.begin()
        self.copy([self.region(row=5, x=1, y=1)])
        self.copy([self.region(buffer=512, row=7, x=1, y=1)], readback=True)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual(len(job.operations), 4)
        self.f.drain()
        memory = self.f.state.aperture
        self.assertEqual(memory.read(base + 4096 + 68, 12), source[:12])
        self.assertEqual(memory.read(base + 4096 + 132, 12), source[20:32])
        self.assertEqual(memory.read(base + 4096 + 80, 48), b'P' * 48)
        self.assertEqual(memory.read(base + 512, 12), source[:12])
        self.assertEqual(memory.read(base + 540, 12), source[20:32])
        self.assertEqual(memory.read(base + 524, 16), b'\0' * 16)

    def test_array_layer_and_mip_offsets_match_pinned_layout(self):
        self.create(mips=2, layers=2, initial_layout=1)
        base = self.f.owner.base
        self.f.state.aperture.write(base, b'array-row-0!array-row-1!')
        self.f.begin()
        self.copy([self.region(mip=1, layer=1)])
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        # layer bytes=256+128; mip1 begins at256, within array layer1.
        target = base + 4096 + 384 + 256
        self.assertEqual(self.f.state.aperture.read(target, 12), b'array-row-0!')
        self.assertEqual(self.f.state.aperture.read(target + 64, 12), b'array-row-1!')

    def test_image_to_image_copy_preserves_subrectangles(self):
        self.create(initial_layout=1)
        self.create(self.SECOND, offset=4352, initial_layout=1)
        base = self.f.owner.base
        self.f.state.aperture.write(base + 4096, bytes(range(256)))
        sub = self.w.structure('VkImageSubresourceLayers', aspectMask=1, mipLevel=0,
                               baseArrayLayer=0, layerCount=1)
        self.f.begin()
        self.f.command('vkCmdCopyImage', commandBuffer=self.f.CB,
            srcImage=self.IMAGE, srcImageLayout=1, dstImage=self.SECOND, dstImageLayout=1,
            regionCount=1, pRegions=[self.w.structure('VkImageCopy',
                srcSubresource=sub, srcOffset=self.w.structure('VkOffset3D', x=2, y=1, z=0),
                dstSubresource=sub, dstOffset=self.w.structure('VkOffset3D', x=1, y=0, z=0),
                extent=self.w.structure('VkExtent3D', width=3, height=2, depth=1))])
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        self.assertEqual(self.f.state.aperture.read(base + 4352 + 4, 12), bytes(range(72, 84)))
        self.assertEqual(self.f.state.aperture.read(base + 4352 + 68, 12), bytes(range(136, 148)))
        self.assertEqual(self.f.state.aperture.read(base + 4352 + 16, 48), b'\0' * 48)

    def test_late_bad_region_is_rejected_before_any_image_write_or_pin(self):
        self.create(initial_layout=1)
        self.f.begin()
        self.copy([self.region(), self.region(x=7, width=3)])
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 4096, 256), b'\0' * 256)
        self.assertEqual(self.f.entry(self.IMAGE)['pins'], 0)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_row_budget_rejects_before_acquiring_leases(self):
        self.create(initial_layout=1)
        self.f.begin()
        self.copy()
        self.f.end()
        self.e.transfers.max_operations = 1
        with self.assertRaises(MemoryError):
            self.f.enqueue()
        self.assertFalse(self.e.replay.held)

    def test_stale_image_memory_binding_rejects(self):
        self.create(initial_layout=1)
        self.f.begin()
        self.copy()
        self.f.end()
        self.f.entry(self.IMAGE)['bind_mgen'] ^= 1
        with self.assertRaises(KeyError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)

    def test_aliasing_buffer_image_overlap_rejects(self):
        self.create(offset=0, initial_layout=1)
        self.f.begin()
        self.copy()
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)

    def test_invalid_layout_aspect_and_strides_reject(self):
        self.create(initial_layout=1)
        for layout, region in ((2, self.region()), (1, self.region(aspect=2)),
                               (1, self.region(row=2)), (1, self.region(buffer=4092))):
            self.f.begin()
            self.copy([region], layout=layout)
            self.f.end()
            with self.assertRaises(ValueError):
                self.f.enqueue()
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_copy_layout_must_match_current_image_layout(self):
        self.create(initial_layout=1)
        self.f.begin()
        self.copy(layout=7)  # image is GENERAL(1), not TRANSFER_DST(7)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'layout'):
            self.f.enqueue()
        # an image created directly in the claimed layout admits
        self.create(self.SECOND, offset=4352, initial_layout=7)
        self.f.begin()
        self.copy(layout=7, image=self.SECOND)
        self.f.end()
        self.f.enqueue()

    def test_create_initial_layout_seeds_tracked_state(self):
        self.create(initial_layout=5)
        self.assertEqual(self.f.entry(self.IMAGE)['layout'], 5)
        self.f.begin()
        self.copy(layout=1)  # image is SHADER_READ_ONLY(5), not GENERAL(1)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'layout'):
            self.f.enqueue()

    def test_create_rejects_layout_outside_coherent_profile(self):
        self.create(initial_layout=9)
        self.assertNotIn(self.IMAGE, self.f.front.idmap)

    def test_pending_image_destroy_and_relocation_wait_for_retirement(self):
        self.create(initial_layout=1)
        self.f.begin()
        self.copy()
        self.f.end()
        self.f.enqueue()
        self.assertEqual(self.f.entry(self.IMAGE)['pins'], 1)
        with self.assertRaises(BlockingIOError):
            self.f.owner.relocate(49152)
        task = self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.IMAGE)
        self.f.resume(task)
        self.assertNotIn(self.IMAGE, self.f.front.idmap)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_context_reset_cancels_image_leases(self):
        self.create(initial_layout=1)
        self.f.begin()
        self.copy()
        self.f.end()
        job = self.f.enqueue()
        image = self.f.entry(self.IMAGE)
        self.f.service.reset()
        self.assertEqual((job.state, image['pins'], self.f.owner.work_refs), ('cancelled', 0, 0))
        self.assertFalse(self.e.replay.held)

    def test_byte_texels_preserve_padded_rows(self):
        self.create(fmt=9, initial_layout=1)  # R8_UNORM.
        base = self.f.owner.base
        self.f.state.aperture.write(base, b'---abcdef')
        self.f.begin()
        self.copy([self.region(buffer=3)])
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        self.assertEqual(self.f.state.aperture.read(base + 4096, 3), b'abc')
        self.assertEqual(self.f.state.aperture.read(base + 4160, 3), b'def')
        self.assertEqual(self.f.state.aperture.read(base + 4099, 61), b'\0' * 61)

    def test_depth_image_cannot_be_treated_as_raw_color(self):
        self.create(fmt=126, initial_layout=1)  # D32_SFLOAT.
        self.f.begin()
        self.copy()
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)

    def test_opt_in_wire_submit_executes_image_rows_before_fence_signal(self):
        self.create(initial_layout=1)
        base = self.f.owner.base
        self.f.state.aperture.write(base, b'abcdefghijklmnopqrstuvwx')
        self.f.begin()
        self.copy()
        self.f.end()
        self.e.submissions.enabled = True
        queue, fence = 0x700020007002, 0x700030007003
        self.f.command('vkGetDeviceQueue', device=self.w.DEVICE,
                       queueFamilyIndex=0, queueIndex=0, pQueue=queue)
        self.f.command('vkCreateFence', device=self.w.DEVICE, pFence=fence,
                       pCreateInfo=self.w.structure('VkFenceCreateInfo', pNext=[], flags=0))
        self.f.command('vkQueueSubmit', queue=queue, submitCount=1,
            pSubmits=[self.w.structure('VkSubmitInfo', pNext=[], waitSemaphoreCount=0,
                pWaitSemaphores=[], pWaitDstStageMask=[], commandBufferCount=1,
                pCommandBuffers=[self.f.CB], signalSemaphoreCount=0, pSignalSemaphores=[])],
            fence=fence)
        bit = 1 << (self.f.entry(fence)['aux'] & 255)
        self.assertFalse(self.f.front.fence_sig & bit)
        self.f.drain()
        self.assertTrue(self.f.front.fence_sig & bit)
        self.assertEqual(self.f.state.aperture.read(base + 4096, 12), b'abcdefghijkl')
        self.assertEqual(self.f.state.aperture.read(base + 4160, 12), b'mnopqrstuvwx')


if __name__ == '__main__':
    unittest.main()
