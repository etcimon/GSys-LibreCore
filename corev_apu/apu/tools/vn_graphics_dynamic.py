# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded immutable dynamic-state payloads; no raster or draw replay admission."""
from dataclasses import dataclass
import math
import struct


@dataclass(frozen=True)
class Recording:
    context: object
    device: int
    command_buffer: int
    recording: object


@dataclass(frozen=True)
class DynamicCommand(Recording):
    kind: str
    values: tuple


def capture(engine, current, name, record):
    if name not in ('vkCmdSetViewport', 'vkCmdSetScissor'):
        return None
    viewport = name == 'vkCmdSetViewport'
    if (record['imm'][:2] != [0, 1] or record['chain'] or
            len(record['pay']) != (6 if viewport else 4)):
        raise ValueError('graphics dynamic first/count/payload exceeds profile')
    values = tuple(record['pay'])
    limits = engine.model.profile['limits']
    if viewport:
        x, y, width, height, near, far = struct.unpack('<6f', struct.pack('<6I', *values))
        lo, hi = limits['viewportBoundsRange']
        maximum_width, maximum_height = limits['maxViewportDimensions']
        if (not all(math.isfinite(v) for v in (x, y, width, height, near, far)) or
                not 0 < width <= maximum_width or not 0 < height <= maximum_height or
                not lo <= x <= hi - width or not lo <= y <= hi - height or
                not 0 <= near <= 1 or not 0 <= far <= 1):
            raise ValueError('graphics dynamic viewport floats/bounds exceed profile')
    else:
        x, y, width, height = values
        max_width, max_height = limits['maxFramebufferWidth'], limits['maxFramebufferHeight']
        if x > max_width or y > max_height or width > max_width - x or height > max_height - y:
            raise ValueError('graphics dynamic scissor exceeds bounded framebuffer range')
    return DynamicCommand(*recording_identity(engine, current, record),
                          'viewport' if viewport else 'scissor', values)


def recording_identity(engine, current, record):
    front, kinds = current.frontend, engine.golden.KIND
    raw = next(record['q'][i] for i in range(8)
               if record['qv'] >> i & 1 and record['kind'][i] == kinds['VkCommandBuffer'])
    status, slot, cb = front.resolve(raw, kinds['VkCommandBuffer'])
    if status != 'OK' or cb['ctx'] != front.ctx:
        raise KeyError('graphics dynamic command buffer generation/context is stale')
    pool = front.ent[cb['parent']]
    descriptor = front.cbd.get(slot)
    if (pool is None or descriptor is None or
            front.resolve(pool['gen'] << 16 | cb['parent'], kinds['VkCommandPool'])[0] != 'OK'):
        raise KeyError('graphics dynamic recording/pool is unavailable')
    parent, device = pool['parent'], front.ent[pool['parent']]
    if (pool['kind'] != kinds['VkCommandPool'] or pool['ctx'] != front.ctx or
            device is None or device['kind'] != kinds['VkDevice'] or device['ctx'] != front.ctx):
        raise KeyError('graphics dynamic device ownership is stale')
    canonical_device = device['gen'] << 16 | parent
    if front.resolve(canonical_device, kinds['VkDevice'])[0] != 'OK':
        raise KeyError('graphics dynamic device is unavailable')
    return engine.contexts[front.ctx], canonical_device, cb['gen'] << 16 | slot, descriptor['recs']


def attach(out, snapshot):
    if snapshot is not None and not out['fault'] and not out['result'] and out.get('record') is not None:
        out['record']['native_graphics_dynamic'] = snapshot


def validate(engine, context_id, snapshot):
    if not isinstance(snapshot, DynamicCommand) or snapshot.kind not in ('viewport', 'scissor'):
        raise KeyError('graphics dynamic identity is unavailable')
    validate_recording(engine, context_id, snapshot)
    return snapshot.values


def validate_recording(engine, context_id, snapshot):
    context = engine.contexts[context_id]
    if (not isinstance(snapshot, Recording) or snapshot.context is not context or
            not engine.transfers._live(context)):
        raise KeyError('graphics dynamic context/identity is unavailable')
    front, kinds = context.frontend, engine.golden.KIND
    status, slot, cb = front.resolve(snapshot.command_buffer, kinds['VkCommandBuffer'])
    if (status != 'OK' or cb['ctx'] != context_id or
            front.resolve(snapshot.device, kinds['VkDevice'])[0] != 'OK'):
        raise KeyError('graphics dynamic generation/device is stale')
    pool = front.ent[cb['parent']]
    descriptor = front.cbd.get(slot)
    if (pool is None or pool['kind'] != kinds['VkCommandPool'] or pool['ctx'] != context_id or
            pool['parent'] != snapshot.device & 0xFFFF or descriptor is None or
            descriptor['recs'] is not snapshot.recording or
            front.resolve(pool['gen'] << 16 | cb['parent'], kinds['VkCommandPool'])[0] != 'OK'):
        raise KeyError('graphics dynamic recording epoch/ownership changed')
