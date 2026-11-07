# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native captured image barriers, generations and coherent transfer ordering."""
import unittest

import test_vn_images as image_fixture
from vn_native_execution import load_decoder
from vn_transfer_executor import Transfer


class ImageBarrierTests(unittest.TestCase):
    def setUp(self):
        self.images = image_fixture.ImageTests()
        self.images.native_profile = True
        self.images.setUp()
        self.images.create()
        self.f, self.w, self.e = self.images.f, self.images.w, self.images.e
        self.image = self.images.IMAGE

    def barrier(self, old=0, new=7, *, image=None, src=0, dst=0x1000, mip=0,
                levels=0xFFFFFFFF, layer=0, layers=0xFFFFFFFF, aspect=1,
                family=0xFFFFFFFF, source_stage=1, target_stage=0x1000, more_images=(),
                declared_count=None):
        info = self.w.structure('VkImageMemoryBarrier', pNext=[],
            srcAccessMask=src, dstAccessMask=dst, oldLayout=old, newLayout=new,
            srcQueueFamilyIndex=family, dstQueueFamilyIndex=family, image=image or self.image,
            subresourceRange=self.w.structure('VkImageSubresourceRange', aspectMask=aspect,
                baseMipLevel=mip, levelCount=levels, baseArrayLayer=layer, layerCount=layers))
        infos = [info] + [{**info, 'image': value} for value in more_images]
        self.f.command('vkCmdPipelineBarrier', commandBuffer=self.f.CB,
            srcStageMask=source_stage, dstStageMask=target_stage, dependencyFlags=0,
            memoryBarrierCount=0, pMemoryBarriers=[], bufferMemoryBarrierCount=0,
            pBufferMemoryBarriers=[], imageMemoryBarrierCount=(
                len(infos) if declared_count is None else declared_count),
            pImageMemoryBarriers=infos)

    def test_transition_upload_transition_readback_is_ordered(self):
        base = self.f.owner.base
        self.f.state.aperture.write(base, b'abcdefghijklmnopqrstuvwx')
        self.f.begin()
        self.barrier()
        self.images.copy(layout=7)
        self.barrier(7, 6, src=0x1000, dst=0x800, source_stage=0x1000)
        self.images.copy([self.images.region(buffer=512)], readback=True, layout=6)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual([op.kind for op in job.operations],
                         ['barrier', 'copy', 'copy', 'barrier', 'copy', 'copy'])
        self.e.transfers.poll()
        self.assertEqual(job.operation, 1)
        self.assertEqual(self.f.owner.work_refs, 1)
        self.assertEqual(self.f.state.aperture.read(base + 4096, 24), b'\0' * 24)
        self.f.drain()
        self.assertEqual(self.f.state.aperture.read(base + 512, 24), b'abcdefghijklmnopqrstuvwx')

    def test_old_layout_must_match_tracked_image_layout(self):
        # a fresh image is UNDEFINED(0); a nonzero oldLayout mismatches
        self.f.begin()
        self.barrier(old=6, new=7)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'oldLayout'):
            self.f.enqueue()
        # UNDEFINED oldLayout discards from any tracked state
        self.f.begin()
        self.barrier()
        self.barrier(7, 6, src=0x1000, dst=0x800, source_stage=0x1000)
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        self.assertEqual(self.f.entry(self.image)['layout'], 6)
        # a stale oldLayout refuses even though newLayout is legal
        self.f.begin()
        self.barrier(old=7, new=1)
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'oldLayout'):
            self.f.enqueue()
        self.assertEqual(self.f.entry(self.image)['layout'], 6)

    def test_layout_state_persists_across_recorded_submits(self):
        self.f.begin()
        self.barrier()
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        # the published layout survives into the next recorded buffer
        self.f.begin()
        self.barrier(7, 6, src=0x1000, dst=0x800, source_stage=0x1000)
        self.barrier(6, 1)
        self.f.end()
        self.f.enqueue()
        self.assertEqual(self.f.entry(self.image)['layout'], 1)

    def test_barrier_only_job_retains_image_backing_without_byte_writes(self):
        base = self.f.owner.base
        self.f.state.aperture.write(base + 4096, b'P' * 256)
        self.f.begin()
        self.barrier()
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual((job.size, self.f.owner.work_refs), (0, 1))
        self.assertEqual(self.f.entry(self.image)['pins'], 1)
        self.f.drain()
        self.assertEqual((self.f.owner.work_refs, job.state), (0, 'done'))
        self.assertEqual(self.f.state.aperture.read(base + 4096, 256), b'P' * 256)

    def test_recording_captures_generation_not_reusable_wire_id(self):
        self.f.begin()
        self.barrier()
        self.f.end()
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.image)
        self.images.create()
        with self.assertRaises(KeyError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)

    def test_unsupported_access_stage_layout_and_ownership_reject_before_pins(self):
        for fields in (dict(src=0x20), dict(source_stage=0x10), dict(new=2),
                       dict(family=0), dict(aspect=2), dict(mip=1), dict(layer=1),
                       dict(levels=0)):
            self.f.begin()
            self.barrier(**fields)
            self.f.end()
            with self.assertRaises(ValueError):
                self.f.enqueue()
            self.assertEqual((self.f.owner.work_refs, self.f.entry(self.image)['pins']), (0, 0))

    def test_all_images_in_barrier_array_capture_generations(self):
        self.images.create(self.images.SECOND, offset=4352)
        self.f.begin()
        self.barrier(more_images=[self.images.SECOND])
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual(len(job.operations), 2)
        self.assertEqual(self.f.entry(self.images.SECOND)['pins'], 1)
        self.f.drain()

    def test_default_decoder_does_not_capture_native_barrier_payload(self):
        _, base, _ = load_decoder()
        _, extended, _ = load_decoder(True)
        self.assertNotIn('vkCmdPipelineBarrier', base.profile['keep'])
        self.assertIn('vkCmdPipelineBarrier', extended.profile['keep'])

    def test_declared_array_count_mismatch_rejects_at_recording(self):
        self.f.begin()
        with self.assertRaises(ValueError):
            self.barrier(declared_count=2)
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_capture_limit_is_bounded_before_append(self):
        self.f.begin()
        with self.assertRaises(ValueError):
            self.barrier(more_images=[self.image] * 16)
        self.assertFalse(self.e.transfers.active)

    def test_barrier_operation_must_not_silently_discard_byte_work(self):
        with self.assertRaises(ValueError):
            self.e.transfers.enqueue(self.f.context, [
                Transfer('barrier', self.f.owner, 0, 4)])
        self.assertEqual(self.f.owner.work_refs, 0)

    def test_nonfinal_array_image_generation_cannot_be_reused(self):
        self.images.create(self.images.SECOND, offset=4352)
        self.f.begin()
        self.barrier(more_images=[self.images.SECOND])
        self.f.end()
        self.f.command('vkDestroyImage', device=self.w.DEVICE, image=self.image)
        self.images.create()
        with self.assertRaises(KeyError):
            self.f.enqueue()
        self.assertEqual(self.f.entry(self.images.SECOND)['pins'], 0)


if __name__ == '__main__':
    unittest.main()
