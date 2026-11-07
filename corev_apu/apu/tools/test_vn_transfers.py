# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Short native transfer-budget, retirement and borrowed-memory regressions."""
import unittest
from unittest.mock import patch

from native_test_wire import NativeWire
from vn_memory import ApertureState
from vn_memory_blobs import MemoryBlobs
from vn_native_execution import ExecutionService
from vn_transfer_executor import Transfer, TransferExecutor


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.state = ApertureState(65536, 32768)
        self.blobs = MemoryBlobs(self.state)
        self.blobs.create(7, 4096)
        self.blobs.map(7, 0)
        self.service = ExecutionService(self.state, self.blobs)
        self.wire = NativeWire()
        self.service.execute(1, self.wire.boot(memory_type=0))
        self.engine = self.service.engine
        self.context = self.engine.contexts[1]
        self.owner = self.engine.memory(1, self.wire.MEMORY)
        self.executor = self.engine.transfers
        self.executor.chunk_bytes = 256

    def fill(self, owner=None, size=1024, value=b'abcd'):
        return Transfer('fill', owner or self.owner, 0, size, data=value)

    def drain(self):
        for _ in range(128):
            if not self.executor.active:
                return
            self.service.poll()
        self.fail('bounded test drain did not finish')

    def test_chunked_fill_uses_service_poll_and_real_memory(self):
        job = self.executor.enqueue(self.context, [self.fill()])
        self.assertTrue(self.service.active)
        self.service.poll()
        self.assertEqual(job.position, 256)
        self.assertEqual(self.state.aperture.read(self.owner.base, 260), b'abcd' * 64 + b'\0' * 4)
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.state.aperture.read(self.owner.base, 1024), b'abcd' * 256)
        self.assertEqual((self.owner.work_refs, self.executor.reserved_bytes), (0, 0))

    def test_fifo_update_and_copy_preserve_chunk_positions(self):
        first = self.executor.enqueue(self.context, [self.fill()])
        update = self.executor.enqueue(self.context, [
            Transfer('update', self.owner, 0, 4, data=b'last')])
        self.service.poll()
        self.assertEqual(update.state, 'queued')
        self.drain()
        self.assertEqual((first.state, update.state), ('done', 'done'))
        copy = self.executor.enqueue(self.context, [
            Transfer('copy', self.owner, 2048, 1024, source=self.owner)])
        self.drain()
        self.assertEqual(copy.state, 'done')
        self.assertEqual(self.state.aperture.read(self.owner.base + 2048, 1024),
                         b'last' + b'abcd' * 255)

    def test_preflight_rejects_whole_job_before_pins_or_writes(self):
        for op in (Transfer('fill', self.owner, 5000, 4, data=b'fail'),
                   Transfer('copy', self.owner, 4, 8, source=self.owner),
                   Transfer('update', self.owner, 0, 4, data=bytearray(b'fail')),
                   self.fill(size=3), self.fill(value=b'bad')):
            with self.assertRaises(ValueError):
                self.executor.enqueue(self.context, [self.fill(size=4), op])
            self.assertEqual(self.owner.work_refs, 0)
            self.assertEqual(self.executor.pending, 0)
        self.assertEqual(self.state.aperture.read(self.owner.base, 4), b'\0' * 4)

    def test_generation_and_context_capabilities_cannot_cross(self):
        self.service.execute(2, self.wire.boot(memory_type=0))
        second = self.engine.memory(2, self.wire.MEMORY)
        with self.assertRaises(KeyError):
            self.executor.enqueue(self.context, [self.fill(second)])
        self.service.execute(1, self.wire.free())
        with self.assertRaises(KeyError):
            self.executor.enqueue(self.context, [self.fill()])

    def test_job_operation_and_aggregate_byte_limits_are_fail_closed(self):
        self.executor.max_jobs = 1
        self.executor.max_operations = 1
        self.executor.max_bytes = 1024
        first = self.executor.enqueue(self.context, [self.fill()])
        with self.assertRaises(MemoryError):
            self.executor.enqueue(self.context, [self.fill(size=4)])
        self.executor.max_jobs = 128
        with self.assertRaises(MemoryError):
            self.executor.enqueue(self.context, [self.fill(size=4)])
        with self.assertRaises(MemoryError):
            self.executor.enqueue(self.context, [self.fill(size=0), self.fill(size=0)])
        self.drain()
        self.assertEqual(first.state, 'done')

    def test_work_pins_prevent_relocation_and_free_waits_for_retirement(self):
        job = self.executor.enqueue(self.context, [self.fill()])
        self.blobs.create_alias(20, 8192, self.owner)
        self.assertEqual((self.owner.refs, self.owner.work_refs), (1, 1))
        with self.assertRaises(BlockingIOError):
            self.blobs.map(20, 8192)
        self.service.execute(1, self.wire.free())
        self.blobs.unref(20)
        self.assertIsNotNone(self.owner.deferred_free)
        self.assertEqual((self.owner.refs, self.owner.work_refs), (0, 1))
        self.drain()
        self.assertEqual(job.state, 'done')
        self.assertNotIn(self.wire.MEMORY, self.context.frontend.idmap)

    def test_context_retirement_cancels_without_reusing_memory(self):
        job = self.executor.enqueue(self.context, [self.fill()])
        self.service.poll()
        base = self.owner.base
        self.service.retire_context(1)
        self.assertEqual((job.state, self.owner.work_refs), ('cancelled', 0))
        self.service.execute(1, self.wire.boot(memory_type=0))
        self.assertIsNot(self.context, self.engine.contexts[1])
        before = self.state.aperture.read(base, 1024)
        self.service.poll()
        self.assertEqual(self.state.aperture.read(base, 1024), before)
        with self.assertRaises(KeyError):
            self.executor.enqueue(self.context, [self.fill()])

    def test_context_round_robin_cannot_reorder_its_own_queue(self):
        self.service.execute(2, self.wire.boot(memory_type=0))
        second = self.engine.memory(2, self.wire.MEMORY)
        self.executor.poll_operations = 1
        first = self.executor.enqueue(self.context, [self.fill()])
        sibling = self.executor.enqueue(self.engine.contexts[2], [self.fill(second)])
        later = self.executor.enqueue(self.context, [self.fill(size=4)])
        self.service.poll()
        self.assertEqual((first.position, sibling.position), (256, 0))
        self.service.poll()
        self.assertEqual((first.position, sibling.position), (256, 256))
        self.assertEqual(later.state, 'queued')
        self.drain()

    def test_io_fault_retires_leases_without_replaying_prefix(self):
        job = self.executor.enqueue(self.context, [self.fill()])
        self.service.poll()
        write = self.state.aperture.write
        self.state.aperture.write = lambda *_: (_ for _ in ()).throw(OSError('DMA revoked'))
        self.service.poll()
        self.state.aperture.write = write
        self.assertEqual((job.state, job.position, self.owner.work_refs), ('faulted', 256, 0))
        self.assertIn('DMA revoked', job.error)
        self.assertEqual(self.executor.reserved_bytes, 0)
        self.assertEqual(self.state.aperture.read(self.owner.base + 256, 4), b'\0' * 4)

    def test_reset_during_copy_read_cannot_publish_stale_write(self):
        self.service.execute(2, self.wire.boot(memory_type=0))
        second = self.engine.memory(2, self.wire.MEMORY)
        self.state.aperture.write(self.owner.base, b'data')
        job = self.executor.enqueue(self.context, [
            Transfer('copy', self.owner, 2048, 4, source=self.owner)])
        sibling = self.executor.enqueue(self.engine.contexts[2], [self.fill(second)])
        read = self.state.aperture.read
        base = self.owner.base

        def cancel(address, count):
            result = read(address, count)
            self.service.reset()
            return result

        self.state.aperture.read = cancel
        self.service.poll()
        self.state.aperture.read = read
        self.assertEqual(job.state, 'cancelled')
        self.assertEqual(sibling.state, 'cancelled')
        self.assertEqual(read(base + 2048, 4), b'\0' * 4)
        self.assertEqual((self.executor.pending, self.executor.reserved_bytes), (0, 0))

    def test_invalid_budgets_and_unbacked_memory_reject(self):
        for kwargs in ({'max_jobs': 0}, {'max_bytes': True}, {'chunk_bytes': 3}):
            with self.assertRaises(ValueError):
                TransferExecutor(self.engine, **kwargs)
        self.service.retire_context(1)
        self.service.execute(1, self.wire.boot(memory_type=1))
        owner = self.engine.memory(1, self.wire.MEMORY)
        with self.assertRaises(ValueError):
            self.executor.enqueue(self.engine.contexts[1], [self.fill(owner)])

    def test_byte_copy_cannot_split_another_contexts_fill_word(self):
        self.service.execute(2, self.wire.boot(memory_type=0))
        second = self.engine.memory(2, self.wire.MEMORY)
        self.executor.chunk_bytes = self.executor.poll_bytes = 4
        self.executor.enqueue(self.context, [
            Transfer('copy', self.owner, 2048, 1, source=self.owner)])
        fill = self.executor.enqueue(self.engine.contexts[2], [
            self.fill(second, size=4, value=b'word')])
        self.service.poll()
        self.assertEqual(fill.position, 0)
        self.service.poll()
        self.assertEqual(fill.state, 'done')
        self.assertEqual(self.state.aperture.read(second.base, 4), b'word')

    def test_late_pin_failure_rolls_back_all_earlier_leases(self):
        memory_id = self.wire.MEMORY + 1
        self.service.execute(1, self.wire.command(
            'vkAllocateMemory', device=self.wire.DEVICE,
            pAllocateInfo=self.wire.structure('VkMemoryAllocateInfo', pNext=[],
                                             allocationSize=4096, memoryTypeIndex=0),
            pMemory=memory_id))
        second = self.engine.memory(1, memory_id)
        with patch.object(second, 'pin_work', side_effect=MemoryError('pin exhausted')):
            with self.assertRaises(MemoryError):
                self.executor.enqueue(self.context, [
                    self.fill(size=4), self.fill(second, size=4)])
        self.assertEqual((self.owner.work_refs, second.work_refs), (0, 0))
        self.assertEqual((self.executor.pending, self.executor.reserved_bytes), (0, 0))

    def test_deferred_free_rejects_new_work_and_blob_references(self):
        self.executor.enqueue(self.context, [self.fill()])
        self.service.execute(1, self.wire.free())
        with self.assertRaises(KeyError):
            self.owner.pin_work()
        with self.assertRaises(KeyError):
            self.blobs.create_alias(20, 8192, self.owner)
        self.assertNotIn(20, self.blobs.blobs)
        self.assertEqual((self.owner.refs, self.owner.work_refs), (0, 1))
        self.drain()


if __name__ == '__main__':
    unittest.main()
