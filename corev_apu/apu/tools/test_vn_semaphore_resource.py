# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Directed checks for vkImportSemaphoreResourceMESA /
vkWaitSemaphoreResourceMESA — the Venus-native external semaphore
resource binding.  Covers both transport models: the §6b pump
TransportModel.t_cmd and the LinearExecution ring scheduler."""
import struct
import unittest

from native_test_wire import NativeWire
from vn_memory import ApertureState
from vn_memory_blobs import MemoryBlobs
from vn_native_execution import LinearExecution, StreamFault
from vn_rings import RingBlocked
from vn_native_execution import load_decoder


class PumpTransportTests(unittest.TestCase):
    """TransportModel.t_cmd path (golden §6b pump model)."""

    @classmethod
    def setUpClass(cls):
        cls.golden, cls.model, cls.assembly = load_decoder(False)

    def setUp(self):
        sim = self.golden.Sim(self.model, self.assembly)
        rep = self.golden.ReplySim(self.model, self.assembly)
        self.tm = self.golden.TransportModel(self.model, self.assembly,
                                             sim, rep)
        self.wire = NativeWire()
        # a mapped blob resource the semaphore can bind to
        self.tm.blobs[7] = {'base_w': 0, 'size': 8192, 'mapped': True,
                            'ctx': 4, 'mem_backed': False, 'mem_id': 0}

    def _cmd(self, name, **kw):
        return self.wire.command(name, **kw)

    def _import(self, sem, rid):
        return self._cmd('vkImportSemaphoreResourceMESA',
                         device=self.wire.DEVICE,
                         pImportSemaphoreResourceInfo=self.wire.structure(
                             'VkImportSemaphoreResourceInfoMESA',
                             pNext=[], semaphore=sem, resourceId=rid))

    def _wait(self, sem):
        return self._cmd('vkWaitSemaphoreResourceMESA',
                         device=self.wire.DEVICE, semaphore=sem)

    def _run(self, *cmds):
        blob = b''.join(cmds)
        words = list(struct.unpack('<%dI' % (len(blob) // 4), blob))

        def get(off, n):
            return words[off:off + n]
        return self.tm.exec_stream(get, len(words) * 4, None, None, [], 4)

    def _ring(self, rid, head, tail):
        self.tm.rings[0] = {
            'slot': 0, 'handle': 0x100, 'rid': rid, 'ctx': 4, 'head': head,
            'head0': head, 'head_base_w': 0x300, 'tail_base_w': 0x301,
            'status_base_w': 0x302, 'buf_base_w': 0x400, 'buf_size': 256,
            'extra_base_w': 0, 'extra_size': 0, 'fatal': False,
            'idle_count': 0}
        self.tm.ap[0x301] = tail

    def test_import_then_wait_drained_resource_succeeds(self):
        _cons, fatal = self._run(self._import(0x111, 7), self._wait(0x111))
        self.assertFalse(fatal)
        self.assertEqual(self.tm.sem_res[0x111], 7)

    def test_wait_without_import_is_fatal(self):
        _cons, fatal = self._run(self._wait(0x111))
        self.assertTrue(fatal)

    def test_import_unknown_resource_is_fatal(self):
        _cons, fatal = self._run(self._import(0x111, 999))
        self.assertTrue(fatal)
        self.assertNotIn(0x111, self.tm.sem_res)

    def test_import_null_semaphore_is_fatal(self):
        _cons, fatal = self._run(self._import(0, 7))
        self.assertTrue(fatal)

    def test_wait_blocks_while_bound_resource_has_pending_work(self):
        self._ring(7, head=0, tail=8)
        _cons, fatal = self._run(self._import(0x111, 7), self._wait(0x111))
        self.assertTrue(fatal)

    def test_wait_succeeds_once_bound_resource_drains(self):
        self._ring(7, head=8, tail=8)
        _cons, fatal = self._run(self._import(0x111, 7), self._wait(0x111))
        self.assertFalse(fatal)

    def test_wait_on_fatal_ring_is_fatal(self):
        self._ring(7, head=0, tail=0)
        self.tm.rings[0]['fatal'] = True
        _cons, fatal = self._run(self._import(0x111, 7), self._wait(0x111))
        self.assertTrue(fatal)

    def test_ring_on_other_resource_does_not_block_wait(self):
        self._ring(8, head=0, tail=16)   # pending, but bound rid is 7
        _cons, fatal = self._run(self._import(0x111, 7), self._wait(0x111))
        self.assertFalse(fatal)


class LinearTransportTests(unittest.TestCase):
    """LinearExecution._transport path (native ring scheduler)."""

    def setUp(self):
        self.state = ApertureState(65536, 32768)
        self.blobs = MemoryBlobs(self.state)
        for resource, base in ((7, 0), (8, 4096), (9, 8192)):
            self.blobs.create(resource, 4096)
            self.blobs.map(resource, base)
        self.execution = LinearExecution(self.state, self.blobs)
        self.wire = NativeWire()

    def _import(self, sem, rid):
        return self.wire.command(
            'vkImportSemaphoreResourceMESA', device=self.wire.DEVICE,
            pImportSemaphoreResourceInfo=self.wire.structure(
                'VkImportSemaphoreResourceInfoMESA',
                pNext=[], semaphore=sem, resourceId=rid))

    def _wait(self, sem):
        return self.wire.command('vkWaitSemaphoreResourceMESA',
                                 device=self.wire.DEVICE, semaphore=sem)

    def test_import_then_wait_drained_resource_completes(self):
        self.execution.execute(1, self._import(0x111, 8))
        result = self.execution.execute(1, self._wait(0x111))
        self.assertIsInstance(result, int)   # task reached 'done'

    def test_wait_without_import_faults(self):
        with self.assertRaises(StreamFault):
            self.execution.execute(1, self._wait(0x111))

    def test_import_unmapped_resource_faults(self):
        self.blobs.create(77, 4096)          # exists but not mapped
        with self.assertRaises(StreamFault):
            self.execution.execute(1, self._import(0x111, 77))
        with self.assertRaises(StreamFault):
            self.execution.execute(1, self._import(0x111, 4242))

    def test_wait_parks_while_bound_resource_has_pending_work(self):
        # a live ring on resource 8 with unconsumed submissions
        self.execution.execute(
            1, self.wire.create_ring(0x100, 8))
        ring = self.execution.rings.rings[(1, 0x100)]
        # publish a nonzero tail so [head, tail) is pending
        self.execution.rings.write32(ring, ring.tail_offset, 4)
        self.execution.execute(1, self._import(0x111, 8))
        result = self.execution.execute(1, self._wait(0x111))
        self.assertNotIsInstance(result, int)  # parked 'waiting', not done
        # drain the ring, then the wait completes
        self.execution.rings.retire(ring)
        self.execution.execute(1, self._wait(0x111))


if __name__ == '__main__':
    unittest.main()
