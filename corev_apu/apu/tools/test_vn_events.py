# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded command-buffer event signal/wait ops and host status feedback."""
import struct
import unittest

import test_vn_images as image_fixture


class EventTests(unittest.TestCase):
    EVENT, SECOND = 0x600000006000, 0x600010006001

    def setUp(self):
        self.images = image_fixture.ImageTests()
        self.images.native_profile = True
        self.images.setUp()
        self.f = self.images.f
        self.w, self.e = self.f.wire, self.f.engine
        for event in (self.EVENT, self.SECOND):
            self.f.command('vkCreateEvent', device=self.w.DEVICE, pEvent=event,
                pCreateInfo=self.w.structure('VkEventCreateInfo', pNext=[], flags=0))

    def create(self, handle):
        self.f.command('vkCreateEvent', device=self.w.DEVICE, pEvent=handle,
            pCreateInfo=self.w.structure('VkEventCreateInfo', pNext=[], flags=0))

    def set_event(self, event=None, stage=0x1000):
        self.f.command('vkCmdSetEvent', commandBuffer=self.f.CB,
            event=event or self.EVENT, stageMask=stage)

    def reset_event(self, event=None, stage=0x1000):
        self.f.command('vkCmdResetEvent', commandBuffer=self.f.CB,
            event=event or self.EVENT, stageMask=stage)

    def wait_events(self, events=None, *, src=0x1000, dst=0x400,
                    memory=0, buffers=0, images=0, src_access=0x800,
                    dst_access=0x100, old_layout=0, new_layout=1):
        events = [self.EVENT] if events is None else events
        self.f.command('vkCmdWaitEvents', commandBuffer=self.f.CB,
            srcStageMask=src, dstStageMask=dst, eventCount=len(events),
            pEvents=events, memoryBarrierCount=memory,
            pMemoryBarriers=[self.w.structure('VkMemoryBarrier', pNext=[],
                srcAccessMask=src_access, dstAccessMask=dst_access)] * memory,
            bufferMemoryBarrierCount=buffers,
            pBufferMemoryBarriers=[self.w.structure('VkBufferMemoryBarrier',
                pNext=[], srcAccessMask=src_access, dstAccessMask=dst_access,
                srcQueueFamilyIndex=0xFFFFFFFF, dstQueueFamilyIndex=0xFFFFFFFF,
                buffer=self.f.BUFFER, offset=0, size=4096)] * buffers,
            imageMemoryBarrierCount=images,
            pImageMemoryBarriers=[self.w.structure('VkImageMemoryBarrier',
                pNext=[], srcAccessMask=src_access, dstAccessMask=dst_access,
                oldLayout=old_layout, newLayout=new_layout,
                srcQueueFamilyIndex=0xFFFFFFFF, dstQueueFamilyIndex=0xFFFFFFFF,
                image=self.images.IMAGE,
                subresourceRange=self.w.structure('VkImageSubresourceRange',
                    aspectMask=1, baseMipLevel=0, levelCount=0xFFFFFFFF,
                    baseArrayLayer=0, layerCount=0xFFFFFFFF))] * images)

    def status(self, event=None):
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.f.command('vkGetEventStatus', device=self.w.DEVICE,
                       event=event or self.EVENT)
        words = struct.unpack('<4I', self.f.blobs.read(
            self.f.blobs.mapping(7), 0, 16))
        return words

    def host_set(self, event=None):
        self.f.command('vkSetEvent', device=self.w.DEVICE, event=event or self.EVENT)

    def host_reset(self, event=None):
        self.f.command('vkResetEvent', device=self.w.DEVICE, event=event or self.EVENT)

    def test_set_wait_reset_execute_in_stream_order(self):
        self.f.begin()
        self.set_event()
        self.wait_events()
        self.reset_event()
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual([op.__class__.__name__ for op in job.operations],
                         ['EventSignal', 'EventWait', 'EventSignal'])
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.event_stats[0], {'signaled': True})
        self.assertEqual(job.event_stats[2], {'signaled': False})
        # Final state is RESET after the ordered reset op.
        words = self.status()
        self.assertIn(4, words)

    def test_wait_blocks_until_host_set_event_releases(self):
        self.f.begin()
        self.wait_events()
        self.f.end()
        job = self.f.enqueue()
        self.f.service.poll()
        self.assertEqual(job.state, 'running')
        self.assertEqual(job.operation, 0)
        self.assertTrue(self.e.transfers.pending)
        self.host_set()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        words = self.status()
        self.assertIn(3, words)

    def test_wait_requires_every_listed_event(self):
        self.host_set(self.SECOND)
        self.f.begin()
        self.wait_events([self.EVENT, self.SECOND])
        self.f.end()
        job = self.f.enqueue()
        self.f.service.poll()
        self.assertEqual(job.state, 'running')
        self.host_set()
        self.f.drain()
        self.assertEqual(job.state, 'done')

    def test_host_reset_clears_signaled_state(self):
        self.host_set()
        words = self.status()
        self.assertIn(3, words)
        self.host_reset()
        words = self.status()
        self.assertIn(4, words)

    def test_wait_events_retained_barriers_execute_in_stream_order(self):
        self.images.create(usage=0x17)
        self.f.begin()
        self.set_event()
        self.wait_events(memory=1, buffers=1, images=1)
        self.f.end()
        job = self.f.enqueue()
        # memory barriers validate scope only; buffer/image barriers each
        # retain a typed Transfer op after the ordered EventWait
        self.assertEqual([op.__class__.__name__ for op in job.operations],
                         ['EventSignal', 'EventWait', 'Transfer', 'Transfer'])
        self.f.drain()
        self.assertEqual(job.state, 'done')

    def test_wait_events_barrier_only_record_skips_event_wait(self):
        self.f.begin()
        self.wait_events(events=[], memory=1, buffers=1)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual([op.__class__.__name__ for op in job.operations],
                         ['Transfer'])
        self.f.drain()
        self.assertEqual(job.state, 'done')

    def test_barrier_payloads_and_bad_stages_refuse_atomically(self):
        for kwargs in (dict(src=0x10), dict(dst=0x40), dict(src=0),
                       dict(memory=1, dst_access=0x20),
                       dict(memory=1, src_access=0x20),
                       dict(buffers=1, dst=0x1000)):
            self.f.begin()
            self.wait_events(**kwargs)
            self.f.end()
            with self.assertRaises(ValueError, msg=str(kwargs)):
                self.f.enqueue()
            self.assertFalse(self.e.transfers.active)
            self.assertFalse(self.e.replay.held)

    def test_wait_events_image_barrier_bounds_refuse(self):
        self.images.create(usage=0x17)
        for kwargs in (dict(images=1, old_layout=3),
                       dict(images=1, new_layout=3),
                       dict(images=1, dst_access=0x20)):
            self.f.begin()
            self.wait_events(**kwargs)
            self.f.end()
            with self.assertRaises(ValueError, msg=str(kwargs)):
                self.f.enqueue()
            self.assertFalse(self.e.transfers.active)
            self.assertFalse(self.e.replay.held)

    def test_wait_events_image_barrier_needs_live_image(self):
        self.f.begin()
        with self.assertRaises(KeyError):
            self.wait_events(images=1)

    def test_dead_event_handle_rejects_before_pins(self):
        self.f.begin()
        self.wait_events()
        self.f.end()
        self.f.command('vkDestroyEvent', device=self.w.DEVICE, event=self.EVENT)
        with self.assertRaises(KeyError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)

    def test_event_pins_release_after_retirement(self):
        self.f.begin()
        self.set_event()
        self.wait_events()
        self.f.end()
        job = self.f.enqueue()
        self.assertGreater(self.f.entry(self.EVENT)['pins'], 0)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.f.entry(self.EVENT)['pins'], 0)

    def test_event_feedback_reports_device_lost_after_fault(self):
        self.host_set()
        words = self.status()
        self.assertIn(3, words)
        context = self.f.engine.contexts[1]
        self.e.submissions.faults.add(id(context))
        words = self.status()
        self.assertIn(0xFFFFFFFC, words)
        # host set/reset report lost rather than mutating event state
        self.host_set()
        self.host_reset()
        self.e.submissions.faults.discard(id(context))
        words = self.status()
        self.assertIn(3, words)


if __name__ == '__main__':
    unittest.main()
