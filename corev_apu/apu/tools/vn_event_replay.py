#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded command-buffer event ops: ordered signal/wait with live entries."""

MAX_EVENTS = 16


class EventSignal:
    """Set or clear one event at its recorded stream position."""
    __slots__ = ('entries', 'signaled', 'size')

    def __init__(self, entries, signaled):
        if (not isinstance(entries, tuple) or len(entries) != 1 or
                any(not isinstance(entry, dict) for entry in entries)):
            raise ValueError('invalid native event signal operation')
        self.entries = entries
        self.signaled = bool(signaled)
        self.size = 0


class EventWait:
    """Stall subsequent ops until every listed event is signaled."""
    __slots__ = ('entries', 'size')

    def __init__(self, entries):
        if (not isinstance(entries, tuple) or not entries or
                len(entries) > MAX_EVENTS or
                any(not isinstance(entry, dict) for entry in entries)):
            raise ValueError('invalid native event wait operation')
        self.entries = entries
        self.size = 0


class _EventRuntime:
    def __init__(self, executor, context, operation):
        self.executor, self.context, self.operation = executor, context, operation
        self.owners = {}
        self.last_turn = 0
        self.done = False


class EventSignalRuntime(_EventRuntime):
    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        (entry,) = self.operation.entries
        entry['state'] = (entry['state'] & ~1) | (1 if self.operation.signaled else 0)
        self.done = True
        return 0


class EventWaitRuntime(_EventRuntime):
    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        if all(entry['state'] & 1 for entry in self.operation.entries):
            self.done = True
        return 0


def replay(images, record, name, *, compute=False, device=None):
    """Validate and emit ordered event ops for Set/Reset/WaitEvents records."""
    from vn_image_barriers import scope, WORDS
    golden = images.engine.golden
    imm = record['imm']
    if name in ('vkCmdSetEvent', 'vkCmdResetEvent'):
        if (record.get('payload_words', 0) != 0 or
                any(imm[1:7]) or imm[7] or any(record['handle'][1:])):
            raise ValueError('event signal record exceeds native profile')
        scope(imm[0], 0, compute=compute)
        _, entry = images.remember(record['handle'][0], golden.KIND['VkEvent'])
        if device is not None and entry['parent'] != device:
            raise ValueError('event signal crosses command-buffer devices')
        images.operations.append(EventSignal((entry,), name == 'vkCmdSetEvent'))
        return
    count = imm[0]
    memory, buffers, barrier_count = imm[3], imm[4], imm[5]
    barrier_words = memory * 2 + buffers * 10 + barrier_count * WORDS
    if (count > MAX_EVENTS or not count + bool(barrier_words) or
            record.get('payload_words') != count + barrier_words or
            imm[6]):
        raise ValueError('event wait record exceeds native profile')
    scope(imm[1], 0, compute=compute)
    scope(imm[2], 0, compute=compute)
    entries = []
    for word in images.payload(record, count):
        _, entry = images.remember(word, golden.KIND['VkEvent'])
        if device is not None and entry['parent'] != device:
            raise ValueError('event wait crosses command-buffer devices')
        entries.append(entry)
    if entries:
        if images._remaining() < 1:
            raise MemoryError('event wait operation budget exhausted')
        images.operations.append(EventWait(tuple(entries)))
    if barrier_words:
        # the retained barrier structs replay through the shared coherent
        # barrier path; a synthetic record presents them in the
        # PipelineBarrier imm layout with the payload offset past the
        # canonical event-handle words
        from vn_image_barriers import replay as replay_barrier
        barrier = dict(record)
        barrier['imm'] = [imm[1], imm[2], 0, memory, buffers,
                          barrier_count, 0, imm[7]]
        replay_barrier(images, barrier, compute=compute, device=device,
                       offset=count)
