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


def gemm_native(a: bytes, b: bytes, m: int, n: int, k: int, numfmt: int,
                lda=None, ldb=None, dtype_mask=SOFTWARE_DTYPE_MASK) -> bytes:
    a, b, lda, ldb, _, _, nc = validate_buffers(a, b, m, n, k, numfmt, lda, ldb, dtype_mask)
    sa, sb = row_bytes(numfmt, lda), row_bytes(numfmt, ldb)
    size = NUMFMT_ELEM_BYTES[numfmt]

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
