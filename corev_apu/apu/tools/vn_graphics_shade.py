#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded vertex-shader stage over fetch records; no raster/FS/descriptor admission."""
from dataclasses import dataclass

from shader.spirv_model import Model
from shader.spirv_scan import EM, Scanner
from vn_graphics_fetch import ATTR_STRIDE, Fetch, FetchRuntime, MAX_RECORDS

VARY_STRIDE = 144           # VS-out records share the 9-slot stride
BATCH_MAX = 256             # invocations per Model wave batch
STEP_QUANTUM = 512          # instructions per cooperative advance
MAX_STEPS = 1 << 20


@dataclass(frozen=True)
class Shade:
    """One draw's vertex-shader stage.  `fetch` is executed first inside the
    same runtime so records observe earlier queued writes exactly once."""
    fetch: Fetch
    code: tuple
    push: tuple = ()
    batch: int = BATCH_MAX

    @property
    def size(self):
        return self.fetch.size + len(self.code) * 4 + len(self.push) * 4 + \
            MAX_RECORDS * VARY_STRIDE


class ShadeRuntime:
    def __init__(self, executor, context, operation):
        if (not isinstance(operation, Shade) or
                not isinstance(operation.code, tuple) or
                not 5 <= len(operation.code) <= 4096 or
                operation.code[0] != 0x07230203 or
                not isinstance(operation.push, tuple) or len(operation.push) > 32 or
                any(type(w) is not int or not 0 <= w < 1 << 32
                    for w in operation.push) or
                type(operation.batch) is not int or
                not 0 < operation.batch <= BATCH_MAX):
            raise ValueError('vertex shade operation exceeds native profile')
        try:
            scan = Scanner(list(operation.code)).scan()
        except Exception as error:
            raise ValueError('vertex shader scan failed: ' + str(error)) from error
        if scan.em != EM['VERTEX']:
            raise ValueError('vertex shade requires a vertex execution model')
        for row in scan.decor.values():
            if row.get('binding') is not None or row.get('set') is not None:
                raise ValueError('vertex shade descriptor bindings are not admitted')
        self.executor, self.context, self.operation = executor, context, operation
        self.fetch = FetchRuntime(executor, context, operation.fetch)
        self.owners = dict(self.fetch.owners)
        self.vary = bytearray()
        self.model = self.ivs = None
        self.batch_start = self.cursor = self.steps = self.batches = 0
        self.robust = 0
        self.max_steps = MAX_STEPS
        self.done = False
        self.last_turn = 0

    def _next_batch(self):
        total = self.fetch.total
        start = self.batch_start
        count = min(self.operation.batch, total - start)
        if count <= 0:
            self.done = True
            return
        recs = bytes(self.fetch.records[start * ATTR_STRIDE:
                                    (start + count) * ATTR_STRIDE])
        words_in = [int.from_bytes(recs[i:i + 4], 'little')
                    for i in range(0, len(recs), 4)]
        nin = len(words_in)
        out_base = nin * 4                     # byte address after inputs
        # {stage,count,in_base,out_base,vbase,inst,nin}: in_base=0 puts the
        # input image at mem word 0; out_base is a byte address so VS-out
        # records land immediately after it.  vbase/inst stay 0; the VS
        # builtin path reads per-record slot 8, which fetch already wrote.
        words = [len(self.operation.code), 0, len(self.operation.push),
                 1, 1, 1, 4, 0,                 # flags bit2 = graphics wave work
                 *self.operation.code, *self.operation.push, 0,
                 0,                            # stage word = SPIR-V Vertex EM
                 count, 0, out_base, 0, 0, nin,
                 *words_in, 0, 0]
        try:
            self.model = Model(words)
        except Exception as error:
            raise ValueError('vertex shader model failed: ' + str(error)) from error
        if self.model.gfx != 1 or self.model.gcnt != count:
            raise ValueError('vertex shader wave layout exceeds native profile')
        m = self.model
        m.wg, m.slab, m.l0_idx = (0, 0, 0), [0] * m.slb_w, {}
        m.ivs = [m.inv_init() for _ in range(count)]
        self.batch_start += count
        self.batches += 1
        self.cursor = 0

    def advance(self, budget):
        self.last_turn = 0
        used = 0
        quantum = self.steps
        try:
            if self.done:
                return 0
            if not self.fetch.done:
                used = self.fetch.advance(budget)
                if not self.fetch.done:
                    self.last_turn = used
                    return used
            while not self.done:
                if self.model is None:
                    self._next_batch()
                    if self.done:
                        break
                if self.steps >= self.max_steps:
                    raise ValueError('vertex shader instruction budget exhausted')
                m = self.model
                live = [i for i in range(m.gcnt) if not m.ivs[i]['done']]
                if not live:
                    stride = VARY_STRIDE // 4
                    self.vary += b''.join(
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
                    raise ValueError('vertex shader fault: ' + str(m.fault))
                if self.steps - quantum >= STEP_QUANTUM:
                    break
            self.last_turn = used
            return used
        except (IndexError, AssertionError, RecursionError, ZeroDivisionError,
                OverflowError) as error:
            raise ValueError('vertex shade failed: ' + str(error)) from error

    @property
    def memory(self):
        class _Used:
            pass
        view = _Used()
        view.used = self.last_turn
        return view
