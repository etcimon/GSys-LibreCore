#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Axis census of the pinned vk-default must-pass set: which name tokens
(the dimensions the CTS multiplies) gate how many cases."""
import collections, glob, os, re, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "specs", "VK-GL-CTS", "external", "vulkancts", "mustpass", "main", "vk-default")
files = sorted(glob.glob(R + '/**/*.txt', recursive=True))
tot = 0
per_list = {}
lvl2 = collections.Counter()
FMT = re.compile(r'(?<![a-z0-9])((?:[rgbaxde]\d+){1,4}|d\d+(?:_s8)?|s8|bc\d[a-z0-9_]*?|etc2_[a-z0-9]+|eac_[a-z0-9]+|astc_\d+x\d+|g8_b8[a-z0-9_]*?|a\d[rgb]\d+[rgb]\d+[rgb]\d+|[rgb]\d+[rgb]\d+[rgb]\d+a\d)_(unorm|snorm|uint|sint|sfloat|srgb|ufloat|uscaled|sscaled)(?:_(?:pack\d+|block))?')
fmts = collections.Counter()
fmt_cases = 0
AX = {
 'stage.geometry': r'(?<![a-z])(geometry|geom)(?![a-z])',
 'stage.tess': r'tess(ellation|_eval|_control|c|e)?(?![a-z])',
 'stage.mesh_task': r'(?<![a-z])(mesh|task)(?![a-z])',
 'stage.rt': r'(?<![a-z])(rgen|rchit|rahit|rmiss|rint|call|ray_query|ray_tracing)(?![a-z])',
 'stage.vertex_only_or_frag': r'(?<![a-z])(vertex|fragment|vert|frag)(?![a-z])',
 'stage.compute': r'(?<![a-z])(compute|comp)(?![a-z])',
 'msaa': r'(samples?_(2|4|8|16|32|64)(?![0-9])|(?<![0-9])(2|4|8|16|32|64)_samples?|multisample|msaa|sample_shading|alpha_to_coverage|resolve)',
 'dim.1d': r'(?<![a-z0-9])1d(?![a-z0-9])', 'dim.3d': r'(?<![a-z0-9])3d(?![a-z0-9])',
 'dim.cube': r'cube', 'dim.array': r'(?<![a-z])array',
 'compressed': r'(?<![a-z0-9])(bc\d|etc2|eac|astc)',
 'ycbcr.fmt': r'(g8_b8|_420_|_422_|_444_|ycbcr)',
 'float64/int64/16/8': r'(float64|int64|double|dvec|dmat|f64|i64|u64|float16|f16|int16|i16|u16|int8|i8|u8|16bit|8bit)',
 'dynamic_rendering': r'dynamic_render', 'renderpass2': r'renderpass2',
 'secondary_cmd': r'secondary', 'multi_queue': r'multi_queue|different_queues|two_queues',
 'timeline': r'timeline', 'sparse': r'sparse', 'protected': r'protected',
 'push_descriptor': r'push_descriptor|push_template', 'desc.template': r'with_template|update_template|template',
 'desc.inline_uniform': r'inline_uniform', 'desc.buffer_ext': r'descriptor_buffer',
 'desc.mutable': r'mutable', 'desc.indexing': r'descriptor_indexing|runtime_array|update_after_bind|variable_descriptor|nonuniform',
 'bda': r'buffer_device_address|device_address|bda', 'spec_const': r'spec_const|specialization',
 'robust': r'robust', 'depth_stencil': r'(?<![a-z])(depth|stencil)(?![a-z])',
 'blend': r'(?<![a-z])blend', 'query': r'query|occlusion|timestamp|statistics',
 'xfb': r'transform_feedback|xfb', 'multiview': r'multiview',
 'lines_points': r'(?<![a-z])(line|lines|point|points|line_strip|line_list|point_list)(?![a-z])',
 'adjacency_fan_patch': r'adjacency|triangle_fan|patch',
 'indirect': r'indirect', 'instanced': r'instanc',
 'subgroup': r'subgroup', 'atomic': r'atomic', 'derivative': r'derivat|dfdx|dfdy|fwidth',
 'ctor.monolithic': r'\.monolithic\.|_monolithic', 'ctor.gpl': r'pipeline_library|fast_linked|optimized_library|_lib(?![a-z])',
 'ctor.shader_object': r'shader_object',
 'host_copy/maint': r'maintenance\d|host_image_copy',
 'khr.ext.amd.nv': r'_(ext|khr|amd|nv|qcom|arm|img)(?![a-z])',
}
AXR = {k: re.compile(v) for k, v in AX.items()}
axc = collections.Counter()
for f in files:
    rel = os.path.relpath(f, R)[:-4]
    n = 0
    for ln in open(f, errors='replace'):
        s = ln.strip()
        if not s.startswith('dEQP-VK.'):
            continue
        n += 1
        p = s.split('.')
        lvl2['.'.join(p[1:3])] += 1
        low = s.lower()
        m = FMT.findall(low)
        if m:
            fmt_cases += 1
            for a, b in set(m):
                fmts[a + '_' + b] += 1
        for k, r in AXR.items():
            if r.search(low):
                axc[k] += 1
    per_list[rel] = n
    tot += n
print('TOTAL', tot, 'lists', len(files))
print('== lists >= 20k ==')
for k, v in sorted(per_list.items(), key=lambda x: -x[1]):
    if v >= 20000:
        print('%9d %5.1f%%  %s' % (v, 100.0 * v / tot, k))
print('== level-2 prefixes >= 25k ==')
for k, v in lvl2.most_common(45):
    print('%9d %5.1f%%  %s' % (v, 100.0 * v / tot, k))
print('== axes (cases whose name carries the token) ==')
for k, v in sorted(axc.items(), key=lambda x: -x[1]):
    print('%9d %5.1f%%  %s' % (v, 100.0 * v / tot, k))
print('== formats: cases naming >=1 format', fmt_cases, 'distinct', len(fmts))
for k, v in fmts.most_common(40):
    print('%9d  %s' % (v, k))
