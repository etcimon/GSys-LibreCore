# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Dynamic-rendering (vkCmdBeginRendering) command-side RenderPass/Framebuffer
synthesis.  There is no VkRenderPass/VkFramebuffer object: the VkRenderingInfo
payload is decoded once at begin, resolved to live image/memory identities, and
folded into the same RenderPass/Framebuffer/FramebufferOperand shapes the
static render-pass path consumes, so graphics draws route unchanged."""
from dataclasses import dataclass

from vn_graphics_dynamic import Recording, recording_identity
from vn_native_rendering import (Attachment, ColorAttachment, Framebuffer,
                                 FramebufferOperand, RenderPass)


@dataclass(frozen=True)
class BeginRendering(Recording):
    render_pass_state: object
    framebuffer_state: object
    operand: object
    area: tuple
    # per-slot (loadOp, storeOp, clearValue) retained for the attachment
    # clear/store follow-up; colour slots precede the optional depth slot,
    # matching render_pass_state.attachments ordering.
    attachment_ops: tuple
    layer_count: int
    view_mask: int


@dataclass(frozen=True)
class EndRendering(Recording):
    begin: BeginRendering


def _d2vk(model):
    """device format id -> admitting VkFormat (inverse of img_fmt_id)."""
    _names, vk2d, _bpp, _attr = model.img_fmt_tables()
    return {d: v for v, d in enumerate(vk2d) if d != 0xFF}


def _ops(engine, words):
    """Sim decode trace -> [(field_name, op, word_position)]."""
    decoder = engine.golden.Sim(engine.model, engine.assembly)
    decoded = decoder.run(words, want_trace=True)
    if decoded['fault'] or decoded['words'] != len(words):
        raise ValueError('dynamic rendering command packet is malformed')
    ops = []
    for pc, op, position in decoder.trace or ():
        if pc >= len(engine.assembly['dec_ops']):
            continue
        name = engine.assembly['dec_ops'][pc][3].split(':')[0]
        ops.append((name, op, position))
    return ops


def _u64(words, position):
    return words[position] | words[position + 1] << 32


def _attachment(ops, words, start):
    """Parse one inlined VkRenderingAttachmentInfo at trace index `start`
    (which points at its STYPE).  Returns (fields, next_index); fields carries
    imageView/loadOp/storeOp/clearValue plus the layout/resolve scalars."""
    fields = {}
    i = start
    while i < len(ops):
        name, op, pos = ops[i]
        if i != start and (name == 'sType' or op in ('ENDARR', 'END', 'PTR')):
            break
        if op == 'HANDLE' and name == 'imageView':
            fields['imageView'] = _u64(words, pos)
        elif op == 'HANDLE' and name == 'resolveImageView':
            fields['resolveImageView'] = _u64(words, pos)
        elif op == 'U32':
            fields[name] = words[pos]
        elif op == 'CHECK':
            fields.setdefault('clear_tags', []).append(name)
        elif op == 'BLOB':
            count = words[pos]
            if count > 8:
                raise ValueError('dynamic rendering clear value exceeds profile')
            fields['clear'] = tuple(words[pos + 2:pos + 2 + count])
        i += 1
    for key in ('imageView', 'imageLayout', 'loadOp', 'storeOp'):
        if key not in fields:
            raise ValueError('dynamic rendering attachment field missing: ' + key)
    return fields, i


def _rendering_info(engine, words):
    """Decode the VkRenderingInfo packet into scalar header fields plus the
    ordered colour/depth/stencil VkRenderingAttachmentInfo records."""
    ops = _ops(engine, words)
    array_i = next((i for i, (n, o, p) in enumerate(ops)
                    if n == 'pColorAttachments' and o == 'ARRAY'), None)
    if array_i is None:
        raise ValueError('dynamic rendering colour attachment array is absent')
    ncolor = words[ops[array_i][2]]
    if not 0 < ncolor <= 4:
        raise ValueError('dynamic rendering colour attachment count exceeds profile')
    header = {}
    for key in ('flags', 'x', 'y', 'width', 'height',
                'layerCount', 'viewMask', 'colorAttachmentCount'):
        hits = [p for n, o, p in ops[:array_i] if n == key and o == 'U32']
        if len(hits) != 1:
            raise ValueError('dynamic rendering header field is incomplete: ' + key)
        header[key] = words[hits[0]]
    if header['colorAttachmentCount'] != ncolor:
        raise ValueError('dynamic rendering colour count disagrees with array')
    if header['flags'] or header['viewMask'] or header['layerCount'] != 1:
        raise ValueError('dynamic rendering flags/viewMask/layerCount exceed profile')
    if not header['width'] or not header['height']:
        raise ValueError('dynamic rendering render area is empty')

    # each colour element closes with its own ENDARR, so the array region
    # ends at the first depth/stencil attachment PTR (or the packet END)
    # rather than at a single array terminator.
    boundary = next((k for k in range(array_i + 1, len(ops))
                     if ops[k][1] == 'END' or
                     (ops[k][0] in ('pDepthAttachment', 'pStencilAttachment')
                      and ops[k][1] == 'PTR')), len(ops))
    colors, i = [], array_i + 1
    for _ in range(ncolor):
        while i < boundary and ops[i][0] != 'sType':
            i += 1
        if i >= boundary:
            raise ValueError('dynamic rendering colour attachment is truncated')
        fields, i = _attachment(ops, words, i)
        colors.append(fields)

    depth = stencil = None
    j = boundary
    for key in ('pDepthAttachment', 'pStencilAttachment'):
        ptr = next((k for k in range(j, len(ops))
                    if ops[k][0] == key and ops[k][1] == 'PTR'), None)
        if ptr is None:
            raise ValueError('dynamic rendering attachment pointer is absent: ' + key)
        present = words[ops[ptr][2]] != 0
        j = ptr + 1
        if present:
            while j < len(ops) and ops[j][0] != 'sType':
                j += 1
            fields, j = _attachment(ops, words, j)
            if key == 'pDepthAttachment':
                depth = fields
            else:
                stencil = fields
    return header, tuple(colors), depth, stencil


def _attachment_for(engine, context_id, device, fields, need_usage, d2vk):
    """Resolve one VkRenderingAttachmentInfo.imageView to a live Attachment
    plus its recovered VkFormat and (loadOp, storeOp, clearValue) record."""
    front, kinds = (engine.contexts[context_id].frontend,
                    engine.golden.KIND)
    parent = device & 0xFFFF

    def resolve(value, kind):
        status, slot, entry = front.resolve(value, kinds[kind])
        if status != 'OK' or entry['ctx'] != context_id:
            raise KeyError('dynamic rendering attachment generation/context is stale')
        return entry['gen'] << 16 | slot, entry

    view, ve = resolve(fields['imageView'], 'VkImageView')
    image, ie = resolve(ve.get('native_view_image', 0), 'VkImage')
    slot = ie.get('bind_mem', -1)
    if not 0 <= slot < front.SLOTS:
        raise ValueError('dynamic rendering image has no live memory binding')
    memory, me = resolve(ie.get('bind_mgen', 0) << 16 | slot, 'VkDeviceMemory')
    aux, va = ie['aux'], ve['aux']
    mip, layer = va >> 28 & 15, va >> 36 & 1023
    dev_fmt = aux >> 32 & 255
    vkfmt = d2vk.get(dev_fmt)
    if vkfmt is None:
        raise ValueError('dynamic rendering image format is outside profile')
    if (any(value['parent'] != parent for value in (ve, ie, me)) or
            ie['state'] >> 19 & 3 != 1 or va & 0xFFFF != image & 0xFFFF or
            va >> 56 & 7 or va >> 16 & 0xFFF or
            va >> 32 & 15 != 1 or va >> 46 & 1023 != 1 or
            mip >= aux >> 40 & 31 or layer >= aux >> 45 & 511 or
            not aux >> 54 & need_usage or
            fields.get('resolveImageView', 0) or
            ie.get('bind_off', 0) + ie['size'] > me['size']):
        raise ValueError('dynamic rendering view/image/device/range exceeds profile')
    attachment = Attachment(view, image, memory, va, aux, ie['state'],
                            ie['size'], ie.get('bind_off', 0))
    ops = (fields['loadOp'], fields['storeOp'], fields.get('clear', ()))
    return attachment, vkfmt, ops


def _active(records):
    for record in reversed(records):
        state = record.get('native_dynamic_render')
        if isinstance(state, EndRendering):
            return None
        if isinstance(state, BeginRendering):
            return state
    return None


def capture(engine, current, name, words, record):
    if name == 'vkCmdEndRendering':
        identity = recording_identity(engine, current, record)
        active = _active(identity[3])
        if not isinstance(active, BeginRendering):
            raise ValueError('dynamic rendering end has no active begin')
        return EndRendering(*identity, active)
    if name == 'vkCmdSetRenderingAttachmentLocations':
        return None
    if name != 'vkCmdBeginRendering':
        return None
    identity = recording_identity(engine, current, record)
    context_id = current.frontend.ctx
    context, device = identity[:2]
    if _active(identity[3]) is not None:
        raise ValueError('dynamic rendering begin is nested')
    if record['chain']:
        raise ValueError('dynamic rendering chain exceeds profile')
    header, colors, depth, stencil = _rendering_info(engine, words)
    if depth is not None and stencil is not None and (
            stencil['imageView'] != depth['imageView']):
        raise ValueError('dynamic rendering split depth/stencil exceeds profile')
    ds = depth if depth is not None else stencil
    d2vk = _d2vk(engine.model)
    color_attachments, color_ops, formats = [], [], []
    for fields in colors:
        attachment, vkfmt, ops = _attachment_for(
            engine, context_id, device, fields, 16, d2vk)
        color_attachments.append(attachment)
        color_ops.append(ops)
        formats.append(vkfmt)

    attachments = [(fmt, 1, 0, 0, 0, 0, 0, 0) for fmt in formats]
    color_refs = tuple((i, 2) for i in range(len(formats)))
    depths = (None,)
    fb_attachments = list(color_attachments)
    attachment_ops = list(color_ops)
    if ds is not None:
        didx = len(formats)
        attachment, vkfmt, ops = _attachment_for(
            engine, context_id, device, ds, 32, d2vk)
        attachments.append((vkfmt, 1, 0, 0, 0, 0, 0, 0))
        depths = ((didx, 3),)
        fb_attachments.append(attachment)
        attachment_ops.append(ops)
    render_pass = RenderPass(context, device, tuple(attachments), color_refs,
                             (color_refs,), (), depths)
    width, height = header['width'], header['height']
    framebuffer = Framebuffer(context, device, render_pass,
                              tuple(fb_attachments), width, height)
    operand = dynamic_framebuffer_operand(engine, context_id, framebuffer)
    return BeginRendering(*identity, render_pass, framebuffer, operand,
                          (header['x'], header['y'], width, height),
                          tuple(attachment_ops), header['layerCount'],
                          header['viewMask'])


def dynamic_framebuffer_operand(engine, context_id, framebuffer):
    """FramebufferOperand for a synthesized dynamic-rendering Framebuffer.
    Mirrors vn_native_rendering.framebuffer_operand but resolves the
    Framebuffer snapshot directly (no VkFramebuffer object exists)."""
    context = engine.contexts[context_id]
    front, kinds = context.frontend, engine.golden.KIND
    references, entries = [], []

    def resolve(value, kind):
        status, slot, entry = front.resolve(value, kinds[kind])
        if status != 'OK' or entry['ctx'] != context_id:
            raise KeyError('framebuffer operand generation/context is stale')
        references.append((entry['gen'] << 16 | slot, kinds[kind]))
        return entry

    if (not isinstance(framebuffer, Framebuffer) or
            framebuffer.context is not context or
            not engine.transfers._live(context)):
        raise ValueError('dynamic framebuffer has no live native identity')
    resolve(framebuffer.device, 'VkDevice')
    colors = []
    for source in framebuffer.attachments:
        ve, ie, me = (resolve(value, kind) for value, kind in (
            (source.view, 'VkImageView'), (source.image, 'VkImage'),
            (source.memory, 'VkDeviceMemory')))
        entries.append((source, ve, ie, me))
        aux, va = source.image_aux, source.view_aux
        width, height, fmt = aux & 0xFFFF, aux >> 16 & 0xFFFF, aux >> 32 & 255
        mips, layers = aux >> 40 & 31, aux >> 45 & 511
        mip, layer = va >> 28 & 15, va >> 36 & 1023
        stride = engine.golden.img_layer_bytes(engine.model, width, height,
                                               fmt, mips)
        offset = source.binding + layer * stride + sum(
            engine.golden.img_mpitch(engine.model, width, fmt, level) *
            max(1, height >> level) for level in range(mip))
        pitch = engine.golden.img_mpitch(engine.model, width, fmt, mip)
        size = pitch * framebuffer.height
        if (source.image_size != stride * layers or
                source.image_state & 0x7FFFF != stride >> 6 or
                source.binding + source.image_size > me['size']):
            raise ValueError('dynamic framebuffer image footprint is inconsistent')
        owner = engine.memory(context_id, source.memory)
        engine.transfers._extent(context, owner, offset, size)
        colors.append(ColorAttachment(owner, offset, size, pitch, fmt))

    device_parent = framebuffer.device & 0xFFFF

    def validate():
        if (not engine.transfers._live(context) or
                framebuffer.context is not context):
            raise KeyError('dynamic framebuffer identity changed during admission')
        for value, kind in references:
            if front.resolve(value, kind)[0] != 'OK':
                raise KeyError('dynamic framebuffer operand retired during admission')
        for source, ve, ie, me in entries:
            if (any(e['parent'] != device_parent for e in (ve, ie, me)) or
                    ve.get('native_view_image') != source.image or
                    ve['aux'] != source.view_aux or
                    ie['aux'] != source.image_aux or
                    ie['state'] != source.image_state or
                    ie['size'] != source.image_size or
                    ie.get('bind_off') != source.binding or
                    ie.get('bind_mem') != source.memory & 0xFFFF or
                    ie.get('bind_mgen') != source.memory >> 16):
                raise KeyError('dynamic framebuffer attachment provenance changed')
        if any(color.owner.deferred_free is not None for color in colors):
            raise KeyError('dynamic framebuffer backing is pending free')

    validate()
    return FramebufferOperand(framebuffer, tuple(colors), tuple(references),
                              validate)


def attach(out, snapshot):
    if snapshot is not None and not out['fault'] and not out['result'] and \
            out.get('record') is not None:
        out['record']['native_dynamic_render'] = snapshot


def _begin_rendering(engine, context_id, state, remember, append, guards):
    # loadOp=CLEAR attachments are filled with their clearValue over the
    # render area before the first draw.  Colour and depth-stencil slots
    # share the packed-clear path: img_clear_texel consumes the wire
    # colour.uint32 union arm, where uint32[0] is the float32 depth bits
    # (fmt12 verbatim, fmt14 -> unorm24) and uint32[1][7:0] the stencil.
    from vn_render_pass_replay import _emit
    result = state.operand
    for ref, kind in result.references:
        remember(ref, kind)
    guards.append(result.validate)
    x, y, width, height = state.area
    for attachment, ops in zip(result.attachments, state.attachment_ops):
        load_op = ops[0] if ops else 0
        if load_op != 1:
            continue
        for op in _emit(engine, attachment, (x, y, width, height), ops[2]):
            append(op)


def replay(engine, context_id, name, record, remember, append, guards):
    state = record.get('native_dynamic_render')
    if name == 'vkCmdBeginRendering':
        if not isinstance(state, BeginRendering):
            raise ValueError('dynamic rendering replay begin has no native identity')
        _begin_rendering(engine, context_id, state, remember, append, guards)
        return
    if name == 'vkCmdEndRendering':
        if not isinstance(state, EndRendering):
            raise ValueError('dynamic rendering replay end has no begin identity')
        return
