#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""gen_sfu_tables.py — one source for the G3a-ii SFU micro-sequences.

Fits the §7d polynomials (Chebyshev-node least squares, numpy only),
evaluates each op's *full* micro-sequence in f32 arithmetic (the exact
fpnew op order the RTL jset steps perform) against a float64 reference
over >= 1e6 points per op across the whole domain including the special
cases, asserts the Vulkan-precision budget, and emits BOTH

    corev_apu/apu/include/g6lc_apu_sfu_pkg.sv     (f32 constants + bounds)
    corev_apu/apu/tools/shader/sfu_tables.py    (same arrays + sequences)

from the same arrays — RTL and spirv_model.py cannot drift (the
sRGB-LUT pattern).  The op implementations below are written once,
backend-parameterized: the generated file carries the exact backend
(Fraction arithmetic, bit-exact with fpnew), while this generator drives
the same functions with a vectorized numpy backend for the >=1e6-point
bound measurement.

usage: gen_sfu_tables.py            # write both outputs
       gen_sfu_tables.py --check    # freshness gate: rc 1 on drift
                                   # (run-apu-regress.sh suite
                                   # `shwave-sfu`)
"""

import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(HERE, "..", "..", "include", "g6lc_apu_sfu_pkg.sv")
TAB = os.path.join(HERE, "sfu_tables.py")

# ---------------------------------------------------------------------
# Polynomial fits (float64 design space, emitted as f32 constants).
# ---------------------------------------------------------------------


def cheb_nodes(a, b, n):
    k = np.arange(n)
    x = np.cos(np.pi * (2 * k + 1) / (2 * n))
    return 0.5 * (a + b) + 0.5 * (b - a) * x


def fit_poly(x, y, deg, basis=None):
    """Least-squares poly fit on nodes x; basis(x)->design matrix cols."""
    if basis is None:
        basis = lambda t: np.vstack([t**i for i in range(deg + 1)]).T
    A = basis(np.asarray(x, dtype=np.float64))
    coef, *_ = np.linalg.lstsq(A, np.asarray(y, dtype=np.float64),
                               rcond=None)
    return coef


def f32(x):
    return np.float32(x).item()


def bits32(x):
    return int(np.float32(x).view(np.uint32))


def fit_all():
    """Return dict name -> [f32 bits] coefficient lists, slot order as
    documented beside each."""
    co = {}

    # exp2: p(f) ~= 2^f on f in [0,1), deg 6, relative error.
    # Slot order for the Horner chain: c6..c0, then 128.0, -150.0.
    x = cheb_nodes(0.0, 1.0, 4096)
    w = 1.0 / np.power(2.0, x)                 # relative-error weight
    A = np.vstack([x**i for i in range(7)]).T * w[:, None]
    c, *_ = np.linalg.lstsq(A, np.ones_like(x), rcond=None)
    # c is the weighted fit of 2^f/2^f = 1 -> coefficients of 2^f
    poly = c                                   # c[i] ~ f^i
    rel = np.abs(np.polyval(poly[::-1], x) / np.power(2.0, x) - 1)
    assert rel.max() < 2**-22, f"exp2 fit rel err {rel.max():g}"
    co['exp2'] = [bits32(v) for v in poly[::-1]] + \
        [bits32(128.0), bits32(-150.0)]

    # log2: odd deg-9 in t = (m-1)/(m+1), m in [sqrt2/2, sqrt2).
    # log2(m) = p(t), p odd: c1 t + c3 t^3 + c5 t^5 + c7 t^7 + c9 t^9.
    # Slot order: c9, c7, c5, c3, c1, then the sqrt2 threshold bits.
    s2 = math.sqrt(2.0)
    tmax = (s2 - 1.0) / (s2 + 1.0)
    t = cheb_nodes(-tmax, tmax, 4096)
    m = (1.0 + t) / (1.0 - t)
    y = np.log2(m)
    A = np.vstack([t**(2 * i + 1) for i in range(5)]).T
    cc, *_ = np.linalg.lstsq(A, y, rcond=None)
    perr = np.abs(A @ cc - y)
    assert perr.max() < 1e-6, f"log2 fit err {perr.max():g}"
    co['log2'] = [bits32(v) for v in cc[::-1]] + [0x3FB504F3]

    # sin: sin r = r + r^3*(s0 + r^2*(s1 + r^2*(s2 + r^2*(s3 + r^2*s4))))
    #   -> S(u) = (sin r - r)/r^3, u = r^2, S poly deg 4 (5 coefs)
    # cos: cos r = 1 + r^2*(c0 + r^2*(c1 + r^2*(c2 + r^2*(c3 + r^2*c4))))
    #   -> C(u) = (cos r - 1)/r^2, deg 4 (5 coefs)
    # Slot order: s4..s0, c4..c0, CW1, CW2, CW3, 2/pi.
    r = cheb_nodes(-math.pi / 4, math.pi / 4, 4096)
    u = r * r
    ss = (np.sin(r) - r) / (r * u)             # S(u), r!=0 guarded below
    uu = cheb_nodes(0.0, (math.pi / 4) ** 2, 4096)
    rr = np.sqrt(uu)
    ss = (np.sin(rr) - rr) / (rr * uu)
    A = np.vstack([uu**i for i in range(5)]).T
    sc, *_ = np.linalg.lstsq(A, ss, rcond=None)
    ccv = (np.cos(rr) - 1.0) / uu
    cc2, *_ = np.linalg.lstsq(A, ccv, rcond=None)
    err_s = np.abs(np.polyval(sc[::-1], u) * r**3 + r - np.sin(r)).max()
    err_c = np.abs(np.polyval(cc2[::-1], u) * u + 1 - np.cos(r)).max()
    assert err_s < 1e-7 and err_c < 1e-7, (err_s, err_c)

    # Cody-Waite C1+C2+C3 = pi/2, each with the low mantissa bits
    # cleared so k*Ci is exact for |k| < 2^10 (k ~ rne(x*2/pi)).
    pi2 = math.pi / 2.0
    c1 = np.float32(pi2).view(np.uint32) & np.uint32(0xFFFFE000)
    c1f = np.uint32(c1).view(np.float32).item()
    c2 = np.float32(pi2 - c1f).view(np.uint32) & np.uint32(0xFFFFE000)
    c2f = np.uint32(c2).view(np.float32).item()
    c3f = f32(pi2 - c1f - c2f)
    # exactness: |k*c1|, |k*c2| products must be exact in f32 for
    # |k| < 2^10 -> low 13 bits zeroed gives <= 10 significant bits.
    assert (int(c1) & 0x1FFF) == 0 and (int(c2) & 0x1FFF) == 0
    co['sincos'] = [bits32(v) for v in sc[::-1]] + \
        [bits32(v) for v in cc2[::-1]] + \
        [int(c1), int(c2), bits32(c3f), bits32(2.0 / math.pi)]

    # atan: odd deg-11 on [0,1]: atan a ~= a1 a + a3 a^3 + ... a11 a^11.
    # Slot order: a11..a1, then pi/2.
    a = cheb_nodes(0.0, 1.0, 4096)
    A = np.vstack([a**(2 * i + 1) for i in range(6)]).T
    ac, *_ = np.linalg.lstsq(A, np.arctan(a), rcond=None)
    aerr = np.abs(A @ ac - np.arctan(a)).max()
    assert aerr < 1e-5, aerr
    co['atan'] = [bits32(v) for v in ac[::-1]] + [bits32(pi2)]

    # wrapper-op constants
    co['exp'] = [bits32(math.log2(math.e))]                # log2e
    co['log'] = [bits32(math.log(2.0))]                    # ln2
    co['acos'] = [bits32(math.pi)]
    co['atan2'] = [bits32(math.pi)]
    co['sinh'] = [bits32(math.log2(math.e))]
    co['cosh'] = [bits32(math.log2(math.e))]
    co['tanh'] = [bits32(2.0 * math.log2(math.e))]
    co['asinh'] = [bits32(math.log(2.0))]
    co['acosh'] = [bits32(math.log(2.0))]
    co['atanh'] = [bits32(0.5 * math.log(2.0))]
    return co


# ---------------------------------------------------------------------
# The canonical micro-sequences.  Written once here as source text;
# emitted verbatim into sfu_tables.py and exec'd by this generator with
# a numpy backend for the bound measurement.  Every primitive maps 1:1
# to a shwave jset step (or an always-stage bit op, marked *_q helpers).
# ---------------------------------------------------------------------

OPS_SRC = '''
# ---- generated op implementations (canonical order; see §7d) --------
# Backend `b` provides: c, fadd, fsub, fmul, fdiv, fsqrt, ffma, fman,
# f2i(w,rnd), i2f(w), minf, maxf, isnan, isinf, flt(a,b), sel(c,a,b),
# seli(c,a,b), s32(w).  Bit ops use plain Python/numpy operators on the
# u32 patterns.  QNAN / masks are module constants.


def s_exp2(b, x):
    """exp2(x): clamp [-150,128]; n=floor, f=x-n in [0,1); deg-6 Horner;
    two-step ldexp for n < -126 (denormal results)."""
    C = COEFS['exp2']
    xx = b.minf(x, C[7])
    xx = b.maxf(xx, C[8])
    n = b.f2i(xx, 'RDN')
    nf = b.i2f(n)
    f = b.fsub(xx, nf)
    p = b.ffma(f, C[0], C[1])
    p = b.ffma(p, f, C[2])
    p = b.ffma(p, f, C[3])
    p = b.ffma(p, f, C[4])
    p = b.ffma(p, f, C[5])
    p = b.ffma(p, f, C[6])
    ni = b.s32(n)
    a = b.seli(b.ilt(ni, -126), -126, ni)
    bb = ni - a
    pa = ((a + 127) << 23) & 0xFFFFFFFF
    pb = ((bb + 127) << 23) & 0xFFFFFFFF
    p = b.fmul(p, pa)
    p = b.fmul(p, pb)
    return b.sel(b.isnan(x), QNAN, p)


def s_log2(b, x):
    """log2(x): denormal-preserving frexp; m -> [sqrt2/2,sqrt2); t-form
    odd deg-9; specials x<0->NaN, 0->-Inf, +Inf->+Inf."""
    C = COEFS['log2']
    den = ((x >> 23) & 0xFF) == 0                       # also catches 0
    y = b.sel(den, b.fmul(x, 0x4B800000), x)            # x * 2^24
    e = b.s32((y >> 23) & 0xFF) - 127 - b.seli(den, 24, 0)
    m = 0x3F800000 | (y & 0x7FFFFF)
    ge = m > C[5]                                       # m > sqrt2 bits
    m = b.sel(ge, (m - 0x00800000) & 0xFFFFFFFF, m)
    e = e + b.seli(ge, 1, 0)
    t = b.fdiv(b.fsub(m, 0x3F800000), b.fadd(m, 0x3F800000))
    t2 = b.fmul(t, t)
    h = b.ffma(t2, C[0], C[1])
    h = b.ffma(t2, h, C[2])
    h = b.ffma(t2, h, C[3])
    h = b.ffma(t2, h, C[4])
    p = b.fmul(h, t)
    r = b.fadd(b.i2f(e & 0xFFFFFFFF), p)
    # specials
    r = b.sel(b.isnan(x), QNAN, r)
    r = b.sel((x & 0x7FFFFFFF) == 0, 0xFF800000, r)     # +-0 -> -Inf
    r = b.sel((x >> 31) != 0, QNAN, r)                  # negatives -> NaN
    r = b.sel(x == 0x7F800000, 0x7F800000, r)           # +Inf -> +Inf
    return r


def s_exp(b, x):
    """exp(x) = exp2(x * log2e)."""
    return s_exp2(b, b.fmul(x, COEFS['exp'][0]))


def s_log(b, x):
    """log(x) = log2(x) * ln2."""
    return b.fmul(s_log2(b, x), COEFS['log'][0])


def s_pow(b, x, y):
    """pow(x,y): GLSL special cases first, then exp2(y*log2 x)."""
    lx = s_log2(b, x)
    w = b.fmul(y, lx)
    r = s_exp2(b, w)
    xmag = x & 0x7FFFFFFF
    xneg = (x >> 31) & (xmag != 0)
    xzero = xmag == 0
    yneg = (y >> 31) & ((y & 0x7FFFFFFF) != 0)
    yzero = (y & 0x7FFFFFFF) == 0
    r0 = b.sel(yzero, 0x3F800000,
               b.sel(yneg, 0x7F800000, 0x00000000))
    r = b.sel(xzero, r0, r)
    r = b.sel(x == 0x3F800000, 0x3F800000, r)           # x==1 -> 1
    r = b.sel(xneg, QNAN, r)                            # x<0 -> NaN
    r = b.sel(b.isnan(x) | b.isnan(y), QNAN, r)
    return r


def s_sincos(b, x):
    """Cody-Waite k=rne(x*2/pi); r=((x-kC1)-kC2)-kC3; quadrant select.
    Returns (sin, cos)."""
    C = COEFS['sincos']
    k = b.f2i(b.fmul(x, C[13]), 'RNE')
    kf = b.i2f(k)
    r = b.fman(kf, C[10], x)
    r = b.fman(kf, C[11], r)
    r = b.fman(kf, C[12], r)
    r2 = b.fmul(r, r)
    hs = b.ffma(r2, C[0], C[1])
    hs = b.ffma(r2, hs, C[2])
    hs = b.ffma(r2, hs, C[3])
    hs = b.ffma(r2, hs, C[4])
    sin_r = b.ffma(b.fmul(r, r2), hs, r)
    hc = b.ffma(r2, C[5], C[6])
    hc = b.ffma(r2, hc, C[7])
    hc = b.ffma(r2, hc, C[8])
    hc = b.ffma(r2, hc, C[9])
    cos_r = b.ffma(r2, hc, 0x3F800000)
    q = k & 3
    neg = x ^ 0x80000000                               # unused, keeps API
    sin_o = b.sel(q == 0, sin_r,
                  b.sel(q == 1, cos_r,
                        b.sel(q == 2, sin_r ^ 0x80000000,
                              cos_r ^ 0x80000000)))
    cos_o = b.sel(q == 0, cos_r,
                  b.sel(q == 1, sin_r ^ 0x80000000,
                        b.sel(q == 2, cos_r ^ 0x80000000, sin_r)))
    bad = b.isnan(x) | b.isinf(x)
    return (b.sel(bad, QNAN, sin_o), b.sel(bad, QNAN, cos_o))


def s_sin(b, x):
    return s_sincos(b, x)[0]


def s_cos(b, x):
    return s_sincos(b, x)[1]


def s_tan(b, x):
    sn, cs = s_sincos(b, x)
    return b.fdiv(sn, cs)


def s_atan(b, z):
    """atan(z): a=|z|; a>1 -> a=1/a and flag; odd deg-11; pi/2 - p;
    sign restore.  z=inf -> +-pi/2 falls out of the a'=0 path."""
    C = COEFS['atan']
    az = z & 0x7FFFFFFF
    flag = b.flt(0x3F800000, az)                        # 1.0 < a
    w = b.fdiv(0x3F800000, az)
    a = b.sel(flag, w, az)
    t2 = b.fmul(a, a)
    h = b.ffma(t2, C[0], C[1])
    h = b.ffma(t2, h, C[2])
    h = b.ffma(t2, h, C[3])
    h = b.ffma(t2, h, C[4])
    h = b.ffma(t2, h, C[5])
    p = b.fmul(a, h)
    r = b.sel(flag, b.fman(p, 0x3F800000, C[6]), p)     # pi/2 - p
    return r ^ (z & 0x80000000)


