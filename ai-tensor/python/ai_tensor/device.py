# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Device facade: native sim/mmio-soft, pure-Python fallback + host tiling."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

import struct

# --- pure Python ABI (fallback; must match ai-tensor-abi) ---
DESC_BYTES = 64
CONTRACT_VERSION = 1
OP_GEMM = 1
ST_OK = 0

# island_p3 defaults (Phase A pin)
DEFAULT_ACC_TILE = (256, 256, 256)
DEFAULT_MACS = 256
DEFAULT_NOC_WIDTH = 64


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


@dataclass(frozen=True)
class Caps:
    """Software view of CAP / profile geometry."""

    acc_tile_m: int = 256
    acc_tile_n: int = 256
    acc_tile_k: int = 256
    macs_per_cycle: int = 256
    noc_width: int = 64
    clusters: int = 1
    compute_ref: bool = True

    def as_dict(self) -> Dict[str, Any]:
        return {
            "acc_tile_m": self.acc_tile_m,
            "acc_tile_n": self.acc_tile_n,
            "acc_tile_k": self.acc_tile_k,
            "macs_per_cycle": self.macs_per_cycle,
            "noc_width": self.noc_width,
            "clusters": self.clusters,
            "compute_ref": self.compute_ref,
        }

    def fits(self, m: int, n: int, k: int) -> bool:
        return m <= self.acc_tile_m and n <= self.acc_tile_n and k <= self.acc_tile_k


@dataclass(frozen=True)
class Pmu:
    r_beats: int = 0
    w_beats: int = 0
    cycles: int = 0
    gbps_x1000: int = 0

    def as_dict(self) -> Dict[str, int]:
        return {
            "r_beats": self.r_beats,
            "w_beats": self.w_beats,
            "cycles": self.cycles,
            "gbps_x1000": self.gbps_x1000,
        }


def tile_gemm(
    m: int, n: int, k: int, tile_m: int, tile_n: int, tile_k: int
) -> List[Tuple[int, int, int, int, int, int]]:
    """Yield (i0, j0, t0, tm, tn, tk) AccTile-sized blocks (same order as Rust IR)."""
    out: List[Tuple[int, int, int, int, int, int]] = []
    if m == 0 or n == 0 or k == 0:
        return out
    i = 0
    while i < m:
        tm = min(tile_m, m - i)
        j = 0
        while j < n:
            tn = min(tile_n, n - j)
            t = 0
            while t < k:
                tk = min(tile_k, k - t)
                out.append((i, j, t, tm, tn, tk))
                t += tk
            j += tn
        i += tm
    return out


def _try_native():
    try:
        import ai_tensor_native  # type: ignore

        return ai_tensor_native
    except ImportError:
        return None


