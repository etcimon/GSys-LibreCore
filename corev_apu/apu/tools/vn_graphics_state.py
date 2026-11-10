# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded native fixed-state values; no draw/interface/execution admission."""
import math
import struct
from dataclasses import dataclass


@dataclass(frozen=True)
class GraphicsState:
    bindings: tuple
    attributes: tuple
    cull: int
    front_face: int
    color_masks: tuple
    dynamic: tuple
    # optional bounded late-z depth test: (depthTestEnable, depthWriteEnable,
    # depthCompareOp) or None when the pipeline declares no depth-stencil
    # state / neither a depth test nor a depth write is requested.  The
    # compare op is ALWAYS when the test is disabled so a lone depth write
    # still commits.  Stencil stays refused.
    depth: object = None
    # optional bounded depth-bounds window (minDepthBounds, maxDepthBounds)
    # when depthBoundsTestEnable=1: a covered fragment whose window-space
    # depth falls outside [min, max] is discarded before colour/depth
    # writeback.  Independent of the depth test; None keeps it off.
    bounds: object = None
    # optional bounded blend for the single active colour output:
    # (srcColorFactor, dstColorFactor, colorOp, srcAlphaFactor,
    #  dstAlphaFactor, alphaOp, writeMask, k0, k1, k2, k3) or None when
    # blendEnable is off.  k0..k3 are the raw fp32 blendConstants words.
    blend: object = None
    # per-attachment blend states for MRT attachments 1..N-1, aligned with
    # the extra_targets order: each entry is None (blendEnable=0) or the
    # same 11-tuple as `blend`.  None when the subpass has a single colour
    # output or no attachment enables blend.
    blend_extra: object = None
    # optional bounded logicOp (VkLogicOp code 0..14) when logicOpEnable=1
    # and no blend is enabled; None keeps the blend/write-through path.
    logic_op: object = None
    # rasterizerDiscardEnable: 1 discards every primitive before
    # rasterization (vertex shading still runs; zero fragments reach
    # writeback).  0 keeps normal rasterization.
    discard: int = 0
    # optional bounded depth bias: (constantFactor, clamp, slopeFactor)
    # fp32 triple when depthBiasEnable=1; the raster stage folds the
    # per-triangle slope term in and adds the result to window depth.
    depth_bias: object = None
    # depthClampEnable: 1 skips the near/far depth-range clip and clamps
    # each fragment's window depth into the viewport range; 0 keeps the
    # clip (a fragment whose window depth falls outside [minDepth,
    # maxDepth] is dropped).  Bounded to 0/1.
    depth_clamp: int = 0
    # polygonMode: 0 FILL keeps triangle coverage; 1 LINE rasterizes each
    # triangle edge as a Bresenham segment; 2 POINT emits one fragment per
    # vertex.  Bounded to 0..2 (VkPolygonMode FILL/LINE/POINT).
    poly_mode: int = 0
    # inputAssembly topology: 0 POINT_LIST emits one fragment per vertex;
    # 1 LINE_LIST draws independent 2-vertex segments; 2 LINE_STRIP chains
    # consecutive vertex pairs; 3 TRIANGLE_LIST keeps the 3-vertex
    # fill/line/point coverage; 4 TRIANGLE_STRIP slides a winding-corrected
    # vertex window; 5 TRIANGLE_FAN anchors every triangle at vertex 0.
    # Line/point primitives reuse the Bresenham and vertex-pixel coverage.
    topology: int = 3
    # optional bounded stencil state when stencilTestEnable=1:
    # (front_ops, back_ops) where each ops tuple is
    # (failOp, passOp, depthFailOp, compareOp, compareMask, writeMask,
    #  reference) — the VkStencilOpState fields plus the pipeline-level
    # stencil compare/write masks and reference.  Bounded to the D24S8
    # packed depth-stencil format; None keeps the depth-only path.
    stencil: object = None
    # primitiveRestartEnable: 1 lets indexed draws break the primitive
    # stream on the index-width sentinel (0xFFFF for 16-bit, 0xFFFFFFFF
    # for 32-bit indices) evaluated on the raw index before vertexOffset;
    # 0 keeps contiguous assembly.  Indexed draws only — non-indexed draws
    # ignore it per Vulkan semantics.
    restart: int = 0


