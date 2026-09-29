# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
from __future__ import annotations

import math
import struct

from .c_abi import NUMFMT_ELEM_BYTES, row_bytes

SOFTWARE_DTYPE_MASK = 0xFB
CANONICAL_NAN = 0x7FC00000


def check_format(numfmt: int, dtype_mask: int = SOFTWARE_DTYPE_MASK) -> None:
    if not isinstance(numfmt, int) or numfmt not in NUMFMT_ELEM_BYTES or numfmt == 2:
        raise ValueError(f'ST_BAD_FMT: unsupported scalar numfmt {numfmt}')
    if not isinstance(dtype_mask, int) or not 0 <= dtype_mask <= 0xFFFF:
        raise ValueError('dtype_mask must be a u16')
    if not dtype_mask & (1 << numfmt):
        raise ValueError(f'ST_BAD_FMT: numfmt {numfmt} not granted by {dtype_mask:#x}')


def layout(m: int, n: int, k: int, numfmt: int, lda=None, ldb=None):
    check_format(numfmt)
    if any(not isinstance(x, int) or not 0 < x <= 0xFFFFFFFF for x in (m, n, k)):
        raise ValueError('dimensions must be positive u32 values')
    lda = k if lda is None else lda
    ldb = k if ldb is None else ldb
    if any(not isinstance(ld, int) or not k <= ld <= 0xFFFF for ld in (lda, ldb)):
        raise ValueError('leading dimensions must be element counts >= K and <= 65535')
    sa, sb, tail = row_bytes(numfmt, lda), row_bytes(numfmt, ldb), row_bytes(numfmt, k)
    return lda, ldb, (m - 1) * sa + tail, (n - 1) * sb + tail, m * n * 4


def validate_buffers(a, b, m, n, k, numfmt, lda=None, ldb=None, dtype_mask=SOFTWARE_DTYPE_MASK):
    check_format(numfmt, dtype_mask)
    if not isinstance(a, (bytes, bytearray, memoryview)) or not isinstance(b, (bytes, bytearray, memoryview)):
        raise TypeError('native operands must be bytes-like, not numeric element sequences')
    a, b = bytes(a), bytes(b)
    lda, ldb, na, nb, nc = layout(m, n, k, numfmt, lda, ldb)
    if len(a) < na or len(b) < nb:
        raise ValueError(f'operand buffer too short: need A={na}, B={nb} bytes')
    return a, b, lda, ldb, na, nb, nc


def _f32(x):
    try:
        return struct.unpack('<f', struct.pack('<f', x))[0]
    except OverflowError:
        return math.copysign(math.inf, x)


def decode_bits(bits: int, numfmt: int):
    check_format(numfmt)
    width = 4 if numfmt == 1 else 8 * NUMFMT_ELEM_BYTES[numfmt]
    if not isinstance(bits, int) or not 0 <= bits < (1 << width):
        raise ValueError('bits exceed native element width')
    if numfmt in (0, 1):
        return bits - (1 << width) if bits & (1 << (width - 1)) else bits
    if numfmt == 7:
        return struct.unpack('<f', struct.pack('<I', bits))[0]
    if numfmt == 6:
        return struct.unpack('<f', struct.pack('<I', bits << 16))[0]
    eb, mb, bias = {3: (4, 3, 7), 4: (5, 2, 15), 5: (5, 10, 15)}[numfmt]
    sign = -1.0 if bits & (1 << (eb + mb)) else 1.0
    exp, mant = (bits >> mb) & ((1 << eb) - 1), bits & ((1 << mb) - 1)
    if numfmt == 3:
        if exp == 15 and mant == 7:
            return math.nan
    elif exp == (1 << eb) - 1:
        return math.nan if mant else math.copysign(math.inf, sign)
    value = math.ldexp(float(mant if exp == 0 else (1 << mb) + mant),
                       (1 if exp == 0 else exp) - bias - mb)
    return math.copysign(value, sign)


# FP8 geometry: (exponent bits, mantissa bits, bias, largest finite code, largest finite value).
FP8_GEOMETRY = {3: (4, 3, 7, 0x7E, 448.0), 4: (5, 2, 15, 0x7B, 57344.0)}


