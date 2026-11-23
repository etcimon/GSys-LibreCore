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

# synchronization2 (vkCmdPipelineBarrier2/SetEvent2/WaitEvents2): every
# barrier carries its own u64 src/dst stage+access masks inside a
# VkDependencyInfo struct.  Pointer hops are transparent for the singular
# pDependencyInfo form, so the keep paths name the barrier arrays
# directly; the plural pDependencyInfos array on WaitEvents2 prefixes
# every path with 'pDependencyInfos.'.  Word counts per staged element
# (KEEP stages each u64 as lo,hi and each u32/HANDLE as one/two words):
#   memory  8  = 4 u64 masks
#   buffer 16  = 4 u64 masks + srcQF + dstQF + buffer(u64) + offset(u64)
#                 + size(u64)
#   image  19  = 4 u64 masks + old/new layout + srcQF + dstQF + image(u64)
#                 + 5 subresourceRange u32s
SYNC2_MASKS = ('srcStageMask', 'srcAccessMask',
               'dstStageMask', 'dstAccessMask')
SYNC2_BUFFER = SYNC2_MASKS + ('srcQueueFamilyIndex',
                              'dstQueueFamilyIndex', 'buffer', 'offset',
                              'size')
SYNC2_IMAGE = SYNC2_MASKS + ('oldLayout', 'newLayout',
                             'srcQueueFamilyIndex', 'dstQueueFamilyIndex',
                             'image') + tuple(
                                 'subresourceRange.' + f for f in (
                                     'aspectMask', 'baseMipLevel',
                                     'levelCount', 'baseArrayLayer',
                                     'layerCount'))
SYNC2_MEMORY_WORDS = 8
SYNC2_BUFFER_WORDS = 16
SYNC2_IMAGE_WORDS = 19


def sync2_fields(prefix=''):
    """Keep paths for one VkDependencyInfo barrier set.  `prefix` is
    '' for the transparent singular pDependencyInfo and
    'pDependencyInfos.' for the WaitEvents2 array form."""
    p = lambda n: prefix + n
    return ([p('pMemoryBarriers.' + f) for f in SYNC2_MASKS] +
            [p('pBufferMemoryBarriers.' + f) for f in SYNC2_BUFFER] +
            [p('pImageMemoryBarriers.' + f) for f in SYNC2_IMAGE])


# Per-VkDependencyInfo scalar members kept so the retained pay stream is
# self-delimiting: dependencyFlags (validated == 0) then the three barrier
# counts, each immediately followed by that array's staged element words.
# WaitEvents2 carries eventCount such structs, so its pay repeats this
# [flags, memCount, mem..., bufCount, buf..., imgCount, img...] block.
SYNC2_DEP_COUNTS = ('memoryBarrierCount', 'bufferMemoryBarrierCount',
                    'imageMemoryBarrierCount')


def sync2_dep_info(prefix=''):
    """Keep paths for one VkDependencyInfo's own scalars (flags + the
    three barrier counts).  Combined with sync2_fields() these let a
    consumer walk the pay stream without a side table."""
    p = lambda n: prefix + n
    return [p('dependencyFlags')] + [p(n) for n in SYNC2_DEP_COUNTS]


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


def capture_sync2(engine, front, record, base=0):
    """Resolve the embedded VkBuffer/VkImage ids inside staged
    synchronization2 barrier payloads to {gen,slot} record handles.
    record['imm'][1:4] carry memory/buffer/image barrier counts; the pay
    layout is [memory 8w][buffer 16w][image 19w] per element."""
    memory, buffers, images = record['imm'][1], record['imm'][2], \
        record['imm'][3]
    counts = (memory, buffers, images)
    if (record['chain'] or base < 0 or base > len(record['pay']) or
            any(c < 0 for c in counts) or sum(counts) > 16 or
            len(record['pay']) - base !=
            memory * SYNC2_MEMORY_WORDS +
            buffers * SYNC2_BUFFER_WORDS +
            images * SYNC2_IMAGE_WORDS):
        raise ValueError('sync2 barrier capture count/chain exceeds profile')
    data = list(record['pay'])
    off = base + memory * SYNC2_MEMORY_WORDS
    for i in range(buffers):
        p = off + i * SYNC2_BUFFER_WORDS + 10
        value = data[p] | data[p + 1] << 32
        status, slot, entry = front.resolve(
            value, engine.golden.KIND['VkBuffer'])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('sync2 buffer barrier refers to stale/foreign resource')
        data[p:p + 2] = [entry['gen'] << 16 | slot, 0]
    off += buffers * SYNC2_BUFFER_WORDS
    for i in range(images):
        p = off + i * SYNC2_IMAGE_WORDS + 12
        value = data[p] | data[p + 1] << 32
        status, slot, entry = front.resolve(
            value, engine.golden.KIND['VkImage'])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('sync2 image barrier refers to stale/foreign resource')
        data[p:p + 2] = [entry['gen'] << 16 | slot, 0]
    record['pay'] = data


