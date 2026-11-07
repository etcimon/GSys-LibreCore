#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded internal compute operations; no wire shader or capset admission."""
from dataclasses import dataclass

from shader.spirv_model import Model, spirv_scan
from vn_image_operands import ImageBinding


@dataclass(frozen=True)
class ShaderBinding:
    owner: object
    offset: int
    size: int
    binding: int = 0
    descriptor_set: int = 0
    kind: int = 7
    element: int = 0


@dataclass(frozen=True)
class IndirectArguments:
    owner: object
    offset: int


@dataclass(frozen=True)
class Compute:
    code: tuple
    bindings: tuple
    groups: tuple = (1, 1, 1)
    push: tuple = ()
    max_steps: int = 65536
    indirect: object = None
    allow_images: bool = False

    @property
    def size(self):
        return sum(binding.size for binding in self.bindings) + (12 if self.indirect else 0)


class ShaderMemory:
    def __init__(self, executor, context, bindings):
        self.executor, self.context, self.bindings = executor, context, bindings
        self.used = self.instruction_left = 0

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
            if base <= address and address + 4 <= base + binding.size:
                if write and binding.kind not in (3, 7):
                    continue
                if self.instruction_left < 4:
                    raise MemoryError('shader instruction exceeds bounded I/O profile')
                self.instruction_left -= 4
                self.used += 4
                return self.executor.execution.state.aperture, address
        raise KeyError('shader memory access is outside admitted bindings/permissions')

    def get(self, word, default=0):
        memory, address = self._access(word)
        return int.from_bytes(memory.read(address, 4), 'little')

    def __getitem__(self, word):
        return self.get(word)

    def __setitem__(self, word, value):
        memory, address = self._access(word, True)
        memory.write(address, int(value & 0xFFFFFFFF).to_bytes(4, 'little'))


