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
  then per binding: {set, binding, size_bytes, mem_addr, aux}
       (5 words; aux bit24 = image/sampler bind — then 5 meta words
        follow carrying the record's bytes 10..27:
        {h[31:16],w[15:0]}, {layers[31:16],mdim[15:8],fmt[7:0]},
        swizzle[11:0], sampler word0, sampler word1)
  then n_push_words push words
  then the dynamic-offset section: n entries {set, ordinal, offset}
  then per binding in order: size_bytes/4 init words (image binds:
       device layout — layer-major, per-mip 64B-aligned pitch)
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
                        1 = float → Gate 2 <= 2 ULP,
                        2 = unorm-sampled float → |d| <= 0.005,
                        3 = packed unorm byte lanes → +-1 per byte)
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

sys.path.insert(0, HERE)
import img_fmts  # noqa: E402

# ---- §12.3 C/5b image binds -------------------------------------------
def img_mdim(v, m):
    return max(v >> m, 1)


def img_words(spec):
    """device layout byte size in u32 words (layer-major, per-mip
    64B-aligned pitch) — mirrors vnfront/vn_golden img_layer_bytes."""
    bpp = img_fmts.BPP[spec['fmt'] & 15]
    wm, hm, acc = spec['w'], spec['h'], 0
    for _m in range(spec.get('mips', 1)):
        wd, hd = img_mdim(wm, 0), img_mdim(hm, 0)
        acc += ((wd * bpp + 63) & ~63) * hd
        wm, hm = wd >> 1, hd >> 1
    return acc * spec.get('layers', 1) // 4


def smp_words(s):
    """sampler params -> the record's {w0,w1} (vnfront StSamCk)."""
    s = s or {}
    def q44(x):
        return max(0, min(255, int(round(float(x) * 16))))
    w0 = (s.get('mag', 0) | s.get('min', 0) << 2 | s.get('mm', 0) << 4 |
          s.get('au', 0) << 5 | s.get('av', 0) << 8 |
          s.get('aw', 0) << 11 | s.get('bc', 0) << 14)
    w1 = (q44(s.get('minl', 0.0)) | q44(s.get('maxl', 0.0)) << 8 |
          ((q44(abs(s.get('bias', 0.0))) |
            (0x100 if s.get('bias', 0.0) < 0 else 0)) << 16))
    return w0, w1


def img_spec(spec, seed):
    return spec(seed) if callable(spec) else spec


def img_meta(spec, seed):
    """the 5 record-meta words trailing an image bind entry."""
    sp = img_spec(spec, seed)
    s0, s1 = smp_words(sp.get('smp'))
    mdim = ((sp.get('dim', 0) & 3) << 4) | (sp.get('mips', 1) & 0xF)
    return [sp['w'] | sp['h'] << 16,
            sp['fmt'] | mdim << 8 | sp.get('layers', 1) << 16,
            sp.get('swz', 0), s0, s1]


def img_bind(st, bd, spec, kind, out=0, idx=0, smp=None):
    """image binding tuple; spec may be dict or seed->dict (then smp
    is folded in per seed)."""
    if callable(spec) or smp is not None:
        def full(s, _spec=spec, _smp=smp):
            sp = dict(_spec(s) if callable(_spec) else _spec)
            extra = _smp(s) if callable(_smp) else _smp
            if extra:
                sp['smp'] = extra
            return sp
        spec = full
    size = img_words(img_spec(spec, 1))
    return (st, bd, size, out, (kind << 16) | idx | (1 << 24), spec)


