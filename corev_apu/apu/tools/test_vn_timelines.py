# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Host-only timeline API extension without modifying the RTL decoder profile."""
import struct
import unittest

from native_test_wire import NativeWire
from vn_memory import ApertureState
from vn_memory_blobs import MemoryBlobs
from vn_native_execution import LinearExecution, StreamFault, load_decoder


class TimelineTests(unittest.TestCase):
    SEM, SECOND = 0x4000A000100A, 0x4000B000100B

    def setUp(self):
        self.state = ApertureState(65536, 32768)
        self.blobs = MemoryBlobs(self.state)
        self.blobs.create(7, 4096)
        self.mapping = self.blobs.map(7, 0)
        self.e = LinearExecution(self.state, self.blobs, transfer_submit=True)
        self.w = NativeWire(native_timeline=True)
        self.e.execute(1, self.w.boot(memory_type=0))
        self.create(self.SEM, (1 << 40) + 1)

    def execute(self, name, **kwargs):
        return self.e.execute(1, self.w.command(name, **kwargs))

    def create(self, semaphore, value):
        info = self.w.structure('VkSemaphoreTypeCreateInfo', semaphoreType=1,
                                initialValue=value)
        return self.execute('vkCreateSemaphore', device=self.w.DEVICE,
            pCreateInfo=self.w.structure('VkSemaphoreCreateInfo', flags=0, pNext=[info]),
            pSemaphore=semaphore)

    def signal(self, value, semaphore=None):
        return self.execute('vkSignalSemaphore', device=self.w.DEVICE,
            pSignalInfo=self.w.structure('VkSemaphoreSignalInfo', pNext=[],
                                         semaphore=semaphore or self.SEM, value=value))

    def counter(self, semaphore=None):
        self.execute('vkSeekReplyCommandStreamMESA', position=0)
        self.execute('vkGetSemaphoreCounterValue', device=self.w.DEVICE,
                     semaphore=semaphore or self.SEM, pValue=0)
        reply, result, presence, value = struct.unpack(
            '<IIQQ', self.blobs.read(self.mapping, 0, 24))
        self.assertEqual(presence, 1)
        return reply, result, value

    def wait(self, targets, timeout=(1 << 64) - 1, flags=0):
        return self.execute('vkWaitSemaphores', device=self.w.DEVICE,
            pWaitInfo=self.w.structure('VkSemaphoreWaitInfo', pNext=[], flags=flags,
                semaphoreCount=len(targets), pSemaphores=[s for s, v in targets],
                pValues=[v for s, v in targets]), timeout=timeout)

    def test_creation_counter_and_host_signal_preserve_full_u64(self):
        self.assertEqual(self.counter()[1:], (0, (1 << 40) + 1))
        self.signal((1 << 63) + 10)
        self.assertEqual(self.counter()[1:], (0, (1 << 63) + 10))

    def test_signal_must_increase_without_mutating_counter_on_failure(self):
        current = (1 << 40) + 1
        with self.assertRaises(ValueError):
            self.signal(current)
        values = self.e.submissions.timelines.values
        self.assertEqual(list(values.values()), [current])

    def test_zero_timeout_and_finite_wait_return_vk_timeout(self):
        self.execute('vkSeekReplyCommandStreamMESA', position=0)
        self.wait([(self.SEM, 1 << 50)], timeout=0)
        self.assertEqual(struct.unpack('<II', self.blobs.read(self.mapping, 0, 8))[1], 2)
        now = [1.]
        self.e.submissions.clock = lambda: now[0]
        self.execute('vkSeekReplyCommandStreamMESA', position=0)
        task = self.wait([(self.SEM, 1 << 50)], timeout=1000000)
        self.assertEqual(task.state, 'waiting')
        now[0] += .002
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')
        self.assertEqual(struct.unpack('<II', self.blobs.read(self.mapping, 0, 8))[1], 2)

    def test_infinite_wait_wakes_from_later_host_signal(self):
        task = self.wait([(self.SEM, 1 << 50)])
        self.assertEqual(task.state, 'waiting')
        self.signal(1 << 50)
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')

    def test_wait_any_and_all_compare_independent_counters(self):
        self.create(self.SECOND, 3)
        self.assertIsInstance(self.wait([(self.SEM, 1), (self.SECOND, 4)], flags=1), int)
        task = self.wait([(self.SEM, 1), (self.SECOND, 4)])
        self.assertEqual(task.state, 'waiting')
        self.signal(4, self.SECOND)
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')

    def test_suspended_wait_rejects_object_id_reuse(self):
        task = self.wait([(self.SEM, 1 << 50)])
        self.execute('vkDestroySemaphore', device=self.w.DEVICE, semaphore=self.SEM)
        self.create(self.SEM, 1 << 60)
        with self.assertRaises(KeyError):
            task.advance([256, 65536])
        task.cancel()

    def test_context_retirement_discards_counters_and_waits(self):
        task = self.wait([(self.SEM, 1 << 50)])
        self.e.retire_context(1)
        self.assertEqual(task.state, 'cancelled')
        self.assertFalse(self.e.submissions.timelines.values)

    def test_host_feedback_reports_device_lost_after_context_fault(self):
        context = self.e.contexts[1]
        self.e.submissions.faults.add(id(context))
        # counter/signal/wait all report DEVICE_LOST; no payload is written
        self.execute('vkSeekReplyCommandStreamMESA', position=0)
        self.execute('vkGetSemaphoreCounterValue', device=self.w.DEVICE,
                     semaphore=self.SEM, pValue=0)
        self.assertEqual(struct.unpack('<II', self.blobs.read(
            self.mapping, 0, 8))[1], 0xFFFFFFFC)
        self.execute('vkSeekReplyCommandStreamMESA', position=0)
        self.signal(1 << 62)
        self.assertEqual(struct.unpack('<II', self.blobs.read(
            self.mapping, 0, 8))[1], 0xFFFFFFFC)
        self.execute('vkSeekReplyCommandStreamMESA', position=0)
        self.wait([(self.SEM, 1 << 62)], timeout=0)
        self.assertEqual(struct.unpack('<II', self.blobs.read(
            self.mapping, 0, 8))[1], 0xFFFFFFFC)
        self.e.submissions.faults.discard(id(context))
        self.assertEqual(self.counter()[1], 0)

    def test_native_decoder_extension_preserves_legacy_wire_ids_and_kinds(self):
        _, base, _ = load_decoder()
        _, extended, _ = load_decoder(True)
        self.assertEqual(base.kind_names, extended.kind_names)
        for name, info in base.cmd_info.items():
            for field in ('type_id', 'reply_id', 'obj_kind', 'q_info', 'act', 'slots'):
                self.assertEqual(info[field], extended.cmd_info[name][field], (name, field))
        self.assertNotIn('VkSemaphoreTypeCreateInfo', base.profile['chain_structs'])
        self.assertIn('VkSemaphoreTypeCreateInfo', extended.profile['chain_structs'])
        self.assertNotIn('vkWaitSemaphores', base.cmd_info)
        self.assertIn('vkWaitSemaphores', extended.cmd_info)

    def test_default_decoder_refuses_timeline_command(self):
        base = LinearExecution(self.state, self.blobs)
        with self.assertRaises(StreamFault):
            base.execute(2, self.w.command('vkSignalSemaphore', device=self.w.DEVICE,
                pSignalInfo=self.w.structure('VkSemaphoreSignalInfo', pNext=[],
                                             semaphore=self.SEM, value=1)))

    def test_binary_semaphore_cannot_be_queried_as_a_timeline(self):
        self.execute('vkCreateSemaphore', device=self.w.DEVICE,
            pCreateInfo=self.w.structure('VkSemaphoreCreateInfo', pNext=[], flags=0),
            pSemaphore=self.SECOND)
        with self.assertRaises(KeyError):
            self.counter(self.SECOND)
        self.assertEqual(len(self.e.submissions.timelines.values), 1)

    def test_missing_output_pointer_and_empty_wait_reject_without_counter_writes(self):
        context = self.e.contexts[1]
        data = self.w.command('vkGetSemaphoreCounterValue', device=self.w.DEVICE,
                              semaphore=self.SEM, pValue=None)
        with self.assertRaises(ValueError):
            self.e.submissions.timelines.host(context, 'vkGetSemaphoreCounterValue',
                struct.unpack('<%dI' % (len(data) // 4), data))
        with self.assertRaises(ValueError):
            self.wait([])
        self.assertEqual(list(self.e.submissions.timelines.values.values()), [(1 << 40) + 1])


if __name__ == '__main__':
    unittest.main()
