# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native timeline submit reservations and bounded diagnostic queue lanes."""
import struct
import unittest
from unittest.mock import patch

import test_vn_timelines as timeline_fixture


class TimelineJobTests(unittest.TestCase):
    Q1, Q2, ALIAS = 0x4000C000100C, 0x4000D000100D, 0x4000E000100E

    def setUp(self):
        self.f = timeline_fixture.TimelineTests()
        self.f.setUp()
        self.e, self.w, self.sem = self.f.e, self.f.w, self.f.SECOND
        self.f.create(self.sem, 0)
        for handle, index in ((self.Q1, 0), (self.Q2, 1), (self.ALIAS, 0)):
            self.f.execute('vkGetDeviceQueue', device=self.w.DEVICE,
                           queueFamilyIndex=0, queueIndex=index, pQueue=handle)
        self.context = self.e.contexts[1]

    def packet(self, queue, waits=(), signals=(), buffers=()):
        info = self.w.structure('VkTimelineSemaphoreSubmitInfo',
            waitSemaphoreValueCount=len(waits), pWaitSemaphoreValues=[v for s, v in waits],
            signalSemaphoreValueCount=len(signals),
            pSignalSemaphoreValues=[v for s, v in signals])
        data = self.w.command('vkQueueSubmit', queue=queue, submitCount=1,
            pSubmits=[self.w.structure('VkSubmitInfo', pNext=[info],
                waitSemaphoreCount=len(waits), pWaitSemaphores=[s for s, v in waits],
                pWaitDstStageMask=[0x1000] * len(waits), commandBufferCount=len(buffers),
                pCommandBuffers=list(buffers), signalSemaphoreCount=len(signals),
                pSignalSemaphores=[s for s, v in signals])], fence=0)
        return data[:4] + struct.pack('<I', 0) + data[8:]

    def submit(self, queue, waits=(), signals=(), buffers=()):
        self.e.execute(1, self.packet(queue, waits, signals, buffers))
        return self.e.transfers.queues[id(self.context)][-1]

    def drain(self):
        for _ in range(32):
            if not self.e.transfers.active:
                return
            self.e.transfers.poll()
        self.fail('diagnostic queue jobs did not drain')

    def counter(self):
        return self.f.counter(self.sem)[2]

    def test_wait_before_signal_progresses_on_another_queue(self):
        waiting = self.submit(self.Q1, waits=[(self.sem, 10)])
        producer = self.submit(self.Q2, signals=[(self.sem, 10)])
        self.e.transfers.poll()
        self.assertEqual(waiting.state, 'waiting')
        self.assertEqual(producer.state, 'done')
        self.assertEqual(self.counter(), 10)
        self.drain()
        self.assertEqual(waiting.state, 'done')

    def test_same_queue_and_alias_cannot_overtake_blocked_head(self):
        waiting = self.submit(self.Q1, waits=[(self.sem, 10)])
        later = self.submit(self.ALIAS)
        self.e.transfers.poll()
        self.assertEqual(waiting.state, 'waiting')
        self.assertEqual(later.state, 'queued')
        self.f.signal(10, self.sem)
        self.drain()
        self.assertEqual((waiting.state, later.state), ('done', 'done'))

    def test_internal_job_is_a_context_ordering_barrier(self):
        waiting = self.submit(self.Q1, waits=[(self.sem, 10)])
        internal = self.e.transfers.enqueue(self.context, ())
        producer = self.submit(self.Q2, signals=[(self.sem, 10)])
        self.e.transfers.poll()
        self.assertEqual((waiting.state, internal.state, producer.state),
                         ('waiting', 'queued', 'queued'))
        self.f.signal(5, self.sem)
        # This host signal cannot overtake the already-reserved value10.
        with self.assertRaises(ValueError):
            self.f.signal(10, self.sem)
        self.e.retire_context(1)
        self.assertFalse(self.e.transfers.active)

    def test_reserved_signals_complete_in_value_order_across_lanes(self):
        first = self.submit(self.Q1, signals=[(self.sem, 10)])
        second = self.submit(self.Q2, signals=[(self.sem, 20)])
        self.e.transfers.lane_cursors[id(self.context)] = 1
        self.e.transfers.poll()
        self.assertEqual(first.state, 'done')
        self.assertEqual(second.state, 'waiting')
        self.drain()
        self.assertEqual(self.counter(), 20)
        self.assertFalse(self.e.submissions.timelines.jobs.pending)

    def test_rejected_signal_and_failed_admission_do_not_reserve_values(self):
        self.submit(self.Q1, signals=[(self.sem, 10)])
        for signals in ([(self.sem, 10)], [(self.sem, 5)]):
            data = self.packet(self.Q2, signals=signals)
            with self.assertRaises(ValueError):
                self.e.submissions._submit(self.context,
                    struct.unpack('<%dI' % (len(data) // 4), data))
        self.e.transfers.max_jobs = 1
        data = self.packet(self.Q2, signals=[(self.sem, 20)])
        with self.assertRaises(MemoryError):
            self.e.submissions._submit(self.context,
                struct.unpack('<%dI' % (len(data) // 4), data))
        self.assertEqual([s.value for q in self.e.submissions.timelines.jobs.pending.values()
                          for s in q], [10])
        self.e.transfers.max_jobs = 128
        self.drain()
        self.assertEqual(self.counter(), 10)

    def test_same_batch_signal_must_exceed_its_wait_value(self):
        data = self.packet(self.Q1, waits=[(self.sem, 10)], signals=[(self.sem, 5)])
        with self.assertRaises(ValueError):
            self.e.submissions._submit(self.context,
                struct.unpack('<%dI' % (len(data) // 4), data))
        self.assertFalse(self.e.transfers.active)

    def test_producer_io_failure_faults_waiter_without_false_counter(self):
        owner = self.e.memory(1, self.w.MEMORY)
        cb = 0x500020002002
        setup = self.w.transfer_commands(0x500000002000, 0x500010002001, cb,
                                         0x500030002003, 0x500040002004)
        self.e.execute(1, setup)
        waiting = self.submit(self.Q1, waits=[(self.sem, 10)])
        producer = self.submit(self.Q2, signals=[(self.sem, 10)], buffers=[cb])
        with patch.object(self.f.state.aperture, 'write', side_effect=OSError('DMA fault')):
            self.e.transfers.poll()
        self.drain()
        self.assertEqual((producer.state, waiting.state), ('faulted', 'faulted'))
        self.assertEqual(self.counter(), 0)
        self.assertEqual(owner.work_refs, 0)

    def test_context_reset_cancels_blocked_values_and_drains_pins(self):
        waiting = self.submit(self.Q1, waits=[(self.sem, 10)])
        self.e.retire_context(1)
        self.assertEqual(waiting.state, 'cancelled')
        self.assertFalse(self.e.submissions.timelines.jobs.pending)
        self.assertFalse(self.e.submissions.timelines.values)
        self.assertFalse(self.e.transfers.lane_cursors)

    def test_binary_resignal_cannot_overtake_unconsumed_wait_on_another_lane(self):
        binary = 0x500050002005
        self.f.execute('vkCreateSemaphore', device=self.w.DEVICE,
            pCreateInfo=self.w.structure('VkSemaphoreCreateInfo', pNext=[], flags=0),
            pSemaphore=binary)
        first = self.submit(self.Q1, signals=[(binary, 0)])
        consumer = self.submit(self.Q2, waits=[(binary, 0), (self.sem, 10)])
        second = self.submit(self.ALIAS, signals=[(binary, 0)])
        self.e.transfers.poll()
        self.assertEqual(first.state, 'done')
        self.e.transfers.poll()
        self.assertEqual((consumer.state, second.state), ('waiting', 'waiting'))
        self.f.signal(10, self.sem)
        self.drain()
        self.assertEqual((consumer.state, second.state), ('done', 'done'))

    def test_ready_lanes_round_robin_while_large_transfer_is_running(self):
        cb = 0x500020002002
        setup = self.w.transfer_commands(0x500000002000, 0x500010002001, cb,
                                         0x500030002003, 0x500040002004)
        self.e.execute(1, setup)
        self.e.transfers.chunk_bytes = 256
        large = self.submit(self.Q1, buffers=[cb])
        other = self.submit(self.Q2, signals=[(self.sem, 10)])
        self.e.transfers.poll()
        self.assertEqual(large.state, 'running')
        self.assertEqual(large.position, 256)
        self.e.transfers.poll()
        self.assertEqual((large.state, other.state), ('running', 'done'))
        self.assertEqual(self.counter(), 10)
        self.drain()
        self.assertEqual(large.state, 'done')

    def test_commit_fault_uses_registered_completion_to_release_all_leases(self):
        data = self.packet(self.Q1, signals=[(self.sem, 10)])
        with patch('vn_timeline_jobs.TimelineReservation.commit',
                   side_effect=MemoryError('commit failed')):
            with self.assertRaises(MemoryError):
                self.e.execute(1, data)
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.context.frontend.ent[
            self.context.frontend.idmap[self.Q1]]['pins'], 0)
        self.assertEqual(self.context.frontend.ent[
            self.context.frontend.idmap[self.sem]]['pins'], 0)


if __name__ == '__main__':
    unittest.main()
