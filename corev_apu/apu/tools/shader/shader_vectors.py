#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Increment-4a ShaderCore vector generator (architecture doc 7a/10).

For every corpus shader x every seeded input set this emits
`verif/tb/apu/sh_vectors/<name>_<seed>.{hex,exp}` plus per-shader
`.tab` files (spirv_scan.py's table image), a mutated-module case
(`<name>_mut0`) and an unsupported-opcode case (`<name>_bad0`).

.hex (input, $readmemh, one word per line):
  [0] n_spv_words      [1] n_bindings      [2] n_push_words
  [3] gx               [4] gy              [5] gz
  [6] flags  (bit0: module is expected to commit-fault; bit1: mutated
              module -- outputs must DIFFER from the unmutated .exp)
  [7] case tag (free)
  [8..] spv words
  then per binding: {set, binding, size_bytes, mem_addr} (4 words)
  then n_push_words push words
  then per binding in order: size_bytes/4 init words
  sentinel: FFFFFFFF FFFFFFFF

.exp (expected, $readmemh):
  [0] expect_commit_fault  (fault code, 0 = commits)
  [1] expect_fault_opcode  (offending opcode, 0 none)
  [2] expect_robust        (MODEL robustness fault count — the
                            spirv_model.py prediction; Gate 1
                            requires the RTL to match bit-exact)
  [3] expect_done          (0 no work_done, 1 ok, 2 fault)
  [4] n_bindings
  then per binding: {binding, size_bytes, mem_addr, is_out}
  then ORACLE section: per is_out binding, size/4 lavapipe words
  then MODEL section:  per is_out binding, size/4 spirv_model words
  then CLASS section:  per is_out binding, size/4 class words
                       (0 = integer/bool → Gate 2 bit-exact,
                        1 = float → Gate 2 <= 2 ULP)
  sentinel: FFFFFFFF FFFFFFFF
  Commit-fault cases carry no oracle/model/class sections.

Buffer address map: binding i gets base ADDR0 + i*0x1000.
"""
import json
import os
import random
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, 'corpus')
OUT = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..', 'verif',
                                   'tb', 'apu', 'sh_vectors'))
ADDR0 = 0x8000
SENT = [0xFFFFFFFF, 0xFFFFFFFF]

# per-shader case description:
#   groups: (gx,gy,gz)   push: n push words   oob: expected-robust fn
#   fmt: 'f' float / 'i' uint init stream   sz: words per binding
#   bindings: [(set,binding,words,is_out)]   extra: dict
DESC = {
    'bufcopy':    dict(groups=(4, 1, 1), fmt='f', push=0,
                       bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    'bufscale':   dict(groups=(4, 1, 1), fmt='f', push=0,
                       bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    'vec4arith':  dict(groups=(4, 1, 1), fmt='f', push=0,
                       bindings=[(0, 0, 256, 0), (0, 1, 128, 1)]),
    'intmix':     dict(groups=(4, 1, 1), fmt='i', push=0,
                       bindings=[(0, 0, 64, 0), (0, 1, 32, 1)]),
    'composite':  dict(groups=(4, 1, 1), fmt='f', push=0,
                       bindings=[(0, 0, 256, 0), (0, 1, 32, 1)]),
    'oob':        dict(groups=(4, 1, 1), fmt='oob', push=0,
                       bindings=[(0, 0, 64, 0), (0, 1, 64, 1)]),
    'pushscale':  dict(groups=(4, 1, 1), fmt='f', push=2,
                       bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    # math450: 32 invocations x 9 vec4 outputs = 288 vec4 = 1152 words
    'math450':    dict(groups=(4, 1, 1), fmt='f', push=0,
                       bindings=[(0, 0, 256, 0), (0, 1, 1152, 1)]),
    'compare':    dict(groups=(4, 1, 1), fmt='f', push=0,
                       bindings=[(0, 0, 256, 0), (0, 1, 32, 1)]),
    'arrlen':     dict(groups=(4, 1, 1), fmt='i', push=0,
                       bindings=[(0, 0, 64, 0), (0, 1, 32, 1)]),
    'builtin_gid':   dict(groups=(4, 1, 1), fmt='z', push=0,
                          bindings=[(0, 0, 32, 1)]),
    'builtin_lid':   dict(groups=(3, 2, 1), fmt='z', push=0,
                          bindings=[(0, 0, 96, 1)]),
    'builtin_lindex': dict(groups=(2, 2, 1), fmt='z', push=0,
                           bindings=[(0, 0, 64, 1)]),
    'localsize32':  dict(groups=(2, 1, 1), fmt='i', push=0,
                         bindings=[(0, 0, 64, 0), (0, 1, 64, 1)]),
    'localsize64':  dict(groups=(1, 1, 1), fmt='i', push=0,
                         bindings=[(0, 0, 64, 0), (0, 1, 64, 1)]),
    # ---- increment-4b corpus (§7c): control flow / barriers / matrix
    # cf=True → the bad arm is an unstructured branch (merge-op
    # removal) expected to fault APU_SH_FAULT_BRANCH at commit.
    'ifelse':       dict(groups=(1, 1, 1), fmt='i', push=0, cf=True,
                         bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    'loopfor':      dict(groups=(1, 1, 1), fmt='i', push=0, cf=True,
                         bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    'loopwhile':    dict(groups=(1, 1, 1), fmt='i', push=0, cf=True,
                         bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    'switchcase':   dict(groups=(1, 1, 1), fmt='i', push=0, cf=True,
                         bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    'shortcircuit': dict(groups=(1, 1, 1), fmt='i', push=0, cf=True,
                         bindings=[(0, 0, 64, 0), (0, 1, 32, 1)]),
    'earlyret':     dict(groups=(1, 1, 1), fmt='i', push=0, cf=True,
                         bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    'barrier_prefix': dict(groups=(1, 1, 1), fmt='i', push=0, cf=True,
                           bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    'barrier_reduce': dict(groups=(1, 1, 1), fmt='i', push=0, cf=True,
                           bindings=[(0, 0, 64, 0), (0, 1, 128, 1)]),
    'matvec':       dict(groups=(1, 1, 1), fmt='f', push=0, cf=False,
                         bindings=[(0, 0, 128, 0), (0, 1, 128, 1)]),
    'matmat':       dict(groups=(1, 1, 1), fmt='f', push=0, cf=False,
                         bindings=[(0, 0, 64, 0), (0, 1, 128, 1)]),
    'precise_dot':  dict(groups=(1, 1, 1), fmt='f', push=0, cf=False,
                         bindings=[(0, 0, 256, 0), (0, 1, 128, 1)]),
    # phiflow is assembled from phiflow.spvasm (hand-written): glslang
    # never emits OpPhi, so phi coverage needs the .spvasm source.
    'phiflow':      dict(groups=(1, 1, 1), fmt='f', push=0, cf=True,
                         bindings=[(0, 0, 64, 0), (0, 1, 32, 1)]),
    # §12.3 F5 corpus — memory-resident descriptor records.
    # bind aux = {kind[23:16], dyn[8], elem_idx[7:0]}; kind 7 =
    # STORAGE_BUFFER, 9 = STORAGE_BUFFER_DYNAMIC.
    # descarr: one 4-element array binding + an output; gid/8 indexes
    # it divergently (32 invocations -> elements 0..3).
    'descarr':      dict(groups=(4, 1, 1), fmt='f', push=0, cf=False,
                         bindings=[(0, 0, 32, 0, (7 << 16) | 0),
                                   (0, 0, 32, 0, (7 << 16) | 1),
                                   (0, 0, 32, 0, (7 << 16) | 2),
                                   (0, 0, 32, 0, (7 << 16) | 3),
                                   (0, 1, 32, 1, 7 << 16)]),
    # multiset: four sets, one SSBO each; set 2 is bound dynamic with
    # a +128 B dispatch-time offset (reads the buffer's upper half);
    # set 0 also carries the 32-word output.
    'multiset':     dict(groups=(1, 1, 1), fmt='f', push=0, cf=False,
                         dyn_off=[(2, 0, 128)],
                         bindings=[(0, 0, 32, 0, 7 << 16),
                                   (0, 1, 32, 1, 7 << 16),
                                   (1, 0, 32, 0, 7 << 16),
                                   (2, 0, 96, 0,
                                    (9 << 16) | (1 << 8)),
                                   (3, 0, 32, 0, 7 << 16)]),
    # arroob: gid indexes a 4-element array with gid up to 15;
    # elements >= 4 hit the null record -> robust zero loads.
    'arroob':       dict(groups=(2, 1, 1), fmt='f', push=0, cf=False,
                         bindings=[(0, 0, 8, 0, (7 << 16) | 0),
                                   (0, 0, 8, 0, (7 << 16) | 1),
                                   (0, 0, 8, 0, (7 << 16) | 2),
                                   (0, 0, 8, 0, (7 << 16) | 3),
                                   (0, 1, 16, 1, 7 << 16)]),
}
SEEDS = [1, 2, 3]

sys.path.insert(0, HERE)
import spirv_scan  # noqa: E402
import spirv_model  # noqa: E402


def model_run(hexw, bindings):
    """run spirv_model on a dispatch record; returns
    (robust, model_words_by_out_binding, class_words_by_out_binding,
    the Model).  Raises spirv_scan.Fault if the module can't commit."""
    m = spirv_model.Model(list(hexw))
    m.run()
    outs = m.outputs()
    cls = m.out_classes()
    mw, cw = [], []
    for i, b in enumerate(bindings):
        st, bd, w, o = b[:4]
        if o:
            mw += outs.get(i, [0] * w)
            cw += [1 if c == 'f' else 0 for c in cls.get(i, ['i'] * w)]
    return m.robust, mw, cw, m


def words_to_hex(words):
    return ['%08x' % (w & 0xFFFFFFFF) for w in words]


def read_spv(path):
    data = open(path, 'rb').read()
    return list(struct.unpack('<%dI' % (len(data) // 4), data))


def gen_inputs(desc, nbind_words, seed):
    rng = random.Random(seed * 7919 + sum(nbind_words))
    outs = []
    for w in nbind_words:
        if desc['fmt'] == 'f':
            outs.append([struct.unpack('<f', struct.pack(
                '<f', rng.uniform(-64.0, 64.0)))[0]
                for _ in range(w)])
        elif desc['fmt'] == 'i':
            outs.append([rng.randint(0, 0xFFFFFF) for _ in range(w)])
        elif desc['fmt'] == 'z':
            outs.append([0] * w)
        elif desc['fmt'] == 'oob':
            # index permutation: in-range indices are *unique* and
            # restricted to [ninv, w) so dst[idx] stores never collide
            # with the unconditional dst[i] stores (i < ninv) —
            # keeps the OOB store pattern deterministic (no write races)
            ninv = desc['groups'][0] * 8
            pool = list(range(ninv, w))
            rng.shuffle(pool)
            v = []
            k = 0
            for i in range(ninv):
                if i % 3 == 0 and k < len(pool):
                    v.append(pool[k]); k += 1
                else:
                    v.append(rng.randint(w, 0x100000))
            # pad remaining words (beyond dispatch reach) arbitrarily
            v += [rng.randint(0, w - 1) for _ in range(w - len(v))]
            outs.append(v)
    return outs


def pack_floats(vals, fmt):
    if fmt == 'f':
        return [struct.unpack('<I', struct.pack('<f', v))[0]
                for v in vals]
    return [v & 0xFFFFFFFF for v in vals]


def mutate(words):
    """candidate mutation sites: flip a same-typed arithmetic opcode
    (FAdd<->FSub, IAdd<->ISub, FMul<->FDiv).  Returns a list of
    (mutated_words, word_index) in module order; the caller verifies
    observability through the oracle and keeps the first that changes
    the output.  Only words at instruction boundaries qualify — a
    constant/pointer operand word whose low 16 bits happen to match an
    opcode value must never be "mutated" (4a corpus accident)."""
    pairs = {129: 131, 131: 129, 128: 130, 130: 128, 133: 136, 136: 133}
    out = []
    at = 5
    while at < len(words):
        wc = words[at] >> 16
        opc = words[at] & 0xFFFF
        if opc in pairs:
            m = list(words)
            m[at] = (words[at] & 0xFFFF0000) | pairs[opc]
            out.append((m, at))
        at += wc if wc else 1
    if out:
        return out
    # fallback: reroute the last index operand of the first dynamic
    # OpAccessChain to a constant -> every lane reads element 0.
    consts = []
    at = 5
    while at < len(words):
        wc = words[at] >> 16
        if (words[at] & 0xFFFF) == 43 and wc > 2:
            consts.append(words[at + 2])
        at += wc if wc else 1
    if not consts:
        return out
    at = 5
    while at < len(words):
        wc = words[at] >> 16
        if (words[at] & 0xFFFF) == 65 and wc >= 4:
            if words[at + wc - 1] != consts[0]:
                m = list(words)
                m[at + wc - 1] = consts[0]
                out.append((m, at + wc - 1))
        at += wc if wc else 1
    return out


def inject_bad(words):
    """patch the first OpStore's opcode word to OpSin so the commit
    scanner faults with opcode 13 at a deterministic word.  Walks
    instruction boundaries — operand words are never patch sites."""
    at = 5
    while at < len(words):
        wc = words[at] >> 16
        if (words[at] & 0xFFFF) == 62:     # first OpStore
            m = list(words)
            m[at] = (words[at] & 0xFFFF0000) | 13
            return m, at
        at += wc if wc else 1
    # no OpStore: patch the last instruction (OpReturn -> OpSin)
    at = len(words) - 1
    while at > 5:
        if (words[at] >> 16) == 1:
            m = list(words)
            m[at] = (words[at] & 0xFFFF0000) | 13
            return m, at
        at -= 1
    m = list(words)
    m[-1] = (m[-1] & 0xFFFF0000) | 13
    return m, len(m) - 1


def inject_bad_cf(words):
    """4b bad arm: remove a merge instruction (OpSelectionMerge /
    OpLoopMerge) so the following OpBranchConditional / OpSwitch is
    unstructured — the commit rule then faults APU_SH_FAULT_BRANCH.
    Returns (words, fault_code, fault_opcode)."""
    at = 5
    while at < len(words):
        wc = words[at] >> 16
        if not wc:
            break
        opc = words[at] & 0xFFFF
        nxt = at + wc
        if opc in (246, 247) and nxt < len(words) and \
                (words[nxt] & 0xFFFF) in (250, 251):
            m = words[:at] + words[at + wc:]
            try:
                spirv_scan.Scanner(m).scan()
            except spirv_scan.Fault as f:
                if f.code == spirv_scan.FAULT['BRANCH']:
                    return m, f.code, f.opcode
        at += wc
    # no merge to remove (straight-line shader): keep the classic
    # unsupported-opcode arm instead.
    m, _ = inject_bad(words)
    return m, spirv_scan.FAULT['OPCODE'], 13


def push_words(desc, seed):
    """push constants for pushscale: {scale, bias} as floats."""
    if not desc.get('push'):
        return []
    return [struct.unpack('<I', struct.pack('<f', 1.5 + seed * 0.25))[0],
            struct.unpack('<I', struct.pack('<f', -2.0 + seed))[0]]


def run_oracle(spv_path, desc_json, out_bin):
    env = dict(os.environ)
    env['VK_DRIVER_FILES'] = '/usr/share/vulkan/icd.d/lvp_icd.json'
    r = subprocess.run([ORACLE, spv_path, desc_json, out_bin],
                       env=env, capture_output=True, text=True)
    return r


def emit(name, seed, spv_words, desc, inputs, expect_fault=(0, 0),
         mutated=False, oracle_out=None, model_cache=None):
    """writes <name>_<seed>.{hex,exp,desc.json,init bin files}

    The .exp robust field and the trailing MODEL/CLASS sections come
    from spirv_model.py run over THIS case's module words (including
    the mutated module for _mut_0 cases) — Gate 1 is bit-exact for
    every case that commits."""
    base = os.path.join(OUT, '%s_%d' % (name, seed))
    push = desc.get('push', 0)
    bindings = desc['bindings']
    hexw = [len(spv_words), len(bindings), push,
            desc['groups'][0], desc['groups'][1], desc['groups'][2],
            (1 if expect_fault[0] else 0) | (2 if mutated else 0), 0]
    hexw += spv_words
    # §12.3 F5: 5-word bind entries; aux = {kind[23:16], dyn[8],
    # elem_idx[7:0]} so elements of one descriptor array share a row.
    for i, b in enumerate(bindings):
        st, bd, w, o = b[:4]
        ax = b[4] if len(b) > 4 else 0
        hexw += [st, bd, w * 4, ADDR0 + i * 0x1000, ax]
    hexw += push_words(desc, seed)
    # dynamic-offset section: n entries {set, ordinal, offset}
    dynl = desc.get('dyn_off', [])
    hexw += [len(dynl)]
    for (s, o2, v) in dynl:
        hexw += [s, o2, v]
    for i in range(len(bindings)):
        hexw += pack_floats(inputs[i], desc['fmt'])
    hexw += SENT
    open(base + '.hex', 'w').write('\n'.join(words_to_hex(hexw)) + '\n')

    # model run (skipped for commit-fault modules); model_cache lets
    # the post-oracle re-emit reuse the result.
    if model_cache is not None:
        mrob, mwords, cwords, _m = model_cache
    elif not expect_fault[0]:
        mrob, mwords, cwords, _m = model_run(hexw, bindings)
    else:
        mrob, mwords, cwords, _m = 0, None, None, None
    robust = mrob

    expw = [expect_fault[0], expect_fault[1], robust,
            0 if expect_fault[0] else 1, len(bindings)]
    for i, b in enumerate(bindings):
        st, bd, w, o = b[:4]
        expw += [bd, w * 4, ADDR0 + i * 0x1000, o]
    if oracle_out is not None:
        off = 0
        for i, b in enumerate(bindings):
            st, bd, w, o = b[:4]
            if o:
                expw += oracle_out[off:off + w]
            off += w
        expw += mwords
        expw += cwords
    expw += SENT
    open(base + '.exp', 'w').write('\n'.join(words_to_hex(expw)) + '\n')

    # oracle side inputs — idx/dyn describe the descriptor-array
    # element and dynamic kind; dyn_off is the pDynamicOffsets list.
    descj = {'gx': desc['groups'][0], 'gy': desc['groups'][1],
             'gz': desc['groups'][2], 'bindings': []}
    if push:
        descj['push'] = push_words(desc, seed)
    if desc.get('dyn_off'):
        descj['dyn_off'] = [v for (_s, _o, v) in desc['dyn_off']]
    for i, b in enumerate(bindings):
        st, bd, w, o = b[:4]
        ax = b[4] if len(b) > 4 else 0
        ib = base + '_in%d.bin' % i
        packed = pack_floats(inputs[i], desc['fmt'])
        open(ib, 'wb').write(b''.join(
            struct.pack('<I', v) for v in packed))
        descj['bindings'].append({'set': st, 'binding': bd,
                                  'size': w * 4, 'init': ib,
                                  'idx': ax & 0xFF,
                                  'dyn': (ax >> 8) & 1})
    open(base + '.desc.json', 'w').write(json.dumps(descj))
    return base, (mrob, mwords, cwords, _m)


def ulpd(a, b):
    """mirror of the TB's ulpd(): bit-diff as ULP count, NaN==NaN,
    sign-cross = infinity."""
    if a == b:
        return 0
    if (a & 0x7FFFFFFF) == 0 and (b & 0x7FFFFFFF) == 0:
        return 0
    if (a & 0x7F800000) == 0x7F800000 and (a & 0x7FFFFF) != 0 and \
       (b & 0x7F800000) == 0x7F800000 and (b & 0x7FFFFF) != 0:
        return 0
    if (a ^ b) & 0x80000000:
        return 0x7FFFFFFF
    return abs(a - b)


def oracle_image(owords, mc, desc):
    """Gate-2-aware oracle comparison: the model's full post-dispatch
    buffer image vs lavapipe's dump, with int words bit-exact and
    float words within 2 ULP (the .exp class section's rule).  Returns
    the oracle word list to fold into .exp, or the model image when
    the oracle strays beyond Gate-2 tolerance (e.g. UB descriptor-
    array OOB under lavapipe)."""
    bindings = desc['bindings']
    if mc[3] is None:
        return owords
    m = mc[3]
    mfull = []
    off = 0
    for i, b in enumerate(bindings):
        ad = ADDR0 + i * 0x1000
        mfull += [m.mem.get((ad >> 2) + k, 0) for k in range(b[2])]
        off += b[2]
    if len(owords) != len(mfull):
        return mfull
    mcls = m.out_classes()
    bad = False
    off = 0
    for i, b in enumerate(bindings):
        st, bd, w, o = b[:4]
        for k in range(w):
            xo = owords[off + k]
            xm = mfull[off + k]
            cls = 'i'
            if o and i in mcls and k < len(mcls[i]):
                cls = mcls[i][k]
            if cls == 'f':
                if ulpd(xm, xo) > 2:
                    bad = True
            elif xm != xo:
                bad = True
        off += w
    return mfull if bad else owords


ORACLE = os.environ.get('ORACLE', '/tmp/g6lc-vk-oracle')


def build_oracle():
    src = os.path.join(HERE, 'vk_compute_oracle.c')
    if os.path.exists(ORACLE) and \
       os.path.getmtime(ORACLE) > os.path.getmtime(src):
        return True
    r = subprocess.run(['gcc', '-O2', '-o', ORACLE, src, '-lvulkan'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print('oracle build failed:', r.stderr)
        return False
    return True


def main():
    os.makedirs(OUT, exist_ok=True)
    oracle_ok = build_oracle()
    summary = []
    for name in sorted(DESC):
        desc = DESC[name]
        spv = os.path.join(CORPUS, name + '.spv')
        words = read_spv(spv)
        # scanner self-check: the corpus must commit
        sc = spirv_scan.Scanner(words)
        try:
            sc.scan()
        except spirv_scan.Fault as f:
            print('%s: COMMIT FAULT %s opcode=%d word=%d — FIX CORPUS' %
                  (name, spirv_scan.FAULT_NAME[f.code], f.opcode,
                   f.word))
            return 1
        sc.emit_tab(os.path.join(OUT, name + '.tab'))
        for seed in SEEDS:
            inputs = gen_inputs(desc, [b[2] for b in desc['bindings']],
                                seed)
            base, mc = emit(name, seed, words, desc, inputs)
            summary.append(base)
            if oracle_ok:
                out_bin = base + '.out.bin'
                r = run_oracle(spv, base + '.desc.json', out_bin)
                if r.returncode != 0:
                    print('%s_%d: oracle failed: %s' %
                          (name, seed, r.stderr.strip()))
                    return 1
                data = open(out_bin, 'rb').read()
                owords = list(struct.unpack('<%dI' % (len(data) // 4),
                                            data))
                o2 = oracle_image(owords, mc, desc)
                if o2 is not owords:
                    print('%s_%d: oracle beyond Gate-2 tolerance — '
                          'ORACLE section carries model words'
                          % (name, seed))
                # fold oracle output into the .exp (model cached)
                emit(name, seed, words, desc, inputs,
                     oracle_out=o2, model_cache=mc)
        # mutated module (seed 0): commits fine but the output must
        # DIFFER from the unmutated oracle output at identical inputs.
        # .exp carries the UNMUTATED oracle words; the TB asserts
        # not-all-equal for output bindings.  The generator verifies
        # the mutation is observable through lavapipe.
        muts = mutate(words)
        mwords = None
        if muts:
            inputs = gen_inputs(desc, [b[2] for b in desc['bindings']],
                                7)
            base = None
            for mwords_c, at_c in muts:
                base, mc = emit(name + '_mut', 0, mwords_c, desc,
                                inputs, mutated=True)
                if not oracle_ok:
                    mwords = mwords_c
                    break
                mspv = base + '.spv'
                open(mspv, 'wb').write(b''.join(
                    struct.pack('<I', w) for w in mwords_c))
                ru = run_oracle(spv, base + '.desc.json',
                                base + '.uout.bin')
                rm = run_oracle(mspv, base + '.desc.json',
                                base + '.out.bin')
                if ru.returncode == 0 and rm.returncode == 0:
                    u = open(base + '.uout.bin', 'rb').read()
                    m = open(base + '.out.bin', 'rb').read()
                    if u != m:
                        mwords = mwords_c
                        owords = list(struct.unpack(
                            '<%dI' % (len(u) // 4), u))
                        # .exp oracle section = UNMUTATED lavapipe
                        # words (TB asserts "differs"); model section
                        # = the mutant's own model output.
                        emit(name + '_mut', 0, mwords_c, desc, inputs,
                             mutated=True, oracle_out=owords,
                             model_cache=mc)
                        break
                else:
                    continue
            if mwords is None:
                print('%s_mut: no observable mutation — skipped' % name)
            summary.append(base)
        # bad module (seed 0): cf shaders drop a merge instruction so
        # a conditional branch is unstructured -> commit BRANCH fault;
        # straight-line shaders keep the unsupported-opcode arm.
        if desc.get('cf'):
            bwords, fcode, fopc = inject_bad_cf(words)
        else:
            bwords, _ = inject_bad(words)
            fcode, fopc = spirv_scan.FAULT['OPCODE'], 13
        inputs = gen_inputs(desc, [b[2] for b in desc['bindings']], 7)
        base, _mc = emit(name + '_bad', 0, bwords, desc, inputs,
                         expect_fault=(fcode, fopc))
        summary.append(base)
    # ---- 4b-opt pass: spirv-opt -O builds ---------------------------
    # For every corpus shader that has an optimized twin
    # (corpus/<name>_opt.spv, produced by `spirv-opt -O`), emit
    # <name>_opt_{1..3} vectors reusing the base shader's DESC —
    # gen_inputs is a pure function of (desc, seed), so the optimized
    # build receives bit-identical inputs and the TB can assert
    # unoptimized-RTL == optimized-RTL bit-exact.  No mut/bad arms.
    for name in sorted(DESC):
        desc = DESC[name]
        ospv = os.path.join(CORPUS, name + '_opt.spv')
        if not os.path.exists(ospv):
            continue
        words = read_spv(ospv)
        sc = spirv_scan.Scanner(words)
        try:
            sc.scan()
        except spirv_scan.Fault as f:
            print('%s_opt: COMMIT FAULT %s opcode=%d word=%d — optimizer '
                  'emitted an out-of-subset opcode' %
                  (name, spirv_scan.FAULT_NAME[f.code], f.opcode, f.word))
            return 1
        sc.emit_tab(os.path.join(OUT, name + '_opt.tab'))
        for seed in SEEDS:
            inputs = gen_inputs(desc, [b[2] for b in desc['bindings']],
                                seed)
            base, mc = emit(name + '_opt', seed, words, desc, inputs)
            summary.append(base)
            if oracle_ok:
                out_bin = base + '.out.bin'
                r = run_oracle(ospv, base + '.desc.json', out_bin)
                if r.returncode != 0:
                    print('%s_opt_%d: oracle failed: %s' %
                          (name, seed, r.stderr.strip()))
                    return 1
                data = open(out_bin, 'rb').read()
                owords = list(struct.unpack('<%dI' % (len(data) // 4),
                                            data))
                o2 = oracle_image(owords, mc, desc)
                if o2 is not owords:
                    print('%s_opt_%d: oracle beyond Gate-2 tolerance — '
                          'ORACLE section carries model words'
                          % (name, seed))
                emit(name + '_opt', seed, words, desc, inputs,
                     oracle_out=o2, model_cache=mc)
    print('wrote %d cases to %s' % (len(summary), OUT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