def _sync2_mask(lo, hi):
    """Fold a staged u64 mask word-pair to an int, fail-closing the
    synchronization2-only high bits the bounded coherent profile does not
    model (mirrors the ResetEvent2 imm[1:7]==0 discipline)."""
    if hi:
        raise ValueError('sync2 barrier mask exceeds coherent profile')
    return lo


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


def _sync2_barriers(images, data, memory, buffers, count, *,
                    compute=False, device=None):
    """Validate + replay one flat synchronization2 barrier stream
    ([memory 8w][buffer 16w][image 19w] per element) into typed barrier
    Transfer ops.  Shared by replay_sync2 (singular pDependencyInfo) and
    the per-dependencyInfo blocks of vkCmdWaitEvents2."""
    if buffers + count > images._remaining():
        raise MemoryError('sync2 barrier operation budget exhausted')
    for i in range(memory):
        r = data[i * SYNC2_MEMORY_WORDS:(i + 1) * SYNC2_MEMORY_WORDS]
        scope(_sync2_mask(r[0], r[1]), _sync2_mask(r[2], r[3]),
              compute=compute)
        scope(_sync2_mask(r[4], r[5]), _sync2_mask(r[6], r[7]),
              compute=compute)
    off = memory * SYNC2_MEMORY_WORDS
    for i in range(buffers):
        r = data[off + i * SYNC2_BUFFER_WORDS:
                 off + (i + 1) * SYNC2_BUFFER_WORDS]
        scope(_sync2_mask(r[0], r[1]), _sync2_mask(r[2], r[3]),
              compute=compute)
        scope(_sync2_mask(r[4], r[5]), _sync2_mask(r[6], r[7]),
              compute=compute)
        if r[8] != 0xFFFFFFFF or r[9] != 0xFFFFFFFF:
            raise ValueError('sync2 buffer barrier ownership transfer exceeds profile')
        resource = {'handle': [r[10] | r[11] << 32]}
        _, entry = images.remember(
            resource['handle'][0], images.engine.golden.KIND['VkBuffer'])
        if device is not None and entry['parent'] != device:
            raise ValueError('sync2 buffer barrier crosses command-buffer devices')
        owner, binding, capacity = images.extent(resource, 0)
        offset = r[12] | r[13] << 32
        size = r[14] | r[15] << 32
        if size == (1 << 64) - 1:
            size = capacity - offset
        if offset >= capacity or not size or size > capacity - offset:
            raise ValueError('sync2 buffer barrier range exceeds logical buffer')
        images.operations.append(Transfer('barrier', owner, binding + offset, 0))
    off += buffers * SYNC2_BUFFER_WORDS
    for i in range(count):
        r = data[off + i * SYNC2_IMAGE_WORDS:
                 off + (i + 1) * SYNC2_IMAGE_WORDS]
        src_stage = _sync2_mask(r[0], r[1])
        src_access = _sync2_mask(r[2], r[3])
        dst_stage = _sync2_mask(r[4], r[5])
        dst_access = _sync2_mask(r[6], r[7])
        scope(src_stage, src_access, compute=compute, image=True)
        scope(dst_stage, dst_access, compute=compute, image=True)
        old_layout, new_layout = r[8], r[9]
        if (r[10] != 0xFFFFFFFF or r[11] != 0xFFFFFFFF or
                old_layout not in ((0, 1, 5, 6, 7, 8) if compute else
                                   (0, 1, 2, 5, 6, 7, 8)) or
                new_layout not in ((1, 5, 6, 7) if compute else
                                   (1, 2, 5, 6, 7))):
            raise ValueError('unsupported sync2 image access/layout/queue-family transition')
        for access, layout in ((src_access, old_layout),
                               (dst_access, new_layout)):
            if (access & 0x40 and layout != 1 or
                    access & 0x20 and layout not in (1, 5) or
                    layout == 5 and access & ~0x8020 or
                    access & 0x180 and layout not in (1, 2) or
                    layout == 2 and access & ~0x8180):
                raise ValueError('sync2 image shader access incompatible with layout')
        resource = {'handle': [r[12] | r[13] << 32]}
        _, entry = images.remember(
            resource['handle'][0], images.engine.golden.KIND['VkImage'])
        if device is not None and entry['parent'] != device:
            raise ValueError('sync2 image barrier crosses command-buffer devices')
        usage = entry['aux'] >> 54
        access = src_access | dst_access
        if (access & 0x40 and not usage & 8 or access & 0x20 and not usage & 12 or
                access & 0x180 and not usage & 16 or
                5 in (old_layout, new_layout) and not usage & 4 or
                2 in (old_layout, new_layout) and not usage & 16):
            raise ValueError('sync2 image shader access exceeds image usage')
        image = images._image(resource, 0)
        aspect, mip, levels, layer, layers = r[14:19]
        levels = image['mips'] - mip if levels == 0xFFFFFFFF else levels
        layers = image['layers'] - layer if layers == 0xFFFFFFFF else layers
        if (aspect != 1 or not 0 < levels <= image['mips'] or
                mip + levels > image['mips'] or not 0 < layers <= image['layers'] or
                layer + layers > image['layers']):
            raise ValueError('sync2 image barrier subresource range exceeds image')
        images.operations.append(
            Transfer('barrier', image['owner'], image['binding'], 0))
        cur = entry.get('layout', 0)
        if old_layout != 0 and old_layout != cur:
            raise ValueError('sync2 image barrier oldLayout does not match current layout')
        entry['layout'] = new_layout