def validate(engine, fields, blobs, render_pass, subpass=0):
    def one(name):
        values = fields.get(name, ())
        if len(values) != 1:
            raise ValueError('graphics fixed field/count mismatch: ' + name)
        return values[0]

    required = {
        'pVertexInputState': 1, 'pInputAssemblyState': 1,
        'pTessellationState': 0, 'pViewportState': 1,
        'pRasterizationState': 1, 'pMultisampleState': 1,
        'pColorBlendState': 1, 'pDynamicState': 1,
        'viewportCount': 1, 'pViewports': 0, 'scissorCount': 1, 'pScissors': 0,
        'lineWidth': 0x3F800000,
        'rasterizationSamples': 1, 'sampleShadingEnable': 0,
        'pSampleMask': 0, 'alphaToCoverageEnable': 0, 'alphaToOneEnable': 0,
        'dynamicStateCount': 2, 'pDynamicStates': 2,
        'blendConstants': 4,
    }
    for name, value in required.items():
        if one(name) != value:
            raise ValueError('graphics fixed state exceeds profile: ' + name)
    # optional depth-stencil state: the wire keeps the presence flag plus
    # the depth/bounds/stencil members.  The bounded profile admits a
    # plain depth test and a depth-bounds window; stencilTestEnable must
    # stay disabled and the stencil op fields are ignored.
    ds = fields.get('pDepthStencilState', ())
    if len(ds) > 1 or (ds and ds[0] not in (0, 1)):
        raise ValueError('graphics fixed depth-stencil presence exceeds profile')
    depth = bounds = stencil = None
    if ds and ds[0]:
        dte, dwe, dco = one('depthTestEnable'), one('depthWriteEnable'), one('depthCompareOp')
        dbte = one('depthBoundsTestEnable')
        ste = one('stencilTestEnable')
        if (dte not in (0, 1) or dwe not in (0, 1) or not 0 <= dco <= 7 or
                dbte not in (0, 1) or ste not in (0, 1)):
            raise ValueError('graphics fixed depth state exceeds profile')
        # depth write is independent of the depth test: keep the
        # attachment path live whenever a test OR a write is requested,
        # and let a disabled test compare ALWAYS so covered fragments pass.
        depth = (dte, dwe, dco if dte else 7) if (dte or dwe) else None
        if ste:
            # bounded stencil: the front/back VkStencilOpState fields arrive
            # as two-element [front, back] arrays; ops are VkStencilOp
            # 0..7, compareOp is VkCompareOp 0..7, and the compare/write
            # masks plus reference are stencil bytes 0..255.
            ops = []
            for name, limit in (('failOp', 7), ('passOp', 7),
                                ('depthFailOp', 7), ('compareOp', 7),
                                ('compareMask', 255), ('writeMask', 255),
                                ('reference', 255)):
                vals = fields.get(name, ())
                if (len(vals) != 2 or
                        any(not 0 <= v <= limit for v in vals)):
                    raise ValueError(
                        'graphics fixed stencil state exceeds profile: ' + name)
                ops.append(tuple(vals))
            # ops[i] is (front_i, back_i); regroup per face
            stencil = tuple(tuple(ops[f][i] for f in range(7))
                            for i in range(2))
        if dbte:
            bmin = struct.unpack('<f', struct.pack('<I',
                one('minDepthBounds')))[0]
            bmax = struct.unpack('<f', struct.pack('<I',
                one('maxDepthBounds')))[0]
            if not (math.isfinite(bmin) and math.isfinite(bmax) and
                    bmin <= bmax):
                raise ValueError('graphics fixed depth bounds exceed profile')
            bounds = (bmin, bmax)
    dynamic = blobs.get('pDynamicStates', ())
    if sorted(dynamic) != [0, 1]:
        raise ValueError('graphics fixed dynamic viewport/scissor must be distinct')
    cull, front = one('cullMode'), one('frontFace')
    if cull not in (0, 1, 2, 3) or front not in (0, 1) or not 0 <= one('logicOp') <= 15:
        raise ValueError('graphics fixed raster enums exceed profile')
    discard = one('rasterizerDiscardEnable')
    if discard not in (0, 1):
        raise ValueError('graphics fixed rasterizerDiscardEnable exceeds profile')
    poly_mode = one('polygonMode')
    if poly_mode not in (0, 1, 2):
        raise ValueError('graphics fixed polygonMode exceeds profile')
    topology = one('topology')
    if topology not in (0, 1, 2, 3, 4, 5):
        raise ValueError('graphics fixed topology exceeds profile')
    # primitiveRestartEnable is a pipeline-global flag; the bounded profile
    # admits 0/1 and applies it to indexed draws only (non-indexed ignore
    # it).  The fetch stage detects the width sentinel on the raw index.
    restart = one('primitiveRestartEnable')
    if restart not in (0, 1):
        raise ValueError('graphics fixed primitiveRestartEnable exceeds profile')
    # optional bounded depth bias: (constantFactor, clamp, slopeFactor)
    # fp32 triple retained when depthBiasEnable=1.  The per-triangle
    # slope term is evaluated in the raster stage; r is 1.0 for the D32
    # depth format this profile admits.
    depth_bias = None
    dbe = one('depthBiasEnable')
    if dbe not in (0, 1):
        raise ValueError('graphics fixed depthBiasEnable exceeds profile')
    if dbe:
        depth_bias = tuple(
            struct.unpack('<f', struct.pack('<I', one(name)))[0]
            for name in ('depthBiasConstantFactor', 'depthBiasClamp',
                         'depthBiasSlopeFactor'))
        if not all(math.isfinite(v) for v in depth_bias):
            raise ValueError('graphics fixed depth bias exceeds profile')
    dcl = one('depthClampEnable')
    if dcl not in (0, 1):
        raise ValueError('graphics fixed depthClampEnable exceeds profile')
    colors = render_pass.subpass_colors(subpass)
    count = len(colors)
    if not 0 < count <= 4 or one('attachmentCount') != count or one('pAttachments') != count:
        raise ValueError('graphics fixed color state differs from subpass')
    for name, limit in (('blendEnable', 1), ('srcColorBlendFactor', 14),
                        ('dstColorBlendFactor', 14), ('colorBlendOp', 4),
                        ('srcAlphaBlendFactor', 14), ('dstAlphaBlendFactor', 14),
                        ('alphaBlendOp', 4), ('colorWriteMask', 15)):
        values = fields.get(name, ())
        if len(values) != count or any(not 0 <= value <= limit for value in values):
            raise ValueError('graphics fixed blend/mask state exceeds profile: ' + name)
    # bounded blend: VkPipelineColorBlendAttachmentState is per-attachment,
    # so each active colour output carries its own (blendEnable, factors,
    # op, writeMask) while the four blendConstants stay pipeline-global.
    # `blend` retains the PRIMARY attachment's 11-tuple (or None when its
    # blendEnable=0) for the single-output fast path; `blend_extra` retains
    # the remaining attachments' states aligned with the MRT extras
    # (attachment 1..N-1), each None or the same 11-tuple.  The standalone
    # colourWriteMask still gates channels when blendEnable=0.
    blend = blend_extra = None
    if any(fields.get('blendEnable', ())):
        consts = blobs.get('blendConstants', ())
        if len(consts) != 4:
            raise ValueError('graphics blend constants are incomplete')
        states = []
        for i in range(count):
            if fields['blendEnable'][i]:
                states.append((fields['srcColorBlendFactor'][i],
                               fields['dstColorBlendFactor'][i],
                               fields['colorBlendOp'][i],
                               fields['srcAlphaBlendFactor'][i],
                               fields['dstAlphaBlendFactor'][i],
                               fields['alphaBlendOp'][i],
                               fields['colorWriteMask'][i], *consts))
            else:
                states.append(None)
        blend = states[0]
        blend_extra = tuple(states[1:])
    # bounded logicOp: a pipeline-global VkLogicOp code replacing the blend
    # result.  Admitted only with blendEnable=0 on every attachment (the
    # logicOp-replaces-blend precedence combo stays refused); the code is
    # bounded to the 15-entry CLEAR..SET table the RTL f_lop mirrors.
    logic_op = None
    loe = one('logicOpEnable')
    if loe not in (0, 1):
        raise ValueError('graphics fixed logicOpEnable exceeds profile')
    if loe:
        if blend is not None or any(fields.get('blendEnable', ())):
            raise ValueError('graphics fixed logicOp/blend combination exceeds profile')
        lop = one('logicOp')
        if not 0 <= lop <= 14:
            raise ValueError('graphics fixed logicOp code exceeds profile')
        logic_op = lop
    nb, na = one('vertexBindingDescriptionCount'), one('vertexAttributeDescriptionCount')
    if (not 0 <= nb <= 16 or not 0 <= na <= 8 or
            one('pVertexBindingDescriptions') != nb or one('pVertexAttributeDescriptions') != na):
        raise ValueError('graphics fixed vertex counts exceed profile')
    if (len(fields.get('binding', ())) != nb + na or
            any(len(fields.get(name, ())) != nb for name in ('stride', 'inputRate')) or
            any(len(fields.get(name, ())) != na for name in ('location', 'format', 'offset'))):
        raise ValueError('graphics fixed vertex rows are incomplete')
    binding_ids = fields.get('binding', ())[:nb]
    bindings = tuple(zip(binding_ids, fields.get('stride', ()), fields.get('inputRate', ())))
    stride_limit = min(0xFFFF, engine.model.profile['limits']['maxVertexInputBindingStride'])
    if (len(set(binding_ids)) != nb or
            any(not 0 <= binding <= 15 or not 0 <= stride <= stride_limit or rate not in (0, 1)
                for binding, stride, rate in bindings)):
        raise ValueError('graphics fixed vertex binding/stride/rate exceed profile')
    attributes = tuple(zip(fields.get('location', ()), fields.get('binding', ())[nb:],
                           fields.get('format', ()), fields.get('offset', ())))
    locations = [location for location, _, _, _ in attributes]
    if (len(set(locations)) != na or
            any(not 0 <= location <= 7 or binding not in binding_ids or
                fmt not in engine.golden.VATTR_OK or not 0 <= offset <= 2047
                for location, binding, fmt, offset in attributes)):
        raise ValueError('graphics fixed vertex attribute exceeds profile')
    return GraphicsState(bindings, attributes, cull, front,
                         tuple(fields['colorWriteMask']), tuple(sorted(dynamic)),
                         depth, bounds, blend, blend_extra, logic_op, discard,
                         depth_bias, dcl, poly_mode, topology, stencil,
                         restart)
