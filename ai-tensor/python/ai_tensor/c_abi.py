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
FLAG_IRQ = 1 << 2

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
