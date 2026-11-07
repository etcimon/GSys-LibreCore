# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded render-pass recording metadata; no attachment writes or draw admission."""
from dataclasses import dataclass

from vn_graphics_dynamic import Recording, recording_identity, validate_recording
from vn_native_rendering import FramebufferOperand, RenderPass, framebuffer_operand


@dataclass(frozen=True)
class BeginPass(Recording):
    render_pass: int
    framebuffer: int
    render_pass_state: object
    framebuffer_state: object
    area: tuple
    clears: tuple


@dataclass(frozen=True)
class EndPass(Recording):
    begin: BeginPass
    subpass: int


@dataclass(frozen=True)
class NextPass(Recording):
    begin: BeginPass
    subpass: int


@dataclass(frozen=True)
class ClearAttachments(Recording):
    begin: BeginPass
    subpass: int
    attachments: tuple
    rects: tuple


def _clear_packet(engine, words):
    decoder = engine.golden.Sim(engine.model, engine.assembly)
    decoded = decoder.run(words, want_trace=True)
    if decoded['fault'] or decoded['words'] != len(words):
        raise ValueError('clear attachments command packet is malformed')
    ops = [(engine.assembly['dec_ops'][pc][3].split(':')[0], op, position)
           for pc, op, position in decoder.trace]
    if (len(ops) < 5 or ops[0][1] != 'HANDLE' or ops[1][1] != 'U32' or
            ops[1][0] != 'attachmentCount' or ops[2][1] != 'ARRAY' or
            ops[2][0] != 'pAttachments'):
        raise ValueError('clear attachments command packet is malformed')
    count = words[ops[1][2]]
    if not 0 < count <= 4:
        raise ValueError('clear attachments count exceeds native profile')
    i = 3
    attachments = []
    for _ in range(count):
        if (i + 5 >= len(ops) or ops[i][1] != 'U32' or ops[i][0] != 'aspectMask' or
                ops[i + 1][1] != 'U32' or ops[i + 1][0] != 'colorAttachment' or
                ops[i + 2][1] != 'CHECK' or words[ops[i + 2][2]] != 0 or
                ops[i + 3][1] != 'CHECK' or words[ops[i + 3][2]] != 2 or
                ops[i + 4][1] != 'BLOB' or ops[i + 5][1] != 'ENDARR'):
            raise ValueError('clear attachments element is malformed')
        pos = ops[i + 4][2]
        if words[pos] != 4 or pos + 6 > len(words):
            raise ValueError('clear attachments value blob is malformed')
        attachments.append((words[ops[i][2]], words[ops[i + 1][2]],
                            tuple(words[pos + 2:pos + 6])))
        i += 6
    if (i + 1 >= len(ops) or ops[i][1] != 'U32' or ops[i][0] != 'rectCount' or
            ops[i + 1][1] != 'ARRAY' or ops[i + 1][0] != 'pRects'):
        raise ValueError('clear attachments rect array is malformed')
    rects = words[ops[i][2]]
    if not 0 < rects <= 16:
        raise ValueError('clear attachments rect count exceeds native profile')
    i += 2
    fields = []
    for _ in range(rects):
        if (i + 6 >= len(ops) or
                any(ops[i + j][1] != 'U32' for j in range(6)) or
                ops[i + 6][1] != 'ENDARR'):
            raise ValueError('clear attachments rect fields are malformed')
        fields.extend(words[ops[i + j][2]] for j in range(6))
        i += 7
    if i >= len(ops) or ops[i][1] != 'END':
        raise ValueError('clear attachments packet is malformed')
    return (tuple(attachments),
            tuple(tuple(fields[6 * j:6 * j + 6]) for j in range(rects)))


def _capture_clear(engine, current, words, record):
    identity = recording_identity(engine, current, record)
    active = _active(identity[3])
    if not isinstance(active, BeginPass):
        raise ValueError('clear attachments command has no active render pass')
    index = _subpass_index(identity[3], active)
    attachments, rects = _clear_packet(engine, words)
    rp = active.render_pass_state
    colors = rp.subpass_colors(index)
    seen, items = set(), []
    for aspect, target, clear in attachments:
        if (aspect != 1 or not 0 <= target < len(colors) or
                colors[target][0] == 0xFFFFFFFF or target in seen):
            raise ValueError('clear attachments target exceeds color profile')
        seen.add(target)
        items.append((target, clear))
    out = []
    for x, y, width, height, base, layers in rects:
        if base or layers != 1 or x < 0 or y < 0 or width <= 0 or height <= 0:
            raise ValueError('clear attachments rect/layer exceeds native profile')
        out.append((x, y, width, height))
    return ClearAttachments(*identity, active, index, tuple(items), tuple(out))


def _capture_next(engine, current, words, record):
    identity = recording_identity(engine, current, record)
    active = _active(identity[3])
    if not isinstance(active, BeginPass):
        raise ValueError('render pass command next subpass has no active pass')
    index = _subpass_index(identity[3], active)
    if index + 1 >= active.render_pass_state.subpass_count:
        raise ValueError('render pass command next subpass exceeds subpass count')
    return NextPass(*identity, active, index + 1)


def _active(records):
    for record in reversed(records):
        state = record.get('native_render_pass')
        if isinstance(state, EndPass):
            return None
        if isinstance(state, BeginPass):
            return state
    return None


def _subpass_index(records, begin):
    return sum(1 for record in records
               if isinstance(record.get('native_render_pass'), NextPass) and
               record['native_render_pass'].begin is begin)


