# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Real-wire recording, bounded transfer replay and pending-object lifetime."""
import unittest
from unittest.mock import patch

from native_test_wire import NativeWire
from vn_memory import ApertureState
from vn_memory_blobs import MemoryBlobs
from vn_native_execution import ExecutionService


class ReplayTests(unittest.TestCase):
    BUFFER, POOL, CB, SECONDARY = (0x400040001004, 0x400050001005,
                                  0x400060001006, 0x400070001007)

    def setUp(self):
        self.state = ApertureState(65536, 32768)
        self.blobs = MemoryBlobs(self.state)
        self.blobs.create(7, 4096)
        self.blobs.map(7, 0)
        native = getattr(self, 'native_profile', False)
        self.service = ExecutionService(self.state, self.blobs, transfer_submit=native)
        self.wire = NativeWire(native_timeline=native)
        self.service.execute(1, self.wire.boot(memory_type=0))
        self.engine = self.service.engine
        self.context = self.engine.contexts[1]
        self.front = self.context.frontend
        self.owner = self.engine.memory(1, self.wire.MEMORY)
        self.engine.transfers.chunk_bytes = 256
        self.command('vkCreateBuffer', device=self.wire.DEVICE,
                     pCreateInfo=self.wire.structure(
                         'VkBufferCreateInfo', pNext=[], flags=0, size=4096,
                         usage=3, sharingMode=0, queueFamilyIndexCount=0,
                         pQueueFamilyIndices=[]), pBuffer=self.BUFFER)
        self.command('vkBindBufferMemory', device=self.wire.DEVICE,
                     buffer=self.BUFFER, memory=self.wire.MEMORY, memoryOffset=0)
        self.command('vkCreateCommandPool', device=self.wire.DEVICE,
                     pCreateInfo=self.wire.structure(
                         'VkCommandPoolCreateInfo', pNext=[], flags=2,
                         queueFamilyIndex=0), pCommandPool=self.POOL)
        self.allocate(self.CB)

    def command(self, name, **kwargs):
        return self.service.execute(1, self.wire.command(name, **kwargs))

    def allocate(self, handle, level=0):
        self.command('vkAllocateCommandBuffers', device=self.wire.DEVICE,
                     pAllocateInfo=self.wire.structure(
                         'VkCommandBufferAllocateInfo', pNext=[], commandPool=self.POOL,
                         level=level, commandBufferCount=1), pCommandBuffers=[handle])

    def entry(self, handle):
        status, _, entry = self.front.resolve(handle, 0)
        self.assertEqual(status, 'OK')
        return entry

    def begin(self, handle=None, flags=0):
        return self.command(
            'vkBeginCommandBuffer', commandBuffer=handle or self.CB,
            pBeginInfo=self.wire.structure('VkCommandBufferBeginInfo',
                                           pNext=[], flags=flags, pInheritanceInfo=None))

    def end(self, handle=None):
        self.command('vkEndCommandBuffer', commandBuffer=handle or self.CB)

    def fill(self, handle=None, offset=0, size=1024):
        self.command('vkCmdFillBuffer', commandBuffer=handle or self.CB,
                     dstBuffer=self.BUFFER, dstOffset=offset, size=size, data=0x64636261)

    def recorded(self, flags=0):
        self.begin(flags=flags)
        self.fill()
        self.end()

    def enqueue(self):
        return self.engine.replay.enqueue(1, [self.CB])

    def drain(self):
        for _ in range(64):
            if not self.service.active:
                return
            self.service.poll()
        self.fail('replay did not drain within the sampled bound')

    def resume(self, task):
        self.assertEqual(task.state, 'waiting')
        self.drain()
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')

    def test_wire_recording_replays_real_fill_and_retires_object_leases(self):
        self.recorded()
        job = self.enqueue()
        self.assertEqual(self.entry(self.CB)['state'] & 15, self.engine.golden.CB_PEND)
        self.assertGreater(self.entry(self.POOL)['pins'], 0)
        self.assertEqual(self.state.aperture.read(self.owner.base, 4), b'\0' * 4)
        self.service.poll()
        self.assertEqual(job.position, 256)
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.state.aperture.read(self.owner.base, 1024), b'abcd' * 256)
        self.assertEqual(self.entry(self.CB)['state'] & 15, self.engine.golden.CB_EXEC)
        self.assertFalse(self.engine.replay.held)
        self.assertEqual(self.entry(self.POOL)['pins'], 0)

    def test_update_payload_is_snapshotted_and_copy_observes_prior_work(self):
        self.begin()
        self.fill()
        self.command('vkCmdUpdateBuffer', commandBuffer=self.CB, dstBuffer=self.BUFFER,
                     dstOffset=0, dataSize=4, pData=b'last')
        self.command('vkCmdCopyBuffer', commandBuffer=self.CB, srcBuffer=self.BUFFER,
                     dstBuffer=self.BUFFER, regionCount=1,
                     pRegions=[self.wire.structure('VkBufferCopy',
                                                  srcOffset=0, dstOffset=2048, size=1024)])
        self.end()
        job = self.enqueue()
        records = self.front.cbd[self.front.idmap[self.CB]]['recs']
        self.front.pay[records[1]['imm'][7] + 4] = 0
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.state.aperture.read(self.owner.base + 2048, 1024),
                         b'last' + b'abcd' * 255)

    def test_begin_and_idle_wait_for_actual_replay_retirement(self):
        self.recorded()
        self.enqueue()
        begin = self.begin()
        idle = self.command('vkDeviceWaitIdle', device=self.wire.DEVICE)
        self.resume(idle)
        begin.advance([256, 65536])
        self.assertEqual(begin.state, 'done')
        self.assertEqual(self.entry(self.CB)['state'] & 15, self.engine.golden.CB_REC)

    def test_pool_reset_and_buffer_destroy_cannot_reclaim_pending_records(self):
        self.recorded()
        self.enqueue()
        reset = self.command('vkResetCommandPool', device=self.wire.DEVICE,
                             commandPool=self.POOL, flags=0)
        destroy = self.command('vkDestroyBuffer', device=self.wire.DEVICE,
                               buffer=self.BUFFER)
        self.assertIn(self.BUFFER, self.front.idmap)
        self.resume(destroy)
        reset.advance([256, 65536])
        self.assertEqual(reset.state, 'done')
        self.assertNotIn(self.BUFFER, self.front.idmap)

    def test_free_command_buffers_defers_until_leases_release(self):
        self.recorded()
        self.enqueue()
        free = self.command('vkFreeCommandBuffers', device=self.wire.DEVICE,
                            commandPool=self.POOL, commandBufferCount=1,
                            pCommandBuffers=[self.CB])
        self.resume(free)
        self.assertNotIn(self.CB, self.front.idmap)

    def test_empty_and_one_time_buffers_have_truthful_retirement_states(self):
        self.begin()
        self.end()
        empty = self.enqueue()
        self.assertEqual(empty.state, 'queued')
        self.drain()
        self.assertEqual(empty.state, 'done')
        self.recorded(flags=1)
        once = self.enqueue()
        self.drain()
        self.assertEqual(once.state, 'done')
        self.assertEqual(self.entry(self.CB)['state'] & 15, self.engine.golden.CB_INV)
        with self.assertRaises(ValueError):
            self.enqueue()

    def test_secondary_stream_is_bounded_and_pinned_with_its_primary(self):
        self.allocate(self.SECONDARY, level=1)
        self.begin(self.SECONDARY)
        self.fill(self.SECONDARY)
        self.end(self.SECONDARY)
        self.begin()
        self.command('vkCmdExecuteCommands', commandBuffer=self.CB,
                     commandBufferCount=1, pCommandBuffers=[self.SECONDARY])
        self.end()
        job = self.enqueue()
        self.assertEqual(self.entry(self.SECONDARY)['state'] & 15, self.engine.golden.CB_PEND)
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.entry(self.SECONDARY)['pins'], 0)

    def test_nested_secondaries_and_unsupported_work_reject_before_writes(self):
        self.allocate(self.SECONDARY, level=1)
        self.begin(self.SECONDARY)
        self.command('vkCmdExecuteCommands', commandBuffer=self.SECONDARY,
                     commandBufferCount=1, pCommandBuffers=[self.SECONDARY])
        self.end(self.SECONDARY)
        self.begin()
        self.command('vkCmdExecuteCommands', commandBuffer=self.CB,
                     commandBufferCount=1, pCommandBuffers=[self.SECONDARY])
        self.end()
        with self.assertRaises(ValueError):
            self.enqueue()
        self.begin()
        self.fill()
        self.command('vkCmdDispatch', commandBuffer=self.CB,
                     groupCountX=1, groupCountY=1, groupCountZ=1)
        self.end()
        with self.assertRaisesRegex(ValueError, 'unsupported replay'):
            self.enqueue()
        self.assertEqual(self.state.aperture.read(self.owner.base, 4), b'\0' * 4)
        self.assertFalse(self.engine.replay.held)

    def test_stale_memory_generation_and_cross_region_overlap_reject(self):
        self.recorded()
        self.command('vkFreeMemory', device=self.wire.DEVICE, memory=self.wire.MEMORY)
        self.service.execute(1, self.wire.allocate(memory_type=0))
        with self.assertRaises(KeyError):
            self.enqueue()
        self.command('vkBindBufferMemory', device=self.wire.DEVICE,
                     buffer=self.BUFFER, memory=self.wire.MEMORY, memoryOffset=0)
        self.begin()
        self.command('vkCmdCopyBuffer', commandBuffer=self.CB, srcBuffer=self.BUFFER,
                     dstBuffer=self.BUFFER, regionCount=2,
                     pRegions=[self.wire.structure('VkBufferCopy', srcOffset=s,
                                                  dstOffset=d, size=4)
                               for s, d in ((0, 8), (16, 0))])
        self.end()
        with self.assertRaisesRegex(ValueError, 'overlap'):
            self.enqueue()

    def test_record_payload_and_operation_budgets_fail_before_admission(self):
        self.begin()
        self.fill()
        self.fill(offset=1024)
        self.end()
        for owner, field, value in ((self.engine, 'max_commands', 1),
                                    (self.engine, 'max_bytes', 16),
                                    (self.engine.transfers, 'max_operations', 1)):
            with patch.object(owner, field, value):
                with self.assertRaises((MemoryError, ValueError)):
                    self.enqueue()
            self.assertFalse(self.engine.replay.held)
            self.assertEqual(self.entry(self.CB)['pins'], 0)

    def test_memory_pin_failure_restores_all_object_states_transactionally(self):
        self.recorded()
        with patch.object(self.owner, 'pin_work', side_effect=MemoryError('pin full')):
            with self.assertRaises(MemoryError):
                self.enqueue()
        self.assertFalse(self.engine.replay.held)
        self.assertEqual(self.entry(self.CB)['state'] & 15, self.engine.golden.CB_EXEC)
        self.assertTrue(all(entry is None or entry['pins'] == 0 for entry in self.front.ent))

    def test_reset_and_pending_resubmit_cannot_reuse_old_object_pins(self):
        self.recorded()
        job = self.enqueue()
        with self.assertRaises(BlockingIOError):
            self.enqueue()
        self.service.reset()
        self.assertEqual(job.state, 'cancelled')
        self.assertFalse(self.engine.replay.held)
        self.assertFalse(self.front.idmap)
        self.assertEqual(self.owner.work_refs, 0)

    def test_whole_size_uses_buffer_bounds_and_stale_descriptor_rejects(self):
        self.begin()
        self.fill(offset=4092, size=(1 << 64) - 1)
        self.end()
        job = self.enqueue()
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.state.aperture.read(self.owner.base + 4088, 12),
                         b'\0' * 4 + b'abcd' + b'\0' * 4)
        descriptor = self.front.cbd[self.front.idmap[self.CB]]
        descriptor['addr'] += 64
        with self.assertRaises(ValueError):
            self.enqueue()
        self.assertFalse(self.engine.replay.held)


if __name__ == '__main__':
    unittest.main()
