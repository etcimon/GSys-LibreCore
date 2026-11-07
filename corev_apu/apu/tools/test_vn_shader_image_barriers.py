# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Compute-only image shader scopes, read-only layouts and ordered backing."""
import unittest

import test_vn_compute_images as image_fixture


class ShaderImageBarrierTests(unittest.TestCase):
    def setUp(self):
        self.h = image_fixture.ComputeImageTests()
        self.h.setUp()
        self.f, self.e, self.w, self.r = self.h.f, self.h.e, self.h.w, self.h.r

    def barrier(self, *, src=0x1000, dst=0x800, read=0x1000, write=0x20,
                old=7, new=5, family=0xFFFFFFFF, aspect=1):
        self.f.command('vkCmdPipelineBarrier', commandBuffer=self.f.CB,
            srcStageMask=src, dstStageMask=dst, dependencyFlags=0,
            memoryBarrierCount=0, pMemoryBarriers=[], bufferMemoryBarrierCount=0,
            pBufferMemoryBarriers=[], imageMemoryBarrierCount=1,
            pImageMemoryBarriers=[self.w.structure('VkImageMemoryBarrier', pNext=[],
                srcAccessMask=read, dstAccessMask=write, oldLayout=old, newLayout=new,
                srcQueueFamilyIndex=family, dstQueueFamilyIndex=family, image=self.h.IMAGE,
                subresourceRange=dict(self.h.subrange(), aspectMask=aspect))])

    def copy(self, *, readback=False, layout=7):
        region = self.w.structure('VkBufferImageCopy', bufferOffset=512 if readback else 1024,
            bufferRowLength=0, bufferImageHeight=0, imageSubresource=self.w.structure(
                'VkImageSubresourceLayers', aspectMask=1, mipLevel=0, baseArrayLayer=0, layerCount=1),
            imageOffset=self.w.structure('VkOffset3D', x=0, y=0, z=0),
            imageExtent=self.w.structure('VkExtent3D', width=1, height=1, depth=1))
        if readback:
            self.f.command('vkCmdCopyImageToBuffer', commandBuffer=self.f.CB,
                srcImage=self.h.IMAGE, srcImageLayout=layout, dstBuffer=self.f.BUFFER,
                regionCount=1, pRegions=[region])
        else:
            self.f.command('vkCmdCopyBufferToImage', commandBuffer=self.f.CB,
                srcBuffer=self.f.BUFFER, dstImage=self.h.IMAGE, dstImageLayout=layout,
                regionCount=1, pRegions=[region])

    def enqueue(self, compute=True):
        self.f.end()
        return self.e.replay.enqueue(1, [self.f.CB], compute=compute)

    def usage(self, value):
        if self.h.VIEW in self.f.front.idmap:
            self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=self.h.VIEW)
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.h.IMAGE)
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.h.IMAGE,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0,
                imageType=1, format=41, extent=self.w.structure(
                    'VkExtent3D', width=8, height=4, depth=1), mipLevels=1, arrayLayers=1,
                samples=1, tiling=0, usage=value, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[], initialLayout=0))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.h.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4096)

    def test_wire_storage_dispatch_image_barrier_copy_and_fence(self):
        self.f.begin()
        self.barrier(src=1, dst=0x800, read=0, write=0x40, old=0, new=1)
        self.r.bind()
        self.r.dispatch()
        self.barrier(src=0x800, dst=0x1000, read=0x40, write=0x800, old=1, new=6)
        self.copy(readback=True, layout=6)
        self.f.end()
        job = self.h.submit()
        self.assertEqual(self.r.word(), 0)
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('done', 5))
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 512, 4), b'\5' * 4)
        self.assertTrue(self.f.front.fence_sig)

    def test_upload_to_readonly_transition_precedes_sampled_fetch(self):
        self.h.configure('fetch')
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.r.d.SOURCE, dstBinding=1, dstArrayElement=0, descriptorCount=1,
                descriptorType=2, pBufferInfo=[], pTexelBufferView=[],
                pImageInfo=[self.w.structure('VkDescriptorImageInfo',
                    sampler=0, imageView=self.h.VIEW, imageLayout=5)])])
        self.f.begin()
        self.barrier(src=1, dst=0x1000, read=0, write=0x1000, old=0, new=7)
        self.f.command('vkCmdUpdateBuffer', commandBuffer=self.f.CB,
            dstBuffer=self.f.BUFFER, dstOffset=1024, dataSize=4, pData=b'\x0b\x16\x21\x2c')
        self.copy()
        self.barrier()
        self.r.bind()
        self.r.dispatch()
        self.f.end()
        job = self.h.submit()
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('done', 11))

    def test_readonly_transition_and_return_retain_barrier_only_leases(self):
        self.f.begin()
        self.barrier(src=1, read=0, old=0)
        self.barrier(src=0x800, dst=0x1000, read=0x20, write=0x1000, old=5, new=7)
        job = self.enqueue()
        self.assertEqual((job.size, len(job.operations), self.f.owner.work_refs), (0, 2, 1))
        self.assertEqual(self.f.entry(self.h.IMAGE)['pins'], 1)
        self.f.drain()
        self.assertEqual((job.state, self.f.owner.work_refs), ('done', 0))

    def test_transfer_only_refuses_shader_access_and_readonly_layout(self):
        self.usage(3)
        for options in (dict(src=0x10000, dst=0x10000, read=0x20, write=0x20, old=1, new=1),
                        dict(src=0x1000, dst=0x1000, read=0, write=0, old=1, new=5)):
            self.f.begin()
            self.barrier(**options)
            with self.assertRaises(ValueError):
                self.enqueue(compute=False)
            self.r.no_work()

    def test_shader_access_layout_pairs_fail_before_pins_or_writes(self):
        for options in (dict(write=0x40), dict(read=0x40, old=5),
                        dict(write=0x20, new=6), dict(write=0x1000),
                        dict(write=0x10000), dict(write=0x800)):
            self.f.begin()
            self.barrier(src=0x10000, dst=0x10000, **options)
            with self.assertRaises(ValueError):
                self.enqueue()
            self.r.no_work()

    def test_image_scopes_refuse_uniform_indirect_and_incompatible_stages(self):
        for options in (dict(dst=0x1000), dict(write=8), dict(write=1),
                        dict(dst=0x4000), dict(family=0), dict(aspect=2)):
            self.f.begin()
            self.barrier(**options)
            with self.assertRaises(ValueError):
                self.enqueue()
            self.r.no_work()

    def test_shader_usage_and_readonly_sampled_usage_are_required(self):
        for usage, access, layout in ((3, 0x20, 1), (4, 0x40, 1), (8, 0x20, 5)):
            self.usage(usage)
            self.f.begin()
            self.barrier(src=1, read=0, write=access, old=0, new=layout)
            with self.assertRaisesRegex(ValueError, 'usage'):
                self.enqueue()
            self.r.no_work()

    def test_cancelled_shader_barrier_releases_image_and_backing(self):
        self.f.begin()
        self.barrier(src=1, read=0, old=0)
        job = self.enqueue()
        self.e.transfers.cancel_context(self.f.context)
        self.assertEqual(job.state, 'cancelled')
        self.assertEqual(self.f.entry(self.h.IMAGE)['pins'], 0)
        self.r.no_work()

    def test_recorded_image_generation_is_not_redirected_by_id_reuse(self):
        self.f.begin()
        self.barrier(src=1, read=0, old=0)
        self.f.end()
        self.usage(15)
        with self.assertRaises(KeyError):
            self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.r.no_work()


if __name__ == '__main__':
    unittest.main()
