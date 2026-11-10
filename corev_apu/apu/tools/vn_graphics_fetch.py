#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded vertex/index fetch stage; produces VS-in records, no shader/raster admission."""
from dataclasses import dataclass
import struct

from vn_vertex_operands import BufferOperand

ATTR_STRIDE = 144          # 9 slots x 16B: 8 varying locs + builtin slot 8
MAX_RECORDS = 1024         # vertex*instance records per fetch operation
MAX_ATTRS = 8              # VATTR_OK attribute gather bound (vnfront na<=8)

# VkFormat -> (components, component bytes, class).  VATTR_OK admits only
# UNORM/SNORM/UINT/SINT/SFLOAT component formats (vn_golden.py:1423).
FORMATS = {}
for _fmt, _n, _sz, _cls in (
        (9, 1, 1, 'unorm'), (10, 1, 1, 'snorm'), (13, 1, 1, 'uint'),
        (14, 1, 1, 'sint'),
        (16, 2, 1, 'unorm'), (17, 2, 1, 'snorm'), (20, 2, 1, 'uint'),
        (21, 2, 1, 'sint'),
        (23, 3, 1, 'unorm'), (24, 3, 1, 'snorm'), (27, 3, 1, 'uint'),
        (28, 3, 1, 'sint'),
        (37, 4, 1, 'unorm'), (38, 4, 1, 'snorm'), (41, 4, 1, 'uint'),
        (42, 4, 1, 'sint'),
        (70, 1, 2, 'unorm'), (71, 1, 2, 'snorm'), (74, 1, 2, 'uint'),
        (75, 1, 2, 'sint'), (76, 1, 2, 'f16'),
        (77, 2, 2, 'unorm'), (78, 2, 2, 'snorm'), (81, 2, 2, 'uint'),
        (82, 2, 2, 'sint'), (83, 2, 2, 'f16'),
        (84, 3, 2, 'unorm'), (85, 3, 2, 'snorm'), (88, 3, 2, 'uint'),
        (89, 3, 2, 'sint'), (90, 3, 2, 'f16'),
        (91, 4, 2, 'unorm'), (92, 4, 2, 'snorm'), (95, 4, 2, 'uint'),
        (96, 4, 2, 'sint'), (97, 4, 2, 'f16'),
        (98, 1, 4, 'uint'), (99, 1, 4, 'sint'), (100, 1, 4, 'f32'),
        (101, 2, 4, 'uint'), (102, 2, 4, 'sint'), (103, 2, 4, 'f32'),
        (104, 3, 4, 'uint'), (105, 3, 4, 'sint'), (106, 3, 4, 'f32'),
        (107, 4, 4, 'uint'), (108, 4, 4, 'sint'), (109, 4, 4, 'f32')):
    FORMATS[_fmt] = (_n, _sz, _cls)


def _f32bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def _f16_to_f32(h):
    sign = -1.0 if h & 0x8000 else 1.0
    exp, mant = (h >> 10) & 0x1F, h & 0x3FF
    if exp == 0:
        val = mant / 1024.0 * 2 ** -14
    elif exp == 31:
        val = float('inf') if not mant else float('nan')
    else:
        val = (1 + mant / 1024.0) * 2 ** (exp - 15)
    return sign * val


def _component(raw, cls, size):
    if cls == 'unorm':
        return _f32bits(int.from_bytes(raw, 'little') /
                        float((1 << (size * 8)) - 1))
    if cls == 'snorm':
        v = int.from_bytes(raw, 'little', signed=True)
        peak = (1 << (size * 8 - 1)) - 1
        return _f32bits(max(v / peak, -1.0))
    if cls == 'uint':
        return int.from_bytes(raw, 'little')
    if cls == 'sint':
        return int.from_bytes(raw, 'little', signed=True) & 0xFFFFFFFF
    if cls == 'f16':
        return _f32bits(_f16_to_f32(int.from_bytes(raw, 'little')))
    return int.from_bytes(raw, 'little')          # f32 passthrough


@dataclass(frozen=True)
class FetchVertex:
    location: int
    format: int
    offset: int
    stride: int
    rate: int
    span: BufferOperand


