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


# vkCmdSet* dynamic-state commands carrying a single scalar immediate in
# imm[0] (no payload/chain/extra immediates) -> (kind, valid lo, hi).
# Bool commands bound to (0,1); enum commands bound to their Vk* range.
_SCALAR_DYNAMIC = {
    'vkCmdSetPrimitiveRestartEnable': ('primitive_restart', 0, 1),
    'vkCmdSetRasterizerDiscardEnable': ('rasterizer_discard', 0, 1),
    'vkCmdSetCullMode': ('cull', 0, 3),
    'vkCmdSetFrontFace': ('front_face', 0, 1),
    'vkCmdSetDepthTestEnable': ('depth_test', 0, 1),
    'vkCmdSetDepthWriteEnable': ('depth_write', 0, 1),
    'vkCmdSetDepthCompareOp': ('depth_compare', 0, 7),
    'vkCmdSetDepthBoundsTestEnable': ('bounds_test', 0, 1),
    'vkCmdSetDepthBiasEnable': ('depth_bias_enable', 0, 1),
}
_BOOL_DYNAMIC = {n: k for n, (k, _lo, _hi) in _SCALAR_DYNAMIC.items()}

# vkCmdSet* dynamic-state commands carrying N raw immediates in imm[0:N]
# (float bit patterns or packed words) -> (kind, count).  Values ride the
# DynamicCommand tuple verbatim; semantic float/range checks run per kind.
_VECTOR_DYNAMIC = {
    'vkCmdSetDepthBounds': ('bounds', 2),
    'vkCmdSetDepthBias': ('depth_bias', 3),
}


def capture(engine, current, name, record):
    scalar = _SCALAR_DYNAMIC.get(name)
    vector = _VECTOR_DYNAMIC.get(name)
    base = name in ('vkCmdSetViewport', 'vkCmdSetScissor')
    counted = name in ('vkCmdSetViewportWithCount', 'vkCmdSetScissorWithCount')
    if not (base or counted or scalar or vector):
        return None
    if vector is not None:
        kind, count = vector
        # count raw immediates in imm[0:count]; no payload, chain or extra
        # immediates.  'bounds' carries two fp32 bit patterns (min,max).
        if (any(record['imm'][count:]) or record['pay'] or record['chain']):
            raise ValueError('graphics dynamic %s exceeds profile' % kind)
        values = tuple(record['imm'][:count])
        if kind in ('bounds', 'depth_bias'):
            floats = struct.unpack('<%df' % count,
                                   struct.pack('<%dI' % count, *values))
            if not all(math.isfinite(v) for v in floats):
                raise ValueError(
                    'graphics dynamic %s floats exceed profile' % kind)
            if kind == 'bounds' and not floats[0] <= floats[1]:
                raise ValueError('graphics dynamic bounds floats exceed profile')
        return DynamicCommand(*recording_identity(engine, current, record),
                              kind, values)
    if scalar is not None:
        kind, lo, hi = scalar
        # single scalar immediate in imm[0]; no payload, chain or extra
        # immediates — bounded to the command's Vk* value domain.
        if (not lo <= record['imm'][0] <= hi or any(record['imm'][1:]) or
                record['pay'] or record['chain']):
            raise ValueError('graphics dynamic %s exceeds profile' % kind)
        return DynamicCommand(*recording_identity(engine, current, record),
                              kind, (record['imm'][0],))
    viewport = 'Viewport' in name
    # base carries {first,count} in imm[0:2]; *WithCount drops first and
    # carries only count in imm[0] (always writes slots [0,count)).  The
    # bounded profile is single-slot (maxVps=maxScissors=1), so only the
    # count==1 record shape is admitted — identical pay payload to base.
    shape = record['imm'][:2] == [0, 1] if base else record['imm'][0] == 1
    if (not shape or record['chain'] or
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
    if (not isinstance(snapshot, DynamicCommand) or
            snapshot.kind not in ('viewport', 'scissor') +
            tuple(_BOOL_DYNAMIC.values()) +
            tuple(k for k, _c in _VECTOR_DYNAMIC.values())):
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