def replay_sync2(images, record, *, compute=False, device=None):
    """Replay a synchronization2 barrier record (vkCmdPipelineBarrier2 /
    SetEvent2 dependency payload).  imm[0]=dependencyFlags,
    imm[1:4]=memory/buffer/image barrier counts; pay holds per-barrier
    u64 stage/access masks plus the buffer/image handle+range fields."""
    imm = record['imm']
    memory, buffers, count = imm[1], imm[2], imm[3]
    if (imm[0] or any(n < 0 for n in (memory, buffers, count)) or
            memory + buffers + count > 16):
        raise ValueError('sync2 dependency/barrier count exceeds coherent profile')
    length = (memory * SYNC2_MEMORY_WORDS +
              buffers * SYNC2_BUFFER_WORDS + count * SYNC2_IMAGE_WORDS)
    if record.get('payload_words') != length:
        raise ValueError('sync2 barrier payload is not retained exactly')
    data = images.payload(record, length) if length else []
    _sync2_barriers(images, data, memory, buffers, count,
                    compute=compute, device=device)


def dep_info_stream(pay, start, count):
    """Walk `count` VkDependencyInfo blocks in a staged pay stream.

    Each block is self-delimiting:
      [dependencyFlags][memoryBarrierCount][memory 8w x N]
      [bufferMemoryBarrierCount][buffer 16w x N]
      [imageMemoryBarrierCount][image 19w x N]
    Yields (flags, memory, buffers, images, mem_data, buf_data, img_data)
    where the *_data slices are the contiguous per-type barrier words.
    Returns the offset just past the last block."""
    p = start
    out = []
    for _ in range(count):
        if p + 4 > len(pay):
            raise ValueError('sync2 dependency-info stream is truncated')
        flags, memory = pay[p], pay[p + 1]
        p += 2
        mem = pay[p:p + memory * SYNC2_MEMORY_WORDS]
        p += memory * SYNC2_MEMORY_WORDS
        if p >= len(pay):
            raise ValueError('sync2 dependency-info stream is truncated')
        buffers = pay[p]
        p += 1
        buf = pay[p:p + buffers * SYNC2_BUFFER_WORDS]
        p += buffers * SYNC2_BUFFER_WORDS
        if p >= len(pay):
            raise ValueError('sync2 dependency-info stream is truncated')
        images = pay[p]
        p += 1
        img = pay[p:p + images * SYNC2_IMAGE_WORDS]
        p += images * SYNC2_IMAGE_WORDS
        out.append((flags, memory, buffers, images, mem, buf, img))
    return out, p


