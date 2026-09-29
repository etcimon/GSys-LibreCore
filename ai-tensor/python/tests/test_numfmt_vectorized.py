# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""The NumPy-vectorized software reference must be bit-identical to the scalar loop for
every format, including NaN/Inf bit patterns, ragged leading dimensions and odd K."""

import random

import pytest

np = pytest.importorskip("numpy")

from ai_tensor import numfmt as nf  # noqa: E402


def _scalar(a, b, m, n, k, fmt, lda, ldb):
    saved = (nf._gemm_int_numpy, nf._gemm_float_numpy)
    nf._gemm_int_numpy = nf._gemm_float_numpy = lambda *x: None
    try:
        return nf.gemm_native(a, b, m, n, k, fmt, lda, ldb)
    finally:
        nf._gemm_int_numpy, nf._gemm_float_numpy = saved


@pytest.mark.parametrize("fmt", [0, 1, 3, 4, 5, 6, 7])
def test_vectorized_reference_is_bit_identical(fmt):
    rng = random.Random(100 + fmt)
    width = 4 if fmt == 1 else 8 * nf.NUMFMT_ELEM_BYTES[fmt]
    for _ in range(25):
        m, n, k = rng.randint(1, 7), rng.randint(1, 7), rng.randint(1, 33)
        lda, ldb = k + rng.randint(0, 3), k + rng.randint(0, 3)
        A = [[rng.randrange(1 << width) for _ in range(lda)] for _ in range(m)]
        B = [[rng.randrange(1 << width) for _ in range(ldb)] for _ in range(n)]
        a = nf.pack_bits(A, fmt)[:(m - 1) * nf.row_bytes(fmt, lda) + nf.row_bytes(fmt, k)]
        b = nf.pack_bits(B, fmt)[:(n - 1) * nf.row_bytes(fmt, ldb) + nf.row_bytes(fmt, k)]
        assert nf.gemm_native(a, b, m, n, k, fmt, lda, ldb) == _scalar(a, b, m, n, k, fmt, lda, ldb)
