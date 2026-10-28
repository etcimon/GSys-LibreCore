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
                        3 = packed unorm byte lanes → +-1 per byte,
                        4|(op<<8) = sfu op index (xnum-13) → bound
                        from g6lc_apu_sfu_pkg.APU_SFU_BND_*)
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
          s.get('aw', 0) << 11 | s.get('bc', 0) << 14 |
          s.get('cmo', 0) << 17 | s.get('cen', 0) << 20)
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


def _lin(a, b, n=32):
    return [a + (b - a) * i / (n - 1) for i in range(n)]


_P = 3.141592653589793
_INF = float('inf')
_NINF = float('-inf')
_NAN = float('nan')

# §7d sfu_* src records — 8 component lists (32 values each):
# src[i] = (a.x,a.y,a.z,a.w), src[i+32] = (b.x,b.y,b.z,b.w).
SFU_IN = {
    'sfu_exp': (
        [_lin(-20.0, 10.0),                      # a.x -> exp
         _lin(-140.0, 127.5),                    # a.y -> exp2
         [0.0, 1.0, -1.0, 2.0, -2.0, 88.0, 88.7, 89.0, -87.3, -100.0,
          -103.0, -104.0, _INF, _NINF, _NAN, 1e-30, -1e-30, 86.0, 87.0,
          2.5, -2.5, 3.7, -3.7, 0.5, -0.5, 10.0, -10.0, 50.0, -50.0,
          70.0, -70.0, 87.5],                    # a.z -> exp (specials)
         _lin(-0.5, 0.5)],                       # a.w -> exp2
        [_lin(-90.0, 5.0),                       # b.x -> exp
         [0.0, -1.0, 1.0, 2.0, -126.0, -127.0, -128.0, -140.0, -149.0,
          -150.0, -151.0, 127.0, 127.5, 128.0, 129.0, _INF, _NINF,
          _NAN, -0.5, 0.5, -10.0, 10.0, -50.0, 50.0, -20.0, 20.0,
          -149.9, 32.0, 64.0, -64.0, -100.0, 4.0],  # b.y -> exp2
         _lin(-3.0, 3.0),                        # b.z -> exp
         _lin(-160.0, -110.0)]),                 # b.w -> exp2
    'sfu_log': (
        [_lin(0.5, 2.0),                         # a.x -> log (band)
         _lin(0.5, 2.0),                         # a.y -> log2 (band)
         [1.0, 2.0, 2.7182817459106445, 0.5, 0.25, 1e-38, 1e-45, _INF,
          0.0, -1.0, -0.5, _NAN, 1e-30, 5.0, 0.1, 100.0, 1000.0, 0.75,
          1.25, 1.5, 1.75, 0.999, 1.001, 4.0, 8.0, 16.0, 32.0, 0.2,
          0.05, 1e-20, 1e20, 64.0],              # a.z -> log (specials)
         _lin(0.25, 4.0)],                       # a.w -> log2
        [[10.0 ** (-6 + 12 * i / 31) for i in range(32)],  # b.x log
         [1.0, 0.5, 0.25, 2.0, 4.0, 8.0, 0.0, -1.0, _INF, _NAN, 1e-45,
          1e-38, 0.75, 1.5, 3.0, 6.0, 10.0, 100.0, 1e3, 1e6, 1e-3,
          1e-6, 0.999, 1.001, 0.501, 1.999, 7.0, 15.0, 31.0, 63.0,
          127.0, 255.0],                         # b.y -> log2
         _lin(0.01, 100.0),                      # b.z -> log
         _lin(0.01, 1000.0)]),                   # b.w -> log2
    'sfu_pow': (
        [[2.0, 0.5, 4.0, 1.5, 0.0, 0.0, 0.0, 1.0, 1.0, -2.0, -2.0,
          1e30, 1e-30, _INF, 2.0, _NAN, -1.0, 2.0, 0.25, 10.0, 2.0,
          0.5, 3.0, 1e-3, -0.0, -0.0, -0.0, _INF, _INF, 1.0000001,
          2.5, 0.75],                            # a.x base
         _lin(0.1, 16.0),                        # a.y base
         _lin(0.05, 8.0),                        # a.z base
         [0.0, 1.0, -1.0, -2.5, 1e-38, 1e20, 0.999, 1.001, 7.0, 11.0,
          0.1, 0.2, 0.3, 0.7, 0.8, 0.9, 1.1, 1.2, 5.5, 9.9, 100.0,
          1e4, 1e-4, _INF, _NAN, -3.0, -0.5, 0.5, 2.0, 4.0, 6.0, 8.0]],  # a.w
        [[3.0, 0.5, -2.0, 7.0, 1.0, 0.0, -1.0, 0.0, 5.0, 2.0, 0.5,
          0.5, 2.0, 2.0, _INF, 1.0, _NAN, -1.0, -0.5, -8.0, -20.0,
          64.0, -150.0, 0.0, 10.0, 1.0, -1.0, 0.0, -1.0, 0.0, 1e7,
          0.3, 1.5],                             # b.x exponent
         _lin(-5.0, 5.0),                        # b.y exponent
         _lin(-3.0, 3.0),                        # b.z exponent
         [0.5, -0.5, 0.0, 2.0, -2.0, 10.0, -10.0, 1.0, -1.0, 3.0,
          -3.0, 0.25, -0.25, 1e-3, -1e-3, 20.0, -20.0, 100.0, -100.0,
          _INF, _NINF, _NAN, 0.0, 0.0, 4.0, -4.0, 6.0, -6.0, 8.0,
          -8.0, 0.75, -0.75]]),                  # b.w exponent
    'sfu_trig': (
        [_lin(-4.0 * _P, 4.0 * _P),              # a.x -> sin
         _lin(-4.0 * _P, 4.0 * _P),              # a.y -> cos
         _lin(-1.5, 1.5),                        # a.z -> tan (poles)
         [0.0, _P / 2, -_P / 2, _P, -_P, 2 * _P, -2 * _P, 1.5 * _P,
          -1.5 * _P, 1e6, -1e6, _INF, _NINF, _NAN, 1e-30, -1e-30,
          _P / 4, -_P / 4, _P / 6, -_P / 6, _P / 3, -_P / 3, 1e-4,
          -1e-4, 3 * _P, -3 * _P, 4 * _P, -4 * _P, 0.1, -0.1, 5.0,
          -5.0]],                                # a.w -> cos
        [[0.0, _P / 6, _P / 4, _P / 3, _P / 2, -_P / 6, -_P / 4,
          -_P / 3, -_P / 2, _P, -_P, 2 * _P, 1e-30, 1e20, -1e20, _INF,
          _NINF, _NAN, 100.0, -100.0, 1000.0, 0.1, -0.1, 3.14159,
          -3.14159, 6.28, -6.28, 12.56, -12.56, 50.0, -50.0, 5.0],
         _lin(-1.55, 1.55),                      # b.y -> tan
         _lin(0.0, 2.0 * _P),                    # b.z -> cos(b.z+b.w)
         [0.0] * 32]),                           # b.w -> cos arg 0
    'sfu_atrig': (
        [_lin(-1.0, 1.0),                        # a.x -> asin
         _lin(-1.0, 1.0),                        # a.y -> acos
         _lin(-10.0, 10.0),                      # a.z -> atan
         [0.0, -0.0, 0.0, -0.0, 1.0, -1.0, 1.0, -1.0, 1e30, -1e30,
          _INF, _NINF, 0.5, -0.5, 0.7, -0.7, 2.0, -2.0, 100.0, -100.0,
          0.0, 1.0, -1.0, 0.5, -0.5, 3.0, -3.0, 1e-3, -1e-3, 0.9,
          -0.9, 0.1]],                           # a.w -> atan2 y
        [[1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0,
          -1.0, 1.0, -1.0, 1.0, -1.0, 0.0, 0.0, _INF, _NINF, _NAN,
          2.0, 0.5, -0.5, 0.7, -0.7, 1e30, -1e30, 0.3, -0.3, 4.0,
          -4.0],                                 # b.x -> atan2 x
         [-1.0, 1.0, 0.0, 1.5, -1.5, _NAN, _INF, _NINF, 0.5, -0.5,
          0.999, -0.999, 0.0001, -0.0001, 0.7071, -0.7071, 0.866,
          -0.866, 1.000001, -1.000001, 1e-10, -1e-10, 2.0, -2.0, 0.3,
          -0.3, 0.99, -0.99, 0.6, -0.6, 0.4, -0.4],   # b.y -> asin
         [-1.0, 1.0, 0.0, 1.5, -1.5, _NAN, _INF, _NINF, 0.5, -0.5,
          0.999, -0.999, 0.0001, -0.0001, 0.7071, -0.7071, 0.866,
          -0.866, 1.000001, -1.000001, 1e-10, -1e-10, 2.0, -2.0, 0.3,
          -0.3, 0.99, -0.99, 0.6, -0.6, 0.4, -0.4],   # b.z -> acos
         [0.0, 1.0, -1.0, _INF, _NINF, _NAN, 1e20, -1e20, 1e-20,
          -1e-20, 0.5, -0.5, 2.0, -2.0, 100.0, -100.0, 1e6, -1e6,
          0.001, -0.001, 45.0, -45.0, 0.7854, -0.7854, 3.0, -3.0,
          7.7, -7.7, 1e-8, -1e-8, 0.9, -0.9]]),    # b.w -> atan
    'sfu_hyper': (
        [_lin(-10.0, 10.0),                      # a.x -> sinh
         _lin(-10.0, 10.0),                      # a.y -> cosh
         _lin(-10.0, 10.0),                      # a.z -> tanh
         _lin(-1e4, 1e4)],                       # a.w -> asinh
        [[1.0, 1.0001, 2.0, 5.0, 10.0, 1e3, 1e6, 0.5, 0.0, -1.0, _NAN,
          _INF, 1.5, 1.2, 1.8, 3.0, 100.0, 1e4, 1e5, 0.99, 0.9, 0.8,
          1.00001, 1.1, 1.3, 1.7, 2.5, 7.0, 20.0, 50.0, 1e2, 1.9],
         [-0.99, 0.99, -1.0, 1.0, -1.5, 1.5, _NAN, 0.0, 0.5, -0.5,
          0.9, -0.9, 0.999, -0.999, 0.1, -0.1, 0.75, -0.75, 1.0,
          -1.0, 2.0, -2.0, _INF, _NINF, 0.3, -0.3, 0.6, -0.6, 0.99,
          -0.99, 0.05, -0.05],                   # b.y -> atanh
         [0.0, -0.0, 1.0, -1.0, 88.0, 89.0, -88.0, -89.0, _INF,
          _NINF, _NAN, 10.0, -10.0, 50.0, -50.0, 5.0, -5.0, 0.5,
          -0.5, 2.0, -2.0, 20.0, -20.0, 30.0, -30.0, 87.0, -87.0,
          87.5, -87.5, 1e-10, -1e-10, 0.1],      # b.z -> sinh
         [0.0, 1.0, -1.0, 88.0, 89.0, -88.0, -89.0, _INF, _NINF, _NAN,
          10.0, -10.0, 50.0, -50.0, 5.0, -5.0, 0.5, -0.5, 2.0, -2.0,
          20.0, -20.0, 30.0, -30.0, 87.0, -87.0, 87.5, -87.5, 1e-10,
          0.1, -0.1, 100.0]]),                   # b.w -> cosh
}


