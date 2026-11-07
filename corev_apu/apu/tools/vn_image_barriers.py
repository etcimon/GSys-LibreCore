#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native coherent barrier capture, retained resource generations and scopes."""
from vn_transfer_executor import Transfer


MEMORY_FIELDS = tuple('pMemoryBarriers.' + field for field in (
    'srcAccessMask', 'dstAccessMask'))
BUFFER_FIELDS = tuple('pBufferMemoryBarriers.' + field for field in (
    'srcAccessMask', 'dstAccessMask', 'srcQueueFamilyIndex', 'dstQueueFamilyIndex',
    'buffer', 'offset', 'size'))
IMAGE_FIELDS = tuple('pImageMemoryBarriers.' + field for field in (
    'srcAccessMask', 'dstAccessMask', 'oldLayout', 'newLayout',
    'srcQueueFamilyIndex', 'dstQueueFamilyIndex', 'image',
    'subresourceRange.aspectMask', 'subresourceRange.baseMipLevel',
    'subresourceRange.levelCount', 'subresourceRange.baseArrayLayer',
    'subresourceRange.layerCount'))
FIELDS = MEMORY_FIELDS + BUFFER_FIELDS + IMAGE_FIELDS
WORDS = 13


def capture(engine, front, record, base=0):
    memory, buffers, images = record['imm'][3:6]
    length = memory * 2 + buffers * 10 + images * WORDS
    if (record['chain'] or base < 0 or base > len(record['pay']) or
            len(record['pay']) - base != length or
            any(count < 0 for count in (memory, buffers, images)) or
            memory + buffers + images > 16):
        raise ValueError('barrier capture count/chain exceeds native profile')
    data = list(record['pay'])
    for count, off, stride, field, kind in (
            (buffers, base + memory * 2, 10, 4, 'VkBuffer'),
            (images, base + memory * 2 + buffers * 10, WORDS, 6, 'VkImage')):
        for i in range(count):
            p = off + i * stride + field
            value = data[p] | data[p + 1] << 32
            status, slot, entry = front.resolve(value, engine.golden.KIND[kind])
            if status != 'OK' or entry['ctx'] != front.ctx:
                raise KeyError('barrier refers to a stale or foreign resource')
            data[p:p + 2] = [entry['gen'] << 16 | slot, 0]
    record['pay'] = data


def scope(stage, access, *, compute=False, shader=True, image=False):
    if compute:
        stages = 0x17001 | 0x802
        accesses = 0x1F800 | (0x60 if image else 0x69)
        compat = ((0x1800, 0x11000), (0x6000, 0x4000), (0x68, 0x10800),
                  (1, 0x10002))
    else:
        # graphics/transfer profile: bounded draw stages (no tess/geom/
        # compute/callback) and color-attachment/vertex/uniform accesses
        stages = 0x17001 | 0x78E
        accesses = 0x1F98F | (0x60 if image else 0)
        compat = ((0x1800, 0x11000), (0x6000, 0x4000), (0x60, 0x18888),
                  (0x8, 0x18888), (0x6, 0x1800C), (0x180, 0x18780),
                  (0x1, 0x10002))
    if not stage or stage & ~stages or access & ~accesses:
        raise ValueError('barrier stage/access exceeds coherent profile')
    for bits, supported in compat:
        if access & bits and not stage & supported:
            raise ValueError('barrier access is incompatible with stage')


