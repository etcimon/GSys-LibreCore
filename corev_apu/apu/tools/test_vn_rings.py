# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Directed native ring ownership, bounded scheduling and retirement checks."""
import struct
import unittest
from unittest.mock import patch

from native_test_wire import NativeWire
from vn_memory import ApertureState
from vn_memory_blobs import MemoryBlobs
from vn_native_execution import LinearExecution
from vn_rings import IDLE, FATAL, ALIVE


class RingTests(unittest.TestCase):
    def setUp(self):
        self.state = ApertureState(65536, 32768)
        self.blobs = MemoryBlobs(self.state)
        for resource, base in ((7, 0), (8, 4096), (9, 8192)):
            self.blobs.create(resource, 4096)
            self.blobs.map(resource, base)
        self.execution = LinearExecution(self.state, self.blobs)
        self.scheduler = self.execution.rings
        self.now = 0
        self.scheduler.clock = lambda: self.now
        self.wire = NativeWire()

    def create(self, handle=0x100, resource=8, context=1, **kwargs):
        self.execution.execute(context, self.wire.create_ring(handle, resource, **kwargs))
        return self.scheduler.rings[(context, handle)]

    def put(self, ring, data):
        tail = self.scheduler.read32(ring, ring.tail_offset)
        offset = tail & (ring.capacity - 1)
        count = min(len(data), ring.capacity - offset)
        self.blobs.write(ring.mapping, ring.offset + ring.buffer_offset + offset, data[:count])
        if count < len(data):
            self.blobs.write(ring.mapping, ring.offset + ring.buffer_offset, data[count:])
        self.scheduler.write32(ring, ring.tail_offset, tail + len(data))

    def extra(self, ring, value=0x12345678):
        return self.wire.command('vkWriteRingExtraMESA', ring=ring.handle, offset=0, value=value)

    def test_real_ring_decode_queries_memory_and_reply_publication(self):
        ring = self.create()
        payload = self.wire.boot()
        self.put(ring, payload)
        self.assertEqual(self.scheduler.poll(), 5)
        self.assertEqual(ring.head, len(payload))
        self.assertEqual(self.scheduler.read32(ring, ring.head_offset), len(payload))
        self.assertEqual(self.execution.memory(1, self.wire.MEMORY).size, 8192)
        self.assertEqual(struct.unpack('<Q', self.state.aperture.read(16, 8))[0],
                         self.wire.INSTANCE)
        self.assertIsNone(self.execution.contexts[1].reply)
        self.assertIsNotNone(ring.view.reply)

    def test_creation_validation_has_no_partial_publication(self):
        for kwargs in ({'tailOffset': 0}, {'bufferSize': 12},
                       {'statusOffset': 1}, {'extraOffset': 8192},
                       {'offset': 1}, {'extraSize': 3}):
            with self.subTest(kwargs=kwargs):
                payload = self.wire.create_ring(**kwargs)
                words = struct.unpack('<%dI' % (len(payload) // 4), payload)
                record = self.execution.decoder.run(words)
                context = self.execution._context(1)
                before = self.state.aperture.read(4096, 4096)
                with self.assertRaises(ValueError):
                    self.scheduler.create(context, words, record)
                self.assertFalse(self.scheduler.rings)
                self.assertEqual(self.blobs.blobs[8].pins, 0)
                self.assertEqual(self.state.aperture.read(4096, 4096), before)

    def test_monitor_chain_and_pin_lifetime(self):
        monitor = self.wire.structure('VkRingMonitorInfoMESA', pNext=[],
                                      maxReportingPeriodMicroseconds=1000)
        ring = self.create(pNext=[monitor])
        self.assertEqual(self.scheduler.read32(ring, ring.status_offset), ALIVE)
        for action in (lambda: self.blobs.unmap(8), lambda: self.blobs.map(8, 12288),
                       lambda: self.blobs.unref(8)):
            with self.assertRaises(BlockingIOError):
                action()
        self.execution.execute(1, self.wire.command('vkDestroyRingMESA', ring=ring.handle))
        self.assertFalse(self.scheduler.rings)
        self.assertEqual(self.blobs.blobs[8].pins, 0)

    def test_wrapped_buffer_and_32bit_counter_publish_after_extra_write(self):
        ring = self.create()
        ring.head = 0xFFFFFFF8
        self.scheduler.write32(ring, ring.head_offset, ring.head)
        self.scheduler.write32(ring, ring.tail_offset, ring.head)
        command = self.extra(ring)
        self.put(ring, command)
        self.assertEqual(self.scheduler.poll(), 1)
        self.assertEqual(ring.head, 0xFFFFFFF8 + len(command))
        self.assertEqual(self.scheduler.read32(ring, ring.head_offset), ring.head & 0xFFFFFFFF)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 0x12345678)

    def test_tail_overrun_and_alignment_fail_at_current_head(self):
        for tail in (2052, 3):
            with self.subTest(tail=tail):
                ring = self.create()
                self.scheduler.write32(ring, ring.tail_offset, tail)
                self.assertEqual(self.scheduler.poll(), 0)
                self.assertTrue(ring.fatal)
                self.assertEqual(ring.head, 0)
                self.assertTrue(self.scheduler.read32(ring, ring.status_offset) & FATAL)
                self.scheduler.retire(ring)
                self.scheduler.write32(ring, ring.tail_offset, 0)

    def test_command_fault_keeps_last_committed_head_and_other_ring_runs(self):
        first, second = self.create(), self.create(0x101, 9)
        good = self.extra(first)
        self.put(first, good + struct.pack('<II', 0xFFFFFFFF, 0))
        self.put(second, self.extra(second, 77))
        self.scheduler.poll()
        self.assertEqual(first.head, len(good))
        self.assertTrue(first.fatal)
        self.assertFalse(second.fatal)
        self.assertEqual(self.scheduler.read32(second, second.extra_offset), 77)
        self.assertFalse(self.execution.contexts[1].faulted)

    def test_round_robin_budget_and_partial_snapshot_are_not_fatal(self):
        first, second = self.create(), self.create(0x101, 9)
        command = self.extra(first)
        self.put(first, command * 3)
        self.put(second, self.extra(second, 77))
        self.execution.max_commands = 1
        self.assertEqual(self.scheduler.poll(), 1)
        self.assertEqual(second.head, 0)
        self.assertEqual(self.scheduler.poll(), 1)
        self.assertGreater(second.head, 0)
        self.execution.max_commands = 256
        self.execution.max_bytes = 40
        self.scheduler.poll()
        self.scheduler.poll()
        self.assertEqual(first.head, len(command) * 3)
        self.assertFalse(first.fatal)

    def test_cooperative_cross_ring_wait_does_not_replay_prior_commands(self):
        first, second = self.create(), self.create(0x101, 9)
        command = self.extra(second, 55)
        wait = self.wire.command('vkWaitRingSeqnoMESA', ring=second.handle, seqno=len(command))
        self.put(first, self.extra(first, 99) + wait)
        self.put(second, command)
        self.scheduler.poll()
        self.assertEqual(first.head, len(self.extra(first)))
        self.assertEqual(second.head, len(command))
        self.scheduler.poll()
        self.assertEqual(first.head, len(self.extra(first)) + len(wait))
        self.assertFalse(first.fatal)

    def test_idle_publication_rechecks_tail_and_notify_wakes_ring(self):
        ring = self.create(idleTimeout=0)
        original = self.scheduler.write32
        inserted = []

        def race(target, offset, value):
            original(target, offset, value)
            if offset == ring.status_offset and value & IDLE and not inserted:
                inserted.append(True)
                self.put(ring, self.extra(ring))

        with patch.object(self.scheduler, 'write32', race):
            self.scheduler.poll()
        self.assertFalse(ring.idle)
        self.scheduler.poll()
        self.scheduler.poll()
        self.assertTrue(ring.idle)
        self.execution.execute(1, self.wire.command(
            'vkNotifyRingMESA', ring=ring.handle, seqno=ring.head, flags=0))
        self.assertFalse(ring.idle)

    def test_context_retirement_and_id_reuse_never_publish_old_work(self):
        old = self.create()
        self.put(old, self.extra(old))
        before = self.state.aperture.read(4096, 4096)
        self.execution.retire_context(1)
        self.assertEqual(self.scheduler.poll(), 0)
        self.assertEqual(self.state.aperture.read(4096, 4096), before)
        self.assertFalse(self.scheduler.live(old))
        self.assertEqual(self.blobs.blobs[8].pins, 0)
        self.scheduler.write32(old, old.tail_offset, 0)
        new = self.create()
        self.assertIsNot(old.context, new.context)
        self.assertFalse(self.scheduler.live(old))

    def test_self_destroy_never_publishes_to_its_retired_head(self):
        ring = self.create()
        self.put(ring, self.wire.command('vkDestroyRingMESA', ring=ring.handle))
        self.scheduler.poll()
        self.assertFalse(self.scheduler.rings)
        self.assertEqual(self.scheduler.read32(ring, ring.head_offset), 0)
        self.assertEqual(self.blobs.blobs[8].pins, 0)

    def test_reset_preflight_keeps_ring_when_external_job_is_pinned(self):
        ring = self.create()
        with self.blobs.pin(self.blobs.mapping(9)):
            with self.assertRaises(BlockingIOError):
                self.scheduler.prepare_reset()
            self.assertTrue(self.scheduler.live(ring))
        self.scheduler.prepare_reset()
        self.assertEqual(self.blobs.blobs[8].pins, 0)
        self.assertFalse(self.scheduler.rings)

    def test_faulting_rings_share_a_snapshot_read_budget(self):
        first, second = self.create(), self.create(0x101, 9)
        for ring in (first, second):
            self.put(ring, struct.pack('<II', 0xFFFFFFFF, 0))
        self.execution.max_bytes = 8
        self.scheduler.poll()
        self.assertTrue(first.fatal)
        self.assertFalse(second.fatal)
        self.scheduler.poll()
        self.assertTrue(second.fatal)

    def test_nested_source_is_bounded_before_reading_guest_bytes(self):
        ring = self.create()
        command = self.wire.command(
            'vkExecuteCommandStreamsMESA', streamCount=1,
            pStreams=[{'_ty': None, 'resourceId': 9, 'offset': 0, 'size': 4096}],
            pReplyPositions=[0], dependencyCount=0, pDependencies=[], flags=0)
        self.put(ring, command)
        self.execution.max_bytes = 128
        with patch.object(self.blobs, 'read', wraps=self.blobs.read) as reads:
            self.scheduler.poll()
        self.assertTrue(ring.fatal)
        self.assertFalse(any(call.args[0].resource == 9 for call in reads.call_args_list))

    def test_control_timeline_unblocks_a_parked_ring(self):
        ring = self.create()
        wait = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        self.put(ring, wait)
        self.assertEqual(self.scheduler.poll(), 0)
        self.assertEqual(ring.head, 0)
        self.execution.execute(1, self.wire.command(
            'vkSubmitVirtqueueSeqnoMESA', ring=0, seqno=10))
        self.assertEqual(self.scheduler.poll(), 1)
        self.assertEqual(ring.head, len(wait))

    def test_stale_reply_mapping_faults_before_frontend_mutation(self):
        ring = self.create()
        self.put(ring, self.wire.boot())
        self.scheduler.poll()
        committed = ring.head
        self.blobs.unmap(7)
        self.blobs.map(7, 12288)
        instance = self.wire.INSTANCE + 0x123
        self.put(ring, self.wire.command('vkCreateInstance', pInstance=instance))
        self.scheduler.poll()
        self.assertTrue(ring.fatal)
        self.assertEqual(ring.head, committed)
        self.assertNotIn(instance, ring.context.frontend.idmap)

    def test_overlapping_context_cannot_retire_another_contexts_ring(self):
        first = self.create()
        with self.assertRaises(ValueError):
            self.create(0x100, 8, context=2)
        self.assertTrue(self.scheduler.live(first))
        self.assertEqual(self.blobs.blobs[8].pins, 1)
        self.assertFalse(first.context.faulted)

    def test_optional_nested_reply_positions_preserve_cursor(self):
        ring = self.create()
        self.put(ring, self.wire.reply())
        self.scheduler.poll()
        ring.view.reply = (*ring.view.reply[:3], 64)
        child = self.extra(ring)
        mapping = self.blobs.mapping(9)
        self.blobs.write(mapping, 0, child)
        command = self.wire.command(
            'vkExecuteCommandStreamsMESA', streamCount=2,
            pStreams=[{'_ty': None, 'resourceId': 9, 'offset': 0, 'size': len(child)}] * 2,
            pReplyPositions=None, dependencyCount=0, pDependencies=[], flags=0)
        self.put(ring, command)
        self.scheduler.poll()
        self.assertFalse(ring.fatal)
        self.assertEqual(ring.view.reply[3], 64)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 0x12345678)
