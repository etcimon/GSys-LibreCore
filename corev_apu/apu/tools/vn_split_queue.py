#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded split virtqueues with immediate and deferred used publication."""
import struct

from vn_control_queue import ControlBuffer, DeferredCompletion


class SplitQueue:
    def __init__(self, dma, processor, *, max_size=256, max_chain=16, legacy_used=False):
        self.dma = dma
        self.processor = processor
        self.max_size = max_size
        self.max_chain = max_chain
        self.legacy_used = legacy_used
        self.size = 0
        self.desc = self.avail = self.used = 0
        self.ready = False
        self.last_avail = self.used_index = 0
        self.pending = {}

    def enable(self):
        if (not 0 < self.size <= self.max_size or self.size & (self.size - 1) or
                self.desc % 16 or self.avail % 2 or self.used % 4):
            raise ValueError('invalid split queue geometry')
        self.dma.memory._check_range(self.desc, 16 * self.size)
        self.dma.memory._check_range(self.avail, 4 + 2 * self.size)
        self.dma.memory._check_range(self.used, 4 + 8 * self.size)
        self.dma.policy.check(self.desc, 16 * self.size)
        self.dma.policy.check(self.avail, 4 + 2 * self.size)
        self.dma.policy.check(self.used, 4 + 8 * self.size, write=True)
        self.ready = True

    def _chain(self, head):
        buffers, seen = [], set()
        index, writing = head, False
        while True:
            if index >= self.size or index in seen or len(seen) >= self.max_chain:
                raise ValueError('cyclic, oversized or out-of-range descriptor chain')
            seen.add(index)
            address, size, flags, next_index = struct.unpack(
                '<QIHH', self.dma.read(self.desc + index * 16, 16))
            if flags & ~3:
                raise ValueError('indirect/reserved descriptor flags were not negotiated')
            writable = bool(flags & 2)
            if writing and not writable:
                raise ValueError('readable descriptor follows writable descriptor')
            writing |= writable
            buffers.append(ControlBuffer(address, size, writable))
            if not flags & 1:
                return buffers
            index = next_index

    def drain(self):
        if not self.ready:
            raise ValueError('split queue is not ready')
        flags, index = struct.unpack('<HH', self.dma.read(self.avail, 4))
        pending = (index - self.last_avail) & 0xFFFF
        if pending > self.size - len(self.pending):
            raise ValueError('available index overran the queue')
        completed = 0
        for _ in range(pending):
            slot = self.last_avail % self.size
            head = struct.unpack('<H', self.dma.read(self.avail + 4 + 2 * slot, 2))[0]
            if head in self.pending or len(self.pending) >= self.size:
                raise ValueError('reused or excessive in-flight descriptor heads')
            buffers = self._chain(head)
            used_slot = self.used + 4 + 8 * (self.used_index % self.size)
            # Publication permissions must be established before control state
            # changes, not discovered after resource teardown.
            self.dma.policy.check(used_slot, 8, write=True)
            self.dma.policy.check(self.used + 2, 2, write=True)
            completion = self.processor.process(buffers)
            self.last_avail = (self.last_avail + 1) & 0xFFFF
            if isinstance(completion, DeferredCompletion):
                self.pending[head] = completion
            else:
                self._publish(head, completion)
                completed += 1
        return completed, bool(completed and not flags & 1)

    def _publish(self, head, completion):
        used_slot = self.used + 4 + 8 * (self.used_index % self.size)
        length = completion.used_bytes if self.legacy_used else completion.reply_bytes
        self.dma.write(used_slot, struct.pack('<II', head, length))
        next_used = (self.used_index + 1) & 0xFFFF
        self.dma.write(self.used + 2, struct.pack('<H', next_used))
        self.used_index = next_used

    def poll(self):
        if not self.pending:
            return 0, False
        flags = struct.unpack('<H', self.dma.read(self.avail, 2))[0]
        budget = [256, 65536, 65536]
        completed = 0
        for head, pending in tuple(self.pending.items()):
            used_slot = self.used + 4 + 8 * (self.used_index % self.size)
            self.dma.policy.check(used_slot, 8, write=True)
            self.dma.policy.check(self.used + 2, 2, write=True)
            completion = pending.poll(budget)
            if completion is not None:
                self._publish(head, completion)
                del self.pending[head]
                completed += 1
            if not budget[0] or budget[1] < 8:
                break
        return completed, bool(completed and not flags & 1)