class ShaderRuntime:
    IO_QUANTUM = 4096

    @staticmethod
    def _image_row(executor, context, binding):
        if (type(binding.kind) is not int or binding.kind not in (0, 1, 2, 3) or
                binding.element != 0 or
                any(type(value) is not int for value in (binding.offset, binding.size,
                    binding.width, binding.height, binding.pitch, binding.fmt, binding.swizzle)) or
                not 0 <= binding.swizzle < 4096 or
                not isinstance(binding.sampler, tuple) or len(binding.sampler) != 2 or
                any(type(word) is not int or not 0 <= word < 1 << 32 for word in binding.sampler)):
            raise ValueError('image binding metadata exceeds native compute profile')
        base = 0
        if binding.kind == 0:
            if (binding.owner is not None or any((binding.offset, binding.size,
                    binding.width, binding.height, binding.pitch, binding.fmt, binding.swizzle))):
                raise ValueError('sampler-only binding cannot own image bytes')
        else:
            names, _, bpp, _ = executor.execution.model.img_fmt_tables()
            depth_ok = (0 <= binding.fmt < len(names) and
                        binding.kind in (1, 2) and
                        names[binding.fmt] in ('D16_UNORM', 'D32_SFLOAT'))
            if (not 0 <= binding.fmt < len(names) or
                    (names[binding.fmt].startswith(('D', 'S8', 'X8_D'))
                     and not depth_ok) or
                    bpp[binding.fmt] not in (1, 2, 4, 8, 16) or
                    not 0 < binding.width <= 4096 or not 0 < binding.height <= 4096 or
                    type(binding.mips) is not int or not 1 <= binding.mips <= 13 or
                    binding.offset % 4 or
                    binding.pitch != executor.execution.golden.img_mpitch(
                        executor.execution.model, binding.width, binding.fmt, 0) or
                    binding.size != executor.execution.golden.img_layer_bytes(
                        executor.execution.model, binding.width, binding.height,
                        binding.fmt, binding.mips)):
                raise ValueError('image binding format/footprint exceeds native compute profile')
            base = executor._extent(context, binding.owner, binding.offset, binding.size)
        return (binding.descriptor_set, binding.binding, binding.size, base,
                binding.kind << 16 | 1 << 24, binding.width | binding.height << 16,
                binding.fmt | binding.mips << 8 | 1 << 16, binding.swizzle,
                *binding.sampler)

    def __init__(self, executor, context, operation):
        if (not isinstance(operation.code, tuple) or not 5 <= len(operation.code) <= 4096 or
                any(type(w) is not int or not 0 <= w < 1 << 32 for w in operation.code) or
                operation.code[0] != 0x07230203 or not 0 < operation.code[3] <= 4096):
            raise ValueError('shader module exceeds native word/ID profile')
        position = 5
        while position < len(operation.code):
            count = operation.code[position] >> 16
            if not 0 < count <= 33 or position + count > len(operation.code):
                raise ValueError('shader instruction word bounds are invalid')
            position += count
        if (not isinstance(operation.bindings, tuple) or len(operation.bindings) > 16 or
                not isinstance(operation.groups, tuple) or len(operation.groups) != 3 or
                any(type(n) is not int or not 0 <= n <= 64 for n in operation.groups) or
                not isinstance(operation.push, tuple) or len(operation.push) > 32 or
                any(type(w) is not int or not 0 <= w < 1 << 32 for w in operation.push) or
                type(operation.max_steps) is not int or not 0 < operation.max_steps <= 65536 or
                type(operation.allow_images) is not bool or
                executor.poll_bytes < self.IO_QUANTUM):
            raise ValueError('shader dimensions/push/instruction/I/O budgets exceed profile')
        self.owners, rows, keys, total = {}, [], set(), 0
        self.indirect = operation.indirect
        if self.indirect is not None:
            if (not isinstance(self.indirect, IndirectArguments) or
                    type(self.indirect.offset) is not int or self.indirect.offset % 4 or
                    operation.groups != (1, 1, 1)):
                raise ValueError('invalid native indirect argument source')
            executor._extent(context, self.indirect.owner, self.indirect.offset, 12)
            self.owners[id(self.indirect.owner)] = self.indirect.owner
        for binding in operation.bindings:
            image = isinstance(binding, ImageBinding)
            if ((not isinstance(binding, ShaderBinding) and not (image and operation.allow_images)) or
                    type(binding.descriptor_set) is not int or
                    not 0 <= binding.descriptor_set < 4 or
                    type(binding.binding) is not int or not 0 <= binding.binding < 256 or
                    type(binding.offset) is not int or type(binding.size) is not int or
                    (not image and (binding.kind not in (6, 7) or
                     binding.offset % 4 or binding.size % 4 or binding.size <= 0)) or
                    type(binding.element) is not int or not 0 <= binding.element < 16):
                raise ValueError('unsupported native shader binding')
            key = binding.descriptor_set, binding.binding, binding.element
            if key in keys:
                raise ValueError('duplicate descriptor element exceeds native shader profile')
            keys.add(key)
            if image:
                row = self._image_row(executor, context, binding)
            else:
                base = executor._extent(context, binding.owner, binding.offset, binding.size)
                row = (binding.descriptor_set, binding.binding, binding.size, base,
                       binding.kind << 16 | binding.element)
            if binding.owner is not None:
                self.owners[id(binding.owner)] = binding.owner
            total += binding.size
            if total > 65536:
                raise MemoryError('shader binding-byte budget exhausted')
            rows.append(row)
        rows = [word for row in sorted(rows, key=lambda row: (row[0], row[1], row[4] & 255))
                for word in row]
        self.memory = ShaderMemory(executor, context, operation.bindings)
        groups = operation.groups if self.indirect is None else (0, 0, 0)
        words = [len(operation.code), len(operation.bindings), len(operation.push),
                 *groups, 0, 0, *operation.code, *rows, *operation.push, 0]
        try:
            self.model = Model(words, memory=self.memory)
        except (spirv_scan.Fault, IndexError, AssertionError, RecursionError) as error:
            raise ValueError('shader scan failed: ' + str(error)) from error
        self.local = self.model.lx * self.model.ly * self.model.lz
        self.groups = groups
        self.group_count = self.groups[0] * self.groups[1] * self.groups[2]
        if (self.model.sc.em != spirv_scan.EM['GLCOMPUTE'] or
                not 0 < self.local <= 64 or self.local * self.group_count > 256):
            raise ValueError('shader stage/invocation count exceeds compute profile')
        self.group = self.cursor = self.steps = 0
        self.max_steps, self.done = operation.max_steps, False
        self._gate = False
        if self.indirect is None:
            self._group()

    def _group(self):
        if self.group == self.group_count:
            self.done = True
            return
        m = self.model
        x = self.group % self.groups[0]
        y = self.group // self.groups[0] % self.groups[1]
        z = self.group // (self.groups[0] * self.groups[1])
        m.wg, m.slab, m.l0_idx = (x, y, z), [0] * m.slb_w, {}
        m.ivs = [m.inv_init() for _ in range(self.local)]
        self.cursor = 0

    def advance(self, budget):
        self.memory.used = 0
        try:
            if not self._gate:
                # conditional rendering: the predicate word is re-read
                # once per dispatch command; a failing predicate
                # discards the whole dispatch (including the indirect
                # argument fetch) at its stream position
                self._gate = True
                gate = self.memory.executor.cond.get(
                    id(self.memory.context))
                if gate is not None:
                    addr, inverted = gate
                    word = int.from_bytes(
                        self.memory.executor.execution.state.aperture.read(
                            addr, 4), 'little')
                    if not ((word != 0) ^ bool(inverted)):
                        self.done = True
                        return 0
            if self.indirect is not None:
                if budget < 12:
                    return 0
                executor, context = self.memory.executor, self.memory.context
                if not executor._live(context):
                    raise KeyError('indirect context was retired')
                address = self.indirect.owner.base + self.indirect.offset
                self.memory.used = 12
                data = executor.execution.state.aperture.read(address, 12)
                if len(data) != 12:
                    raise OSError('short indirect argument read')
                if not executor._live(context):
                    raise KeyError('indirect context retired during argument read')
                groups = tuple(int.from_bytes(data[i:i + 4], 'little') for i in (0, 4, 8))
                count = groups[0] * groups[1] * groups[2]
                if any(value > 64 for value in groups) or count * self.local > 256:
                    raise ValueError('indirect dimensions exceed bounded compute profile')
                self.model.gx, self.model.gy, self.model.gz = groups
                self.groups, self.group_count, self.indirect = groups, count, None
                self._group()
            for _ in range(32):
                if self.done or budget - self.memory.used < self.IO_QUANTUM:
                    break
                if not self.memory.executor._live(self.memory.context):
                    raise KeyError('shader context was retired during execution')
                m = self.model
                live = [i for i in range(self.local) if not m.ivs[i]['done']]
                if not live:
                    self.group += 1
                    self._group()
                    continue
                if self.steps >= self.max_steps:
                    raise ValueError('shader instruction budget exhausted')
                ready = [i for i in live if not m.ivs[i]['bwait']]
                if not ready:
                    for i in live:
                        m.ivs[i]['bwait'] = False
                    m.nswitch += 1
                    self.steps += 1
                    continue
                index = next((i for i in ready if i >= self.cursor), ready[0])
                self.cursor = (index + 1) % self.local
                self.memory.instruction_left = self.IO_QUANTUM
                m.run_inv(index, single=True)
                self.steps += 1
                if m.fault is not None:
                    raise ValueError('shader model reported execution fault: ' + str(m.fault))
        except (IndexError, AssertionError, RecursionError, ZeroDivisionError,
                OverflowError, spirv_scan.Fault) as error:
            raise ValueError('shader execution failed: ' + str(error)) from error
        return self.memory.used