def s_atan2(b, y, x):
    """atan2(y,x) = atan(y/x) with the quadrant rules."""
    z = b.fdiv(y, x)
    r = s_atan(b, z)
    pi = COEFS['atan2'][0]
    r = b.sel((x >> 31) != 0,
              b.sel((y >> 31) != 0, b.fsub(r, pi), b.fadd(r, pi)),
              r)
    # only y==0 & x==+-0 leaves a NaN from finite inputs -> 0
    r = b.sel(b.isnan(z) & ~(b.isnan(x) | b.isnan(y)), 0, r)
    return r


def s_asin(b, x):
    """asin(x) = atan(x / sqrt(1 - x^2)) — the spec formula."""
    t = b.fsqrt(b.fman(x, x, 0x3F800000))
    return s_atan(b, b.fdiv(x, t))


def s_acos(b, x):
    """acos(x) = atan2(sqrt(1 - x^2), x) — the spec formula."""
    t = b.fsqrt(b.fman(x, x, 0x3F800000))
    r = s_atan(b, b.fdiv(t, x))
    return b.sel((x >> 31) != 0, b.fadd(r, COEFS['acos'][0]), r)


def s_sinh(b, x):
    """sinh = (e^x - e^-x)/2 over the exp core."""
    e1 = s_exp(b, x)
    e2 = s_exp(b, x ^ 0x80000000)
    return b.fmul(b.fsub(e1, e2), 0x3F000000)


