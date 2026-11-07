# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded binary semaphore reservations and actual transfer retirement."""
import struct
import unittest
from unittest.mock import patch

import test_vn_submit as submit_fixture


class SemaphoreTests(unittest.TestCase):
    SEM = 0x4000A000100A

    def setUp(self):
        self.f = submit_fixture.SubmissionTests()
        self.f.setUp()
        self.e, self.w = self.f.e, self.f.wire
        self.f.f.command('vkCreateSemaphore', device=self.w.DEVICE,
                        pCreateInfo=self.w.structure('VkSemaphoreCreateInfo',
                                                    pNext=[], flags=0),
                        pSemaphore=self.SEM)

    def packet(self, waits=(), signals=()):
        data = self.w.command('vkQueueSubmit', queue=self.f.QUEUE, submitCount=1,
            pSubmits=[self.w.structure('VkSubmitInfo', pNext=[],
                waitSemaphoreCount=len(waits), pWaitSemaphores=list(waits),
                pWaitDstStageMask=[0x1000] * len(waits), commandBufferCount=0,
                pCommandBuffers=[], signalSemaphoreCount=len(signals),
                pSignalSemaphores=list(signals))], fence=0)
        return data[:4] + struct.pack('<I', 0) + data[8:]

    def submit(self, waits=(), signals=()):
        return self.f.execute(self.packet(waits, signals))

    def test_pending_signal_wait_and_resignal_follow_executor_order(self):
        self.submit(signals=[self.SEM])
        self.submit(waits=[self.SEM])
        self.submit(signals=[self.SEM])
        self.submit(waits=[self.SEM])
        self.assertEqual(self.e.transfers.pending, 4)
        self.f.f.drain()
        self.assertFalse(self.e.submissions.semaphores.tokens)
        self.assertEqual(self.f.f.entry(self.SEM)['pins'], 0)

    def test_unsubmitted_wait_rejects_without_leases(self):
        with self.assertRaises(ValueError):
            self.submit(waits=[self.SEM])
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.f.entry(self.SEM)['pins'], 0)

    def test_duplicate_alias_and_double_signal_reject_before_reservation(self):
        manager = self.e.submissions.semaphores
        context = self.f.f.context
        handle, entry = self.e.submissions._object(context, self.SEM, 'VkSemaphore')
        for signals in ([self.SEM, self.SEM], [self.SEM, handle]):
            with self.assertRaises(ValueError):
                manager.plan(context, [], signals, entry['parent'])
        self.submit(signals=[self.SEM])
        with self.assertRaises(ValueError):
            manager.plan(context, [], [self.SEM], entry['parent'])
        self.assertEqual(self.e.transfers.pending, 1)
        self.assertEqual(len(manager.tokens[(id(context), handle)]), 1)
        self.f.f.drain()

    def test_failed_enqueue_leaves_signal_unclaimed_and_rolls_back_pins(self):
        self.submit(signals=[self.SEM])
        data = self.packet(waits=[self.SEM])
        self.e.transfers.max_jobs = 1
        with self.assertRaises(MemoryError):
            self.e.submissions._submit(self.f.f.context,
                struct.unpack('<%dI' % (len(data) // 4), data))
        token = next(iter(self.e.submissions.semaphores.tokens.values()))[0]
        self.assertFalse(token.claimed)
        self.assertEqual(self.f.f.entry(self.SEM)['pins'], 1)
        self.e.transfers.max_jobs = 128
        self.submit(waits=[self.SEM])
        self.f.f.drain()
        self.assertFalse(self.e.submissions.semaphores.tokens)

    def test_late_semaphore_pin_failure_rolls_back_queue_pin(self):
        semaphore = self.f.f.entry(self.SEM)
        semaphore['pins'] = 255
        data = self.packet(signals=[self.SEM])
        try:
            with self.assertRaises(MemoryError):
                self.e.submissions._submit(self.f.f.context,
                    struct.unpack('<%dI' % (len(data) // 4), data))
            self.assertEqual(self.f.f.entry(self.f.QUEUE)['pins'], 0)
            self.assertFalse(self.e.submissions.semaphores.tokens)
            self.assertFalse(self.e.transfers.active)
        finally:
            semaphore['pins'] = 0

    def test_timeline_chain_and_unknown_create_flags_reject_before_allocation(self):
        handle = self.SEM + 1
        data = self.w.command('vkCreateSemaphore', device=self.w.DEVICE,
            pCreateInfo=self.w.structure('VkSemaphoreCreateInfo', pNext=[], flags=0),
            pSemaphore=handle)
        words = list(struct.unpack('<%dI' % (len(data) // 4), data))
        for index in (7, 9):
            changed = words.copy()
            changed[index] = 1
            with self.assertRaises(ValueError):
                self.e.submissions.validate_command('vkCreateSemaphore', changed)
        chain = self.w.structure('VkSemaphoreTypeCreateInfo',
                                 semaphoreType=1, initialValue=10)
        timeline = self.w.command('vkCreateSemaphore', device=self.w.DEVICE,
            pCreateInfo=self.w.structure('VkSemaphoreCreateInfo', pNext=[chain], flags=0),
            pSemaphore=handle)
        self.assertEqual(self.e.submissions.validate_command('vkCreateSemaphore',
            struct.unpack('<%dI' % (len(timeline) // 4), timeline)), (1, 10))
        self.assertNotIn(handle, self.f.f.front.idmap)

    def test_destroy_recreate_does_not_inherit_old_signal_generation(self):
        self.submit(signals=[self.SEM])
        self.f.f.drain()
        old, _ = self.e.submissions._object(self.f.f.context, self.SEM, 'VkSemaphore')
        self.f.f.command('vkDestroySemaphore', device=self.w.DEVICE, semaphore=self.SEM)
        self.f.f.command('vkCreateSemaphore', device=self.w.DEVICE,
                        pCreateInfo=self.w.structure('VkSemaphoreCreateInfo',
                                                    pNext=[], flags=0),
                        pSemaphore=self.SEM)
        new, entry = self.e.submissions._object(self.f.f.context, self.SEM, 'VkSemaphore')
        self.assertNotEqual(old, new)
        with self.assertRaises(ValueError):
            self.e.submissions.semaphores.plan(self.f.f.context, [self.SEM], [],
                                               entry['parent'])
        self.assertFalse(self.e.submissions.semaphores.tokens)

    def test_same_batch_wait_and_resignal_uses_separate_binary_tokens(self):
        self.submit(signals=[self.SEM])
        self.submit(waits=[self.SEM], signals=[self.SEM])
        self.submit(waits=[self.SEM])
        self.f.f.drain()
        self.assertFalse(self.e.submissions.semaphores.tokens)
        self.assertEqual(self.f.f.entry(self.SEM)['pins'], 0)

    def test_destroy_parks_until_pending_signal_retires_and_removes_tokens(self):
        self.submit(signals=[self.SEM])
        task = self.f.f.command('vkDestroySemaphore', device=self.w.DEVICE,
                               semaphore=self.SEM)
        self.f.f.resume(task)
        self.assertFalse(self.e.submissions.semaphores.tokens)
        self.assertFalse(self.e.submissions.semaphores.created)

    def test_failed_producer_does_not_fabricate_signal_success(self):
        self.f.f.recorded()
        data = self.w.command('vkQueueSubmit', queue=self.f.QUEUE, submitCount=1,
            pSubmits=[self.w.structure('VkSubmitInfo', pNext=[], waitSemaphoreCount=0,
                pWaitSemaphores=[], pWaitDstStageMask=[], commandBufferCount=1,
                pCommandBuffers=[self.f.f.CB], signalSemaphoreCount=1,
                pSignalSemaphores=[self.SEM])], fence=0)
        self.f.execute(data)
        self.submit(waits=[self.SEM])
        with patch.object(self.f.f.state.aperture, 'write', side_effect=OSError('DMA failure')):
            self.f.f.service.poll()
        self.f.f.drain()
        self.assertFalse(self.e.transfers.active)
        self.assertFalse(self.e.submissions.semaphores.tokens)
        self.assertEqual(self.f.f.entry(self.SEM)['pins'], 0)
        self.assertIn(id(self.f.f.context), self.e.submissions.faults)

    def test_context_reset_drains_semaphore_generation_leases(self):
        self.submit(signals=[self.SEM])
        self.submit(waits=[self.SEM])
        entry = self.f.f.entry(self.SEM)
        self.f.f.service.reset()
        self.assertEqual(entry['pins'], 0)
        self.assertFalse(self.e.submissions.semaphores.tokens)
        self.assertFalse(self.e.submissions.semaphores.created)


if __name__ == '__main__':
    unittest.main()