def _packet(engine, words, count):
    decoder = engine.golden.Sim(engine.model, engine.assembly)
    decoded = decoder.run(words, want_trace=True)
    if decoded['fault'] or decoded['words'] != len(words):
        raise ValueError('render pass command packet is malformed')
    fields = {}
    for pc, op, position in decoder.trace:
        name = engine.assembly['dec_ops'][pc][3].split(':')[0]
        if op == 'CHECK' and name.startswith('VkClearValue tag ') and words[position] != 0:
            raise ValueError('render pass command requires color clear values')
        if op == 'U32':
            value = words[position]
        elif op in ('PTR', 'PNEXT', 'ARRAY', 'BLOB'):
            value = words[position] | words[position + 1] << 32
        else:
            continue
        fields.setdefault(name, []).append(value)
    if (fields.get('pRenderPassBegin') != [1] or any(fields.get('pNext', ())) or
            fields.get('contents') != [0] or fields.get('clearValueCount') != [count] or
            fields.get('pClearValues') != [count] or
            any(value != 4 for name in ('float32', 'int32', 'uint32')
                for value in fields.get(name, ()))):
        raise ValueError('render pass command contents/counts/chain exceed profile')


def capture(engine, current, name, words, record):
    if name == 'vkCmdNextSubpass':
        return _capture_next(engine, current, words, record)
    if name == 'vkCmdClearAttachments':
        return _capture_clear(engine, current, words, record)
    if name not in ('vkCmdBeginRenderPass', 'vkCmdEndRenderPass', 'vkEndCommandBuffer'):
        return None
    identity = recording_identity(engine, current, record)
    active = _active(identity[3])
    if name == 'vkEndCommandBuffer':
        if active is not None:
            raise ValueError('render pass command scope remains open')
        return None
    if name == 'vkCmdEndRenderPass':
        if active is None:
            raise ValueError('render pass command end has no begin')
        return EndPass(*identity, active, _subpass_index(identity[3], active))
    if active is not None:
        raise ValueError('render pass command begin is nested')
    pay = record['pay']
    if len(pay) < 9 or record['chain']:
        raise ValueError('render pass command payload/chain exceeds profile')
    count = pay[8]
    if count > 4 or len(pay) != 9 + 4 * count:
        raise ValueError('render pass command clear payload exceeds profile')
    _packet(engine, words, count)
    context, device = identity[:2]
    front, kinds = current.frontend, engine.golden.KIND
    rp_raw, fb_raw = pay[0] | pay[1] << 32, pay[2] | pay[3] << 32
    status, slot, entry = front.resolve(rp_raw, kinds['VkRenderPass'])
    if status != 'OK' or entry['ctx'] != front.ctx:
        raise KeyError('render pass command generation/context is stale')
    render_pass = entry['gen'] << 16 | slot
    rp = entry.get('native_rendering')
    operand = framebuffer_operand(engine, front.ctx, fb_raw)
    fb = operand.framebuffer
    if (not isinstance(rp, RenderPass) or rp.context is not context or rp.device != device or
            fb.device != device or not rp.compatible(fb.render_pass) or
            tuple(a[:2] for a in rp.attachments) != tuple(a[:2] for a in fb.render_pass.attachments)):
        raise ValueError('render pass command framebuffer compatibility/device exceeds profile')
    x, y, width, height = pay[4:8]
    if (not width or not height or x > fb.width or y > fb.height or
            width > fb.width - x or height > fb.height - y):
        raise ValueError('render pass command area exceeds framebuffer')
    required = max((i + 1 for i, a in enumerate(rp.attachments) if a[2] == 1), default=0)
    if not required <= count <= len(rp.attachments):
        raise ValueError('render pass command clear count does not cover load operations')
    status, fb_slot, fb_entry = front.resolve(fb_raw, kinds['VkFramebuffer'])
    if status != 'OK' or fb_entry['ctx'] != front.ctx:
        raise KeyError('render pass command framebuffer generation/context is stale')
    return BeginPass(*identity, render_pass, fb_entry['gen'] << 16 | fb_slot, rp, fb,
                     (x, y, width, height), tuple(tuple(pay[i:i + 4]) for i in range(9, len(pay), 4)))


def attach(out, snapshot):
    if snapshot is not None and not out['fault'] and not out['result'] and out.get('record') is not None:
        out['record']['native_render_pass'] = snapshot


def operand(engine, context_id, snapshot):
    if not isinstance(snapshot, BeginPass):
        raise ValueError('render pass command has no begin identity')
    validate_recording(engine, context_id, snapshot)
    front, kinds = engine.contexts[context_id].frontend, engine.golden.KIND
    result = framebuffer_operand(engine, context_id, snapshot.framebuffer)
    if result.framebuffer is not snapshot.framebuffer_state:
        raise KeyError('render pass command framebuffer changed')
    validate_recording(engine, context_id, snapshot)
    _, _, cb = front.resolve(snapshot.command_buffer, kinds['VkCommandBuffer'])
    pool = front.ent[cb['parent']]
    references = result.references + (
        (snapshot.render_pass, kinds['VkRenderPass']),
        (snapshot.command_buffer, kinds['VkCommandBuffer']),
        (pool['gen'] << 16 | cb['parent'], kinds['VkCommandPool']))

    def validate():
        validate_recording(engine, context_id, snapshot)
        status, _, entry = front.resolve(snapshot.render_pass, kinds['VkRenderPass'])
        if (status != 'OK' or entry['ctx'] != context_id or
                entry.get('native_rendering') is not snapshot.render_pass_state or
                entry['parent'] != snapshot.device & 0xFFFF):
            raise KeyError('render pass command identity changed')
        result.validate()

    validate()
    return FramebufferOperand(result.framebuffer, result.attachments, references, validate)