def nclamp_in(seed, bi, w):
    """nclamp input hook — a=src[0:32], b=src[32:64], c=src[64:96];
    NaN planted per slot (see DESC), finite values seeded."""
    rng = random.Random(seed * 977 + bi)
    vals = [struct.unpack('<f', struct.pack(
        '<f', rng.uniform(-8.0, 8.0)))[0] for _ in range(w)]
    for i in range(32):
        if i % 5 == 0:
            vals[i] = _NAN
        if i % 4 == 1 or i % 4 == 3:
            vals[32 + i] = _NAN
        if i % 3 == 2:
            vals[64 + i] = _NAN
    return vals


def sfu_in(name, bi, w):
    """sfu_* input hook for gen_inputs — binding 0 gets the domain-
    spanning record table; any other binding gets zeros."""
    if bi != 0:
        return [0.0] * w
    a, b = SFU_IN[name]
    flat = []
    for i in range(32):
        flat += [a[0][i], a[1][i], a[2][i], a[3][i]]
    for i in range(32):
        flat += [b[0][i], b[1][i], b[2][i], b[3][i]]
    return flat


# per-shader Gate-2 op map: out-binding index -> per-word op index
# (GLSL.std.450 xnum - 13); encoded in the class word as 4|(op<<8).
SFU_OPS = {
    'sfu_exp':    [14, 16] * 4,
    'sfu_log':    [15, 17] * 4,
    'sfu_pow':    [13] * 8,
    'sfu_trig':   [0, 1, 2, 0, 1, 2, 0, 1],
    'sfu_atrig':  [3, 4, 5, 12, 3, 4, 5, 12],
    'sfu_hyper':  [6, 7, 8, 9, 10, 11, 6, 7],
}


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
    # CTS probe corpus (compute.pipeline.basic): the exact guest
    # shaders.  cts_atomic1 = empty_workgroup's atomicAdd block.
    # cts_shared1 = shared_var_single_invocation (SPIR-V 1.0: SSBO
    # rides Uniform+BufferBlock, workgroup slab + both barriers).
    'cts_atomic1':  dict(groups=(1, 1, 1), fmt='z', push=0,
                         bindings=[(0, 0, 1, 1, 7 << 16)]),
    'cts_shared1':  dict(groups=(1, 1, 1), fmt='z', push=0,
                         # mut=False: every arithmetic flip site lands
                         # on shared-slab index math whose reads
                         # collapse to equal-valued cells — oracle-
                         # invisible, and the one oracle-visible site
                         # (word 427) is model-invisible too.
                         mut=False,
                         bindings=[(0, 0, 1, 1, 7 << 16)]),
    # cts_arrlen1 = read_unbound_ssbo: two bindings; bind1's record
    # sizes a 16-byte buffer so OpArrayLength of the runtime member
    # is (16-16)/4 = 0; ssbo0.x must read back 0.
    'cts_arrlen1':  dict(groups=(1, 1, 1), fmt='z', push=0,
                         bindings=[(0, 0, 1, 1, 7 << 16),
                                   (0, 1, 4, 0, 7 << 16)]),
    # cts_arrlensb = read_unbound_ssbo as the guest compiles it
    # (glslang --target-env vulkan1.1 -> StorageBuffer class instead
    # of Uniform+BufferBlock).  Same bindings/expectation.
    'cts_arrlensb': dict(groups=(1, 1, 1), fmt='z', push=0,
                         bindings=[(0, 0, 1, 1, 7 << 16),
                                   (0, 1, 4, 0, 7 << 16)]),
    # cts_sharedg = shared_var_single_group: local 3x2x5 = 30
    # invocations = 4 waves sharing one workgroup slab across a
    # barrier-separated shared exchange.
    'cts_sharedg':  dict(groups=(1, 1, 1), fmt='z', push=0,
                         bindings=[(0, 0, 30, 1, 7 << 16)]),
    # cts_wgloop = webgl_spirv_loop (Tint-built loop): a Function var
    # carries a zero OpConstantNull initializer — the commit must
    # accept it as a no-op on pre-zeroed scratch.  mut=False: the one
    # IAdd->ISub mutation site is the loop counter increment, which
    # would make the `until ==1` exit unreachable.
    'cts_wgloop':   dict(groups=(1, 1, 1), fmt='z', push=0, cf=True,
                         mut=False,
                         bindings=[(0, 0, 1, 1, 7 << 16)]),
    # cts_imgcopy = copy_image_to_ssbo_large (r32ui uimage2D load ->
    # SSBO store): the guest wedge probe — imageLoad on a 2x4 R32UI
    # storage image, one wave of 8 lanes.
    'cts_imgcopy':  dict(groups=(1, 1, 1), fmt='z', push=0,
                         bindings=[
        img_bind(0, 1, dict(w=2, h=4, fmt=10), kind=3),
        (0, 0, 8, 1, 7 << 16)]),
    # cts_b2b = copy_ssbo_* (BufferToBufferInvertTest, SSBO->SSBO):
    # gl_NumWorkGroups*gl_WorkGroupSize sizing, OpArrayLength on the
    # output runtime array, per-lane ~copy of 256 words.
    'cts_b2b':      dict(groups=(1, 1, 1), fmt='i', push=0,
                         bindings=[(0, 0, 256, 0), (0, 1, 256, 1)]),
    # cts_mls64 = max_local_size_*: local_size_x=64 (spec-const folded
    # by Mesa to a literal), 8 waves of one workgroup, every lane
    # stores 1 at values[gl_LocalInvocationIndex].  One 64-word SSBO.
    'cts_mls64':    dict(groups=(1, 1, 1), fmt='z', push=0,
                         bindings=[(0, 0, 64, 1, 7 << 16)]),

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
    # ---- G3a-i corpus ------------------------------------------------
    # fn_call: value-param + inout pointer-param helpers, a depth-3
    # chain, and a two-site early return — OpFunctionCall through the
    # wave call stack (CallDepth=8).
    'fn_call':      dict(groups=(1, 1, 1), fmt='i', push=0,
                         bindings=[(0, 0, 64, 0), (0, 1, 32, 1)]),
    # atomic_hist: LocalSize 32 → four waves share the Workgroup slab
    # counter; the SSBO histogram/max cells + the per-invocation Or
    # cells are the deterministic RMW targets.  mut=False: a flipped
    # index op would move atomicMax onto a histogram cell shared with
    # atomicAdd, and add/max ordering across waves is not commutative.
    'atomic_hist':  dict(groups=(2, 1, 1), fmt='i', push=0,
                         mut=False,
                         bindings=[(0, 0, 64, 0), (0, 1, 96, 1)]),
    # atomic_cas: order-insensitive CAS bump of cell 0 plus per-lane
    # Exchange/Min/And/Xor cells.
    'atomic_cas':   dict(groups=(1, 1, 1), fmt='i', push=0,
                         bindings=[(0, 0, 48, 0), (0, 1, 48, 1)]),
    # bitops: carry/borrow, extended mul, bitfield insert/extract,
    # reverse/count, FindLsb/Msb, any/all/isnan/isinf.
    'bitops':       dict(groups=(1, 1, 1), fmt='i', push=0,
                         bindings=[(0, 0, 64, 0), (0, 1, 96, 1)]),
    # packops: pack/unpack round trips (snorm/unorm/half) + Modf /
    # Frexp / Ldexp — the f16 steps pin the RNE converter.
    'packops':      dict(groups=(1, 1, 1), fmt='f', push=0,
                         bindings=[(0, 0, 48, 0), (0, 1, 96, 1)]),
    # dynvec: hand-assembled — OpVectorExtractDynamic/InsertDynamic +
    # OpUndef/OpCopyObject (glslang lowers indexed vectors through
    # Function temporaries instead).
    'dynvec':       dict(groups=(1, 1, 1), fmt='i', push=0,
                         bindings=[(0, 0, 32, 0), (0, 1, 32, 1)]),
    # nclamp: hand-assembled — GLSL.std.450 NMin/NMax/NClamp are the
    # NaN-suppressing variants (a NaN operand yields the other
    # operand; NaN only when both NaN); glslang emits the F- forms for
    # GLSL min/max/clamp so this needs nclamp.spvasm.  infn plants NaN
    # in each operand slot plus both-NaN pairs:
    #   a[i%5==0]  b[i%4==1 or i%4==3]  c[i%3==2]
    'nclamp':       dict(groups=(1, 1, 1), fmt='f', push=0,
                         infn=nclamp_in,
                         bindings=[(0, 0, 96, 0), (0, 1, 96, 1)]),
    # fn_divret: callee takes an early `return v` under divergence
    # while sibling lanes are parked at the caller merge — the
    # non-kill variant of the all-dead callee unwind.
    'fn_divret':    dict(groups=(1, 1, 1), fmt='i', push=0,
                         bindings=[(0, 0, 64, 0), (0, 1, 32, 1)]),
    # ---- G3a-ii §7d SFU corpus --------------------------------------
    # One shader per op family; sfu_in feeds domain-spanning inputs
    # incl. specials and SFU_OPS maps every output word to its op
    # index (xnum-13) for the class-4 Gate-2 bound compare.
    'sfu_exp':    dict(groups=(4, 1, 1), fmt='f', push=0,
                       infn=lambda s, bi, w: sfu_in('sfu_exp', bi, w),
                       sfuops={1: SFU_OPS['sfu_exp'] * 32},
                       bindings=[(0, 0, 256, 0), (0, 1, 256, 1)]),
    'sfu_log':    dict(groups=(4, 1, 1), fmt='f', push=0,
                       infn=lambda s, bi, w: sfu_in('sfu_log', bi, w),
                       sfuops={1: SFU_OPS['sfu_log'] * 32},
                       bindings=[(0, 0, 256, 0), (0, 1, 256, 1)]),
    'sfu_pow':    dict(groups=(4, 1, 1), fmt='f', push=0,
                       infn=lambda s, bi, w: sfu_in('sfu_pow', bi, w),
                       sfuops={1: SFU_OPS['sfu_pow'] * 32},
                       bindings=[(0, 0, 256, 0), (0, 1, 256, 1)]),
    'sfu_trig':   dict(groups=(4, 1, 1), fmt='f', push=0,
                       infn=lambda s, bi, w: sfu_in('sfu_trig', bi, w),
                       sfuops={1: SFU_OPS['sfu_trig'] * 32},
                       bindings=[(0, 0, 256, 0), (0, 1, 256, 1)]),
    'sfu_atrig':  dict(groups=(4, 1, 1), fmt='f', push=0,
                       infn=lambda s, bi, w: sfu_in('sfu_atrig', bi, w),
                       sfuops={1: SFU_OPS['sfu_atrig'] * 32},
                       bindings=[(0, 0, 256, 0), (0, 1, 256, 1)]),
    'sfu_hyper':  dict(groups=(4, 1, 1), fmt='f', push=0,
                       infn=lambda s, bi, w: sfu_in('sfu_hyper', bi, w),
                       sfuops={1: SFU_OPS['sfu_hyper'] * 32},
                       bindings=[(0, 0, 256, 0), (0, 1, 256, 1)]),
}
SEEDS = [1, 2, 3]