def encode_fp8(values, numfmt: int):
    """Vectorized float -> FP8 (E4M3 = 3, E5M2 = 4) codes as a uint8 array.

    Round-to-nearest-even at the format's precision, subnormals kept, magnitudes
    beyond the largest finite value saturate to it (never to the NaN/Inf codes, which
    the island would propagate). NaN input encodes as the canonical NaN code.
    ``decode_bits(code, numfmt)`` round-trips every code this produces.
    """
    import numpy as np
    eb, mb, bias, max_code, max_val = FP8_GEOMETRY[numfmt]
    x = np.asarray(values, dtype=np.float64)
    sign = (np.signbit(x)).astype(np.uint8) << 7
    mag = np.abs(x)
    nan = np.isnan(mag)
    mag = np.where(nan, 0.0, np.minimum(mag, max_val))
    m, e = np.frexp(mag)              # mag = m * 2**e, m in [0.5, 1)
    e = e - 1                         # exponent of the leading one
    e_min = 1 - bias                  # smallest normal exponent
    sub = e < e_min
    quantum = np.where(sub, 2.0 ** (e_min - mb), 2.0 ** (e - mb))
    q = np.rint(mag / quantum).astype(np.int64)   # RNE; normals give q in [2^mb, 2^(mb+1)]
    # A normal rounding up to 2^(mb+1) is the next binade: exponent +1, mantissa 0.
    carry = (~sub) & (q == (1 << (mb + 1)))
    e = np.where(carry, e + 1, e)
    q = np.where(carry, 1 << mb, q)
    exp_field = np.where(sub, 0, e + bias)
    mant = np.where(sub, q, q - (1 << mb))
    code = (exp_field.astype(np.int64) << mb) | mant.astype(np.int64)
    code = np.minimum(code, max_code)             # saturation after rounding
    code = np.where(mag == 0.0, 0, code)
    nan_code = (1 << (eb + mb)) - 1 if numfmt == 3 else (((1 << eb) - 1) << mb) | 1
    code = np.where(nan, nan_code, code)
    return (code.astype(np.uint8) | sign).astype(np.uint8)


