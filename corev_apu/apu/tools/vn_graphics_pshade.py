#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded fragment-shader stage over FS-in records; no raster/ROP/descriptor admission."""
import math
import struct
from dataclasses import dataclass, replace

from shader.spirv_model import Model
from shader.spirv_scan import EM, Scanner
from vn_graphics_fetch import ATTR_STRIDE, MAX_RECORDS
from vn_graphics_shade import (BATCH_MAX, GfxMemory, STEP_QUANTUM, MAX_STEPS,
                              resolve_bindings)

RECORD_STRIDE = ATTR_STRIDE       # FS-in/out records share the 144-byte stride
MAX_INPUT = MAX_RECORDS * RECORD_STRIDE


def _quad_order(records):
    """Reorder fragment FS-in records into 2x2 quad lane order so the
    OpDPdx/OpDPdy/OpFwidth{,Fine,Coarse} quad-lane derivatives resolve
    against true screen neighbours.  The model groups lanes {4k..4k+3}
    of each 8-lane wave as one quad (lane0=TL,1=TR,2=BL,3=BR anchored at
    the even pixel pair), so every consecutive group of four records must
    be one complete screen quad.  Uncovered quad pixels are filled with
    helper records carrying an off-screen FragCoord — the writeback
    bounds gate drops them — and a covered neighbour's varyings.  Returns
    the reordered record bytes, or None when the coverage cannot form
    clean quads (non-finite or duplicated FragCoord) so the caller keeps
    scanline order."""
    n = len(records) // RECORD_STRIDE
    if n == 0:
        return None
    pix_of = {}
    order = []
    for i in range(n):
        fx, fy = struct.unpack_from('<2f', records, i * RECORD_STRIDE)
        if not (math.isfinite(fx) and math.isfinite(fy)):
            return None
        px, py = int(fx), int(fy)
        if px < 0 or py < 0 or (px, py) in pix_of:
            return None
        pix_of[(px, py)] = i
        order.append((px, py))
    # lane = (py&1)*2 + (px&1): quad pixels TL,TR,BL,BR -> 0,1,2,3
    quads = {}
    for i, (px, py) in enumerate(order):
        lane = (py & 1) * 2 + (px & 1)
        quads.setdefault((px & ~1, py & ~1), {})[lane] = i
    out = bytearray()
    for (qx, qy) in sorted(quads, key=lambda k: (k[1], k[0])):
        lanes = quads[(qx, qy)]
        ref = lanes[min(lanes)]
        refrec = records[ref * RECORD_STRIDE:(ref + 1) * RECORD_STRIDE]
        for lane in range(4):
            ri = lanes.get(lane)
            if ri is not None:
                out += records[ri * RECORD_STRIDE:(ri + 1) * RECORD_STRIDE]
            else:
                h = bytearray(refrec)
                struct.pack_into('<4f', h, 0, -1.0e6, -1.0e6, 0.0, 1.0)
                out += h
    return bytes(out)


@dataclass(frozen=True)
class FragmentShade:
    """One fragment-shader stage over a caller-supplied FS-in record image.

    `records` is an immutable byte string of `count` 144-byte records
    (FragCoord slot 0, Location'd varyings at 16*(1+loc)).  `helpers` is a
    per-record helper-invocation bitmask (bit i -> record i; only the low
    64 bits of each batch window are visible to the model, matching the
    two-word work-record field).  `front` carries the primitive
    front-facing bit into the work record's vbase field (bit 0)."""
    records: bytes
    code: tuple
    push: tuple = ()
    batch: int = BATCH_MAX
    helpers: int = 0
    front: int = 0
    bindings: tuple = ()

    @property
    def size(self):
        return len(self.records) + len(self.code) * 4 + len(self.push) * 4 + \
            MAX_INPUT


