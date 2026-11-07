# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Owned GENERAL-layout compute images share transfer execution and retirement."""
import struct
import unittest
from unittest.mock import patch

import test_vn_compute_submit as wire_fixture
import test_vn_native_layouts as layout_fixture
from test_vn_compute import program


def image_program(mode='storage', *, bad_write=False):
    source, result, position = program(), list(program()[:5]), 5
    result[3] = 64

    def emit(opcode, *operands):
        result.extend(((len(operands) + 1) << 16 | opcode, *operands))

    while position < len(source):
        count, opcode = source[position] >> 16, source[position] & 0xFFFF
        if opcode == 19:
            emit(71, 23, 34, 0)
            emit(71, 23, 33, 1)
            if mode == 'separate':
                emit(71, 39, 34, 0)
                emit(71, 39, 33, 2)
        if opcode == 54:
            emit(25, 21, 3, 1, 0, 0, 0, 2 if mode == 'storage' else 1,
                 32 if mode == 'storage' else 0)
            if mode in ('combined', 'separate'):
                emit(27, 31, 21)
                emit(22, 32, 32)
                emit(23, 33, 32, 2)
                emit(43, 32, 36, 0)
                emit(44, 33, 35, 36, 36)
            emit(32, 22, 0, 31 if mode == 'combined' else 21)
            emit(59, 22, 23, 0)
            emit(23, 25, 3, 2)
            emit(44, 25, 26, 9, 9)
            emit(23, 27, 3, 4)
            emit(44, 27, 28, 5, 5, 5, 5)
            if mode == 'separate':
                emit(26, 37)
                emit(32, 38, 0, 37)
                emit(59, 38, 39, 0)
        if opcode == 62:
            emit(62, 12, 30)
        else:
            result.extend(source[position:position + count])
        if opcode == 248:
            emit(61, 31 if mode == 'combined' else 21, 24, 23)
            if mode == 'storage' or bad_write:
                emit(99, 24, 26, 28)
            if mode == 'storage':
                emit(98, 27, 29, 24, 26)
            elif mode == 'fetch':
                emit(95, 27, 29, 24, 26, 2, 9)
            else:
                sampled = 24
                if mode == 'separate':
                    emit(61, 37, 40, 39)
                    emit(86, 31, 41, 24, 40)
                    sampled = 41
                emit(88, 27, 29, sampled, 35, 2, 36)
            emit(81, 3, 30, 29, 0)
        position += count
    return tuple(result)