def s_cosh(b, x):
    """cosh = (e^x + e^-x)/2."""
    e1 = s_exp(b, x)
    e2 = s_exp(b, x ^ 0x80000000)
    return b.fmul(b.fadd(e1, e2), 0x3F000000)


def s_tanh(b, x):
    """tanh = (e^2x - 1)/(e^2x + 1)."""
    e = s_exp2(b, b.fmul(x, COEFS['tanh'][0]))
    return b.fdiv(b.fsub(e, 0x3F800000), b.fadd(e, 0x3F800000))


def s_asinh(b, x):
    """asinh = log(x + sqrt(x^2 + 1))."""
    t = b.fsqrt(b.ffma(x, x, 0x3F800000))
    return b.fmul(s_log2(b, b.fadd(x, t)), COEFS['asinh'][0])


def s_acosh(b, x):
    """acosh = log(x + sqrt(x^2 - 1))."""
    t = b.fsqrt(b.ffma(x, x, 0xBF800000))
    return b.fmul(s_log2(b, b.fadd(x, t)), COEFS['acosh'][0])


def s_atanh(b, x):
    """atanh = 0.5*log((1+x)/(1-x))."""
    z = b.fdiv(b.fadd(0x3F800000, x), b.fsub(0x3F800000, x))
    return b.fmul(s_log2(b, z), COEFS['atanh'][0])


