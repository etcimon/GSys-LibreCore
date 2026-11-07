# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Directed continuation suspension, source lifetime and prefix preservation."""
import unittest
import struct

import test_vn_rings
from vn_control import HEADER, RESP_NODATA
from vn_control_queue import DeferredCompletion
from vn_deferred import DeferredReply
from vn_dma import GuestDma
from vn_split_queue import SplitQueue
from vn_stream_task import StreamTask


class ContinuationTests(unittest.TestCase):
    setUp = test_vn_rings.RingTests.setUp
    create = test_vn_rings.RingTests.create
    put = test_vn_rings.RingTests.put
    extra = test_vn_rings.RingTests.extra

    def nested(self, size):
        return self.wire.command(
            'vkExecuteCommandStreamsMESA', streamCount=1,
            pStreams=[{'_ty': None, 'resourceId': 9, 'offset': 0, 'size': size}],
            pReplyPositions=None, dependencyCount=0, pDependencies=[], flags=0)

    def signal(self):
        self.execution.execute(1, self.wire.command(
            'vkSubmitVirtqueueSeqnoMESA', ring=0, seqno=10))

    def test_nested_ring_wait_preserves_prefix_and_source_pin(self):
        ring = self.create()
        wait = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        suffix = self.wire.command('vkWriteRingExtraMESA', ring=ring.handle, offset=4, value=20)
        child = self.extra(ring, 10) + wait + suffix
        self.blobs.write(self.blobs.mapping(9), 0, child)
        parent = self.nested(len(child))
        self.put(ring, parent)
        self.scheduler.poll()
        self.assertEqual(ring.head, 0)
        self.assertEqual(ring.task.state, 'waiting')
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 10)
        with self.assertRaises(BlockingIOError):
            self.blobs.unmap(9)
        self.scheduler.write32(ring, ring.extra_offset, 77)
        self.signal()
        self.scheduler.poll()
        self.assertEqual(ring.head, len(parent))
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 77)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset + 4), 20)
        self.assertEqual(self.blobs.blobs[9].pins, 0)
        self.assertFalse(self.execution.tasks)

    def test_linear_wait_returns_a_task_and_resumes_after_signal(self):
        ring = self.create()
        wait = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        task = self.execution.execute(1, self.extra(ring, 10) + wait)
        self.assertIsInstance(task, StreamTask)
        self.assertEqual(task.state, 'waiting')
        self.scheduler.write32(ring, ring.extra_offset, 77)
        self.signal()
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 77)

    def test_pending_linear_reply_view_does_not_follow_a_newer_stream(self):
        first_id, second_id = self.wire.INSTANCE, self.wire.INSTANCE + 0x100
        wait = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        task = self.execution.execute(1, self.wire.reply(7) + wait +
                                      self.wire.command('vkCreateInstance', pInstance=first_id))
        self.execution.execute(1, self.wire.reply(9) +
                               self.wire.command('vkCreateInstance', pInstance=second_id))
        latest = self.execution.contexts[1].reply
        self.signal()
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')
        self.assertEqual(self.execution.contexts[1].reply, latest)
        self.assertEqual(struct.unpack('<Q', self.state.aperture.read(16, 8))[0], first_id)
        self.assertEqual(struct.unpack('<Q', self.state.aperture.read(8192 + 16, 8))[0], second_id)

    def test_context_cancellation_releases_nested_sources_without_publication(self):
        ring = self.create()
        child = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        self.blobs.write(self.blobs.mapping(9), 0, child)
        self.put(ring, self.nested(len(child)))
        self.scheduler.poll()
        task = ring.task
        self.assertEqual(self.blobs.blobs[9].pins, 1)
        before = self.state.aperture.read(4096, 4096)
        self.execution.retire_context(1)
        self.assertEqual(task.state, 'cancelled')
        self.assertEqual(self.blobs.blobs[9].pins, 0)
        self.assertFalse(self.execution.tasks)
        self.assertEqual(self.state.aperture.read(4096, 4096), before)

    def deferred_queue(self):
        ring = self.create()
        wait = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        task = self.execution.execute(1, wait + self.extra(ring, 99))
        dma = GuestDma(self.state.guest_ram)
        dma.policy.grant(0, 2048, read=True, write=True)
        dma.policy.grant(4096, 64, read=True, write=True)
        memory = dma.memory
        memory.write(4096, b'Z' * 64)
        reply = DeferredReply(task, lambda _: HEADER.pack(RESP_NODATA, 0, 0, 1, 0))
        deferred = DeferredCompletion(reply, dma, [(4096, 24)], len(wait))

        class Processor:
            def process(self, buffers):
                return deferred

        queue = SplitQueue(dma, Processor())
        queue.size, queue.desc, queue.avail, queue.used = 4, 0, 512, 1024
        queue.enable()
        memory.write(0, struct.pack('<QIHH', 1536, 8, 0, 0))
        memory.write(512, struct.pack('<HHH', 0, 1, 0))
        self.assertEqual(queue.drain(), (0, False))
        return ring, task, queue, dma

    def test_used_publication_is_deferred_and_normal_accounting_is_preserved(self):
        ring, task, queue, dma = self.deferred_queue()
        self.assertEqual(queue.poll(), (0, False))
        self.assertEqual(queue.used_index, 0)
        self.assertEqual(dma.memory.read(4096, 64), b'Z' * 64)
        self.signal()
        self.assertEqual(queue.poll(), (1, True))
        self.assertEqual(task.state, 'done')
        self.assertEqual(struct.unpack('<II', dma.memory.read(1028, 8)), (0, 24))
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 99)
        self.assertFalse(queue.pending)

    def test_revoked_response_permission_precedes_resume_and_side_effects(self):
        ring, task, queue, dma = self.deferred_queue()
        self.signal()
        dma.policy.revoke(4096, 64)
        with self.assertRaises(PermissionError):
            queue.poll()
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(queue.used_index, 0)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 0)
        self.assertEqual(dma.memory.read(4096, 64), b'Z' * 64)

    def test_revoked_used_permission_precedes_resume_and_side_effects(self):
        ring, task, queue, dma = self.deferred_queue()
        self.signal()
        dma.policy.revoke(0, 2048)
        dma.policy.grant(0, 2048, read=True)
        with self.assertRaises(PermissionError):
            queue.poll()
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(queue.used_index, 0)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 0)

    def test_inflight_head_reuse_is_rejected_without_resuming_work(self):
        _, task, queue, dma = self.deferred_queue()
        dma.memory.write(518, struct.pack('<H', 0))
        dma.memory.write(514, struct.pack('<H', 2))
        with self.assertRaisesRegex(ValueError, 'in-flight'):
            queue.drain()
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(queue.last_avail, 1)

    def test_reset_preflight_drains_parked_task_pins_but_not_external_pins(self):
        ring = self.create()
        child = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        self.blobs.write(self.blobs.mapping(9), 0, child)
        task = self.execution.execute(1, self.nested(len(child)))
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(self.blobs.blobs[9].pins, 1)
        with self.blobs.pin(self.blobs.mapping(7)):
            with self.assertRaises(BlockingIOError):
                self.scheduler.prepare_reset()
            self.assertEqual(task.state, 'waiting')
            self.assertTrue(self.scheduler.live(ring))
        self.scheduler.prepare_reset()
        self.assertEqual(task.state, 'cancelled')
        self.assertEqual(self.blobs.blobs[9].pins, 0)
        self.assertEqual(self.blobs.blobs[8].pins, 0)
        self.assertFalse(self.execution.tasks)

    def test_nested_dma_read_budget_is_shared_between_tasks(self):
        child = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        self.blobs.write(self.blobs.mapping(9), 0, child)
        current = self.execution._context(1)
        first = self.execution.start_view(current, self.nested(len(child)))
        second = self.execution.start_view(current, self.nested(len(child)))
        budget = [256, 65536, len(child)]
        first.advance(budget)
        second.advance(budget)
        self.assertEqual(first.state, 'waiting')
        self.assertEqual(second.state, 'ready')
        self.assertFalse(second.pins)
        self.assertEqual(self.blobs.blobs[9].pins, 1)
        second.advance([256, 65536, len(child)])
        self.assertEqual(second.state, 'waiting')
        self.assertEqual(self.blobs.blobs[9].pins, 2)
        first.cancel()
        second.cancel()
        self.assertEqual(self.blobs.blobs[9].pins, 0)

    def test_multiple_nested_windows_share_one_mapping_lease(self):
        child = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        self.blobs.write(self.blobs.mapping(9), 0, child)
        command = self.wire.command(
            'vkExecuteCommandStreamsMESA', streamCount=2,
            pStreams=[{'_ty': None, 'resourceId': 9, 'offset': 0, 'size': len(child)}] * 2,
            pReplyPositions=None, dependencyCount=0, pDependencies=[], flags=0)
        task = self.execution.execute(1, command)
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(self.blobs.blobs[9].pins, 1)
        task.cancel()
        self.assertEqual(self.blobs.blobs[9].pins, 0)

    def test_old_context_view_cannot_start_work_after_context_id_reuse(self):
        old = self.execution._context(1)
        self.execution.retire_context(1)
        self.execution._context(1)
        with self.assertRaises(ValueError):
            self.execution.start_view(old, self.wire.reply())
        self.assertFalse(self.execution.tasks)

    def test_withdrawn_tail_cancels_parked_work_before_resuming_effects(self):
        ring = self.create()
        child = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10) + self.extra(ring, 99)
        self.blobs.write(self.blobs.mapping(9), 0, child)
        self.put(ring, self.nested(len(child)))
        self.scheduler.poll()
        task = ring.task
        self.scheduler.write32(ring, ring.tail_offset, 4)
        self.signal()
        self.scheduler.poll()
        self.assertTrue(ring.fatal)
        self.assertEqual(task.state, 'cancelled')
        self.assertEqual(ring.head, 0)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 0)
        self.assertEqual(self.blobs.blobs[9].pins, 0)
