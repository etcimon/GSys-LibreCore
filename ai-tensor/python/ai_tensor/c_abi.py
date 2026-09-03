# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Constants and pack helpers aligned with include/ai_tensor.h (no ctypes required)."""

from __future__ import annotations

import struct
from pathlib import Path

DESC_BYTES = 64
CONTRACT_VERSION = 1
OP_GEMM = 1
ST_OK = 0
ST_BAD_PTR = 4
ST_BAD_QID = 5
ST_DISABLED = 6
ST_BAD_FMT = 8
FLAG_IRQ = 1 << 2

# Numeric-format selector inside Desc64.flags, at flags[22:20].
#
# Mirrors g6lc_ai_desc_pkg FLAG_NUMFMT_SHIFT/WIDTH. `ew` and `dtype` describe only integers
# (a width and a signedness), so BF16 and the FP8 variants have no encoding without this
# field. It sits in previously reserved bits with AI_FMT_INT == 0, so a descriptor built
# before the field existed keeps its exact prior meaning and CONTRACT_VERSION stays 1.
FLAG_NUMFMT_SHIFT = 20
FLAG_NUMFMT_WIDTH = 3
FLAG_NUMFMT_MASK = (1 << FLAG_NUMFMT_WIDTH) - 1

# config_pkg::AI_FMT_* — the ABI value is also the grant-mask bit index, so a grant check is
# a shift-and-test rather than a lookup table that can drift from the hardware's copy.
AI_FMT_INT = 0
AI_FMT_INT4 = 1
AI_FMT_SP24 = 2
AI_FMT_FP8_E4M3 = 3
AI_FMT_FP8_E5M2 = 4
AI_FMT_FP16 = 5
AI_FMT_BF16 = 6
AI_FMT_FP32 = 7

NUMFMT_NAMES = {
    AI_FMT_INT: "int",
    AI_FMT_INT4: "int4",
    AI_FMT_SP24: "sp24",
    AI_FMT_FP8_E4M3: "fp8e4m3",
    AI_FMT_FP8_E5M2: "fp8e5m2",
    AI_FMT_FP16: "fp16",
    AI_FMT_BF16: "bf16",
    AI_FMT_FP32: "fp32",
}

# Framework dtype spelling -> ABI format. Torch and NumPy names both appear because a caller
# may hold either; `torch.bfloat16` stringifies to "torch.bfloat16" and numpy to "float32".
#
# The map is deliberately NOT total over framework dtypes: an unmapped dtype must raise
# rather than be approximated by a nearby format, because a GEMM computed in the wrong
# arithmetic returns plausible numbers that nothing downstream can detect.
DTYPE_TO_NUMFMT = {
    "int8": AI_FMT_INT,
    "torch.int8": AI_FMT_INT,
    "int4": AI_FMT_INT4,
    "float8_e4m3fn": AI_FMT_FP8_E4M3,
    "torch.float8_e4m3fn": AI_FMT_FP8_E4M3,
    "float8_e5m2": AI_FMT_FP8_E5M2,
    "torch.float8_e5m2": AI_FMT_FP8_E5M2,
    "float16": AI_FMT_FP16,
    "torch.float16": AI_FMT_FP16,
    "half": AI_FMT_FP16,
    "bfloat16": AI_FMT_BF16,
    "torch.bfloat16": AI_FMT_BF16,
    "float32": AI_FMT_FP32,
    "torch.float32": AI_FMT_FP32,
    "float": AI_FMT_FP32,
}

# Operand bytes per element; None means sub-byte (packed).
NUMFMT_ELEM_BYTES = {
    AI_FMT_INT: 1,
    AI_FMT_SP24: 1,
    AI_FMT_FP8_E4M3: 1,
    AI_FMT_FP8_E5M2: 1,
    AI_FMT_FP16: 2,
    AI_FMT_BF16: 2,
    AI_FMT_FP32: 4,
    AI_FMT_INT4: None,
}


def numfmt_of_dtype(dtype) -> int:
    """Map a framework dtype to its ABI numeric format.

    Raises `ValueError` for a dtype with no ABI encoding. Refusing is the point: silently
    substituting a nearby format would produce a numerically plausible wrong result.
    """
    key = str(dtype)
    if key in DTYPE_TO_NUMFMT:
        return DTYPE_TO_NUMFMT[key]
    # `numpy.dtype('float32')` stringifies to "float32", but a torch dtype may arrive as a
    # bare attribute; fall back to its trailing component before giving up.
    tail = key.rsplit(".", 1)[-1]
    if tail in DTYPE_TO_NUMFMT:
        return DTYPE_TO_NUMFMT[tail]
    raise ValueError(
        f"dtype {dtype!r} has no Xg6lcai numeric format; "
        f"supported: {sorted(set(DTYPE_TO_NUMFMT))}"
    )


def numfmt_flags(numfmt: int, flags: int = 0) -> int:
    """Place `numfmt` into a flags word, clearing any previous value."""
    if not 0 <= numfmt <= FLAG_NUMFMT_MASK:
        raise ValueError(f"numfmt {numfmt} does not fit {FLAG_NUMFMT_WIDTH} bits")
    return (flags & ~(FLAG_NUMFMT_MASK << FLAG_NUMFMT_SHIFT)) | (
        numfmt << FLAG_NUMFMT_SHIFT
    )


def numfmt_from_flags(flags: int) -> int:
    """Read the numeric format out of a flags word."""
    return (flags >> FLAG_NUMFMT_SHIFT) & FLAG_NUMFMT_MASK


def numfmt_granted(dtype_mask: int, numfmt: int) -> bool:
    """Does an island publishing `dtype_mask` at CAP_DTYPE_MASK grant `numfmt`?

    The capability window is the discovery authority, so callers ask rather than assume:
    submitting an ungranted format returns ST_BAD_FMT and the island will not demote it.
    """
    return (dtype_mask >> numfmt) & 1 == 1


def row_bytes(numfmt: int, n: int) -> int:
    """Bytes spanned by `n` consecutive elements of `numfmt`.

    A packed INT4 row is half an INT8 row and an FP32 row four times as long, so a tiler
    that strides by elements rather than bytes overlaps or gaps its rows.
    """
    per = NUMFMT_ELEM_BYTES[numfmt]
    if per is None:
        return (n + 1) // 2
    return n * per

MMIO_CTL = 0x0100
MMIO_DOORBELL = 0x0108
MMIO_DONE = 0x010C
MMIO_DESC = 0x0140
MMIO_PMU_R = 0x0180

CTL_ENABLE = 1 << 0
CTL_WR_CPL_EN = 1 << 1
PLIC_SOURCE_ISLAND_P3 = 8


def header_path() -> Path:
    return Path(__file__).resolve().parents[2] / "include" / "ai_tensor.h"


def pack_desc64(
    m: int,
    n: int,
    k: int,
    ptr_a: int = 0,
    ptr_b: int = 0,
    ptr_c: int = 0,
    ptr_done: int = 0,
    flags: int = 0,
) -> bytes:
    """Pack LE Desc64 matching C/Rust layout."""
    ld_ab = (k & 0xFFFF) | ((n & 0xFFFF) << 16)
    return struct.pack(
        "<HHI IIII QQQQQ",
        CONTRACT_VERSION,
        OP_GEMM,
        flags,
        m,
        n,
        k,
        ld_ab,
        ptr_a,
        ptr_b,
        ptr_c,
        0,
        ptr_done,
    )


def completion_make(ticket: int, status: int = ST_OK) -> int:
    return (int(status) << 32) | (int(ticket) & 0xFFFFFFFF)


def verify_header_present() -> bool:
    return header_path().is_file()