class Device:
    """
    Host device facade.

    backend:
      - ``sim``: direct sim (native or pure-Python)
      - ``mmio`` / ``mmio-soft``: SoftIsland MMIO protocol (native required)
    """

    def __init__(self, backend: str = "sim"):
        be = backend.lower().replace("_", "-")
        if be in ("mmio-soft", "mmio"):
            be = "mmio"
        if be not in ("sim", "mmio"):
            raise ValueError("backend must be 'sim' or 'mmio'/'mmio-soft'")
        self._native = _try_native()
        self._dev = None
        self._caps = Caps()
        self._last_pmu = Pmu()
        self.backend = be

        if be == "sim":
            if self._native is not None and hasattr(self._native, "Sim"):
                self._dev = self._native.Sim()
                self.backend = "sim-native"
                self._refresh_caps_native()
            else:
                self.backend = "sim-python"
        else:
            if self._native is None or not hasattr(self._native, "Mmio"):
                raise RuntimeError(
                    "backend='mmio' requires ai_tensor_native.Mmio "
                    "(build: cargo build -p ai-tensor-py && install module)"
                )
            self._dev = self._native.Mmio()
            self.backend = "mmio-soft-native"
            if hasattr(self._dev, "probe_caps"):
                self._dev.probe_caps()
            self._refresh_caps_native()

    def _refresh_caps_native(self) -> None:
        if self._dev is None or not hasattr(self._dev, "caps"):
            return
        d = self._dev.caps()
        self._caps = Caps(
            acc_tile_m=int(d.get("acc_tile_m", 256)),
            acc_tile_n=int(d.get("acc_tile_n", 256)),
            acc_tile_k=int(d.get("acc_tile_k", 256)),
            macs_per_cycle=int(d.get("macs_per_cycle", 256)),
            noc_width=int(d.get("noc_width", 64)),
            clusters=int(d.get("clusters", 1)),
            compute_ref=bool(d.get("compute_ref", True)),
        )

    def caps(self) -> Caps:
        return self._caps

    def pmu(self) -> Pmu:
        if self._dev is not None and hasattr(self._dev, "pmu"):
            d = self._dev.pmu()
            self._last_pmu = Pmu(
                r_beats=int(d.get("r_beats", 0)),
                w_beats=int(d.get("w_beats", 0)),
                cycles=int(d.get("cycles", 0)),
                gbps_x1000=int(d.get("gbps_x1000", 0)),
            )
        return self._last_pmu

    def gemm_s8(
        self,
        m: int,
        n: int,
        k: int,
        a: Sequence[int],
        b: Sequence[int],
        ticket: int = 1,
        *,
        auto_tile: bool = True,
    ) -> Tuple[List[int], int, int, Dict[str, Any]]:
        """
        INT8 GEMM → i32 C.

        Returns ``(c_list, ticket, status, meta)`` where meta includes caps/pmu/tiles.
        If dims exceed AccTile and ``auto_tile``, streams tiled jobs and accumulates.
        """
        a8 = [int(x) for x in a]
        b8 = [int(x) for x in b]
        caps = self.caps()
        meta: Dict[str, Any] = {
            "backend": self.backend,
            "caps": caps.as_dict(),
            "tiles": 1,
            "auto_tile": False,
        }

        if caps.fits(m, n, k) or not auto_tile:
            c, tix, status = self._gemm_one(m, n, k, a8, b8, ticket)
            meta["pmu"] = self.pmu().as_dict()
            return c, tix, status, meta

        # Host-side tiling (AccTile stream); accumulate partials into C
        meta["auto_tile"] = True
        c = [0] * (m * n)
        tix = ticket
        status = ST_OK
        tiles = tile_gemm(
            m, n, k, caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k
        )
        meta["tiles"] = len(tiles)
        last_ticket = ticket
        for i0, j0, t0, tm, tn, tk in tiles:
            a_tile = _slice_a(a8, m, k, i0, t0, tm, tk)
            b_tile = _slice_b(b8, k, n, t0, j0, tk, tn)
            partial, last_ticket, status = self._gemm_one(
                tm, tn, tk, a_tile, b_tile, tix
            )
            if status != ST_OK:
                meta["pmu"] = self.pmu().as_dict()
                return c, last_ticket, status, meta
            for ii in range(tm):
                for jj in range(tn):
                    c[(i0 + ii) * n + (j0 + jj)] += partial[ii * tn + jj]
            tix = last_ticket + 1
        meta["pmu"] = self.pmu().as_dict()
        return c, last_ticket, status, meta

    def _gemm_one(
        self,
        m: int,
        n: int,
        k: int,
        a8: List[int],
        b8: List[int],
        ticket: int,
    ) -> Tuple[List[int], int, int]:
        if self._dev is not None:
            return self._dev.gemm_s8(m, n, k, a8, b8, ticket)
        return _python_gemm_s8(m, n, k, a8, b8, ticket)


def gemm_s8(
    m: int,
    n: int,
    k: int,
    a: Sequence[int],
    b: Sequence[int],
    ticket: int = 1,
    device: Optional[Device] = None,
    auto_tile: bool = True,
) -> Tuple[List[int], int, int, Dict[str, Any]]:
    dev = device or Device("sim")
    return dev.gemm_s8(m, n, k, a, b, ticket, auto_tile=auto_tile)


def _slice_a(a: List[int], m: int, k: int, i0: int, t0: int, tm: int, tk: int) -> List[int]:
    out: List[int] = []
    for i in range(tm):
        row = (i0 + i) * k + t0
        out.extend(a[row : row + tk])
    return out


def _slice_b(b: List[int], k: int, n: int, t0: int, j0: int, tk: int, tn: int) -> List[int]:
    out: List[int] = []
    for t in range(tk):
        row = (t0 + t) * n + j0
        out.extend(b[row : row + tn])
    return out


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
