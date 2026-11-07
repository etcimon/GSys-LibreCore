#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Full native draw chain: fetch -> vertex shade -> raster -> fragment shade
-> writeback inside one executor operation; no descriptors/blend/depth."""
import struct
from dataclasses import dataclass

from shader.spirv_scan import EM, Scanner
from vn_graphics_fetch import Fetch, ATTR_STRIDE
from vn_graphics_pshade import BATCH_MAX, FragmentShade, FragmentShadeRuntime
from vn_graphics_raster import (MAX_FRAGMENTS, Raster, RasterRuntime,
                                 RECORD_STRIDE)
from vn_graphics_shade import Shade, ShadeRuntime
from vn_graphics_writeback import Writeback, WritebackRuntime


def _fragment_scan(code):
    if (not isinstance(code, tuple) or not 5 <= len(code) <= 4096 or
            code[0] != 0x07230203):
        raise ValueError('draw fragment stage exceeds native profile')
    try:
        scan = Scanner(list(code)).scan()
    except Exception as error:
        raise ValueError('draw fragment scan failed: ' + str(error)) from error
    if scan.em != EM['FRAGMENT']:
        raise ValueError('draw execution requires a fragment execution model')
    for row in scan.decor.values():
        if row.get('binding') is not None or row.get('set') is not None:
            raise ValueError('draw descriptor bindings are not admitted')
    return scan


@dataclass(frozen=True)
class DrawExec:
    """One bounded draw: `fetch` supplies vertex records, `vs`/`fs` are the
    stage code tuples, `push` words are shared per stage is not supported --
    `vs_push`/`fs_push` are separate.  Raster fields mirror `Raster`;
    writeback fields mirror `Writeback`."""
    fetch: Fetch
    vs: tuple
    fs: tuple
    viewport: tuple
    scissor: tuple
    owner: object
    offset: int
    pitch: int
    width: int
    height: int
    fmt: int
    vs_push: tuple = ()
    fs_push: tuple = ()
    batch: int = BATCH_MAX
    flat: int = 0
    nopersp: int = 0
    front_ccw: int = 1
    cull: int = 0
    location: int = 0

    @property
    def size(self):
        fragments = min(MAX_FRAGMENTS, self.scissor[2] * self.scissor[3])
        return (self.fetch.size + len(self.vs) * 4 + len(self.fs) * 4 +
                len(self.vs_push) * 4 + len(self.fs_push) * 4 +
                fragments * RECORD_STRIDE * 2 +
                self.height * self.pitch)


class DrawExecRuntime:
    def __init__(self, executor, context, operation):
        if not isinstance(operation, DrawExec):
            raise ValueError('draw execution exceeds native profile')
        op = operation
        # eager admission probes: each stage validates its own profile
        # before any work is published (vary/record bytes are placeholders)
        self.shade = ShadeRuntime(executor, context,
                                  Shade(op.fetch, op.vs, op.vs_push,
                                        op.batch))
        scan = _fragment_scan(op.fs)
        RasterRuntime(executor, context, Raster(
            b'\0' * (3 * RECORD_STRIDE), op.viewport, op.scissor, 3,
            op.flat, op.nopersp, op.front_ccw, op.cull))
        WritebackRuntime(executor, context, Writeback(
            b'\0' * ATTR_STRIDE, b'\0' * ATTR_STRIDE, 1, op.owner,
            op.offset, op.pitch, op.width, op.height, op.fmt,
            op.location))
        self.executor, self.context, self.operation = executor, context, op
        self.uses_front = any(
            v.get('storage') == 1 and v.get('builtin') == 17
            for v in scan.vars.values())
        self.raster = self.fs = self.wb = None
        self._gate = False
        # shade owners (fetch buffers) plus the writeback destination must
        # be pinned at enqueue time, before the first advance
        self.owners = dict(self.shade.owners)
        self.owners[id(op.owner)] = op.owner
        self.done = False
        self.last_turn = 0

    def _chain(self):
        """Advance the stage pipeline; construct the next runtime when the
        previous stage completes.  Returns True while work remains."""
        op = self.operation
        if not self.shade.done:
            return True
        if self.raster is None:
            count = self.shade.fetch.records_done
            self.raster = RasterRuntime(self.executor, self.context,
                                        Raster(bytes(self.shade.vary),
                                               op.viewport, op.scissor,
                                               count, op.flat, op.nopersp,
                                               op.front_ccw, op.cull))
            return True
        if not self.raster.done:
            return True
        if not self.raster.records:
            # culled/degenerate draw: no fragments, nothing left to run
            self.done = True
            return False
        if self.fs is None:
            if self.uses_front and len(set(self.raster.fronts)) > 1:
                raise ValueError(
                    'mixed front-facing exceeds native profile')
            front = self.raster.fronts[0] if self.raster.fronts else 0
            count = len(self.raster.records) // RECORD_STRIDE
            self.fs = FragmentShadeRuntime(self.executor, self.context,
                                           FragmentShade(
                                               bytes(self.raster.records),
                                               op.fs, op.fs_push,
                                               op.batch, 0, front))
            return True
        if not self.fs.done:
            return True
        if self.wb is None:
            self.wb = WritebackRuntime(self.executor, self.context,
                                       Writeback(
                                           bytes(self.raster.records),
                                           bytes(self.fs.color),
                                           len(self.raster.records) //
                                           RECORD_STRIDE,
                                           op.owner, op.offset, op.pitch,
                                           op.width, op.height, op.fmt,
                                           op.location))
            return True
        return not self.wb.done

    def advance(self, budget):
        self.last_turn = 0
        try:
            if self.done:
                return 0
            if not self._gate:
                # conditional rendering: the predicate word is re-read
                # once per draw command (the spec's per-command model);
                # a zero word discards the whole draw at its stream
                # position with no stage work published
                self._gate = True
                gate = self.executor.cond.get(id(self.context))
                if gate is not None:
                    addr, inverted = gate
                    word = int.from_bytes(
                        self.executor.execution.state.aperture.read(
                            addr, 4), 'little')
                    if not ((word != 0) ^ bool(inverted)):
                        self.done = True
                        return 0
            while self._chain():
                stage = next((s for s in (self.shade, self.raster,
                                          self.fs, self.wb)
                              if s is not None and not s.done), None)
                if stage is None:
                    break
                used = stage.advance(budget)
                self.last_turn = used
                if not stage.done:
                    return used
            self.done = True
            return self.last_turn
        except (IndexError, AssertionError, RecursionError,
                ZeroDivisionError, OverflowError, struct.error) as error:
            raise ValueError('draw execution failed: ' + str(error)) from error

    @property
    def memory(self):
        class _Used:
            pass
        view = _Used()
        view.used = self.last_turn
        return view
