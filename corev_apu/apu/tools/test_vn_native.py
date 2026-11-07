# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native blob, queue and MMIO integration; no RTL or Vulkan qualification."""
from dataclasses import replace
import struct
import unittest

from vn_blob_control import BlobController, CREATE_BLOB, MAP_BLOB, UNMAP_BLOB, RESP_MAP_INFO
from vn_blobs import BlobStore
from vn_control import (HEADER, CTX_CREATE, RESOURCE_UNREF, RESP_NODATA, ERR_PARAMETER,
                        ERR_UNSPEC, ERR_OOM)
from vn_control_queue import ControlBuffer, ControlQueue
from vn_dma import GuestDma
from vn_memory import ApertureState, SparseMemory
from vn_native_device import NativeDevice
from vn_resource_lifetime import ResourceState
from vn_split_queue import SplitQueue


class BlobTests(unittest.TestCase):
    def setUp(self):
        self.state = ApertureState(32768, 16384)
        self.blobs = BlobStore(self.state)
        self.blobs.create(1, 8192)

    def test_lazy_create_overlap_move_private_unmap_and_remap(self):
        self.assertFalse(any(self.state.ap_pages))
        first = self.blobs.map(1, 0)
        data = bytes(range(256)) * 32
        self.blobs.write(first, 0, data)
        moved = self.blobs.map(1, 4096)
        self.assertEqual(self.blobs.read(moved, 0, 8192), data)
        with self.assertRaises(KeyError):
            self.blobs.read(first, 0, 1)
        self.blobs.unmap(1)
        self.assertFalse(any(self.state.ap_pages[:4]))
        with self.assertRaises(KeyError):
            self.blobs.mapping(1)
        new = self.blobs.map(1, 8192)
        self.assertEqual(self.blobs.read(new, 0, 8192), data)
        self.blobs.unref(1)
        self.assertFalse(any(self.state.ap_pages))

    def test_failed_collision_and_invalid_map_preserve_ownership(self):
        original = self.blobs.map(1, 0)
        self.blobs.create(2, 4096)
        self.blobs.map(2, 8192)
        pages = list(self.state.ap_pages)
        for address in (-4096, 1, 12288, 4096):
            with self.assertRaises(ValueError):
                self.blobs.map(1, address)
            self.assertIs(self.blobs.mapping(1), original)
            self.assertEqual(self.state.ap_pages, pages)

    def test_pins_stale_forged_and_reused_ids(self):
        mapping = self.blobs.map(1, 0)
        with self.blobs.pin(mapping):
            for action in (lambda: self.blobs.map(1, 4096),
                           lambda: self.blobs.unmap(1), lambda: self.blobs.unref(1)):
                with self.assertRaises(BlockingIOError):
                    action()
        with self.assertRaises(KeyError):
            self.blobs.read(replace(mapping), 0, 1)
        with self.assertRaises(ValueError):
            self.blobs.write(mapping, 8191, b'xx')
        self.blobs.unref(1)
        self.blobs.create(1, 4096)
        self.blobs.map(1, 0)
        with self.assertRaises(KeyError):
            self.blobs.read(mapping, 0, 1)

    def test_private_exhaustion_and_io_fault_preserve_metadata(self):
        tiny = ApertureState(8192, 8192)
        blobs = BlobStore(tiny)
        blobs.create(1, 4096)
        mapping = blobs.map(1, 0)
        with self.assertRaises(MemoryError):
            blobs.unmap(1)
        self.assertIs(blobs.mapping(1), mapping)
        original = tiny.aperture.write
        tiny.aperture.write = lambda *args: (_ for _ in ()).throw(OSError('bus'))
        with self.assertRaises(OSError):
            blobs.map(1, 4096)
        self.assertIs(blobs.mapping(1), mapping)
        tiny.aperture.write = original

    def test_create_validation_and_budget(self):
        for resource, size in ((0, 1), (True, 1), (3, 0), (3, 16385)):
            with self.assertRaises(ValueError):
                self.blobs.create(resource, size)
        with self.assertRaises(KeyError):
            self.blobs.create(1, 4096)
        store = BlobStore(ApertureState(8192, 4096), max_blobs=1)
        store.create(1, 1)
        with self.assertRaises(MemoryError):
            store.create(2, 1)


