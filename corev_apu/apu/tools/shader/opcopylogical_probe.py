#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Run the CTS spirv1p4/opcopylogical amber shaders through spirv_scan +
spirv_model and check the amber probes (local oracle = amber expectations)."""
import glob, os, re, struct, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spirv_scan, spirv_model, shader_vectors as sv

D = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 '..', '..', '..', '..', 'specs', 'VK-GL-CTS', 'external',
                 'vulkancts', 'data', 'vulkan', 'amber', 'spirv_assembly',
                 'instruction', 'spirv1p4', 'opcopylogical')
NCOMP = dict(float=1, uint=1, int=1, vec4=4, uvec4=4, vec3=3, vec2=2)


def enc(ty, v):
    if ty in ('float', 'vec4', 'vec3', 'vec2'):
        return struct.unpack('<I', struct.pack('<f', float(v)))[0]
    return int(v) & 0xFFFFFFFF


def parse(path):
    txt = open(path).read()
    asm = txt.split('[compute shader spirv]')[1].split('[test]')[0]
    test = txt.split('[test]')[1]
    bufs, kinds, probes = {}, {}, []
    for ln in test.splitlines():
        t = ln.split()
        if not t or t[0].startswith('#'):
            continue
        if t[0] == 'uniform':               # uniform ubo s:b type off v*
            t = t[1:]
            kinds[t[1]] = 6
        if t[0] in ('ssbo', 'ubo'):
            key = t[1]
            kinds.setdefault(key, 7)
            b = bufs.setdefault(key, {})
            if t[2] == 'subdata':
                ty, off = t[3], int(t[4])
                for i, v in enumerate(t[5:]):
                    b[off // 4 + i] = enc(ty, v)
            elif len(t) == 3:               # ssbo s:b size
                b[int(t[2]) // 4 - 1] = b.get(int(t[2]) // 4 - 1, 0)
            else:                           # ubo s:b type off v*
                ty, off = t[2], int(t[3])
                for i, v in enumerate(t[4:]):
                    b[off // 4 + i] = enc(ty, v)
        if t[0] == 'probe':                 # probe ssbo type s:b off == v*
            ty, key, off = t[2], t[3], int(t[4])
            probes.append((key, off // 4, [enc(ty, v) for v in t[6:]]))
    return asm, bufs, kinds, probes


def main():
    ok = bad = 0
    for path in sorted(glob.glob(D + '/*.amber')):
        name = os.path.basename(path)[:-6]
        asm, bufs, kinds, probes = parse(path)
        with tempfile.TemporaryDirectory() as td:
            a, s = td + '/a.spvasm', td + '/a.spv'
            open(a, 'w').write(asm)
            subprocess.check_call(['spirv-as', '--target-env', 'vulkan1.2',
                                   '-o', s, a])
            spv = sv.read_spv(s)
        keys = sorted(bufs)
        outk = {p[0] for p in probes}
        binds, inputs = [], []
        for k in keys:
            st, bd = (int(x) for x in k.split(':'))
            nw = max(max(bufs[k]) + 1,
                     max([p[1] + len(p[2]) for p in probes if p[0] == k]
                         or [0]))
            binds.append((st, bd, nw, 1 if k in outk else 0,
                          kinds[k] << 16))
            inputs.append([bufs[k].get(i, 0) for i in range(nw)])
        desc = dict(groups=(1, 1, 1), fmt='raw', push=0, bindings=binds)
        sv.pack_floats = lambda vals, fmt: list(vals)
        try:
            hexw = sv._build_hexw(spv, desc, inputs, 1, (0, 0), False)
            rob, mw, cw, m = sv.model_run(hexw, binds)
        except spirv_scan.Fault as e:
            bad += 1
            print('%-40s FAULT %s opc=%d' % (
                name, spirv_scan.FAULT_NAME[e.code], e.opcode))
            continue
        except Exception as e:                       # noqa: BLE001
            bad += 1
            print('%-40s EXC %s: %s' % (name, type(e).__name__,
                                        str(e)[:70]))
            continue
        outs = m.outputs()
        miss = 0
        tot = 0
        first = None
        for (k, w0, exp) in probes:
            got = outs.get(keys.index(k), [])
            for i, e in enumerate(exp):
                tot += 1
                g = got[w0 + i] if w0 + i < len(got) else None
                if g != e:
                    miss += 1
                    if first is None:
                        first = (w0 + i, e, g)
        if miss:
            bad += 1
            print('%-40s MISMATCH %d/%d words; first word %d exp %08x got %s'
                  % (name, miss, tot, first[0], first[1],
                     'none' if first[2] is None else '%08x' % first[2]))
        else:
            ok += 1
            print('%-40s PASS %d words' % (name, tot))
    print('TOTAL pass=%d fail=%d' % (ok, bad))


main()
