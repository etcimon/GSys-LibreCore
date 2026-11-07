# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded dependency ordering and cooperative sibling stream regressions."""
import struct
import unittest
from unittest.mock import patch

import test_vn_continuations
from vn_stream_group import dependency_graph
from vn_stream_task import StreamTask


class DependencyTests(unittest.TestCase):
    setUp = test_vn_continuations.ContinuationTests.setUp
    create = test_vn_continuations.ContinuationTests.create
    put = test_vn_continuations.ContinuationTests.put
    extra = test_vn_continuations.ContinuationTests.extra
    signal = test_vn_continuations.ContinuationTests.signal

    def packet(self, streams, edges=(), positions=None):
        mapping = self.blobs.mapping(9)
        descriptions = []
        for index, data in enumerate(streams):
            self.blobs.write(mapping, index * 1024, data)
            descriptions.append({'_ty': None, 'resourceId': 9,
                                 'offset': index * 1024, 'size': len(data)})
        return self.wire.command(
            'vkExecuteCommandStreamsMESA', streamCount=len(streams), pStreams=descriptions,
            pReplyPositions=positions, dependencyCount=len(edges),
            pDependencies=[self.wire.structure(
                'VkCommandStreamDependencyMESA', srcCommandStream=source,
                dstCommandStream=destination) for source, destination in edges], flags=0)

    def test_graph_validation_deduplicates_and_rejects_cycles_indices_and_limits(self):
        successors, incoming = dependency_graph(3, [(2, 0), (2, 0), (0, 1)], max_edges=4)
        self.assertEqual(successors, [{1}, set(), {0}])
        self.assertEqual(incoming, [1, 1, 0])
        for count, edges in ((2, [(0, 1), (1, 0)]), (1, [(0, 0)]),
                             (1, [(1, 0)]), (1, [(0, 1)]), (0, [(0, 0)])):
            with self.subTest(count=count, edges=edges), self.assertRaises(ValueError):
                dependency_graph(count, edges, max_edges=4)
        with self.assertRaisesRegex(ValueError, 'edge budget'):
            dependency_graph(2, [(0, 1)] * 5, max_edges=4)

    def test_reverse_dependency_runs_source_before_lower_index_destination(self):
        ring = self.create()
        command = self.packet([self.extra(ring, 10), self.extra(ring, 20)], [(1, 0)])
        self.put(ring, command)
        self.scheduler.poll()
        self.assertFalse(ring.fatal)
        self.assertEqual(ring.head, len(command))
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 10)

    def test_fanin_waits_for_both_predecessors(self):
        ring = self.create()
        command = self.packet([self.extra(ring, 30), self.extra(ring, 10),
                               self.extra(ring, 20)], [(1, 0), (2, 0)])
        with patch.object(self.execution, '_command', wraps=self.execution._command) as calls:
            self.execution.execute(1, command)
        values = [call.args[2][6] for call in calls.call_args_list
                  if call.args[1] == 'vkWriteRingExtraMESA']
        self.assertEqual(values, [10, 20, 30])

    def test_cycle_rejection_precedes_child_reads_and_effects(self):
        ring = self.create()
        command = self.packet([self.extra(ring, 10), self.extra(ring, 20)],
                              [(0, 1), (1, 0)])
        with patch.object(self.blobs, 'read', wraps=self.blobs.read) as reads:
            with self.assertRaisesRegex(ValueError, 'cyclic'):
                self.execution.execute(1, command)
        self.assertFalse(reads.call_args_list)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 0)
        self.assertEqual(self.blobs.blobs[9].pins, 0)
        self.assertFalse(self.execution.tasks)

    def test_independent_sibling_can_signal_a_parked_stream(self):
        ring = self.create()
        first = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10) + self.extra(ring, 10)
        second = self.wire.command('vkSubmitVirtqueueSeqnoMESA', ring=0, seqno=10)
        task = self.execution.execute(1, self.packet([first, second]))
        self.assertIsInstance(task, StreamTask)
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(self.execution.contexts[1].vq_seqno, 10)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 0)
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 10)

    def test_blocked_predecessor_does_not_release_its_dependent(self):
        ring = self.create()
        first = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        command = self.packet([first, self.extra(ring, 99)], [(0, 1)])
        task = self.execution.execute(1, command)
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 0)
        self.signal()
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 99)

    def test_parked_sibling_restores_its_reply_view(self):
        self.execution.execute(1, self.wire.reply(7))
        first_id, second_id, third_id = (self.wire.INSTANCE + offset for offset in (0, 256, 512))
        first = (self.wire.command('vkCreateInstance', pInstance=first_id) +
                 self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10) +
                 self.wire.command('vkCreateInstance', pInstance=third_id))
        second = (self.wire.command('vkCreateInstance', pInstance=second_id) +
                  self.wire.command('vkSubmitVirtqueueSeqnoMESA', ring=0, seqno=10))
        task = self.execution.execute(1, self.packet([first, second], positions=[0, 128]))
        self.assertEqual(task.state, 'waiting')
        task.advance([256, 65536])
        self.assertEqual(task.state, 'done')
        for offset, expected in ((16, first_id), (144, second_id), (40, third_id)):
            self.assertEqual(struct.unpack('<Q', self.state.aperture.read(offset, 8))[0], expected)

    def test_duplicate_edges_execute_each_child_once(self):
        ring = self.create()
        command = self.packet([self.extra(ring, 10), self.extra(ring, 20)], [(1, 0), (1, 0)])
        with patch.object(self.execution, '_command', wraps=self.execution._command) as calls:
            self.execution.execute(1, command)
        self.assertEqual(sum(call.args[1] == 'vkWriteRingExtraMESA'
                             for call in calls.call_args_list), 2)
        self.assertEqual(self.scheduler.read32(ring, ring.extra_offset), 10)

    def test_group_cancellation_releases_the_shared_source_lease(self):
        wait = self.wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        task = self.execution.execute(1, self.packet([wait, wait]))
        self.assertEqual(task.state, 'waiting')
        self.assertEqual(self.blobs.blobs[9].pins, 1)
        self.execution.retire_context(1)
        self.assertEqual(task.state, 'cancelled')
        self.assertEqual(self.blobs.blobs[9].pins, 0)
        self.assertFalse(self.execution.tasks)