class FragmentShadeRuntime:
    def __init__(self, executor, context, operation):
        if (not isinstance(operation, FragmentShade) or
                type(operation.records) is not bytes or
                not operation.records or
                len(operation.records) % RECORD_STRIDE or
                len(operation.records) > MAX_INPUT or
                not isinstance(operation.code, tuple) or
                not 5 <= len(operation.code) <= 4096 or
                operation.code[0] != 0x07230203 or
                not isinstance(operation.push, tuple) or len(operation.push) > 32 or
                any(type(w) is not int or not 0 <= w < 1 << 32
                    for w in operation.push) or
                type(operation.batch) is not int or
                not 0 < operation.batch <= BATCH_MAX or
                type(operation.helpers) is not int or
                not 0 <= operation.helpers < 1 << 64 or
                operation.front not in (0, 1) or
                not isinstance(operation.bindings, tuple) or
                len(operation.bindings) > 16):
            raise ValueError('fragment shade operation exceeds native profile')
        try:
            scan = Scanner(list(operation.code)).scan()
        except Exception as error:
            raise ValueError('fragment shader scan failed: ' + str(error)) from error
        if scan.em != EM['FRAGMENT']:
            raise ValueError('fragment shade requires a fragment execution model')
        if scan.has_deriv:
            # quad-lane derivatives need 2x2 screen-quad record order;
            # reorder (synthesizing off-screen helper lanes for uncovered
            # quad pixels) when the coverage forms clean quads.
            q = _quad_order(operation.records)
            if q is not None and len(q) <= MAX_INPUT:
                operation = replace(operation, records=q)
        bind_rows, bind_pad, bound_owners = resolve_bindings(
            executor, context, operation.bindings, scan, 'fragment')
        self.executor, self.context, self.operation = executor, context, operation
        # FS-in records are immutable caller bytes: only descriptor owners lease.
        self.owners = dict(bound_owners)
        self.bind_rows, self.bind_pad = bind_rows, bind_pad
        self.total = len(operation.records) // RECORD_STRIDE
        self.color = bytearray()
        self.model = self.ivs = None
        self.batch_start = self.cursor = self.steps = self.batches = 0
        self.robust = 0
        self.max_steps = MAX_STEPS
        self.done = False
        self.last_turn = 0

    def _next_batch(self):
        total = self.total
        start = self.batch_start
        count = min(self.operation.batch, total - start)
        if count <= 0:
            self.done = True
            return
        recs = self.operation.records[start * RECORD_STRIDE:
                                      (start + count) * RECORD_STRIDE]
        words_in = [int.from_bytes(recs[i:i + 4], 'little')
                    for i in range(0, len(recs), 4)]
        nin = len(words_in)
        out_base = nin * 4                     # byte address after inputs
        ghelp = (self.operation.helpers >> start) & 0xFFFFFFFFFFFFFFFF
        # {stage,count,in_base,out_base,vbase,inst,nin}: stage=Fragment EM;
        # vbase bit0 carries front-facing; helper mask follows the inputs.
        # Binding rows sit between SPIR-V and push; per-binding init-word
        # placeholders keep the graphics section aligned under live memory.
        flat = [word for row in self.bind_rows for word in row]
        words = [len(self.operation.code), len(self.bind_rows),
                 len(self.operation.push),
                 1, 1, 1, 4, 0,                 # flags bit2 = graphics wave work
                 *self.operation.code, *flat, *self.operation.push, 0,
                 *([0] * self.bind_pad),
                 4,                            # stage word = SPIR-V Fragment EM
                 count, 0, out_base, self.operation.front, 0, nin,
                 *words_in, ghelp & 0xFFFFFFFF, ghelp >> 32]
        memory = GfxMemory(self.executor, self.context, self.operation.bindings)
        try:
            self.model = Model(words, memory=memory)
        except Exception as error:
            raise ValueError('fragment shader model failed: ' + str(error)) from error
        if self.model.gfx != 2 or self.model.gcnt != count:
            raise ValueError('fragment shader wave layout exceeds native profile')
        m = self.model
        m.wg, m.slab, m.l0_idx = (0, 0, 0), [0] * m.slb_w, {}
        m.ivs = [m.inv_init() for _ in range(count)]
        self.batch_start += count
        self.batches += 1
        self.cursor = 0

    def advance(self, budget):
        self.last_turn = 0
        quantum = self.steps
        try:
            if self.done:
                return 0
            while not self.done:
                if self.model is None:
                    self._next_batch()
                    if self.done:
                        break
                if self.steps >= self.max_steps:
                    raise ValueError('fragment shader instruction budget exhausted')
                m = self.model
                live = [i for i in range(m.gcnt) if not m.ivs[i]['done']]
                if not live:
                    stride = RECORD_STRIDE // 4
                    self.color += b''.join(
                        m.mem.get(m.out_base // 4 + w, 0).to_bytes(4, 'little')
                        for w in range(m.gcnt * stride))
                    self.robust += m.robust
                    self.model = None
                    continue
                waiters = [i for i in live if m.ivs[i]['bwait']]
                if len(waiters) == len(live):
                    for i in waiters:
                        m.ivs[i]['bwait'] = False
                    m.nswitch += 1
                    self.steps += 1
                    continue
                ready = [i for i in live if not m.ivs[i]['bwait']]
                index = next((i for i in ready if i >= self.cursor), ready[0])
                self.cursor = (index + 1) % m.gcnt
                m.run_inv(index, single=True)
                self.steps += 1
                if m.fault is not None:
                    raise ValueError('fragment shader fault: ' + str(m.fault))
                if self.steps - quantum >= STEP_QUANTUM:
                    break
            return 0
        except (IndexError, AssertionError, RecursionError, ZeroDivisionError,
                OverflowError) as error:
            raise ValueError('fragment shade failed: ' + str(error)) from error

    @property
    def memory(self):
        class _Used:
            pass
        view = _Used()
        view.used = self.last_turn
        return view
