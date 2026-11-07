# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Recorded native vertex/index provenance; callers must acquire work leases."""
from dataclasses import dataclass


@dataclass(frozen=True)
class BufferSource:
    context: object
    device: int
    buffer: int
    memory: int
    binding: int
    capacity: int
    usage: int
    offset: int
    index_bytes: int


@dataclass(frozen=True)
class BufferBindings:
    first: int
    sources: tuple


def capture(engine, current, name, record):
    if name not in ('vkCmdBindVertexBuffers', 'vkCmdBindIndexBuffer'):
        return None
    front, kinds = current.frontend, engine.golden.KIND
    context = engine.contexts[front.ctx]

    def resolve(value, kind):
        status, slot, entry = front.resolve(value, kinds[kind])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('vertex/index generation/context is stale')
        return entry['gen'] << 16 | slot, entry

    cb = next(record['q'][i] for i in range(8)
              if record['qv'] >> i & 1 and record['kind'][i] == kinds['VkCommandBuffer'])
    _, command = resolve(cb, 'VkCommandBuffer')
    pool = front.ent[command['parent']]
    if pool is None:
        raise KeyError('vertex/index command pool is unavailable')
    resolve(pool['gen'] << 16 | command['parent'], 'VkCommandPool')
    parent = pool['parent']
    device_entry = front.ent[parent]
    if device_entry is None:
        raise KeyError('vertex/index command device is unavailable')
    device, _ = resolve(device_entry['gen'] << 16 | parent, 'VkDevice')
    if record['chain']:
        raise ValueError('vertex/index chain exceeds profile')
    vertex = name == 'vkCmdBindVertexBuffers'
    if vertex:
        first, count = record['imm'][:2]
        if (not 0 <= first < 16 or not 0 < count <= 16 - first or
                len(record['pay']) != 4 * count or
                record['blob'][0][1] != 2 * count or record['blob'][1][1] != 2 * count):
            raise ValueError('vertex binding count/payload exceeds profile')
        data = record['pay']
        values = [(data[2 * i] | data[2 * i + 1] << 32,
                   data[2 * count + 2 * i] | data[2 * count + 2 * i + 1] << 32, 0)
                  for i in range(count)]
    else:
        first, index_type = 0, record['imm'][0]
        if index_type not in (0, 1) or len(record['pay']) != 2:
            raise ValueError('index type/payload exceeds uint16/uint32 profile')
        buffer = next(record['q'][i] for i in range(8)
                      if record['qv'] >> i & 1 and record['kind'][i] == kinds['VkBuffer'])
        values = [(buffer, record['pay'][0] | record['pay'][1] << 32, 2 << index_type)]
    sources = []
    for raw, offset, index_bytes in values:
        buffer, entry = resolve(raw, 'VkBuffer')
        slot = entry.get('bind_mem', -1)
        if not 0 <= slot < front.SLOTS:
            raise KeyError('vertex/index buffer has no memory binding')
        memory, me = resolve(entry.get('bind_mgen', 0) << 16 | slot, 'VkDeviceMemory')
        usage, binding, capacity = entry.get('native_usage', 0), entry.get('bind_off', 0), entry['size']
        if (entry['parent'] != parent or me['parent'] != parent or
                not usage & (0x40 if index_bytes else 0x80) or offset >= capacity or
                binding + capacity > me['size'] or
                index_bytes and (offset % index_bytes or binding % index_bytes)):
            raise ValueError('vertex/index usage/device/alignment/range exceeds logical buffer')
        sources.append(BufferSource(context, device, buffer, memory, binding,
                                    capacity, usage, offset, index_bytes))
    return BufferBindings(first, tuple(sources))


def attach(out, snapshot):
    if snapshot is not None and not out['fault'] and not out['result'] and out.get('record') is not None:
        out['record']['native_graphics_buffers'] = snapshot


@dataclass(frozen=True)
class BufferOperand:
    owner: object
    offset: int
    size: int
    index_bytes: int
    references: tuple
    validate: object


def operand(engine, context_id, source, length=None):
    context = engine.contexts[context_id]
    front, kinds = context.frontend, engine.golden.KIND
    if not isinstance(source, BufferSource) or source.context is not context:
        raise ValueError('vertex/index source context exceeds profile')
    refs = []

    def resolve(handle, kind):
        status, slot, entry = front.resolve(handle, kinds[kind])
        if status != 'OK' or entry['ctx'] != context_id:
            raise KeyError('vertex/index operand generation/context is stale')
        refs.append((entry['gen'] << 16 | slot, kinds[kind]))
        return entry

    resolve(source.device, 'VkDevice')
    entry, memory = resolve(source.buffer, 'VkBuffer'), resolve(source.memory, 'VkDeviceMemory')
    size = source.capacity - source.offset if length is None else length
    if (type(size) is not int or not 0 < size <= source.capacity - source.offset or
            source.binding + source.capacity > memory['size'] or
            source.index_bytes and size % source.index_bytes and length is not None):
        raise ValueError('vertex/index operand range exceeds logical buffer')
    owner = engine.memory(context_id, source.memory)

    def validate():
        if not engine.transfers._live(context):
            raise KeyError('vertex/index context retired during admission')
        if any(front.resolve(handle, kind)[0] != 'OK' for handle, kind in refs):
            raise KeyError('vertex/index operand retired during admission')
        if (entry['parent'] != source.device & 0xFFFF or
                memory['parent'] != source.device & 0xFFFF or
                entry.get('native_usage') != source.usage or entry['size'] != source.capacity or
                entry.get('bind_off') != source.binding or
                entry.get('bind_mem') != source.memory & 0xFFFF or
                entry.get('bind_mgen') != source.memory >> 16 or owner.deferred_free is not None):
            raise KeyError('vertex/index buffer provenance changed')

    validate()
    engine.transfers._extent(context, owner, source.binding + source.offset, size)
    validate()
    return BufferOperand(owner, source.binding + source.offset, size,
                         source.index_bytes, tuple(refs), validate)
