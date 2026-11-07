#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Experimental native virtio-mmio GPU; diagnostic opt-ins, zero Vulkan capsets."""
from vn_blob_control import BlobController
from vn_memory_blobs import MemoryBlobs
from vn_control_queue import ControlQueue
from vn_dma import GuestDma
from vn_memory import ApertureState, SparseMemory
from vn_resource_lifetime import ResourceState
from vn_split_queue import SplitQueue
from vn_native_execution import ExecutionService, check_submission_modes


class SharedAperture:
    """Guest-visible bytes alias peer DRAM; device-private bytes stay private."""

    def __init__(self, dma, base, total, guest):
        self.dma, self.base, self.size_bytes, self.guest = dma, base, total, guest
        self.private = SparseMemory({}, total)

    def _check_range(self, address, size):
        self.private._check_range(address, size)

    def read(self, address, size):
        self.private._check_range(address, size)
        count = min(size, max(0, self.guest - address))
        data = self.dma.read(self.base + address, count) if count else b''
        return data + self.private.read(address + count, size - count)

    def write(self, address, data):
        data = memoryview(data).tobytes()
        self.private._check_range(address, len(data))
        count = min(len(data), max(0, self.guest - address))
        if count:
            self.dma.write(self.base + address, data[:count])
        if count < len(data):
            self.private.write(address + count, data[count:])


