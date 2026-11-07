# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native by-value pipeline layout identity; no hardware layout/table changes."""
from dataclasses import dataclass


@dataclass(frozen=True)
class PipelineLayout:
    context: object
    device: int
    flags: int
    sets: tuple
    push: tuple

    def compatible(self, other, descriptor_set):
        return (isinstance(other, PipelineLayout) and
                type(descriptor_set) is int and descriptor_set >= 0 and
                descriptor_set < min(len(self.sets), len(other.sets)) and
                self.context is other.context and
                self.device == other.device and self.flags == other.flags and
                self.push == other.push and
                self.sets[:descriptor_set + 1] == other.sets[:descriptor_set + 1])


def capture(engine, current, name, record):
    front, kinds = current.frontend, engine.golden.KIND

    def resolve(handle, kind):
        status, slot, entry = front.resolve(handle, kinds[kind])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('native layout operand generation/context is stale')
        return entry['gen'] << 16 | slot, entry

    if name in ('vkCmdBindDescriptorSets', 'vkCmdPushConstants'):
        handle = next((record['q'][i] for i in range(8)
                       if record['qv'] >> i & 1 and
                       record['kind'][i] == kinds['VkPipelineLayout']), 0)
        _, entry = resolve(handle, 'VkPipelineLayout')
        result = entry.get('native_pipeline_layout')
        if result is None:
            raise ValueError('pipeline layout has no native identity')
        return result
    if name != 'vkCreatePipelineLayout':
        return None
    device = next((record['q'][i] for i in range(8)
                   if record['qv'] >> i & 1 and record['kind'][i] == kinds['VkDevice']), 0)
    device, _ = resolve(device, 'VkDevice')
    flags, nsets, nranges = record['imm'][:3]
    pay, signatures = record['pay'], []
    if flags or not 0 <= nsets <= 4 or not 0 <= nranges <= 32 or len(pay) != 2 * nsets + 3 * nranges:
        raise ValueError('pipeline layout counts/flags exceed native profile')
    for i in range(nsets):
        _, entry = resolve(pay[2 * i] | pay[2 * i + 1] << 32, 'VkDescriptorSetLayout')
        signature = entry.get('native_signature')
        if entry['parent'] != device & 0xFFFF or signature is None:
            raise ValueError('set layout device/native identity mismatch')
        signatures.append(signature)
    ranges = tuple(tuple(pay[2 * nsets + 3 * i:2 * nsets + 3 * i + 3])
                   for i in range(nranges))
    limit = engine.model.profile['limits']['maxPushConstantsSize']
    for i, (stages, offset, size) in enumerate(ranges):
        if (not stages or (stages != 0x7FFFFFFF and stages & ~0x3F) or offset % 4 or size % 4 or
                size <= 0 or offset + size > limit):
            raise ValueError('push constant range exceeds native layout profile')
        if any(stages & s for s, _, _ in ranges[:i]):
            raise ValueError('push ranges repeat shader stages')
    # Stream reply views are ephemeral; identity belongs to the context owner.
    owner = engine.contexts[front.ctx]
    if owner.frontend is not front or owner.retired:
        raise KeyError('native layout context owner was retired')
    return PipelineLayout(owner, device, flags, tuple(signatures), tuple(sorted(ranges)))


def attach(front, name, record, out, snapshot):
    if snapshot is None or out['fault'] or out['result']:
        return
    if name == 'vkCreatePipelineLayout':
        index = next(i for i in range(8)
                     if record['qv'] >> i & 1 and record['role'][i] == 1)
        status, _, entry = front.resolve(record['q'][index], record['kind'][index])
        if status != 'OK':
            raise KeyError('created native layout is unavailable')
        entry['native_pipeline_layout'] = snapshot
    elif out['record'] is not None:
        out['record']['native_pipeline_layout'] = snapshot
