#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded vertex-shader stage over fetch records; no raster/FS admission.

Buffer (UBO/SSBO) descriptor reads are admitted through a hybrid memory that
routes binding-range accesses to the device aperture while vertex/varying
records stay in an internal store.  Descriptor `ad` bases are biased into a
high word range disjoint from the low record image so the two cannot alias;
image/sampler (UNIFORMCONST) descriptors remain refused."""
from dataclasses import dataclass

from shader.spirv_model import Model
from shader.spirv_scan import EM, SC, Scanner
from vn_compute import ShaderBinding
from vn_graphics_fetch import ATTR_STRIDE, Fetch, FetchRuntime, MAX_RECORDS

VARY_STRIDE = 144           # VS-out records share the 9-slot stride
BATCH_MAX = 256             # invocations per Model wave batch
STEP_QUANTUM = 512          # instructions per cooperative advance
MAX_STEPS = 1 << 20
GFX_DESC_BIAS = 0x10000000  # byte-address bias keeping descriptor `ad` clear
                            # of the low record image; bounded at admission so
                            # biased addresses always fit the 32-bit header.


class GfxMemory:
    """Hybrid shader memory for graphics waves.  Descriptor binding ranges
    (biased `ad` bases) route to the device aperture; every other word --
    vertex inputs, varying outputs, scratch -- stays in a bounded internal
    store so records and descriptor content cannot alias."""

    def __init__(self, executor, context, bindings):
        self.executor, self.context, self.bindings = executor, context, bindings
        self.store = {}

    def _access(self, word, write=False):
        if not self.executor._live(self.context):
            raise KeyError('shader context was retired')
        if type(word) is not int or word < 0:
            raise ValueError('invalid shader word address')
        address = word * 4
        for binding in self.bindings:
            if binding.owner is None:
                continue
            base = binding.owner.base + binding.offset
            lo = GFX_DESC_BIAS + base
            if lo <= address and address + 4 <= lo + binding.size:
                if write and binding.kind != 7:
                    raise KeyError('shader write to read-only descriptor')
                return self.executor.execution.state.aperture, \
                    address - GFX_DESC_BIAS
        return None

    def get(self, word, default=0):
        access = self._access(word)
        if access is None:
            return self.store.get(word, default)
        memory, address = access
        return int.from_bytes(memory.read(address, 4), 'little')

    def __getitem__(self, word):
        return self.get(word)

    def __setitem__(self, word, value):
        access = self._access(word, True)
        if access is None:
            self.store[word] = value & 0xFFFFFFFF
            return
        memory, address = access
        memory.write(address, int(value & 0xFFFFFFFF).to_bytes(4, 'little'))


@dataclass(frozen=True)
class Shade:
    """One draw's vertex-shader stage.  `fetch` is executed first inside the
    same runtime so records observe earlier queued writes exactly once.
    `bindings` carries resolved buffer descriptor operands (ShaderBinding)."""
    fetch: Fetch
    code: tuple
    push: tuple = ()
    batch: int = BATCH_MAX
    bindings: tuple = ()

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
                not 0 < operation.batch <= BATCH_MAX or
                not isinstance(operation.bindings, tuple) or
                len(operation.bindings) > 16):
            raise ValueError('vertex shade operation exceeds native profile')
        try:
            scan = Scanner(list(operation.code)).scan()
        except Exception as error:
            raise ValueError('vertex shader scan failed: ' + str(error)) from error
        if scan.em != EM['VERTEX']:
            raise ValueError('vertex shade requires a vertex execution model')
        bound = set()
        for binding in operation.bindings:
            if (not isinstance(binding, ShaderBinding) or
                    binding.kind not in (6, 7) or
                    type(binding.descriptor_set) is not int or
                    not 0 <= binding.descriptor_set < 4 or
                    type(binding.binding) is not int or
                    not 0 <= binding.binding < 256 or
                    type(binding.offset) is not int or
                    type(binding.size) is not int or
                    binding.offset % 4 or binding.size % 4 or
                    binding.size <= 0 or
                    type(binding.element) is not int or
                    not 0 <= binding.element < 16):
                raise ValueError('unsupported vertex shade binding')
            key = (binding.descriptor_set, binding.binding, binding.element)
            if key in bound:
                raise ValueError('duplicate vertex shade descriptor element')
            bound.add(key)
        for vid, row in scan.decor.items():
            if row.get('binding') is None and row.get('set') is None:
                continue
            var = scan.vars.get(vid)
            storage = var.get('storage') if var else None
            if storage not in (SC['UNIFORM'], SC['SBUF']):
                raise ValueError('vertex shade descriptor storage is not admitted')
            if ((row.get('set'), row.get('binding')) not in
                    {(b.descriptor_set, b.binding) for b in operation.bindings}):
                raise ValueError('vertex shade descriptor is not bound')
        self.executor, self.context, self.operation = executor, context, operation
        self.fetch = FetchRuntime(executor, context, operation.fetch)
        self.owners = dict(self.fetch.owners)
        self.bind_rows = []
        self.bind_pad = 0
        for binding in operation.bindings:
            base = executor._extent(context, binding.owner, binding.offset,
                                    binding.size)
            if base + binding.size > (1 << 32) - GFX_DESC_BIAS:
                raise ValueError('vertex shade descriptor address overflows profile')
            self.bind_rows.append((binding.descriptor_set, binding.binding,
                                   binding.size, GFX_DESC_BIAS + base,
                                   binding.kind << 16 | binding.element))
            self.bind_pad += binding.size // 4
            self.owners[id(binding.owner)] = binding.owner
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
        # Binding rows sit between the SPIR-V and push sections; the per-
        # binding init-word slots are emitted as placeholders (consumed but
        # not stored because a live GfxMemory is supplied) so the trailing
        # graphics section stays aligned.
        flat = [word for row in self.bind_rows for word in row]
        words = [len(self.operation.code), len(self.bind_rows),
                 len(self.operation.push),
                 1, 1, 1, 4, 0,                 # flags bit2 = graphics wave work
                 *self.operation.code, *flat, *self.operation.push, 0,
                 *([0] * self.bind_pad),
                 0,                            # stage word = SPIR-V Vertex EM
                 count, 0, out_base, 0, 0, nin,
                 *words_in, 0, 0]
        memory = GfxMemory(self.executor, self.context, self.operation.bindings)
        try:
            self.model = Model(words, memory=memory)
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
