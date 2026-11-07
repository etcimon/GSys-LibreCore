# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Coherent compute/transfer barrier scopes, resource leases and refusal."""
import unittest

import test_vn_compute_submit as wire_fixture
import test_vn_images as image_fixture
import test_vn_replay as replay_fixture


class ComputeBarrierTests(unittest.TestCase):
    def setUp(self):
        self.r = wire_fixture.scene()
        self.f, self.e, self.w = self.r.f, self.r.e, self.r.w

    def memory(self, src=0x40, dst=0x800):
        return self.w.structure('VkMemoryBarrier', pNext=[], srcAccessMask=src, dstAccessMask=dst)

    def buffer(self, *, offset=0, size=(1 << 64) - 1, family=0xFFFFFFFF):
        return self.w.structure('VkBufferMemoryBarrier', pNext=[],
            srcAccessMask=0x40, dstAccessMask=0x800, srcQueueFamilyIndex=family,
            dstQueueFamilyIndex=family, buffer=self.f.BUFFER, offset=offset, size=size)

    def barrier(self, *, memories=(), buffers=(), images=(), src=0x800, dst=0x1000):
        self.f.command('vkCmdPipelineBarrier', commandBuffer=self.f.CB,
            srcStageMask=src, dstStageMask=dst, dependencyFlags=0,
            memoryBarrierCount=len(memories), pMemoryBarriers=list(memories),
            bufferMemoryBarrierCount=len(buffers), pBufferMemoryBarriers=list(buffers),
            imageMemoryBarrierCount=len(images), pImageMemoryBarriers=list(images))

    def enqueue(self, compute=True):
        self.f.end()
        return self.e.replay.enqueue(1, [self.f.CB], compute=compute)

    def test_wire_dispatch_memory_barrier_copy_and_fence(self):
        self.f.begin()
        self.r.bind()
        self.r.dispatch()
        self.barrier(memories=[self.memory()])
        self.f.command('vkCmdCopyBuffer', commandBuffer=self.f.CB,
            srcBuffer=self.f.BUFFER, dstBuffer=self.f.BUFFER, regionCount=1,
            pRegions=[self.w.structure('VkBufferCopy', srcOffset=256, dstOffset=512, size=4)])
        self.f.end()
        self.f.service.execute(1, wire_fixture.submit_packet(self.w, [self.f.CB]))
        self.assertEqual(self.r.word(512), 0)
        self.f.drain()
        self.assertEqual(self.r.word(512), 5)
        self.assertTrue(self.f.front.fence_sig)

    def test_buffer_only_barrier_holds_backing_until_retirement(self):
        self.f.begin()
        self.barrier(buffers=[self.buffer(offset=128)])
        job = self.enqueue()
        self.assertEqual((job.size, self.f.owner.work_refs), (0, 1))
        self.assertEqual(self.f.entry(self.f.BUFFER)['pins'], 1)
        self.assertEqual(job.operations[0].offset, 128)
        self.f.drain()
        self.assertEqual((self.f.owner.work_refs, self.f.entry(self.f.BUFFER)['pins']), (0, 0))

    def test_cancelled_buffer_barrier_releases_all_leases(self):
        self.f.begin()
        self.barrier(buffers=[self.buffer()])
        job = self.enqueue()
        self.e.transfers.cancel_context(self.f.context)
        self.assertEqual(job.state, 'cancelled')
        self.assertEqual(self.f.entry(self.f.BUFFER)['pins'], 0)
        self.r.no_work()

    def test_shader_access_requires_compute_even_with_all_commands_stage(self):
        self.f.begin()
        self.barrier(memories=[self.memory()], src=0x10000)
        with self.assertRaises(ValueError):
            self.enqueue(compute=False)
        self.r.no_work()

    def test_incompatible_or_unsupported_stage_access_rejects_without_pins(self):
        for src, dst, access in ((0x1000, 0x1000, 0x40), (0x800, 0x4000, 0x40),
                                 (8, 0x1000, 0), (0x800, 0x1000, 0x10),
                                 (0x10000, 0x1000, 0x4000)):
            self.f.begin()
            self.barrier(memories=[self.memory(src=access)], src=src, dst=dst)
            with self.assertRaises(ValueError):
                self.enqueue()
            self.r.no_work()

    def test_buffer_ranges_and_ownership_reject_without_writes(self):
        for fields in (dict(size=0), dict(offset=4096), dict(offset=4095, size=2),
                       dict(family=0)):
            self.f.begin()
            self.barrier(buffers=[self.buffer(**fields)])
            with self.assertRaises(ValueError):
                self.enqueue()
            self.r.no_work()

    def test_buffer_generation_capture_rejects_destroyed_and_reused_id(self):
        self.f.begin()
        self.barrier(buffers=[self.buffer()])
        self.f.end()
        self.f.command('vkDestroyBuffer', device=self.w.DEVICE, buffer=self.f.BUFFER)
        self.r.d.buffer()
        with self.assertRaises(KeyError):
            self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.r.no_work()

    def test_mixed_memory_buffer_image_payload_offsets_and_leases(self):
        image = image_fixture.ImageTests()
        image.f, image.w, image.e = self.f, self.w, self.e
        image.create()
        ib = self.w.structure('VkImageMemoryBarrier', pNext=[], srcAccessMask=0x1000,
            dstAccessMask=0x800, oldLayout=0, newLayout=6,
            srcQueueFamilyIndex=0xFFFFFFFF, dstQueueFamilyIndex=0xFFFFFFFF, image=image.IMAGE,
            subresourceRange=self.w.structure('VkImageSubresourceRange', aspectMask=1,
                baseMipLevel=0, levelCount=1, baseArrayLayer=0, layerCount=1))
        bb = dict(self.buffer(), srcAccessMask=0x1000)
        self.f.begin()
        self.barrier(memories=[self.memory()], buffers=[bb], images=[ib], src=0x1800)
        job = self.enqueue()
        self.assertEqual([operation.kind for operation in job.operations], ['barrier', 'barrier'])
        self.assertEqual(self.f.entry(image.IMAGE)['pins'], 1)
        self.assertEqual(self.f.entry(self.f.BUFFER)['pins'], 1)
        self.assertEqual(self.f.owner.work_refs, 1)
        self.f.drain()
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_shader_image_access_requires_shader_usage(self):
        image = image_fixture.ImageTests()
        image.f, image.w, image.e = self.f, self.w, self.e
        image.create()
        ib = self.w.structure('VkImageMemoryBarrier', pNext=[], srcAccessMask=0x40,
            dstAccessMask=0x800, oldLayout=1, newLayout=6,
            srcQueueFamilyIndex=0xFFFFFFFF, dstQueueFamilyIndex=0xFFFFFFFF, image=image.IMAGE,
            subresourceRange=self.w.structure('VkImageSubresourceRange', aspectMask=1,
                baseMipLevel=0, levelCount=1, baseArrayLayer=0, layerCount=1))
        self.f.begin()
        self.barrier(images=[ib])
        with self.assertRaises(ValueError):
            self.enqueue()
        self.assertEqual(self.f.entry(image.IMAGE)['pins'], 0)
        self.r.no_work()

    def test_buffer_barrier_cannot_cross_command_buffer_devices(self):
        device, buffer = 0x400180001018, 0x400190001019
        self.f.command('vkCreateDevice', physicalDevice=self.w.PHYSICAL, pDevice=device,
            pCreateInfo=self.w.structure('VkDeviceCreateInfo', pNext=[], flags=0,
                queueCreateInfoCount=1, pQueueCreateInfos=[self.w.structure(
                    'VkDeviceQueueCreateInfo', pNext=[], flags=0, queueFamilyIndex=0,
                    queueCount=1, pQueuePriorities=[0x3F800000])],
                enabledLayerCount=0, ppEnabledLayerNames=[], enabledExtensionCount=0,
                ppEnabledExtensionNames=[], pEnabledFeatures=None))
        self.f.command('vkCreateBuffer', device=device, pBuffer=buffer,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=4096, usage=3, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.begin()
        self.barrier(buffers=[dict(self.buffer(), buffer=buffer)])
        with self.assertRaisesRegex(ValueError, 'devices'):
            self.enqueue()
        self.r.no_work()

    def test_combined_capture_count_limit_is_checked_before_append(self):
        self.f.begin()
        with self.assertRaises(ValueError):
            self.barrier(memories=[self.memory()] * 8, buffers=[self.buffer()] * 9)
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.front.cbd[self.f.front.idmap[self.f.CB]]['count'], 0)

    def test_record_local_payload_count_cannot_consume_neighbor_words(self):
        self.f.begin()
        self.barrier(buffers=[self.buffer()])
        self.f.end()
        record = self.f.front.cbd[self.f.front.idmap[self.f.CB]]['recs'][0]
        record['payload_words'] += 1
        with self.assertRaises(ValueError):
            self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.r.no_work()

    def test_default_decoder_does_not_silently_accept_unretained_access_masks(self):
        f = replay_fixture.ReplayTests()
        f.setUp()
        f.begin()
        f.command('vkCmdPipelineBarrier', commandBuffer=f.CB, srcStageMask=0x1000,
            dstStageMask=0x1000, dependencyFlags=0, memoryBarrierCount=1,
            pMemoryBarriers=[f.wire.structure('VkMemoryBarrier', pNext=[],
                                            srcAccessMask=0x1000, dstAccessMask=0x800)],
            bufferMemoryBarrierCount=0, pBufferMemoryBarriers=[],
            imageMemoryBarrierCount=0, pImageMemoryBarriers=[])
        f.end()
        with self.assertRaises(ValueError):
            f.enqueue()
        self.assertFalse(f.engine.transfers.active)
        self.assertEqual(f.owner.work_refs, 0)


if __name__ == '__main__':
    unittest.main()