@dataclass(frozen=True)
class Fetch:
    """One draw's fetch stage.  `direct` is the resolved
    (count, instances, first, vertex_offset, first_instance) tuple; `indirect`
    is a BufferOperand whose DrawIndirectCommand/DrawIndexedIndirectCommand is
    read at execution time.  Exactly one of the two must be set."""
    indexed: bool
    indices: object
    vertices: tuple
    direct: object
    indirect: object
    # primitiveRestartEnable: 1 lets an indexed draw break the primitive
    # stream on the index-width sentinel read from the raw index (before
    # vertexOffset).  The runtime records each sentinel's record index in
    # `breaks` so the raster can assemble primitives break-aware; the
    # sentinel slot still emits a (skipped) vertex record.  Non-indexed
    # draws ignore it.
    restart: int = 0

    @property
    def size(self):
        per_vertex = (4 if self.indexed and self.indices else 0)
        per_vertex += sum(FORMATS[v.format][0] * FORMATS[v.format][1]
                          for v in self.vertices if v.rate == 0)
        per_instance = sum(FORMATS[v.format][0] * FORMATS[v.format][1]
                           for v in self.vertices if v.rate == 1)
        count = self.direct[0] * self.direct[1] if self.direct else MAX_RECORDS
        return min(count, MAX_RECORDS) * (per_vertex + per_instance) + \
            (20 if self.indirect else 0)


