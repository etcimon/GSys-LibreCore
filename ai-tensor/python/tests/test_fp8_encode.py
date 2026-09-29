# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""encode_fp8 against a brute-force nearest-code oracle built from decode_bits."""

import math
import random

import numpy as np
import pytest

from ai_tensor.numfmt import FP8_GEOMETRY, decode_bits, encode_fp8


def _oracle(x, numfmt):
    eb, mb, bias, max_code, max_val = FP8_GEOMETRY[numfmt]
    if math.isnan(x):
        return None
    finite = [c for c in range(128) if not math.isnan(decode_bits(c, numfmt)) and not math.isinf(decode_bits(c, numfmt))]
    mag = min(abs(x), max_val)
    best = min(finite, key=lambda c: (abs(decode_bits(c, numfmt) - mag), c & 1))  # ties -> even mantissa
    return best | (0x80 if x < 0 or (x == 0 and math.copysign(1, x) < 0) else 0)


@pytest.mark.parametrize("numfmt", [3, 4])
def test_every_code_round_trips(numfmt):
    for c in range(256):
        v = decode_bits(c, numfmt)
        if math.isnan(v) or math.isinf(v):
            continue
        assert int(encode_fp8([v], numfmt)[0]) == c or (v == 0 and int(encode_fp8([v], numfmt)[0]) & 0x7F == 0)


@pytest.mark.parametrize("numfmt", [3, 4])
def test_random_values_match_nearest_even_oracle(numfmt):
    rng = random.Random(numfmt)
    _, _, _, _, max_val = FP8_GEOMETRY[numfmt]
    xs = [rng.uniform(-2 * max_val, 2 * max_val) for _ in range(400)]
    xs += [rng.uniform(-1e-3, 1e-3) for _ in range(300)]          # subnormal region
    xs += [rng.choice([-1, 1]) * 2.0 ** rng.uniform(-12, 10) for _ in range(300)]
    # exact midpoints between adjacent codes must round to even
    for c in range(0, 120, 7):
        a, b = decode_bits(c, numfmt), decode_bits(c + 1, numfmt)
        if not (math.isnan(a) or math.isnan(b) or math.isinf(a) or math.isinf(b)):
            xs.append((a + b) / 2)
    codes = encode_fp8(xs, numfmt)
    for x, c in zip(xs, codes):
        assert int(c) == _oracle(x, numfmt), (numfmt, x, int(c), _oracle(x, numfmt))


def test_nan_and_saturation_never_emit_inf_or_nan_codes_for_finite_input():
    for numfmt in (3, 4):
        codes = encode_fp8([1e9, -1e9, float("inf"), -float("inf")], numfmt)
        for c in codes:
            v = decode_bits(int(c), numfmt)
            assert math.isfinite(v)
        assert math.isnan(decode_bits(int(encode_fp8([float("nan")], numfmt)[0]), numfmt))
