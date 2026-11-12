# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded timestamp query-pool ops: ordered slot state and readback."""
import struct
import unittest

import test_vn_images as image_fixture


class QueryTests(unittest.TestCase):
    POOL = 0x800000008000

    def setUp(self):
        self.images = image_fixture.ImageTests()
        self.images.native_profile = True
        self.images.setUp()
        self.f = self.images.f
        self.w, self.e = self.f.wire, self.f.engine

    def create(self, qtype=2, count=4, stats=0, flags=0, handle=None):
        self.f.command('vkCreateQueryPool', device=self.w.DEVICE,
            pQueryPool=handle or self.POOL,
            pCreateInfo=self.w.structure('VkQueryPoolCreateInfo', pNext=[],
                flags=flags, queryType=qtype, queryCount=count,
                pipelineStatistics=stats, checksum=0))

    def reset(self, first=0, count=4):
        self.f.command('vkCmdResetQueryPool', commandBuffer=self.f.CB,
            queryPool=self.POOL, firstQuery=first, queryCount=count)

    def begin(self, query=0, flags=0):
        self.f.command('vkCmdBeginQuery', commandBuffer=self.f.CB,
            queryPool=self.POOL, query=query, flags=flags)

    def end(self, query=0):
        self.f.command('vkCmdEndQuery', commandBuffer=self.f.CB,
            queryPool=self.POOL, query=query)

    def stamp(self, query=0, stage=0x1000):
        self.f.command('vkCmdWriteTimestamp', commandBuffer=self.f.CB,
            pipelineStage=stage, queryPool=self.POOL, query=query)

    def slots(self):
        return self.f.entry(self.POOL)['qslots']

    def results(self, first=0, count=4, flags=0x1, stride=0, data_size=None):
        # single-counter record: u64 result + u64 availability when
        # 64_BIT is set, else u32 each (spec widens both together)
        cw = 8 if flags & 0x1 else 4
        record = cw + (cw if flags & 0x8 else 0)
        packed = stride or record
        if data_size is None:
            data_size = count * packed
        return self.f.command('vkGetQueryPoolResults', device=self.w.DEVICE,
            queryPool=self.POOL, firstQuery=first, queryCount=count,
            dataSize=data_size, pData=b'\0' * data_size,
            stride=stride, flags=flags)

    def read_reply(self):
        mapping = self.f.blobs.map(7, 0)
        head = self.f.blobs.read(mapping, 0, 16)
        rtype, result, count = struct.unpack('<IIQ', head)
        payload = self.f.blobs.read(mapping, 16, count)
        return rtype, result, count, payload

    def test_timestamp_ops_execute_in_stream_order(self):
        self.create()
        self.assertEqual(self.slots(), [None] * 4)
        self.f.begin()
        self.begin(0)
        self.stamp(1)
        self.end(2)
        self.reset(0, 2)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual([op.__class__.__name__ for op in job.operations],
                         ['QueryStamp', 'QueryStamp', 'QueryStamp',
                          'QueryReset'])
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.slots(), [None, None, 0, None])
        self.assertEqual(job.query_stats[0], {'stamped': 0})
        self.assertEqual(job.query_stats[3], {'reset': 2})

    def test_occlusion_stats_flags_and_count_refuse_at_create(self):
        for i, kwargs in enumerate((dict(qtype=1, stats=0x8),
                                    dict(qtype=3),
                                    dict(stats=1), dict(flags=1),
                                    dict(count=4097))):
            handle = self.POOL + i * 0x10000
            self.create(handle=handle, **kwargs)
            self.assertNotIn(handle, self.f.front.idmap, msg=str(kwargs))

    def test_occlusion_pool_create_and_empty_count(self):
        self.create(qtype=0)
        self.assertEqual(self.slots(), [None] * 4)
        self.f.begin()
        self.begin(0)
        self.end(0)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual([op.__class__.__name__ for op in job.operations],
                         ['QueryBegin', 'QueryEnd'])
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.slots(), [0, None, None, None])
        self.assertEqual(job.query_stats[1], {'ended': 0, 'samples': 0})
        # readback reports the published zero count as available
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.results(count=1, flags=0x9)
        _rtype, result, count, payload = self.read_reply()
        self.assertEqual((result, count), (0, 16))
        value, avail = struct.unpack('<QQ', payload)
        self.assertEqual((value, avail), (0, 1))

    def test_occlusion_pairing_and_flag_refusals(self):
        self.create(qtype=0)
        cases = (
            lambda: self.end(0),                     # end without begin
            lambda: (self.begin(0), self.begin(0)),  # double begin
            lambda: self.begin(0, 2),                # flags beyond PRECISE
            lambda: self.begin(4),                   # index out of range
            lambda: self.begin(0),                   # left open at submit end
        )
        for record in cases:
            self.f.begin()
            record()
            self.f.end()
            with self.assertRaises(ValueError):
                self.f.enqueue()
            self.assertFalse(self.e.transfers.active)

    def test_indexed_query_variants_admit_index_zero(self):
        self.create(qtype=0)
        self.f.begin()
        self.f.command('vkCmdBeginQueryIndexedEXT', commandBuffer=self.f.CB,
            queryPool=self.POOL, query=1, flags=1, index=0)
        self.f.command('vkCmdEndQueryIndexedEXT', commandBuffer=self.f.CB,
            queryPool=self.POOL, query=1, index=0)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual([op.__class__.__name__ for op in job.operations],
                         ['QueryBegin', 'QueryEnd'])
        self.f.drain()
        self.assertEqual(self.slots()[1], 0)
        # nonzero index is outside the bounded transform-feedback-free
        # profile and refuses
        self.f.begin()
        self.f.command('vkCmdBeginQueryIndexedEXT', commandBuffer=self.f.CB,
            queryPool=self.POOL, query=2, flags=0, index=1)
        self.f.command('vkCmdEndQueryIndexedEXT', commandBuffer=self.f.CB,
            queryPool=self.POOL, query=2, index=1)
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)

    def test_occlusion_copy_and_wrong_type_refusals(self):
        self.create(qtype=0)
        # timestamp write on an occlusion pool refuses
        self.f.begin()
        self.f.command('vkCmdWriteTimestamp', commandBuffer=self.f.CB,
            pipelineStage=0x1000, queryPool=self.POOL, query=0)
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        # ordered begin/end/copy publishes then copies the count
        self.f.begin()
        self.begin(0)
        self.end(0)
        self.f.command('vkCmdCopyQueryPoolResults', commandBuffer=self.f.CB,
            queryPool=self.POOL, dstBuffer=self.f.BUFFER, dstOffset=0,
            queryCount=1, firstQuery=0, stride=16,
            flags=0x1 | 0x8)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        data = self.f.state.aperture.read(self.f.owner.base, 16)
        value, avail = struct.unpack('<QQ', data[:16])
        self.assertEqual((value, avail), (0, 1))

    def test_query_bounds_flags_and_stages_refuse(self):
        self.create()
        for record in (lambda: self.begin(4), lambda: self.end(4),
                       lambda: self.stamp(4), lambda: self.begin(0, 1),
                       lambda: self.stamp(0, 0x10),
                       lambda: self.reset(3, 2)):
            self.f.begin()
            record()
            self.f.end()
            with self.assertRaises(ValueError):
                self.f.enqueue()
            self.assertFalse(self.e.transfers.active)

    def test_dead_pool_and_destroy_release(self):
        self.create()
        self.f.command('vkDestroyQueryPool', device=self.w.DEVICE,
                       queryPool=self.POOL)
        self.assertNotIn(self.POOL, self.f.front.idmap)
        # a dead pool handle fails the record-time LOOKUP: the command
        # is dropped before it can reach the executor
        self.f.begin()
        self.begin(0)
        self.f.end()
        job = self.f.enqueue()
        self.assertFalse(any(type(op).__name__.startswith('Query')
                             for op in job.operations))
        self.f.drain()
        self.assertEqual(job.state, 'done')

    def test_pool_pins_release_after_retirement(self):
        self.create()
        self.f.begin()
        self.stamp(0)
        self.f.end()
        job = self.f.enqueue()
        self.assertGreater(self.f.entry(self.POOL)['pins'], 0)
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.f.entry(self.POOL)['pins'], 0)
        self.assertEqual(self.slots()[0], 0)

    def test_results_readback_after_ordered_stamps(self):
        self.create()
        self.f.begin()
        self.stamp(0)
        self.stamp(1)
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.results(count=2)
        rtype, result, count, payload = self.read_reply()
        self.assertEqual((rtype, result, count), (49, 0, 16))
        self.assertEqual(payload, b'\0' * 16)
        # availability variant: 16-byte records, u64 value then u64 flag
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.results(count=2, flags=0x9)
        _rtype, result, count, payload = self.read_reply()
        self.assertEqual((result, count), (0, 32))
        records = struct.unpack('<QQQQ', payload[:32])
        # per record: u64 value + u64 available; packed stride 16
        self.assertEqual(records, (0, 1, 0, 1))

    def test_results_not_ready_before_stamps_drain(self):
        self.create()
        self.f.begin()
        self.stamp(0)
        self.f.end()
        self.f.enqueue()
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.results(count=1)
        _rtype, result, _count, _payload = self.read_reply()
        self.assertEqual(result, 1)  # VK_NOT_READY
        self.f.drain()
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.results(count=1)
        _rtype, result, count, payload = self.read_reply()
        self.assertEqual((result, count), (0, 8))

    def test_results_wait_blocks_until_stamp_retires(self):
        self.create()
        self.f.begin()
        self.stamp(0)
        self.f.end()
        self.f.enqueue()
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        task = self.results(count=1, flags=0x3)
        self.assertEqual(task.state, 'waiting')
        self.f.drain()
        task.advance([self.f.engine.max_commands,
                      self.f.engine.max_bytes])
        self.assertEqual(task.state, 'done')
        _rtype, result, count, _payload = self.read_reply()
        self.assertEqual((result, count), (0, 8))

    def test_results_validation_and_profile_refusals(self):
        self.create()
        # 32-bit results and unknown flag bits are outside the profile
        for flags in (0x0, 0x2, 0x4, 0x10):
            self.f.command('vkSeekReplyCommandStreamMESA', position=0)
            self.results(count=1, flags=flags)
            _rtype, result, _count, _payload = self.read_reply()
            self.assertEqual(result, 0xFFFFFFF8, msg=hex(flags))
        # out-of-range, undersized dataSize and bad stride validate-fail
        for kwargs in (dict(first=3, count=2),
                       dict(count=1, data_size=4),
                       dict(count=1, stride=3),
                       dict(count=1, stride=4)):
            self.f.command('vkSeekReplyCommandStreamMESA', position=0)
            self.results(**kwargs)
            _rtype, result, _count, _payload = self.read_reply()
            self.assertEqual(result, 0xC4650B08, msg=str(kwargs))

    def test_results_report_device_lost_after_context_fault(self):
        self.create()
        self.f.begin()
        self.stamp(0)
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        context = self.f.engine.contexts[1]
        self.f.engine.submissions.faults.add(id(context))
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.results(count=1)
        _rtype, result, _count, _payload = self.read_reply()
        self.assertEqual(result, 0xFFFFFFFC)  # VK_ERROR_DEVICE_LOST
        self.f.engine.submissions.faults.discard(id(context))
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.results(count=1)
        _rtype, result, count, _payload = self.read_reply()
        self.assertEqual((result, count), (0, 8))

    def stamp2(self, query=0, stage=0x1000):
        self.f.command('vkCmdWriteTimestamp2', commandBuffer=self.f.CB,
            stage=stage, queryPool=self.POOL, query=query)

    def copy_results(self, first=0, count=4, flags=0x9, dst=512, stride=0):
        cw = 8 if flags & 1 else 4
        record = cw + (cw if flags & 8 else 0)
        self.f.command('vkCmdCopyQueryPoolResults', commandBuffer=self.f.CB,
            queryPool=self.POOL, firstQuery=first, queryCount=count,
            dstBuffer=self.f.BUFFER, dstOffset=dst, stride=stride or record,
            flags=flags)

    def test_timestamp2_stamps_in_order_and_reads_back(self):
        self.create()
        self.f.begin()
        self.stamp2(0)
        self.stamp(1)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual([op.__class__.__name__ for op in job.operations],
                         ['QueryStamp', 'QueryStamp'])
        self.f.drain()
        self.assertEqual(self.slots()[:2], [0, 0])
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.results(count=2)
        _rtype, result, count, _payload = self.read_reply()
        self.assertEqual((result, count), (0, 16))

    def test_timestamp2_refuses_out_of_profile_stage(self):
        self.create()
        self.f.begin()
        self.stamp2(0, stage=1 << 40)
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)

    def test_copy_results_writes_ordered_records(self):
        self.create(count=4)
        self.f.begin()
        self.stamp(0)
        self.stamp(2)
        self.copy_results(first=0, count=4, flags=0x9, dst=512, stride=16)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual(job.operations[-1].__class__.__name__, 'QueryCopy')
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(job.query_stats[2], {'copied': 4, 'bytes': 64})
        expected = b''
        for stamped in (True, False, True, False):
            expected += ((0).to_bytes(8, 'little') +
                         (1 if stamped else 0).to_bytes(8, 'little'))
        self.assertEqual(
            self.f.state.aperture.read(self.f.owner.base + 512, 64), expected)
        self.assertEqual(self.f.entry(self.f.BUFFER)['pins'], 0)

    def test_copy_results_32bit_packed_records(self):
        self.create(count=2)
        self.f.begin()
        self.stamp(0)
        self.stamp(1)
        self.copy_results(first=0, count=2, flags=0x8, dst=1024)
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        # availability-only 32-bit records pack as u32 value + u32 flag
        self.assertEqual(
            self.f.state.aperture.read(self.f.owner.base + 1024, 16),
            b'\0' * 4 + (1).to_bytes(4, 'little') +
            b'\0' * 4 + (1).to_bytes(4, 'little'))

    def test_copy_results_validation_refusals(self):
        self.create()
        for kwargs in (dict(first=3, count=2),
                       dict(count=1, stride=4),
                       dict(count=1, dst=2),
                       dict(count=1, flags=0xB),
                       dict(count=1, flags=0x10),
                       dict(count=4, dst=4090)):
            self.f.begin()
            self.copy_results(**kwargs)
            self.f.end()
            with self.assertRaises(ValueError, msg=str(kwargs)):
                self.f.enqueue()
            self.assertFalse(self.e.transfers.active)

    def test_copy_results_dead_pool_rejects(self):
        self.create()
        self.f.command('vkDestroyQueryPool', device=self.w.DEVICE,
                       queryPool=self.POOL)
        self.f.begin()
        self.copy_results(count=1)
        self.f.end()
        job = self.f.enqueue()
        self.assertFalse(any(type(op).__name__ == 'QueryCopy'
                             for op in job.operations))
        self.f.drain()
        self.assertEqual(job.state, 'done')

    def stat_results(self, first=0, count=1, flags=0x1, stride=0,
                     data_size=None, counters=4):
        cw = 8 if flags & 0x1 else 4
        record = counters * cw + (cw if flags & 0x8 else 0)
        packed = stride or record
        if data_size is None:
            data_size = count * packed
        return self.f.command('vkGetQueryPoolResults', device=self.w.DEVICE,
            queryPool=self.POOL, firstQuery=first, queryCount=count,
            dataSize=data_size, pData=b'\0' * data_size,
            stride=stride, flags=flags)

    def test_statistics_pool_create_and_empty_region(self):
        self.create(qtype=1, count=2, stats=0x87)
        self.f.begin()
        self.begin(0)
        self.end(0)
        self.begin(1, flags=1)  # PRECISE admitted for statistics too
        self.end(1)
        self.f.end()
        job = self.f.enqueue()
        self.assertEqual([op.__class__.__name__ for op in job.operations],
                         ['QueryBegin', 'QueryEnd',
                          'QueryBegin', 'QueryEnd'])
        self.f.drain()
        self.assertEqual(job.state, 'done')
        self.assertEqual(self.slots(), [[0, 0, 0, 0], [0, 0, 0, 0]])
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.stat_results(count=2)
        _rtype, result, count, payload = self.read_reply()
        self.assertEqual((result, count), (0, 64))
        self.assertEqual(payload, b'\0' * 64)

    def test_statistics_create_refusals(self):
        # geometry/tessellation/clipping/compute bits and stats flags on
        # non-statistics pools all refuse before ObjTab allocation
        for i, (qtype, stats) in enumerate(((1, 0x8), (1, 0x400),
                                            (1, 0xFFFF), (2, 0x87),
                                            (0, 0x1), (3, 0))):
            handle = self.POOL + i * 0x10000
            self.create(qtype=qtype, stats=stats, handle=handle)
            self.assertNotIn(handle, self.f.front.idmap,
                             msg=(qtype, stats))

    def test_statistics_mask_subset_availability_and_not_ready(self):
        self.create(qtype=1, count=2, stats=0x80)  # FS invocations only
        self.f.begin()
        self.begin(0)
        self.end(0)
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        self.assertEqual(self.slots(), [[0], None])
        # query 1 was never begun: without WAIT the read reports
        # VK_NOT_READY while still writing its unavailable record
        self.f.command('vkSeekReplyCommandStreamMESA', position=0)
        self.stat_results(count=2, flags=0x9, counters=1)
        _rtype, result, count, payload = self.read_reply()
        self.assertEqual((result, count), (1, 32))  # VK_NOT_READY
        self.assertEqual(payload, (0).to_bytes(8, 'little') +
                         (1).to_bytes(8, 'little') +
                         (0).to_bytes(8, 'little') + (0).to_bytes(8, 'little'))

    def test_statistics_copy_writes_counter_arrays(self):
        self.create(qtype=1, count=2, stats=0x87)
        self.f.begin()
        self.begin(0)
        self.end(0)
        self.f.end()
        self.f.enqueue()
        self.f.drain()
        # 4 counters * u64 + u64 availability = 40 bytes per query
        self.f.begin()
        self.copy_results(count=1, flags=0x9, dst=512, stride=40)
        self.f.end()
        job = self.f.enqueue()
        self.f.drain()
        self.assertEqual(job.state, 'done')
        out = self.f.state.aperture.read(self.f.owner.base + 512, 40)
        self.assertEqual(out[:32], b'\0' * 32)
        self.assertEqual(out[32:40], (1).to_bytes(8, 'little'))

    def test_statistics_wrong_type_ops_refuse(self):
        self.create(qtype=1, count=1, stats=0x87)
        self.f.begin()
        self.stamp(0)  # timestamp write on a statistics pool
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)
        # and nonzero begin flags still refuse on a timestamp pool
        self.create(count=1, handle=self.POOL + 0x200)
        self.f.begin()
        self.f.command('vkCmdBeginQuery', commandBuffer=self.f.CB,
            queryPool=self.POOL + 0x200, query=0, flags=2)
        self.f.end()
        with self.assertRaises(ValueError):
            self.f.enqueue()
        self.assertFalse(self.e.transfers.active)


if __name__ == '__main__':
    unittest.main()
