#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Authorized native control queue with deferred stream completions.

Raw vring walking, asynchronous DMA/bus faults, used-ring publication and IRQs
remain transport responsibilities. The caller serializes mapping and commands.
"""
from dataclasses import dataclass

from vn_control import HEADER
from vn_deferred import DeferredReply
from vn_dma import GuestDma


@dataclass(frozen=True)
class ControlBuffer:
    address: int
    size: int
    writable: bool = False


@dataclass(frozen=True)
class ControlCompletion:
    request_bytes: int
    reply_bytes: int

    @property
    def used_bytes(self):
        # Existing G6LC vgctl/vector contract counts consumed plus written.
        # Keep this separate from standard virtqueue written-byte accounting.
        return self.request_bytes + self.reply_bytes


class ControlQueue:
    """Authorize a full chain before any control or guest-memory mutation."""

    def __init__(self, dispatcher, dma, *, max_descriptors=16):
        if not isinstance(dma, GuestDma):
            raise TypeError('control queue requires an explicit GuestDma facade')
        if type(max_descriptors) is not int or max_descriptors <= 0:
            raise ValueError('invalid control descriptor budget')
        self.dispatcher = dispatcher
        self.dma = dma
        self.max_descriptors = max_descriptors

    def process(self, buffers):
        reads, writes = [], []
        request_bytes, capacity = 0, 0
        for index, buffer in enumerate(buffers):
            if index >= self.max_descriptors:
                raise ValueError('control chain exceeds descriptor budget')
            if not isinstance(buffer, ControlBuffer):
                raise TypeError('invalid control buffer')
            if (type(buffer.address) is not int or not 0 <= buffer.address < 1 << 64 or
                    type(buffer.size) is not int or not 0 <= buffer.size <= 0xFFFFFFFF or
                    type(buffer.writable) is not bool or
                    buffer.address + buffer.size > self.dma.memory.size_bytes):
                raise ValueError('invalid control buffer range or flags')
            if buffer.writable:
                capacity += buffer.size
                writes.append(buffer)
            else:
                request_bytes += buffer.size
                reads.append(buffer)
        if not HEADER.size <= request_bytes <= self.dispatcher.max_request:
            raise ValueError('control request exceeds packet bounds')
        if capacity < HEADER.size:
            raise ValueError('control chain has no complete reply buffer')
        for buffer in reads:
            self.dma.policy.check(buffer.address, buffer.size)
        request = b''.join(self.dma.read(buffer.address, buffer.size) for buffer in reads)
        remaining = self.dispatcher.reply_size(request, capacity)
        if remaining > capacity:
            raise ValueError('control reply exceeds writable capacity')
        targets = []
        for buffer in writes:
            count = min(remaining, buffer.size)
            if count:
                self.dma.policy.check(buffer.address, count, write=True)
                targets.append((buffer.address, count))
                remaining -= count
        # All bounded reads and actual reply writes are authorized before the
        # dispatcher can retire a context or revoke a backing resource.
        reply = self.dispatcher.dispatch(request, response_capacity=capacity)
        if isinstance(reply, DeferredReply):
            return DeferredCompletion(reply, self.dma, targets, request_bytes)
        offset = 0
        for address, count in targets:
            part = reply[offset:offset + count]
            if part:
                self.dma.write(address, part)
                offset += len(part)
        return ControlCompletion(request_bytes, len(reply))


class DeferredCompletion:
    def __init__(self, reply, dma, targets, request_bytes):
        self.reply, self.dma, self.targets = reply, dma, targets
        self.request_bytes = request_bytes

    def poll(self, budget):
        # Authorization must still hold before resuming guest-visible work.
        for address, count in self.targets:
            self.dma.policy.check(address, count, write=True)
        task = self.reply.task
        if not task.terminal:
            try:
                task.advance(budget, quantum=16)
            except (ValueError, KeyError, MemoryError):
                task.parent.faulted = True
                task.execution.cancel_tasks(task.parent)
                task.execution.rings.retire_context(task.parent)
        data = self.reply.poll()
        if data is None:
            return None
        offset = 0
        for address, count in self.targets:
            part = data[offset:offset + count]
            if part:
                self.dma.write(address, part)
                offset += len(part)
        return ControlCompletion(self.request_bytes, len(data))