class FetchRuntime:
    def __init__(self, executor, context, operation):
        if (not isinstance(operation, Fetch) or
                not isinstance(operation.vertices, tuple) or
                len(operation.vertices) > MAX_ATTRS or
                (operation.indexed != (operation.indices is not None)) or
                (operation.direct is None) == (operation.indirect is None)):
            raise ValueError('invalid native vertex fetch operation')
        self.executor, self.context, self.operation = executor, context, operation
        self.owners = {}
        rows = []
        for vertex in operation.vertices:
            if (not isinstance(vertex, FetchVertex) or
                    type(vertex.location) is not int or not 0 <= vertex.location < 8 or
                    vertex.format not in FORMATS or
                    type(vertex.offset) is not int or vertex.offset < 0 or
                    type(vertex.stride) is not int or vertex.stride <= 0 or
                    vertex.rate not in (0, 1) or
                    not isinstance(vertex.span, BufferOperand)):
                raise ValueError('vertex fetch attribute exceeds native profile')
            base = executor._extent(context, vertex.span.owner,
                                    vertex.span.offset, vertex.span.size)
            self.owners[id(vertex.span.owner)] = vertex.span.owner
            rows.append((vertex.location, vertex.format, vertex.offset,
                         vertex.stride, vertex.rate, base, vertex.span.size))
        self.vertices = tuple(rows)
        self.indices = None
        if operation.indices is not None:
            span = operation.indices
            if (not isinstance(span, BufferOperand) or span.index_bytes not in (2, 4)):
                raise ValueError('index fetch operand exceeds native profile')
            base = executor._extent(context, span.owner, span.offset, span.size)
            self.owners[id(span.owner)] = span.owner
            self.indices = (base, span.size, span.index_bytes)
        self.indirect = None
        if operation.indirect is not None:
            span = operation.indirect
            if not isinstance(span, BufferOperand) or span.index_bytes:
                raise ValueError('indirect fetch operand exceeds native profile')
            base = executor._extent(context, span.owner, span.offset, span.size)
            self.owners[id(span.owner)] = span.owner
            self.indirect = (base, span.size)
        self.used = self.records_done = self.robust = self.steps = 0
        self.last_turn = 0
        self.args = operation.direct
        self.records = None
        self.total = self._cursor = 0
        self.done = False
        # primitive-restart bookkeeping: only indexed draws honour the
        # flag; the sentinel is the all-ones value of the index width and
        # is matched on the raw index before vertexOffset is applied.
        self.restart = bool(operation.restart) and operation.indexed
        self.sentinel = (0xFFFF if self.indices and self.indices[2] == 2
                         else 0xFFFFFFFF) if self.indices else 0
        self.breaks = set()
        if self.args is not None:
            self._bind_args(self.args)

    def _bind_args(self, args):
        count, instances, first, vertex_offset, first_instance = args
        if (any(type(v) is not int for v in args) or
                not 0 < count or not 0 < instances or
                not 0 <= first <= (1 << 32) - 1 or
                not -(1 << 31) <= vertex_offset < (1 << 31) or
                not 0 <= first_instance <= (1 << 32) - 1):
            raise ValueError('vertex fetch draw arguments exceed native profile')
        if count * instances > MAX_RECORDS:
            raise MemoryError('vertex fetch record budget exhausted')
        self.args = args
        self.total = count * instances
        self.records = bytearray(self.total * ATTR_STRIDE)
        self._cursor = 0

    def _read(self, address, size):
        if size <= 0:
            return b''
        executor = self.executor
        if not executor._live(self.context):
            raise KeyError('vertex fetch context was retired')
        self.used += size
        data = executor.execution.state.aperture.read(address, size)
        if len(data) != size:
            raise OSError('short vertex fetch read')
        if not executor._live(self.context):
            raise KeyError('vertex fetch context retired during read')
        return data

    def _args_now(self):
        if self.args is not None:
            return self.args
        base, size = self.indirect
        need = 20 if self.operation.indexed else 16
        if size < need:
            raise ValueError('indirect fetch argument extent is too small')
        data = self._read(base, need)
        w = struct.unpack('<%dI' % (need // 4), data)
        if self.operation.indexed:
            self._bind_args((w[0], w[1], w[2], w[3], w[4]))
        else:
            self._bind_args((w[0], w[1], w[2], 0, w[3]))
        return self.args

    def _index(self, i):
        base, size, width = self.indices
        count, _, first, _, _ = self._args_now()
        pos = first + i
        if not 0 <= pos or (pos + 1) * width > size:
            self.robust += 1
            return 0
        return int.from_bytes(self._read(base + pos * width, width), 'little')

    def _attribute(self, row, index):
        _, fmt, off, stride, rate, base, size = row
        n, width, cls = FORMATS[fmt]
        extent = n * width
        shift = index * stride + off
        if index < 0 or shift < 0 or shift + extent > size:
            self.robust += 1
            return [0] * 4
        data = self._read(base + shift, extent)
        return [_component(data[c * width:(c + 1) * width], cls, width)
                for c in range(n)] + [0] * (4 - n)

    def _emit(self, rec):
        count, instances, first, vertex_offset, first_instance = self._args_now()
        instance, i = divmod(rec, count)
        if self.operation.indexed:
            raw = self._index(i)
            if self.restart and raw == self.sentinel:
                # restart sentinel: this record is a break, not a vertex.
                # vertex_index is a harmless in-range value; the raster
                # drops the record via the breaks set regardless.
                self.breaks.add(rec)
                vertex_index = 0
            else:
                vertex_index = raw + vertex_offset
        else:
            vertex_index = first + i
        inst_index = first_instance + instance
        words = bytearray(ATTR_STRIDE)
        for row in self.vertices:
            index = vertex_index if row[4] == 0 else inst_index
            comps = self._attribute(row, index)
            struct.pack_into('<4I', words, row[0] * 16,
                             *(w & 0xFFFFFFFF for w in comps))
        struct.pack_into('<4I', words, 128, vertex_index & 0xFFFFFFFF,
                         inst_index & 0xFFFFFFFF, 0, 0)
        self.records[rec * ATTR_STRIDE:(rec + 1) * ATTR_STRIDE] = words
        self.records_done += 1

    def advance(self, budget):
        start = self.used
        self.last_turn = 0
        if self.done or budget <= 0:
            return 0
        try:
            self._args_now()
            while (not self.done and self._cursor < self.total and
                   self.used - start < budget):
                self.steps += 1
                self._emit(self._cursor)
                self._cursor += 1
                if self._cursor >= self.total:
                    self.done = True
        except (IndexError, struct.error, OverflowError,
                ZeroDivisionError) as error:
            raise ValueError('vertex fetch failed: ' + str(error)) from error
        finally:
            self.last_turn = self.used - start
        return self.last_turn
