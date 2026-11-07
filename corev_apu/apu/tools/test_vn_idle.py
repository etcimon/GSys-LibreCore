# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Queue/device-scoped idle continuations, alias identity and failure feedback."""
import struct
import unittest
from unittest.mock import patch

import test_vn_timeline_jobs as queue_fixture


class IdleTests(unittest.TestCase):
    def setUp(self):
        self.q = queue_fixture.TimelineJobTests()
        self.q.setUp()
        self.f, self.e, self.w, self.context = self.q.f, self.q.e, self.q.w, self.q.context

    def idle(self, *, queue=None, device=None):
        self.f.execute('vkSeekReplyCommandStreamMESA', position=0)
        if queue is not None:
            return self.f.execute('vkQueueWaitIdle', queue=queue)
        return self.f.execute('vkDeviceWaitIdle', device=device or self.w.DEVICE)

    def result(self):
        return struct.unpack('<II', self.f.blobs.read(self.f.mapping, 0, 8))[1]

    def foreign_device(self):
        device = 0x400180001018
        self.f.execute('vkCreateDevice', physicalDevice=self.w.PHYSICAL, pDevice=device,
            pCreateInfo=self.w.structure('VkDeviceCreateInfo', pNext=[], flags=0,
                queueCreateInfoCount=1, pQueueCreateInfos=[self.w.structure(
                    'VkDeviceQueueCreateInfo', pNext=[], flags=0, queueFamilyIndex=0,
                    queueCount=1, pQueuePriorities=[0x3F800000])],
                enabledLayerCount=0, ppEnabledLayerNames=[], enabledExtensionCount=0,
                ppEnabledExtensionNames=[], pEnabledFeatures=None))
        return device

    def test_idle_queue_does_not_wait_for_unrelated_parked_queue(self):
        waiting = self.q.submit(self.q.Q1, waits=[(self.q.sem, 10)])
        self.assertIsInstance(self.idle(queue=self.q.Q2), int)
        self.assertEqual(self.result(), 0)
        self.assertTrue(self.e.transfers.active)
        self.f.signal(10, self.q.sem)
        self.q.drain()
        self.assertEqual(waiting.state, 'done')

    def test_queue_alias_waits_for_same_lane_then_resumes(self):
        self.q.submit(self.q.Q1, waits=[(self.q.sem, 10)])
        task = self.idle(queue=self.q.ALIAS)
        self.assertEqual(task.state, 'waiting')
        self.f.signal(10, self.q.sem)
        self.q.drain()
        task.advance([256, 65536])
        self.assertEqual((task.state, self.result()), ('done', 0))

    def test_device_idle_waits_for_all_its_queues(self):
        self.q.submit(self.q.Q1, waits=[(self.q.sem, 10)])
        task = self.idle()
        self.assertEqual(task.state, 'waiting')
        self.f.signal(10, self.q.sem)
        self.q.drain()
        task.advance([256, 65536])
        self.assertEqual((task.state, self.result()), ('done', 0))

    def test_other_device_is_not_blocked_by_foreign_native_lanes(self):
        device = self.foreign_device()
        self.q.submit(self.q.Q1, waits=[(self.q.sem, 10)])
        self.assertIsInstance(self.idle(device=device), int)
        self.assertEqual(self.result(), 0)
        self.e.retire_context(1)

    def test_internal_context_wide_job_still_blocks_queue_idle(self):
        self.e.transfers.enqueue(self.context, ())
        task = self.idle(queue=self.q.Q2)
        self.assertEqual(task.state, 'waiting')
        self.e.transfers.poll()
        task.advance([256, 65536])
        self.assertEqual((task.state, self.result()), ('done', 0))

    def test_suspended_queue_idle_rejects_reused_alias_generation(self):
        self.q.submit(self.q.Q1, waits=[(self.q.sem, 10)])
        task = self.idle(queue=self.q.ALIAS)
        self.context.frontend.retire(self.q.ALIAS, self.e.golden.KIND['VkQueue'])
        self.f.execute('vkGetDeviceQueue', device=self.w.DEVICE, queueFamilyIndex=0,
                       queueIndex=0, pQueue=self.q.ALIAS)
        with self.assertRaisesRegex(KeyError, 'generation'):
            task.advance([256, 65536])
        self.assertEqual(task.state, 'faulted')
        self.e.retire_context(1)

    def test_suspended_queue_idle_rejects_changed_lane_identity(self):
        self.q.submit(self.q.Q1, waits=[(self.q.sem, 10)])
        task = self.idle(queue=self.q.ALIAS)
        slot = self.context.frontend.idmap[self.q.ALIAS]
        entry = self.context.frontend.ent[slot]
        entry['native_lane'] = (*entry['native_lane'][:2], 2)
        with self.assertRaisesRegex(KeyError, 'scope'):
            task.advance([256, 65536])
        self.e.retire_context(1)

    def test_context_reset_cancels_idle_and_releases_queued_pins(self):
        job = self.q.submit(self.q.Q1, waits=[(self.q.sem, 10)])
        task = self.idle(queue=self.q.Q1)
        self.e.retire_context(1)
        self.assertEqual((task.state, job.state), ('cancelled', 'cancelled'))
        self.assertFalse(self.e.transfers.active)
        self.assertFalse(self.e.tasks)

    def test_fault_returns_lost_without_waiting_for_other_queued_work(self):
        cb = 0x500020002002
        self.e.execute(1, self.w.transfer_commands(0x500000002000, 0x500010002001,
                                                  cb, 0x500030002003, 0x500040002004))
        self.q.submit(self.q.Q2, waits=[(self.q.sem, 10)])
        producer = self.q.submit(self.q.Q1, buffers=[cb])
        task = self.idle(queue=self.q.Q1)
        with patch.object(self.f.state.aperture, 'write', side_effect=OSError('DMA fault')):
            self.e.transfers.poll()
        self.assertEqual(producer.state, 'faulted')
        task.advance([256, 65536])
        self.assertEqual((task.state, self.result()), ('done', self.e.golden.VK_ERR_LOST))
        self.assertIsInstance(self.idle(), int)
        self.assertEqual(self.result(), self.e.golden.VK_ERR_LOST)
        self.q.drain()

    def test_parked_idle_does_not_replay_prior_host_signal(self):
        self.q.submit(self.q.Q1, waits=[(self.q.sem, 10)])
        value = (1 << 40) + 2
        prefix = self.w.command('vkSignalSemaphore', device=self.w.DEVICE,
            pSignalInfo=self.w.structure('VkSemaphoreSignalInfo', pNext=[],
                                        semaphore=self.f.SEM, value=value))
        task = self.e.execute(1, prefix + self.w.command('vkQueueWaitIdle', queue=self.q.Q1))
        task.advance([256, 65536])
        task.advance([256, 65536])
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(self.f.counter(self.f.SEM)[2], value)
        self.f.signal(10, self.q.sem)
        self.q.drain()
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')


if __name__ == '__main__':
    unittest.main()