class BlobControlTests(unittest.TestCase):
    def setUp(self):
        self.state = ApertureState(16384, 8192)
        self.blobs = BlobStore(self.state)
        self.control = BlobController(ResourceState(self.state.aperture), self.blobs)

    def packet(self, command, body):
        return HEADER.pack(command, 1, 9, 1, 0) + body

    def create(self, memory_id=0):
        return self.packet(CREATE_BLOB, struct.pack('<IIIIQQ', 1, 2, 1, 0,
                                                   memory_id, 4096))

    def test_wire_blob_lifecycle_and_unsupported_memory_backing(self):
        self.assertEqual(HEADER.unpack(self.control.dispatch(self.create()))[0], RESP_NODATA)
        request = self.packet(MAP_BLOB, struct.pack('<IIQ', 1, 0, 0))
        self.assertEqual(HEADER.unpack(self.control.dispatch(request))[0], ERR_PARAMETER)
        self.assertFalse(any(self.state.ap_pages))
        reply = self.control.dispatch(request, response_capacity=32)
        self.assertEqual(HEADER.unpack_from(reply)[0], RESP_MAP_INFO)
        self.assertEqual(reply[24:], struct.pack('<II', 3, 0))
        old = self.blobs.mapping(1)
        self.control.dispatch(self.packet(UNMAP_BLOB, struct.pack('<II', 1, 0)))
        self.control.dispatch(request, response_capacity=32)
        self.control.dispatch(self.packet(RESOURCE_UNREF, struct.pack('<II', 1, 0)))
        with self.assertRaises(KeyError):
            self.blobs.read(old, 0, 1)
        self.assertEqual(HEADER.unpack(self.control.dispatch(self.create(99)))[0], ERR_UNSPEC)

    def test_map_reply_pre_authorized_and_reset_waits_for_pins(self):
        self.control.dispatch(self.create())
        self.blobs.map(1, 0)
        mapping = self.blobs.mapping(1)
        with self.blobs.pin(mapping):
            with self.assertRaises(BlockingIOError):
                self.control.reset()
        self.assertIs(self.blobs.mapping(1), mapping)
        dma = GuestDma(self.state.guest_ram)
        dma.policy.grant(0x1000, 128, read=True)
        dma.policy.grant(0x2000, 24, read=False, write=True)
        request = self.packet(MAP_BLOB, struct.pack('<IIQ', 1, 0, 4096))
        self.state.guest_ram.write(0x1000, request)
        with self.assertRaises(PermissionError):
            ControlQueue(self.control, dma).process([
                ControlBuffer(0x1000, 40), ControlBuffer(0x2000, 32, True)])
        self.assertIs(self.blobs.mapping(1), mapping)
        self.control.reset()
        with self.assertRaises(KeyError):
            self.blobs.read(mapping, 0, 1)


class DeviceTests(unittest.TestCase):
    def setUp(self):
        self.memory = SparseMemory({}, 1 << 64)
        self.device = NativeDevice(self.memory, dma_base=0x1000, dma_bytes=0x40000,
                                   shm_base=0x30000, shm_bytes=16384, shm_guest_bytes=8192,
                                   queue_depth=8)
        self.device.write32(0x70, 1)
        self.device.write32(0x70, 3)
        self.device.write32(0x24, 1)
        self.device.write32(0x20, (self.device.FEATURES >> 32) & 0xFFFFFFFF)
        self.device.write32(0x24, 0)
        self.device.write32(0x20, self.device.FEATURES & 0xFFFFFFFF)
        self.device.write32(0x70, 11)
        for address, value in ((0x38, 4), (0x80, 0x1000), (0x90, 0x2000),
                               (0xA0, 0x3000), (0x44, 1)):
            self.device.write32(address, value)
        self.device.write32(0x70, 15)

    def submit(self, payload, index=1, flags=0, next_index=1):
        self.memory.write(0x4000, payload)
        self.memory.write(0x1000, struct.pack('<QIHH', 0x4000, len(payload), 1, next_index))
        self.memory.write(0x1010, struct.pack('<QIHH', 0x5000, 64, 2, 0))
        self.memory.write(0x2000, struct.pack('<HH', flags, index))
        self.memory.write(0x2004 + 2 * ((index - 1) % 4), b'\0\0')
        self.device.write32(0x50, 0)

    def create(self):
        return HEADER.pack(CTX_CREATE, 1, 1, 1, 0) + struct.pack('<II64s', 0, 4, b'')

    def test_control_to_used_ring_irq_ack_and_reset(self):
        self.submit(self.create())
        self.assertEqual(struct.unpack('<II', self.memory.read(0x3004, 8)), (0, 24))
        self.assertEqual(self.memory.read(0x3002, 2), b'\1\0')
        self.assertTrue(self.device.irq)
        self.device.write32(0x64, 1)
        self.assertFalse(self.device.irq)
        self.device.write32(0xC0, 1)
        self.assertFalse(self.device.queue.ready)
        self.device.write32(0x70, 0)
        self.assertEqual(self.device.status, 0)
        self.assertFalse(self.device.controller._contexts)

    def test_cyclic_indirect_and_overrun_do_not_publish(self):
        self.submit(self.create(), next_index=0)
        self.assertTrue(self.device.status & 64)
        self.assertEqual(self.device.interrupt_status, 2)
        self.assertFalse(self.device.controller._contexts)
        self.assertEqual(self.memory.read(0x3002, 2), b'\0\0')

    def test_irq_suppression_and_index_wrap(self):
        self.device.queue.last_avail = 65535
        self.device.queue.used_index = 65535
        self.submit(self.create(), index=0, flags=1)
        self.assertEqual(self.device.queue.last_avail, 0)
        self.assertEqual(self.device.queue.used_index, 0)
        self.assertFalse(self.device.irq)

    def test_shared_guest_private_domain_and_no_vulkan_advertisement(self):
        self.assertEqual(self.device.read32(0x10C), 0)
        self.device.write32(0xAC, 1)
        self.assertEqual(self.device.read32(0xB0), 8192)
        self.device.blobs.create(1, 4096)
        mapping = self.device.blobs.map(1, 0)
        self.device.blobs.write(mapping, 0, b'abcd')
        self.assertEqual(self.memory.read(0x30000, 4), b'abcd')
        self.device.blobs.unmap(1)
        self.memory.write(0x30000, b'xxxx')
        new = self.device.blobs.map(1, 4096)
        self.assertEqual(self.device.blobs.read(new, 0, 4), b'abcd')

    def test_live_queue_is_immutable_and_status_monotonic(self):
        for address, value in ((0x38, 8), (0x20, 0), (0x70, 3), (0x50, 1)):
            with self.assertRaises(ValueError):
                self.device.write32(address, value)
        with self.assertRaises(ValueError):
            self.device.read32(1)
