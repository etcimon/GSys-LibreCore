#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Cooperative bounded round-robin native ring turns, not GPU execution."""
import struct

from vn_rings import RingStore


class RingScheduler(RingStore):
    @property
    def active(self):
        return any(not ring.fatal and not ring.idle for ring in self.rings.values())

    def poll(self):
        keys = tuple(self.rings)
        if not keys:
            return 0
        start = self.cursor % len(keys)
        keys = keys[start:] + keys[:start]
        budget = [self.execution.max_commands, self.execution.max_bytes, self.execution.max_bytes]
        reads = [self.execution.max_bytes]
        completed = 0
        for index, key in enumerate(keys):
            ring = self.rings.get(key)
            self.cursor = start + index + 1
            if ring is None:
                continue
            if not self.live(ring):
                self.retire(ring)
                continue
            if not ring.fatal and not ring.idle:
                turn = [min(16, budget[0]), budget[1], budget[2]]
                commands = turn[0]
                completed += self._turn(ring, turn, reads)
                budget[0] -= commands - turn[0]
                budget[1:] = turn[1:]
            if not budget[0] or budget[1] < 8 or reads[0] < 8:
                break
        return completed

    def _pending(self, ring):
        tail = self.read32(ring, ring.tail_offset)
        count = (tail - (ring.head & 0xFFFFFFFF)) & 0xFFFFFFFF
        if count > ring.capacity or count % 4:
            raise ValueError('ring producer overrun or unaligned tail')
        return count

    def _turn(self, ring, budget, reads):
        if self.read32(ring, ring.head_offset) != (ring.head & 0xFFFFFFFF):
            self.status(ring, fatal=True)
            return 0
        self.status(ring)
        try:
            pending = self._pending(ring)
            if ring.task is not None and pending < ring.task.size:
                raise ValueError('producer withdrew an in-flight command')
        except ValueError:
            if ring.task is not None:
                ring.task.cancel()
                ring.task = None
            self.status(ring, fatal=True)
            return 0
        if ring.task is not None:
            return int(self._resume(ring, budget))
        if not pending:
            if self.clock() - ring.activity >= ring.idle_timeout:
                self.status(ring, idle=True)
                # Publish IDLE before the second tail load: a producer either
                # observes IDLE and notifies, or its tail is found here.
                try:
                    if self._pending(ring):
                        self.status(ring)
                except ValueError:
                    self.status(ring, fatal=True)
            else:
                self.status(ring)
            return 0
        count = min(pending, budget[1], reads[0])
        if count < 8:
            return 0
        reads[0] -= count
        offset = ring.head & (ring.capacity - 1)
        first = min(count, ring.capacity - offset)
        completed = position = 0
        with self.blobs.pin(ring.mapping):
            data = self.blobs.read(ring.mapping, ring.offset + ring.buffer_offset + offset, first)
            if first < count:
                data += self.blobs.read(ring.mapping, ring.offset + ring.buffer_offset, count - first)
            while position < len(data) and completed < 16 and budget[0]:
                chunk = data[position:]
                words = struct.unpack('<%dI' % (len(chunk) // 4), chunk)
                record = self.execution.decoder.run(words)
                if record['fault'] or not 0 < record['words'] <= len(words):
                    if record['fault'] == self.execution.golden.FAULT['BOUND'] and count < pending:
                        if position or count < self.execution.max_bytes:
                            break  # Retry with a full turn budget, never a partial command.
                    self.status(ring, fatal=True)
                    break
                length = record['words'] * 4
                try:
                    ring.task = self.execution.start_view(ring.view, chunk[:length])
                except MemoryError:
                    self.status(ring, fatal=True)
                    break
                if not self._resume(ring, budget):
                    break
                position += length
                completed += 1
                if budget[1] < 8:
                    break
        return completed

    def _resume(self, ring, budget):
        task = ring.task
        try:
            task.advance(budget, quantum=16)
        except (ValueError, KeyError, MemoryError):
            if self.live(ring):
                self.status(ring, fatal=True)
            ring.task = None
            return False
        if not self.live(ring) or task.state == 'cancelled':
            return False
        if task.state != 'done':
            return False
        ring.task = None
        ring.head += task.size
        self.write32(ring, ring.head_offset, ring.head)
        ring.activity = self.clock()
        return True
