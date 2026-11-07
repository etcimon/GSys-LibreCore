#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded query-pool ops: ordered timestamp/occlusion/statistics state."""

MAX_QUERIES = 4096
# pipeline-statistics bits the bounded draw stages count truthfully:
# input-assembly vertices/primitives, vertex/fragment shader invocations
STAT_BITS = (0, 1, 2, 7)


def _stat_bits(mask):
    """Enabled statistic counters in spec order (ascending bit position)."""
    return tuple(bit for bit in range(11) if mask >> bit & 1)


def _stat_count(entry):
    return len(_stat_bits((entry['aux'] & 0xFFFFFFFF) >> 8))


class QueryReset:
    """Mark a pool slot range unavailable at its stream position."""
    __slots__ = ('spans', 'size')

    def __init__(self, spans):
        if (not isinstance(spans, tuple) or len(spans) != 1 or
                any(not isinstance(span, tuple) or len(span) != 3 or
                    not isinstance(span[0], dict) or
                    type(span[1]) is not int or type(span[2]) is not int
                    for span in spans)):
            raise ValueError('invalid native query reset operation')
        self.spans = spans
        self.size = 0


class QueryStamp:
    """Publish an available timestamp slot (honest value 0)."""
    __slots__ = ('slots', 'size')

    def __init__(self, slots):
        if (not isinstance(slots, tuple) or len(slots) != 1 or
                any(not isinstance(slot, tuple) or len(slot) != 2 or
                    not isinstance(slot[0], dict) or
                    type(slot[1]) is not int for slot in slots)):
            raise ValueError('invalid native query stamp operation')
        self.slots = slots
        self.size = 0


class QueryBegin:
    """Open an occlusion/statistics accumulation at its stream position."""
    __slots__ = ('entry', 'index', 'size')

    def __init__(self, entry, index):
        if (not isinstance(entry, dict) or type(index) is not int or
                not 0 <= index < len(entry.get('qslots') or ())):
            raise ValueError('invalid native query begin operation')
        self.entry, self.index = entry, index
        self.size = 0


class QueryEnd:
    """Publish the accumulated query result at its stream position."""
    __slots__ = ('entry', 'index', 'size')

    def __init__(self, entry, index):
        if (not isinstance(entry, dict) or type(index) is not int or
                not 0 <= index < len(entry.get('qslots') or ())):
            raise ValueError('invalid native query end operation')
        self.entry, self.index = entry, index
        self.size = 0


class QueryCopy:
    """Write ordered query results into a pinned buffer extent."""
    __slots__ = ('entry', 'first', 'count', 'flags', 'owner', 'offset',
                 'stride', 'counters', 'size')

    def __init__(self, entry, first, count, flags, owner, offset, stride,
                 counters=1):
        record = (counters * (8 if flags & 0x1 else 4) +
                  (4 if flags & 0x8 else 0)
                  if type(flags) is int else 0)
        if (not isinstance(entry, dict) or type(first) is not int or
                type(count) is not int or type(flags) is not int or
                type(offset) is not int or type(stride) is not int or
                type(counters) is not int or counters < 0 or
                not 0 < count <= MAX_QUERIES or
                first + count > len(entry.get('qslots') or ()) or
                flags & ~0x9 or stride < record or stride % 4 or
                offset % 4):
            raise ValueError('invalid native query copy operation')
        self.entry, self.first, self.count = entry, first, count
        self.flags, self.owner, self.offset, self.stride = \
            flags, owner, offset, stride
        self.counters = counters
        self.size = count * stride


class _QueryRuntime:
    def __init__(self, executor, context, operation):
        self.executor, self.context, self.operation = executor, context, operation
        self.owners = {}
        self.last_turn = 0
        self.done = False


class QueryResetRuntime(_QueryRuntime):
    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        (entry, first, count), = self.operation.spans
        slots = entry['qslots']
        for index in range(first, first + count):
            slots[index] = None
        self.done = True
        return 0


class QueryStampRuntime(_QueryRuntime):
    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        (entry, index), = self.operation.slots
        # timestampPeriod is 0 in the bounded profile: 0 is the honest
        # timestamp value, not a fabricated clock reading
        entry['qslots'][index] = 0
        self.done = True
        return 0


