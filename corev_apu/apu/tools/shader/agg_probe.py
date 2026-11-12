#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Probe: does a whole-aggregate OpLoad/OpStore (plain GLSL struct/array
assignment between two SSBOs) survive spirv_scan + spirv_model?"""
import os, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spirv_scan, shader_vectors as sv

CASES = {
    'struct_8w': ('struct S { vec4 a; uint b; uint c; uint d; uint e; };',
                  'S s;', 'o.s = i.s;', 8),
    'struct_4w': ('struct S { uint a; uint b; uint c; uint d; };',
                  'S s;', 'o.s = i.s;', 4),
    'array_8w': ('', 'uint s[8];', 'o.s = i.s;', 8),
    'local_struct_8w': ('struct S { vec4 a; uint b; uint c; uint d; uint e; };',
                        'S s;', 'S t = i.s; S u = t; o.s = u;', 8),
}
ok = True
for name, (decl, memb, body, nw) in CASES.items():
    src = ('#version 450\nlayout(local_size_x=1) in;\n%s\n'
           'layout(set=0,binding=0,std430) buffer I { %s } i;\n'
           'layout(set=0,binding=1,std430) buffer O { %s } o;\n'
           'void main() { %s }\n' % (decl, memb, memb, body))
    with tempfile.TemporaryDirectory() as td:
        c, s = td + '/a.comp', td + '/a.spv'
        open(c, 'w').write(src)
        r = subprocess.run(['glslangValidator', '-V', '-o', s, c],
                           capture_output=True, text=True)
        if r.returncode:
            print(name, 'GLSLANG FAIL', r.stdout[-200:]); continue
        dis = subprocess.run(['spirv-dis', s], capture_output=True,
                             text=True).stdout
        spv = sv.read_spv(s)
    aggs = [l.strip() for l in dis.splitlines()
            if ('OpLoad %S ' in l or 'OpLoad %_arr' in l or 'OpCopy' in l
                or 'OpLoad %S_0' in l)]
    binds = [(0, 0, nw, 0, 7 << 16), (0, 1, nw, 1, 7 << 16)]
    inputs = [[0x1000 + k for k in range(nw)], [0] * nw]
    sv.pack_floats = lambda vals, fmt: list(vals)
    desc = dict(groups=(1, 1, 1), fmt='raw', push=0, bindings=binds)
    try:
        hexw = sv._build_hexw(spv, desc, inputs, 1, (0, 0), False)
        rob, mw, cw, m = sv.model_run(hexw, binds)
        got = m.outputs().get(1, [])
        good = got[:nw] == inputs[0]
        print('%-16s %s got=%s  aggregate-ops=%s' % (
            name, 'PASS' if good else 'WRONG',
            ' '.join('%x' % g for g in got[:nw]), aggs[:3]))
        ok &= good
    except spirv_scan.Fault as e:
        print('%-16s FAULT %s opc=%d (truthful refusal)' % (
            name, spirv_scan.FAULT_NAME[e.code], e.opcode))
