#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""spirv_model.py — bit-exact reference interpreter for the G6LC
ShaderCore increment-4b subset (architecture doc §7a/§7c — 4a
straight-line subset plus structured control flow, workgroup barriers
and matrix ops).

4b control-flow semantics are INDEPENDENT-LANE, not lockstep: each
invocation runs its own pc straight through branches (prev_blk
records the block it came from for OpPhi) until it reaches an
OpControlBarrier or terminates; a workgroup runs in phases separated
by barriers, with Workgroup (slab) memory the only shared state.
Gate 1 (bit-exact RTL == this model) is then the proof that the
RTL's wave reconvergence stack reproduces independent-lane results.

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
import srgb_lut    # noqa: E402  generated — mirrors g6lc_apu_srgb_pkg
import sfu_tables  # noqa: E402  generated — mirrors g6lc_apu_sfu_pkg
import img_fmts    # noqa: E402  generated — mirrors APU_VN_IMG_*

SC = spirv_scan.SC
TK = spirv_scan.TK

# DUT default geometry (g6lc_apu_shwave parameters)
SCRATCH_WORDS = 256        # ScratchBytes=1024 / 4
SLAB_WORDS = 4096          # SlabBytes=16384 / 4
LAN = 8                    # ShaderLanes
CALLDEPTH = 8              # g6lc_apu_shwave CallDepth (call stack)

# storage-class / builtin ids (must match g6lc_apu_sh_pkg)
SC_INPUT = SC['INPUT']
SC_UNIFORM = SC['UNIFORM']
SC_SBUF = SC['SBUF']
SC_WORKGROUP = SC['WORKGROUP']
SC_PRIVATE = SC['PRIVATE']
SC_FUNCTION = SC['FUNCTION']
SC_PUSHCONST = SC['PUSHCONST']
SC_UCONST = SC['UNIFORMCONST']

BI_NUMWG = 24
BI_WGSIZE = 25
BI_WGID = 26
BI_LID = 27
BI_GID = 28
BI_LINDEX = 29
BI_FRONTFACING = 17
BI_HELPER = 23
BI_VERTEXINDEX = 42
BI_INSTANCEINDEX = 43

# graphics record layout (mirrors g6lc_apu_sh_pkg)
SC_OUTPUT = SC['OUTPUT']
VARY_LOCS = 8
# VS-in records carry a ninth slot (8) = {VertexIndex, InstanceIndex,
# 0, 0}; FS-out records share the stride
ATTR_STRIDE = 16 * (1 + VARY_LOCS)
VARY_STRIDE = 16 * (1 + VARY_LOCS)
VF_REC = 0x1
VF_DROP = 0x2
# graphics stage codes mirror APU_SH_GFX_* (0 = compute dispatch) —
# the SPIR-V execution model (0=Vertex) cannot double as the "is gfx"
# flag, so the .hex stage word is remapped
GFX_NONE = 0
GFX_VS = 1
GFX_FS = 2
EM2GFX = {spirv_scan.EM['VERTEX']: GFX_VS,
          spirv_scan.EM['FRAGMENT']: GFX_FS}

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
# §12.3 C/5b image helpers — every one mirrors a g6lc_apu_shwave
# function (f_*) bit-exactly
# ---------------------------------------------------------------------

# descriptor-kind legality per opcode (f_tx_kind): 0 SAMPLER,
# 1 COMBINED_IMAGE_SAMPLER, 2 SAMPLED_IMAGE, 3 STORAGE_IMAGE
IMG_KIND_OK = {95: (1, 2), 87: (1, 2), 88: (1, 2), 98: (2, 3),
               89: (1, 2), 90: (1, 2), 91: (1, 2), 92: (1, 2),
               93: (1, 2), 94: (1, 2), 96: (1, 2), 97: (1, 2),
               105: (1, 2),
               99: (3,),
               103: (0, 1, 2, 3), 104: (0, 1, 2, 3), 106: (0, 1, 2, 3)}


def f16_f32(h):
    """f_f16_f32 — exact fp16 -> fp32 widening."""
    e = (h >> 10) & 0x1F
    m = h & 0x3FF
    s = (h & 0x8000) << 16
    if e == 0x1F:
        return s | 0x7F800000 | (m << 13)
    if e == 0:
        if m == 0:
            return s
        sh = 0
        for i in range(9, -1, -1):
            if m & (1 << i):
                sh = 9 - i
                break
        ae = 113 - sh
        return s | (ae << 23) | (((m << (sh + 1)) & 0x3FF) << 13)
    return s | ((e + 112) << 23) | (m << 13)


def f32_f16(f):
    """f_f32_f16 — fp32 -> fp16 RNE; overflow -> inf; nan/inf kept."""
    fe = (f >> 23) & 0xFF
    s = (f >> 16) & 0x8000
    if fe == 0xFF:
        return s | 0x7C00 | (0x200 if f & 0x7FFFFF else 0)
    if fe == 0:
        return s
    if fe >= 143:
        return s | 0x7C00
    if fe >= 113:
        rn = s | ((fe - 112) << 10) | ((f >> 13) & 0x3FF)
        up = (f >> 12) & 1 and ((f & 0xFFF) != 0 or (f >> 13) & 1)
        return (rn + 1) & 0xFFFF if up else rn
    sh = 126 - fe
    if sh > 30:
        return s
    fmn = (1 << 23) | (f & 0x7FFFFF)
    r = fmn >> sh
    rem = fmn & ((1 << sh) - 1)
    if rem > (1 << (sh - 1)) or (rem == (1 << (sh - 1)) and r & 1):
        r += 1
    return s | (r & 0x7FFF)


def ldexp(w, e):
    """Ldexp — x * 2**e by exponent-field arithmetic (bit-exact,
    denormal-aware; mirrors the W_EX ldexp comb block)."""
    s = w & 0x80000000
    ex = (w >> 23) & 0xFF
    m = w & 0x7FFFFF
    if ex == 0xFF or (ex == 0 and m == 0):
        return w                              # inf/nan/zero pass
    if ex == 0:                               # denormal: normalize
        clz = 23 - m.bit_length()
        m = (m << (clz + 1)) & 0x7FFFFF
        ex = 1 - clz
    ne = ex + s32(e)
    if ne >= 255:
        return s | 0x7F800000
    if ne <= 0:                               # underflow: denormal RNE
        fmn = 0x800000 | m
        sh = 1 - ne
        if sh >= 25:
            return s
        r = fmn >> sh
        rem = fmn & ((1 << sh) - 1)
        if rem > (1 << (sh - 1)) or \
                (rem == (1 << (sh - 1)) and r & 1):
            r += 1
        # r <= 0x800000: carry folds into the exp field = min normal
        return s | r
    return s | (ne << 23) | m


def twrap(i, n, m):
    """f_twrap — returns (border, coord).  REPEAT=0 MIRRORED=1
    CLAMP_TO_EDGE=2 CLAMP_TO_BORDER=3."""
    if m == 0:
        return (0, i % n)
    if m == 1:
        mm = i if i >= 0 else -i - 1
        r = mm % (2 * n)
        if r >= n:
            r = 2 * n - 1 - r
        return (0, r)
    if m == 2:
        return (0, 0 if i < 0 else (n - 1 if i >= n else i))
    if i < 0 or i >= n:
        return (1, 0)
    return (0, i)


def bord16(b, c):
    if b in (4, 5):
        return 0xFFFF
    if b in (2, 3):
        return 0xFFFF if c == 3 else 0
    return 0


def bord32(b, c):
    if b in (4, 5):
        return 0x3F800000
    if b in (2, 3):
        return 0x3F800000 if c == 3 else 0
    return 0


def bord_int(b, c):
    if b >= 4:
        return 1
    return 1 if (b == 3 and c == 3) else 0


def f01(f):
    """f_f01 — clamp fp32 bits to [0,1]; NaN -> 0."""
    if (f >> 31) & 1 or isnan(f):
        return 0
    return 0x3F800000 if ((f >> 23) & 0xFF) >= 127 else f


def f_dcmp(r, t, op):
    """f_dcmp — integer u16 compare (VkCompareOp order) for D16 PCF."""
    return (False, r < t, r == t, r <= t,
            r > t, r != t, r >= t, True)[op & 7]


def f_fcmp32(r, t, op):
    """f_fcmp32 — fp32 compare (VkCompareOp order) for D32 PCF;
    unordered (NaN) only satisfies NEQUAL/ALWAYS."""
    unr = isnan(r) or isnan(t)
    eq = (not unr) and \
        (r == t or ((r & 0x7FFFFFFF) == 0 and (t & 0x7FFFFFFF) == 0))
    lt = (not unr) and (not eq) and \
        (bool(r >> 31) if (r >> 31) != (t >> 31)
         else ((r & 0x7FFFFFFF) < (t & 0x7FFFFFFF)) ^ bool(r >> 31))
    return (False, lt, eq, lt or eq,
            (not unr) and (not lt) and (not eq),
            not eq, (not unr) and (not lt), True)[op & 7]


