#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""DrawPlan -> DrawExec conversion for bounded native draw replay.

Converts one recorded draw plan into a single executor operation chaining
fetch, vertex shade, raster, fragment shade and writeback.  All six
bounded topologies (POINT/LINE/LINE_STRIP/TRIANGLE_LIST/TRIANGLE_STRIP/
TRIANGLE_FAN) are admitted; descriptor bindings, stencil, MRT, texture/
sampling, occlusion/multi-subpass, instancing/indirect and fragment
discard/quad-derivatives are implemented.  A bounded float32 late-z depth
test plus depth-bounds window, bounded single-output UNORM8 RGBA/BGRA
blend, colourWriteMask and logicOp are forwarded when the
pipeline enables them and the active subpass/framebuffer supply the
matching attachments.  Up to four active subpass colour outputs are
admitted (MRT): every target is written atomically per fragment under the
shared depth/stencil/bounds/logicOp gate, with per-attachment
colourWriteMask, per-attachment blend and pipeline-global logicOp."""
import struct

from vn_graphics_drawexec import DrawExec
from vn_graphics_fetch import Fetch, FetchVertex


def _push(stages):
    result = {}
    for stage in stages:
        result[stage.stage] = (stage.push, stage.bindings)
    if 1 not in result or 16 not in result:
        raise ValueError('graphics draw stage bindings are incomplete')
    vs_push, vs_bindings = result[1]
    fs_push, fs_bindings = result[16]
    return vs_push, fs_push, vs_bindings, fs_bindings


def _scissor(plan):
    """Effective scissor: recorded scissor intersected with the render
    area, in framebuffer coordinates."""
    sx, sy, sw, sh = plan.scissor
    ax, ay, aw, ah = plan.pass_state.area
    x, y = max(sx, ax), max(sy, ay)
    w = min(sx + sw, ax + aw) - x
    h = min(sy + sh, ay + ah) - y
    if w <= 0 or h <= 0:
        return None
    return (x, y, w, h)


def _color_targets(plan):
    """Active color outputs -> framebuffer attachments, in subpass order.
    FS must declare exactly the active output locations; the bounded
    profile admits up to four (MRT) UNORM8 outputs."""
    colors = plan.pass_state.render_pass_state.subpass_colors(plan.subpass)
    active = [(loc, ref[0]) for loc, ref in enumerate(colors)
              if ref[0] != 0xFFFFFFFF]
    if not 1 <= len(active) <= 4:
        raise ValueError('graphics draw color outputs exceed profile')
    outputs = plan.pipeline.interfaces.colors
    if sorted(o[0] for o in outputs) != sorted(loc for loc, _ in active):
        raise ValueError('graphics draw fragment outputs exceed active subpass')
    targets = []
    for location, attachment_index in active:
        if attachment_index >= len(plan.attachments):
            raise ValueError('graphics draw color attachment exceeds framebuffer')
        targets.append((location, plan.attachments[attachment_index]))
    return targets


def operation(engine, context_id, plan, remember, guards):
    """Validate `plan` and return a DrawExec op, or None when the draw's
    effective scissor is empty (no fragments can be produced)."""
    snapshot = plan.pipeline
    vs_push, fs_push, vs_bindings, fs_bindings = _push(
        plan.stage_bindings.stages)
    scissor = _scissor(plan)
    if scissor is None:
        for ref, kind in plan.references:
            remember(ref, kind)
        guards.append(plan.validate)
        return None
    targets = _color_targets(plan)
    location, attachment = targets[0]
    fixed = snapshot.fixed
    # per-attachment blend states aligned with the active targets: the
    # primary keeps `blend`, attachments 1..N-1 keep `blend_extra`.  Only
    # the plain UNORM8 four-component outputs (device fmt 2 RGBA / fmt 4
    # BGRA) have a defined dst decode; refuse others on every blended
    # attachment.
    blend_states = ((fixed.blend,) +
                    (fixed.blend_extra or ()))[:len(targets)]
    for k, (_loc, att) in enumerate(targets):
        if (k < len(blend_states) and blend_states[k] is not None and
                att.fmt not in (2, 4)):
            raise ValueError('graphics blend format exceeds profile')
        if fixed.logic_op is not None and att.fmt not in (2, 4):
            raise ValueError('graphics logicOp format exceeds profile')
    # attachments 1..N-1 become extra writeback targets carrying their own
    # writeMask and optional per-attachment blend state.  Shape matches
    # Writeback.extras: (owner, offset, pitch, fmt, location, write_mask).
    extra_targets = tuple(
        (att.owner, att.offset, att.pitch, att.fmt, loc,
         fixed.color_masks[loc]) for loc, att in targets[1:])
    # bounded late-z / stencil: a pipeline depth test or stencil test needs
    # a matching depth-stencil attachment on the active subpass; the
    # framebuffer already resolved it to a geometry operand alongside the
    # colour one.  depth_fmt is the device format (12 = D32_SFLOAT float32,
    # 14 = D24S8 packed); stencilTestEnable alone (no depth test or write)
    # still activates the packed path with an ALWAYS/no-write depth tuple.
    depth = None
    depth_fmt = 12
    if fixed.depth is not None or fixed.stencil is not None:
        dref = plan.pass_state.render_pass_state.subpass_depth(plan.subpass)
        if dref is not None:
            depth_att = plan.attachments[dref[0]]
            if fixed.depth is not None:
                _dte, dwe, dco = fixed.depth
            else:
                # stencil-only: depth always passes and never writes
                dwe, dco = 0, 7
            depth_fmt = depth_att.fmt
            depth = (depth_att.owner, depth_att.offset, depth_att.pitch,
                     dco, dwe)
    if fixed.stencil is not None and depth is None:
        raise ValueError('graphics stencil needs a depth-stencil attachment')
    vertices = tuple(FetchVertex(vertex.location, vertex.format,
                                 vertex.offset, vertex.stride, vertex.rate,
                                 vertex.span)
                     for vertex in plan.vertices)
    indexed = 'Indexed' in plan.command
    if plan.indirect is not None:
        direct, indirect = None, plan.indirect
    elif indexed:
        direct = tuple(plan.values)
        indirect = None
    else:
        direct = (plan.values[0], plan.values[1], plan.values[2], 0,
                  plan.values[3])
        indirect = None
    fetch = Fetch(indexed, plan.indices, vertices, direct, indirect,
                  fixed.restart)
    viewport = struct.unpack('<6f', struct.pack('<6I', *plan.viewport))
    framebuffer = plan.framebuffer.framebuffer
    op = DrawExec(fetch, snapshot.vertex.code, snapshot.fragment.code,
                  viewport, scissor, attachment.owner, attachment.offset,
                  attachment.pitch, framebuffer.width, framebuffer.height,
                  attachment.fmt, vs_push=vs_push, fs_push=fs_push,
                  vs_bindings=vs_bindings, fs_bindings=fs_bindings,
                  flat=snapshot.flat, nopersp=snapshot.nopersp,
                  front_ccw=1 - fixed.front_face,
                  cull=fixed.cull, location=location, depth=depth,
                  blend=fixed.blend,
                  write_mask=fixed.color_masks[location],
                  logic_op=fixed.logic_op, discard=fixed.discard,
                  extra_targets=extra_targets,
                  bounds=fixed.bounds, depth_bias=fixed.depth_bias,
                  depth_clamp=fixed.depth_clamp, poly_mode=fixed.poly_mode,
                  topology=fixed.topology, depth_fmt=depth_fmt,
                  stencil=fixed.stencil, blend_extra=fixed.blend_extra)
    for ref, kind in plan.references:
        remember(ref, kind)
    guards.append(plan.validate)
    return op
