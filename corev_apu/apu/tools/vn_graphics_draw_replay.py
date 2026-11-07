#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""DrawPlan -> DrawExec conversion for bounded native draw replay.

Converts one recorded draw plan into a single executor operation chaining
fetch, vertex shade, raster, fragment shade and writeback.  Descriptor
bindings, blending, depth/stencil, multiple color outputs, non-triangle
topology and helper lanes remain refused by the stage profiles."""
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


def _color_target(plan):
    """Exactly one active color output, written to its framebuffer
    attachment; FS must declare exactly that output location."""
    colors = plan.pass_state.render_pass_state.subpass_colors(plan.subpass)
    active = [(loc, ref[0]) for loc, ref in enumerate(colors)
              if ref[0] != 0xFFFFFFFF]
    if len(active) != 1:
        raise ValueError('graphics draw requires exactly one active color output')
    location, attachment_index = active[0]
    outputs = plan.pipeline.interfaces.colors
    if len(outputs) != 1 or outputs[0][0] != location:
        raise ValueError('graphics draw fragment outputs exceed single-color profile')
    if attachment_index >= len(plan.attachments):
        raise ValueError('graphics draw color attachment exceeds framebuffer')
    return location, plan.attachments[attachment_index]


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
    location, attachment = _color_target(plan)
    fixed = snapshot.fixed
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
    fetch = Fetch(indexed, plan.indices, vertices, direct, indirect)
    viewport = struct.unpack('<6f', struct.pack('<6I', *plan.viewport))
    framebuffer = plan.framebuffer.framebuffer
    op = DrawExec(fetch, snapshot.vertex.code, snapshot.fragment.code,
                  viewport, scissor, attachment.owner, attachment.offset,
                  attachment.pitch, framebuffer.width, framebuffer.height,
                  attachment.fmt, vs_push=vs_push, fs_push=fs_push,
                  vs_bindings=vs_bindings, fs_bindings=fs_bindings,
                  flat=0, nopersp=0, front_ccw=1 - fixed.front_face,
                  cull=fixed.cull, location=location)
    for ref, kind in plan.references:
        remember(ref, kind)
    guards.append(plan.validate)
    return op
