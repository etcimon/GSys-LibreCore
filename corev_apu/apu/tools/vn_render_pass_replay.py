#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded render-pass attachment clears; no draw or shader execution."""
from vn_transfer_executor import Transfer
from vn_render_pass_commands import BeginPass, ClearAttachments, EndPass, operand


def _operand(engine, context_id, begin, remember, guards):
    result = operand(engine, context_id, begin)
    for ref, kind in result.references:
        remember(ref, kind)
    guards.append(result.validate)
    return result


def _emit(engine, attachment, region, clear, gated=False):
    golden, model = engine.golden, engine.model
    _, _, bpp, _ = model.img_fmt_tables()
    fmt = attachment.fmt
    if not 0 <= fmt < len(bpp) or not bpp[fmt]:
        raise ValueError('render pass clear format exceeds native profile')
    x, y, width, height = region
    texel = golden.img_clear_texel(model, fmt, clear)
    size = width * bpp[fmt]
    for row in range(y, y + height):
        yield Transfer('pattern', attachment.owner,
                       attachment.offset + row * attachment.pitch + x * bpp[fmt],
                       size, data=texel, conditional=gated)


def _layouts(engine, context_id, fb, rp, remember, begin):
    # §12.3 render-pass layout transitions: at begin every attachment
    # must sit in initialLayout (UNDEFINED discards from any state) and
    # color-referenced attachments move to their subpass layout; at end
    # attachments must still hold that layout and publish finalLayout.
    # Validation resolves all entries before any publish so a duplicated
    # attachment cannot validate against its own update.
    resolved = []
    for i, attachment in enumerate(fb.attachments):
        initial, final = rp.attachments[i][6], rp.attachments[i][7]
        sub = next((layout for index, layout in rp.colors if index == i), None)
        _, entry = remember(attachment.image, engine.golden.KIND['VkImage'])
        resolved.append((entry, initial, final, sub))
    if begin:
        for entry, initial, _final, _sub in resolved:
            if initial != 0 and entry.get('layout', 0) != initial:
                raise ValueError('render pass attachment is not in initialLayout')
        for entry, _initial, _final, sub in resolved:
            if sub is not None:
                entry['layout'] = sub
        return
    for entry, initial, final, sub in resolved:
        current = entry.get('layout', 0)
        if sub is not None:
            if current != sub:
                raise ValueError('render pass attachment left its subpass layout')
        elif initial != 0 and current != initial:
            raise ValueError('render pass attachment changed during the pass')
        entry['layout'] = final


def _begin_pass(engine, context_id, state, remember, append, guards):
    result = _operand(engine, context_id, state, remember, guards)
    # layout transitions follow the BeginRenderPass render pass object —
    # its attachment descriptions govern initial/subpass/final layouts
    # while the framebuffer supplies the image attachments positionally
    _layouts(engine, context_id, result.framebuffer, state.render_pass_state,
             remember, True)
    specs, clears = state.render_pass_state.attachments, state.clears
    x, y, width, height = state.area
    for index, attachment in enumerate(result.attachments):
        if index >= len(specs) or specs[index][2] != 1 or index >= len(clears):
            continue
        for op in _emit(engine, attachment, (x, y, width, height), clears[index]):
            append(op)


def _clear_attachments(engine, context_id, state, remember, append, guards):
    result = _operand(engine, context_id, state.begin, remember, guards)
    colors = state.begin.render_pass_state.colors
    ax, ay, aw, ah = state.begin.area
    for target, clear in state.attachments:
        attachment_index = colors[target][0]
        if attachment_index >= len(result.attachments):
            raise ValueError('clear attachments target exceeds framebuffer')
        attachment = result.attachments[attachment_index]
        for x, y, width, height in state.rects:
            left, top = max(x, ax), max(y, ay)
            right, bottom = min(x + width, ax + aw), min(y + height, ay + ah)
            if right <= left or bottom <= top:
                continue
            for op in _emit(engine, attachment,
                            (left, top, right - left, bottom - top), clear,
                            gated=True):
                append(op)


def replay(engine, context_id, name, record, remember, append, guards):
    state = record.get('native_render_pass')
    if name == 'vkCmdEndRenderPass':
        if not isinstance(state, EndPass):
            raise ValueError('render pass replay end has no begin identity')
        begin = state.begin
        _layouts(engine, context_id, begin.framebuffer_state,
                 begin.render_pass_state, remember, False)
        return
    if name == 'vkCmdClearAttachments':
        if not isinstance(state, ClearAttachments):
            raise ValueError('clear attachments replay has no native identity')
        _clear_attachments(engine, context_id, state, remember, append, guards)
        return
    if not isinstance(state, BeginPass):
        raise ValueError('render pass replay begin has no native identity')
    _begin_pass(engine, context_id, state, remember, append, guards)
