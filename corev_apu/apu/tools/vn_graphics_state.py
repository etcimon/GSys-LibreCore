# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded native fixed-state values; no draw/interface/execution admission."""
from dataclasses import dataclass


@dataclass(frozen=True)
class GraphicsState:
    bindings: tuple
    attributes: tuple
    cull: int
    front_face: int
    color_masks: tuple
    dynamic: tuple


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
        'pDepthStencilState': 0, 'pColorBlendState': 1, 'pDynamicState': 1,
        'topology': 3, 'primitiveRestartEnable': 0,
        'viewportCount': 1, 'pViewports': 0, 'scissorCount': 1, 'pScissors': 0,
        'depthClampEnable': 0, 'rasterizerDiscardEnable': 0, 'polygonMode': 0,
        'depthBiasEnable': 0, 'lineWidth': 0x3F800000,
        'rasterizationSamples': 1, 'sampleShadingEnable': 0,
        'pSampleMask': 0, 'alphaToCoverageEnable': 0, 'alphaToOneEnable': 0,
        'logicOpEnable': 0, 'dynamicStateCount': 2, 'pDynamicStates': 2,
        'blendConstants': 4,
    }
    for name, value in required.items():
        if one(name) != value:
            raise ValueError('graphics fixed state exceeds profile: ' + name)
    dynamic = blobs.get('pDynamicStates', ())
    if sorted(dynamic) != [0, 1]:
        raise ValueError('graphics fixed dynamic viewport/scissor must be distinct')
    cull, front = one('cullMode'), one('frontFace')
    if cull not in (0, 1, 2, 3) or front not in (0, 1) or not 0 <= one('logicOp') <= 15:
        raise ValueError('graphics fixed raster enums exceed profile')
    colors = render_pass.subpass_colors(subpass)
    count = len(colors)
    if not 0 < count <= 4 or one('attachmentCount') != count or one('pAttachments') != count:
        raise ValueError('graphics fixed color state differs from subpass')
    for name, limit in (('blendEnable', 0), ('srcColorBlendFactor', 14),
                        ('dstColorBlendFactor', 14), ('colorBlendOp', 4),
                        ('srcAlphaBlendFactor', 14), ('dstAlphaBlendFactor', 14),
                        ('alphaBlendOp', 4), ('colorWriteMask', 15)):
        values = fields.get(name, ())
        if len(values) != count or any(not 0 <= value <= limit for value in values):
            raise ValueError('graphics fixed blend/mask state exceeds profile: ' + name)
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
                         tuple(fields['colorWriteMask']), tuple(sorted(dynamic)))
