#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""spirv_model.py — bit-exact reference interpreter for the G6LC
ShaderCore increment-4a subset (architecture doc §7a, "the ShaderCore's
commit scanner and the straight-line compute path").

This is the Gate-1 oracle: `tb_g6lc_apu_shwave` requires the RTL to
match this model **bit-for-bit** on every output word and on the
robustness counter.  The model therefore replicates the RTL's exact
micro-sequences (see `g6lc_apu_shwave.sv` and the "ShaderCore arithmetic
definitions" section of `g6lc_apu_vn_tables.md`), NOT an idealized
Vulkan semantics:

  * FP32 arithmetic uses Python doubles as the substrate with an
    explicit round-to-FP32 after every operation.  +,-,*,/,sqrt are
    correctly rounded (f64 carries >= 2*24+2 significand bits, so the
    double rounding is innocuous); FMA/FMADD is single-rounded through
    an exact Fraction -> binary32 conversion.
  * Every FPnew special case is reproduced: canonical NaN
    0x7FC00000 for all NaN-producing ops (fpnew does not propagate
    payloads), the fpnew_cast_multi F2I/I2F special tables, the
    fpnew_noncomp CMP truth table (LE/LT/EQ keyed by rounding mode,
    op_mod inversion, NaN rules) and MINMAX (RNE=MIN, RTZ=MAX).
  * Integer ops wrap to 32 bits; the iterative divider's semantics
    (divide-by-zero -> 0, SMod takes the divisor's sign, SDiv/SRem
    sign corrections) are reproduced exactly.
  * Memory obeys robustBufferAccess: OOB loads return 0, OOB stores
    are dropped, and every OOB access increments `robust`.  Pointer
    registers carry the RTL's {offset, tag} record; storage-class
    dispatch, binding lookup, push-constant window, builtin loads,
    workgroup slab and per-invocation scratch bounds are all
    replicated.

If the RTL disagrees with this model anywhere, the RTL is presumed
wrong unless the model can be shown to be wrong.

Usage:
    spirv_model.py vector.hex [--json out.json]

The vector .hex layout is the shader_vectors.py dispatch record:
  [0] n_spv  [1] n_bindings  [2] n_push  [3..5] gx gy gz
  [6] flags  [7] tag  [8..8+n_spv) SPIR-V words
  per binding: {set, binding, size_bytes, mem_addr}
  then n_push push words, then per-binding init words, then sentinel.

Model output: per output binding (a binding that received at least one
in-bounds store) the model's memory words, the model robust count, and
a per-word class ('f' float / 'i' integer-bool) recorded from the
stored value's SPIR-V type — used by the testbench for Gate 2.
"""
import json
import math
import os
import struct
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import spirv_scan  # noqa: E402

SC = spirv_scan.SC
TK = spirv_scan.TK

# DUT default geometry (g6lc_apu_shwave parameters)
SCRATCH_WORDS = 256        # ScratchBytes=1024 / 4
SLAB_WORDS = 4096          # SlabBytes=16384 / 4
LAN = 8                    # ShaderLanes

# storage-class / builtin ids (must match g6lc_apu_sh_pkg)
SC_INPUT = SC['INPUT']
SC_UNIFORM = SC['UNIFORM']
SC_SBUF = SC['SBUF']
SC_WORKGROUP = SC['WORKGROUP']
SC_PRIVATE = SC['PRIVATE']
SC_FUNCTION = SC['FUNCTION']
SC_PUSHCONST = SC['PUSHCONST']

BI_NUMWG = 24
BI_WGSIZE = 25
BI_WGID = 26
BI_LID = 27
BI_GID = 28
BI_LINDEX = 29

QNAN = 0x7FC00000

# ---------------------------------------------------------------------
# FP helpers — every value crossing an op boundary is a u32 bit pattern
# ---------------------------------------------------------------------


def b2f(w):
    """u32 bits -> Python float (exact)."""
    return struct.unpack('<f', struct.pack('<I', w & 0xFFFFFFFF))[0]


def f2b(x):
    """Python float -> f32 bits, RNE; overflow -> inf; NaN -> canonical."""
    if math.isnan(x):
        return QNAN
    try:
        return struct.unpack('<I', struct.pack('<f', x))[0]
    except OverflowError:
        return 0xFF800000 if x < 0 else 0x7F800000


def isnan(w):
    return (w & 0x7F800000) == 0x7F800000 and (w & 0x7FFFFF) != 0


def issnan(w):
    return isnan(w) and (w & 0x400000) == 0


def isinf(w):
    return (w & 0x7FFFFFFF) == 0x7F800000


def fadd(a, b):
    return f2b(b2f(a) + b2f(b))


def fsub(a, b):
    return f2b(b2f(a) - b2f(b))


def fmul(a, b):
    return f2b(b2f(a) * b2f(b))


def fdiv(a, b):
    fa, fb = b2f(a), b2f(b)
    if math.isnan(fa) or math.isnan(fb):
        return QNAN
    if fb == 0.0:
        if fa == 0.0:
            return QNAN                      # 0/0
        return f2b(math.copysign(math.inf, fa) *
                   math.copysign(1.0, fb))
    if math.isinf(fb):
        if math.isinf(fa):
            return QNAN                      # inf/inf
        return f2b(math.copysign(0.0, fa) * math.copysign(1.0, fb))
    if math.isinf(fa):
        return f2b(math.copysign(math.inf, fa) * math.copysign(1.0, fb))
    return f2b(fa / fb)


def fsqrt(a):
    fa = b2f(a)
    if math.isnan(fa):
        return QNAN
    if fa == 0.0:
        return a & 0x80000000                # sqrt(-0) = -0
    if fa < 0.0:
        return QNAN
    return f2b(math.sqrt(fa))


def _round_shift(n, d, e2):
    """round(n / (d * 2**e2)) to integer, ties to even — n,d > 0."""
    if e2 >= 0:
        dd = d << e2
        nn = n
    else:
        nn = n << (-e2)
        dd = d
    q, r = divmod(nn, dd)
    twice = r << 1
    if twice > dd or (twice == dd and (q & 1)):
        q += 1
    return q


def frac_to_f32_bits(fr, neg_zero=False):
    """exact Fraction -> binary32 bits, round-to-nearest-even."""
    if fr == 0:
        return 0x80000000 if neg_zero else 0
    sgn = fr < 0
    a = -fr if sgn else fr
    n, d = a.numerator, a.denominator
    # e such that 2**e <= a < 2**(e+1)
    e = n.bit_length() - d.bit_length()
    if e >= 0:
        if n < (d << e):
            e -= 1
    else:
        if (n << (-e)) < d:
            e -= 1
    if e >= -126:
        m = _round_shift(n, d, e - 23)       # 24-bit significand
        if m >> 24:
            m >>= 1
            e += 1
        if e > 127:
            return (0xFF800000 if sgn else 0x7F800000)
        bits = ((e + 127) << 23) | (m & 0x7FFFFF)
    else:
        # subnormal: fixed exponent -149
        m = _round_shift(n, d, -149)
        if m >= (1 << 23):
            bits = (1 << 23)                 # rounded up to min normal
        else:
            bits = m
    return bits | (int(sgn) << 31)


def ffma(a, b, c):
    """fpnew FMADD: fl32(a*b + c) — single rounding via exact Fraction."""
    fa, fb, fc = b2f(a), b2f(b), b2f(c)
    if math.isnan(fa) or math.isnan(fb) or math.isnan(fc):
        return QNAN
    # inf*0 or inf + -inf -> canonical qNaN
    prod_inf = math.isinf(fa) or math.isinf(fb)
    if prod_inf and (fa == 0.0 or fb == 0.0):
        return QNAN
    if math.isinf(fa) or math.isinf(fb):
        psign = math.copysign(1.0, fa) * math.copysign(1.0, fb)
        if math.isinf(fc) and math.copysign(1.0, fc) != psign:
            return QNAN
        return 0xFF800000 if psign < 0 else 0x7F800000
    if math.isinf(fc):
        return c & 0xFFFFFFFF
    # exact: a*b + c
    fr = Fraction(fa) * Fraction(fb) + Fraction(fc)
    if fr == 0:
        # exact zero: -0 only when both contributions are -0
        sp = (a >> 31) & 1 ^ (b >> 31) & 1   # product sign (may be -0)
        neg = sp and (fc == 0.0 and math.copysign(1.0, fc) < 0)
        return 0x80000000 if neg else 0
    return frac_to_f32_bits(fr)


# fpnew_noncomp helpers ------------------------------------------------


def _a_smaller(a, b):
    """fpnew packed-struct compare: u32 compare XOR any sign bit."""
    return ((a & 0xFFFFFFFF) < (b & 0xFFFFFFFF)) ^ bool((a | b) & 0x80000000)


def _fp_eq(a, b):
    """operands_equal: bitwise equal or both zero."""
    return a == b or ((a & 0x7FFFFFFF) == 0 and (b & 0x7FFFFFFF) == 0)


def fp_cmp(a, b, rnd, mod):
    """fpnew CMP: rnd RNE=LE RTZ=LT RDN=EQ; mod inverts (except sNaN
    and the NaN rules).  Returns 0/1."""
    snan = issnan(a) or issnan(b)
    anan = isnan(a) or isnan(b)
    if snan:
        return 1 if (rnd == 'RDN' and mod) else 0
    if rnd == 'RNE':                          # LE
        if anan:
            return 0
        return int((_a_smaller(a, b) or _fp_eq(a, b)) ^ bool(mod))
    if rnd == 'RTZ':                          # LT
        if anan:
            return 0
        return int((_a_smaller(a, b) and not _fp_eq(a, b)) ^ bool(mod))
    # RDN — EQ
    if anan:
        return int(mod)
    return int(_fp_eq(a, b) ^ bool(mod))


def fp_minmax(a, b, is_max):
    """fpnew MINMAX: RNE=MIN RTZ=MAX; canonical qNaN if both NaN;
    single NaN returns the other operand."""
    na, nb = isnan(a), isnan(b)
    if na and nb:
        return QNAN
    if na:
        return b
    if nb:
        return a
    if is_max:
        return a if not _a_smaller(a, b) else b
    return a if _a_smaller(a, b) else b


# fpnew_cast_multi -----------------------------------------------------


def _round_int(x, rnd):
    """exact float -> mathematical integer under fpnew rounding mode."""
    if rnd == 'RTZ':
        return math.trunc(x)
    if rnd == 'RDN':
        return math.floor(x)
    if rnd == 'RUP':
        return math.ceil(x)
    if rnd == 'RMM':
        return (math.floor(x + 0.5) if x > 0 else
                -math.floor(-x + 0.5))       # half away from zero
    # RNE — ties to even
    f = math.floor(x)
    r = x - f
    if r > 0.5:
        return f + 1
    if r < 0.5:
        return f
    return f + (f & 1)


def f2i(w, unsigned, rnd='RTZ'):
    """fpnew_cast_multi F2I (32-bit).  Returns a u32 pattern."""
    x = b2f(w)
    if math.isnan(x):
        return 0xFFFFFFFF if unsigned else 0x7FFFFFFF
    r = _round_int(x, rnd) if math.isfinite(x) else None
    special = (not math.isfinite(x)) or \
        (unsigned and (x < 0 and r != 0)) or \
        (r is not None and
         (r > (0xFFFFFFFF if unsigned else 0x7FFFFFFF) or
          r < (0 if unsigned else -0x80000000)))
    if special:
        res = 0xFFFFFFFF if unsigned else 0x7FFFFFFF
        if math.copysign(1.0, x) < 0:
            res = (~res) & 0xFFFFFFFF
        return res
    return r & 0xFFFFFFFF


def i2f(w, unsigned):
    """fpnew_cast_multi I2F -> f32 bits, RNE."""
    v = w & 0xFFFFFFFF
    if not unsigned and v & 0x80000000:
        v -= 0x100000000
    return f2b(float(v))


def s32(w):
    return w - 0x100000000 if w & 0x80000000 else w


def u32(x):
    return x & 0xFFFFFFFF


# ---------------------------------------------------------------------
# The interpreter
# ---------------------------------------------------------------------


class Model:
    """Executes one dispatch of a scanned 4a-subset module."""

    def __init__(self, words, scratch_words=SCRATCH_WORDS,
                 slab_words=SLAB_WORDS):
        self.w = words
        self.sc_w = scratch_words
        self.slb_w = slab_words
        # ---- parse the .hex dispatch record ----
        n = words[0]
        self.nb = words[1]
        self.np = words[2]
        self.gx, self.gy, self.gz = words[3], words[4], words[5]
        self.flags = words[6]
        self.spv = words[8:8 + n]
        p = 8 + n
        self.binds = []                        # (set,bd,size,addr)
        for _ in range(self.nb):
            self.binds.append(tuple(words[p:p + 4]))
            p += 4
        self.push = words[p:p + self.np]
        p += self.np
        self.mem = {}                          # word addr -> u32
        for (st, bd, sz, ad) in self.binds:
            for i in range(sz // 4):
                self.mem[(ad >> 2) + i] = words[p + i]
            p += sz // 4
        # ---- scan the module (spirv_scan golden tables) ----
        self.sc = spirv_scan.Scanner(self.spv)
        self.sc.scan()
        self.lx, self.ly, self.lz = self.sc.localsize
        self.robust = 0
        self.wclass = {}                       # word addr -> 'f'/'i'
        self.slab = None
        self.wg = (0, 0, 0)
        self.wave = 0
        self.lane = 0
        self.inv = 0
        self.scratch = None
        self.rf = None
        self.fault = None
        self.cur_pc = 0
        self.l0_idx = {}          # (pc, id) -> lane-0 chain index value

    # -- memory --------------------------------------------------------
    def mread(self, byte_addr):
        return self.mem.get(byte_addr >> 2, 0)

    def mwrite(self, byte_addr, val, cls):
        self.mem[byte_addr >> 2] = val & 0xFFFFFFFF
        self.wclass[byte_addr >> 2] = cls

    def binding(self, st, bd):
        """f_bind: last matching bind record wins (RTL scans 0..15 and
        overwrites r on match)."""
        r = None
        for (s2, b2, sz, ad) in self.binds:
            if s2 == st and b2 == bd:
                r = (ad, sz)
        return r                              # (base,size) or None

    def builtin(self, bi, c):
        """f_bi() — lane builtin values for the current invocation."""
        lx, ly, lz = self.lx, self.ly, self.lz
        inv = self.inv
        lix = inv % lx if lx else 0
        liy = (inv // lx) % ly if lx and ly else 0
        liz = inv // (lx * ly) if lx and ly else 0
        wgx, wgy, wgz = self.wg
        if bi == BI_GID:
            return ((wgx * lx + lix) if c == 0 else
                    (wgy * ly + liy) if c == 1 else
                    (wgz * lz + liz) if c == 2 else 0)
        if bi == BI_LID:
            return lix if c == 0 else liy if c == 1 else \
                liz if c == 2 else 0
        if bi == BI_WGID:
            return wgx if c == 0 else wgy if c == 1 else \
                wgz if c == 2 else 0
        if bi == BI_NUMWG:
            return self.gx if c == 0 else self.gy if c == 1 else \
                self.gz if c == 2 else 0
        if bi == BI_WGSIZE:
            return lx if c == 0 else ly if c == 1 else \
                lz if c == 2 else 0
        if bi == BI_LINDEX:
            return inv if c == 0 else 0
        return 0

    # -- LSU -----------------------------------------------------------
    def lsu(self, ptr_off, ptr_tag, comp, is_store, val, cls):
        """One (lane,comp) access; returns loaded word (loads) or None."""
        o32 = u32(ptr_off + comp * 4)
        sc = ptr_tag & 0xF
        bi = (ptr_tag >> 4) & 0xFF
        st = (ptr_tag >> 12) & 0xFF
        bd = (ptr_tag >> 20) & 0xFF
        if sc == SC_INPUT:
            if is_store:
                return None                    # stores to input: nothing
            return self.builtin(bi, o32 >> 2)
        if sc == SC_PUSHCONST:
            if (o32 >> 2) >= self.np:
                self.robust += 1
                return 0 if not is_store else None
            return None if is_store else self.push[o32 >> 2]
        if sc in (SC_UNIFORM, SC_SBUF):
            b = self.binding(st, bd)
            if b is None or o32 + 4 > b[1]:
                self.robust += 1
                return 0 if not is_store else None
            if is_store:
                self.mwrite(b[0] + o32, val, cls)
                return None
            return self.mread(b[0] + o32)
        if sc == SC_WORKGROUP:
            if (o32 >> 2) >= self.slb_w:
                self.robust += 1
                return 0 if not is_store else None
            if is_store:
                self.slab[o32 >> 2] = val & 0xFFFFFFFF
                return None
            return self.slab[o32 >> 2]
        if sc in (SC_FUNCTION, SC_PRIVATE):
            if (o32 >> 2) >= self.sc_w or o32 >= self.sc.scratch:
                self.robust += 1
                return 0 if not is_store else None
            if is_store:
                self.scratch[o32 >> 2] = val & 0xFFFFFFFF
                return None
            return self.scratch[o32 >> 2]
        self.robust += 1
        return 0 if not is_store else None

    # -- operand fetch ---------------------------------------------------
    def regv(self, iid):
        """operand value vec4: const table (tag 1) or RF row."""
        r = self.sc.regmap.get(iid)
        if r is None:
            return [0, 0, 0, 0]
        tag, idx, tid, aux = r
        if tag == 1:
            cw = self.sc.consts.get(iid, [0])
            return [cw[c] if c < len(cw) else cw[0] for c in range(4)]
        return list(self.rf[idx])

    def regt(self, iid):
        r = self.sc.regmap.get(iid)
        return r[2] if r else 0

    def ncomps(self, tid):
        t = self.sc.types.get(tid)
        if t is None:
            return 1
        if t['kind'] == TK['VEC']:
            return t['comps']
        if t['kind'] == TK['MAT']:
            return t['cols'] * self.sc.types[t['elem']]['comps']
        return 1

    def setres(self, rid, vec, ncomp):
        r = self.sc.regmap.get(rid)
        if r is None or r[0] == 1:
            return
        dst = self.rf[r[1]]
        for c in range(min(ncomp, 4)):
            dst[c] = vec[c] & 0xFFFFFFFF

    # -- per-lane value for a chain index operand -------------------------
    def idxval(self, iid):
        """chain index word0 of the current invocation."""
        r = self.sc.regmap.get(iid)
        if r is None:
            return 0
        if r[0] == 1:
            cw = self.sc.consts.get(iid, [0])
            return cw[0]
        return self.rf[r[1]][0]

    def idxval_struct(self, iid):
        """struct member index — the RTL reads lane 0 of the wave
        (`vix_q[0][0]`, W_CHT1).  Lane 0 runs first and records its
        value per (pc, id); other lanes replay it."""
        key = (self.cur_pc, iid)
        if self.lane == 0:
            self.l0_idx[key] = self.idxval(iid)
            return self.l0_idx[key]
        if key in self.l0_idx:
            return self.l0_idx[key]
        return self.idxval(iid)     # unreachable in the corpus order

    def chain(self, base, ids):
        """OpAccessChain walk — replicates W_CHT/CHM/CHE/CHX."""
        ptr = self.regv(base)
        off = ptr[0]
        tag = ptr[1]
        cty = self.sc.types.get(self.regt(base), {})
        cty = cty.get('elem', 0)               # pointee type
        cmstride = 0
        for iid in ids:
            t = self.sc.types.get(cty)
            if t is None:
                break
            k = t['kind']
            if k == TK['STRUCT']:
                midx = self.idxval_struct(iid)
                mb = self.sc.member_base.get(cty, 0) + midx
                if mb < len(self.sc.members):
                    m = self.sc.members[mb]
                    off = u32(off + m['offset'])
                    cmstride = m['mstride']
                    cty = m['type']
                continue
            if k in (TK['ARRAY'], TK['RARRAY']):
                st_ = t['stride'] if t['stride'] else \
                    self.natural_size(t['elem'])
            elif k == TK['MAT']:
                et = self.sc.types.get(t['elem'], {'comps': 1})
                st_ = cmstride if cmstride else 4 * et['comps']
            elif k == TK['VEC']:
                st_ = 4
            else:
                st_ = 4
            elem = t.get('elem', cty)
            off = u32(off + self.idxval(iid) * st_)
            cty = elem
        return [off, tag, 0, 0]

    def natural_size(self, tid):
        """W_CHE0: ty_size != 0 ? size : 4 (natural layout)."""
        try:
            sz = self.sc.size_of(tid)
        except Exception:
            sz = 0
        return sz if sz else 4

    # -- GLSL.std.450 micro-sequences ------------------------------------
    # jset operands are described by (cmode, source): cmode 0 = per-unit
    # comp, 1 = broadcast comp0, 2 = iterate comp tc, 3 = cross swizzle.
    # The model evaluates per-invocation so we apply them directly.

    def x_ext(self, xnum, va, vt):
        """GLSL.std.450 — exact RTL micro-sequences."""
        if xnum in (4,):                      # FAbs
            return [v & 0x7FFFFFFF for v in va[0]]
        if xnum == 5:                         # SAbs
            return [u32(-s32(v)) if v & 0x80000000 else v
                    for v in va[0]]
        if xnum == 6:                         # FSign
            return [(v if isnan(v) else
                     0 if (v & 0x7FFFFFFF) == 0 else
                     0xBF800000 if v & 0x80000000 else 0x3F800000)
                    for v in va[0]]
        if xnum == 7:                         # SSign
            return [0 if v == 0 else
                    0xFFFFFFFF if v & 0x80000000 else 1
                    for v in va[0]]
        if xnum in (8, 9, 3, 1, 2):           # Floor Ceil Trunc Round REven
            mode = {8: 'RDN', 9: 'RUP', 3: 'RTZ',
                    1: 'RMM', 2: 'RNE'}[xnum]
            out = []
            for c in range(4):
                i = f2i(va[0][c], False, mode)
                f = i2f(i, False)
                # guard: NaN or |x| >= 2**31 (biased exp >= 158) -> x
                out.append(va[0][c] if (isnan(va[0][c]) or
                                        ((va[0][c] >> 23) & 0xFF) >= 158)
                           else f)
            return out
        if xnum == 10:                        # Fract = x - floor(x)
            out = []
            for c in range(4):
                i = f2i(va[0][c], False, 'RDN')
                f = i2f(i, False)
                t1 = va[0][c] if (isnan(va[0][c]) or
                                  ((va[0][c] >> 23) & 0xFF) >= 158) else f
                out.append(fsub(va[0][c], t1))
            return out
        if xnum == 31:                        # Sqrt
            return [fsqrt(v) for v in va[0]]
        if xnum == 32:                        # InverseSqrt = 1/sqrt(x)
            return [fdiv(0x3F800000, fsqrt(v)) for v in va[0]]
        if xnum == 37:                        # FMin
            return [fp_minmax(va[0][c], va[1][c], False)
                    for c in range(4)]
        if xnum == 40:                        # FMax
            return [fp_minmax(va[0][c], va[1][c], True)
                    for c in range(4)]
        if xnum == 38:                        # UMin
            return [a if a < b else b for a, b in zip(va[0], va[1])]
        if xnum == 41:                        # UMax
            return [a if a > b else b for a, b in zip(va[0], va[1])]
        if xnum == 39:                        # SMin
            return [a if s32(a) < s32(b) else b
                    for a, b in zip(va[0], va[1])]
        if xnum == 42:                        # SMax
            return [a if s32(a) > s32(b) else b
                    for a, b in zip(va[0], va[1])]
        if xnum == 43:                        # FClamp = min(max(x,lo),hi)
            return [fp_minmax(fp_minmax(va[0][c], va[1][c], True),
                              va[2][c], False) for c in range(4)]
        if xnum == 44:                        # UClamp
            return [va[1][c] if va[0][c] < va[1][c] else
                    (va[2][c] if va[0][c] > va[2][c] else va[0][c])
                    for c in range(4)]
        if xnum == 45:                        # SClamp
            return [va[1][c] if s32(va[0][c]) < s32(va[1][c]) else
                    (va[2][c] if s32(va[0][c]) > s32(va[2][c])
                     else va[0][c]) for c in range(4)]
        if xnum == 46:                        # FMix = x*(1-t) + y*t
            # lavapipe nir_lower_flrp strict form, ffma lowered
            return [fadd(fmul(va[0][c], fsub(0x3F800000, va[2][c])),
                         fmul(va[1][c], va[2][c])) for c in range(4)]
        if xnum == 48:                        # Step(edge,x): 0 if x<edge
            return [0 if fp_cmp(va[1][c], va[0][c], 'RTZ', False)
                    else 0x3F800000 for c in range(4)]
        if xnum == 49:                        # SmoothStep(e0,e1,x)
            out = []
            for c in range(4):
                t0c = fsub(va[2][c], va[0][c])        # x-e0
                t1c = fsub(va[1][c], va[0][c])        # e1-e0
                t0c = fdiv(t0c, t1c)                  # t
                t1c = fp_minmax(t0c, 0, True)         # max(t,0)
                t1c = fp_minmax(t1c, 0x3F800000, False)  # min(t,1)
                t2c = fmul(0xC0000000, t1c)           # -2*t
                t0c = fadd(0x40400000, t2c)           # 3-2t
                t2c = fmul(t1c, t0c)                  # t*(3-2t)
                out.append(fmul(t1c, t2c))            # t*(t*(3-2t))
            return out
        if xnum == 50:                        # Fma = mul+add (ffma lowered)
            return [fadd(fmul(va[0][c], va[1][c]), va[2][c])
                    for c in range(4)]
        if xnum == 66:                        # Length = sqrt(dot(v,v))
            nc = self.ncomps(vt[0])
            m = [fmul(va[0][c], va[0][c]) for c in range(nc)]
            t = fmul(m[nc-1], 0x3F800000)
            for c in range(nc-2, -1, -1):
                t = ffma(m[c], 0x3F800000, t)
            return [fsqrt(t), 0, 0, 0]
        if xnum == 67:                        # Distance(p0,p1)
            nc = self.ncomps(vt[0])
            d = [fsub(va[0][c], va[1][c]) for c in range(4)]
            m = [fmul(d[c], d[c]) for c in range(nc)]
            t = fmul(m[nc-1], 0x3F800000)
            for c in range(nc-2, -1, -1):
                t = ffma(m[c], 0x3F800000, t)
            return [fsqrt(t), 0, 0, 0]
        if xnum == 68:                        # Cross
            a, b = va[0], va[1]
            t0 = [fmul(a[1], b[2]), fmul(a[2], b[0]), fmul(a[0], b[1])]
            t1 = [fmul(a[2], b[1]), fmul(a[0], b[2]), fmul(a[1], b[0])]
            return [fsub(t0[c], t1[c]) for c in range(3)] + [0]
        if xnum == 69:                        # Normalize = v * (1/sqrt(dot))
            nc = self.ncomps(vt[0])
            m = [fmul(va[0][c], va[0][c]) for c in range(nc)]
            t = fmul(m[nc-1], 0x3F800000)
            for c in range(nc-2, -1, -1):
                t = ffma(m[c], 0x3F800000, t)
            r = fdiv(0x3F800000, fsqrt(t))
            return [fmul(va[0][c], r) for c in range(4)]
        raise self.FaultX(xnum)

    class FaultX(Exception):
        pass

    # -- integer divider (W_IDIV semantics) ------------------------------
    @staticmethod
    def idiv(a, b, signed, want_rem, smod):
        if signed:
            mag_a = u32(-s32(a)) if a & 0x80000000 else a
            mag_b = u32(-s32(b)) if b & 0x80000000 else b
        else:
            mag_a, mag_b = a, b
        if mag_b == 0:
            q = r = 0
        else:
            q, r = divmod(mag_a, mag_b)
        if smod:
            if r == 0:
                return 0
            if (a >> 31) == (b >> 31):
                return u32(-r) if b & 0x80000000 else r
            res = u32(mag_b - r)
            return u32(-res) if b & 0x80000000 else res
        if signed:
            if (a >> 31) != (b >> 31):
                q = u32(-q)
            if a & 0x80000000:
                r = u32(-r)
        return r if want_rem else q

    # -- instruction execution -------------------------------------------
    def exec_one(self, pc):
        """execute the instruction at word offset pc; returns next pc or
        'ret'."""
        w = self.spv
        w0 = w[pc]
        wc = w0 >> 16
        opc = w0 & 0xFFFF
        ops = w[pc + 1:pc + wc]
        rty = ops[0] if opc in self.HAS_RTY else 0
        rid = ops[1] if opc in self.HAS_RTY else 0
        ncomp = self.ncomps(rty) if opc in self.HAS_RTY else 1
        # operand vectors
        def opid(k):
            if opc == 62:
                return ops[k] if k < len(ops) else 0
            if opc == 12:
                return ops[4 + k] if 4 + k < len(ops) else 0
            return ops[2 + k] if 2 + k < len(ops) else 0
        nva = self.nva(opc, wc)
        va = [self.regv(opid(k)) for k in range(nva)] + \
             [[0] * 4] * (4 - nva)
        vt = [self.regt(opid(k)) for k in range(nva)] + \
             [0] * (4 - nva)

        if opc in (0, 54, 59, 248):           # Nop Function Variable Label
            return pc + wc
        if opc in (56, 253):                  # FunctionEnd / Return
            return 'ret'
        if opc == 249:                        # Branch (uniform forward)
            return self.sc.labels[ops[0]]
        if opc == 61:                         # Load
            wb = [0, 0, 0, 0]
            for c in range(ncomp):
                r = self.lsu(va[0][0], va[0][1], c, False, 0, 'i')
                wb[c] = r if r is not None else 0
            self.setres(rid, wb, ncomp)
            return pc + wc
        if opc == 62:                         # Store
            ncs = self.ncomps(vt[1])          # stored value type comps
            cls = self.classof(vt[1])
            for c in range(ncs):
                self.lsu(va[0][0], va[0][1], c, True, va[1][c], cls)
            return pc + wc
        if opc in (65, 66):                   # (InBounds)AccessChain
            wb = self.chain(ops[2], ops[3:]) if len(ops) > 3 \
                else va[0]
            self.setres(rid, wb, 4)
            return pc + wc
        if opc == 68:                         # ArrayLength
            ptr = va[0]
            b = self.binding((ptr[1] >> 12) & 0xFF, (ptr[1] >> 20) & 0xFF)
            bsz = b[1] if b else 0
            stt = self.sc.types.get(self.regt(ops[2]), {})
            sty = self.sc.types.get(stt.get('elem', 0), {})
            midx = ops[3]
            mb = self.sc.member_base.get(stt.get('elem', 0), 0) + midx
            m = self.sc.members[mb]
            mt = self.sc.types.get(m['type'], {})
            stride = mt.get('stride', 0) or 4
            num = (bsz - m['offset']) if bsz >= m['offset'] else 0
            self.setres(rid, [num // stride, 0, 0, 0], 1)
            return pc + wc
        if opc == 79:                         # VectorShuffle
            wb = [0] * 4
            for c in range(ncomp):
                lit = ops[4 + c]
                if lit == 0xFFFFFFFF:
                    wb[c] = 0
                elif lit & 4:
                    wb[c] = va[1][lit & 3]
                else:
                    wb[c] = va[0][lit & 3]
            self.setres(rid, wb, ncomp)
            return pc + wc
        if opc == 80:                         # CompositeConstruct
            wb = [0] * 4
            pos = 0
            for k in range(nva):
                nc = self.ncomps(vt[k])
                for c in range(nc):
                    if pos + c < 4:
                        wb[pos + c] = va[k][c]
                pos += nc
            self.setres(rid, wb, ncomp)
            return pc + wc
        if opc == 81:                         # CompositeExtract
            self.setres(rid, [va[0][ops[3] & 3], 0, 0, 0], 1)
            return pc + wc
        if opc == 82:                         # CompositeInsert
            wb = list(va[1])
            wb[ops[4] & 3] = va[0][0]
            self.setres(rid, wb, ncomp)
            return pc + wc
        if opc == 124:                        # Bitcast
            self.setres(rid, va[0], ncomp)
            return pc + wc

        # per-component ALU ops
        wb = [0, 0, 0, 0]
        if opc == 12:                         # ExtInst
            wb = self.x_ext(ops[3], va, vt)
        elif opc in self.INTOPS:
            wb = self.intop(opc, va, vt)
        elif opc in (129, 131, 133):          # FAdd FSub FMul
            for c in range(4):
                a, b = va[0][c], va[1][c]
                wb[c] = fadd(a, b) if opc == 129 else \
                    fsub(a, b) if opc == 131 else fmul(a, b)
        elif opc == 136:                      # FDiv
            wb = [fdiv(va[0][c], va[1][c]) for c in range(4)]
        elif opc == 142:                      # VectorTimesScalar
            wb = [fmul(va[0][c], va[1][0]) for c in range(4)]
        elif opc == 148:                      # Dot
            # lavapipe fdotN fold: products then (m_{n-1}+...)+m_0.
            # RTL: MUL sweep into t1, then FMADD(m_c,1.0,acc) in
            # reverse comp order (b=1.0 -> single-rounded fadd).
            nc = self.ncomps(vt[0])
            m = [fmul(va[0][c], va[1][c]) for c in range(nc)]
            t = fmul(m[nc-1], 0x3F800000)
            for c in range(nc-2, -1, -1):
                t = ffma(m[c], 0x3F800000, t)
            wb = [t, 0, 0, 0]
        elif opc in (109, 110, 111, 112):     # converts
            if opc == 109:
                wb = [f2i(v, True, 'RTZ') for v in va[0]]
            elif opc == 110:
                wb = [f2i(v, False, 'RTZ') for v in va[0]]
            elif opc == 111:
                wb = [i2f(v, False) for v in va[0]]
            else:
                wb = [i2f(v, True) for v in va[0]]
        elif opc in (180, 181, 182, 183, 184, 185, 186, 187,
                     188, 189, 190, 191):     # fp compares
            FCMP = {180: ('RDN', 0, (0, 1)), 181: ('RDN', 0, (0, 1)),
                    182: ('RDN', 1, (0, 1)), 183: ('RDN', 1, (0, 1)),
                    184: ('RTZ', 0, (0, 1)), 185: ('RTZ', 0, (0, 1)),
                    186: ('RTZ', 0, (1, 0)), 187: ('RTZ', 0, (1, 0)),
                    188: ('RNE', 0, (0, 1)), 189: ('RNE', 0, (0, 1)),
                    190: ('RNE', 0, (1, 0)), 191: ('RNE', 0, (1, 0))}
            rnd, mod, sw = FCMP[opc]
            wb = [fp_cmp(va[sw[0]][c], va[sw[1]][c], rnd, mod)
                  for c in range(4)]
        elif opc in (134, 135, 137, 138, 139):  # int div/rem/mod
            sg = opc in (135, 138, 139)
            md = opc not in (134, 135)
            sm = opc == 139
            wb = [self.idiv(va[0][c], va[1][c], sg, md, sm)
                  for c in range(4)]
        else:
            raise self.FaultX(opc)
        self.setres(rid, wb, ncomp)
        return pc + wc

    INTOPS = frozenset((126, 127, 128, 130, 132, 164, 165, 166, 167,
                        168, 169, 170, 171, 172, 173, 174, 175, 176,
                        177, 178, 179, 194, 195, 196, 197, 198, 199,
                        200))
    HAS_RTY = frozenset((12, 61, 65, 66, 68, 79, 80, 81, 82, 109, 110,
                         111, 112, 124, 126, 127, 128, 129, 130, 131,
                         132, 133, 134, 135, 136, 137, 138, 139, 142,
                         148, 164, 165, 166, 167, 168, 169, 170, 171,
                         172, 173, 174, 175, 176, 177, 178, 179, 180,
                         181, 182, 183, 184, 185, 186, 187, 188, 189,
                         190, 191, 194, 195, 196, 197, 198, 199, 200))

    @staticmethod
    def nva(opc, wc):
        """f_nva() — operand count per opcode."""
        if opc == 62:
            return 2
        if opc == 80:
            return min(4, wc - 3)
        if opc == 169:
            return 3
        if opc == 82:
            return 2
        if opc == 12:
            return 3 if wc > 8 else (wc - 5 if wc > 5 else 0)
        if opc in (61, 65, 66, 68, 81, 109, 110, 111, 112, 124, 126,
                   127, 146, 168, 200):
            return 1
        if opc in (54, 56, 248, 249, 253):
            return 0
        return 2

    def classof(self, tid):
        """Gate-2 word class: 'f' iff the stored value is float-typed."""
        t = self.sc.types.get(tid, {})
        k = t.get('kind')
        if k == TK['FLOAT']:
            return 'f'
        if k == TK['VEC']:
            e = self.sc.types.get(t['elem'], {})
            return 'f' if e.get('kind') == TK['FLOAT'] else 'i'
        return 'i'

    def intop(self, opc, va, vt):
        """combinational integer/bool ALU (the W_EX int_alu block)."""
        a, b = va[0], va[1]
        out = [0, 0, 0, 0]
        for c in range(4):
            x, y = a[c], b[c]
            if opc == 126:
                out[c] = u32(-x)
            elif opc == 127:
                out[c] = (x ^ 0x80000000) & 0xFFFFFFFF
            elif opc == 128:
                out[c] = u32(x + y)
            elif opc == 130:
                out[c] = u32(x - y)
            elif opc == 132:
                out[c] = u32(x * y)
            elif opc == 194:
                out[c] = x >> (y & 31)
            elif opc == 195:
                out[c] = u32(s32(x) >> (y & 31))
            elif opc == 196:
                out[c] = u32(x << (y & 31))
            elif opc == 197:
                out[c] = x | y
            elif opc == 198:
                out[c] = x ^ y
            elif opc == 199:
                out[c] = x & y
            elif opc == 200:
                out[c] = u32(~x)
            elif opc == 170:
                out[c] = int(x == y)
            elif opc == 171:
                out[c] = int(x != y)
            elif opc == 172:
                out[c] = int(x > y)
            elif opc == 173:
                out[c] = int(s32(x) > s32(y))
            elif opc == 174:
                out[c] = int(x >= y)
            elif opc == 175:
                out[c] = int(s32(x) >= s32(y))
            elif opc == 176:
                out[c] = int(x < y)
            elif opc == 177:
                out[c] = int(s32(x) < s32(y))
            elif opc == 178:
                out[c] = int(x <= y)
            elif opc == 179:
                out[c] = int(s32(x) <= s32(y))
            elif opc == 164:
                out[c] = int(bool(x) == bool(y))
            elif opc == 165:
                out[c] = int(bool(x) != bool(y))
            elif opc == 166:
                out[c] = int(bool(x) or bool(y))
            elif opc == 167:
                out[c] = int(bool(x) and bool(y))
            elif opc == 168:
                out[c] = int(not x)
            elif opc == 169:                  # Select
                cc = c if self.ncomps(vt[0]) > 1 else 0
                out[c] = va[1][c] if a[cc] else va[2][c]
        return out

    # -- dispatch --------------------------------------------------------
    def run_inv(self):
        """one invocation (wave/lane already set by the caller)."""
        # RF init from the scanner's init table — identical per lane
        self.rf = [[0, 0, 0, 0] for _ in range(self.sc.n_regs)]
        for (idx, sc, bi, st, bd, off) in self.sc.init:
            tag = (bd << 20) | (st << 12) | (bi << 4) | sc
            self.rf[idx] = [off, tag, 0, 0]
        self.scratch = [0] * self.sc_w
        pc = self.sc.entry_off
        steps = 0
        while True:
            self.cur_pc = pc
            npc = self.exec_one(pc)
            steps += 1
            if npc == 'ret' or steps > (1 << 22):
                return
            pc = npc

    def run(self):
        """whole dispatch: workgroups x-fastest (W_EOW order), waves of
        LAN lanes, lanes in order (lane 0 first so its chain-index
        values are recorded before other lanes need them — matching
        the RTL's uniform `vix_q[0]` struct-member-index read)."""
        ninv = self.lx * self.ly * self.lz
        nwaves = (ninv + LAN - 1) // LAN
        for wgz in range(self.gz):
            for wgy in range(self.gy):
                for wgx in range(self.gx):
                    self.wg = (wgx, wgy, wgz)
                    self.slab = [0] * self.slb_w
                    for wv in range(nwaves):
                        self.wave = wv
                        self.l0_idx = {}
                        for l in range(min(LAN, ninv - wv * LAN)):
                            self.lane = l
                            self.inv = wv * LAN + l
                            self.run_inv()
        return self.mem

    # output collection -------------------------------------------------
    def outputs(self):
        """{(bind_idx): [words]} for bindings that received stores."""
        out = {}
        for i, (st, bd, sz, ad) in enumerate(self.binds):
            if any((ad >> 2) + k in self.wclass for k in range(sz // 4)):
                out[i] = [self.mem.get((ad >> 2) + k, 0)
                          for k in range(sz // 4)]
        return out

    def out_classes(self):
        out = {}
        for i, (st, bd, sz, ad) in enumerate(self.binds):
            if any((ad >> 2) + k in self.wclass for k in range(sz // 4)):
                out[i] = [self.wclass.get((ad >> 2) + k, 'i')
                          for k in range(sz // 4)]
        return out


def load_hex(path):
    return [int(l.strip(), 16) for l in open(path)
            if l.strip() and not l.startswith('//')]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    words = load_hex(sys.argv[1])
    m = Model(words)
    m.run()
    outs = m.outputs()
    cls = m.out_classes()
    res = {'robust': m.robust, 'bindings': []}
    for i in sorted(outs):
        res['bindings'].append(
            {'index': i, 'words': ['%08x' % w for w in outs[i]],
             'class': cls[i]})
    if len(sys.argv) > 2:
        open(sys.argv[2], 'w').write(json.dumps(res, indent=1))
    else:
        print(json.dumps(res, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