sys.path.insert(0, HERE)
import spirv_scan  # noqa: E402
import spirv_model  # noqa: E402
import sfu_tables  # noqa: E402


CLSMAP = {'i': 0, 'f': 1, 'u': 2, 'p': 3}


def model_run(hexw, bindings, ucls=False, sfuops=None):
    """run spirv_model on a dispatch record; returns
    (robust, model_words_by_out_binding, class_words_by_out_binding,
    the Model).  Raises spirv_scan.Fault if the module can't commit.
    sfuops: per-output-word dict {binding_idx: [opidx, ...]} — encodes
    class 4|(opidx<<8) so the TB compares against APU_SFU_BND_*."""
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
            if sfuops and i in sfuops:
                cw += [4 | (op << 8) for op in sfuops[i]]
            else:
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
    for bi, b in enumerate(desc['bindings']):
        if len(b) > 5:
            outs.append(img_init(img_spec(b[5], seed), seed))
            continue
        w = b[2]
        infn = desc.get('infn')
        if infn is not None:
            outs.append(infn(seed, bi, w))
            continue
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
         mutated=False, oracle_out=None, model_cache=None,
         expect_done=None):
    """writes <name>_<seed>.{hex,exp,desc.json,init bin files}

    The .exp robust field and the trailing MODEL/CLASS sections come
    from spirv_model.py run over THIS case's module words (including
    the mutated module for _mut_0 cases) — Gate 1 is bit-exact for
    every case that commits."""
    base = os.path.join(OUT, '%s_%d' % (name, seed))
    push = desc.get('push', 0)
    bindings = desc['bindings']
    # G3b-iii DispatchBase (desc['base'] = {gbx,gby,gz}): flags bit4
    # parks the base group in 3 words between the tag and the module.
    wbase = tuple(desc.get('base', (0, 0, 0)))
    hexw = [len(spv_words), len(bindings), push,
            desc['groups'][0], desc['groups'][1], desc['groups'][2],
            (1 if expect_fault[0] else 0) | (2 if mutated else 0) |
            (0x10 if any(wbase) else 0), 0]
    if any(wbase):
        hexw += list(wbase)
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
            hexw, bindings, ucls=desc.get('ucls', False),
            sfuops=desc.get('sfuops'))
    else:
        mrob, mwords, cwords, _m = 0, None, None, None
    robust = mrob

    expw = [expect_fault[0], expect_fault[1], robust,
            (0 if expect_fault[0] else 1) if expect_done is None
            else expect_done, len(bindings)]
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
    elif expect_done == 2:
        # G3a-i runtime-fault arm (CallDepth overflow): the model
        # stops the faulting invocation at the same instruction, so
        # bindings it never stored hold their preload image — Gate-1
        # compares against exactly that.  The oracle section repeats
        # the model words (there is no lavapipe run for a fault arm).
        outs = _m.outputs()
        ocls = _m.out_classes()
        ow = []
        cc = []
        for i, b in enumerate(bindings):
            st, bd, w, o = b[:4]
            if o:
                ow += [v & 0xFFFFFFFF
                       for v in outs.get(
                           i, pack_floats(inputs[i], desc['fmt']))]
                cc += [CLSMAP[c]
                       for c in ocls.get(i, ['i'] * w)]
        expw += ow + ow + cc
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