def img_init(spec, seed):
    """init words in device layout (layer-major, 64B-aligned rows)."""
    rng = random.Random(seed * 7919 + spec['w'] + spec['fmt'] * 131)
    fmt = spec['fmt'] & 15
    bpp = img_fmts.BPP[fmt]
    attr = img_fmts.ATTR[fmt]
    isint = (attr >> 3) & 1
    ish16 = (attr >> 5) & 1
    isflt = ((attr >> 4) | ish16) & 1
    buf = bytearray(img_words(spec) * 4)
    wm, hm = spec['w'], spec['h']
    mofs = []
    acc = 0
    for _m in range(spec.get('mips', 1)):
        wd, hd = img_mdim(wm, 0), img_mdim(hm, 0)
        pit = (wd * bpp + 63) & ~63
        mofs.append((acc, pit, wd, hd))
        acc += pit * hd
        wm, hm = wd >> 1, hd >> 1
    layb = acc
    for ly in range(spec.get('layers', 1)):
        for m, (mo, pit, wd, hd) in enumerate(mofs):
            for y in range(hd):
                for x in range(wd):
                    off = ly * layb + mo + y * pit + x * bpp
                    if isint:
                        for c in range(bpp // 4):
                            v = (x * 1009 + y * 101 + c * 11 +
                                 ly * 13 + m * 17 + seed) & 0xFFFFFFFF
                            struct.pack_into('<I', buf, off + c * 4, v)
                    elif isflt and not ish16:
                        for c in range(bpp // 4):
                            f = (x * 0.5 + y * 0.25 + c * 0.125 +
                                 ly * 0.75 + m * 0.375 +
                                 rng.uniform(-0.1, 0.1))
                            struct.pack_into('<f', buf, off + c * 4, f)
                    elif ish16:
                        for c in range(bpp // 2):
                            f = (x * 0.25 + y * 0.125 + c * 0.0625 +
                                 ly * 0.5 + m * 0.25)
                            struct.pack_into('<e', buf, off + c * 2, f)
                    else:
                        for c in range(bpp):
                            buf[off + c] = (x * 53 + y * 31 + c * 17 +
                                            ly * 29 + m * 23 +
                                            seed * 7) & 0xFF
    return [struct.unpack_from('<I', buf, i)[0]
            for i in range(0, len(buf), 4)]


# VkFormat enum for each device format id (img_fmts.VK2D inverted).
IMG_VKFMT = (9, 16, 37, 43, 44, 50, 97, 100, 103, 109, 98, 107)


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
    # ---- §12.3 C/5b image corpus --------------------------------------
    # A binding's 6th element is the image spec (or a function of the
    # case seed returning one): {w,h,fmt,mips,layers,dim,swz,smp}.
    # fmt is the img_fmts device id; dim 0=2D/1=2D-array; swz the
    # packed 4x3b VkComponentSwizzle field (0=identity); smp the
    # sampler parameter dict {mag,min,mm,au,av,aw,bc,minl,maxl,bias}
    # (VkFilter/VkSamplerAddressMode/VkBorderColor codes; lods/bias
    # float).  Descriptor kinds: 1=COMBINED_IMAGE_SAMPLER,
    # 3=STORAGE_IMAGE.  ucls marks SSBO float outs that carry
    # unorm-sampled values (Gate-2 abs tolerance, class 2).
    'texfetch':     dict(groups=(1, 1, 1), fmt='i', push=0, cf=False,
                         ucls=True,
                         bindings=[
        img_bind(0, 0, dict(w=4, h=4, fmt=2), kind=1),
        (0, 1, 32, 1, 7 << 16)]),
    'texfetch_mip': dict(groups=(1, 1, 1), fmt='i', push=0, cf=False,
                         ucls=True,
                         bindings=[
        img_bind(0, 0, dict(w=4, h=4, fmt=2, mips=2), kind=1),
        (0, 1, 32, 1, 7 << 16)]),
    # texlod_lin varies the address mode pair per seed: REPEAT /
    # MIRRORED_REPEAT / CLAMP_TO_EDGE / CLAMP_TO_BORDER (opaque-white
    # and opaque-black borders) all appear across seeds 1..3.
    'texlod_lin':   dict(groups=(1, 1, 1), fmt='i', push=0, cf=False,
                         ucls=True,
                         bindings=[
        img_bind(0, 0, dict(w=4, h=4, fmt=2), kind=1,
                 smp=lambda s: dict(
                     mag=1, min=1,
                     au=(0, 1, 2)[(s - 1) % 3],
                     av=(2, 3, 0)[(s - 1) % 3],
                     bc=(0, 4, 2)[(s - 1) % 3])),
        (0, 1, 32, 1, 7 << 16)]),
    'texlod_mip':   dict(groups=(1, 1, 1), fmt='i', push=0, cf=False,
                         ucls=True,
                         bindings=[
        img_bind(0, 0, dict(w=4, h=4, fmt=2, mips=3), kind=1,
                 smp=dict(mag=1, min=1, mm=1, au=2, av=2,
                          maxl=2.0)),
        (0, 1, 32, 1, 7 << 16)]),
    'imgloadstore': dict(groups=(1, 1, 1), fmt='i', push=0, cf=False,
                         bindings=[
        img_bind(0, 0, dict(w=4, h=2, fmt=9), kind=3),
        img_bind(0, 1, dict(w=4, h=2, fmt=9), kind=3, out=1),
        (0, 2, 32, 1, 7 << 16)]),
    'texarr':       dict(groups=(1, 1, 1), fmt='i', push=0, cf=False,
                         ucls=True,
                         bindings=[
        img_bind(0, 0, dict(w=2, h=2, fmt=2, layers=4, dim=1),
                 kind=1),
        (0, 1, 32, 1, 7 << 16)]),
    # texsrgb: R8G8B8A8_SRGB sample + R8G8B8A8_UNORM (rgba8) store.
    # The store-out words carry packed unorm bytes -> class 3.
    'texsrgb':      dict(groups=(1, 1, 1), fmt='i', push=0, cf=False,
                         ucls=True,
                         bindings=[
        img_bind(0, 0, dict(w=4, h=2, fmt=3), kind=1),
        img_bind(0, 1, dict(w=4, h=2, fmt=2), kind=3, out=1),
        (0, 2, 32, 1, 7 << 16)]),
    'texquery':     dict(groups=(1, 1, 1), fmt='i', push=0, cf=False,
                         bindings=[
        img_bind(0, 0, dict(w=4, h=4, fmt=2, mips=2), kind=1),
        img_bind(0, 1, dict(w=4, h=2, fmt=10), kind=3),
        (0, 2, 32, 1, 7 << 16)]),
}
SEEDS = [1, 2, 3]

sys.path.insert(0, HERE)
import spirv_scan  # noqa: E402
import spirv_model  # noqa: E402


CLSMAP = {'i': 0, 'f': 1, 'u': 2, 'p': 3}


def model_run(hexw, bindings, ucls=False):
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
            cc = list(cls.get(i, ['i'] * w))
            if ucls and not (len(b) > 5):
                # unorm-sampled floats in the SSBO compare against
                # lavapipe with the §12.3 1/255-class tolerance
                cc = ['u' if c == 'f' else c for c in cc]
            cw += [CLSMAP[c] for c in cc]
    return m.robust, mw, cw, m


def words_to_hex(words):
    return ['%08x' % (w & 0xFFFFFFFF) for w in words]


def read_spv(path):
    data = open(path, 'rb').read()
    return list(struct.unpack('<%dI' % (len(data) // 4), data))


def gen_inputs(desc, seed):
    # one RNG stream per shader, consumed binding-by-binding — the
    # pre-5b vectors depend on this exact stream; image inits get
    # their own rng inside img_init.
    rng = random.Random(seed * 7919 +
                        sum(x[2] for x in desc['bindings']))
    outs = []
    for b in desc['bindings']:
        if len(b) > 5:
            outs.append(img_init(img_spec(b[5], seed), seed))
            continue
        w = b[2]
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
    # §12.3 C/5b: aux bit24 marks an image/sampler bind — 5 meta words
    # (the record's bytes 10..27) follow the entry.
    for i, b in enumerate(bindings):
        st, bd, w, o = b[:4]
        ax = b[4] if len(b) > 4 else 0
        hexw += [st, bd, w * 4, ADDR0 + i * 0x1000, ax]
        if ax & (1 << 24):
            hexw += img_meta(b[5], seed)
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
        mrob, mwords, cwords, _m = model_run(
            hexw, bindings, ucls=desc.get('ucls', False))
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
        bd_j = {'set': st, 'binding': bd, 'size': w * 4, 'init': ib,
                'idx': ax & 0xFF, 'dyn': (ax >> 8) & 1,
                'kind': (ax >> 16) & 0xFF or 7}
        if ax & (1 << 24):
            # image/sampler record (§12.3 C/5b): flat keys keep the
            # oracle's permissive JSON scanner happy
            sp = img_spec(b[5], seed)
            smp = sp.get('smp') or {}
            bd_j['img'] = 1
            bd_j['imgfmt'] = IMG_VKFMT[sp['fmt'] & 15]
            bd_j['imgw'] = sp['w']
            bd_j['imgh'] = sp['h']
            bd_j['imgmips'] = sp.get('mips', 1)
            bd_j['imglayers'] = sp.get('layers', 1)
            bd_j['imgarr'] = sp.get('dim', 0)
            swz = sp.get('swz', 0)
            for c in range(4):
                bd_j['swz%d' % c] = (swz >> (3 * c)) & 7
            for k in ('mag', 'min', 'mm', 'au', 'av', 'aw', 'bc'):
                bd_j['smp' + k] = smp.get(k, 0)
            bd_j['smpminl'] = int(round(smp.get('minl', 0.0) * 16))
            bd_j['smpmaxl'] = int(round(smp.get('maxl', 0.0) * 16))
            bd_j['smpbias'] = int(round(smp.get('bias', 0.0) * 16))
        descj['bindings'].append(bd_j)
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
    ucls = desc.get('ucls', False)
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
            if ucls and len(b) <= 5 and cls == 'f':
                cls = 'u'
            if cls == 'f':
                if ulpd(xm, xo) > 2:
                    bad = True
            elif cls == 'u':
                if abs(struct.unpack('<f', struct.pack('<I', xm))[0] -
                       struct.unpack('<f', struct.pack('<I', xo))[0]) \
                        > 0.005:
                    bad = True
            elif cls == 'p':
                for bb in range(4):
                    if abs(((xm >> (8 * bb)) & 0xFF) -
                           ((xo >> (8 * bb)) & 0xFF)) > 1:
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
            inputs = gen_inputs(desc, seed)
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
            inputs = gen_inputs(desc, 7)
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
        inputs = gen_inputs(desc, 7)
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
            inputs = gen_inputs(desc, seed)
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