def pack_bits(rows, numfmt: int, ld=None) -> bytes:
    check_format(numfmt)
    rows = [list(row) for row in rows]
    if not rows or not rows[0]:
        raise ValueError('nonempty rows required')
    k = len(rows[0])
    ld = k if ld is None else ld
    layout(len(rows), 1, k, numfmt, ld, k)
    if any(len(row) != k for row in rows):
        raise ValueError('ragged rows')
    out = bytearray(len(rows) * row_bytes(numfmt, ld))
    for i, row in enumerate(rows):
        for t, bits in enumerate(row):
            decode_bits(bits, numfmt)
            off = i * row_bytes(numfmt, ld)
            if numfmt == 1:
                out[off + t // 2] |= bits << (4 * (t % 2))
            else:
                size = NUMFMT_ELEM_BYTES[numfmt]
                off += t * size
                out[off:off + size] = bits.to_bytes(size, 'little')
    return bytes(out)


def _gemm_int_numpy(a, b, m, n, k, numfmt, sa, sb, c_init=None):
    """Vectorized INT8/INT4 GEMM, bit-identical to the scalar loop (exact integer
    arithmetic, u32 wrap). Returns None when NumPy is unavailable."""
    try:
        import numpy as np
    except ImportError:
        return None

    def rows(buf, stride, count):
        need = count * stride
        raw = np.frombuffer(buf if len(buf) >= need else bytes(buf) + bytes(need - len(buf)),
                            dtype=np.uint8)
        mat = np.lib.stride_tricks.as_strided(raw, shape=(count, stride), strides=(stride, 1))
        if numfmt == 1:
            lo = (mat & 0x0F).astype(np.int16)
            hi = (mat >> 4).astype(np.int16)
            nib = np.stack([lo, hi], axis=-1).reshape(count, -1)[:, :k]
            return np.where(nib >= 8, nib - 16, nib).astype(np.int64)
        return mat[:, :k].astype(np.int8).astype(np.int64)

    c = rows(a, sa, m) @ rows(b, sb, n).T
    if c_init is not None:
        c = c + np.frombuffer(bytes(c_init[:m * n * 4]), dtype='<i4').astype(np.int64).reshape(m, n)
    return (c & 0xFFFFFFFF).astype(np.uint32).astype('<u4').tobytes()


def _gemm_float_numpy(a, b, m, n, k, numfmt, sa, sb, c_init=None):
    """Vectorized float GEMM with the island's ordered reduction: for each t, one f32
    multiply then one f32 add. Bit-identical to the scalar fallback below (f64 then
    f32 is innocuous double rounding for binary32 mul/add, 53 >= 2*24+2) and to the
    Rust reference; it only removes the per-element Python cost."""
    try:
        import numpy as np
    except ImportError:
        return None
    size = NUMFMT_ELEM_BYTES[numfmt]

    def rows(buf, stride, count):
        need = count * stride
        raw = np.frombuffer(buf if len(buf) >= need else bytes(buf) + bytes(need - len(buf)),
                            dtype=np.uint8)
        mat = np.lib.stride_tricks.as_strided(raw, shape=(count, stride), strides=(stride, 1))
        elems = mat[:, :k * size].reshape(count, k, size)
        if size == 4:
            return np.ascontiguousarray(elems).view('<u4').reshape(count, k).view('<f4')
        bits = np.ascontiguousarray(elems).view('<u2' if size == 2 else 'u1').reshape(count, k)
        if numfmt == 7:
            return bits.view('<f4')
        if numfmt == 6:
            return (bits.astype(np.uint32) << 16).view('<f4')
        if numfmt == 5:
            return bits.view('<f2').astype(np.float32)
        lut = np.array([decode_bits(v, numfmt) for v in range(256)], dtype=np.float32)
        return lut[bits]

    A, B = rows(a, sa, m), rows(b, sb, n)
    if c_init is None:
        acc = np.zeros((m, n), dtype=np.float32)
    else:
        acc = np.frombuffer(bytes(c_init[:m * n * 4]), dtype='<f4').reshape(m, n).copy()
    with np.errstate(all='ignore'):
        for t in range(k):
            acc = acc + np.multiply.outer(A[:, t], B[:, t]).astype(np.float32, copy=False)
    out = acc.view('<u4').copy()
    out[np.isnan(acc)] = CANONICAL_NAN
    return out.astype('<u4').tobytes()


def gemm_native(a: bytes, b: bytes, m: int, n: int, k: int, numfmt: int,
                lda=None, ldb=None, dtype_mask=SOFTWARE_DTYPE_MASK, c_init=None) -> bytes:
    """Native GEMM. With ``c_init`` (``flags.accmode == 01``) every output's ordered
    reduction starts from the i32/f32 word already stored in C instead of zero, so a
    host K-split is bit-identical to one long ordered reduction."""
    a, b, lda, ldb, _, _, nc = validate_buffers(a, b, m, n, k, numfmt, lda, ldb, dtype_mask)
    sa, sb = row_bytes(numfmt, lda), row_bytes(numfmt, ldb)
    size = NUMFMT_ELEM_BYTES[numfmt]
    if c_init is not None:
        if not isinstance(c_init, (bytes, bytearray, memoryview)) or len(c_init) < nc:
            raise ValueError(f'accumulate seed too short: need C={nc} bytes')
        c_init = bytes(c_init)

    fast = (_gemm_int_numpy if numfmt < 2 else _gemm_float_numpy)(a, b, m, n, k, numfmt, sa, sb, c_init)
    if fast is not None:
        return fast

    def element(buf, off, t):
        if numfmt == 1:
            bits = (buf[off + t // 2] >> (4 * (t % 2))) & 15
        else:
            pos = off + t * size
            bits = int.from_bytes(buf[pos:pos + size], 'little')
        return decode_bits(bits, numfmt)

    out = bytearray(nc)
    for i in range(m):
        for j in range(n):
            acc = 0 if numfmt < 2 else 0.0
            if c_init is not None:
                bits = struct.unpack_from('<I', c_init, (i * n + j) * 4)[0]
                acc = (bits if numfmt < 2 else struct.unpack('<f', struct.pack('<I', bits))[0])
            for t in range(k):
                av, bv = element(a, i * sa, t), element(b, j * sb, t)
                if numfmt < 2:
                    acc = (acc + av * bv) & 0xFFFFFFFF
                else:
                    product = _f32(av * bv)
                    acc = _f32(acc + product)
            bits = acc if numfmt < 2 else (CANONICAL_NAN if math.isnan(acc) else struct.unpack('<I', struct.pack('<f', acc))[0])
            struct.pack_into('<I', out, (i * n + j) * 4, bits)
    return bytes(out)