# SFU op-index order (xnum - 13) — mirrors gen_sfu_tables' emission
# of APU_SFU_BND_E20/APU_SFU_BND_ABS.
SFU_OP_ORDER = ('sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'sinh',
                'cosh', 'tanh', 'asinh', 'acosh', 'atanh', 'atan2',
                'pow', 'exp', 'log', 'exp2', 'log2')


def sfu_bound(op):
    """('a', abs) for absolute-error bounds (a positive bound < 1.0),
    else ('u', ulp) — same encoding rule the generator uses for the
    APU_SFU_BND_E20/BND_ABS package arrays."""
    b = sfu_tables.BOUNDS[SFU_OP_ORDER[op]]
    return ('a', b) if 0 < b < 1 else ('u', b)


def oracle_image(owords, mc, desc):
    """Gate-2-aware oracle comparison: the model's full post-dispatch
    buffer image vs lavapipe's dump, with int words bit-exact and
    float words within 2 ULP (the .exp class section's rule).  Returns
    the oracle word list to fold into .exp, or the model image when
    the oracle strays beyond Gate-2 tolerance (e.g. UB descriptor-
    array OOB under lavapipe).  For sfuops-described bindings the
    check is per-word against the op's generated bound and only the
    out-of-bound words fall back to the model image, so lavapipe
    keeps Gate-2 coverage wherever it is inside the budget."""
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
    sfuops = desc.get('sfuops')
    bad = False
    ow = list(owords)
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
            if o and sfuops and i in sfuops and k < len(sfuops[i]):
                kind, bv = sfu_bound(sfuops[i][k])
                if kind == 'a':
                    ok = xo == xm or abs(
                        struct.unpack('<f', struct.pack('<I', xm))[0] -
                        struct.unpack('<f', struct.pack('<I', xo))[0]
                    ) <= bv
                else:
                    ok = ulpd(xm, xo) <= bv
                if not ok:
                    ow[off + k] = xm
            elif cls == 'f':
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
    if bad:
        return mfull
    return ow