def replay(images, record, *, compute=False, device=None, offset=0):
    imm = record['imm']
    memory, buffers, count = imm[3:6]
    if imm[2] or any(n < 0 for n in (memory, buffers, count)) or memory + buffers + count > 16:
        raise ValueError('barrier flags/count exceeds coherent profile')
    scope(imm[0], 0, compute=compute)
    scope(imm[1], 0, compute=compute)
    if buffers + count > images._remaining():
        raise MemoryError('barrier operation budget exhausted')
    length = memory * 2 + buffers * 10 + count * WORDS
    if record.get('payload_words') != length + offset:
        raise ValueError('barrier payload is not retained exactly')
    data = images.payload(record, length, offset) if length else []
    for i in range(memory):
        scope(imm[0], data[i * 2], compute=compute)
        scope(imm[1], data[i * 2 + 1], compute=compute)
    for i in range(buffers):
        r = data[memory * 2 + i * 10:memory * 2 + (i + 1) * 10]
        scope(imm[0], r[0], compute=compute)
        scope(imm[1], r[1], compute=compute)
        if r[2] != 0xFFFFFFFF or r[3] != 0xFFFFFFFF:
            raise ValueError('buffer barrier ownership transfer exceeds profile')
        resource = {'handle': [r[4] | r[5] << 32]}
        _, entry = images.remember(resource['handle'][0], images.engine.golden.KIND['VkBuffer'])
        if device is not None and entry['parent'] != device:
            raise ValueError('buffer barrier crosses command-buffer devices')
        owner, binding, capacity = images.extent(resource, 0)
        offset, size = r[6] | r[7] << 32, r[8] | r[9] << 32
        if size == (1 << 64) - 1:
            size = capacity - offset
        if offset >= capacity or not size or size > capacity - offset:
            raise ValueError('buffer barrier range exceeds logical buffer')
        images.operations.append(Transfer('barrier', owner, binding + offset, 0))
    data = data[memory * 2 + buffers * 10:]
    for i in range(count):
        r = data[i * WORDS:(i + 1) * WORDS]
        scope(imm[0], r[0], compute=compute, image=True)
        scope(imm[1], r[1], compute=compute, image=True)
        if (r[2] not in ((0, 1, 5, 6, 7, 8) if compute else
                         (0, 1, 2, 5, 6, 7, 8)) or
                r[3] not in ((1, 5, 6, 7) if compute else (1, 2, 5, 6, 7)) or
                r[4] != 0xFFFFFFFF or r[5] != 0xFFFFFFFF):
            raise ValueError('unsupported image access/layout/queue-family transition')
        for access, layout in ((r[0], r[2]), (r[1], r[3])):
            if (access & 0x40 and layout != 1 or
                    access & 0x20 and layout not in (1, 5) or
                    layout == 5 and access & ~0x8020 or
                    access & 0x180 and layout not in (1, 2) or
                    layout == 2 and access & ~0x8180):
                raise ValueError('image shader access is incompatible with layout')
        resource = {'handle': [r[6] | r[7] << 32]}
        _, entry = images.remember(resource['handle'][0], images.engine.golden.KIND['VkImage'])
        if device is not None and entry['parent'] != device:
            raise ValueError('image barrier crosses command-buffer devices')
        usage = entry['aux'] >> 54
        access = r[0] | r[1]
        if (access & 0x40 and not usage & 8 or access & 0x20 and not usage & 12 or
                access & 0x180 and not usage & 16 or
                5 in r[2:4] and not usage & 4 or
                2 in r[2:4] and not usage & 16):
            raise ValueError('image shader access exceeds image usage')
        image = images._image(resource, 0)
        aspect, mip, levels, layer, layers = r[8:13]
        levels = image['mips'] - mip if levels == 0xFFFFFFFF else levels
        layers = image['layers'] - layer if layers == 0xFFFFFFFF else layers
        if (aspect != 1 or not 0 < levels <= image['mips'] or
                mip + levels > image['mips'] or not 0 < layers <= image['layers'] or
                layer + layers > image['layers']):
            raise ValueError('image barrier subresource range exceeds image')
        # Linear coherent storage needs no cache/layout conversion. A typed
        # barrier operation still retains backing until ordered retirement.
        images.operations.append(Transfer('barrier', image['owner'], image['binding'], 0))
        # §12.3 layout transition: oldLayout must match the image's
        # tracked layout unless it is UNDEFINED (contents discarded —
        # always admitted); newLayout publishes as the current layout.
        # Per-image granularity: a barrier on any subresource range
        # transitions the whole tracked image (subresource-level layout
        # state is not modelled).
        cur = entry.get('layout', 0)
        if r[2] != 0 and r[2] != cur:
            raise ValueError('image barrier oldLayout does not match current layout')
        entry['layout'] = r[3]