class ComputeImageTests(unittest.TestCase):
    IMAGE, VIEW = 0x700000007000, 0x700020007002

    def setUp(self):
        self.r = wire_fixture.scene()
        self.f, self.e, self.w, self.d = self.r.f, self.r.e, self.r.w, self.r.d
        self.configure()

    def configure(self, mode='storage', *, immutable=False, bad_write=False):
        if hasattr(self, 'mode'):
            self.f.command('vkDestroyImageView', device=self.w.DEVICE, imageView=self.VIEW)
            self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.IMAGE)
            if self.mode in ('combined', 'separate'):
                self.f.command('vkDestroySampler', device=self.w.DEVICE, sampler=self.r.l.SAMPLER)
        self.mode = mode
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.r.l.PIPE)
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE, pipelineLayout=self.r.l.PL)
        allocated = [value for value in (self.d.SOURCE, self.d.TARGET) if value in self.f.front.idmap]
        self.f.command('vkFreeDescriptorSets', device=self.w.DEVICE,
            descriptorPool=self.d.POOL, descriptorSetCount=len(allocated), pDescriptorSets=allocated)
        self.f.command('vkDestroyDescriptorPool', device=self.w.DEVICE, descriptorPool=self.d.POOL)
        self.f.command('vkDestroyDescriptorSetLayout', device=self.w.DEVICE, descriptorSetLayout=self.d.LAYOUT)
        if mode in ('combined', 'separate'):
            self.r.l.sampler()
        dtype = {'storage': 3, 'fetch': 2, 'combined': 1, 'separate': 2}[mode]
        rows = [(0, 7), (1, dtype)] + ([(2, 0)] if mode == 'separate' else [])
        self.f.command('vkCreateDescriptorSetLayout', device=self.w.DEVICE, pSetLayout=self.d.LAYOUT,
            pCreateInfo=self.w.structure('VkDescriptorSetLayoutCreateInfo', pNext=[], flags=0,
                bindingCount=len(rows), pBindings=[self.w.structure('VkDescriptorSetLayoutBinding',
                    binding=binding, descriptorType=kind, descriptorCount=1, stageFlags=0x20,
                    pImmutableSamplers=[self.r.l.SAMPLER] if immutable and kind in (0, 1) else [])
                    for binding, kind in rows]))
        self.f.command('vkCreateDescriptorPool', device=self.w.DEVICE, pDescriptorPool=self.d.POOL,
            pCreateInfo=self.w.structure('VkDescriptorPoolCreateInfo', pNext=[], flags=1, maxSets=1,
                poolSizeCount=len(rows), pPoolSizes=[self.w.structure(
                    'VkDescriptorPoolSize', type=kind, descriptorCount=1) for _, kind in rows]))
        self.f.command('vkAllocateDescriptorSets', device=self.w.DEVICE, pDescriptorSets=[self.d.SOURCE],
            pAllocateInfo=self.w.structure('VkDescriptorSetAllocateInfo', pNext=[],
                descriptorPool=self.d.POOL, descriptorSetCount=1, pSetLayouts=[self.d.LAYOUT]))
        self.f.command('vkCreateImage', device=self.w.DEVICE, pImage=self.IMAGE,
            pCreateInfo=self.w.structure('VkImageCreateInfo', pNext=[], flags=0, imageType=1,
                format=41, extent=self.w.structure('VkExtent3D', width=8, height=4, depth=1),
                mipLevels=1, arrayLayers=1, samples=1, tiling=0, usage=15, sharingMode=0,
                queueFamilyIndexCount=0, pQueueFamilyIndices=[], initialLayout=0))
        self.f.command('vkBindImageMemory', device=self.w.DEVICE, image=self.IMAGE,
                       memory=self.w.MEMORY, memoryOffset=4096)
        self.f.command('vkCreateImageView', device=self.w.DEVICE, pView=self.VIEW,
            pCreateInfo=self.w.structure('VkImageViewCreateInfo', pNext=[], flags=0,
                image=self.IMAGE, viewType=1, format=41,
                components=self.w.structure('VkComponentMapping', r=0, g=0, b=0, a=0),
                subresourceRange=self.subrange()))
        self.d.dtype = 7
        self.d.write()
        writes = [self.w.structure('VkWriteDescriptorSet', pNext=[], dstSet=self.d.SOURCE,
            dstBinding=binding, dstArrayElement=0, descriptorCount=1, descriptorType=kind,
            pBufferInfo=[], pTexelBufferView=[], pImageInfo=[self.w.structure(
                'VkDescriptorImageInfo', sampler=self.r.l.SAMPLER if kind in (0, 1) else 0,
                imageView=0 if kind == 0 else self.VIEW, imageLayout=1)])
            for binding, kind in rows[1:]]
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE, descriptorWriteCount=len(writes),
                       pDescriptorWrites=writes, descriptorCopyCount=0, pDescriptorCopies=[])
        self.r.l.layout()
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.r.l.MODULE)
        self.r.p.module(image_program(mode, bad_write=bad_write))
        self.r.p.pipeline()

    def subrange(self):
        return self.w.structure('VkImageSubresourceRange', aspectMask=1, baseMipLevel=0,
                                levelCount=1, baseArrayLayer=0, layerCount=1)

    def barrier(self, src, dst, access_src, access_dst, *, transition=False):
        self.f.command('vkCmdPipelineBarrier', commandBuffer=self.f.CB,
            srcStageMask=src, dstStageMask=dst, dependencyFlags=0,
            memoryBarrierCount=0 if transition else 1,
            pMemoryBarriers=[] if transition else [self.w.structure(
                'VkMemoryBarrier', pNext=[], srcAccessMask=access_src, dstAccessMask=access_dst)],
            bufferMemoryBarrierCount=0, pBufferMemoryBarriers=[],
            imageMemoryBarrierCount=1 if transition else 0,
            pImageMemoryBarriers=[self.w.structure('VkImageMemoryBarrier', pNext=[],
                srcAccessMask=access_src, dstAccessMask=access_dst, oldLayout=0, newLayout=1,
                srcQueueFamilyIndex=0xFFFFFFFF, dstQueueFamilyIndex=0xFFFFFFFF,
                image=self.IMAGE, subresourceRange=self.subrange())] if transition else [])

    def copy(self, readback=False):
        region = self.w.structure('VkBufferImageCopy', bufferOffset=512 if readback else 1024,
            bufferRowLength=0, bufferImageHeight=0, imageSubresource=self.w.structure(
                'VkImageSubresourceLayers', aspectMask=1, mipLevel=0, baseArrayLayer=0, layerCount=1),
            imageOffset=self.w.structure('VkOffset3D', x=0, y=0, z=0),
            imageExtent=self.w.structure('VkExtent3D', width=1, height=1, depth=1))
        if readback:
            self.f.command('vkCmdCopyImageToBuffer', commandBuffer=self.f.CB,
                srcImage=self.IMAGE, srcImageLayout=1, dstBuffer=self.f.BUFFER,
                regionCount=1, pRegions=[region])
        else:
            self.f.command('vkCmdCopyBufferToImage', commandBuffer=self.f.CB,
                srcBuffer=self.f.BUFFER, dstImage=self.IMAGE, dstImageLayout=1,
                regionCount=1, pRegions=[region])

    def record(self, readback=False):
        self.f.begin()
        self.barrier(1, 0x1000, 0, 0x1000, transition=True)
        if self.mode != 'storage':
            self.f.command('vkCmdUpdateBuffer', commandBuffer=self.f.CB, dstBuffer=self.f.BUFFER,
                           dstOffset=1024, dataSize=4, pData=b'\x0b\x16\x21\x2c')
            self.copy()
        self.barrier(0x1000, 0x800, 0x1000, 0x40 if self.mode == 'storage' else 0x20)
        self.r.bind()
        self.r.dispatch()
        if readback:
            self.barrier(0x800, 0x1000, 0x40, 0x800)
            self.copy(True)
        self.f.end()

    def submit(self):
        self.f.service.execute(1, wire_fixture.submit_packet(self.w, [self.f.CB]))
        return next(iter(self.e.submissions.pending.values()))

    def test_dispatch_descriptor_layout_requires_prior_transition(self):
        self.f.begin()
        self.r.bind()
        self.r.dispatch()
        self.f.end()
        with self.assertRaises(ValueError):
            self.submit()
        self.r.no_work()

    def test_storage_write_read_and_transfer_readback_use_real_backing(self):
        self.record(readback=True)
        job = self.submit()
        self.assertEqual(self.r.word(), 0)
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('done', 5))
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 512, 4), b'\5' * 4)
        self.assertTrue(self.f.front.fence_sig)

    def test_sampled_fetch_follows_transfer_upload(self):
        self.configure('fetch')
        self.record()
        job = self.submit()
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('done', 11))

    def test_combined_and_separate_sampling_keep_sampler_values(self):
        for mode in ('combined', 'separate'):
            self.configure(mode)
            self.record()
            job = self.r.enqueue()
            self.f.drain()
            self.assertEqual((job.state, self.r.word()), ('done', 11))
            self.f.state.aperture.write(self.f.owner.base + 256, b'\0' * 4)

    def test_pending_view_destroy_parks_until_cancelled_work_releases_refs(self):
        self.record()
        job = self.submit()
        task = self.f.service.execute(1, self.w.command('vkDestroyImageView',
                                                      device=self.w.DEVICE, imageView=self.VIEW))
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(self.f.entry(self.VIEW)['pins'], 1)
        self.e.transfers.cancel_context(self.f.context)
        task.advance([256, 65536])
        self.assertEqual((job.state, task.state), ('cancelled', 'done'))
        self.assertNotIn(self.VIEW, self.f.front.idmap)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(self.e.replay.held)

    def test_pending_regular_sampler_destroy_waits_for_work(self):
        self.configure('combined')
        self.record()
        job = self.submit()
        task = self.f.service.execute(1, self.w.command('vkDestroySampler',
            device=self.w.DEVICE, sampler=self.r.l.SAMPLER))
        self.assertEqual(task.state, 'waiting')
        self.f.drain()
        task.advance([256, 65536])
        self.assertEqual((job.state, task.state, self.r.word()), ('done', 'done', 11))

    def test_immutable_sampler_values_need_no_live_sampler_lease(self):
        self.configure('combined', immutable=True)
        self.record()
        job = self.submit()
        self.assertEqual(self.f.entry(self.r.l.SAMPLER)['pins'], 0)
        result = self.f.service.execute(1, self.w.command('vkDestroySampler',
            device=self.w.DEVICE, sampler=self.r.l.SAMPLER))
        self.assertIsInstance(result, int)
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('done', 11))

    def test_late_view_mutation_rolls_back_all_object_and_backing_leases(self):
        self.record()
        view = self.f.entry(self.VIEW)
        handle = view['gen'] << 16 | self.f.front.idmap[self.VIEW]
        original = self.f.front.pin

        def pin(value):
            result = original(value)
            if value == handle:
                view['aux'] ^= 1 << 16
            return result

        with patch.object(self.f.front, 'pin', pin), self.assertRaises(KeyError):
            self.r.enqueue()
        self.assertEqual(view['pins'], 0)
        self.r.no_work()

    def test_image_store_io_failure_loses_fence_without_false_retirement(self):
        self.record()
        job = self.submit()
        address, original = self.f.owner.base + 4096, self.f.state.aperture.write

        def write(at, data):
            if at == address:
                raise OSError('image store DMA revoked')
            original(at, data)

        with patch.object(self.f.state.aperture, 'write', write):
            self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('faulted', 0))
        self.assertTrue(self.f.front.fence_lost)
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.f.command('vkGetFenceStatus', device=self.w.DEVICE, fence=wire_fixture.FENCE)
        reply = self.f.blobs.read(self.f.blobs.mapping(7), 0, 8)
        self.assertEqual(struct.unpack('<II', reply)[1], self.e.golden.VK_ERR_LOST)
        self.assertTrue(self.f.context.gpu_lost)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(self.e.replay.held)

    def test_sampled_image_store_cannot_borrow_writable_buffer_alias(self):
        self.configure('fetch', bad_write=True)
        alias = 0x700050007005
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=alias,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=256, usage=0x20, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=alias,
                       memory=self.w.MEMORY, memoryOffset=4096)
        self.f.command('vkUpdateDescriptorSets', device=self.w.DEVICE,
            descriptorWriteCount=1, descriptorCopyCount=0, pDescriptorCopies=[],
            pDescriptorWrites=[self.w.structure('VkWriteDescriptorSet', pNext=[],
                dstSet=self.d.SOURCE, dstBinding=0, dstArrayElement=0, descriptorCount=1,
                descriptorType=7, pImageInfo=[], pTexelBufferView=[],
                pBufferInfo=[self.w.structure('VkDescriptorBufferInfo', buffer=alias,
                                             offset=0, range=128)])])
        self.record()
        job = self.submit()
        self.f.drain()
        self.assertEqual(job.state, 'faulted')
        self.assertIn('IMGKIND', job.error)
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base + 4096, 4),
                         b'\x0b\x16\x21\x2c')

    def test_transfer_only_replay_does_not_admit_image_shaders(self):
        self.f.begin()
        self.r.bind()
        self.r.dispatch()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'unsupported replay'):
            self.e.replay.enqueue(1, [self.f.CB])
        self.r.no_work()


if __name__ == '__main__':
    unittest.main()