# ---- G1a graphics wave work (Vertex/Fragment records) ----------------
# A gfx vector carries no descriptor bindings: the dispatch record is
# {count, in_base, out_base, vbase, inst} and the input/output images
# are aperture-resident record batches (layout in g6lc_apu_sh_pkg).
GFXIN = 0x40000        # input-record arena base (aperture byte addr)
GFXOUT = 0x50000       # output-record arena base
GFXBIND = 0x60000      # texture binding base (gfx vectors)
GFX = {
    # 8 vertices: pos@loc0, col@loc1 -> vcol(loc0) + gl_Position
    'vs_passthru': dict(stage=0, count=8, vbase=3, inst=0),
    # vs_texlod: G3a-ii vertex-stage texture — OpImageSampleExplicitLod
    # Lod=0 (the dEQP texture.*_vertex shape); set0/binding0 combined
    # sampler on a 4x4 colour map, NEAREST/CLAMP.
    'vs_texlod':   dict(stage=0, count=8, vbase=3, inst=0,
                       binds=[img_bind(0, 0, dict(w=4, h=4, fmt=2),
                                       kind=1,
                                       smp=dict(mag=0, min=0, mm=0,
                                                au=2, av=2))]),
    # 16 fragments: FragCoord + vcol(loc0) -> o(loc0)
    'fs_color':    dict(stage=4, count=16, vbase=0, inst=0),
    # 16 fragments in 4 quads: linear loc-0 varyings exercise
    # dFdx/dFdy/fwidth plus the Fine/Coarse forms (vbase.0 fronts)
    'fs_deriv':    dict(stage=4, count=16, vbase=1, inst=0),
    # 16 fragments: vcol.xy texcoords, a 2-mip texture and per-quad
    # uv gradients that select mip 1 in quads 0/2 and mip 0 in 1/3
    'fs_tex_implicit': dict(stage=4, count=16, vbase=1, inst=0,
                           binds=[img_bind(0, 0,
                                           dict(w=4, h=4, fmt=2,
                                                mips=2),
                                           kind=1,
                                           smp=dict(mag=0, min=0,
                                                    mm=0, au=2,
                                                    av=2,
                                                    maxl=2.0))]),
    # ---- G3a-i graphics corpus -------------------------------------
    # fs_fncall: the fn_call helper family in an FS (value params,
    # inout pointer param, depth-3 chain, early return).
    'fs_fncall':   dict(stage=4, count=16, vbase=0, inst=0),
    # fs_kill: checkerboard discard on FragCoord — lanes 8..15 of the
    # batch die (x>=8), slot-8 flags mark them.
    'fs_kill':     dict(stage=4, count=16, vbase=0, inst=0),
    # geomops: FaceForward/Reflect/Refract/Determinant/MatrixInverse
    # over the vcol input.
    'geomops':     dict(stage=4, count=16, vbase=0, inst=0),
    # atomic_frag: FS with an SSBO atomic counter + max
    # (fragmentStoresAndAtomics); count stays inside the binding.
    # Lanes 2,5,9,11 are helper invocations (partial-quad fills as
    # rast marks them): their atomic adds are suppressed, their
    # out-records still land.
    'atomic_frag': dict(stage=4, count=16, vbase=0, inst=0,
                       help=(1 << 2) | (1 << 5) | (1 << 9) | (1 << 11),
                       binds=[(0, 0, 8, 1, 7 << 16)]),
    # fs_demote_deriv: odd-x lanes demote then round-trip v through a
    # Function-storage local; dFdxFine(v) in the survivors needs the
    # demoted lane's private store — helper rules keep Function/
    # Private/Output storage live.
    'fs_demote_deriv': dict(stage=4, count=16, vbase=0, inst=0),
    # fs_kill_fn: odd-x lanes call a discarding callee and die while
    # even-x lanes are parked at the caller merge — the all-dead
    # callee frame pop must resume the parked lanes, not finish.
    'fs_kill_fn':  dict(stage=4, count=16, vbase=0, inst=0),
    # ---- G3a-ii §7d texture corpus ----------------------------------
    # fs_tex_shadow: D16_UNORM depth map + compareEnable/LESS_OR_EQUAL
    # LINEAR sampler — dref implicit (89) / explicit (90),
    # proj-dref (93) and dref-gather (97).
    'fs_tex_shadow': dict(stage=4, count=16, vbase=0, inst=0,
                         binds=[img_bind(
                             0, 0, dict(w=4, h=4, fmt=13), kind=1,
                             smp=dict(mag=1, min=1, mm=0, au=2, av=2,
                                      cen=1, cmo=3))]),
    # fs_tex_proj: textureProj implicit (91) / explicit (92) + a plain
    # sample (87) on a colour map.
    'fs_tex_proj':   dict(stage=4, count=16, vbase=0, inst=0,
                         binds=[img_bind(
                             0, 0, dict(w=4, h=4, fmt=2), kind=1,
                             smp=dict(mag=1, min=1, mm=0,
                                      au=2, av=2))]),
    # fs_tex_gather: OpImageGather (96) comp 0/1 + ConstOffset (1,0).
    'fs_tex_gather': dict(stage=4, count=16, vbase=0, inst=0,
                         binds=[img_bind(
                             0, 0, dict(w=4, h=4, fmt=2), kind=1,
                             smp=dict(mag=0, min=0, mm=0,
                                      au=2, av=2))]),
    # fs_tex_qlod: OpImageQueryLod (105) — clamped + unclamped λ on a
    # 4-mip texture.
    'fs_tex_qlod':   dict(stage=4, count=16, vbase=0, inst=0,
                         binds=[img_bind(
                             0, 0, dict(w=4, h=4, fmt=2, mips=4),
                             kind=1,
                             smp=dict(mag=1, min=1, mm=1, au=2, av=2,
                                      maxl=3.0))]),
    # fs_tex_bias: OpImageSampleImplicitLod + Bias image operand
    # (mask 0x1) — per-quad bias flips the mip choice across the
    # λ=0 boundary; the dEQP texture().bias shape.
    'fs_tex_bias':   dict(stage=4, count=16, vbase=1, inst=0,
                         binds=[img_bind(
                             0, 0, dict(w=4, h=4, fmt=2, mips=2),
                             kind=1,
                             smp=dict(mag=0, min=0, mm=1, au=2, av=2,
                                      maxl=2.0))]),
    # fs_tex_array: sampler2DArray implicit LOD — coord.z is the array
    # layer (W_TXC1 F2I), 4 layers on a 2-mip map; the dEQP
    # sampler2darray_fixed_fragment shape.
    'fs_tex_array':  dict(stage=4, count=16, vbase=1, inst=0,
                         binds=[img_bind(
                             0, 0, dict(w=4, h=4, fmt=2, mips=2,
                                        dim=1, layers=4),
                             kind=1,
                             smp=dict(mag=0, min=0, mm=1, au=2, av=2,
                                      maxl=2.0))]),
}
GFX_SEEDS = [1]


