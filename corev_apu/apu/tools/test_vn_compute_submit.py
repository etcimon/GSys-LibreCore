# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Explicit diagnostic wire compute submission, fences and sticky fault feedback."""
import struct
import subprocess
import sys
import unittest
from unittest.mock import patch

import test_vn_compute_replay as compute_fixture
import test_vn_native_bridge as bridge_fixture
from native_test_wire import NativeWire
from test_vn_specialization import spec_program
from vn_blob_control import CREATE_BLOB, MAP_BLOB, RESP_MAP_INFO, SUBMIT_3D
from vn_control import CTX_CREATE, RESP_NODATA
from vn_native_execution import ExecutionService, LinearExecution
from vn_native_submit import NativeSubmissions


QUEUE, FENCE, SEM = 0x400130001013, 0x400140001014, 0x400150001015


def scene():
    def service(state, blobs, **kwargs):
        return ExecutionService(state, blobs, transfer_submit=True, compute_submit=True)

    with patch('test_vn_replay.ExecutionService', side_effect=service):
        result = compute_fixture.ComputeReplayTests()
        result.setUp()
    f, w = result.f, result.w
    f.command('vkGetDeviceQueue', device=w.DEVICE, queueFamilyIndex=0, queueIndex=0,
              pQueue=QUEUE)
    f.command('vkCreateFence', device=w.DEVICE, pFence=FENCE,
              pCreateInfo=w.structure('VkFenceCreateInfo', pNext=[], flags=0))
    return result


def submit_packet(w, buffers, *, fence=FENCE, waits=(), signals=(), timeline=False):
    chain = [w.structure('VkTimelineSemaphoreSubmitInfo', pNext=[],
              waitSemaphoreValueCount=len(waits), pWaitSemaphoreValues=[1] * len(waits),
              signalSemaphoreValueCount=len(signals), pSignalSemaphoreValues=[2] * len(signals))] \
            if timeline else []
    data = w.command('vkQueueSubmit', queue=QUEUE, submitCount=1,
        pSubmits=[w.structure('VkSubmitInfo', pNext=chain, waitSemaphoreCount=len(waits),
            pWaitSemaphores=list(waits), pWaitDstStageMask=[0x800] * len(waits),
            commandBufferCount=len(buffers), pCommandBuffers=list(buffers),
            signalSemaphoreCount=len(signals), pSignalSemaphores=list(signals))], fence=fence)
    return data[:4] + struct.pack('<I', 0) + data[8:]


