# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Live bounded indirect group reads after ordered writes, leases and faults."""
import struct
import unittest
from unittest.mock import patch

import test_vn_compute_submit as wire_fixture
from test_vn_compute import program


def numgroups_program():
    source, result, position = program(), list(program()[:5]), 5
    while position < len(source):
        count, opcode = source[position] >> 16, source[position] & 0xFFFF
        if opcode == 19:
            result.extend((4 << 16 | 71, 24, 11, 24))
        if opcode == 54:
            result.extend((4 << 16 | 23, 21, 3, 3, 4 << 16 | 32, 22, 1, 21,
                           4 << 16 | 59, 22, 24, 1))
        if opcode == 15:
            result.extend(((count + 1) << 16 | opcode, *source[position + 1:position + count], 24))
        elif opcode == 62:
            result.extend((4 << 16 | 61, 21, 26, 24, 5 << 16 | 81, 3, 27, 26, 0,
                           3 << 16 | 62, 12, 27))
        else:
            result.extend(source[position:position + count])
        position += count
    return tuple(result)


class IndirectTests(unittest.TestCase):
    ARG = 0x4001A000101A

    def setUp(self):
        self.r = wire_fixture.scene()
        self.f, self.e, self.w = self.r.f, self.r.e, self.r.w
        self.arguments()

    def arguments(self, *, usage=0x102, binding=1024, memory=None, size=12):
        if self.ARG in self.f.front.idmap:
            self.f.command('vkDestroyBuffer', device=self.w.DEVICE, buffer=self.ARG)
        self.f.command('vkCreateBuffer', device=self.w.DEVICE, pBuffer=self.ARG,
            pCreateInfo=self.w.structure('VkBufferCreateInfo', pNext=[], flags=0,
                size=size, usage=usage, sharingMode=0, queueFamilyIndexCount=0,
                pQueueFamilyIndices=[]))
        self.f.command('vkBindBufferMemory', device=self.w.DEVICE, buffer=self.ARG,
                       memory=memory or self.w.MEMORY, memoryOffset=binding)
        self.binding = binding

    def dispatch(self, offset=0):
        self.f.command('vkCmdDispatchIndirect', commandBuffer=self.f.CB,
                       buffer=self.ARG, offset=offset)

    def record(self, groups=None, *, offset=0):
        self.f.begin()
        if groups is not None:
            self.f.command('vkCmdUpdateBuffer', commandBuffer=self.f.CB, dstBuffer=self.ARG,
                dstOffset=0, dataSize=12, pData=struct.pack('<III', *groups))
            self.f.command('vkCmdPipelineBarrier', commandBuffer=self.f.CB,
                srcStageMask=0x1000, dstStageMask=2, dependencyFlags=0,
                memoryBarrierCount=1, pMemoryBarriers=[self.w.structure(
                    'VkMemoryBarrier', pNext=[], srcAccessMask=0x1000, dstAccessMask=1)],
                bufferMemoryBarrierCount=0, pBufferMemoryBarriers=[],
                imageMemoryBarrierCount=0, pImageMemoryBarriers=[])
        self.r.bind()
        self.dispatch(offset)
        self.f.end()

    def submit(self):
        self.f.service.execute(1, wire_fixture.submit_packet(self.w, [self.f.CB]))
        return next(iter(self.e.submissions.pending.values()))

    def test_argument_bytes_are_read_once_only_after_queued_update(self):
        self.record((1, 1, 1))
        original, reads = self.f.state.aperture.read, []
        address = self.f.owner.base + self.binding

        def read(at, count):
            if (at, count) == (address, 12):
                reads.append(original(at, count))
            return original(at, count)

        with patch.object(self.f.state.aperture, 'read', read):
            job = self.submit()
            self.assertEqual(reads, [])
            self.e.transfers.poll()
            self.assertEqual(reads, [])
            self.assertEqual(self.r.word(), 0)
            self.f.drain()
        self.assertEqual(reads, [struct.pack('<III', 1, 1, 1)])
        self.assertEqual((job.state, self.r.word()), ('done', 5))
        self.assertTrue(self.f.front.fence_sig)

    def test_prior_compute_writes_live_indirect_dimensions(self):
        self.arguments(binding=256)
        self.f.state.aperture.write(self.f.owner.base + 256, struct.pack('<III', 1, 1, 1))
        self.f.begin()
        self.r.bind()
        self.r.dispatch()
        self.dispatch()
        self.f.end()
        job = self.e.replay.enqueue(1, [self.f.CB], compute=True)
        runtime = job.runtimes[1]
        self.f.drain()
        self.assertEqual((runtime.groups, runtime.group_count, job.state), ((5, 1, 1), 5, 'done'))

    def test_num_workgroups_builtin_uses_live_argument_values(self):
        self.r.pipeline_code(numgroups_program())
        self.record((3, 2, 1))
        job = self.submit()
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('done', 3))

    def test_zero_group_is_no_work_but_retires_fence(self):
        self.record((0, 1, 1))
        job = self.submit()
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('done', 0))
        self.assertEqual(job.compute_stats[1]['steps'], 0)
        self.assertTrue(self.f.front.fence_sig)

    def test_excess_invocations_fault_before_shader_writes(self):
        self.record((64, 64, 1))
        job = self.submit()
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('faulted', 0))
        self.assertTrue(self.f.front.fence_lost)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(self.e.replay.held)

    def test_component_limit_is_checked_even_for_zero_work(self):
        self.record((0, 65, 1))
        job = self.submit()
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('faulted', 0))
        self.assertTrue(self.f.front.fence_lost)

    def test_argument_io_failure_marks_fence_lost_and_releases_leases(self):
        self.record()
        address, original = self.f.owner.base + self.binding, self.f.state.aperture.read

        def read(at, count):
            if (at, count) == (address, 12):
                raise OSError('indirect DMA revoked')
            return original(at, count)

        job = self.submit()
        with patch.object(self.f.state.aperture, 'read', read):
            self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('faulted', 0))
        self.assertTrue(self.f.front.fence_lost)
        self.assertEqual(self.f.owner.work_refs, 0)
        self.assertFalse(self.e.replay.held)

    def test_short_argument_read_fails_without_shader_writes(self):
        self.record()
        address, original = self.f.owner.base + self.binding, self.f.state.aperture.read

        def read(at, count):
            return b'\0' * 8 if (at, count) == (address, 12) else original(at, count)

        job = self.submit()
        with patch.object(self.f.state.aperture, 'read', read):
            self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('faulted', 0))
        self.assertTrue(self.f.front.fence_lost)

    def test_context_retirement_during_argument_read_cannot_write_or_double_retire(self):
        self.record()
        address, original = self.f.owner.base + self.binding, self.f.state.aperture.read
        owner = self.f.owner

        def read(at, count):
            data = original(at, count)
            if (at, count) == (address, 12):
                self.e.retire_context(1)
            return data

        job = self.submit()
        with patch.object(self.f.state.aperture, 'read', read):
            self.e.transfers.poll()
        self.assertEqual((job.state, owner.work_refs), ('cancelled', 0))
        self.assertFalse(self.e.transfers.active)
        self.assertFalse(self.e.replay.held)
        self.assertFalse(self.e.submissions.pending)

    def test_usage_alignment_and_logical_range_refuse_before_pins(self):
        for usage, offset in ((2, 0), (0x102, 2), (0x102, 4)):
            self.arguments(usage=usage)
            self.record(offset=offset)
            with self.assertRaises(ValueError):
                self.e.replay.enqueue(1, [self.f.CB], compute=True)
            self.r.no_work()

    def test_recorded_argument_buffer_generation_survives_no_raw_id_reuse(self):
        self.record()
        self.arguments()
        with self.assertRaises(KeyError):
            self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.r.no_work()

    def test_late_binding_mutation_rolls_back_admission(self):
        self.record()
        entry = self.f.entry(self.ARG)
        handle = entry['gen'] << 16 | self.f.front.idmap[self.ARG]
        original = self.f.front.pin

        def pin(value):
            result = original(value)
            if value == handle:
                entry['bind_off'] += 256
            return result

        with patch.object(self.f.front, 'pin', pin), self.assertRaises(KeyError):
            self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.assertEqual(entry['pins'], 0)
        self.r.no_work()

    def test_cancellation_holds_and_releases_distinct_argument_backing(self):
        memory = 0x4001B000101B
        self.f.command('vkAllocateMemory', device=self.w.DEVICE, pMemory=memory,
            pAllocateInfo=self.w.structure('VkMemoryAllocateInfo', pNext=[],
                                           allocationSize=4096, memoryTypeIndex=0))
        self.arguments(binding=0, memory=memory)
        owner = self.e.memory(1, memory)
        self.record()
        job = self.e.replay.enqueue(1, [self.f.CB], compute=True)
        self.assertEqual((owner.work_refs, self.f.owner.work_refs), (1, 1))
        self.assertEqual(len(job.pins), 2)
        self.e.transfers.cancel_context(self.f.context)
        self.assertEqual((owner.work_refs, self.f.owner.work_refs), (0, 0))
        self.assertEqual(self.f.entry(self.ARG)['pins'], 0)
        self.r.no_work()

    def test_argument_read_respects_poll_budget_and_does_not_repeat(self):
        self.record((1, 1, 1))
        self.e.transfers.poll_bytes = 4096
        job = self.e.replay.enqueue(1, [self.f.CB], compute=True)
        runtime = job.runtimes[1]
        self.e.transfers.poll()
        self.e.transfers.poll()
        self.assertEqual((job.turn_bytes, runtime.steps, runtime.groups), (12, 0, (1, 1, 1)))
        self.f.state.aperture.write(self.f.owner.base + self.binding, b'\xff' * 12)
        self.f.drain()
        self.assertEqual((job.state, self.r.word()), ('done', 5))

    def test_transfer_profile_still_refuses_indirect_dispatch(self):
        self.f.begin()
        self.dispatch()
        self.f.end()
        with self.assertRaisesRegex(ValueError, 'unsupported replay'):
            self.e.replay.enqueue(1, [self.f.CB])
        self.r.no_work()

    def test_indirect_command_access_pairs_with_draw_indirect_stage(self):
        # INDIRECT_COMMAND_READ is admitted under the graphics profile when
        # paired with DRAW_INDIRECT; a fragment-only stage still refuses.
        self.f.begin()
        self.f.command('vkCmdPipelineBarrier', commandBuffer=self.f.CB,
            srcStageMask=0x1000, dstStageMask=0x80, dependencyFlags=0,
            memoryBarrierCount=1, pMemoryBarriers=[self.w.structure(
                'VkMemoryBarrier', pNext=[], srcAccessMask=0x1000, dstAccessMask=1)],
            bufferMemoryBarrierCount=0, pBufferMemoryBarriers=[],
            imageMemoryBarrierCount=0, pImageMemoryBarriers=[])
        self.f.end()
        with self.assertRaises(ValueError):
            self.e.replay.enqueue(1, [self.f.CB])
        self.r.no_work()
        self.f.begin()
        self.f.command('vkCmdPipelineBarrier', commandBuffer=self.f.CB,
            srcStageMask=0x1000, dstStageMask=2, dependencyFlags=0,
            memoryBarrierCount=1, pMemoryBarriers=[self.w.structure(
                'VkMemoryBarrier', pNext=[], srcAccessMask=0x1000, dstAccessMask=1)],
            bufferMemoryBarrierCount=0, pBufferMemoryBarriers=[],
            imageMemoryBarrierCount=0, pImageMemoryBarriers=[])
        self.f.end()
        job = self.e.replay.enqueue(1, [self.f.CB])
        self.f.drain()
        self.assertEqual(job.state, 'done')


if __name__ == '__main__':
    unittest.main()