class QueryBeginRuntime(_QueryRuntime):
    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        op = self.operation
        if (op.entry['aux'] & 0xFF) == 1:
            # statistics: per-counter accumulators in spec bit order
            bits = _stat_bits((op.entry['aux'] & 0xFFFFFFFF) >> 8)
            acc = (bits, [0] * len(bits))
            self.executor.statistics.setdefault(
                id(self.context), {})[(id(op.entry), op.index)] = acc
        else:
            open_queries = self.executor.occlusion.setdefault(
                id(self.context), {})
            open_queries[(id(op.entry), op.index)] = 0
        self.done = True
        return 0


class QueryEndRuntime(_QueryRuntime):
    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        op = self.operation
        if (op.entry['aux'] & 0xFF) == 1:
            open_queries = self.executor.statistics.get(id(self.context))
            key = (id(op.entry), op.index)
            if not open_queries or key not in open_queries:
                raise ValueError('query end without an active begin')
            _, acc = open_queries.pop(key)
            op.entry['qslots'][op.index] = acc
            if not open_queries:
                self.executor.statistics.pop(id(self.context), None)
        else:
            open_queries = self.executor.occlusion.get(id(self.context))
            key = (id(op.entry), op.index)
            if not open_queries or key not in open_queries:
                raise ValueError('query end without an active begin')
            op.entry['qslots'][op.index] = open_queries.pop(key)
            if not open_queries:
                self.executor.occlusion.pop(id(self.context), None)
        self.done = True
        return 0


class QueryCopyRuntime(_QueryRuntime):
    def __init__(self, executor, context, operation):
        super().__init__(executor, context, operation)
        op = operation
        record = (op.counters * (8 if op.flags & 0x1 else 4) +
                  (4 if op.flags & 0x8 else 0))
        self.record, self.pad = record, op.stride - record
        total = (op.count - 1) * op.stride + record
        # enqueue-time extent validation mirrors Transfer._extent so a
        # stale/unbacked/oversized destination faults before any pin
        self.base = executor._extent(context, op.owner, op.offset, total)
        self.owners = {id(op.owner): op.owner}

    def advance(self, budget):
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        op = self.operation
        out = bytearray()
        for index in range(op.first, op.first + op.count):
            slot = op.entry['qslots'][index]
            stamped = slot is not None
            if op.counters > 1 or isinstance(slot, list):
                # statistics pool: each query result is an array of
                # per-counter values in spec bit order
                counters = slot if stamped else [0] * op.counters
                for counter in counters:
                    if op.flags & 0x1:
                        out += counter.to_bytes(8, 'little')
                    else:
                        out += (counter & 0xFFFFFFFF).to_bytes(4, 'little')
            else:
                value = slot if stamped else 0
                if op.flags & 0x1:
                    out += value.to_bytes(8, 'little')
                else:
                    out += (value & 0xFFFFFFFF).to_bytes(4, 'little')
            if op.flags & 0x8:
                out += (1 if stamped else 0).to_bytes(4, 'little')
            out += b'\0' * self.pad
        if not self.executor._live(self.context):
            return 0
        self.executor.execution.state.aperture.write(
            self.base, bytes(out))
        self.last_turn = len(out)
        self.done = True
        return self.last_turn


def _pool(images, record, device, dst=False, types=(2,)):
    golden = images.engine.golden
    tail = record['handle'][2:] if dst else record['handle'][1:]
    empty = [0, 0] if dst else [0, 0, 0]
    if tail != empty or record.get('payload_words', 0):
        raise ValueError('query record exceeds native profile')
    if dst and not record['handle'][1]:
        raise ValueError('query copy requires a destination buffer')
    handle, entry = images.remember(record['handle'][0],
                                    golden.KIND['VkQueryPool'])
    if device is not None and entry['parent'] != device:
        raise ValueError('query operation crosses command-buffer devices')
    pool_type = entry['aux'] & 0xFF
    if (pool_type not in types or type(entry['size']) is not int or
            not 0 <= entry['size'] <= MAX_QUERIES or
            not isinstance(entry.get('qslots'), list) or
            len(entry['qslots']) != entry['size']):
        raise ValueError('query pool is outside the admitted profile')
    return handle, entry


