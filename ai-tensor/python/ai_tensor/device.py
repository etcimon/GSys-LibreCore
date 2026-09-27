# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Device facade: native sim/mmio-soft, virt-card PCIe virtual, pure-Python fallback."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

import struct

# --- pure Python ABI (fallback; must match ai-tensor-abi) ---
DESC_BYTES = 64
CONTRACT_VERSION = 2
OP_GEMM = 1
ST_OK = 0

# island_p3 box. MAC issue stays 512; this constant is the accumulator bound.
DEFAULT_ACC_TILE = (1024, 512, 512)
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
    *,
    lda: int | None = None,
    ldb: int | None = None,
) -> bytes:
    """Pack a 64-byte LE GEMM descriptor (island layout)."""
    from .c_abi import pack_desc64
    validated = pack_desc64(m, n, k, ptr_a, ptr_b, ptr_c, ptr_done, flags, lda=lda, ldb=ldb)
    ld_ab = struct.unpack_from('<I', validated, 20)[0]
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

    acc_tile_m: int = 1024
    acc_tile_n: int = 512
    acc_tile_k: int = 512
    macs_per_cycle: int = 512
    noc_width: int = 64
    clusters: int = 1
    compute_ref: bool = True
    dtype_mask: int = 1

    def as_dict(self) -> Dict[str, Any]:
        return {
            "acc_tile_m": self.acc_tile_m,
            "acc_tile_n": self.acc_tile_n,
            "acc_tile_k": self.acc_tile_k,
            "macs_per_cycle": self.macs_per_cycle,
            "noc_width": self.noc_width,
            "clusters": self.clusters,
            "compute_ref": self.compute_ref,
            "dtype_mask": self.dtype_mask,
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


def va_panels(macs: int) -> List[Tuple[int, int, int]]:
    """Named VA panels at this MAC issue width. Empty unless macs is a multiple of 4."""
    if macs < 4 or macs % 4:
        return []
    half = macs // 2
    quarter = macs // 4
    return [(macs, macs, macs), (macs, half, macs), (macs * 2, quarter, macs)]


def _div_ceil(n: int, d: int) -> int:
    return (n + d - 1) // d


def choose_va_blocking(
    m: int, n: int, k: int, cap_m: int, cap_n: int, cap_k: int, macs: int
) -> Tuple[int, int, int]:
    """Panel inside the cap with the fewest tiles, then the most exact panels, then wider N.

    A cap the panels do not fit returns the cap itself.
    """
    best = None
    for pm, pn, pk in va_panels(macs):
        if pm > cap_m or pn > cap_n or pk > cap_k or min(pm, pn, pk) <= 0:
            continue
        tm, tn, tk = _div_ceil(m, pm), _div_ceil(n, pn), _div_ceil(k, pk)
        tiles = tm * tn * tk
        exact_m = tm if m % pm == 0 else tm - 1
        exact_n = tn if n % pn == 0 else tn - 1
        named = exact_m * exact_n * tk
        score = (tiles, -named, -pn)
        if best is None or score < best[0]:
            best = (score, (pm, pn, pk))
    if best is None:
        return cap_m, cap_n, cap_k
    return best[1]


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


def _normalize_backend(backend: str) -> str:
    be = backend.lower().replace("_", "-")
    if be in ("mmio-soft", "mmio"):
        return "mmio"
    if be in (
        "virt-card",
        "virt",
        "virt-ai",
        "virt-ai-pcie",
        "pcie-virt",
        "virtual-pcie",
    ):
        return "virt-card"
    if be in ("qemu-uio", "uio", "linux-uio-real", "guest-uio"):
        return "qemu-uio"
    if be in ('sim', 'software-reference-v2'):
        return be
    raise ValueError(
        "backend must be 'sim', 'mmio'/'mmio-soft', 'virt-card' or 'qemu-uio' "
        f"(got {backend!r})"
    )


def _env_backend_default() -> str:
    """Resolve default backend from env (board-aware)."""
    be = os.environ.get("AI_TENSOR_BACKEND", "").strip()
    if be:
        try:
            return _normalize_backend(be)
        except ValueError:
            pass
    board = os.environ.get("AI_TENSOR_BOARD_ID", "").strip().lower()
    if board in ("virt-ai-pcie", "virt-ai", "virt_ai_pcie"):
        return "virt-card"
    uio = os.environ.get("AI_TENSOR_UIO", "").strip()
    if uio.startswith("virt://"):
        return "virt-card"
    # A real UIO node plus a guest-physical operand window means we are inside a guest
    # talking to an actual island, not to a host-side stand-in.
    if uio.startswith("/dev/") and os.environ.get("AI_TENSOR_DMA_BASE", "").strip():
        return "qemu-uio"
    return "sim"


class Device:
    """
    Host device facade.

    backend:
      - ``sim``: direct sim (native or pure-Python)
      - ``mmio`` / ``mmio-soft``: SoftIsland MMIO protocol (native required)
      - ``virt-card``: virtual PCIe AI board (soft UIO/eventfd; local or TCP agent)
      - ``qemu-uio``: in-guest UIO against a real island (emulator or hardware)
    """

    def __init__(
        self,
        backend: Optional[str] = None,
        *,
        caps: Optional[Caps] = None,
        board_id: Optional[str] = None,
        virt_mode: Optional[str] = None,
        session: Optional[Any] = None,
    ):
        if backend is None or backend == "":
            be = _env_backend_default()
        else:
            be = _normalize_backend(backend)
        self._native = _try_native()
        self._dev = None
        self._virt = None
        self._uio = None
        self._caps = caps or Caps()
        self._last_pmu = Pmu()
        self.backend = be
        self.profile_id: Optional[str] = None
        self.board_id: Optional[str] = board_id or os.environ.get(
            "AI_TENSOR_BOARD_ID"
        )

        if be == 'software-reference-v2':
            self._native = None
            self._caps = caps or Caps(dtype_mask=0xfb)
            self.backend = 'software-reference-v2'
        elif be == "sim":
            if self._native is not None and hasattr(self._native, "Sim"):
                if getattr(self._native, 'CONTRACT_VERSION', None) != CONTRACT_VERSION:
                    raise RuntimeError('native extension must be rebuilt for Desc64 v2')
                self._dev = self._native.Sim(software_reference=bool(caps and caps.dtype_mask == 0xfb))
                self.backend = "sim-native"
                self._refresh_caps_native()
            else:
                self.backend = "sim-python"
            if caps is not None:
                # Explicit profile/caps override wins over native defaults.
                self._caps = caps
        elif be == "virt-card":
            from .virt_card import VirtCardSession

            self._virt = VirtCardSession(
                mode=virt_mode,
                board_id=self.board_id,
            )
            self.backend = f"virt-card-{self._virt.caps.mode}"
            self.board_id = self._virt.board_id
            d = self._virt.as_caps_dict()
            self._caps = Caps(
                acc_tile_m=int(d.get("acc_tile_m", 1024)),
                acc_tile_n=int(d.get("acc_tile_n", 512)),
                acc_tile_k=int(d.get("acc_tile_k", 512)),
                macs_per_cycle=int(d.get("macs_per_cycle", 512)),
                noc_width=int(d.get("noc_width", 64)),
                clusters=int(d.get("clusters", 1)),
                compute_ref=True,
            )
            if caps is not None:
                self._caps = caps
        elif be == "qemu-uio":
            from . import qemu_uio

            # A caller may pass a pre-built session (tests, or a runtime that owns the
            # mapping); otherwise open one from the environment.
            self._uio = session or qemu_uio.open_from_env()
            self.backend = "qemu-uio"
            c = self._uio.caps
            # Geometry comes from the CAP window, which is the whole point of the
            # window: an explicit `caps=` override is honoured, but it is an override of
            # a real measurement rather than a substitute for one.
            self._caps = Caps(
                acc_tile_m=c.acc_tile_m,
                acc_tile_n=c.acc_tile_n,
                acc_tile_k=c.acc_tile_k,
                macs_per_cycle=c.macs_per_cycle,
                noc_width=c.noc_width,
                clusters=c.clusters,
                compute_ref=False,
                dtype_mask=c.dtype_mask,
            )
            if caps is not None:
                self._caps = caps
        else:
            if self._native is None or not hasattr(self._native, "Mmio"):
                raise RuntimeError(
                    "backend='mmio' requires ai_tensor_native.Mmio "
                    "(build: cargo build -p ai-tensor-py && install module)"
                )
            if getattr(self._native, 'CONTRACT_VERSION', None) != CONTRACT_VERSION:
                raise RuntimeError('native extension must be rebuilt for Desc64 v2')
            self._dev = self._native.Mmio(software_reference=bool(caps and caps.dtype_mask == 0xfb))
            self.backend = "mmio-soft-native"
            if hasattr(self._dev, "probe_caps"):
                self._dev.probe_caps()
            self._refresh_caps_native()
            if caps is not None:
                self._caps = caps

    def close(self) -> None:
        """Release virt-card agent/client or UIO mapping when used."""
        if self._virt is not None:
            self._virt.close()
            self._virt = None
        if self._uio is not None:
            self._uio.close()
            self._uio = None

    def __enter__(self) -> "Device":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    @classmethod
    def from_env(cls, *, backend: Optional[str] = None) -> "Device":
        """
        Open from ``AI_TENSOR_*`` env (board id, backend, UIO, AccTile pins).

        Used by build-platform ``tensor frameworks|regress`` after exporting
        board-derived env (``AI_TENSOR_BOARD_ID``, ``AI_TENSOR_BACKEND``, …).
        """
        return cls(backend=backend)

    @classmethod
    def from_board(
        cls,
        board_id: str = "virt-ai-pcie",
        *,
        virt_mode: Optional[str] = None,
        caps: Optional[Caps] = None,
    ) -> "Device":
        """Open virt-card (or env backend) for a named board id."""
        os.environ.setdefault("AI_TENSOR_BOARD_ID", board_id)
        be = "virt-card"
        if board_id not in ("virt-ai-pcie", "virt-ai", "virt_ai_pcie"):
            # Non-virtual boards default to mmio if native present, else sim.
            try:
                return cls("mmio", caps=caps, board_id=board_id)
            except RuntimeError:
                return cls("sim", caps=caps, board_id=board_id)
        return cls(be, caps=caps, board_id=board_id, virt_mode=virt_mode)

    @classmethod
    def from_profile(cls, path: str) -> "Device":
        """Open a device using a package profile TOML (backend + AccTile pins)."""
        from .profile import Profile

        pr = Profile.load_file(path)
        be = pr.backend.lower().replace("_", "-")
        if be in ("mmio-soft", "mapped", "mapped-file", "linux", "uio"):
            be = "mmio"
        elif be in (
            "virt-card",
            "virt",
            "virt-ai-pcie",
            "pcie-virt",
            "virtual-pcie",
            "linux-uio",
        ):
            # Generated board profiles use backend=linux-uio; virt boards map
            # soft-sticky UIO paths to virt-card.
            board = getattr(pr, "board_id", None) or os.environ.get(
                "AI_TENSOR_BOARD_ID", ""
            )
            uio = getattr(pr, "uio_primary", None) or os.environ.get(
                "AI_TENSOR_UIO", ""
            )
            if (
                str(board).startswith("virt")
                or str(uio).startswith("virt://")
                or be in ("virt-card", "virt", "virt-ai-pcie", "pcie-virt", "virtual-pcie")
            ):
                be = "virt-card"
            else:
                be = "mmio"
        elif be not in ("sim", "mmio", "software-reference-v2"):
            be = "sim"
        caps = Caps(
            acc_tile_m=pr.acc_tile_m,
            acc_tile_n=pr.acc_tile_n,
            acc_tile_k=pr.acc_tile_k,
            macs_per_cycle=pr.macs_per_cycle,
            noc_width=pr.noc_width,
            clusters=1,
            compute_ref=True,
            dtype_mask=pr.dtype_mask,
        )
        try:
            dev = cls(be, caps=caps)
        except RuntimeError:
            # SoftIsland native optional: fall back to sim with profile caps.
            dev = cls("sim", caps=caps)
        dev.profile_id = pr.id
        return dev

    def _refresh_caps_native(self) -> None:
        if self._dev is None or not hasattr(self._dev, "caps"):
            return
        d = self._dev.caps()
        self._caps = Caps(
            acc_tile_m=int(d.get("acc_tile_m", 1024)),
            acc_tile_n=int(d.get("acc_tile_n", 512)),
            acc_tile_k=int(d.get("acc_tile_k", 512)),
            macs_per_cycle=int(d.get("macs_per_cycle", 512)),
            noc_width=int(d.get("noc_width", 64)),
            clusters=int(d.get("clusters", 1)),
            compute_ref=bool(d.get("compute_ref", True)),
            dtype_mask=int(d.get("dtype_mask", 1)),
        )

    def caps(self) -> Caps:
        return self._caps

    def pmu(self) -> Pmu:
        if self._uio is not None:
            d = self._uio.pmu()
            self._last_pmu = Pmu(
                r_beats=int(d.get("r_beats", 0)),
                w_beats=int(d.get("w_beats", 0)),
                cycles=int(d.get("cycles", 0)),
                gbps_x1000=int(d.get("gbps_x1000", 0)),
            )
            return self._last_pmu
        if self._dev is not None and hasattr(self._dev, "pmu"):
            d = self._dev.pmu()
            self._last_pmu = Pmu(
                r_beats=int(d.get("r_beats", 0)),
                w_beats=int(d.get("w_beats", 0)),
                cycles=int(d.get("cycles", 0)),
                gbps_x1000=int(d.get("gbps_x1000", 0)),
            )
        return self._last_pmu

    def gemm_native(self, a: bytes, b: bytes, m: int, n: int, k: int, numfmt: int,
                    lda=None, ldb=None, *, ticket: int = 1) -> bytes:
        from .numfmt import gemm_native, validate_buffers
        a, b, lda, ldb, _, _, _ = validate_buffers(
            a, b, m, n, k, numfmt, lda, ldb, self._caps.dtype_mask)
        if not self._caps.fits(m, n, k):
            raise ValueError('native GEMM exceeds AccTile; ordered FP K-splitting is unsupported')
        if self._uio is not None:
            return self._uio.gemm_native(a, b, m, n, k, numfmt, lda, ldb, ticket=ticket)
        if self._virt is not None:
            raise NotImplementedError('virt-card native formats are not implemented; use sim or qemu-uio')
        if self._dev is not None:
            if not hasattr(self._dev, 'gemm_native'):
                raise NotImplementedError('native extension lacks gemm_native; rebuild or use the pure Python reference')
            return bytes(self._dev.gemm_native(a, b, m, n, k, numfmt, lda, ldb, ticket))
        out = gemm_native(a, b, m, n, k, numfmt, lda, ldb, self._caps.dtype_mask)
        return out

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
        va_panels: bool = False,
    ) -> Tuple[List[int], int, int, Dict[str, Any]]:
        """
        INT8 GEMM → i32 C.

        Returns ``(c_list, ticket, status, meta)`` where meta includes caps/pmu/tiles.
        If dims exceed AccTile and ``auto_tile``, streams tiled jobs and accumulates.
        """
        from .numfmt import check_format
        check_format(0, self._caps.dtype_mask)
        if min(m, n, k) <= 0 or len(a) < m * k or len(b) < k * n:
            raise ValueError('invalid shape or short S8 operands')
        a8 = [int(x) for x in a]
        b8 = [int(x) for x in b]
        caps = self.caps()
        meta: Dict[str, Any] = {
            "backend": self.backend,
            "board_id": self.board_id,
            "caps": caps.as_dict(),
            "tiles": 1,
            "auto_tile": False,
        }
        if self._virt is not None:
            meta["virt"] = self._virt.as_caps_dict()
        if self._uio is not None:
            meta["uio"] = self._uio.as_caps_dict()

        if va_panels and auto_tile:
            bm, bn, bk = choose_va_blocking(
                m, n, k,
                caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k,
                caps.macs_per_cycle,
            )
        else:
            bm, bn, bk = caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k
        if (m <= bm and n <= bn and k <= bk) or not auto_tile:
            c, tix, status = self._gemm_one(m, n, k, a8, b8, ticket)
            meta["pmu"] = self.pmu().as_dict()
            meta["backend"] = self.backend
            meta["board_id"] = self.board_id
            return c, tix, status, meta

        # Host-side tiling (AccTile stream); accumulate partials into C
        meta["auto_tile"] = True
        c = [0] * (m * n)
        tix = ticket
        status = ST_OK
        tiles = tile_gemm(m, n, k, bm, bn, bk)
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
                    dst = (i0 + ii) * n + (j0 + jj)
                    value = (c[dst] + partial[ii * tn + jj]) & 0xFFFFFFFF
                    c[dst] = value - (1 << 32) if value & (1 << 31) else value
            tix = last_ticket + 1
        meta["pmu"] = self.pmu().as_dict()
        meta["backend"] = self.backend
        meta["board_id"] = self.board_id
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
        if self._uio is not None:
            return self._uio.gemm_s8(m, n, k, a8, b8, ticket)
        if self._virt is not None:
            return self._virt.gemm_s8(m, n, k, a8, b8, ticket)
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
    va_panels: bool = False,
) -> Tuple[List[int], int, int, Dict[str, Any]]:
    dev = device or Device("sim")
    return dev.gemm_s8(m, n, k, a, b, ticket, auto_tile=auto_tile, va_panels=va_panels)


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
    from .numfmt import gemm_native
    if len(a) < m * k or len(b) < k * n:
        raise ValueError('operand buffer too short')
    a_bytes = bytes(x & 255 for x in a)
    b_bytes = bytes(b[t * n + j] & 255 for j in range(n) for t in range(k))
    raw = gemm_native(a_bytes, b_bytes, m, n, k, 0)
    return list(struct.unpack('<' + 'i' * (m * n), raw)), ticket, ST_OK