# xnum -> (function, arity).  Bit-exact with the RTL sequences.
SFU_FUNCS = {
    13: (s_sin, 1), 14: (s_cos, 1), 15: (s_tan, 1), 16: (s_asin, 1),
    17: (s_acos, 1), 18: (s_atan, 1), 19: (s_sinh, 1), 20: (s_cosh, 1),
    21: (s_tanh, 1), 22: (s_asinh, 1), 23: (s_acosh, 1),
    24: (s_atanh, 1), 25: (s_atan2, 2), 26: (s_pow, 2), 27: (s_exp, 1),
    28: (s_log, 1), 29: (s_exp2, 1), 30: (s_log2, 1),
}


def sfu_eval(xnum, args):
    """args: list of per-component u32 lists.  Returns [wb0..3]."""
    fn, arity = SFU_FUNCS[xnum]
    out = [0, 0, 0, 0]
    for c in range(len(args[0])):
        out[c] = fn(_EXACT, *[a[c] for a in args[:arity]])
    return out
'''

# exact backend (emitted into sfu_tables.py): Fraction-accurate fp32,
# identical edge semantics to spirv_model.py's helpers.
EXACT_SRC = '''
# ---- exact f32 backend (fpnew-compatible, bit-exact) -----------------
import math as _math
import struct as _struct
from fractions import Fraction as _Frac

QNAN = 0x7FC00000


def _b2f(w):
    return _struct.unpack('<f', _struct.pack('<I', w & 0xFFFFFFFF))[0]


def _f2b(x):
    if _math.isnan(x):
        return QNAN
    try:
        return _struct.unpack('<I', _struct.pack('<f', x))[0]
    except OverflowError:
        return 0xFF800000 if x < 0 else 0x7F800000


def _isnan(w):
    return (w & 0x7F800000) == 0x7F800000 and (w & 0x7FFFFF) != 0


def _isinf(w):
    return (w & 0x7FFFFFFF) == 0x7F800000


def _rs(n, d, e2):
    if e2 >= 0:
        d = d << e2
    else:
        n = n << (-e2)
    q, r = divmod(n, d)
    if (r << 1) > d or ((r << 1) == d and (q & 1)):
        q += 1
    return q


def _fr2b(fr, neg_zero=False):
    if fr == 0:
        return 0x80000000 if neg_zero else 0
    sgn = fr < 0
    a = -fr if sgn else fr
    n, d = a.numerator, a.denominator
    e = n.bit_length() - d.bit_length()
    if e >= 0:
        if n < (d << e):
            e -= 1
    elif (n << (-e)) < d:
        e -= 1
    if e >= -126:
        m = _rs(n, d, e - 23)
        if m >> 24:
            m >>= 1
            e += 1
        if e > 127:
            return 0xFF800000 if sgn else 0x7F800000
        bits = ((e + 127) << 23) | (m & 0x7FFFFF)
    else:
        m = _rs(n, d, -149)
        bits = 0x800000 if m >= (1 << 23) else m
    return bits | (int(sgn) << 31)


def _ffma(a, b, c):
    fa, fb, fc = _b2f(a), _b2f(b), _b2f(c)
    if _math.isnan(fa) or _math.isnan(fb) or _math.isnan(fc):
        return QNAN
    if _math.isinf(fa) or _math.isinf(fb):
        if fa == 0.0 or fb == 0.0:
            return QNAN
        ps = _math.copysign(1.0, fa) * _math.copysign(1.0, fb)
        if _math.isinf(fc) and _math.copysign(1.0, fc) != ps:
            return QNAN
        return 0xFF800000 if ps < 0 else 0x7F800000
    if _math.isinf(fc):
        return c & 0xFFFFFFFF
    fr = _Frac(fa) * _Frac(fb) + _Frac(fc)
    if fr == 0:
        sp = ((a >> 31) & 1) ^ ((b >> 31) & 1)
        return 0x80000000 if (sp and fc == 0.0 and
                              _math.copysign(1.0, fc) < 0) else 0
    return _fr2b(fr)


def _fp_cmp_lt(a, b):
    fa, fb = _b2f(a), _b2f(b)
    if _math.isnan(fa) or _math.isnan(fb):
        return False
    return fa < fb


def _fp_minmax(a, b, is_max):
    na, nb = _isnan(a), _isnan(b)
    if na and nb:
        return QNAN
    if na:
        return b
    if nb:
        return a
    if is_max:
        return b if _fp_cmp_lt(a, b) else a
    return a if _fp_cmp_lt(a, b) else b


def _f2i(w, rnd):
    x = _b2f(w)
    if _math.isnan(x):
        return 0x7FFFFFFF
    if not _math.isfinite(x):
        r = None
    elif rnd == 'RDN':
        r = _math.floor(x)
    elif rnd == 'RUP':
        r = _math.ceil(x)
    elif rnd == 'RTZ':
        r = _math.trunc(x)
    elif rnd == 'RNE':
        r = round(x)
    else:
        r = int(_math.floor(x + 0.5))
    if r is None or r > 0x7FFFFFFF or r < -0x80000000:
        return 0x80000000 if _math.copysign(1.0, x) < 0 else 0x7FFFFFFF
    return r & 0xFFFFFFFF


def _i2f(w):
    v = w & 0xFFFFFFFF
    if v & 0x80000000:
        v -= 0x100000000
    return _f2b(float(v))