class NativeDevice:
    FEATURES = (1 << 32) | (1 << 40) | (1 << 3) | (1 << 4)

    def __init__(self, memory, *, dma_base, dma_bytes, shm_base, shm_bytes,
                 shm_guest_bytes, queue_depth=64, shm_id=1, legacy_used=False,
                 transfer_submit=False, compute_submit=False):
        check_submission_modes(transfer_submit, compute_submit)
        if (type(queue_depth) is not int or not 0 < queue_depth <= 32768 or
                queue_depth & (queue_depth - 1) or dma_bytes <= 0 or dma_base < 0 or
                dma_base + dma_bytes > memory.size_bytes or shm_base < dma_base or
                shm_base + shm_guest_bytes > dma_base + dma_bytes):
            raise ValueError('invalid native device memory/queue geometry')
        self.memory = memory
        self.dma = GuestDma(memory)
        self.dma.policy.grant(dma_base, dma_bytes, read=True, write=True)
        self.geometry = (shm_base, shm_bytes, shm_guest_bytes)
        self.queue_depth, self.shm_id, self.legacy_used = queue_depth, shm_id, legacy_used
        self.transfer_submit = transfer_submit
        self.compute_submit = compute_submit
        self.reset()

    def reset(self):
        if hasattr(self, 'controller'):
            self.controller.reset()
        base, total, guest = self.geometry
        self.state = ApertureState(total, guest)
        self.state.aperture = SharedAperture(self.dma, base, total, guest)
        self.resources = ResourceState(self.state.aperture)
        self.blobs = MemoryBlobs(self.state)
        self.execution = ExecutionService(self.state, self.blobs,
                                          transfer_submit=self.transfer_submit,
                                          compute_submit=self.compute_submit)
        self.controller = BlobController(self.resources, self.blobs, execution=self.execution,
                                         max_request=65568)
        self.processor = ControlQueue(self.controller, self.dma)
        self.queue = self._new_queue()
        self.queue_reconfigurable = False
        self.status = self.interrupt_status = 0
        self.device_features_sel = self.driver_features_sel = self.queue_sel = 0
        self.driver_features = self.shm_sel = 0
        self.last_error = ''

    def _new_queue(self):
        return SplitQueue(self.dma, self.processor, max_size=self.queue_depth,
                          legacy_used=self.legacy_used)

    @property
    def irq(self):
        return bool(self.interrupt_status)

    @property
    def ring_polling(self):
        return (self.status & 15 == 15 and not self.status & (64 | 128) and
                (self.execution.active or bool(self.queue.pending)))

    def poll_rings(self):
        if not self.ring_polling:
            return 0
        try:
            completed = self.execution.poll()
            count, irq = self.queue.poll()
            if irq:
                self.interrupt_status |= 1
            return completed + count
        except (ValueError, OSError) as error:
            self.last_error = str(error)[:512]
            self.status |= 64
            self.interrupt_status |= 2
            return 0

    def _offset(self, offset):
        if type(offset) is not int or offset < 0 or offset >= 0x1000 or offset % 4:
            raise ValueError('unaligned or out-of-window MMIO')

    def read32(self, offset):
        self._offset(offset)
        fixed = {0: 0x74726976, 4: 2, 8: 16, 12: 0x47534C43,
                 0x14: self.device_features_sel, 0x24: self.driver_features_sel,
                 0x30: self.queue_sel, 0x60: self.interrupt_status, 0x70: self.status,
                 0xAC: self.shm_sel, 0xC0: 0, 0xFC: 0,
                 0x100: 0, 0x108: 0, 0x10C: 0}
        if offset in fixed:
            return fixed[offset]
        if offset == 0x10:
            return ((self.FEATURES >> (32 * self.device_features_sel)) & 0xFFFFFFFF
                    if self.device_features_sel < 2 else 0)
        if offset == 0x20:
            return ((self.driver_features >> (32 * self.driver_features_sel)) & 0xFFFFFFFF
                    if self.driver_features_sel < 2 else 0)
        if offset in (0xB0, 0xB4, 0xB8, 0xBC):
            if self.shm_sel != self.shm_id:
                return 0xFFFFFFFF
            value = self.geometry[2] if offset < 0xB8 else self.geometry[0]
            return (value >> (32 if offset in (0xB4, 0xBC) else 0)) & 0xFFFFFFFF
        if self.queue_sel:
            return 0
        q = self.queue
        values = {0x34: self.queue_depth, 0x38: q.size, 0x44: int(q.ready),
                  0x80: q.desc & 0xFFFFFFFF, 0x84: q.desc >> 32,
                  0x90: q.avail & 0xFFFFFFFF, 0x94: q.avail >> 32,
                  0xA0: q.used & 0xFFFFFFFF, 0xA4: q.used >> 32}
        return values.get(offset, 0)

    def write32(self, offset, value, strobe=15):
        self._offset(offset)
        if not 0 <= value <= 0xFFFFFFFF or not 0 <= strobe <= 15:
            raise ValueError('invalid MMIO data/strobe')
        if not strobe:
            return
        mask = sum(0xFF << (8 * i) for i in range(4) if strobe & (1 << i))
        if offset in (0x50, 0x64, 0xC0):
            value &= mask
        else:
            value = (self.read32(offset) & ~mask) | (value & mask)
        if offset == 0x70:
            self._status(value)
        elif offset == 0x14:
            self.device_features_sel = value
        elif offset == 0x24:
            self.driver_features_sel = value
        elif offset == 0x20:
            if not self.status & 2 or self.status & (8 | 64 | 128):
                raise ValueError('features cannot change in this state')
            if self.driver_features_sel >= 2:
                if value:
                    raise ValueError('feature selector out of range')
            else:
                shift = self.driver_features_sel * 32
                self.driver_features = ((self.driver_features & ~(0xFFFFFFFF << shift)) |
                                        (value << shift))
        elif offset == 0x30:
            self.queue_sel = value
        elif offset == 0xAC:
            self.shm_sel = value
        elif offset == 0x64:
            self.interrupt_status &= ~(value & 3)
        elif offset == 0x50:
            if value or self.status & (64 | 128) or self.status & 15 != 15:
                raise ValueError('queue notification while device is not live')
            try:
                _, irq = self.queue.drain()
                if irq:
                    self.interrupt_status |= 1
            except (ValueError, OSError) as error:
                self.last_error = str(error)[:512]
                self.status |= 64
                self.interrupt_status |= 2
        elif offset == 0xC0:
            if self.queue_sel or value not in (0, 1) or not self.driver_features & (1 << 40):
                raise ValueError('queue reset was not negotiated')
            if value:
                for pending in self.queue.pending.values():
                    pending.reply.task.cancel()
                self.queue = self._new_queue()
                self.queue_reconfigurable = True
        elif offset in (0x38, 0x44, 0x80, 0x84, 0x90, 0x94, 0xA0, 0xA4):
            self._queue_write(offset, value)
        else:
            raise ValueError('unsupported/read-only MMIO register')

    def _status(self, value):
        if value == 0:
            self.reset()
            return
        value &= 0x8F
        old = self.status & 0x8F
        if (old & ~value or value & 2 and not value & 1 or
                value & 8 and value & 3 != 3 or value & 4 and not old & 8):
            raise ValueError('invalid device status transition')
        if value & 8 and (self.driver_features & ~self.FEATURES or
                          not self.driver_features & (1 << 32)):
            value &= ~(8 | 4)
        self.status = value | (self.status & 64)

    def _queue_write(self, offset, value):
        q = self.queue
        if (self.queue_sel or not self.status & 2 or self.status & (64 | 128) or
                self.status & 4 and not self.queue_reconfigurable):
            raise ValueError('queue configuration is not writable')
        if offset == 0x44:
            if value not in (0, 1):
                raise ValueError('invalid queue ready bit')
            if value and not q.ready:
                q.enable()
                self.queue_reconfigurable = False
            elif not value:
                if q.ready:
                    raise ValueError('use negotiated queue reset')
            return
        if q.ready:
            raise ValueError('ready queue configuration is immutable')
        if offset == 0x38:
            if not 0 < value <= self.queue_depth or value & (value - 1):
                raise ValueError('invalid queue size')
            q.size = value
        else:
            name = {0x80: 'desc', 0x84: 'desc', 0x90: 'avail', 0x94: 'avail',
                    0xA0: 'used', 0xA4: 'used'}[offset]
            shift = 32 if offset & 4 else 0
            old = getattr(q, name)
            setattr(q, name, (old & ~(0xFFFFFFFF << shift)) | (value << shift))
