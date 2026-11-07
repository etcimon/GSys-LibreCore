# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Opt-in wire queue submission and real executor-owned fence retirement."""
import struct
import unittest
from unittest.mock import patch

import test_vn_replay as replay_fixture
import test_vn_native_bridge as bridge_fixture
from vn_blob_control import CREATE_BLOB, MAP_BLOB, RESP_MAP_INFO, SUBMIT_3D
from vn_control import CTX_CREATE, RESP_NODATA
from vn_native_execution import StreamFault


class SubmissionTests(unittest.TestCase):
    QUEUE, FENCE = 0x400080001008, 0x400090001009

    def setUp(self):
        self.setup_submission()

    def setup_submission(self, *, native=False):
        self.f = replay_fixture.ReplayTests()
        self.f.native_profile = native
        self.f.setUp()
        self.e, self.wire = self.f.engine, self.f.wire
        self.e.submissions.enabled = True
        self.f.command('vkGetDeviceQueue', device=self.wire.DEVICE,
                       queueFamilyIndex=0, queueIndex=0, pQueue=self.QUEUE)
        self.f.command('vkCreateFence', device=self.wire.DEVICE,
                       pCreateInfo=self.wire.structure('VkFenceCreateInfo',
                                                       pNext=[], flags=0),
                       pFence=self.FENCE)

    def packet(self, buffers=None, *, batches=True, fence=None, waits=0, signals=0):
        buffers = [self.f.CB] if buffers is None else buffers
        data = self.wire.command(
            'vkQueueSubmit', queue=self.QUEUE, submitCount=int(batches),
            pSubmits=[self.wire.structure(
                'VkSubmitInfo', pNext=[], waitSemaphoreCount=waits,
                pWaitSemaphores=[0x123] * waits, pWaitDstStageMask=[0x1000] * waits,
                commandBufferCount=len(buffers), pCommandBuffers=buffers,
                signalSemaphoreCount=signals, pSignalSemaphores=[0x123] * signals)]
            if batches else [], fence=self.FENCE if fence is None else fence)
        return data[:4] + struct.pack('<I', 0) + data[8:]  # Stock async submit.

    def execute(self, data):
        return self.f.service.execute(1, data)

    def status(self):
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.f.command('vkGetFenceStatus', device=self.wire.DEVICE, fence=self.FENCE)
        return struct.unpack('<II', self.f.blobs.read(self.f.blobs.mapping(7), 0, 8))[1]

    def wait(self, timeout=(1 << 64) - 1):
        return self.f.command('vkWaitForFences', device=self.wire.DEVICE,
                              fenceCount=1, pFences=[self.FENCE], waitAll=1,
                              timeout=timeout)

    def test_async_submit_returns_before_real_writes_and_fence_signals(self):
        self.f.recorded()
        data = self.packet()
        self.assertEqual(self.execute(data), len(data))
        self.assertEqual(self.status(), 1)
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base, 4), b'\0' * 4)
        self.f.drain()
        self.assertEqual(self.status(), 0)
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base, 1024), b'abcd' * 256)
        self.assertFalse(self.e.submissions.pending)

    def test_infinite_wait_parks_and_zero_timeout_returns_vk_timeout(self):
        self.f.recorded()
        self.execute(self.packet())
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.wait(timeout=0)
        self.assertEqual(struct.unpack('<II', self.f.blobs.read(
            self.f.blobs.mapping(7), 0, 8))[1], 2)
        task = self.wait()
        self.f.resume(task)
        self.assertEqual(self.status(), 0)

    def test_finite_wait_uses_saved_deadline_without_replaying(self):
        now = [100.]
        self.e.submissions.clock = lambda: now[0]
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        task = self.wait(timeout=1000000)
        self.assertEqual(task.state, 'waiting')
        now[0] += .002
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')
        self.assertEqual(struct.unpack('<II', self.f.blobs.read(
            self.f.blobs.mapping(7), 0, 8))[1], 2)

    def test_empty_submit_still_retires_a_fence(self):
        self.execute(self.packet(batches=False))
        self.assertEqual(self.status(), 1)
        self.f.drain()
        self.assertEqual(self.status(), 0)

    def test_pending_fence_reset_and_destroy_wait_for_executor_release(self):
        self.f.recorded()
        self.execute(self.packet())
        task = self.f.command('vkResetFences', device=self.wire.DEVICE,
                              fenceCount=1, pFences=[self.FENCE])
        self.f.resume(task)
        self.assertEqual(self.status(), 1)
        self.execute(self.packet())
        destroy = self.f.command('vkDestroyFence', device=self.wire.DEVICE,
                                 fence=self.FENCE)
        self.f.resume(destroy)
        self.assertNotIn(self.FENCE, self.f.front.idmap)

    def test_pending_resubmit_parks_without_duplicating_first_work(self):
        self.f.recorded()
        self.execute(self.packet(fence=0))
        second = self.execute(self.packet())
        self.assertEqual(second.state, 'waiting')
        self.f.drain()
        second.advance([256, 65536])
        self.assertEqual(second.state, 'done')
        self.assertEqual(self.status(), 1)
        self.f.drain()
        self.assertEqual(self.status(), 0)

    def test_signaled_fence_creation_requires_reset_before_submit(self):
        self.f.command('vkDestroyFence', device=self.wire.DEVICE, fence=self.FENCE)
        self.f.command('vkCreateFence', device=self.wire.DEVICE,
                       pCreateInfo=self.wire.structure('VkFenceCreateInfo',
                                                       pNext=[], flags=1),
                       pFence=self.FENCE)
        self.assertEqual(self.status(), 0)
        with self.assertRaises(ValueError):
            self.e.submissions._submit(self.f.context,
                                       struct.unpack('<%dI' % (len(self.packet()) // 4),
                                                     self.packet()))
        self.assertFalse(self.e.transfers.active)

    def test_semaphore_and_declared_count_mismatch_reject_without_pins(self):
        self.f.recorded()
        for data in (self.packet(waits=1), self.packet(signals=1)):
            with self.assertRaises((ValueError, KeyError)):
                self.e.submissions._submit(self.f.context, struct.unpack(
                    '<%dI' % (len(data) // 4), data))
        data = bytearray(self.packet())
        struct.pack_into('<I', data, 5 * 4, 2)
        with self.assertRaises(ValueError):
            self.e.submissions._submit(self.f.context, struct.unpack(
                '<%dI' % (len(data) // 4), data))
        self.assertFalse(self.e.replay.held)
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.f.entry(self.FENCE)['pins'], 0)

    def test_io_failure_marks_fence_lost_after_releasing_memory(self):
        self.f.recorded()
        self.execute(self.packet())
        with patch.object(self.f.state.aperture, 'write', side_effect=OSError('DMA revoked')):
            self.f.service.poll()
        self.assertEqual(self.status(), self.e.golden.VK_ERR_LOST)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(self.e.submissions.pending)
        self.assertEqual(self.f.entry(self.FENCE)['pins'], 0)

    def test_reset_cancels_submissions_without_signaling_old_fence(self):
        self.f.recorded()
        self.execute(self.packet())
        old = self.f.entry(self.FENCE)
        self.f.service.reset()
        self.assertEqual(old['pins'], 0)
        self.assertFalse(self.e.submissions.pending)
        self.assertFalse(self.f.front.fence_sig)
        self.assertFalse(self.f.front.idmap)

    def test_memory_only_feedback_barriers_order_fill_but_images_reject(self):
        self.setup_submission(native=True)
        self.f.begin()
        values = dict(commandBuffer=self.f.CB, srcStageMask=0x1000, dstStageMask=0x4000,
                      dependencyFlags=0, memoryBarrierCount=1, pMemoryBarriers=[
                          self.wire.structure('VkMemoryBarrier', pNext=[],
                                              srcAccessMask=0x1000, dstAccessMask=0x4000)],
                      bufferMemoryBarrierCount=0, pBufferMemoryBarriers=[],
                      imageMemoryBarrierCount=0, pImageMemoryBarriers=[])
        self.f.command('vkCmdPipelineBarrier', **values)
        self.f.fill()
        self.f.command('vkCmdPipelineBarrier', **values)
        self.f.end()
        self.execute(self.packet())
        self.f.drain()
        self.assertEqual(self.status(), 0)
        self.assertEqual(self.f.state.aperture.read(self.f.owner.base, 4), b'abcd')
        self.f.begin()
        values['dependencyFlags'] = 2
        self.f.command('vkCmdPipelineBarrier', **values)
        self.f.end()
        with self.assertRaises(ValueError):
            self.e.replay.enqueue(1, [self.f.CB])

    def test_default_native_backend_still_refuses_gpu_admission(self):
        self.e.submissions.enabled = False
        with self.assertRaisesRegex(StreamFault, 'work submission'):
            self.execute(self.packet())

    def test_suspended_fence_wait_rejects_recycled_object_id(self):
        task = self.wait()
        self.f.command('vkDestroyFence', device=self.wire.DEVICE, fence=self.FENCE)
        self.f.command('vkCreateFence', device=self.wire.DEVICE,
                       pCreateInfo=self.wire.structure('VkFenceCreateInfo',
                                                       pNext=[], flags=1),
                       pFence=self.FENCE)
        with self.assertRaises(KeyError):
            task.advance([256, 65536])
        task.cancel()

    BUF, MEM2 = 0x4000A000100A, 0x4000B000100B

    def create_buffer(self, handle):
        self.f.command('vkCreateBuffer', device=self.wire.DEVICE,
            pBuffer=handle,
            pCreateInfo=self.wire.structure('VkBufferCreateInfo', pNext=[],
                flags=0, size=4096, usage=3, sharingMode=0,
                queueFamilyIndexCount=0, pQueueFamilyIndices=[]))

    def allocate(self, handle):
        self.f.command('vkAllocateMemory', device=self.wire.DEVICE,
            pAllocateInfo=self.wire.structure('VkMemoryAllocateInfo', pNext=[],
                allocationSize=4096, memoryTypeIndex=0), pMemory=handle)

    def lost_result(self, issue):
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        issue()
        head = self.f.blobs.read(self.f.blobs.mapping(7), 0, 16)
        return struct.unpack('<IIQ', head)[1]

    def fault(self):
        context = self.e.contexts[1]
        self.e.submissions.faults.add(id(context))
        self.addCleanup(self.e.submissions.faults.discard, id(context))

    def test_device_lost_reports_for_alloc_bind_and_memory(self):
        self.create_buffer(self.BUF)
        self.fault()
        lost = 0xFFFFFFFC  # VK_ERROR_DEVICE_LOST
        self.assertEqual(self.lost_result(
            lambda: self.create_buffer(0x4000C000100C)), lost)
        status, _, _ = self.f.front.resolve(0x4000C000100C, 0)
        self.assertNotEqual(status, 'OK')
        self.assertEqual(self.lost_result(lambda: self.allocate(self.MEM2)), lost)
        self.assertEqual(self.lost_result(lambda: self.f.command(
            'vkBindBufferMemory', device=self.wire.DEVICE, buffer=self.BUF,
            memory=self.wire.MEMORY, memoryOffset=0)), lost)
        self.assertEqual(self.lost_result(lambda: self.f.command(
            'vkCreateFence', device=self.wire.DEVICE,
            pCreateInfo=self.wire.structure('VkFenceCreateInfo', pNext=[], flags=0),
            pFence=0x4000D000100D)), lost)

    def test_device_lost_recovers_after_fault_clears(self):
        self.fault()
        self.assertEqual(self.lost_result(
            lambda: self.create_buffer(self.BUF)), 0xFFFFFFFC)
        self.e.submissions.faults.clear()
        self.assertEqual(self.lost_result(lambda: self.create_buffer(self.BUF)), 0)
        status, _, _ = self.f.front.resolve(self.BUF, 0)
        self.assertEqual(status, 'OK')

    def test_device_lost_keeps_retire_and_record_commands_live(self):
        self.create_buffer(self.BUF)
        self.fault()
        # RETRE class destroys stay live so post-loss cleanup still runs
        self.f.command('vkDestroyBuffer', device=self.wire.DEVICE,
                       buffer=self.BUF)
        status, _, _ = self.f.front.resolve(self.BUF, 0)
        self.assertNotEqual(status, 'OK')


class TransferBridgeTests(unittest.TestCase):
    def test_opt_in_cli_retires_wire_submission_and_writes_shared_backing(self):
        f = bridge_fixture.NativeBridgeTests()
        f.transfer_submit = True
        f.cleanup_owner = self
        f.setUp()
        wire = bridge_fixture.NativeWire()
        self.assertEqual(f.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'xfer')),
                         RESP_NODATA)
        self.assertEqual(f.submit(CREATE_BLOB, struct.pack('<IIIIQQ', 7, 2, 1, 0, 0, 4096)),
                         RESP_NODATA)
        self.assertEqual(f.submit(MAP_BLOB, struct.pack('<IIQ', 7, 0, 0)), RESP_MAP_INFO)
        boot = wire.boot(memory_type=0)
        self.assertEqual(f.submit(SUBMIT_3D, struct.pack('<II', len(boot), 0) + boot),
                         RESP_NODATA)
        self.assertEqual(f.submit(CREATE_BLOB, struct.pack(
            '<IIIIQQ', 20, 2, 1, 0, wire.MEMORY, 8192)), RESP_NODATA)
        self.assertEqual(f.submit(MAP_BLOB, struct.pack('<IIQ', 20, 0, 8192)), RESP_MAP_INFO)
        buffer, pool, cb = replay_fixture.ReplayTests.BUFFER, replay_fixture.ReplayTests.POOL, replay_fixture.ReplayTests.CB
        queue, fence = SubmissionTests.QUEUE, SubmissionTests.FENCE
        setup = wire.transfer_commands(buffer, pool, cb, queue, fence)
        self.assertEqual(f.submit(SUBMIT_3D, struct.pack('<II', len(setup), 0) + setup),
                         RESP_NODATA)
        submit = wire.command('vkQueueSubmit', queue=queue, submitCount=1,
            pSubmits=[wire.structure('VkSubmitInfo', pNext=[], waitSemaphoreCount=0,
                pWaitSemaphores=[], pWaitDstStageMask=[], commandBufferCount=1,
                pCommandBuffers=[cb], signalSemaphoreCount=0, pSignalSemaphores=[])],
            fence=fence)
        submit = submit[:4] + struct.pack('<I', 0) + submit[8:]
        wait = wire.command('vkWaitForFences', device=wire.DEVICE, fenceCount=1,
                            pFences=[fence], waitAll=1, timeout=(1 << 64) - 1)
        payload = wire.command('vkSeekReplyCommandStreamMESA', position=0) + submit + wait
        response = f.enqueue(SUBMIT_3D, struct.pack('<II', len(payload), 0) + payload)
        f.wait_used(f.index)
        self.assertEqual(bridge_fixture.HEADER.unpack(f.mem.r(response, 24))[0], RESP_NODATA)
        self.assertEqual(struct.unpack('<II', f.mem.r(f.config['shm_base'], 8))[1], 0)
        self.assertEqual(f.mem.r(f.config['shm_base'] + 8192, 4096), b'abcd' * 1024)


if __name__ == '__main__':
    unittest.main()