class _ExactBackend:
    def c(self, x):
        return _f2b(float(x))

    def fadd(self, a, b):
        return _f2b(_b2f(a) + _b2f(b))

    def fsub(self, a, b):
        return _f2b(_b2f(a) - _b2f(b))

    def fmul(self, a, b):
        return _f2b(_b2f(a) * _b2f(b))

    def fdiv(self, a, b):
        fa, fb = _b2f(a), _b2f(b)
        if _math.isnan(fa) or _math.isnan(fb):
            return QNAN
        if fb == 0.0:
            if fa == 0.0:
                return QNAN
            return _f2b(_math.copysign(_math.inf, fa) *
                        _math.copysign(1.0, fb))
        if _math.isinf(fb):
            if _math.isinf(fa):
                return QNAN
            return _f2b(_math.copysign(0.0, fa) * _math.copysign(1.0, fb))
        if _math.isinf(fa):
            return _f2b(_math.copysign(_math.inf, fa) *
                        _math.copysign(1.0, fb))
        return _f2b(fa / fb)

    def fsqrt(self, a):
        fa = _b2f(a)
        if _math.isnan(fa):
            return QNAN
        if fa == 0.0:
            return a & 0x80000000
        if fa < 0.0:
            return QNAN
        return _f2b(_math.sqrt(fa))

    def ffma(self, a, b, c):
        return _ffma(a, b, c)

    def fman(self, a, b, c):
        return _ffma(a ^ 0x80000000, b, c)

    def f2i(self, w, rnd):
        return _f2i(w, rnd)

    def i2f(self, w):
        return _i2f(w)

    def minf(self, a, b):
        return _fp_minmax(a, b, False)

    def maxf(self, a, b):
        return _fp_minmax(a, b, True)

    def isnan(self, w):
        return _isnan(w)

    def isinf(self, w):
        return _isinf(w)

    def flt(self, a, b):
        return _fp_cmp_lt(a, b)

    def sel(self, c, a, b):
        return a if c else b

    def seli(self, c, a, b):
        return a if c else b

    def s32(self, w):
        return w - 0x100000000 if w & 0x80000000 else w

    def ilt(self, a, k):
        return a < k