def replay(images, record, name, *, compute=False, device=None):
    """Validate and emit ordered query ops for the admitted Cmd* records."""
    from vn_image_barriers import scope
    imm = record['imm']
    if name == 'vkCmdWriteTimestamp2':
        # stage is a u64 scalar captured into imm[1:3]; query stays imm[0]
        if any(imm[3:]) or imm[2]:
            raise ValueError('query record exceeds native profile')
        _, entry = _pool(images, record, device)
        scope(imm[1], 0, compute=compute)
        query = imm[0]
        if query >= entry['size']:
            raise ValueError('query timestamp index exceeds pool')
        if images._remaining() < 1:
            raise MemoryError('query operation budget exhausted')
        images.operations.append(QueryStamp(((entry, query),)))
        return
    elif name == 'vkCmdCopyQueryPoolResults':
        if any(imm[7:]) or imm[2] & ~0x9:
            raise ValueError('query record exceeds native profile')
        _, entry = _pool(images, record, device, dst=True, types=(0, 1, 2))
        first, count, flags = imm[0], imm[1], imm[2]
        dst_offset = imm[3] | imm[4] << 32
        stride = imm[5] | imm[6] << 32
        if not count:
            return
        owner, binding, capacity = images.extent(record, 1)
        counters = (_stat_count(entry)
                    if (entry['aux'] & 0xFF) == 1 else 1)
        record_size = (counters * (8 if flags & 0x1 else 4) +
                       (4 if flags & 0x8 else 0))
        if (first + count > entry['size'] or stride < record_size or
                stride % 4 or dst_offset % 4 or
                dst_offset > capacity or
                (count - 1) * stride + record_size > capacity - dst_offset):
            raise ValueError('query copy range/stride exceeds buffer')
        if images._remaining() < 1:
            raise MemoryError('query operation budget exhausted')
        images.operations.append(QueryCopy(
            entry, first, count, flags, owner, binding + dst_offset,
            stride, counters))
        return
    else:
        if any(imm[2:]):
            raise ValueError('query record exceeds native profile')
        _, entry = _pool(images, record, device, types=(0, 1, 2))
    size = entry['size']
    pool_type = entry['aux'] & 0xFF
    if name == 'vkCmdResetQueryPool':
        first, count = imm[0], imm[1]
        if first + count > size:
            raise ValueError('query reset range exceeds pool')
        if count and images._remaining() < 1:
            raise MemoryError('query operation budget exhausted')
        if count:
            images.operations.append(QueryReset(((entry, first, count),)))
        return
    if name in ('vkCmdBeginQuery', 'vkCmdBeginQueryIndexedEXT'):
        query, flags = imm[0], imm[1]
        if query >= size:
            raise ValueError('query begin index exceeds pool')
        if pool_type in (0, 1):
            # occlusion/statistics: PRECISE is the only defined flag
            # bit and both bounded counts are exact, so it is always
            # satisfiable; indexed variants admit index==0 only
            # (imm[2] already forced to zero by the spare check above)
            if flags & ~1:
                raise ValueError('query begin flags exceed profile')
            key = (id(entry), query)
            if key in images.qopen:
                raise ValueError('query begin while already active')
            images.qopen.add(key)
            if images._remaining() < 1:
                raise MemoryError('query operation budget exhausted')
            images.operations.append(QueryBegin(entry, query))
            return
        if flags:
            raise ValueError('query begin flags exceed profile')
    elif name in ('vkCmdEndQuery', 'vkCmdEndQueryIndexedEXT'):
        query = imm[0]
        if imm[1] or query >= size:
            raise ValueError('query end record exceeds profile')
        if pool_type in (0, 1):
            key = (id(entry), query)
            if key not in images.qopen:
                raise ValueError('query end without an active begin')
            images.qopen.discard(key)
            if images._remaining() < 1:
                raise MemoryError('query operation budget exhausted')
            images.operations.append(QueryEnd(entry, query))
            return
    else:  # vkCmdWriteTimestamp
        if pool_type != 2:
            raise ValueError('timestamp write requires a timestamp pool')
        scope(imm[0], 0, compute=compute)
        query = imm[1]
        if query >= size:
            raise ValueError('query timestamp index exceeds pool')
    if images._remaining() < 1:
        raise MemoryError('query operation budget exhausted')
    images.operations.append(QueryStamp(((entry, query),)))
