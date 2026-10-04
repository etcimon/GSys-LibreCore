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
}
SEEDS = [1, 2, 3]

sys.path.insert(0, HERE)
import spirv_scan  # noqa: E402
import spirv_model  # noqa: E402


def model_run(hexw, bindings):
    """run spirv_model on a dispatch record; returns
    (robust, model_words_by_out_binding, class_words_by_out_binding).
    Raises spirv_scan.Fault if the module does not commit."""
    m = spirv_model.Model(list(hexw))
    m.run()
    outs = m.outputs()
    cls = m.out_classes()
    mw, cw = [], []
    for i, (st, bd, w, o) in enumerate(bindings):
        if o:
            mw += outs.get(i, [0] * w)
            cw += [1 if c == 'f' else 0 for c in cls.get(i, ['i'] * w)]
    return m.robust, mw, cw


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
    the output."""
    pairs = {129: 131, 131: 129, 128: 130, 130: 128, 133: 136, 136: 133}
    out = []
    for i in range(5, len(words)):
        opc = words[i] & 0xFFFF
        if opc in pairs:
            m = list(words)
            m[i] = (words[i] & 0xFFFF0000) | pairs[opc]
            out.append((m, i))
    if out:
        return out
    # fallback: reroute the last index operand of the first dynamic
    # OpAccessChain to a constant -> every lane reads element 0.
    consts = [words[i + 2] for i in range(5, len(words))
              if (words[i] & 0xFFFF) == 43 and i + 2 < len(words)]
    if not consts:
        return out
    for i in range(5, len(words)):
        if (words[i] & 0xFFFF) == 65 and (words[i] >> 16) >= 4:
            wc = words[i] >> 16
            if words[i + wc - 1] != consts[0]:
                m = list(words)
                m[i + wc - 1] = consts[0]
                out.append((m, i + wc - 1))
    return out


def inject_bad(words):
    """append an unsupported opcode (OpSin=13) as a trailing
    instruction inside the module: we turn the last OpReturn (253,
    wc=1) into OpReturnValue-free space — simplest: insert OpNop->
    OpSin swap on the first OpNop-able word.  We patch the first
    OpStore's opcode word to OpSin so the commit scanner faults with
    opcode 13 at a deterministic word."""
    for i in range(5, len(words)):
        if (words[i] & 0xFFFF) == 62:      # first OpStore
            m = list(words)
            m[i] = (words[i] & 0xFFFF0000) | 13
            return m, i
    # no OpStore: patch the last word (OpReturn -> OpSin)
    m = list(words)
    m[-2] = (m[-2] & 0xFFFF0000) | 13
    return m, len(m) - 2


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
    for i, (st, bd, w, o) in enumerate(bindings):
        hexw += [st, bd, w * 4, ADDR0 + i * 0x1000]
    hexw += push_words(desc, seed)
    for i in range(len(bindings)):
        hexw += pack_floats(inputs[i], desc['fmt'])
    hexw += SENT
    open(base + '.hex', 'w').write('\n'.join(words_to_hex(hexw)) + '\n')

    # model run (skipped for commit-fault modules); model_cache lets
    # the post-oracle re-emit reuse the result.
    if model_cache is not None:
        mrob, mwords, cwords = model_cache
    elif not expect_fault[0]:
        mrob, mwords, cwords = model_run(hexw, bindings)
    else:
        mrob, mwords, cwords = 0, None, None
    robust = mrob

    expw = [expect_fault[0], expect_fault[1], robust,
            0 if expect_fault[0] else 1, len(bindings)]
    for i, (st, bd, w, o) in enumerate(bindings):
        expw += [bd, w * 4, ADDR0 + i * 0x1000, o]
    if oracle_out is not None:
        off = 0
        for i, (st, bd, w, o) in enumerate(bindings):
            if o:
                expw += oracle_out[off:off + w]
            off += w
        expw += mwords
        expw += cwords
    expw += SENT
    open(base + '.exp', 'w').write('\n'.join(words_to_hex(expw)) + '\n')

    # oracle side inputs
    descj = {'gx': desc['groups'][0], 'gy': desc['groups'][1],
             'gz': desc['groups'][2], 'bindings': []}
    if push:
        descj['push'] = push_words(desc, seed)
    for i, (st, bd, w, o) in enumerate(bindings):
        ib = base + '_in%d.bin' % i
        packed = pack_floats(inputs[i], desc['fmt'])
        open(ib, 'wb').write(b''.join(
            struct.pack('<I', v) for v in packed))
        descj['bindings'].append({'set': st, 'binding': bd, 'size': w * 4,
                                  'init': ib})
    open(base + '.desc.json', 'w').write(json.dumps(descj))
    return base, (mrob, mwords, cwords)


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
                # fold oracle output into the .exp (model cached)
                emit(name, seed, words, desc, inputs,
                     oracle_out=owords, model_cache=mc)
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
        # unsupported-opcode module (seed 0): commit fault OPCODE
        bwords, at = inject_bad(words)
        inputs = gen_inputs(desc, [b[2] for b in desc['bindings']], 7)
        base, _mc = emit(name + '_bad', 0, bwords, desc, inputs,
                         expect_fault=(spirv_scan.FAULT['OPCODE'], 13))
        summary.append(base)
    print('wrote %d cases to %s' % (len(summary), OUT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