def f2b_w(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def gfx_inputs(name, g, seed):
    """deterministic input records — one record per invocation,
    fields at their record-layout offsets (attr/vary strides)."""
    w = []
    if name == 'fs_deriv':
        # loc-0 varying linear inside every 2x2 quad so each lane's
        # derivatives are exact: r -> dx .125, g -> dy .25,
        # b -> dx .0625 + dy .125 (fwidth .1875),
        # a -> dx .5 + dy .25 for the Fine/Coarse terms (q adds a
        # per-quad base so the quads differ)
        for i in range(g['count']):
            lx, ly, q = i & 1, (i >> 1) & 1, i >> 2
            rec = [0] * (spirv_model.VARY_STRIDE // 4)
            rec[0] = f2b_w(i + 0.5)
            rec[1] = f2b_w(0.5)
            rec[2] = f2b_w(0.0)
            rec[3] = f2b_w(1.0)
            rec[4] = f2b_w(0.125 * lx + 0.5 * q + 0.03125)
            rec[5] = f2b_w(0.25 * ly + 0.125 * q)
            rec[6] = f2b_w(0.0625 * lx + 0.125 * ly)
            rec[7] = f2b_w(0.5 * lx + 0.25 * ly + 0.03125 * q)
            w += rec
        return w
    if name == 'fs_tex_implicit':
        # vcol.xy texcoords: quad 0 dx-only 0.5 px^-1, quad 1 a mild
        # 0.125, quad 2 dy-only 0.5, quad 3 mild in both — a 4x4
        # mip-0 texture puts quads 0/2 at lambda=+1 (mip 1) and
        # quads 1/3 at lambda=-1 (mip 0)
        for i in range(g['count']):
            lx, ly, q = i & 1, (i >> 1) & 1, i >> 2
            du = (0.5, 0.125, 0.0, 0.0625)[q]
            dv = (0.0, 0.0, 0.5, 0.125)[q]
            rec = [0] * (spirv_model.VARY_STRIDE // 4)
            rec[0] = f2b_w(i + 0.5)
            rec[1] = f2b_w(0.5)
            rec[2] = f2b_w(0.0)
            rec[3] = f2b_w(1.0)
            rec[4] = f2b_w(0.25 + lx * du)
            rec[5] = f2b_w(0.25 + ly * dv + (0.25 if q == 2 else 0.0))
            w += rec
        return w
    if name == 'fs_tex_shadow':
        # vcol = {u, v, dref, proj-divisor}: uv across the 4x4 D16
        # depth map, ref sweeping 0..1 so the LESS_OR_EQUAL PCF mixes
        # pass/fail, divisor varies the projected lookup.
        for i in range(g['count']):
            rec = [0] * (spirv_model.VARY_STRIDE // 4)
            rec[0] = f2b_w(i + 0.5)
            rec[1] = f2b_w(0.5)
            rec[2] = f2b_w(0.0)
            rec[3] = f2b_w(1.0)
            rec[4] = f2b_w(0.08 + (i % 4) * 0.22)
            rec[5] = f2b_w(0.08 + ((i // 4) % 4) * 0.22)
            rec[6] = f2b_w(0.1 + (i * 0.37) % 0.9)
            rec[7] = f2b_w(1.0 + (i % 3) * 0.5)
            w += rec
        return w
    if name == 'fs_tex_proj':
        # vcol = {u_num, v_num, divisor}: divisors {0.5,1,2,4} give
        # effective uvs inside/outside [0,1] (CLAMP_TO_EDGE).
        for i in range(g['count']):
            rec = [0] * (spirv_model.VARY_STRIDE // 4)
            rec[0] = f2b_w(i + 0.5)
            rec[1] = f2b_w(0.5)
            rec[2] = f2b_w(0.0)
            rec[3] = f2b_w(1.0)
            rec[4] = f2b_w(0.25 + (i % 4) * 0.5)
            rec[5] = f2b_w(0.20 + ((i // 4) % 4) * 0.3)
            rec[6] = f2b_w((0.5, 1.0, 2.0, 4.0)[i % 4])
            w += rec
        return w
    if name == 'fs_tex_gather':
        # vcol.xy = uv spread over the 4x4 colour map.
        for i in range(g['count']):
            rec = [0] * (spirv_model.VARY_STRIDE // 4)
            rec[0] = f2b_w(i + 0.5)
            rec[1] = f2b_w(0.5)
            rec[2] = f2b_w(0.0)
            rec[3] = f2b_w(1.0)
            rec[4] = f2b_w(0.1 + (i * 0.23) % 0.85)
            rec[5] = f2b_w(0.1 + (i * 0.31) % 0.85)
            w += rec
        return w
    if name in ('fs_tex_bias', 'fs_tex_array'):
        # fs_tex_implicit's per-quad λ spread (quads 0/2 mip1, 1/3
        # mip0).  vcol.z: for _bias the Bias operand {-1.5,+1.5,-1.5,
        # +1.0} flips every quad's mip choice; for _array the layer
        # index 0..3 (one per quad).
        for i in range(g['count']):
            lx, ly, q = i & 1, (i >> 1) & 1, i >> 2
            du = (0.5, 0.125, 0.0, 0.0625)[q]
            dv = (0.0, 0.0, 0.5, 0.125)[q]
            rec = [0] * (spirv_model.VARY_STRIDE // 4)
            rec[0] = f2b_w(i + 0.5)
            rec[1] = f2b_w(0.5)
            rec[2] = f2b_w(0.0)
            rec[3] = f2b_w(1.0)
            rec[4] = f2b_w(0.25 + lx * du)
            rec[5] = f2b_w(0.25 + ly * dv + (0.25 if q == 2 else 0.0))
            rec[6] = f2b_w((-1.5, 1.5, -1.5, 1.0)[q]
                           if name == 'fs_tex_bias' else float(q))
            w += rec
        return w
    if name == 'fs_tex_qlod':
        # like fs_tex_implicit: per-quad derivative magnitudes so the
        # lambda spread covers several mips of the 4-mip map.
        for i in range(g['count']):
            lx, ly, q = i & 1, (i >> 1) & 1, i >> 2
            du = (0.75, 0.25, 0.0, 0.125)[q]
            dv = (0.0, 0.0, 0.75, 0.25)[q]
            rec = [0] * (spirv_model.VARY_STRIDE // 4)
            rec[0] = f2b_w(i + 0.5)
            rec[1] = f2b_w(0.5)
            rec[2] = f2b_w(0.0)
            rec[3] = f2b_w(1.0)
            rec[4] = f2b_w(0.25 + lx * du)
            rec[5] = f2b_w(0.25 + ly * dv + (0.25 if q == 2 else 0.0))
            w += rec
        return w
    if g['stage'] == 0:
        # VS input (ATTR_STRIDE 144 B): pos vec2 @loc0, col vec4 @loc1,
        # slot 8 = {VertexIndex, InstanceIndex, 0, 0} (G2a — the
        # builtin path reads it; vbase/inst stay in the vector header
        # only for the compat f_bi path)
        for i in range(g['count']):
            rec = [0] * (spirv_model.ATTR_STRIDE // 4)
            rec[0] = f2b_w(0.25 * i - 1.0)
            rec[1] = f2b_w(1.0 - 0.125 * i)
            rec[4] = f2b_w(0.0625 * i)
            rec[5] = f2b_w(1.0 - 0.03125 * i)
            rec[6] = f2b_w(0.25)
            rec[7] = f2b_w(1.0)
            rec[32] = g['vbase'] + i
            rec[33] = g['inst']
            w += rec
    else:
        # FS input (VARY_STRIDE 144 B): FragCoord @0, vcol @loc0(+16)
        for i in range(g['count']):
            rec = [0] * (spirv_model.VARY_STRIDE // 4)
            rec[0] = f2b_w(i + 0.5)          # pixel-center x
            rec[1] = f2b_w(0.5)
            rec[2] = f2b_w(0.0)
            rec[3] = f2b_w(1.0)
            rec[4] = f2b_w(0.03125 * i)
            rec[5] = f2b_w(0.5)
            rec[6] = f2b_w(0.75 - 0.03125 * i)
            rec[7] = f2b_w(1.0)
            w += rec
    return w


def emit_gfx(name, seed, spv_words, g):
    """graphics wave-work vector — the .hex appends a gfx section
    (gated by flags bit2): {stage,count,in_base,out_base,vbase,inst,
    n_in} + input-record words.  The .exp appends {n_out,out_base} +
    model words + class words; no lavapipe oracle for VS/FS.
    g['binds'] adds descriptor bindings + their data blocks before
    the gfx section (same layout as the compute corpus)."""
    base = os.path.join(OUT, '%s_%d' % (name, seed))
    binds = g.get('binds', [])
    in_words = gfx_inputs(name, g, seed)
    hexw = [len(spv_words), len(binds), 0, 0, 0, 0, 4, 0]
    hexw += spv_words
    for i, b in enumerate(binds):
        st, bd, w, o = b[:4]
        ax = b[4] if len(b) > 4 else 0
        hexw += [st, bd, w * 4, GFXBIND + i * 0x1000, ax]
        if ax & (1 << 24):
            hexw += img_meta(b[5], seed)
    hexw += [0]                        # dynamic-offset section: empty
    for i, b in enumerate(binds):
        if len(b) > 5:
            hexw += img_init(img_spec(b[5], seed), seed)
        else:
            hexw += [0] * b[2]
    hexw += [g['stage'], g['count'], GFXIN, GFXOUT,
             g['vbase'], g['inst'], len(in_words)]
    hexw += in_words
    # G3a-i: per-record helper-lane mask {lo, hi} — FS waves read it
    # from dispatch imm[6:7] (quads rasterized from degenerate
    # coverage mark helper lanes here)
    hlp = g.get('help', 0)
    hexw += [hlp & 0xFFFFFFFF, (hlp >> 32) & 0xFFFFFFFF]
    hexw += SENT
    open(base + '.hex', 'w').write('\n'.join(words_to_hex(hexw)) + '\n')

    m = spirv_model.Model(list(hexw))
    m.run()
    ow, oc = m.gfx_outputs()
    expw = [0, 0, m.robust, 1, 0]
    expw += [len(ow), GFXOUT]
    expw += ow
    expw += [CLSMAP[c] for c in oc]
    expw += SENT
    open(base + '.exp', 'w').write('\n'.join(words_to_hex(expw)) + '\n')

    descj = {'stage': g['stage'], 'count': g['count'],
             'in_base': GFXIN, 'out_base': GFXOUT,
             'vbase': g['vbase'], 'inst': g['inst'],
             'in_bytes': b''.join(
                 struct.pack('<I', w) for w in in_words).hex()}
    open(base + '.desc.json', 'w').write(json.dumps(descj))
    return base


def gfx_main():
    """`shader_vectors.py gfx` — (re)generate only the G1a graphics
    vectors; the compute corpus' oracle-backed .exp files are not
    touched."""
    os.makedirs(OUT, exist_ok=True)
    summary = []
    for name in sorted(GFX):
        g = GFX[name]
        spv = os.path.join(CORPUS, name + '.spv')
        words = read_spv(spv)
        sc = spirv_scan.Scanner(words)
        try:
            sc.scan()
        except spirv_scan.Fault as f:
            print('%s: COMMIT FAULT %s opcode=%d word=%d — FIX CORPUS' %
                  (name, spirv_scan.FAULT_NAME[f.code], f.opcode,
                   f.word))
            return 1
        sc.emit_tab(os.path.join(OUT, name + '.tab'))
        for seed in GFX_SEEDS:
            summary.append(emit_gfx(name, seed, words, g))
    print('wrote %d gfx cases to %s' % (len(summary), OUT))
    return 0


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
                    # oracle cannot run this module (e.g. lavapipe
                    # rejects OpVectorExtractDynamic): keep Gate-1
                    # coverage by folding the model image in.
                    print('%s_%d: oracle failed: %s — ORACLE section '
                          'carries model words' %
                          (name, seed, r.stderr.strip()))
                    emit(name, seed, words, desc, inputs,
                         oracle_out=oracle_image(mc[1], mc, desc),
                         model_cache=mc)
                    continue
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
        # the mutation is observable through lavapipe.  Shaders with
        # cross-bin atomics are opted out: an arithmetic mutation can
        # move a second atomic onto another atomic's cell, and
        # max/add vs add/max order is not commutative — the mutant is
        # then not bit-reproducible against the sequential model.
        muts = mutate(words) if desc.get('mut', True) else []
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
                        owords = list(struct.unpack(
                            '<%dI' % (len(u) // 4), u))
                        # The TB's "must differ" check runs RTL vs the
                        # unmutated oracle words — a mutation that is
                        # oracle-visible but model-invisible (e.g. an
                        # index flip that lands on equal-valued shared
                        # cells under our wave order) can never trip
                        # it; screen it out here.
                        if mc[1] == owords:
                            continue
                        mwords = mwords_c
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
                    print('%s_opt_%d: oracle failed: %s — ORACLE '
                          'section carries model words' %
                          (name, seed, r.stderr.strip()))
                    emit(name + '_opt', seed, words, desc, inputs,
                         oracle_out=oracle_image(mc[1], mc, desc),
                         model_cache=mc)
                    continue
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
    # ---- G3a-i: CallDepth overflow arm -------------------------------
    # fn_deep's static depth-10 chain exceeds the wave call stack
    # (CallDepth=8): every wave faults at the same OpFunctionCall
    # before any store, so the out binding keeps its preload image.
    # Single vector — no mut/bad/seed arms.
    deep_desc = dict(groups=(1, 1, 1), fmt='i', push=0,
                     bindings=[(0, 0, 64, 0), (0, 1, 32, 1)])
    deep_words = read_spv(os.path.join(CORPUS, 'fn_deep.spv'))
    spirv_scan.Scanner(deep_words).scan()
    base, _ = emit('fn_deep', 0, deep_words, deep_desc,
                   gen_inputs(deep_desc, 7), expect_done=2)
    summary.append(base)
    # C1 smoke: a zero-dimension dispatch must retire DONE_OK with no
    # waves issued and no stores — the zeroed output preload returns
    # untouched.  oracle_out folds the preload image directly (no
    # lavapipe run needed: nothing executes).
    zero_desc = dict(groups=(0, 2, 3), fmt='z', push=0,
                     bindings=[(0, 0, 64, 0), (0, 1, 32, 1)])
    zero_words = read_spv(os.path.join(CORPUS, 'fn_deep.spv'))
    spirv_scan.Scanner(zero_words).scan()
    base, _ = emit('zerodim', 0, zero_words, zero_desc,
                   gen_inputs(zero_desc, 7), expect_done=1,
                   oracle_out=[0] * 96)
    summary.append(base)
    # G3b-iii DispatchBase: base group {3,5,2} must offset
    # WorkgroupId and GlobalInvocationId.  lavapipe's oracle path
    # issues a plain vkCmdDispatch (no vkCmdDispatchBase), so the
    # ORACLE section folds the model image — Gate 1 carries the
    # check.
    db_desc = dict(groups=(2, 2, 1), fmt='z', push=0,
                   base=(3, 5, 2),
                   bindings=[(0, 0, 128, 1)])
    db_words = read_spv(os.path.join(CORPUS, 'dbase.spv'))
    spirv_scan.Scanner(db_words).scan()
    bbase, mc = emit('dispbase', 0, db_words, db_desc,
                     gen_inputs(db_desc, 7))
    emit('dispbase', 0, db_words, db_desc, gen_inputs(db_desc, 7),
         oracle_out=oracle_image(mc[1], mc, db_desc), model_cache=mc)
    summary.append(bbase)
    print('wrote %d cases to %s' % (len(summary), OUT))
    return 0


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'gfx':
        sys.exit(gfx_main())
    sys.exit(main())
