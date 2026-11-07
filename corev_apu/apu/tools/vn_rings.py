#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native Venus ring catalogue, mapping pins and transport lifecycle."""
from dataclasses import dataclass, replace
import struct
import time


IDLE, FATAL, ALIVE = 1, 2, 4


class RingBlocked(Exception):
    """A direct ring wait parks at its command, without publishing its head."""


@dataclass
class NativeRing:
    context: object
    handle: int
    mapping: object
    offset: int
    size: int
    head_offset: int
    tail_offset: int
    status_offset: int
    buffer_offset: int
    capacity: int
    extra_offset: int
    extra_size: int
    idle_timeout: int
    activity: int
    pin: object
    view: object
    head: int = 0
    idle: bool = False
    fatal: bool = False
    task: object = None


class RingStore:
    def __init__(self, execution, *, max_rings=64, clock=time.monotonic_ns):
        if type(max_rings) is not int or max_rings <= 0:
            raise ValueError('invalid ring catalogue budget')
        self.execution, self.blobs = execution, execution.blobs
        self.max_rings, self.clock = max_rings, clock
        self.rings = {}
        self.sem_res = {}               # semaphore handle -> resourceId
        self.cursor = 0

    def _key(self, ring):
        return ring.context.frontend.ctx, ring.handle

    def live(self, ring):
        context = ring.context
        if (self.rings.get(self._key(ring)) is not ring or context.retired or context.faulted or
                self.execution.contexts.get(context.frontend.ctx) is not context):
            return False
        try:
            self.blobs._live(ring.mapping, ring.offset, ring.size)
        except (KeyError, ValueError):
            return False
        return True

    def read32(self, ring, offset):
        return struct.unpack('<I', self.blobs.read(ring.mapping, ring.offset + offset, 4))[0]

    def write32(self, ring, offset, value):
        self.blobs.write(ring.mapping, ring.offset + offset, struct.pack('<I', value & 0xFFFFFFFF))

    def status(self, ring, *, idle=False, fatal=False):
        ring.fatal = ring.fatal or fatal
        self.write32(ring, ring.status_offset,
                     ALIVE | (FATAL if ring.fatal else 0) | (IDLE if idle else 0))
        ring.idle = idle

    def create(self, context, words, record):
        def u64(index):
            return words[index] | words[index + 1] << 32

        start = 9 + 4 * len(record['chain'])
        flags, resource = words[start:start + 2]
        offset, size, timeout, head, tail, status, buffer, capacity, extra, extra_size = (
            u64(start + index) for index in range(2, 22, 2))
        handle = u64(2)
        key = (context.frontend.ctx, handle)
        mapping = self.blobs.mapping(resource)
        self.blobs._live(mapping, offset, size)
        ranges = [(head, head + 4), (tail, tail + 4), (status, status + 4),
                  (buffer, buffer + capacity)]
        if extra_size:
            ranges.append((extra, extra + extra_size))
        if (flags or key in self.rings or len(self.rings) >= self.max_rings or
                offset % 4 or capacity < 8 or capacity & (capacity - 1) or
                extra % 4 or extra_size % 4 or extra > size or
                any(lo % 4 or hi > size for lo, hi in ranges) or
                any(a < d and c < b for index, (a, b) in enumerate(ranges)
                    for c, d in ranges[index + 1:])):
            raise ValueError('invalid ring geometry, duplicate handle or ring budget')
        absolute = mapping.base + offset
        if any(absolute < other.mapping.base + other.offset + other.size and
               other.mapping.base + other.offset < absolute + size
               for other in self.rings.values()):
            raise ValueError('ring windows overlap a live ring')
        pin = self.blobs.pin(mapping)
        view = replace(context, reply=None, owners=context.owners)
        ring = NativeRing(context, handle, mapping, offset, size, head, tail, status,
                          buffer, capacity, extra, extra_size, timeout, self.clock(), pin, view)
        view.active_ring = ring
        pin.__enter__()
        try:
            if self.read32(ring, head) or self.read32(ring, tail):
                raise ValueError('ring counters must start at zero')
            self.write32(ring, status, ALIVE)
            self.rings[key] = ring
        except BaseException:
            pin.__exit__(None, None, None)
            raise
        return ring

    def retire(self, ring):
        if self.rings.get(self._key(ring)) is ring:
            del self.rings[self._key(ring)]
            if ring.task is not None:
                ring.task.cancel()
            ring.pin.__exit__(None, None, None)

    def retire_context(self, context):
        for ring in tuple(self.rings.values()):
            if ring.context is context:
                self.retire(ring)

    def prepare_reset(self):
        pins = {}
        for ring in self.rings.values():
            resource = ring.mapping.resource
            pins[resource] = pins.get(resource, 0) + 1
        for task in self.execution.tasks.values():
            for mapping, _ in task.pins:
                resource = mapping.resource
                pins[resource] = pins.get(resource, 0) + 1
        if any(blob.pins != pins.get(resource, 0)
               for resource, blob in self.blobs.blobs.items()):
            raise BlockingIOError('reset requires external blob jobs to drain')
        for ring in tuple(self.rings.values()):
            self.retire(ring)
        for task in tuple(self.execution.tasks.values()):
            task.cancel()

    def command(self, current, name, words, record, depth):
        def u64(index):
            return words[index] | words[index + 1] << 32

        context = self.execution.contexts[current.frontend.ctx]
        if name == 'vkCreateRingMESA':
            self.create(context, words, record)
            return
        if name == 'vkSubmitVirtqueueSeqnoMESA':
            if u64(2):
                raise ValueError('only the native control timeline is implemented')
            context.vq_seqno = max(context.vq_seqno, u64(4))
            return
        if name == 'vkWaitVirtqueueSeqnoMESA':
            reached = context.vq_seqno >= u64(2)
        else:
            ring = self.rings.get((context.frontend.ctx, u64(2)))
            if ring is None or not self.live(ring):
                raise KeyError('ring handle is absent or stale')
            if name == 'vkDestroyRingMESA':
                self.retire(ring)
                return
            if name == 'vkNotifyRingMESA':
                if words[5] or ring.fatal:
                    raise ValueError('invalid flags or notification of a fatal ring')
                self.status(ring)
                ring.activity = self.clock()
                return
            if name == 'vkWriteRingExtraMESA':
                offset = u64(4)
                if offset % 4 or offset + 4 > ring.extra_size:
                    raise ValueError('ring extra write exceeds its extent')
                self.write32(ring, ring.extra_offset + offset, words[6])
                return
            if name != 'vkWaitRingSeqnoMESA' or ring.fatal:
                raise ValueError('unsupported ring operation or fatal dependency')
            reached = ring.head >= u64(4)
        if not reached:
            raise RingBlocked()