def _dep_info_handles(data, buffers, images, off_buf, off_img, front,
                      engine):
    """Resolve embedded VkBuffer/VkImage ids inside one dep-info barrier
    group to {gen,slot} record handles, in place on `data`."""
    for i in range(buffers):
        p = off_buf + i * SYNC2_BUFFER_WORDS + 10
        value = data[p] | data[p + 1] << 32
        status, slot, entry = front.resolve(
            value, engine.golden.KIND['VkBuffer'])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('sync2 buffer barrier refers to stale/foreign resource')
        data[p:p + 2] = [entry['gen'] << 16 | slot, 0]
    for i in range(images):
        p = off_img + i * SYNC2_IMAGE_WORDS + 12
        value = data[p] | data[p + 1] << 32
        status, slot, entry = front.resolve(
            value, engine.golden.KIND['VkImage'])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('sync2 image barrier refers to stale/foreign resource')
        data[p:p + 2] = [entry['gen'] << 16 | slot, 0]


def capture_sync2_wait2(engine, front, record):
    """Canonicalize the vkCmdWaitEvents2 retained payload: 2 words per
    event id lead, then `eventCount` self-delimiting VkDependencyInfo
    blocks.  Resolves embedded buffer/image barrier handles to
    {gen,slot} in place and bounds every count/range."""
    count = record['imm'][0] & 0xFFFF
    base = 2 * count
    if record['chain'] or base > len(record['pay']):
        raise ValueError('sync2 wait2 payload chain/count exceeds profile')
    data = list(record['pay'])
    p = base
    total = 0
    for _ in range(count):
        # [dependencyFlags][memoryBarrierCount][mem 8w][bufCount]
        # [buf 16w][imgCount][img 19w]
        if p + 4 > len(data):
            raise ValueError('sync2 wait2 dependency-info stream is truncated')
        flags, memory = data[p], data[p + 1]
        if flags or memory < 0 or memory > 16:
            raise ValueError('sync2 wait2 dependency/barrier count exceeds profile')
        p += 2
        mem_end = p + memory * SYNC2_MEMORY_WORDS
        if mem_end > len(data):
            raise ValueError('sync2 wait2 dependency-info stream is truncated')
        p = mem_end
        buffers = data[p]
        p += 1
        buf_start = p
        buf_end = p + buffers * SYNC2_BUFFER_WORDS
        if buffers < 0 or buf_end > len(data):
            raise ValueError('sync2 wait2 dependency-info stream is truncated')
        p = buf_end
        images = data[p]
        p += 1
        img_start = p
        img_end = p + images * SYNC2_IMAGE_WORDS
        if images < 0 or img_end > len(data):
            raise ValueError('sync2 wait2 dependency-info stream is truncated')
        p = img_end
        total += memory + buffers + images
        if total > 16:
            raise ValueError('sync2 wait2 total barrier count exceeds profile')
        _dep_info_handles(data, buffers, images, buf_start, img_start,
                          front, engine)
    if p != len(data):
        raise ValueError('sync2 wait2 payload has trailing words')
    record['pay'] = data


def replay_sync2_wait2(images, stream, count, *, compute=False, device=None):
    """Replay the `count` VkDependencyInfo blocks trailing a vkCmdWaitEvents2
    event-id list.  `stream` is the retained pay slice starting at the first
    dependencyFlags word; each block is self-delimiting (see
    dep_info_stream).  The leading resolved event handles and the EventWait
    op itself are emitted by the caller."""
    blocks, end = dep_info_stream(stream, 0, count)
    if end != len(stream):
        raise ValueError('sync2 wait2 dependency-info stream is malformed')
    for flags, memory, buffers, images_, mem, buf, img in blocks:
        if flags or memory + buffers + images_ > 16:
            raise ValueError('sync2 wait2 dependency/barrier count exceeds profile')
        flat = list(mem) + list(buf) + list(img)
        _sync2_barriers(images, flat, memory, buffers, images_,
                        compute=compute, device=device)