_EXACT = _ExactBackend()
'''


# ---------------------------------------------------------------------
# Vectorized numpy backend for the >=1e6-point bound measurement.
# ---------------------------------------------------------------------


class FastBackend:
    """numpy float32/uint32 arrays; fma emulated via f64 + single f32
    rounding of the exact double product-sum (sub-ulp-f64 error only,
    vanishing vs the measured f32 ulp bounds)."""

    def c(self, x):
        return np.uint32(np.float32(x).view(np.uint32))

    def _f(self, w):
        return np.asarray(w, dtype=np.uint32).view(np.float32)

    def _b(self, v):
        return np.asarray(v, dtype=np.float32).view(np.uint32)

    def fadd(self, a, b):
        return self._b(self._f(a) + self._f(b))

    def fsub(self, a, b):
        return self._b(self._f(a) - self._f(b))

    def fmul(self, a, b):
        return self._b(self._f(a) * self._f(b))

    def fdiv(self, a, b):
        fa, fb = self._f(a), self._f(b)
        r = self._b(fa / fb)
        nan = np.isnan(fa) | np.isnan(fb)
        z = (fb == 0.0)
        bad = nan | (z & (fa == 0.0)) | (np.isinf(fa) & np.isinf(fb))
        r = np.where(bad, np.uint32(0x7FC00000), r).astype(np.uint32)
        zbad = z & ~nan & (fa != 0.0)
        sgn = ((a ^ b) >> 31).astype(np.uint32) << 31
        r = np.where(zbad, sgn | np.uint32(0x7F800000), r)
        iinf = np.isinf(fb) & ~np.isinf(fa) & ~nan
        r = np.where(iinf, sgn, r)
        return r.astype(np.uint32)

    def fsqrt(self, a):
        fa = self._f(a)
        r = self._b(np.sqrt(fa))
        bad = np.isnan(fa) | (fa < 0.0)
        r = np.where(bad, np.uint32(0x7FC00000), r).astype(np.uint32)
        z = fa == 0.0
        r = np.where(z, a & np.uint32(0x80000000), r)
        return r.astype(np.uint32)

    def ffma(self, a, b, c):
        fa, fb, fc = (self._f(a).astype(np.float64),
                      self._f(b).astype(np.float64),
                      self._f(c).astype(np.float64))
        r = self._b(np.float32(fa * fb + fc))
        nan = np.isnan(fa) | np.isnan(fb) | np.isnan(fc)
        pinf = np.isinf(fa) | np.isinf(fb)
        bad = nan | (pinf & ((fa == 0.0) | (fb == 0.0))) | \
            (pinf & np.isinf(fc) &
             (np.sign(fc) != np.sign(fa) * np.sign(fb)))
        r = np.where(bad, np.uint32(0x7FC00000), r).astype(np.uint32)
        infp = pinf & ~bad & ~(np.isinf(fc))
        sgn = (np.sign(fa) * np.sign(fb) < 0)
        r = np.where(infp, np.where(sgn, np.uint32(0xFF800000),
                                    np.uint32(0x7F800000)), r)
        cinf = np.isinf(fc) & ~pinf & ~bad
        r = np.where(cinf, c, r)
        return r.astype(np.uint32)

    def fman(self, a, b, c):
        return self.ffma(np.asarray(a, dtype=np.uint32) ^
                         np.uint32(0x80000000), b, c)

    def f2i(self, w, rnd):
        x = self._f(w).astype(np.float64)
        if rnd == 'RDN':
            r = np.floor(x)
        elif rnd == 'RUP':
            r = np.ceil(x)
        elif rnd == 'RTZ':
            r = np.trunc(x)
        elif rnd == 'RNE':
            r = np.round(x)
        else:
            r = np.floor(x + 0.5)
        big = ~np.isfinite(x) | (r > 0x7FFFFFFF) | (r < -0x80000000)
        r = np.clip(r, -0x80000000, 0x7FFFFFFF).astype(np.int64)
        out = (r & 0xFFFFFFFF).astype(np.uint32)
        neg = np.sign(x) < 0
        out = np.where(big & neg, np.uint32(0x80000000), out)
        out = np.where(big & ~neg, np.uint32(0x7FFFFFFF), out)
        out = np.where(np.isnan(x), np.uint32(0x7FFFFFFF), out)
        return out

    def i2f(self, w):
        v = np.asarray(w, dtype=np.uint32).astype(np.int32)
        return self._b(v.astype(np.float32))

    def minf(self, a, b):
        fa, fb = self._f(a), self._f(b)
        na, nb = np.isnan(fa), np.isnan(fb)
        r = np.where(na & nb, np.uint32(0x7FC00000),
                     np.where(na, b,
                              np.where(nb, a,
                                       np.where(fa < fb, a, b))))
        return r.astype(np.uint32)

    def maxf(self, a, b):
        fa, fb = self._f(a), self._f(b)
        na, nb = np.isnan(fa), np.isnan(b)
        r = np.where(na & nb, np.uint32(0x7FC00000),
                     np.where(na, b,
                              np.where(nb, a,
                                       np.where(fb < fa, a, b))))
        return r.astype(np.uint32)

    def isnan(self, w):
        w = np.asarray(w, dtype=np.uint32)
        return ((w & np.uint32(0x7F800000)) == np.uint32(0x7F800000)) & \
            ((w & np.uint32(0x7FFFFF)) != 0)

    def isinf(self, w):
        return (np.asarray(w, dtype=np.uint32) &
                np.uint32(0x7FFFFFFF)) == np.uint32(0x7F800000)

    def flt(self, a, b):
        fa, fb = self._f(a), self._f(b)
        return (fa < fb) & ~(np.isnan(fa) | np.isnan(fb))

    def sel(self, cnd, a, b):
        return np.where(cnd, a, b).astype(np.uint32)

    def seli(self, cnd, a, b):
        return np.where(cnd, np.int32(a), np.int32(b)).astype(np.int64)

    def s32(self, w):
        return np.asarray(w, dtype=np.uint32).astype(np.int32)

    def ilt(self, a, k):
        return np.asarray(a) < k


# ---------------------------------------------------------------------
# Measurement: ULP/abs error of the emulated sequence vs float64.
# ---------------------------------------------------------------------


def ulp_key(w):
    w = np.asarray(w, dtype=np.uint32).astype(np.int64)
    return np.where(w & 0x80000000, 0x80000000 - (w & 0x7FFFFFFF),
                    0x80000000 + w)


def f32_ref(vals):
    return np.asarray(vals, dtype=np.float64).astype(np.float32)


def run_op(mod, xnum, argsets):
    fn, _ = mod.SFU_FUNCS[xnum]
    B = FastBackend()
    return fn(B, *argsets)


def measure(mod):
    """Measure each op vs f64 reference; `mod` exposes SFU_FUNCS (the
    exec'd generated source)."""

    def ulp_err(res, ref64):
        ok = np.isfinite(ref64)
        rf = f32_ref(ref64).astype(np.float64)
        r = np.asarray(res, dtype=np.uint32).view(np.float32) \
            .astype(np.float64)
        u = np.zeros(len(r))
        # ordered-int distance, in ULPs, between res and f32(ref)
        d = np.abs(ulp_key(np.asarray(res, dtype=np.uint32)) -
                   ulp_key(f32_ref(ref64).view(np.uint32)))
        both_nan = np.isnan(r) & np.isnan(ref64)
        u = np.where(both_nan, 0.0, d.astype(np.float64))
        u = np.where(np.isnan(r) | np.isnan(ref64),
                     np.where(both_nan, 0.0, 1e9), u)
        infm = np.isinf(r) | np.isinf(rf)
        same_inf = np.isinf(r) & np.isinf(rf) & \
            (np.sign(r) == np.sign(rf))
        u = np.where(infm, np.where(same_inf, 0.0, 1e9), u)
        absd = np.abs(r - rf)
        return u, absd, r

    bounds = {}
    N = 1 << 20                                       # 1,048,576 points

    # exp2 / exp: ULP <= 3 + 2|x|
    x = np.linspace(-170.0, 140.0, N)
    xb = np.float32(x).view(np.uint32)
    xf = xb.astype(np.uint32).view(np.float32).astype(np.float64)
    r = run_op(mod, 29, [xb])
    u, _, _ = ulp_err(r, np.power(2.0, xf))
    bnd = 3.0 + 2.0 * np.abs(xf)
    bad = u > bnd
    assert not bad.any(), f"exp2 over budget: {u[bad].max():g} ulp"
    bounds['exp2'] = u.max()

    xe = np.linspace(-100.0, 95.0, N)
    xeb = np.float32(xe).view(np.uint32)
    xef = xeb.astype(np.uint32).view(np.float32).astype(np.float64)
    r = run_op(mod, 27, [xeb])
    u, _, _ = ulp_err(r, np.exp(xef))
    bnd = 3.0 + 2.0 * np.abs(xef)
    bad = u > bnd
    assert not bad.any(), f"exp over budget: {u[bad].max():g}"
    bounds['exp'] = u.max()

    # log2: 3 ULP outside [0.5,2]; abs < 2^-21 inside
    xl = np.concatenate([
        np.logspace(-45, 38, N, dtype=np.float64),    # incl denormals
        np.linspace(0.45, 2.05, N)])
    xb = np.float32(np.abs(xl)).view(np.uint32)
    xa32 = xb.astype(np.uint32).view(np.float32).astype(np.float64)
    r = run_op(mod, 30, [xb])
    ref = np.log2(xa32)
    u, ad, rf = ulp_err(r, ref)
    inside = (xa32 >= 0.5) & (xa32 <= 2.0)
    bad_o = (~inside) & (u > 3.0)
    bad_i = inside & (ad > 2**-21)
    assert not bad_o.any(), f"log2 ulp {u[bad_o].max():g}"
    assert not bad_i.any(), f"log2 abs {ad[bad_i].max():g}"
    bounds['log2'] = max(u[~inside].max(), 0.0)
    rl = run_op(mod, 28, [xb])
    refl = np.log(xa32)
    u, ad, _ = ulp_err(rl, refl)
    bad = (~inside) & (u > 3.0)
    badi = inside & (ad > 2**-21)
    assert not bad.any() and not badi.any()
    bounds['log'] = max(u[~inside].max(), 0.0)

    # sin/cos: abs <= 2^-11 on [-pi,pi]
    xs = np.linspace(-math.pi, math.pi, N)
    xb = np.float32(xs).view(np.uint32)
    xsf = xb.astype(np.uint32).view(np.float32).astype(np.float64)
    for xn, refn, nm in ((13, np.sin, 'sin'), (14, np.cos, 'cos')):
        r = run_op(mod, xn, [xb])
        _, ad, _ = ulp_err(r, refn(xsf))
        assert ad.max() <= 2**-11, f"{nm} abs {ad.max():g}"
        bounds[nm] = ad.max()
    r = run_op(mod, 15, [xb])
    u, ad, _ = ulp_err(r, np.tan(xsf))
    bounds['tan'] = u.max()

    # atan / atan2: 4096 ULP
    xa = np.linspace(-1e6, 1e6, N)
    xb = np.float32(xa).view(np.uint32)
    xaf = xb.astype(np.uint32).view(np.float32).astype(np.float64)
    r = run_op(mod, 18, [xb])
    u, _, _ = ulp_err(r, np.arctan(xaf))
    assert u.max() <= 4096, f"atan {u.max():g}"
    bounds['atan'] = u.max()

    rng = np.random.default_rng(0xC0FFEE)
    ya = np.float32(rng.uniform(-100, 100, N)).view(np.uint32)
    xaa = np.float32(rng.uniform(-100, 100, N)).view(np.uint32)
    r = run_op(mod, 25, [ya, xaa])
    ref = np.arctan2(ya.astype(np.uint32).view(np.float32)
                     .astype(np.float64),
                     xaa.astype(np.uint32).view(np.float32)
                     .astype(np.float64))
    u, _, _ = ulp_err(r, ref)
    assert u.max() <= 4096, f"atan2 {u.max():g}"
    bounds['atan2'] = u.max()

    # pow: inherited — record
    xp = np.float32(rng.uniform(0.001, 1e4, N)).view(np.uint32)
    yp = np.float32(rng.uniform(-32, 32, N)).view(np.uint32)
    r = run_op(mod, 26, [xp, yp])
    ref = np.power(xp.astype(np.uint32).view(np.float32)
                   .astype(np.float64),
                   yp.astype(np.uint32).view(np.float32)
                   .astype(np.float64))
    u, _, _ = ulp_err(r, ref)
    bounds['pow'] = u.max()

    # asin/acos/hyperbolics: record
    xi = np.float32(np.linspace(-1.0, 1.0, N)).view(np.uint32)
    for xn, refn, nm, lo, hi in (
            (16, np.arcsin, 'asin', -1, 1), (17, np.arccos, 'acos', -1, 1),
            (22, np.arcsinh, 'asinh', -100, 100),
            (23, np.arccosh, 'acosh', 1, 100),
            (24, np.arctanh, 'atanh', -0.9999, 0.9999),
            (19, np.sinh, 'sinh', -10, 10), (20, np.cosh, 'cosh', -10, 10),
            (21, np.tanh, 'tanh', -10, 10)):
        xw = np.float32(np.linspace(lo, hi, N)).view(np.uint32) \
            if nm not in ('asin', 'acos') else xi
        r = run_op(mod, xn, [xw])
        ref = refn(xw.astype(np.uint32).view(np.float32)
                   .astype(np.float64))
        u, _, _ = ulp_err(r, ref)
        bounds[nm] = u.max()

    return bounds


# ---------------------------------------------------------------------
# Emitters.
# ---------------------------------------------------------------------

NAME_BY_KEY = dict(
    exp2=('APU_SFU_EXP2', ('P6', 'P5', 'P4', 'P3', 'P2', 'P1', 'P0',
                           'C128', 'CM150')),
    log2=('APU_SFU_LOG2', ('T9', 'T7', 'T5', 'T3', 'T1', 'SQRT2')),
    sincos=('APU_SFU_TRIG', ('S4', 'S3', 'S2', 'S1', 'S0',
                             'C4', 'C3', 'C2', 'C1', 'C0',
                             'CW1', 'CW2', 'CW3', 'TWOPI')),
    atan=('APU_SFU_ATAN', ('A11', 'A9', 'A7', 'A5', 'A3', 'A1', 'PI2')),
    exp=('APU_SFU_EXP', ('LOG2E',)), log=('APU_SFU_LOG', ('LN2',)),
    acos=('APU_SFU_ACOS', ('PI',)), atan2=('APU_SFU_ATAN2', ('PI',)),
    sinh=('APU_SFU_SINH', ('LOG2E',)), cosh=('APU_SFU_COSH', ('LOG2E',)),
    tanh=('APU_SFU_TANH', ('TWOLOG2E',)),
    asinh=('APU_SFU_ASINH', ('LN2',)), acosh=('APU_SFU_ACOSH', ('LN2',)),
    atanh=('APU_SFU_ATANH', ('HALFLN2',)),
)

BUDGET = dict(
    exp2='3 + 2|x| ulp', exp='3 + 2|x| ulp',
    log2='3 ulp / 2^-21 abs in [0.5,2]', log='same as log2',
    sin='2^-11 abs on [-pi,pi]', cos='2^-11 abs on [-pi,pi]',
    atan='4096 ulp', atan2='4096 ulp')


def build_tables_src(co, bounds):
    """sfu_tables.py content — exact backend + canonical sequences."""
    lines = ['"""GENERATED by gen_sfu_tables.py — do not edit.',
             'GLSL.std.450 SFU tables + canonical micro-sequences.',
             'sfu_eval(xnum, args) mirrors the shwave jset steps',
             'op-for-op; coefficients are f32 bit patterns identical',
             'to g6lc_apu_sfu_pkg.sv (APU_SFU_*).  The trailing',
             'BOUNDS dict records the measured error budget the TB',
             'uses for Gate-2 tolerance.', '"""', '',
             'COEFS = {']
    for k, vals in co.items():
        nm, subs = NAME_BY_KEY[k]
        row = ', '.join(f'0x{v:08X}' for v in vals)
        lines.append(f'    {k!r}: [{row}],')
    lines.append('}')
    lines.append('')
    lines.append('BOUNDS = {')
    for k in sorted(bounds):
        lines.append(f'    {k!r}: {bounds[k]!r},')
    lines.append('}')
    lines.append(EXACT_SRC)
    lines.append(OPS_SRC)
    return '\n'.join(lines) + '\n'


def build_pkg_src(co, bounds):
    """g6lc_apu_sfu_pkg.sv content."""
    flat = []
    lines = ['// Copyright 2026 Etienne Cimon',
             '// SPDX-License-Identifier: CERN-OHL-S-2.0 OR '
             'LicenseRef-GSys-Commercial',
             '//',
             '// GENERATED by tools/shader/gen_sfu_tables.py — do not',
             '// edit.  f32 constants for the shwave SFU micro-',
             '// sequences (architecture/uncore/apu-vulkan-engine.md',
             '// §7d); sfu_tables.py carries the identical arrays for',
             '// the SPIR-V model.  APU_SFU_BOUND_* are the measured',
             '// per-op error bounds (ULP * 2^20 fixed point; the',
             '// comment gives the §7d budget and the float value).',
             '',
             'package g6lc_apu_sfu_pkg;',
             '']
    for k, vals in co.items():
        nm, subs = NAME_BY_KEY[k]
        base = len(flat)
        lines.append(f'  localparam int unsigned {nm}_BASE = {base};')
        for i, (sub, v) in enumerate(zip(subs, vals)):
            lines.append(f'  // [{base + i}] {nm}_{sub} = '
                         f'{float(np.uint32(v).view(np.float32))!r}')
            flat.append(v)
        lines.append('')
    lines.append(f'  localparam int unsigned APU_SFU_N = {len(flat)};')
    lines.append('  localparam logic [31:0] APU_SFU_COEF'
                 f' [0:{len(flat) - 1}] = \'{{')
    # '{...} maps left-to-right onto the ascending [0:N] index range —
    # emit in natural order (a previous reversed() per chunk scrambled
    # every group of 4 coefficients).
    for i in range(0, len(flat), 4):
        chunk = ', '.join(f"32'h{v:08X}" for v in flat[i:i + 4])
        sep = ',' if i + 4 < len(flat) else ''
        lines.append(f'      {chunk}{sep}')
    lines.append('      };')
    lines.append('')
    lines.append('  localparam logic [31:0] APU_SFU_QNAN = '
                 "32'h7FC00000;")
    lines.append('')
    for k in sorted(bounds):
        lines.append(f'  // {k}: measured bound {bounds[k]:.6g}; '
                     f'budget {BUDGET.get(k, "inherited")}')
        lines.append(f'  localparam longint unsigned APU_SFU_BOUND_'
                     f'{k.upper()}_E20 = '
                     f"64'd{int(round(bounds[k] * 1048576))};")
    lines.append('')
    # Gate-2 lookup for tb_g6lc_apu_shwave class-4 words, indexed by
    # (xnum - 13): E20 = ULP * 2^20; 0 means the op's bound is the
    # absolute fp32 value in APU_SFU_BND_ABS (bits).
    order = ['sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'sinh',
             'cosh', 'tanh', 'asinh', 'acosh', 'atanh', 'atan2',
             'pow', 'exp', 'log', 'exp2', 'log2']
    e20 = [0] * 18
    abits = [0] * 18
    for i, k in enumerate(order):
        b = bounds.get(k, 0)
        if 0 < b < 1:                    # absolute bound (sin/cos)
            abits[i] = int(
                np.float32(b).view(np.uint32))
        else:
            e20[i] = int(round(b * 1048576))
    lines.append('  localparam longint unsigned APU_SFU_BND_E20'
                 ' [0:17] = \'{')
    for i in range(0, 18, 3):
        chunk = ', '.join(f"64'd{e20[j]}" for j in
                          range(i, min(i + 3, 18)))
        lines.append(f'      {chunk}{"," if i + 3 < 18 else ""}')
    lines.append('      };')
    lines.append('  localparam int unsigned APU_SFU_BND_ABS'
                 ' [0:17] = \'{')
    for i in range(0, 18, 6):
        chunk = ', '.join(f"32'h{abits[j]:08X}" for j in
                          range(i, min(i + 6, 18)))
        lines.append(f'      {chunk}{"," if i + 6 < 18 else ""}')
    lines.append('      };')
    lines.append('')
    lines.append('endpackage')
    lines.append('')
    return '\n'.join(lines)


def write_if_changed(path, text):
    try:
        old = open(path).read()
    except FileNotFoundError:
        old = None
    if old == text:
        return False
    with open(path, 'w') as f:
        f.write(text)
    return True


def main():
    import types
    co = fit_all()
    src = build_tables_src(co, {})          # BOUNDS placeholder pass
    g = {}
    exec(src, g)
    mod = types.SimpleNamespace(SFU_FUNCS=g['SFU_FUNCS'])
    bounds = measure(mod)
    tab = build_tables_src(co, bounds)
    pkg = build_pkg_src(co, bounds)
    if '--check' in sys.argv:
        drift = [p for p, t in ((TAB, tab), (PKG, pkg))
                 if not os.path.exists(p) or open(p).read() != t]
        if drift:
            print('FAIL sfu tables stale:', *drift)
            sys.exit(1)
        print('PASS g6lc_apu_sfu_pkg.sv + sfu_tables.py: fresh')
        return
    for p, t in ((TAB, tab), (PKG, pkg)):
        write_if_changed(p, t)
        print('wrote', p)
    for k in sorted(bounds):
        print(f'  bound {k:8s} {bounds[k]:.6g}   (budget '
              f'{BUDGET.get(k, "inherited")})')


if __name__ == '__main__':
    main()
