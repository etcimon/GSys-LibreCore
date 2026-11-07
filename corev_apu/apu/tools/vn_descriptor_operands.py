# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Resolve native buffer-descriptor provenance; callers must acquire leases."""
from dataclasses import dataclass

from vn_compute import ShaderBinding


@dataclass(frozen=True)
class DescriptorOperand:
    binding: ShaderBinding
    references: tuple
    validate: object


def buffer_descriptor(engine, context_id, descriptor_set, binding, element=0,
                      dynamic_offset=0, set_index=0):
    context = engine.contexts[context_id]
    if not engine.transfers._live(context):
        raise KeyError('descriptor context is unavailable')
    front, kinds = context.frontend, engine.golden.KIND
    references = []

    def resolve(handle, name):
        status, slot, entry = front.resolve(handle, kinds[name])
        if status != 'OK' or entry['ctx'] != context_id:
            raise KeyError('descriptor operand generation/context is stale')
        canonical = entry['gen'] << 16 | slot
        references.append((canonical, kinds[name]))
        return entry

    descriptor = resolve(descriptor_set, 'VkDescriptorSet')
    dead, layout = front.dset_dead(descriptor)
    if dead or descriptor['aux'] & (1 << 31):
        raise KeyError('descriptor pool/layout/epoch is stale or poisoned')
    pool = resolve(descriptor['size'] & 0xFFFFFFFF, 'VkDescriptorPool')
    layout_handle = descriptor['aux'] >> 32
    if descriptor.get('native_layout') is not None:
        if layout.get('native_handle') != layout_handle or 'native_signature' not in layout:
            raise KeyError('descriptor has no retained layout identity')
    else:
        resolve(layout_handle, 'VkDescriptorSetLayout')
    if (type(binding) is not int or not 0 <= binding < 256 or
            type(element) is not int or element < 0 or
            type(set_index) is not int or not 0 <= set_index < 4 or
            type(dynamic_offset) is not int or dynamic_offset < 0):
        raise ValueError('invalid native descriptor index/dynamic offset')
    row = front.lay_row(layout, binding)
    if row is None or row['type'] not in (6, 7, 8, 9) or element >= row['count']:
        raise ValueError('buffer descriptor row/element exceeds native profile')
    if dynamic_offset and not row['dyn']:
        raise ValueError('non-dynamic descriptor cannot consume dynamic offsets')
    address = ((descriptor['aux'] & 0x1FFFFFF) << 2) + (row['off'] + element) * 32
    source = (front.descriptor_sources.get(address)
              if front.descriptor_sources is not None else None)
    if not isinstance(source, tuple) or len(source) != 7:
        raise KeyError('descriptor has no native buffer provenance')
    buffer_handle, memory_handle, binding_offset, buffer_size, offset, size, dtype = source
    resource = resolve(buffer_handle, 'VkBuffer')
    memory = resolve(memory_handle, 'VkDeviceMemory')
    parent = pool['parent']
    device = front.ent[parent] if 0 <= parent < front.SLOTS else None
    if (device is None or descriptor['parent'] != descriptor['size'] & 0xFFFF or
            any(entry['parent'] != parent for entry in (layout, resource, memory))):
        raise ValueError('descriptor operands belong to different devices')
    resolve(device['gen'] << 16 | parent, 'VkDevice')
    if (resource['bind_mem'] != memory_handle & 0xFFFF or
            resource['bind_mgen'] != memory_handle >> 16 or
            resource['bind_off'] != binding_offset or resource['size'] != buffer_size):
        raise KeyError('descriptor buffer memory binding changed')
    uniform = dtype in (6, 8)
    limits = engine.model.profile['limits']
    alignment = limits['minUniformBufferOffsetAlignment' if uniform else
                       'minStorageBufferOffsetAlignment']
    maximum = limits['maxUniformBufferRange' if uniform else 'maxStorageBufferRange']
    if (dtype != row['type'] or not resource.get('native_usage', 0) & (0x10 if uniform else 0x20) or
            offset % alignment or dynamic_offset % alignment or size <= 0 or
            size % 4 or size > maximum or offset + dynamic_offset > buffer_size or
            size > buffer_size - offset - dynamic_offset or
            binding_offset + offset + dynamic_offset + size > memory['size']):
        raise ValueError('descriptor type/usage/alignment/range exceeds logical resource')
    words = [front.apr64(address + i * 8) for i in range(4)]
    if (words[0] != memory_handle | size << 32 or
            words[1] & 0xFFFFFFFF != dtype | 1 << 8 or
            words[3] >> 32 != binding_offset + offset):
        raise ValueError('descriptor bytes differ from captured provenance')
    def validate():
        if not engine.transfers._live(context):
            raise KeyError('descriptor context retired during resolution')
        if (front.descriptor_sources is None or
                front.descriptor_sources.get(address) is not source or
                resource['bind_mem'] != memory_handle & 0xFFFF or
                resource['bind_mgen'] != memory_handle >> 16 or
                resource['bind_off'] != binding_offset or resource['size'] != buffer_size or
                descriptor['aux'] & (1 << 31) or front.dset_dead(descriptor)[0]):
            raise KeyError('descriptor provenance/binding changed during resolution')
        for handle, kind in references:
            if front.resolve(handle, kind)[0] != 'OK':
                raise KeyError('descriptor operand retired during resolution')

    validate()
    owner = engine.memory(context_id, memory_handle)
    if owner.base is None:
        raise ValueError('descriptor memory is unbacked')
    return DescriptorOperand(ShaderBinding(
        owner, binding_offset + offset + dynamic_offset, size, binding,
        set_index, 6 if uniform else 7, element), tuple(references), validate)
