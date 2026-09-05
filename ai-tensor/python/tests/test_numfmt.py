# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Numeric-format lowering: framework dtype -> Desc64 flags[22:20] -> grant check.

These tests pin the *contract*, not an implementation detail. The values must agree with
three other places at once — `config_pkg::AI_FMT_*`, `g6lc_ai_desc_pkg::FLAG_NUMFMT_*`, and
`ai_tensor_abi::NumFmt` — and a silent disagreement between any two of them shows up as a
GEMM computed in the wrong arithmetic, which returns plausible numbers.
"""

from __future__ import annotations

import pytest

from ai_tensor.c_abi import (
    AI_FMT_BF16,
    AI_FMT_FP8_E4M3,
    AI_FMT_FP8_E5M2,
    AI_FMT_FP16,
    AI_FMT_FP32,
    AI_FMT_INT,
    AI_FMT_INT4,
    AI_FMT_SP24,
    CONTRACT_VERSION,
    FLAG_IRQ,
    FLAG_NUMFMT_MASK,
    FLAG_NUMFMT_SHIFT,
    FLAG_NUMFMT_WIDTH,
    NUMFMT_NAMES,
    ST_BAD_FMT,
    numfmt_flags,
    numfmt_from_flags,
    numfmt_granted,
    numfmt_of_dtype,
    pack_desc64,
    row_bytes,
)

ALL_FORMATS = [
    AI_FMT_INT,
    AI_FMT_INT4,
    AI_FMT_SP24,
    AI_FMT_FP8_E4M3,
    AI_FMT_FP8_E5M2,
    AI_FMT_FP16,
    AI_FMT_BF16,
    AI_FMT_FP32,
]


def test_field_position_matches_the_design_package():
    # flags[22:20]: 3 bits at shift 20. Pinned because the emulator, the RTL and this file
    # each decode the same word.
    assert FLAG_NUMFMT_SHIFT == 20
    assert FLAG_NUMFMT_WIDTH == 3
    assert FLAG_NUMFMT_MASK == 0x7


def test_integer_is_the_all_zero_encoding():
    """AI_FMT_INT must be 0, or every pre-numfmt descriptor changes meaning.

    This is what makes the field an extension into reserved space rather than a contract
    version bump, so CONTRACT_VERSION staying 1 depends on it.
    """
    assert AI_FMT_INT == 0
    assert numfmt_from_flags(0) == AI_FMT_INT
    assert CONTRACT_VERSION == 2


def test_abi_values_are_dense_and_named():
    assert ALL_FORMATS == list(range(8))
    for f in ALL_FORMATS:
        assert f in NUMFMT_NAMES, f"format {f} has no wire name"
    assert len(set(NUMFMT_NAMES.values())) == len(NUMFMT_NAMES), "names must be unique"


@pytest.mark.parametrize("fmt", ALL_FORMATS)
def test_flags_round_trip(fmt):
    assert numfmt_from_flags(numfmt_flags(fmt)) == fmt


def test_numfmt_does_not_disturb_other_flags():
    """The IRQ bit shares the word, so writing a format must not clear it."""
    flags = numfmt_flags(AI_FMT_BF16, FLAG_IRQ)
    assert flags & FLAG_IRQ == FLAG_IRQ
    assert numfmt_from_flags(flags) == AI_FMT_BF16
    # Overwriting the format must not accumulate old values either.
    flags = numfmt_flags(AI_FMT_FP32, flags)
    assert numfmt_from_flags(flags) == AI_FMT_FP32
    assert flags & FLAG_IRQ == FLAG_IRQ


def test_a_format_outside_the_field_is_refused():
    with pytest.raises(ValueError):
        numfmt_flags(8)
    with pytest.raises(ValueError):
        numfmt_flags(-1)


@pytest.mark.parametrize(
    "dtype,want",
    [
        ("int8", AI_FMT_INT),
        ("torch.int8", AI_FMT_INT),
        ("int4", AI_FMT_INT4),
        ("float8_e4m3fn", AI_FMT_FP8_E4M3),
        ("torch.float8_e4m3fn", AI_FMT_FP8_E4M3),
        ("float8_e5m2", AI_FMT_FP8_E5M2),
        ("float16", AI_FMT_FP16),
        ("torch.float16", AI_FMT_FP16),
        ("bfloat16", AI_FMT_BF16),
        ("torch.bfloat16", AI_FMT_BF16),
        ("float32", AI_FMT_FP32),
        ("torch.float32", AI_FMT_FP32),
    ],
)
def test_framework_dtype_names_map_to_the_abi(dtype, want):
    assert numfmt_of_dtype(dtype) == want


def test_an_unmapped_dtype_raises_rather_than_approximating():
    """A dtype with no ABI encoding must fail loudly.

    Substituting a nearby format is the failure mode this whole field exists to prevent: the
    GEMM would succeed and return numbers computed in arithmetic the caller did not ask for.
    """
    for dtype in ["float64", "torch.float64", "complex64", "int16", "uint8"]:
        with pytest.raises(ValueError, match="no Xg6lcai numeric format"):
            numfmt_of_dtype(dtype)


def test_grant_check_against_the_live_mask():
    """The live island publishes 0x0003 — dense INT8 + INT4 (F1).

    INT4 joined the grant only once the PE unpacked two sign-extended nibbles per byte
    through the existing signed 8x8 cell, the reduction widened to 2*Lanes, and both
    loaders started counting bytes against ``ceil(k/2)``. The float formats are still
    ungranted because their accumulator paths (F2-F5) do not exist.

    This mirrors ``AiIslandDtypeMask``; if the two drift, a host plans around a format
    the island then refuses with ``ST_BAD_FMT``.
    """
    live = 0x0003
    granted = {AI_FMT_INT, AI_FMT_INT4}
    for fmt in granted:
        assert numfmt_granted(live, fmt), f"{NUMFMT_NAMES[fmt]} must be granted"
    for fmt in ALL_FORMATS:
        if fmt not in granted:
            assert not numfmt_granted(live, fmt), f"{NUMFMT_NAMES[fmt]} is not granted"


@pytest.mark.parametrize("fmt", ALL_FORMATS)
def test_each_format_is_granted_only_by_its_own_bit(fmt):
    """One bit at a time, so a wrong-bit implementation cannot pass.

    A test that only checked "nothing beyond INT8" would accept an implementation that
    granted the wrong format.
    """
    only = 1 << fmt
    assert numfmt_granted(only, fmt)
    everything_else = 0xFF & ~only
    assert not numfmt_granted(everything_else, fmt)


def test_row_bytes_track_packing():
    assert row_bytes(AI_FMT_INT, 8) == 8
    assert row_bytes(AI_FMT_INT4, 8) == 4, "two elements per byte"
    assert row_bytes(AI_FMT_INT4, 7) == 4, "odd length rounds up"
    assert row_bytes(AI_FMT_FP8_E4M3, 8) == 8
    assert row_bytes(AI_FMT_FP16, 8) == 16
    assert row_bytes(AI_FMT_BF16, 8) == 16
    assert row_bytes(AI_FMT_FP32, 8) == 32


def test_a_packed_descriptor_carries_the_format():
    """End to end: the format must survive into the 64-byte image the island reads."""
    import struct

    flags = numfmt_flags(AI_FMT_BF16, FLAG_IRQ)
    blob = pack_desc64(m=4, n=4, k=4, flags=flags)
    assert len(blob) == 64
    # flags is the third field: u16 version, u16 op, u32 flags.
    (got_flags,) = struct.unpack_from("<I", blob, 4)
    assert numfmt_from_flags(got_flags) == AI_FMT_BF16
    assert got_flags & FLAG_IRQ == FLAG_IRQ


def test_bad_fmt_status_is_distinct():
    """ST_BAD_FMT must not collide with the statuses it needs to be told apart from."""
    from ai_tensor.c_abi import ST_BAD_PTR, ST_BAD_QID, ST_DISABLED, ST_OK

    assert ST_BAD_FMT == 8
    assert len({ST_OK, ST_BAD_PTR, ST_BAD_QID, ST_DISABLED, ST_BAD_FMT}) == 5