class ComputeSubmissionTests(unittest.TestCase):
    def setUp(self):
        self.r = scene()
        self.f, self.e, self.w = self.r.f, self.r.e, NativeWire(True)
        self.r.record()

    def command(self, name, **kwargs):
        return self.f.service.execute(1, self.w.command(name, **kwargs))

    def result(self, name, **kwargs):
        self.command('vkSeekReplyCommandStreamMESA', position=0)
        self.command(name, **kwargs)
        return struct.unpack('<II', self.f.blobs.read(self.f.blobs.mapping(7), 0, 8))[1]

    def status(self, fence=FENCE):
        return self.result('vkGetFenceStatus', device=self.w.DEVICE, fence=fence)

    def wait(self, timeout=0):
        return self.result('vkWaitForFences', device=self.w.DEVICE, fenceCount=1,
                           pFences=[FENCE], waitAll=1, timeout=timeout)

    def submit(self, **kwargs):
        data = submit_packet(self.w, [self.f.CB], **kwargs)
        return self.f.service.execute(1, data)

    def test_explicit_modes_reach_queue_and_fence_follows_compute_retirement(self):
        self.assertTrue(self.e.submissions.compute_enabled)
        self.submit()
        self.assertEqual(self.status(), 1)
        self.assertEqual(self.wait(), 2)
        self.assertEqual(self.r.word(), 0)
        self.f.drain()
        self.assertEqual(self.status(), 0)
        self.assertEqual(self.r.word(), 5)
        self.assertFalse(self.e.submissions.pending)
        self.assertFalse(self.e.replay.held)

    def test_transfer_only_mode_still_refuses_shader_replay(self):
        self.e.submissions.compute_enabled = False
        with self.assertRaisesRegex(ValueError, 'unsupported replay'):
            self.e.submissions._submit(self.f.context, struct.unpack(
                '<%dI' % (len(submit_packet(self.w, [self.f.CB])) // 4),
                submit_packet(self.w, [self.f.CB])))
        self.r.no_work()
        self.assertEqual(self.f.entry(FENCE)['pins'], 0)

    def test_wire_submit_executes_specialized_pipeline(self):
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.r.l.PIPE)
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.r.l.MODULE)
        self.r.p.module(spec_program())
        spec = self.w.structure('VkSpecializationInfo', mapEntryCount=1,
            pMapEntries=[self.w.structure('VkSpecializationMapEntry', constantID=7,
                                         offset=0, size=4)],
            dataSize=4, pData=(41).to_bytes(4, 'little'))
        self.r.p.pipeline(spec=spec)
        self.r.record()
        self.submit()
        self.f.drain()
        self.assertEqual(self.status(), 0)
        self.assertEqual(self.r.word(), 41)

    def test_compute_fault_is_lost_after_leases_release_and_remains_sticky(self):
        self.submit()
        with patch.object(self.f.state.aperture, 'write', side_effect=OSError('DMA revoked')):
            self.f.service.poll()
        self.assertEqual(self.status(), self.e.golden.VK_ERR_LOST)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(self.e.replay.held)
        self.assertFalse(self.e.submissions.pending)
        self.command('vkResetFences', device=self.w.DEVICE, fenceCount=1, pFences=[FENCE])
        self.assertEqual(self.status(), self.e.golden.VK_ERR_LOST)
        self.assertEqual(self.wait(timeout=(1 << 64) - 1), self.e.golden.VK_ERR_LOST)
        self.submit()
        self.assertFalse(self.e.transfers.active)
        self.assertEqual(self.r.word(), 0)

    def test_reset_cancels_compute_without_signaling_reused_fence(self):
        self.submit()
        old = self.f.entry(FENCE)
        self.f.service.reset()
        self.assertEqual(old['pins'], 0)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(self.e.replay.held)
        self.assertFalse(self.e.submissions.pending)
        self.assertFalse(self.f.front.fence_sig)

    def test_fault_cancels_already_queued_work_before_later_writes(self):
        cb, fence = 0x400160001016, 0x400170001017
        self.f.allocate(cb)
        self.f.begin(cb)
        self.f.fill(handle=cb, offset=1024, size=4)
        self.f.end(cb)
        self.command('vkCreateFence', device=self.w.DEVICE, pFence=fence,
            pCreateInfo=self.w.structure('VkFenceCreateInfo', pNext=[], flags=0))
        self.submit()
        self.f.service.execute(1, submit_packet(self.w, [cb], fence=fence))
        with patch.object(self.f.state.aperture, 'write', side_effect=OSError('DMA revoked')):
            self.f.service.poll()
        self.f.drain()
        self.assertEqual(self.r.word(1024), 0)
        self.assertEqual(self.status(fence), self.e.golden.VK_ERR_LOST)
        self.assertFalse(self.e.transfers.active)
        self.assertFalse(self.e.replay.held)
        self.assertFalse(self.e.submissions.pending)

    def test_compute_binary_signal_and_wait_retire_in_order(self):
        self.command('vkCreateSemaphore', device=self.w.DEVICE, pSemaphore=SEM,
            pCreateInfo=self.w.structure('VkSemaphoreCreateInfo', pNext=[], flags=0))
        self.submit(signals=(SEM,))
        self.f.service.execute(1, submit_packet(self.w, [], fence=0, waits=(SEM,)))
        self.f.drain()
        self.assertEqual(self.status(), 0)
        self.assertEqual(self.r.word(), 5)
        self.assertFalse(self.e.submissions.semaphores.tokens)
        self.assertEqual(self.f.entry(SEM)['pins'], 0)

    def test_compute_timeline_wait_host_signal_and_queue_signal(self):
        self.command('vkCreateSemaphore', device=self.w.DEVICE, pSemaphore=SEM,
            pCreateInfo=self.w.structure('VkSemaphoreCreateInfo',
                pNext=[self.w.structure('VkSemaphoreTypeCreateInfo', pNext=[],
                                       semaphoreType=1, initialValue=0)], flags=0))
        self.submit(waits=(SEM,), signals=(SEM,), timeline=True)
        self.f.service.poll()
        self.assertEqual(self.r.word(), 0)
        self.assertEqual(self.status(), 1)
        self.command('vkSignalSemaphore', device=self.w.DEVICE,
            pSignalInfo=self.w.structure('VkSemaphoreSignalInfo', pNext=[],
                                        semaphore=SEM, value=1))
        self.f.drain()
        self.assertEqual(self.status(), 0)
        self.assertEqual(self.r.word(), 5)
        handle, _ = self.e.submissions._object(self.f.context, SEM, 'VkSemaphore')
        self.assertEqual(self.e.submissions.timelines.values[(id(self.f.context), handle)], 2)

    def test_queue_cannot_submit_command_buffers_from_another_device(self):
        device, queue = 0x400180001018, 0x400190001019
        self.command('vkCreateDevice', physicalDevice=self.w.PHYSICAL,
            pDevice=device, pCreateInfo=self.w.structure('VkDeviceCreateInfo', pNext=[],
                flags=0, queueCreateInfoCount=1, pQueueCreateInfos=[self.w.structure(
                    'VkDeviceQueueCreateInfo', pNext=[], flags=0, queueFamilyIndex=0,
                    queueCount=1, pQueuePriorities=[0x3F800000])],
                enabledLayerCount=0, ppEnabledLayerNames=[], enabledExtensionCount=0,
                ppEnabledExtensionNames=[], pEnabledFeatures=None))
        self.command('vkGetDeviceQueue', device=device, queueFamilyIndex=0, queueIndex=0,
                     pQueue=queue)
        packet = bytearray(submit_packet(self.w, [self.f.CB], fence=0))
        struct.pack_into('<Q', packet, 8, queue)
        with self.assertRaisesRegex(ValueError, 'command buffer'):
            self.e.submissions._submit(self.f.context, struct.unpack(
                '<%dI' % (len(packet) // 4), packet))
        self.r.no_work()

    def test_invalid_mode_combinations_fail_before_decoder_or_device_side_effects(self):
        for constructor, args in ((ExecutionService, (None, None)),
                                  (LinearExecution, (None, None))):
            for transfer, compute in ((False, True), (1, True), (True, 1)):
                with self.assertRaises(ValueError):
                    constructor(*args, transfer_submit=transfer, compute_submit=compute)
        with self.assertRaises(ValueError):
            NativeSubmissions(None, False, compute_submit=True)

    def test_cli_compute_requires_transfer_before_map_or_socket_access(self):
        result = subprocess.run([sys.executable, '-B', str(bridge_fixture.HERE / 'vn_native_bridge.py'),
                                 '--sock', 'unused', '--map', 'missing', '--compute-submit'],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--compute-submit requires --transfer-submit', result.stderr)


class ComputeBridgeTests(unittest.TestCase):
    def test_real_client_cli_compute_submit_wait_and_shared_memory(self):
        tape, original = [], NativeWire.command

        def recording(wire, *args, **kwargs):
            data = original(wire, *args, **kwargs)
            tape.append(data)
            return data

        # Generate the actual tested wire scene, not a second handwritten ABI.
        with patch.object(NativeWire, 'command', recording):
            reference = scene()
            reference.record()
        f = bridge_fixture.NativeBridgeTests()
        f.cleanup_owner = self
        f.transfer_submit = f.compute_submit = True
        f.setUp()
        self.assertEqual(f.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'compute')),
                         RESP_NODATA)
        self.assertEqual(f.submit(CREATE_BLOB, struct.pack('<IIIIQQ', 7, 2, 1, 0, 0, 4096)),
                         RESP_NODATA)
        self.assertEqual(f.submit(MAP_BLOB, struct.pack('<IIQ', 7, 0, 0)), RESP_MAP_INFO)
        setup = b''.join(tape)
        self.assertEqual(f.submit(SUBMIT_3D, struct.pack('<II', len(setup), 0) + setup),
                         RESP_NODATA)
        self.assertEqual(f.submit(CREATE_BLOB, struct.pack(
            '<IIIIQQ', 20, 2, 1, 0, reference.w.MEMORY, 8192)), RESP_NODATA)
        self.assertEqual(f.submit(MAP_BLOB, struct.pack('<IIQ', 20, 0, 8192)), RESP_MAP_INFO)
        w = NativeWire(True)
        submit = submit_packet(w, [reference.f.CB])
        wait = w.command('vkWaitForFences', device=w.DEVICE, fenceCount=1,
                         pFences=[FENCE], waitAll=1, timeout=(1 << 64) - 1)
        payload = w.command('vkSeekReplyCommandStreamMESA', position=0) + submit + wait
        response = f.enqueue(SUBMIT_3D, struct.pack('<II', len(payload), 0) + payload)
        f.wait_used(f.index)
        self.assertEqual(bridge_fixture.HEADER.unpack(f.mem.r(response, 24))[0], RESP_NODATA)
        self.assertEqual(struct.unpack('<II', f.mem.r(f.config['shm_base'], 8))[1], 0)
        self.assertEqual(f.mem.r(f.config['shm_base'] + 8192 + 256, 4),
                         (5).to_bytes(4, 'little'))


if __name__ == '__main__':
    unittest.main()
