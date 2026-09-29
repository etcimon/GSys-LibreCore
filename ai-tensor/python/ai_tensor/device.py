# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Device facade: native sim/mmio-soft, virt-card PCIe virtual, pure-Python fallback."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

import struct

from .c_abi import NUMFMT_ELEM_BYTES

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
    # CAP_ACCMODE bit 0: flags.accmode 01 (seed the reduction from C) is executable.
    accumulate: bool = False
    # CAP_BANK_{A,B}_BYTES: operand bank capacity. 0 = not published, legacy K box.
    bank_a_bytes: int = 0
    bank_b_bytes: int = 0

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
            "accumulate": self.accumulate,
            "bank_a_bytes": self.bank_a_bytes,
            "bank_b_bytes": self.bank_b_bytes,
        }

    @property
    def flat_panels(self) -> bool:
        """True when the island publishes operand bank bytes (flat panel mapping)."""
        return self.bank_a_bytes > 0 and self.bank_b_bytes > 0

    def pitch_bytes(self, row_bytes: int) -> int:
        """Bank row pitch for a row of ``row_bytes``: the next power of two of the
        lane-word count, in bytes (the island's row address is a shift)."""
        lanes = max(1, self.macs_per_cycle)
        words = max(1, -(-row_bytes // lanes))
        return (1 << (words - 1).bit_length()) * lanes

    def fits(self, m: int, n: int, k: int, row_bytes: Optional[int] = None) -> bool:
        """Shape admission. Legacy parts box ``k`` by ``acc_tile_k``; parts that publish
        bank bytes box the *panels*: ``n * pitch <= bank_b`` and ``m * pitch <= bank_a``
        (``row_bytes`` defaults to ``k`` bytes, i.e. one-byte elements)."""
        if m > self.acc_tile_m or n > self.acc_tile_n or k <= 0:
            return False
        if not self.flat_panels:
            return k <= self.acc_tile_k
        pitch = self.pitch_bytes(k if row_bytes is None else row_bytes)
        return k <= 0xFFFF and n * pitch <= self.bank_b_bytes and m * pitch <= self.bank_a_bytes

    def max_k(self, m: int, n: int, elem_bytes: int) -> int:
        """Largest K (elements) one job may carry for an ``m x n`` output at
        ``elem_bytes`` per element -- the runtime's K block."""
        if not self.flat_panels:
            return self.acc_tile_k
        lanes = max(1, self.macs_per_cycle)
        rows = max(m, n, 1)
        # Largest power-of-two pitch (in lane words) that fits both banks.
        words = 1
        while (rows * (words * 2) * lanes <= self.bank_b_bytes and m * (words * 2) * lanes <= self.bank_a_bytes
               and n * (words * 2) * lanes <= self.bank_b_bytes):
            words *= 2
        if n * words * lanes > self.bank_b_bytes or m * words * lanes > self.bank_a_bytes:
            return 0
        return min(0xFFFF, (words * lanes) // max(1, elem_bytes))


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


VA_TURBO_TEST_MACS = 8
VA_TURBO_TEST_TILE = (1024, 512, 16)


def _adjacent_reuse(
    prev: Tuple[int, int, int, int, int, int],
    tile: Tuple[int, int, int, int, int, int],
) -> Tuple[bool, bool]:
    """Whether the previous tile can skip A, and whether it can skip B."""
    pi, pj, pt, ptm, ptn, ptk = prev
    i0, j0, t0, tm, tn, tk = tile
    reuse_b = pj == j0 and ptn == tn and pt == t0 and ptk == tk
    reuse_a = pi == i0 and ptm == tm and pt == t0 and ptk == tk
    return reuse_a, reuse_b


def tile_can_reuse(m: int, n: int, k: int, caps: Caps) -> Tuple[bool, bool]:
    """Any adjacent tiles that the previous-tile rule can skip."""
    bm, bn, bk = choose_va_blocking(
        m, n, k, caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k, caps.macs_per_cycle
    )
    tiles = tile_gemm(m, n, k, bm, bn, bk)
    hit_a = False
    hit_b = False
    for idx in range(1, len(tiles)):
        reuse_a, reuse_b = _adjacent_reuse(tiles[idx - 1], tiles[idx])
        hit_a = hit_a or reuse_a
        hit_b = hit_b or reuse_b
    return hit_a, hit_b


def exact_reuse_for_call(caps: Caps, m: int, n: int, k: int) -> bool:
    """Exact reuse for one high-level call.

    Only the directed 8-MAC tile, and only when two adjacent tiles can
    skip A or B. The live 512-MAC package stays off.
    """
    if (
        caps.macs_per_cycle != VA_TURBO_TEST_MACS
        or (caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k) != VA_TURBO_TEST_TILE
    ):
        return False
    hit_a, hit_b = tile_can_reuse(int(m), int(n), int(k), caps)
    return hit_a or hit_b


def _i8(v: int) -> int:
    v &= 255
    return v - 256 if v >= 128 else v


def _pack_a_tile(a: Sequence[int], k: int, i0: int, t0: int, tm: int, tk: int) -> List[int]:
    out: List[int] = []
    for ii in range(tm):
        row = (i0 + ii) * k + t0
        out.extend(int(a[row + t]) for t in range(tk))
    return out


def _pack_b_tile(
    b: Sequence[int], n: int, j0: int, t0: int, tn: int, tk: int
) -> List[int]:
    out: List[int] = []
    for jj in range(tn):
        for t in range(tk):
            out.append(int(b[(t0 + t) * n + (j0 + jj)]))
    return out


def _dot_i8_tile(a_tile: Sequence[int], b_tile: Sequence[int], tm: int, tn: int, tk: int) -> List[int]:
    out: List[int] = []
    for ii in range(tm):
        for jj in range(tn):
            acc = 0
            for t in range(tk):
                acc += _i8(a_tile[ii * tk + t]) * _i8(b_tile[jj * tk + t])
            out.append(acc)
    return out


def run_va_turbo_test_s8(
    m: int,
    n: int,
    k: int,
    a: Sequence[int],
    b: Sequence[int],
    caps: Caps,
    level: int = 0,
    measured_ppm: Optional[int] = None,
) -> Dict[str, Any]:
    """Directed 8-MAC schedule. The live 512-MAC tile is refused.

    Exact reuse is enabled for this call. A hit multiplies the resident
    tile. The applied level stays 0, so a level does not change C.
    """
    from .policy import FLAG_REUSE_A, FLAG_REUSE_B, OperandReuse, va_turbo_applied_level
    from .va_turbo import measurement_fits

    if (
        caps.macs_per_cycle != VA_TURBO_TEST_MACS
        or (caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k) != VA_TURBO_TEST_TILE
    ):
        raise ValueError("VaTurbo test schedule requires the 8-MAC 1024x512x16 directed tile")
    if level != 0 and not measurement_fits(level, measured_ppm):
        raise ValueError("VaTurbo level above 0 needs a measured ppm inside the level budget")
    if va_turbo_applied_level(level) != 0:
        raise ValueError("VaTurbo arithmetic level is not applied")
    if min(m, n, k) <= 0 or len(a) < m * k or len(b) < k * n:
        raise ValueError("invalid shape or short S8 operands")
    bm, bn, bk = choose_va_blocking(
        m, n, k, caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k, caps.macs_per_cycle
    )
    tiles = tile_gemm(m, n, k, bm, bn, bk)
    if not tiles:
        raise ValueError("empty tile plan")
    reuse = OperandReuse()
    can_a, can_b = tile_can_reuse(m, n, k, caps)
    reuse.set_enabled(can_a or can_b)
    c = [0] * (m * n)
    flags: List[int] = []
    pa, pb = 0x1000, 0x2000
    hit_a = False
    hit_b = False
    for idx, (i0, j0, t0, tm, tn, tk) in enumerate(tiles):
        flag = 0
        if idx:
            reuse_a, reuse_b = _adjacent_reuse(tiles[idx - 1], (i0, j0, t0, tm, tn, tk))
            if reuse_b:
                flag |= FLAG_REUSE_B
            if reuse_a:
                flag |= FLAG_REUSE_A
        a_tile = _pack_a_tile(a, k, i0, t0, tm, tk)
        b_tile = _pack_b_tile(b, n, j0, t0, tn, tk)
        _, a_used = reuse.bind(
            "a", flag & FLAG_REUSE_A, (pa + i0 * k + t0, tm, tk, k, 0), a_tile, True
        )
        _, b_used = reuse.bind(
            "b", flag & FLAG_REUSE_B, (pb + j0 * k + t0, tn, tk, k, 0), b_tile, True
        )
        hit_a = hit_a or not reuse.last_read_a
        hit_b = hit_b or not reuse.last_read_b
        partial = _dot_i8_tile(a_used, b_used, tm, tn, tk)
        reuse.finish(True)
        for ii in range(tm):
            for jj in range(tn):
                dst = (i0 + ii) * n + (j0 + jj)
                c[dst] += partial[ii * tn + jj]
        flags.append(flag)
    return {
        "c": c,
        "flags": flags,
        "read_a": reuse.last_read_a,
        "read_b": reuse.last_read_b,
        "hit_a": hit_a,
        "hit_b": hit_b,
        "reuse_enabled": can_a or can_b,
        "requested_level": level,
        "applied_level": 0,
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
            self._caps = caps or Caps(dtype_mask=0xfb, accumulate=True)
            self.backend = 'software-reference-v2'
        elif be == "sim":
            if self._native is not None and hasattr(self._native, "Sim"):
                if getattr(self._native, 'CONTRACT_VERSION', None) != CONTRACT_VERSION:
                    raise RuntimeError('native extension must be rebuilt for Desc64 v2')
                sw = bool(caps and caps.dtype_mask == 0xfb)
                directed = (
                    caps is not None
                    and not sw
                    and caps.macs_per_cycle == VA_TURBO_TEST_MACS
                    and (caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k)
                    == VA_TURBO_TEST_TILE
                )
                try:
                    self._dev = self._native.Sim(software_reference=sw, directed=directed)
                except TypeError:
                    self._dev = self._native.Sim(software_reference=sw)
                self.backend = "sim-native"
                self._refresh_caps_native()
            else:
                self.backend = "sim-python"
            if caps is not None:
                # Explicit profile/caps override wins over native defaults.
                self._caps = caps
        elif be == "virt-card":
            from .virt_card import VirtCardSession

            if isinstance(session, VirtCardSession):
                self._virt = session
            else:
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
                accumulate=bool(getattr(c, "accumulate", False)),
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
            sw = bool(caps and caps.dtype_mask == 0xfb)
            directed = (
                caps is not None
                and not sw
                and caps.macs_per_cycle == VA_TURBO_TEST_MACS
                and (caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k) == VA_TURBO_TEST_TILE
            )
            try:
                self._dev = self._native.Mmio(software_reference=sw, directed=directed)
            except TypeError:
                self._dev = self._native.Mmio(software_reference=sw)
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
                    lda=None, ldb=None, *, ticket: int = 1, c_init=None) -> bytes:
        """One native descriptor. ``c_init`` requests ``flags.accmode == 01``: the reduction
        of every output starts from that stored C word. Refused unless the device grants
        it (``Caps.accumulate`` / CAP_ACCMODE), never silently ignored."""
        from .numfmt import gemm_native, validate_buffers
        a, b, lda, ldb, _, _, _ = validate_buffers(
            a, b, m, n, k, numfmt, lda, ldb, self._caps.dtype_mask)
        if not self._caps.fits(m, n, k, row_bytes=k * max(1, NUMFMT_ELEM_BYTES.get(numfmt, 1)) if numfmt != 1 else (k + 1) // 2):
            raise ValueError('native GEMM exceeds the island box (AccTile / operand bank bytes); tile on the host')
        if c_init is not None:
            if not self._caps.accumulate:
                raise ValueError('ST_BAD_FMT: accumulate mode is not granted by this device')
            if self._uio is not None:
                return self._uio.gemm_native(a, b, m, n, k, numfmt, lda, ldb, ticket=ticket, c_init=c_init)
            if self._dev is not None or self._virt is not None:
                raise NotImplementedError('accumulate mode: native extension and virt-card paths are not wired')
            return gemm_native(a, b, m, n, k, numfmt, lda, ldb, self._caps.dtype_mask, c_init=c_init)
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
        On the directed 8-MAC tile, ``auto_tile`` uses the named-panel schedule
        when an adjacent tile can skip. A K-split and every other record stay
        one ordinary GEMM when the shape fits, and do not enable reuse.
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

        schedule_caps = self._directed_schedule_caps()
        if auto_tile and schedule_caps is not None and exact_reuse_for_call(
            schedule_caps, m, n, k
        ):
            result = self._run_directed_auto(m, n, k, a8, b8, ticket)
            flags = list(result["flags"])
            ntiles = len(flags)
            meta["tiles"] = ntiles
            meta["auto_tile"] = ntiles > 1
            meta["exact_reuse"] = bool(result["reuse_enabled"])
            meta["hit_a"] = bool(result["hit_a"])
            meta["hit_b"] = bool(result["hit_b"])
            meta["read_a"] = bool(result["read_a"])
            meta["read_b"] = bool(result["read_b"])
            meta["applied_level"] = 0
            meta["pmu"] = self.pmu().as_dict()
            last = ticket + max(ntiles, 1) - 1
            return list(result["c"]), last, ST_OK, meta

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

    def _directed_schedule_caps(self) -> Optional[Caps]:
        """Caps of the directed tile, or none when this device is not that tile.

        A device that publishes its own record wins over a host caps override.
        With no such device, the caps object is the model.
        """
        for obj in (self._uio, self._virt, self._dev):
            if obj is None:
                continue
            report = getattr(obj, "reports_directed_tile", None)
            if report is None:
                continue
            if not report():
                return None
            return Caps(
                acc_tile_m=VA_TURBO_TEST_TILE[0],
                acc_tile_n=VA_TURBO_TEST_TILE[1],
                acc_tile_k=VA_TURBO_TEST_TILE[2],
                macs_per_cycle=VA_TURBO_TEST_MACS,
                noc_width=self._caps.noc_width,
                clusters=self._caps.clusters,
                dtype_mask=self._caps.dtype_mask,
            )
        caps = self._caps
        if (
            caps.macs_per_cycle == VA_TURBO_TEST_MACS
            and (caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k) == VA_TURBO_TEST_TILE
        ):
            return caps
        return None

    def _run_directed_auto(
        self,
        m: int,
        n: int,
        k: int,
        a: Sequence[int],
        b: Sequence[int],
        ticket: int,
    ) -> Dict[str, Any]:
        for obj in (self._uio, self._virt, self._dev):
            if obj is None:
                continue
            run = getattr(obj, "run_va_turbo_test_s8", None)
            if run is None:
                continue
            try:
                return run(int(m), int(n), int(k), a, b, ticket=ticket)
            except TypeError:
                return run(int(m), int(n), int(k), a, b)
        sched = self._directed_schedule_caps()
        if sched is None:
            raise ValueError(
                "VaTurbo test schedule requires the 8-MAC 1024x512x16 directed tile"
            )
        return run_va_turbo_test_s8(int(m), int(n), int(k), a, b, sched)


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


def high_level_fields(
    caps: Caps, m: int, n: int, k: int, exact_reuse: bool, native: bool = False
) -> Dict[str, Any]:
    """What this call decided, and why reuse or promotion did not happen.

    ``shape_reuse_a`` and ``shape_reuse_b`` are the shape choice. ``exact_reuse``
    is whether this call actually enabled it. ``reuse_blocked`` is ``shape``,
    ``live-caps``, or ``native-call`` when it did not. ``promotion_missing``
    is the known witness list. The live 64-bit fabric stays unpromoted.
    """
    from .va_turbo import (
        LIVE_MACS_PER_BYTE,
        NARROW_BEAT_BYTES,
        GateWitness,
        PortSetting,
        known_promotion_witnesses,
        select_workload,
        va_turbo_from_witnesses,
    )

    choice = select_workload(int(m), int(n), int(k))
    wants = bool(choice.reuse_a or choice.reuse_b)
    if exact_reuse:
        blocked = None
    elif native:
        blocked = "native-call"
    elif exact_reuse_for_call(caps, m, n, k):
        blocked = "not-enabled"
    elif not wants:
        blocked = "shape"
    else:
        blocked = "live-caps"
    port = PortSetting(512, int(caps.noc_width))
    carried = port.carried_bytes()
    total = int(caps.clusters) * int(caps.macs_per_cycle)
    fed = (
        carried > 0
        and total <= carried * LIVE_MACS_PER_BYTE
        and total <= NARROW_BEAT_BYTES * LIVE_MACS_PER_BYTE
    )
    decision = va_turbo_from_witnesses(
        GateWitness("exact_reuse", "passed", "high-level-fields"),
        known_promotion_witnesses(),
    )
    return {
        "exact_reuse": bool(exact_reuse),
        "applied_level": 0,
        "workload_code": choice.code,
        "shape_reuse_a": bool(choice.reuse_a),
        "shape_reuse_b": bool(choice.reuse_b),
        "reuse_blocked": blocked,
        "carried_bytes": carried,
        "port_promoted": port.promoted(),
        "fed": fed,
        "promotion_missing": list(decision.missing),
        "hit_a": False,
        "hit_b": False,
    }


def run_high_level_s8(
    dev: Device,
    m: int,
    n: int,
    k: int,
    a: Sequence[int],
    b: Sequence[int],
    ticket: int = 1,
    auto_tile: bool = True,
    recipe: Optional[str] = None,
) -> Tuple[List[int], Dict[str, Any]]:
    """INT8 high-level call. A named recipe is refused. Live reuse stays off.

    A virtual card, local or over TCP, whose CAP is the directed tile runs
    that schedule. The default 512-MAC card does not. A qemu-uio window
    does the same when its capability record is that tile. A different
    window stays on one exact GEMM, including when the host caps differ.
    The native soft island does the same: a directed Mmio runs the
    schedule, and the default 512-MAC island does not, even if the host
    caps name the directed tile. A native simulator constructed with
    that directed tile does the same. Its default 512-MAC configuration
    does not, even if the host caps are overwritten afterward.
    This call uses :meth:`Device.gemm_s8`, so the auto schedule is decided
    in one place.
    """
    from .va_turbo import refuse_unapplied_recipe

    refuse_unapplied_recipe(recipe)
    caps = dev.caps()
    c, tix, status, meta = dev.gemm_s8(
        int(m), int(n), int(k), a, b, ticket, auto_tile=auto_tile
    )
    if status != ST_OK:
        raise RuntimeError(f"ai-tensor gemm failed status={status}")
    reused = bool(meta.get("exact_reuse"))
    hits = (
        bool(meta.get("hit_a", False)),
        bool(meta.get("hit_b", False)),
        bool(meta.get("read_a", True)),
        bool(meta.get("read_b", True)),
    )
    meta.update(high_level_fields(caps, m, n, k, reused))
    if reused:
        meta["hit_a"], meta["hit_b"], meta["read_a"], meta["read_b"] = hits
    meta["ticket"] = tix
    meta["status"] = status
    meta["backend"] = dev.backend
    return c, meta


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
