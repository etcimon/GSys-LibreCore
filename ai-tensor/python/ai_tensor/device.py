# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Device facade: prefers native sim, pure-Python fallback for bring-up."""

from __future__ import annotations

from typing import List, Optional, Sequence, Tuple, Union

import struct

# --- pure Python ABI (fallback; must match ai-tensor-abi) ---
DESC_BYTES = 64
CONTRACT_VERSION = 1
OP_GEMM = 1
ST_OK = 0


def pack_gemm_desc(
    m: int,
    n: int,
    k: int,
    ptr_a: int = 0x1000,
    ptr_b: int = 0x2000,
    ptr_c: int = 0x3000,
    ptr_done: int = 0x4000,
    flags: int = 0,
) -> bytes:
    """Pack a 64-byte LE GEMM descriptor (island layout)."""
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
        0,  # scale
        ptr_done,
    )


def _try_native():
    try:
        import ai_tensor_native  # type: ignore

        return ai_tensor_native
    except ImportError:
        return None


class Device:
    """Sim device (native or pure-Python reference GEMM)."""

    def __init__(self, backend: str = "sim"):
        if backend != "sim":
            raise ValueError("only backend='sim' is implemented in M2–M4")
        self._native = _try_native()
        self._sim = self._native.Sim() if self._native else None
        self.backend = "sim-native" if self._sim else "sim-python"

    def gemm_s8(
        self,
        m: int,
        n: int,
        k: int,
        a: Sequence[int],
        b: Sequence[int],
        ticket: int = 1,
    ) -> Tuple[List[int], int, int]:
        """Return (c_i32_list, ticket, status)."""
        a8 = [int(x) for x in a]
        b8 = [int(x) for x in b]
        if self._sim is not None:
            return self._sim.gemm_s8(m, n, k, a8, b8, ticket)
        return _python_gemm_s8(m, n, k, a8, b8, ticket)


def gemm_s8(
    m: int,
    n: int,
    k: int,
    a: Sequence[int],
    b: Sequence[int],
    ticket: int = 1,
    device: Optional[Device] = None,
) -> Tuple[List[int], int, int]:
    dev = device or Device("sim")
    return dev.gemm_s8(m, n, k, a, b, ticket)


def _python_gemm_s8(
    m: int, n: int, k: int, a: List[int], b: List[int], ticket: int
) -> Tuple[List[int], int, int]:
    """Reference path when native module is not built."""
    assert len(a) >= m * k and len(b) >= k * n
    c: List[int] = []
    for i in range(m):
        for j in range(n):
            acc = 0
            for t in range(k):
                acc += int(a[i * k + t]) * int(b[t * n + j])
            c.append(acc)
    return c, ticket, ST_OK