def swz_sel(s, c):
    """f_swz — VkComponentSwizzle: 0 identity, 1 zero, 2 one, 3..6 RGBA."""
    w = (s >> (3 * c)) & 7
    return (3 + c) if w == 0 else w


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
        # §12.1 F5: bind entries carry aux = {kind[23:16], dyn[8],
        # elem_idx[7:0]} — elem_idx is the record's index inside its
        # (set,binding) row so descriptor arrays share one row.
        # §12.3 C/5b: aux bit24 marks image/sampler binds — 5 meta
        # words follow carrying the record's bytes 10..27:
        #   {h[31:16],w[15:0]}, {layers[31:16],mdim[15:8],fmt[7:0]},
        #   swizzle[11:0], smpw0, smpw1
        self.binds = []                        # (set,bd,size,addr,aux[,meta])
        for _ in range(self.nb):
            e = tuple(words[p:p + 5])
            p += 5
            if e[4] & (1 << 24):
                e += tuple(words[p:p + 5])
                p += 5
            self.binds.append(e)
        self.push = words[p:p + self.np]
        p += self.np
        # dynamic-offset section: n entries {set, ord, off} -> dyn[s][o]
        self.dyn = [[0] * 16 for _ in range(4)]
        nd = words[p]
        p += 1
        for _ in range(nd):
            s, o, v = words[p], words[p + 1], words[p + 2]
            p += 3
            if s < 4 and o < 16:
                self.dyn[s][o] = v
        self.mem = {}                          # word addr -> u32
        for b in self.binds:
            st, bd, sz, ad = b[0], b[1], b[2], b[3]
            for i in range(sz // 4):
                self.mem[(ad >> 2) + i] = words[p + i]
            p += sz // 4
        # G1a graphics wave work (flags bit2): {stage, count, in_base,
        # out_base, vbase, inst, n_in} + the input-record image; the
        # stage word is a SPIR-V execution model, remapped to the
        # APU_SH_GFX_* code (0=Vertex cannot be a truthy flag)
        self.gfx = GFX_NONE
        self.gcnt = self.vbase = self.inst = 0
        self.in_base = self.out_base = 0
        self.ghelp = 0            # G3a-i: per-record helper-lane mask
        if self.flags & 4:
            (stage, self.gcnt, self.in_base, self.out_base,
             self.vbase, self.inst, nin) = words[p:p + 7]
            self.gfx = EM2GFX.get(stage, GFX_NONE)
            p += 7
            for i in range(nin):
                self.mem[(self.in_base >> 2) + i] = words[p + i]
            p += nin
            # {help_lo, help_hi} — helper bits per record index
            self.ghelp = words[p] | (words[p + 1] << 32)
            p += 2
        # memory-resident descriptor model: binding rows (per-set
        # element cursor in 32B record units) + the records themselves.
        self.drows = {}                        # (set,bd) -> row dict
        self.drecs = {}                        # (set,off32) -> record
        ecnt = [0] * 4
        dord = [0] * 4
        for b in self.binds:
            st, bd, sz, ad, ax = b[:5]
            meta = None
            if ax & (1 << 24):
                hw, mlf, swz, s0, s1 = b[5:10]
                meta = dict(w=hw & 0xFFFF, h=(hw >> 16) & 0xFFFF,
                            fmt=mlf & 0xFF, mdim=(mlf >> 8) & 0xFF,
                            layers=(mlf >> 16) & 0xFFFF,
                            swz=swz & 0xFFF, smp0=s0, smp1=s1)
            idx = ax & 0xFF
            dyn = (ax >> 8) & 1
            kind = ((ax >> 16) & 0xFF) or 7
            key = (st, bd)
            row = self.drows.get(key)
            if row is None:
                row = dict(count=0, off32=ecnt[st], dyn=dyn,
                           dynbase=dord[st])
                self.drows[key] = row
            row['count'] = max(row['count'], idx + 1)
            if dyn:
                dord[st] = max(dord[st], row['dynbase'] + idx + 1)
            ecnt[st] = max(ecnt[st], row['off32'] + row['count'])
            self.drecs[(st, row['off32'] + idx)] = \
                (ad, sz, kind, 1, meta)        # (base,size,kind,fl,meta)
        # ---- scan the module (spirv_scan golden tables) ----
        self.sc = spirv_scan.Scanner(self.spv)
        self.sc.scan()
        self.lx, self.ly, self.lz = self.sc.localsize
        # G3a-i: FS late-Z arm — the slot-8 tail write only runs for
        # modules with kills/demotes or a FragDepth output (mirrors
        # shmod's entry word3 bit and shwave's fslate gate)
        self.fs_late = bool(self.sc.has_kill or self.sc.wr_fdepth)
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
        self.cur_lbl = 0          # label id of the current block
        self.prev_lbl = 0         # label id this block was entered from
        self.l0_idx = {}          # (pc, id) -> lane-0 chain index value
        self.dvals = {}           # (pc, id) -> {inv: operand value} G2b
        self.nswitch = 0          # barrier/wave interleave counter (info)

    # -- memory --------------------------------------------------------
    def mread(self, byte_addr):
        return self.mem.get(byte_addr >> 2, 0)

    def mwrite(self, byte_addr, val, cls):
        self.mem[byte_addr >> 2] = val & 0xFFFFFFFF
        self.wclass[byte_addr >> 2] = cls

    def desc_rec(self, st, bd, idx):
        """§12.1 F5 resolve: (set,binding,idx) -> (base,size,ok) or
        None when no such binding row / idx >= count (RTL null desc).
        ok folds record valid + supported kind; dynamic kinds add the
        bound dynamic offset to the record base."""
        row = self.drows.get((st, bd))
        if row is None or idx >= row['count']:
            return None
        rec = self.drecs.get((st, row['off32'] + idx))
        if rec is None:
            return (0, 0, False)
        base, size, kind, flags = rec[:4]
        ok = bool(flags & 1) and kind in (6, 7, 8, 9)
        if row['dyn']:
            base = u32(base + self.dyn[st]
                       [min(row['dynbase'] + idx, 15)])
        return (base, size, ok)

    # -- §12.3 C/5b image path (W_TX* mirror) --------------------------
    def img_rec(self, ptr):
        """image/sampler pointer -> record (base,size,kind,flags,meta)
        or None when no row/index exists (RTL null record)."""
        st = (ptr[1] >> 12) & 0xFF
        bd = (ptr[1] >> 20) & 0xFF
        idx = ptr[2] & 0xFFFF
        row = self.drows.get((st, bd))
        if row is None or idx >= row['count']:
            return None
        return self.drecs.get((st, row['off32'] + idx))

    def bread8(self, a):
        return (self.mread(a) >> (8 * (a & 3))) & 0xFF

    def bread32(self, a):
        return (self.bread8(a) | (self.bread8(a + 1) << 8) |
                (self.bread8(a + 2) << 16) | (self.bread8(a + 3) << 24))

    def bwrite8(self, a, v, cls):
        w = self.mread(a)
        sh = 8 * (a & 3)
        self.mem[a >> 2] = (w & ~(0xFF << sh)) | ((v & 0xFF) << sh)
        self.wclass[a >> 2] = cls

    def img_walk(self, meta, m0, m1=-1):
        """W_TXM — {level: (mof,pit,w,h)} for m0/m1 + layer_bytes."""
        bpp = img_fmts.BPP[meta['fmt'] & 15]
        wm, hm, macc = meta['w'], meta['h'], 0
        out = {}
        for m in range(meta['mdim'] & 0xF):
            wd, hd = (wm if wm else 1), (hm if hm else 1)
            pit = (wd * bpp + 63) & ~63
            if m == m0:
                out[m0] = (macc, pit, wd, hd)
            if m == m1:
                out[m1] = (macc, pit, wd, hd)
            macc += pit * hd
            wm, hm = wd >> 1, hd >> 1
        return out, macc

    def tx_decode(self, meta, bcol, brd, by):
        """W_TXD — by = texel byte list -> (ch16[4], fc32[4])."""
        attr = img_fmts.ATTR[meta['fmt'] & 15]
        bgr = (attr >> 6) & 1
        ch = [0, 0, 0, 0]
        fc = [0, 0, 0, 0]
        if brd:
            if (attr >> 3) & 1:                   # int: integer border
                fc = [bord_int(bcol, c) for c in range(4)]
            else:
                fc = [bord32(bcol, c) for c in range(4)]
            ch = [bord16(bcol, c) for c in range(4)]
            return ch, fc
        fmt = meta['fmt']
        if fmt == 0:                              # R8_UNORM
            ch[0] = by[0] * 0x101
            ch[3] = 0xFFFF
        elif fmt == 1:                            # R8G8_UNORM
            ch[0] = by[0] * 0x101
            ch[1] = by[1] * 0x101
            ch[3] = 0xFFFF
        elif fmt in (2, 4):                       # [B]RGBA8_UNORM
            ch[2 if bgr else 0] = by[0] * 0x101
            ch[1] = by[1] * 0x101
            ch[0 if bgr else 2] = by[2] * 0x101
            ch[3] = by[3] * 0x101
        elif fmt in (3, 5):                       # [B]RGBA8_SRGB
            ch[2 if bgr else 0] = srgb_lut.TO_LIN16[by[0]]
            ch[1] = srgb_lut.TO_LIN16[by[1]]
            ch[0 if bgr else 2] = srgb_lut.TO_LIN16[by[2]]
            ch[3] = by[3] * 0x101                 # alpha is linear
        elif fmt == 6:                            # RGBA16_SFLOAT
            fc = [f16_f32(by[2 * c] | (by[2 * c + 1] << 8))
                  for c in range(4)]
        elif fmt == 7:                            # R32_SFLOAT
            fc[0] = by[0] | by[1] << 8 | by[2] << 16 | by[3] << 24
            fc[3] = 0x3F800000
        elif fmt == 8:                            # R32G32_SFLOAT
            fc[0] = by[0] | by[1] << 8 | by[2] << 16 | by[3] << 24
            fc[1] = by[4] | by[5] << 8 | by[6] << 16 | by[7] << 24
            fc[3] = 0x3F800000
        elif fmt == 9:                            # R32G32B32A32_SFLOAT
            fc = [(by[4 * c] | by[4 * c + 1] << 8 |
                   by[4 * c + 2] << 16 | by[4 * c + 3] << 24)
                  for c in range(4)]
        elif fmt == 10:                           # R32_UINT
            fc[0] = by[0] | by[1] << 8 | by[2] << 16 | by[3] << 24
            fc[3] = 1
        else:                                     # R32G32B32A32_UINT
            fc = [(by[4 * c] | by[4 * c + 1] << 8 |
                   by[4 * c + 2] << 16 | by[4 * c + 3] << 24)
                  for c in range(4)]
        return ch, fc

    def helper(self):
        """helper-invocation bit for the current lane (dispatch ghelp
        mask): the lane executes fully — it feeds quad derivatives —
        but its device-visible side effects (atomics, image writes,
        UNIFORM/SBUF/WORKGROUP stores) are suppressed, exactly like a
        demoted lane; private/function/out-record state still updates."""
        return (self.ghelp >> self.inv) & 1

    def img_op(self, pc, opc, wc, ops, va, rty, rid, ncomp):
        """the whole W_TX* sequence for one invocation; returns the
        next pc or 'ret' (on a device-lost fault)."""
        nxt = pc + wc
        if opc == 99 and (self.dead or self.helper()):
            return nxt                     # dead/helper: no image store
        # W_TXJ0/J1: projected forms divide coord.xy by the last
        # component wave-wide, before operand legality — the divided
        # value is what the derivative lanes see too
        if opc in (91, 92, 93, 94):
            nc = self.ncomps(self.regt(ops[3]))
            q = va[1][(nc - 1) & 3]
            va[1] = [fdiv(va[1][0], q), fdiv(va[1][1], q),
                     va[1][2], va[1][3]]
        # W_TX0 operand-mask legality (only Lod 0x2 is decoded); 87
        # takes no image operands in v1 (Bias rides the sampler record)
        if (opc == 95 and wc > 6 and (ops[4] & ~0x2) != 0) or \
           (opc == 87 and wc > 5 and ops[4] != 0) or \
           (opc == 88 and (wc < 7 or (ops[4] & ~0x2) != 0 or
                           not (ops[4] & 0x2))) or \
           (opc == 98 and wc > 5 and ops[4] != 0) or \
           (opc == 99 and wc > 4 and ops[3] != 0) or \
           (opc in (89, 93) and wc > 6 and ops[5] != 0) or \
           (opc == 91 and wc > 5 and ops[4] != 0) or \
           (opc in (90, 94) and (wc < 8 or (ops[5] & ~0xA) != 0 or
                                 not (ops[5] & 0x2))) or \
           (opc == 92 and (wc < 7 or (ops[4] & ~0xA) != 0 or
                           not (ops[4] & 0x2))) or \
           (opc in (96, 97) and wc > 6 and (ops[5] & ~0xA) != 0) or \
           (opc == 105 and wc > 5 and ops[4] != 0):
            self.fault = 'IMGOPMASK'
            return 'ret'
        rec = self.img_rec(va[0])
        valid = bool(rec and (rec[3] & 1))
        kind = rec[2] if rec else 0
        meta = rec[4] if rec else None
        # W_TX2 kind legality — mismatch is a truthful device-lost
        if valid and kind not in IMG_KIND_OK[opc]:
            self.fault = 'IMGKIND'
            return 'ret'
        smp = 0
        if opc in (87, 88, 89, 90, 91, 92, 93, 94, 96, 97, 105) and \
           valid:
            if va[0][1] & 0x80000000:
                # merged OpSampledImage: fetch the SAMPLER record
                sk = va[0][0]
                st, bd, idx = ((sk >> 16) & 0xFF, (sk >> 24) & 0xFF,
                               sk & 0xFFFF)
                srow = self.drows.get((st, bd))
                srec = None if srow is None else \
                    self.drecs.get((st, srow['off32'] + idx))
                if srec is None or not (srec[3] & 1) or srec[2] != 0:
                    self.fault = 'IMGKIND'
                    return 'ret'
                smeta = srec[4]
                smp = (smeta['smp0'] | smeta['smp1'] << 32) \
                    if smeta else 0
            elif kind != 1:
                self.fault = 'IMGKIND'    # SAMPLED_IMAGE w/o sampler
                return 'ret'
            else:
                smp = meta['smp0'] | (meta['smp1'] << 32)
        elif meta:
            smp = meta['smp0'] | (meta['smp1'] << 32)
        wb = [0, 0, 0, 0]
        if not valid or meta is None:
            # invalid record -> robust zero / dropped store (W_TXR0)
            self.robust += 1
            if opc != 99:
                self.setres(rid, wb, ncomp)
            return nxt
        fmt = meta['fmt'] & 15
        attr = img_fmts.ATTR[fmt]
        bpp = img_fmts.BPP[fmt]
        nch = (attr & 7) + 1
        isflt = ((attr >> 4) | (attr >> 5)) & 1
        isf16 = (attr >> 5) & 1
        isint = (attr >> 3) & 1
        issr = (attr >> 7) & 1
        lvl = meta['mdim'] & 0xF
        dim = (meta['mdim'] >> 4) & 3
        layers = meta['layers']
        swz = meta['swz']
        bcol = (smp >> 14) & 7
        base = rec[0]
        size = rec[1]
        # ---- query ops (W_TXQ) --------------------------------------
        if opc == 106:                            # QueryLevels
            wb[0] = lvl
            self.setres(rid, wb, ncomp)
            return nxt
        if opc == 104:                            # QuerySize
            wb[0], wb[1] = meta['w'], meta['h']
            if dim == 1:
                wb[2] = layers
            self.setres(rid, wb, ncomp)
            return nxt
        if opc == 103:                            # QuerySizeLod
            lod = va[1][0] & 0x1F
            mt = lod if lod < lvl else lvl - 1
            wk, _lb = self.img_walk(meta, mt)
            wb[0], wb[1] = wk[mt][2], wk[mt][3]
            if dim == 1:
                wb[2] = layers
            self.setres(rid, wb, ncomp)
            return nxt
        # ---- int-coordinate ops (95 fetch / 98 read / 99 write) ------
        if opc in (95, 98, 99):
            lod = (va[2][0] & 0x1F) if (opc == 95 and wc > 6) else 0
            if lod >= lvl:
                self.robust += 1
                if opc != 99:
                    self.setres(rid, wb, ncomp)
                return nxt
            iu, iv = s32(va[1][0]), s32(va[1][1])
            ly = (va[1][2] & 0xFFFF) if dim == 1 else 0
            wk, layb = self.img_walk(meta, lod)
            mof, pit, w0, h0 = wk[lod]
            # W_TXB bounds
            if (ly >= layers or iu < 0 or iv < 0 or
                    iu >= w0 or iv >= h0):
                self.robust += 1
                if opc != 99:
                    self.setres(rid, wb, ncomp)
                return nxt
            ta = base + ly * layb + mof + iv * pit + iu * bpp
            if opc == 99:
                self.tx_store(va[2], fmt, attr, bpp, nch,
                              isint, isflt, isf16, issr, ta)
                return nxt
            # fetch/read: one gather point, weight 65536, fw = 0
            pts = [(iu, iv, 65536, 0, False)]
            return self.tx_finish(pts, ta, meta, rec, bcol,
                                  isint, isflt, issr, swz,
                                  rid, ncomp, wb, nxt, lvl)
        # ---- sampled/dref/proj/gather/query-lod (87-94,96,97,105) ----
        addrU = (smp >> 5) & 7
        addrV = (smp >> 8) & 7
        lin0 = ((smp >> 2) & 3) != 0              # min filter
        mag0 = (smp & 3) != 0                     # mag filter
        min44 = (smp >> 32) & 0xFF
        max44 = (smp >> 40) & 0xFF
        bias = (smp >> 48) & 0xFF
        cen = (smp >> 20) & 1                     # compareEnable
        cmo = (smp >> 17) & 7                     # compareOp
        gath = opc in (96, 97)
        dref = opc in (89, 90, 93, 94, 97)
        lodbit = gath and wc > 6 and (ops[5] & 0x2)
        # λ: implicit forms (and operand-less gathers) derive it from
        # the quad derivatives; explicit forms read their lod operand —
        # slot 2 for 88/92, slot 3 for 90/94/96/97
        implicit = opc in (87, 89, 91, 93, 105) or (gath and not lodbit)
        if implicit:
            lod_in = self.ilod_v(pc, ops[3], va[1], meta['w'], meta['h'])
        else:
            lod_in = va[2][0] if opc in (88, 92) else va[3][0]
        # G3a-ii dref: the compare ref is quantized to u16 once for
        # UNORM depth (D16); D32_SFLOAT compares in fp directly
        ref16 = 0
        if dref:
            ref16 = s32(f2i(fmul(f01(va[2][0]), 0x477FFF00),
                            False, 'RNE')) & 0xFFFF
        # lod q4.4 is floored, not RNE — W_TXC2's own +0.5 round is the
        # mip-nearest decision, so a second RNE here double-rounds and
        # tips boundary lods one mip early (vkcmp tex_mip_nearest).
        le = s32(f2i(ffma(lod_in, 0x41800000, 0), False, 'RDN'))
        le += -bias if (smp >> 56) & 1 else bias
        le = min(max(le, min44), max44)
        le = max(le, 0)
        if opc == 105:                            # QueryLod
            # {λ clamped also to the mip range, λ unclamped}
            lec = min(le, (lvl - 1) * 16)
            wb[0] = fmul(i2f(lec, True), 0x3D800000)   # lec * 2^-4
            wb[1] = lod_in
            self.setres(rid, wb, ncomp)
            return nxt
        lin = True if gath else (lin0 if le > 0 else mag0)
        if gath:                                  # gather: mip floor
            m0 = m1 = le >> 4
            fw = 0
        elif (smp >> 4) & 1:                      # mipmap LINEAR
            m0, m1 = le >> 4, (le >> 4) + 1
            fw = (le & 0xF) << 4
        else:
            m0 = m1 = (le + 8) >> 4
            fw = 0
        m0 = min(m0, lvl - 1)
        m1 = min(m1, lvl - 1)
        tril = m1 != m0
        ly = (s32(f2i(va[1][2], False, 'RNE')) & 0xFFFF) if dim == 1 \
            else 0
        wk, layb = self.img_walk(meta, m0, m1 if tril else -1)
        mof0, pit0, w0, h0 = wk[m0]
        mof1 = pit1 = w1 = h1 = 0
        if tril:
            mof1, pit1, w1, h1 = wk[m1]
        # coords: linear -> 8.8 (u*w<<8 - 128), nearest -> pixels
        sc8 = 8 if lin else 0
        cst = 0xC3000000 if lin else 0
        su0 = s32(f2i(ffma(va[1][0], i2f(w0 << sc8, True), cst),
                      False, 'RDN'))
        sv0 = s32(f2i(ffma(va[1][1], i2f(h0 << sc8, True), cst),
                      False, 'RDN'))
        su1 = sv1 = 0
        if tril:
            su1 = s32(f2i(ffma(va[1][0], i2f(w1 << sc8, True), cst),
                          False, 'RDN'))
            sv1 = s32(f2i(ffma(va[1][1], i2f(h1 << sc8, True), cst),
                          False, 'RDN'))
        # ConstOffset (gathers): integer texel shift in the s8.8
        # domain, applied before the address-mode wrap
        if gath and wc > 6 and (ops[5] & 0x8):
            osl = 4 if lodbit else 3
            su0 = s32(su0 + (s32(va[osl][0]) << 8))
            sv0 = s32(sv0 + (s32(va[osl][1]) << 8))
        # gather list: (u, v, weight, mip, border)
        pts = []
        if gath:
            # SPIR-V result order (i0,j1),(i1,j1),(i1,j0),(i0,j0) —
            # the linear corner texels of mip m0, unfiltered
            iu0, iv0 = su0 >> 8, sv0 >> 8
            cu0, u0 = twrap(iu0, w0, addrU)
            cu1, u1 = twrap(iu0 + 1, w0, addrU)
            cv0, v0 = twrap(iv0, h0, addrV)
            cv1, v1 = twrap(iv0 + 1, h0, addrV)
            pts = [(u0, v1, 65536, 0, bool(cu0 or cv1)),
                   (u1, v1, 65536, 0, bool(cu1 or cv1)),
                   (u1, v0, 65536, 0, bool(cu1 or cv0)),
                   (u0, v0, 65536, 0, bool(cu0 or cv0))]
        elif lin:
            fu0, fv0 = su0 & 0xFF, sv0 & 0xFF
            iu0, iv0 = su0 >> 8, sv0 >> 8
            for (du, dv, wu, wv, mi) in (
                    (iu0, iv0, 256 - fu0, 256 - fv0, 0),
                    (iu0 + 1, iv0, fu0, 256 - fv0, 0),
                    (iu0, iv0 + 1, 256 - fu0, fv0, 0),
                    (iu0 + 1, iv0 + 1, fu0, fv0, 0)):
                bu, cu = twrap(du, w0, addrU)
                bv, cv = twrap(dv, h0, addrV)
                pts.append((cu, cv, wu * wv, 0, bool(bu or bv)))
            if tril:
                fu1, fv1 = su1 & 0xFF, sv1 & 0xFF
                iu1, iv1 = su1 >> 8, sv1 >> 8
                for (du, dv, wu, wv, mi) in (
                        (iu1, iv1, 256 - fu1, 256 - fv1, 1),
                        (iu1 + 1, iv1, fu1, 256 - fv1, 1),
                        (iu1, iv1 + 1, 256 - fu1, fv1, 1),
                        (iu1 + 1, iv1 + 1, fu1, fv1, 1)):
                    bu, cu = twrap(du, w1, addrU)
                    bv, cv = twrap(dv, h1, addrV)
                    pts.append((cu, cv, wu * wv, 1, bool(bu or bv)))
        else:
            bu, cu = twrap(su0, w0, addrU)
            bv, cv = twrap(sv0, h0, addrV)
            pts.append((cu, cv, 65536, 0, bool(bu or bv)))
            if tril:
                bu, cu = twrap(su1, w1, addrU)
                bv, cv = twrap(sv1, h1, addrV)
                pts.append((cu, cv, 65536, 1, bool(bu or bv)))
        mofs = (mof0, mof1)
        pits = (pit0, pit1)
        ta = None                                  # per-point ta
        dref_ctx = (cen, cmo, va[2][0], ref16) if dref else None
        if gath:
            # component operand selects the gathered channel (op 96);
            # dref-gather (97) collects the per-texel compare results
            comp = (va[2][0] & 3) if opc == 96 else 0
            return self.tx_gather(pts, mofs, pits, layb, ly, meta, rec,
                                  bcol, dref_ctx, comp, rid, wb, nxt)
        return self.tx_finish_pts(pts, mofs, pits, layb, ly, meta, rec,
                                  bcol, fw, tril, rid, ncomp, wb, nxt,
                                  dref_ctx)

    def tx_texel(self, base, layb, ly, mof, pit, gu, gv, bpp):
        """byte list of the texel at (gu,gv) of mip/layer, or None."""
        ta = base + ly * layb + mof + gv * pit + gu * bpp
        return ta, [self.bread8(ta + i) for i in range(bpp)]

    def tx_finish_pts(self, pts, mofs, pits, layb, ly, meta, rec,
                      bcol, fw, tril, rid, ncomp, wb, nxt, dref=None):
        """fetch/sample accumulate tail (W_TXT0/W_TXD/W_TXA/W_TXR0).
        dref = (cen, cmo, ref_fp, ref16) replaces each decoded texel by
        the compare result — PCF = per-texel compare, then the same
        bilinear/trilinear weighting as colour sampling."""
        attr = img_fmts.ATTR[meta['fmt'] & 15]
        bpp = img_fmts.BPP[meta['fmt'] & 15]
        isint = (attr >> 3) & 1
        isflt = ((attr >> 4) | (attr >> 5)) & 1
        acc = [0, 0, 0, 0]
        acc1 = [0, 0, 0, 0]
        facc = [0, 0, 0, 0]
        base, size = rec[0], rec[1]
        for (gu, gv, gw, gm, gb) in pts:
            ta = base + ly * layb + mofs[gm] + gv * pits[gm] + gu * bpp
            brd = gb
            if not brd and ta + bpp > base + size:
                self.robust += 1
                brd = True
            by = [0] * 16 if brd else \
                [self.bread8(ta + i) for i in range(bpp)]
            if dref is not None:
                # compare on the raw texel bits — D16 u16 int domain,
                # D32 fp domain; border colour substitutes first
                cen, cmo, reff, ref16 = dref
                tw = 0
                for i, b in enumerate(by):
                    tw |= b << (8 * i)
                if not cen:
                    cm = 1
                elif isflt:
                    cm = f_fcmp32(reff, bord32(bcol, 0) if brd else
                                  tw & 0xFFFFFFFF, cmo)
                elif not isint:
                    cm = f_dcmp(ref16, bord16(bcol, 0) if brd else
                                tw & 0xFFFF, cmo)
                else:
                    cm = 1                    # int fmts: no compare
                ch, fc = [0] * 4, [0x3F800000 if cm else 0, 0, 0, 0]
            else:
                ch, fc = self.tx_decode(meta, bcol, brd, by)
            if isint:
                for c in range(4):
                    s = swz_sel(meta['swz'], c)
                    wb[c] = 0 if s == 1 else \
                        (1 if s == 2 else fc[s - 3])
            elif isflt or dref is not None:
                wi = gw * (fw if gm == 1 else 256 - fw)
                wf = fmul(i2f(wi, True), 0x33800000)
                for c in range(4):
                    facc[c] = ffma(wf, fc[c], facc[c])
            else:
                d = acc1 if gm == 1 else acc
                for c in range(4):
                    d[c] = (d[c] + gw * ch[c]) & 0xFFFFFFFFFF
        if dref is not None:
            # scalar compare fraction, no swizzle (W_TXR0 dref arm)
            wb[0], wb[1], wb[2], wb[3] = facc[0], 0, 0, 0
        elif isint:
            pass
        elif isflt:
            for c in range(4):
                s = swz_sel(meta['swz'], c)
                wb[c] = 0 if s == 1 else \
                    (0x3F800000 if s == 2 else facc[s - 3])
        else:
            rr = [0, 0, 0, 0]
            for c in range(4):
                rr[c] = 0xFFFF if acc[c] + 0x8000 >= 0x100000000 \
                    else (acc[c] + 0x8000) >> 16
                if tril:
                    r1 = 0xFFFF if acc1[c] + 0x8000 >= 0x100000000 \
                        else (acc1[c] + 0x8000) >> 16
                    rr[c] = (rr[c] * (256 - fw) + r1 * fw + 128) >> 8
            for c in range(4):
                s = swz_sel(meta['swz'], c)
                x16 = 0 if s == 1 else (65535 if s == 2 else rr[s - 3])
                wb[c] = fmul(i2f(x16, True), 0x37800080)
        self.setres(rid, wb, ncomp)
        return nxt

    def tx_gather(self, pts, mofs, pits, layb, ly, meta, rec, bcol,
                  dref, comp, rid, wb, nxt):
        """G3a-ii OpImageGather/DrefGather tail (W_TXA gather arm +
        W_TXG0/G1): each footprint point feeds result component gi
        (the spec order was built into pts); `comp` picks the channel
        through the view swizzle — for dref-gather each point is the
        per-texel compare result.  No filtering."""
        attr = img_fmts.ATTR[meta['fmt'] & 15]
        bpp = img_fmts.BPP[meta['fmt'] & 15]
        isint = (attr >> 3) & 1
        isflt = ((attr >> 4) | (attr >> 5)) & 1
        base, size = rec[0], rec[1]
        for gi, (gu, gv, gw, gm, gb) in enumerate(pts):
            ta = base + ly * layb + mofs[gm] + gv * pits[gm] + gu * bpp
            brd = gb
            if not brd and ta + bpp > base + size:
                self.robust += 1
                brd = True
            by = [0] * 16 if brd else \
                [self.bread8(ta + i) for i in range(bpp)]
            if dref is not None:
                cen, cmo, reff, ref16 = dref
                tw = 0
                for i, b in enumerate(by):
                    tw |= b << (8 * i)
                if not cen:
                    cm = 1
                elif isflt:
                    cm = f_fcmp32(reff, bord32(bcol, 0) if brd else
                                  tw & 0xFFFFFFFF, cmo)
                elif not isint:
                    cm = f_dcmp(ref16, bord16(bcol, 0) if brd else
                                tw & 0xFFFF, cmo)
                else:
                    cm = 1
                wb[gi] = 0x3F800000 if cm else 0
                continue
            ch, fc = self.tx_decode(meta, bcol, brd, by)
            s = swz_sel(meta['swz'], comp)
            if isint:
                wb[gi] = 0 if s == 1 else \
                    (1 if s == 2 else fc[s - 3])
            elif isflt:
                wb[gi] = 0 if s == 1 else \
                    (0x3F800000 if s == 2 else fc[s - 3])
            else:
                # UNORM/sRGB: ch16 -> fp32 normalize (W_TXG0/G1)
                x16 = 0 if s == 1 else (65535 if s == 2 else ch[s - 3])
                wb[gi] = fmul(i2f(x16, True), 0x37800080)
        self.setres(rid, wb, 4)
        return nxt

    def tx_finish(self, pts, ta, meta, rec, bcol, isint, isflt, issr,
                  swz, rid, ncomp, wb, nxt, lvl):
        """fetch/read tail — the single-point gather (W_TXB)."""
        attr = img_fmts.ATTR[meta['fmt'] & 15]
        bpp = img_fmts.BPP[meta['fmt'] & 15]
        base, size = rec[0], rec[1]
        brd = ta + bpp > base + size
        if brd:
            self.robust += 1
        by = [0] * 16 if brd else \
            [self.bread8(ta + i) for i in range(bpp)]
        ch, fc = self.tx_decode(meta, bcol, brd, by)
        if isint:
            for c in range(4):
                s = swz_sel(swz, c)
                wb[c] = 0 if s == 1 else (1 if s == 2 else fc[s - 3])
        elif isflt:
            for c in range(4):
                s = swz_sel(swz, c)
                wb[c] = 0 if s == 1 else \
                    (0x3F800000 if s == 2 else fc[s - 3])
        else:
            for c in range(4):
                s = swz_sel(swz, c)
                x16 = 0 if s == 1 else (65535 if s == 2 else ch[s - 3])
                wb[c] = fmul(i2f(x16, True), 0x37800080)
        self.setres(rid, wb, ncomp)
        return nxt

    def tx_store(self, val, fmt, attr, bpp, nch, isint, isflt, isf16,
                 issr, ta):
        """W_TXE0..W_TXW1 — encode va[2] into the image at ta.
        UNORM/SRGB byte stores get class 'p' (Gate-2 per-byte +-1 —
        lavapipe's quantize may differ one code from the RTL's
        fixed-point encode)."""
        cls = 'f' if isflt else ('i' if isint else 'p')
        if isint or (isflt and not isf16):
            for i in range(bpp):
                self.bwrite8(ta + i,
                             (val[i >> 2] >> (8 * (i & 3))) & 0xFF, cls)
            return
        if isf16:
            for c in range(4):
                if c < nch:
                    h = f32_f16(val[c])
                    self.bwrite8(ta + 2 * c, h & 0xFF, cls)
                    self.bwrite8(ta + 2 * c + 1, h >> 8, cls)
            return
        # UNORM / sRGB: f01 -> *scale -> RNE int -> clamp / LUT
        bgr = (attr >> 6) & 1
        u8 = [0, 0, 0, 0]
        for c in range(4):
            if c >= nch:
                continue
            t = fmul(f01(val[c]),
                     0x477FFF00 if (issr and c < 3) else 0x437F0000)
            xi = s32(f2i(t, False, 'RNE'))
            if issr and c < 3:
                x16 = 0 if xi < 0 else (0xFFFF if xi > 65535 else xi)
                u8[c] = srgb_lut.lin16_to_srgb8(x16)
            else:
                u8[c] = 0 if xi < 0 else (0xFF if xi > 255 else xi)
        for c in range(nch):
            bi = (2 if c == 0 else (0 if c == 2 else c)) if bgr else c
            self.bwrite8(ta + bi, u8[c], cls)

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
        # graphics builtins — inv enumerates records (wave*LAN + lane)
        if bi == BI_VERTEXINDEX:
            return u32(self.vbase + inv) if c == 0 else 0
        if bi == BI_INSTANCEINDEX:
            return self.inst if c == 0 else 0
        if bi == BI_FRONTFACING:
            # G2b: FS waves carry the primitive's front-facing bit in
            # the work record's vbase field (imm[3].0)
            return (self.vbase & 1) if c == 0 else 0
        if bi == BI_HELPER:
            # gl_HelperInvocation — same as OpIsHelperInvocationEXT
            return ((self.ghelp >> self.inv) & 1) | int(self.dead) \
                if c == 0 else 0
        return 0

    # -- LSU -----------------------------------------------------------
    def lsu(self, ptr_off, ptr_tag, didx, comp, is_store, val, cls):
        """One (lane,comp) access; returns loaded word (loads) or
        None.  didx = the descriptor-array element index carried by
        the pointer (ptr[2])."""
        o32 = u32(ptr_off + comp * 4)
        sc = ptr_tag & 0xF
        bi = (ptr_tag >> 4) & 0xFF
        st = (ptr_tag >> 12) & 0xFF
        bd = (ptr_tag >> 20) & 0xFF
        fl = (ptr_tag >> 28) & 0xF
        if fl == VF_DROP:
            # dropped variable/member (PointSize/Clip/CullDistance):
            # stores ignored, loads read zero
            return None if is_store else 0
        if (fl == VF_REC and self.gfx and
                sc in (SC_INPUT, SC_OUTPUT)):
            # record access: base + inv*stride + off, bounded by the
            # batch extent count*stride (W_LSC mirror)
            if sc == SC_INPUT:
                base = self.in_base
                stride = ATTR_STRIDE if self.gfx == GFX_VS \
                    else VARY_STRIDE
            else:
                base = self.out_base
                stride = VARY_STRIDE if self.gfx == GFX_VS \
                    else ATTR_STRIDE
            aoff = u32(self.inv * stride + o32)
            if aoff + 4 > self.gcnt * stride:
                self.robust += 1
                return 0 if not is_store else None
            if is_store:
                self.mwrite(u32(base + aoff), val, cls)
                return None
            return self.mread(u32(base + aoff))
        if sc == SC_INPUT:
            if is_store:
                return None                    # stores to input: nothing
            if self.gfx == GFX_VS and \
                    bi in (BI_VERTEXINDEX, BI_INSTANCEINDEX):
                # G2a: the record's slot 8 is the source of truth —
                # {VertexIndex, InstanceIndex, 0, 0} at +128
                aoff = u32(self.inv * ATTR_STRIDE + 128 +
                           (4 if bi == BI_INSTANCEINDEX else 0))
                if aoff + 4 > self.gcnt * ATTR_STRIDE:
                    self.robust += 1
                    return 0
                return self.mread(u32(self.in_base + aoff))
            return self.builtin(bi, o32 >> 2)
        if sc == SC_PUSHCONST:
            if (o32 >> 2) >= self.np:
                self.robust += 1
                return 0 if not is_store else None
            return None if is_store else self.push[o32 >> 2]
        if sc in (SC_UNIFORM, SC_SBUF):
            b = self.desc_rec(st, bd, didx)
            if b is None or not b[2] or o32 + 4 > b[1]:
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

    def matv(self, iid):
        """matrix operand: list of column vectors (each a comps-list).
        cols-major order, matching the cols consecutive RF rows."""
        r = self.sc.regmap.get(iid)
        if r is None:
            return []
        tag, idx, tid, aux = r
        t = self.sc.types.get(tid, {})
        if t.get('kind') != TK['MAT']:
            return [self.regv(iid)]
        cols = t['cols']
        comps = self.sc.types[t['elem']]['comps']
        if tag == 1:
            cw = self.sc.consts.get(iid, [0] * (cols * comps))
            return [cw[c * comps:(c + 1) * comps] for c in range(cols)]
        return [list(self.rf[idx + c])[:comps] for c in range(cols)]

    def matshape(self, tid):
        """(cols, comps) for a MAT type id; (1, comps) otherwise."""
        t = self.sc.types.get(tid, {})
        if t.get('kind') == TK['MAT']:
            return t['cols'], self.sc.types[t['elem']]['comps']
        return 1, self.ncomps(tid)

    # ---- G3a-i Determinant / MatrixInverse (cofactor expansion;
    # each op is an fmul/fadd/fsub — the RTL jset chain mirrors this
    # exact expression tree) ----------------------------------------
    def detn(self, m):
        """m = column-major [col][row] square matrix -> fp32 det."""
        n = len(m)
        if n == 1:
            return m[0][0]
        if n == 2:
            return fsub(fmul(m[0][0], m[1][1]), fmul(m[0][1], m[1][0]))
        acc = fmul(m[0][0], self.minor_rc(m, 0, 0))
        for j in range(1, n):
            t = fmul(m[j][0], self.minor_rc(m, 0, j))
            acc = fsub(acc, t) if j & 1 else fadd(acc, t)
        return acc

    def minor_rc(self, m, row, col):
        """det of m minus `row`/`col` (column-major in/out)."""
        n = len(m)
        mm = [[m[c][r] for c in range(n) if c != col]
              for r in range(n) if r != row]
        cols = [[mm[r][c] for r in range(n - 1)]
                for c in range(n - 1)]
        return self.detn(cols)

    def matinv(self, m):
        """adj/det: inverse[r][i] = Cofactor(i,r)/det — column-major."""
        n = len(m)
        inv = fdiv(0x3F800000, self.detn(m))
        cols = []
        for i in range(n):
            col = []
            for r in range(n):
                cof = self.minor_rc(m, i, r)
                if (i + r) & 1:
                    cof ^= 0x80000000
                col.append(fmul(cof, inv))
            cols.append(col)
        return cols

    @staticmethod
    def dotfold(m):
        """products then right-leaning FMADD fold — OpDot semantics,
        shared by every matrix product term in 4b (§7c)."""
        t = fmul(m[-1], 0x3F800000)
        for c in range(len(m) - 2, -1, -1):
            t = ffma(m[c], 0x3F800000, t)
        return t

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
        t = self.sc.types.get(r[2], {})
        if t.get('kind') == TK['MAT']:
            # vec is a flat cols-major word list (cols*comps); each
            # column lands in its own consecutive RF row.
            comps = self.sc.types[t['elem']]['comps']
            for c in range(t['cols']):
                dst = self.rf[r[1] + c]
                for j in range(comps):
                    dst[j] = vec[c * comps + j] & 0xFFFFFFFF
            return
        if t.get('kind') == TK['STRUCT']:
            # G3a-i struct results (IAddCarry, ModfStruct, ...): the
            # flat word image packs 4 words per RF row
            nw = self.sc.nwords(r[2])
            for j in range(min(nw, len(vec))):
                self.rf[r[1] + j // 4][j % 4] = vec[j] & 0xFFFFFFFF
            return
        dst = self.rf[r[1]]
        for c in range(min(ncomp, 4)):
            dst[c] = vec[c] & 0xFFFFFFFF

    def flatv(self, iid):
        """flat word image of id's register value (multi-row aware —
        matrix columns then struct members pack consecutively)."""
        r = self.sc.regmap.get(iid)
        if r is None:
            return [0]
        if r[0] == 1:
            return list(self.sc.consts.get(iid, [0]))
        n = self.sc.nwords(r[2])
        return [self.rf[r[1] + k // 4][k % 4] for k in range(n)]

    # -- quad-lane operand values (G2b derivatives) -----------------------
    # The model steps graphics invocations one instruction at a time in
    # lane order, so at a derivative op the lanes after the current one
    # still hold their at-pc registers and the earlier lanes' values are
    # replayed from dvals[(pc, id)][inv], recorded as each lane passed
    # the instruction.  Uniform control flow makes the two views agree;
    # divergent derivatives are UB in SPIR-V anyway.
    def regv_for(self, iid, inv):
        """regv() of another (still-live) invocation's rf."""
        r = self.sc.regmap.get(iid)
        if r is None:
            return [0, 0, 0, 0]
        tag, idx, tid, aux = r
        if tag == 1:
            cw = self.sc.consts.get(iid, [0])
            return [cw[c] if c < len(cw) else cw[0] for c in range(4)]
        return list(self.ivs[inv]['rf'][idx])

    def pull_to(self, pc, iid, inv):
        """run quad-mate inv forward until it records at (pc, iid) —
        a lane on the longer side of a divergent merge (e.g. demote's
        extra block) is instruction-behind its quad, so regv_for()
        would read its not-yet-loaded register; the wave parks lanes
        at the merge and all quad mates arrive at the op together, so
        pull the straggler to it and replay its at-pc value."""
        save = (self.wave, self.lane, self.inv, self.rf, self.scratch,
                self.stack, self.dead, self.cur_lbl, self.prev_lbl,
                self.cur_pc)
        guard = 0
        while guard < (1 << 22):
            s = self.ivs[inv]
            if s['done'] or s['bwait']:
                break
            if inv in self.dvals.get((pc, iid), {}):
                break
            self.run_inv(inv, single=True)
            guard += 1
        (self.wave, self.lane, self.inv, self.rf, self.scratch,
         self.stack, self.dead, self.cur_lbl, self.prev_lbl,
         self.cur_pc) = save

    def qpull(self, pc, iid):
        """pull every live quad lane of the current invocation that has
        not yet recorded at (pc, iid) — merge-park emulation."""
        q = self.lane & ~3
        for s in range(q, q + 4):
            peer = self.wave * LAN + s
            if (peer != self.inv and peer < len(self.ivs)
                    and not self.ivs[peer]['done']
                    and peer not in self.dvals.get((pc, iid), {})):
                self.pull_to(pc, iid, peer)

    def dpeer(self, pc, iid, inv):
        """operand iid's value as invocation inv sees it at pc."""
        if inv >= len(self.ivs):
            return [0, 0, 0, 0]             # inactive lane reads 0
        got = self.dvals.get((pc, iid), {})
        if inv in got:
            return got[inv]
        if self.ivs[inv]['done']:
            return [0, 0, 0, 0]
        return self.regv_for(iid, inv)

    def deriv(self, pc, opc, iid):
        """OpDPdx/DPdy/Fwidth{,Fine,Coarse}: quads are lanes {4k..4k+3}
        of a wave.  Fine: dx(l)=v[l|1]-v[l&~1], dy(l)=v[l|2]-v[l&~2];
        coarse (and the non-suffixed forms) broadcast the quad's
        lane-0-based pair dx=v[q+1]-v[q], dy=v[q+2]-v[q].
        Fwidth = |dx| + |dy|."""
        l = self.lane
        q = l & ~3
        base = self.wave * LAN
        self.dvals.setdefault((pc, iid), {})[self.inv] = self.regv(iid)
        self.qpull(pc, iid)
        v = [self.dpeer(pc, iid, base + s) for s in range(q, q + 4)]

        def pair(sa, sb):
            return [fsub(v[sa & 3][c], v[sb & 3][c]) for c in range(4)]

        if opc in (207, 213):                 # DPdx / DPdxCoarse
            dx = pair(q + 1, q)
            return dx
        if opc in (208, 214):                 # DPdy / DPdyCoarse
            return pair(q + 2, q)
        if opc == 210:                        # DPdxFine
            return pair(l | 1, l & ~1)
        if opc == 211:                        # DPdyFine
            return pair(l | 2, l & ~2)
        if opc == 212:                        # FwidthFine
            dx, dy = pair(l | 1, l & ~1), pair(l | 2, l & ~2)
        else:                                 # 209/215 Fwidth[Coarse]
            dx, dy = pair(q + 1, q), pair(q + 2, q)
        return [fadd(dx[c] & 0x7FFFFFFF, dy[c] & 0x7FFFFFFF)
                for c in range(4)]

    def ilod(self, pc, iid, w0, h0):
        return self.ilod_v(pc, iid, self.regv(iid), w0, h0)

    def ilod_v(self, pc, iid, cval, w0, h0):
        """implicit-LOD λ for the current lane: quad-lane fine
        derivatives of the texcoord scaled by mip-0 dims —
        rho2 = max(dx2, dy2), lam = 0.5*log2(rho2).  cval is this lane's
        coordinate value — the projected forms pass the post-division
        coord (W_TXJ1 folds it back into va[1] wave-wide before the
        derivative reads, so siblings divide too).
        §7d/TEX-H1: log2 is the SFU core sequence (the old linear-
        mantissa approximation had ~0.086 λ max error)."""
        l = self.lane
        q = l & ~3
        base = self.wave * LAN
        self.dvals.setdefault((pc, iid), {})[self.inv] = cval
        self.qpull(pc, iid)
        v = [self.dpeer(pc, iid, base + s) for s in range(q, q + 4)]
        li = l & 3
        wf = i2f(w0, True)
        hf = i2f(h0, True)
        ax = fmul(fsub(v[li | 1][0], v[li & ~1][0]), wf)
        bx = fmul(fsub(v[li | 1][1], v[li & ~1][1]), hf)
        ay = fmul(fsub(v[li | 2][0], v[li & ~2][0]), wf)
        by = fmul(fsub(v[li | 2][1], v[li & ~2][1]), hf)
        dx2 = ffma(bx, bx, fmul(ax, ax))
        dy2 = ffma(by, by, fmul(ay, ay))
        rho2 = fp_minmax(dx2, dy2, True)
        # W_TXL8/W_TXLC: SFU log2 core then *0.5
        lg = sfu_tables.sfu_eval(30, [[rho2, 0, 0, 0]])
        return fmul(lg[0], 0x3F000000)

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
        didx = ptr[2]                          # carried desc index
        cty = self.sc.types.get(self.regt(base), {})
        cty = cty.get('elem', 0)               # pointee type
        cmstride = 0
        first = True
        for iid in ids:
            t = self.sc.types.get(cty)
            if t is None:
                break
            k = t['kind']
            # §12.3 F5 (W_CHT1): first index into an array under
            # UNIFORM/SBUF storage selects the descriptor record —
            # it lands in ptr[2], not the byte offset.
            if (first and k in (TK['ARRAY'], TK['RARRAY']) and
                    (tag & 0xF) in (SC_UNIFORM, SC_SBUF, SC_UCONST)):
                didx = self.idxval(iid)
                cty = t.get('elem', cty)
                first = False
                continue
            first = False
            if k == TK['STRUCT']:
                midx = self.idxval_struct(iid)
                mb = self.sc.member_base.get(cty, 0) + midx
                if mb < len(self.sc.members):
                    m = self.sc.members[mb]
                    off = u32(off + m['offset'])
                    cmstride = m['mstride']
                    cty = m['type']
                    if m['flags'] & 0x40:      # MF_DROP (W_CHM1)
                        tag = (tag & 0x0FFFFFFF) | (VF_DROP << 28)
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
        return [off, tag, didx, 0]

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
        # ---- G3a-i -------------------------------------------------
        if xnum in (33, 34):                  # Determinant/Inverse
            nc, nc2 = self.matshape(vt[0])
            m = [va[0][i * nc2:(i + 1) * nc2] for i in range(nc)]
            if xnum == 33:
                return [self.detn(m), 0, 0, 0]
            return [w for col in self.matinv(m) for w in col]
        if xnum == 35 or xnum == 36:          # Modf / ModfStruct
            # Modf: [fr0..3, ip0..3], caller stores wb[4+c] to the ptr.
            # ModfStruct: flat {frac(nc), integ(nc)} member order.
            fr = []
            ip = []
            for c in range(4):
                i = f2i(va[0][c], False, 'RTZ')
                f = i2f(i, False)
                ip.append(va[0][c] if (isnan(va[0][c]) or
                                       ((va[0][c] >> 23) & 0xFF) >= 158)
                          else f)
                fr.append(fsub(va[0][c], ip[c]))
            if xnum == 36:
                nc = self.ncomps(vt[0])
                return fr[:nc] + ip[:nc]
            return fr + ip
        if xnum == 51 or xnum == 52:          # Frexp / FrexpStruct
            out = []
            for c in range(4):
                w = va[0][c]
                ex = (w >> 23) & 0xFF
                if ex == 0 or ex == 0xFF:     # zero/denorm/inf/nan
                    out.append([w, 0])
                    continue
                out.append([(w & 0x807FFFFF) | 0x3F000000,
                            ex - 126])
            if xnum == 52:
                nc = self.ncomps(vt[0])
                return [o[0] for o in out][:nc] + \
                    [o[1] for o in out][:nc]
            return [o[0] for o in out] + [o[1] for o in out]
        if xnum == 53:                        # Ldexp
            return [ldexp(va[0][c], va[1][c]) for c in range(4)]
        if xnum in (54, 55, 56, 57):          # Pack{S,U}norm{4x8,2x16}
            # clamp then *scale then round-to-nearest-even
            sc_, lo_, nb = {54: (0x42FE0000, 0xBF800000, 8),
                            55: (0x437F0000, 0, 8),
                            56: (0x46FFFE00, 0xBF800000, 16),
                            57: (0x477FFF00, 0, 16)}[xnum]
            nc = 32 // nb                  # 4x8 -> 4, 2x16 -> 2
            r = 0
            for c in range(nc):
                t = fp_minmax(va[0][c], lo_, True)
                t = fp_minmax(t, 0x3F800000, False)
                u = f2i(fmul(t, sc_), False, 'RNE')
                r |= (u & ((1 << nb) - 1)) << (nb * c)
            return [r, 0, 0, 0]
        if xnum == 58:                        # PackHalf2x16
            return [f32_f16(va[0][0]) | (f32_f16(va[0][1]) << 16),
                    0, 0, 0]
        if xnum in (60, 61, 62, 63, 64):      # Unpack*
            if xnum == 62:
                return [f16_f32(va[0][0] & 0xFFFF),
                        f16_f32((va[0][0] >> 16) & 0xFFFF), 0, 0]
            nb = 16 if xnum in (60, 61) else 8
            sc_ = {60: 0x46FFFE00, 61: 0x477FFF00,
                   63: 0x42FE0000, 64: 0x437F0000}[xnum]
            nc = 32 // nb                  # 2x16 -> 2, 4x8 -> 4
            sgd = xnum in (60, 63)
            out = []
            for c in range(nc):
                u = (va[0][0] >> (nb * c)) & ((1 << nb) - 1)
                if sgd and u & (1 << (nb - 1)):
                    u -= 1 << nb
                t = fdiv(i2f(u & 0xFFFFFFFF, False), sc_)
                if sgd:
                    t = fp_minmax(t, 0xBF800000, True)
                    t = fp_minmax(t, 0x3F800000, False)
                out.append(t)
            return out + [0] * (4 - nc)
        if xnum == 73:                        # FindILsb
            return [u32((x & -x).bit_length() - 1) if x else 0xFFFFFFFF
                    for x in va[0]]
        if xnum == 75:                        # FindUMsb
            return [u32(x.bit_length() - 1) if x else 0xFFFFFFFF
                    for x in va[0]]
        if xnum == 74:                        # FindSMsb
            def _smsb(x):
                if x == 0 or x == 0xFFFFFFFF:
                    return 0xFFFFFFFF
                v = (~x & 0xFFFFFFFF) if x & 0x80000000 else x
                return v.bit_length() - 1
            return [u32(_smsb(x)) for x in va[0]]
        if xnum == 70:                        # FaceForward
            nc = self.ncomps(vt[0])
            m = [fmul(va[1][c], va[2][c]) for c in range(nc)]
            t = fmul(m[nc - 1], 0x3F800000)
            for c in range(nc - 2, -1, -1):
                t = ffma(m[c], 0x3F800000, t)
            neg = fp_cmp(t, 0, 'RTZ', False)      # d < 0
            return [va[0][c] if neg else va[0][c] ^ 0x80000000
                    for c in range(4)]
        if xnum == 71:                        # Reflect = I - 2(N.I)N
            nc = self.ncomps(vt[0])
            m = [fmul(va[0][c], va[1][c]) for c in range(nc)]
            t = fmul(m[nc - 1], 0x3F800000)
            for c in range(nc - 2, -1, -1):
                t = ffma(m[c], 0x3F800000, t)
            t2 = fmul(0x40000000, t)
            return [ffma(va[1][c] ^ 0x80000000, t2, va[0][c])
                    for c in range(4)]
        if xnum == 72:                        # Refract
            nc = self.ncomps(vt[0])
            m = [fmul(va[0][c], va[1][c]) for c in range(nc)]
            t = fmul(m[nc - 1], 0x3F800000)
            for c in range(nc - 2, -1, -1):
                t = ffma(m[c], 0x3F800000, t)
            d2 = fmul(t, t)
            e2 = fmul(va[2][0], va[2][0])
            t0 = fsub(0x3F800000, d2)
            k = ffma(e2 ^ 0x80000000, t0, 0x3F800000)
            if fp_cmp(k, 0, 'RTZ', False):        # k < 0 -> 0
                return [0, 0, 0, 0]
            co = fadd(fmul(va[2][0], t), fsqrt(k))
            return [fsub(fmul(va[2][0], va[0][c]),
                         fmul(co, va[1][c])) for c in range(4)]
        if xnum in (79, 80):                  # NMin / NMax (NaN prop)
            mx = xnum == 80
            return [0x7FC00000 if isnan(va[0][c]) or isnan(va[1][c])
                    else fp_minmax(va[0][c], va[1][c], mx)
                    for c in range(4)]
        if xnum == 81:                        # NClamp = NMin(NMax(x,lo),hi)
            out = []
            for c in range(4):
                t = 0x7FC00000 if isnan(va[0][c]) or isnan(va[1][c]) \
                    else fp_minmax(va[0][c], va[1][c], True)
                t = 0x7FC00000 if isnan(t) or isnan(va[2][c]) \
                    else fp_minmax(t, va[2][c], False)
                out.append(t)
            return out
        # ---- G3a-ii §7d SFU transcendentals/hyperbolics ---------------
        # Bit-exact mirror of the g6lc_apu_shwave xsub cores + epilogue:
        # the sequences live in sfu_tables.py, generated by
        # gen_sfu_tables.py from the same source as g6lc_apu_sfu_pkg.sv.
        if xnum in sfu_tables.SFU_FUNCS:
            return sfu_tables.sfu_eval(xnum, va)
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
            if opc in (62, 99):               # Store / ImageWrite: no rty
                return ops[k] if k < len(ops) else 0
            if opc in (95, 87, 88):           # operand mask word at [4]
                if k == 0:
                    return ops[2]
                if k == 1:
                    return ops[3]
                return ops[5] if 5 < len(ops) else 0
            # G3a-ii: dref/proj/gather operand positions (mask word
            # splits the id list; Lod/ConstOffset ids trail it)
            if opc in (90, 94):               # mask at [5]
                return ops[2 + k] if k < 3 else \
                    (ops[k + 3] if k + 3 < len(ops) else 0)
            if opc == 92:                     # mask at [4]
                return ops[2 + k] if k < 2 else \
                    (ops[k + 3] if k + 3 < len(ops) else 0)
            if opc == 91:
                return ops[2 + k] if k < 2 else \
                    (ops[k + 3] if k + 3 < len(ops) else 0)
            # 89/93/96/97: mask at [5], trailing Lod/ConstOffset at
            # [6..7] (97 DrefGather has no Component operand per the
            # grammar — dref is ops[4])
            if opc in (89, 93, 96, 97):
                return ops[2 + k] if k < 3 else \
                    (ops[k + 3] if k + 3 < len(ops) else 0)
            if opc == 105:
                return ops[2 + k] if 2 + k < len(ops) else 0
            if opc == 12:
                return ops[4 + k] if 4 + k < len(ops) else 0
            if opc == 228:                    # AtomicStore: ptr, val
                return (ops[0], ops[3])[k]
            if opc == 230:                    # CAS: ptr, val, cmp
                return (ops[2], ops[5], ops[6])[k]
            if opc in self.ATOMOPS:           # ptr, [val]
                return ops[2] if k == 0 else ops[5]
            return ops[2 + k] if 2 + k < len(ops) else 0
        nva = self.nva(opc, wc, ops)
        va = [self.regv(opid(k)) for k in range(nva)] + \
             [[0] * 4] * (6 - nva)
        vt = [self.regt(opid(k)) for k in range(nva)] + \
             [0] * (6 - nva)

        if opc in (0, 54, 55, 59):            # Nop Function Param Var
            return pc + wc
        if opc == 248:                        # Label — track cur block
            self.cur_lbl = ops[0]
            return pc + wc
        if opc == 57:                         # FunctionCall — push frame
            f = self.sc.funcs[ops[2]]
            if len(self.stack) >= CALLDEPTH:
                self.fault = 'CALLDEPTH'
                return 'ret'
            for i, (pid, _pt) in enumerate(f['params']):
                aid = ops[3 + i] if 3 + i < len(ops) else 0
                pd = self.sc.regmap.get(pid)
                ad = self.sc.regmap.get(aid)
                if pd is None or ad is None or pd[0] == 1:
                    continue
                # copy the argument's RF row(s) into the callee's
                # param row — the param's type decides the row count
                nr = self.sc.reg_rows(_pt)
                if ad[0] == 1:
                    cw = self.sc.consts.get(aid, [0])
                    for k in range(nr):
                        self.rf[pd[1] + k] = \
                            [cw[4 * k + c] if 4 * k + c < len(cw)
                             else 0 for c in range(4)]
                else:
                    for k in range(nr):
                        self.rf[pd[1] + k] = list(self.rf[ad[1] + k])
            self.stack.append(dict(ret=pc + wc, rid=rid, rty=rty,
                                   prev=self.prev_lbl,
                                   cur=self.cur_lbl))
            return f['off']
        if opc in (56, 253):                  # FunctionEnd / Return
            if self.stack:
                fr = self.stack.pop()
                self.prev_lbl, self.cur_lbl = fr['prev'], fr['cur']
                return fr['ret']
            return 'ret'
        if opc == 254:                        # ReturnValue — callee pop
            if self.stack:
                fr = self.stack.pop()
                if self.sc.types.get(fr['rty'],
                                     {}).get('kind') != TK['VOID']:
                    self.setres(fr['rid'], self.flatv(ops[0]),
                                self.sc.nwords(fr['rty']))
                self.prev_lbl, self.cur_lbl = fr['prev'], fr['cur']
                return fr['ret']
            return 'ret'
        if opc in (252, 4416):                # Kill / Terminate
            self.dead = True
            self.ivs[self.inv]['killed'] = True
            return 'ret'
        if opc == 5380:                       # Demote — dead, keeps run
            self.dead = True
            return pc + wc
        if opc == 5381:                       # IsHelperInvocationEXT
            h = ((self.ghelp >> self.inv) & 1) | int(self.dead)
            self.setres(rid, [h, 0, 0, 0], 1)
            return pc + wc
        if opc in (246, 247, 225):            # LoopMerge SelectionMerge
            return pc + wc                    # MemoryBarrier (no-op)
        if opc == 224:                        # ControlBarrier — phase edge
            return 'barrier'
        if opc == 255:                        # Unreachable — run fault
            self.fault = 'UNREACHABLE'
            return 'ret'
        if opc == 245:                        # Phi — pick by prev block
            val = ops[2]                      # fallback: first pair
            for k in range((wc - 3) // 2):
                if ops[3 + 2 * k] == self.prev_lbl:
                    val = ops[2 + 2 * k]
                    break
            self.setres(rid, self.regv(val), ncomp)
            return pc + wc
        if opc == 249:                        # Branch
            self.prev_lbl = self.cur_lbl
            return self.sc.labels[ops[0]]
        if opc == 250:                        # BranchConditional
            self.prev_lbl = self.cur_lbl
            tgt = ops[1] if self.regv(ops[0])[0] else ops[2]
            return self.sc.labels[tgt]
        if opc == 251:                        # Switch
            self.prev_lbl = self.cur_lbl
            sel = self.regv(ops[0])[0]
            tgt = ops[1]
            for k in range((wc - 3) // 2):
                if ops[2 + 2 * k] == sel:
                    tgt = ops[3 + 2 * k]
                    break
            return self.sc.labels[tgt]
        if opc in (86, 100):                  # SampledImage / Image
            if opc == 86:
                sp = va[1]
                wb = [(((sp[1] >> 20) & 0xFF) << 24) |
                      (((sp[1] >> 12) & 0xFF) << 16) |
                      (sp[2] & 0xFFFF),
                      va[0][1] | 0x80000000, va[0][2], 0]
            else:
                wb = [0, va[0][1] & 0x7FFFFFFF, va[0][2], 0]
            self.setres(rid, wb, 4)
            return pc + wc
        if opc in (87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99,
                   103, 104, 105, 106):
            return self.img_op(pc, opc, wc, ops, va, rty, rid, ncomp)
        if opc in (207, 208, 209, 210, 211, 212, 213, 214, 215):
            self.setres(rid, self.deriv(pc, opc, ops[2]), ncomp)
            return pc + wc
        if opc == 61:                         # Load
            tk = self.sc.types.get(rty, {}).get('kind')
            if tk in (TK['IMG'], TK['SAMP'], TK['SIMG']):
                # image/sampler loads pass the descriptor ref through
                self.setres(rid, va[0], 4)
                return pc + wc
            wb = [0] * ncomp
            for c in range(ncomp):
                r = self.lsu(va[0][0], va[0][1], va[0][2], c,
                             False, 0, 'i')
                wb[c] = r if r is not None else 0
            self.setres(rid, wb, ncomp)
            return pc + wc
        if opc == 62:                         # Store
            if (self.dead or self.helper()) and \
                    (va[0][1] & 0xF) in \
                    (SC_UNIFORM, SC_SBUF, SC_WORKGROUP):
                # dead/helper lane: device-visible stores suppressed;
                # Function/Private/Output storage stays live — demoted
                # lanes keep their per-invocation state for quad
                # derivatives; killed lanes never reach here ('ret'
                # at the kill site)
                return pc + wc
            ncs = self.ncomps(vt[1])          # stored value words
            cls = self.classof(vt[1])
            if self.sc.types.get(vt[1], {}).get('kind') == TK['MAT']:
                src = [w for col in self.matv(ops[1]) for w in col]
            else:
                src = va[1]
            for c in range(ncs):
                self.lsu(va[0][0], va[0][1], va[0][2], c,
                         True, src[c], cls)
            return pc + wc
        if opc in (65, 66):                   # (InBounds)AccessChain
            wb = self.chain(ops[2], ops[3:]) if len(ops) > 3 \
                else va[0]
            self.setres(rid, wb, 4)
            return pc + wc
        if opc == 68:                         # ArrayLength
            ptr = va[0]
            b = self.desc_rec((ptr[1] >> 12) & 0xFF,
                              (ptr[1] >> 20) & 0xFF, ptr[2])
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
            if self.sc.types.get(rty, {}).get('kind') == TK['MAT']:
                # constituents are the column vectors — flat cols-major
                # concatenation into the cols RF rows.
                flat = []
                for k in range(nva):
                    if self.sc.types.get(vt[k], {}).get('kind') \
                            == TK['MAT']:
                        for col in self.matv(ops[2 + k]):
                            flat += col
                    else:
                        flat += va[k][:self.ncomps(vt[k])]
                self.setres(rid, flat, ncomp)
                return pc + wc
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
            t0 = self.sc.types.get(vt[0], {})
            if t0.get('kind') == TK['MAT']:
                # register-resident matrix: cols-major column list;
                # [col][comp] element extract or [col] column extract
                m = self.matv(opid(0))
                col = m[(ops[3] & 3) % len(m)] if m else [0, 0, 0, 0]
                if len(ops) > 4:
                    self.setres(rid, [col[ops[4] & 3], 0, 0, 0], 1)
                else:
                    self.setres(rid, (col + [0, 0, 0, 0])[:4], ncomp)
            elif t0.get('kind') == TK['STRUCT']:
                # walk literals through member offsets then sub-index
                off, tid = 0, vt[0]
                for lit in ops[3:]:
                    t = self.sc.types.get(tid, {})
                    if t.get('kind') == TK['STRUCT']:
                        m = self.sc.members[
                            self.sc.member_base.get(tid, 0) + lit]
                        off += m['offset'] // 4
                        tid = m['type']
                    elif t.get('kind') in (TK['VEC'], TK['ARR']):
                        off += lit * self.sc.nwords(t['elem'])
                        tid = t['elem']
                    else:
                        off += lit
                fl = self.flatv(opid(0))
                nw = self.sc.nwords(rty)
                self.setres(rid, (fl[off:off + nw] + [0] * nw)[:nw],
                            nw)
            else:
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

        # ---- matrix ops (§7c lane micro-sequences; products then
        # right-leaning FMADD fold per output element — OpDot fold) --
        if opc == 84:                         # Transpose
            mc, mc2 = self.matshape(vt[0])
            m = self.matv(ops[2])
            flat = [m[j][c] for c in range(mc2) for j in range(mc)]
            self.setres(rid, flat, ncomp)
            return pc + wc
        if opc == 143:                        # MatrixTimesScalar
            s = va[1][0]
            flat = [fmul(x, s) for col in self.matv(ops[2])
                    for x in col]
            self.setres(rid, flat, ncomp)
            return pc + wc
        if opc == 145:                        # MatrixTimesVector
            cols, comps = self.matshape(vt[0])
            m, v = self.matv(ops[2]), va[1]
            flat = [self.dotfold([fmul(m[c][j], v[c])
                                  for c in range(cols)])
                    for j in range(comps)]
            self.setres(rid, flat, ncomp)
            return pc + wc
        if opc == 144:                        # VectorTimesMatrix
            cols, comps = self.matshape(vt[1])
            v, m = va[0], self.matv(ops[3])
            flat = [self.dotfold([fmul(v[k], m[j][k])
                                  for k in range(comps)])
                    for j in range(cols)]
            self.setres(rid, flat, ncomp)
            return pc + wc
        if opc == 146:                        # MatrixTimesMatrix
            cA, rA = self.matshape(vt[0])     # A: cA cols of vec rA
            cB, _rB = self.matshape(vt[1])    # B: cB cols of vec cA
            a, b = self.matv(ops[2]), self.matv(ops[3])
            flat = [self.dotfold([fmul(a[k][j], b[c][k])
                                  for k in range(cA)])
                    for c in range(cB) for j in range(rA)]
            self.setres(rid, flat, ncomp)
            return pc + wc
        if opc == 147:                        # OuterProduct v1 x v2
            c1 = self.ncomps(vt[0])
            c2 = self.ncomps(vt[1])
            flat = [fmul(va[0][j], va[1][c])
                    for c in range(c2) for j in range(c1)]
            self.setres(rid, flat, ncomp)
            return pc + wc

        # per-component ALU ops
        wb = [0, 0, 0, 0]
        if opc == 12:                         # ExtInst
            if ops[3] in (33, 34):
                # matrix operand: flatten the column RF rows
                va = list(va)
                va[0] = [w for col in self.matv(ops[4]) for w in col]
            wb = self.x_ext(ops[3], va, vt)
            if ops[3] in (35, 51) and not (
                    (self.dead or self.helper()) and
                    (va[1][1] & 0xF) in
                    (SC_UNIFORM, SC_SBUF, SC_WORKGROUP)):
                # Modf/Frexp: integer part / exponent words live at
                # wb[4+c] — store per component to the pointer operand
                ptr = va[1]
                for c in range(ncomp):
                    self.lsu(ptr[0], ptr[1], ptr[2], c, True,
                             wb[4 + c], 'i')
            self.setres(rid, wb,
                        self.sc.nwords(rty)
                        if self.sc.types.get(rty, {}).get('kind')
                        == TK['STRUCT'] else ncomp)
            return pc + wc
        # ---- G3a-i atomics: lane-serial RMW through the LSU ---------
        if opc == 228 or opc in self.ATOMOPS:
            if self.dead or self.helper():
                # dead/helper lane: the RMW is a side effect — result
                # register still written (0), memory untouched
                if opc != 228:
                    self.setres(rid, [0, 0, 0, 0], 1)
                return pc + wc
            ptr = va[0]
            r0 = self.robust
            old = self.lsu(ptr[0], ptr[1], ptr[2], 0, False, 0, 'i')
            if self.robust != r0:             # OOB: returns 0, no write
                if opc != 228:
                    self.setres(rid, [0, 0, 0, 0], 1)
                return pc + wc
            old = 0 if old is None else old
            val = va[1][0] if opc not in (227, 232, 233) else 0
            new = self.atomic_op(opc, old, val,
                                 va[2][0] if opc == 230 else 0)
            if opc != 227:                    # AtomicLoad never writes
                self.lsu(ptr[0], ptr[1], ptr[2], 0, True, new, 'i')
            if opc != 228:
                self.setres(rid, [old, 0, 0, 0], 1)
            return pc + wc
        # ---- FRem/FMod: fdiv -> trunc/floor int -> reconstruct -----
        if opc in (140, 141):
            rnd = 'RTZ' if opc == 140 else 'RDN'
            for c in range(4):
                q = fdiv(va[0][c], va[1][c])
                t = i2f(f2i(q, False, rnd), False)
                wb[c] = fsub(va[0][c], fmul(va[1][c], t))
            self.setres(rid, wb, ncomp)
            return pc + wc
        # ---- carry/borrow/extended-mul: struct {lo, hi} results ----
        if opc in (149, 150, 151, 152):
            wb = [0] * 8
            for c in range(4):
                x, y = va[0][c], va[1][c]
                if opc == 149:
                    r = u32(x + y)
                    wb[2 * c] = r
                    wb[2 * c + 1] = int(r < x)
                elif opc == 150:
                    wb[2 * c] = u32(x - y)
                    wb[2 * c + 1] = int(x < y)
                elif opc == 151:
                    p = x * y
                    wb[2 * c] = u32(p)
                    wb[2 * c + 1] = u32(p >> 32)
                else:
                    p = s32(x) * s32(y)
                    wb[2 * c] = u32(p)
                    wb[2 * c + 1] = u32(p >> 32)
            self.setres(rid, wb, 8)
            return pc + wc
        if opc == 77:                         # VectorExtractDynamic
            self.setres(rid, [va[0][va[1][0] & 3], 0, 0, 0], 1)
            return pc + wc
        if opc == 78:                         # VectorInsertDynamic
            wb = list(va[0])
            wb[va[2][0] & 3] = va[1][0]
            self.setres(rid, wb, ncomp)
            return pc + wc
        if opc == 83 or opc == 1:             # CopyObject / Undef
            self.setres(rid, va[0] if opc == 83 else [0] * 4, ncomp)
            return pc + wc
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
                        200, 154, 155, 156, 157, 201, 202, 203, 204,
                        205))
    # 32-bit atomics over StorageBuffer/Workgroup — lane-serial RMW
    ATOMOPS = frozenset((227, 229, 230, 232, 233, 234, 235, 236, 237,
                         238, 239, 240, 241, 242))
    HAS_RTY = frozenset((1, 12, 57, 61, 65, 66, 68, 77, 78, 79, 80, 81,
                         82, 83, 84, 86, 87, 88, 89, 90, 91, 92, 93, 94,
                         95, 96, 97, 98, 100, 103, 104, 105,
                         106, 109, 110, 111, 112, 124, 126, 127, 128,
                         129, 130, 131, 132, 133, 134, 135, 136, 137,
                         138, 139, 140, 141, 142, 143, 144, 145, 146,
                         147, 148, 149, 150, 151, 152, 154, 155, 156,
                         157, 164, 165, 166, 167, 168, 169, 170, 171,
                         172, 173, 174, 175, 176, 177, 178, 179, 180,
                         181, 182, 183, 184, 185, 186, 187, 188, 189,
                         190, 191, 194, 195, 196, 197, 198, 199, 200,
                         201, 202, 203, 204, 205,
                         207, 208, 209, 210, 211, 212, 213, 214, 215,
                         227, 229, 230, 232, 233, 234, 235, 236, 237,
                         238, 239, 240, 241, 242, 245, 5381))

    @staticmethod
    def atomic_op(opc, old, val, cmpv):
        """RMW function — 32-bit; mirrored in shwave's W_EX atomic
        datapath."""
        if opc == 227 or opc == 228 or opc == 229:
            return u32(val)                        # load/xchg/store
        if opc == 230:
            return u32(val) if old == cmpv else u32(old)
        if opc == 232:
            return u32(old + 1)
        if opc == 233:
            return u32(old - 1)
        if opc == 234:
            return u32(old + val)
        if opc == 235:
            return u32(old - val)
        if opc == 236:
            return u32(min(s32(old), s32(val)))
        if opc == 237:
            return u32(min(old, val))
        if opc == 238:
            return u32(max(s32(old), s32(val)))
        if opc == 239:
            return u32(max(old, val))
        if opc == 240:
            return old & val
        if opc == 241:
            return old | val
        if opc == 242:
            return old ^ val
        return u32(old)

    @staticmethod
    def nva(opc, wc, ops):
        """f_nva() — operand count per opcode (mask-aware for the
        G3a-ii image ops: Lod/ConstOffset ids trail the mask word)."""
        if opc == 62:
            return 2
        if opc == 80:
            return min(4, wc - 3)
        if opc == 169:
            return 3
        if opc == 78 or opc == 230:
            return 3
        if opc == 82:
            return 2
        if opc == 201:
            return 4
        if opc in (202, 203):
            return 3
        if opc == 12:
            return 3 if wc > 8 else (wc - 5 if wc > 5 else 0)
        if opc == 228:
            return 2                          # ptr, value
        if opc == 227 or opc in (232, 233):
            return 1                          # ptr
        if opc == 99:
            return 3                          # img, coord, texel
        if opc == 95:
            return 3 if wc > 6 else 2         # img, coord[, lod]
        if opc in (87, 88, 103):
            return 3 if opc == 88 else 2
        # G3a-ii
        if opc == 89:
            return 4 if (wc > 7 and (ops[5] & 8)) else 3
        if opc == 90:
            return 5 if (wc > 8 and (ops[5] & 8)) else 4
        if opc == 91:
            return 3 if (wc > 5 and (ops[4] & 8)) else 2
        if opc == 92:
            return 4 if (wc > 6 and (ops[4] & 8)) else 3
        if opc == 93:
            return 4 if (wc > 6 and (ops[5] & 8)) else 3
        if opc == 94:
            return 5 if (wc > 8 and (ops[5] & 8)) else 4
        if opc in (96, 97):
            return 3 + (((ops[5] >> 3) & 1) + ((ops[5] >> 1) & 1)
                        if wc > 6 else 0)
        if opc == 105:
            return 2
        if opc in (61, 65, 66, 68, 81, 83, 84, 109, 110, 111, 112,
                   124, 126, 127, 154, 155, 156, 157, 168, 200, 204,
                   205):
            return 1
        if opc in (54, 55, 56, 248, 249, 252, 253, 254, 4416, 5380):
            return 0
        if opc in (0, 224, 225, 245, 246, 247, 250, 251, 255):
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
            elif opc == 201:                  # BitFieldInsert
                off, cnt = va[2][c] & 31, va[3][c] & 31
                if cnt == 0:
                    out[c] = x
                else:
                    m = ((1 << cnt) - 1) << off
                    out[c] = (x & ~m | (y << off) & m) & 0xFFFFFFFF
            elif opc == 202:                  # BitFieldSExtract
                off, cnt = va[1][c] & 31, va[2][c] & 31
                out[c] = 0 if cnt == 0 else \
                    u32(s32(x << (32 - off - cnt) & 0xFFFFFFFF)
                        >> (32 - cnt))
            elif opc == 203:                  # BitFieldUExtract
                off, cnt = va[1][c] & 31, va[2][c] & 31
                out[c] = 0 if cnt == 0 else (x >> off) & \
                    ((1 << cnt) - 1)
            elif opc == 204:                  # BitReverse
                out[c] = int('{:032b}'.format(x)[::-1], 2)
            elif opc == 205:                  # BitCount
                out[c] = bin(x).count('1')
            elif opc == 154:                  # Any
                out[c] = int(any(bool(a[j])
                                 for j in range(self.ncomps(vt[0]))))
            elif opc == 155:                  # All
                out[c] = int(all(bool(a[j])
                                 for j in range(self.ncomps(vt[0]))))
            elif opc == 156:                  # IsNan
                out[c] = int((x & 0x7FFFFFFF) > 0x7F800000)
            elif opc == 157:                  # IsInf
                out[c] = int((x & 0x7FFFFFFF) == 0x7F800000)
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
    # §7c independent-lane semantics: each invocation executes
    # sequentially to a barrier or to the end; the workgroup runs in
    # phases separated by barriers.  Workgroup (slab) memory is the
    # only shared state.  There is no lockstep in the model — Gate 1
    # (bit-exact RTL == model) is the proof that the RTL's wave
    # reconvergence reproduces independent-lane results.

    def inv_init(self):
        """fresh per-invocation state dict."""
        rf = [[0, 0, 0, 0] for _ in range(self.sc.n_regs)]
        for (idx, sc, bi, st, bd, off, fl) in self.sc.init:
            tag = (fl << 28) | (bd << 20) | (st << 12) | (bi << 4) | sc
            rf[idx] = [off, tag, 0, 0]
        return dict(rf=rf, scratch=[0] * self.sc_w,
                    pc=self.sc.entry_off, cur_lbl=0, prev_lbl=0,
                    done=False, bwait=False, steps=0,
                    stack=[], dead=False, killed=False)

    def run_inv(self, i, single=False):
        """run invocation i until it ends or waits at a barrier; with
        single=True it executes exactly one instruction (the graphics
        lockstep that makes quad-lane derivative values visible)."""
        s = self.ivs[i]
        self.wave, self.lane = i // LAN, i % LAN
        self.inv = i
        self.rf, self.scratch = s['rf'], s['scratch']
        self.stack = s['stack']
        self.dead = s['dead']
        self.cur_lbl, self.prev_lbl = s['cur_lbl'], s['prev_lbl']
        while True:
            self.cur_pc = s['pc']
            npc = self.exec_one(s['pc'])
            s['steps'] += 1
            if npc == 'barrier':
                s['pc'] += (self.spv[s['pc']] >> 16)  # past the barrier
                s['bwait'] = True
                break
            if npc == 'ret' or s['steps'] > (1 << 22):
                s['done'] = True
                break
            s['pc'] = npc
            if single:
                break
        s['dead'] = self.dead
        s['cur_lbl'], s['prev_lbl'] = self.cur_lbl, self.prev_lbl
        if s['done'] and self.gfx == GFX_FS and self.fs_late:
            # G3a-i FS-out record slot 8: {FragDepth(word0, shader-
            # stored), flags(bit0 discarded), SampleMask, 0} — the
            # wave writes words 1-3 at wave end for every lane of an
            # fs_late module, helpers included
            base = self.out_base + self.inv * ATTR_STRIDE
            fl = 1 if (s['dead'] or s['killed']) else 0
            self.mwrite(base + 132, fl, 'i')
            self.mwrite(base + 136, 0xFFFFFFFF, 'i')
            self.mwrite(base + 140, 0, 'i')

    def run(self):
        """whole dispatch: workgroups x-fastest (W_EOW order); within a
        workgroup the invocations run in barrier-separated phases —
        each invocation independently to its next OpControlBarrier
        or to termination, finished invocations counting as arrived.
        Graphics wave work runs a single batch of `gcnt` records (one
        "workgroup" — lanes enumerate record indices)."""
        ninv = self.gcnt if self.gfx else self.lx * self.ly * self.lz
        for wgz in range(1 if self.gfx else self.gz):
            for wgy in range(1 if self.gfx else self.gy):
                for wgx in range(1 if self.gfx else self.gx):
                    self.wg = (wgx, wgy, wgz)
                    self.slab = [0] * self.slb_w
                    self.l0_idx = {}
                    self.ivs = [self.inv_init() for _ in range(ninv)]
                    phases = 0
                    while True:
                        live = [i for i in range(ninv)
                                if not self.ivs[i]['done']]
                        if not live:
                            break
                        waiters = [i for i in live
                                   if self.ivs[i]['bwait']]
                        if len(waiters) == len(live):
                            # rendezvous: release everyone
                            for i in waiters:
                                self.ivs[i]['bwait'] = False
                            self.nswitch += 1
                        for i in live:
                            if not self.ivs[i]['bwait']:
                                # graphics waves step one instruction
                                # per round (lane order) so derivative
                                # ops see every quad lane's at-pc value
                                self.run_inv(i, bool(self.gfx))
                        phases += 1
                        if phases > 4096:
                            break
        return self.mem

    # output collection -------------------------------------------------
    def outputs(self):
        """{(bind_idx): [words]} for bindings that received stores."""
        out = {}
        for i, b in enumerate(self.binds):
            st, bd, sz, ad = b[0], b[1], b[2], b[3]
            if any((ad >> 2) + k in self.wclass for k in range(sz // 4)):
                out[i] = [self.mem.get((ad >> 2) + k, 0)
                          for k in range(sz // 4)]
        return out

    def out_classes(self):
        out = {}
        for i, b in enumerate(self.binds):
            st, bd, sz, ad = b[0], b[1], b[2], b[3]
            if any((ad >> 2) + k in self.wclass for k in range(sz // 4)):
                out[i] = [self.wclass.get((ad >> 2) + k, 'i')
                          for k in range(sz // 4)]
        return out

    def gfx_outputs(self):
        """graphics wave work: (words, classes) over the output-record
        extent — count records of out_stride bytes at out_base."""
        if not self.gfx:
            return [], []
        stride = VARY_STRIDE if self.gfx == GFX_VS else ATTR_STRIDE
        n = self.gcnt * stride // 4
        return ([self.mem.get((self.out_base >> 2) + k, 0)
                 for k in range(n)],
                [self.wclass.get((self.out_base >> 2) + k, 'i')
                 for k in range(n)])


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
