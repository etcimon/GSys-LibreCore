#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded conditional rendering: predicate-gated draw execution."""


class CondBegin:
    """Open a conditional region reading a 32-bit predicate word."""
    __slots__ = ('owner', 'offset', 'inverted', 'size')

    def __init__(self, owner, offset, inverted):
        if (owner is None or type(offset) is not int or offset < 0 or
                type(inverted) is not int or inverted not in (0, 1)):
            raise ValueError('invalid native conditional begin operation')
        self.owner, self.offset, self.inverted = owner, offset, inverted
        self.size = 0


class CondEnd:
    """Close the active conditional region."""
    __slots__ = ('size',)

    def __init__(self):
        self.size = 0


class _CondRuntime:
    def __init__(self, executor, context, operation):
        self.executor, self.context, self.operation = executor, context, operation
        self.owners = {}
        self.last_turn = 0
        self.done = False


class CondBeginRuntime(_CondRuntime):
    def __init__(self, executor, context, operation):
        super().__init__(executor, context, operation)
        op = operation
        # enqueue-time extent validation mirrors Transfer._extent so a
        # stale/unbacked predicate faults before any pin
        self.base = executor._extent(context, op.owner, op.offset, 4)
        self.owners = {id(op.owner): op.owner}

    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        self.executor.cond[id(self.context)] = (
            self.base, self.operation.inverted)
        self.done = True
        return 0


class CondEndRuntime(_CondRuntime):
    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        self.executor.cond.pop(id(self.context), None)
        self.done = True
        return 0


def replay(images, record, name, *, device=None):
    """Validate and emit ordered conditional ops for the admitted records."""
    golden = images.engine.golden
    imm = record['imm']
    if name == 'vkCmdEndConditionalRenderingEXT':
        if (any(imm) or any(record['handle']) or
                record.get('payload_words', 0)):
            raise ValueError('conditional end record exceeds native profile')
        if images.cond is None:
            raise ValueError('conditional end without an active begin')
        images.cond = None
        if images._remaining() < 1:
            raise MemoryError('conditional operation budget exhausted')
        images.operations.append(CondEnd())
        return
    # vkCmdBeginConditionalRenderingEXT: imm[0]=flags (INVERTED bit only),
    # imm[1:3]=offset u64, handle[0]=buffer resolved canonically
    if any(imm[3:]):
        raise ValueError('conditional begin record exceeds native profile')
    if images.cond is not None:
        raise ValueError('nested conditional rendering exceeds profile')
    _, entry = images.remember(record['handle'][0],
                               golden.KIND['VkBuffer'])
    if device is not None and entry['parent'] != device:
        raise ValueError('conditional buffer crosses command-buffer devices')
    owner, binding, size = images.extent(record, 0)
    flags, offset = imm[0], imm[1] | imm[2] << 32
    if flags & ~1:
        raise ValueError('conditional flags exceed profile')
    if (entry.get('native_usage', 0) & 0x200) == 0:
        raise ValueError('conditional buffer lacks rendering usage')
    # the predicate is one 32-bit word: offset must be 4-aligned and leave
    # at least 32 bits inside the buffer extent (VUID offset bounds)
    if offset % 4 or offset > size - 4:
        raise ValueError('conditional predicate offset exceeds buffer')
    if images._remaining() < 1:
        raise MemoryError('conditional operation budget exhausted')
    images.cond = True
    images.operations.append(CondBegin(owner, binding + offset, flags & 1))
