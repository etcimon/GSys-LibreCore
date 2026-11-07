#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded fragment writeback to a single color attachment; no blend/depth."""
import struct
from dataclasses import dataclass

import vn_golden
from vn_graphics_fetch import ATTR_STRIDE
from vn_graphics_raster import MAX_FRAGMENTS

WRITE_QUANTUM = 4096            # fragment writes per cooperative turn


@dataclass(frozen=True)
class Writeback:
    """ROP stage: FS-in FragCoord records + FS-out color records -> one
    color attachment.  `inputs`/`colors` are immutable 144-byte record
    images of equal `count`; `owner`/`offset`/`pitch`/`width`/`height`
    describe the destination span and `fmt` the device format id.
    `location` selects the FS-out color slot (0..7)."""
    inputs: bytes
    colors: bytes
    count: int
    owner: object
    offset: int
    pitch: int
    width: int
    height: int
    fmt: int
    location: int = 0

    @property
    def size(self):
        return len(self.inputs) + len(self.colors) + self.height * self.pitch


class WritebackRuntime:
    def __init__(self, executor, context, operation):
        if (not isinstance(operation, Writeback) or
                type(operation.inputs) is not bytes or
                type(operation.colors) is not bytes or
                not operation.inputs or
                len(operation.inputs) != len(operation.colors) or
                len(operation.inputs) % ATTR_STRIDE or
                type(operation.count) is not int or
                not 0 < operation.count <= MAX_FRAGMENTS or
                operation.count * ATTR_STRIDE != len(operation.inputs) or
                type(operation.offset) is not int or operation.offset < 0 or
                type(operation.pitch) is not int or
                not 0 < operation.pitch <= 1 << 22 or
                type(operation.width) is not int or
                not 0 < operation.width <= 4096 or
                type(operation.height) is not int or
                not 0 < operation.height <= 4096 or
                type(operation.fmt) is not int or
                not 0 <= operation.fmt < 16 or
                type(operation.location) is not int or
                not 0 <= operation.location < 8):
            raise ValueError('writeback operation exceeds native profile')
        self.executor, self.context, self.operation = executor, context, operation
        model = executor.execution.model
        _names, _v2d, bpp, _attr = model.img_fmt_tables()
        if not bpp[operation.fmt]:
            raise ValueError('writeback format has no bytes-per-pixel')
        self.bpp = bpp[operation.fmt]
        span = ((operation.height - 1) * operation.pitch +
                operation.width * self.bpp)
        self.base = executor._extent(context, operation.owner,
                                     operation.offset, span)
        self.owners = {id(operation.owner): operation.owner}
        self.cursor = self.written = self.dropped = self.steps = 0
        self.done = False
        self.last_turn = 0
        self.golden = executor.execution.golden

    def advance(self, budget):
        self.last_turn = 0
        written = 0
        try:
            if self.done:
                return 0
            op = self.operation
            memory = self.executor.execution.state.aperture
            loc_off = op.location * 16
            quantum = self.cursor + WRITE_QUANTUM
            end = min(quantum, op.count)
            while self.cursor < end:
                if not self.executor._live(self.context):
                    raise KeyError('writeback context retired during work')
                i = self.cursor * ATTR_STRIDE
                fx, fy = struct.unpack_from('<2f', op.inputs, i)
                px, py = int(fx), int(fy)
                self.cursor += 1
                self.steps += 1
                if (fx < 0.0 or fy < 0.0 or
                        not (0 <= px < op.width and 0 <= py < op.height)):
                    self.dropped += 1
                    continue
                words = struct.unpack_from('<4I', op.colors,
                                           i + loc_off)
                texel = vn_golden.img_clear_texel(
                    self.executor.execution.model, op.fmt, words)
                memory.write(self.base + py * op.pitch + px * self.bpp,
                             texel)
                self.written += 1
                written += 1
            if self.cursor >= op.count:
                self.done = True
            self.last_turn = written
            return written
        except (IndexError, struct.error, OverflowError,
                ZeroDivisionError, OSError) as error:
            raise ValueError('writeback failed: ' + str(error)) from error

    @property
    def memory(self):
        class _Used:
            pass
        view = _Used()
        view.used = self.last_turn
        return view
