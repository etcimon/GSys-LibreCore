# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Virtual PCIe AI card session for ``Device(backend='virt-card')``.

Stand-in for host↔card PCIe/SSH + soft UIO/eventfd (board ``virt-ai-pcie``).

Modes (``AI_TENSOR_VIRT_MODE`` or ctor):
  * ``local`` — in-process ``VirtualUioDevice`` (fast hostless CI)
  * ``tcp``   — ``HostClient`` over ``VirtualPcieLink`` (auto-spawns
    ``CardAgent`` unless ``AI_TENSOR_VIRT_HOST``/``PORT`` point at a live agent)
  * ``auto``  — ``tcp`` when host/port set, else ``local``

Board id defaults from ``AI_TENSOR_BOARD_ID`` (``virt-ai-pcie``).
"""

from __future__ import annotations

import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

# Ensure tools/ is importable when running from package without install.
_TOOLS = Path(__file__).resolve().parents[2] / "tools"
if _TOOLS.is_dir() and str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))


def _env(name: str, default: Optional[str] = None) -> Optional[str]:
    v = os.environ.get(name)
    if v is None or v.strip() == "":
        return default
    return v.strip()


@dataclass
class VirtCardCaps:
    acc_tile_m: int = 1024
    acc_tile_n: int = 512
    acc_tile_k: int = 512
    macs_per_cycle: int = 512
    noc_width: int = 64
    clusters: int = 1
    board_id: str = "virt-ai-pcie"
    mode: str = "local"
    uio: str = "virt://virt-ai-pcie/island0"
    eventfd: str = "virt://virt-ai-pcie/island0_irq"


class VirtCardSession:
    """Owns local UIO device and/or TCP agent+client for virt-card GEMM."""

    def __init__(
        self,
        *,
        mode: Optional[str] = None,
        board_id: Optional[str] = None,
        host: Optional[str] = None,
        port: Optional[int] = None,
        caps: Optional[VirtCardCaps] = None,
    ) -> None:
        self.board_id = board_id or _env("AI_TENSOR_BOARD_ID", "virt-ai-pcie") or "virt-ai-pcie"
        self._mode_req = (mode or _env("AI_TENSOR_VIRT_MODE", "auto") or "auto").lower()
        self._host = host or _env("AI_TENSOR_VIRT_HOST")
        port_s = _env("AI_TENSOR_VIRT_PORT")
        self._port = port if port is not None else (int(port_s) if port_s else None)
        self._agent = None
        self._client = None
        self._local = None
        self._owns_agent = False
        self._last_ticket = 0
        self.caps = caps or VirtCardCaps(
            board_id=self.board_id,
            acc_tile_m=int(_env("AI_TENSOR_ACC_TILE_M", "1024") or "1024"),
            acc_tile_n=int(_env("AI_TENSOR_ACC_TILE_N", "512") or "512"),
            acc_tile_k=int(_env("AI_TENSOR_ACC_TILE_K", "512") or "512"),
            macs_per_cycle=int(_env("AI_TENSOR_MACS", "512") or "512"),
            noc_width=int(_env("AI_TENSOR_NOC_WIDTH", "64") or "64"),
            uio=_env("AI_TENSOR_UIO", f"virt://{self.board_id}/island0")
            or f"virt://{self.board_id}/island0",
            eventfd=_env("AI_TENSOR_EVENTFD", f"virt://{self.board_id}/island0_irq")
            or f"virt://{self.board_id}/island0_irq",
        )
        self._open()

    def _resolve_mode(self) -> str:
        m = self._mode_req
        if m == "auto":
            if self._host or self._port:
                return "tcp"
            return "local"
        if m in ("local", "tcp", "pcie", "virt-pcie"):
            return "local" if m == "local" else "tcp"
        raise ValueError(
            f"AI_TENSOR_VIRT_MODE must be local|tcp|auto (got {self._mode_req!r})"
        )

    def _open(self) -> None:
        mode = self._resolve_mode()
        self.caps.mode = mode
        self.caps.board_id = self.board_id
        if mode == "local":
            from virt_ai_card.driver import VirtualEventFd, VirtualUioDevice

            efd = VirtualEventFd(path=self.caps.eventfd)
            self._local = VirtualUioDevice(
                eventfd=efd,
                path=self.caps.uio,
                cap=self._uio_cap(),
            )
            self._local.enable(True)
            self._adopt_cap(self._local.cap_snapshot())
            return

        # TCP / virtual PCIe path
        from virt_ai_card.card_agent import CardAgent
        from virt_ai_card.host_client import HostClient

        if self._host and self._port:
            host, port = self._host, int(self._port)
            self._owns_agent = False
        else:
            self._agent = CardAgent(
                host=self._host or "127.0.0.1",
                port=self._port or 0,
                cap=self._uio_cap(),
            )
            host, port = self._agent.start()
            self._owns_agent = True
            time.sleep(0.02)

        self._client = HostClient(host=host, port=port)
        hello = self._client.connect()
        # Prefer card-reported board id when present
        if hello.get("boardid"):
            self.board_id = str(hello["boardid"])
            self.caps.board_id = self.board_id
        if hello.get("uio"):
            self.caps.uio = str(hello["uio"])
        if hello.get("eventfd"):
            self.caps.eventfd = str(hello["eventfd"])
        cap = hello.get("cap")
        if isinstance(cap, dict):
            self._adopt_cap(cap)

    def close(self) -> None:
        if self._client is not None:
            try:
                self._client.close()
            except Exception:
                pass
            self._client = None
        if self._owns_agent and self._agent is not None:
            try:
                self._agent.stop()
            except Exception:
                pass
            self._agent = None
            self._owns_agent = False
        self._local = None

    def __enter__(self) -> "VirtCardSession":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def as_caps_dict(self) -> Dict[str, Any]:
        return {
            "acc_tile_m": self.caps.acc_tile_m,
            "acc_tile_n": self.caps.acc_tile_n,
            "acc_tile_k": self.caps.acc_tile_k,
            "macs_per_cycle": self.caps.macs_per_cycle,
            "noc_width": self.caps.noc_width,
            "clusters": self.caps.clusters,
            "compute_ref": True,
            "board_id": self.caps.board_id,
            "virt_mode": self.caps.mode,
            "uio": self.caps.uio,
            "eventfd": self.caps.eventfd,
        }

    def gemm_s8(
        self,
        m: int,
        n: int,
        k: int,
        a: Sequence[int],
        b: Sequence[int],
        ticket: int = 1,
    ) -> Tuple[List[int], int, int]:
        """Flat int8 row-major A[m,k], B[k,n] → flat i32 C[m,n], ticket, status."""
        if len(a) < m * k or len(b) < k * n:
            raise ValueError("a/b length short for m,n,k")
        a2 = [list(a[i * k : (i + 1) * k]) for i in range(m)]
        b2 = [list(b[t * n : (t + 1) * n]) for t in range(k)]

        if self._local is not None:
            c2 = self._local.gemm_s8(a2, b2, ticket=ticket, irq=True, wait=True)
        elif self._client is not None:
            c2 = self._client.gemm_s8(a2, b2, ticket=ticket, irq=True)
        else:
            raise RuntimeError("virt-card session not open")

        flat: List[int] = []
        for row in c2:
            flat.extend(int(x) for x in row)
        self._last_ticket = ticket
        return flat, ticket, 0

    def _uio_cap(self) -> Dict[str, int]:
        return {
            "clusters": int(self.caps.clusters),
            "macs_per_cycle": int(self.caps.macs_per_cycle),
            "acc_tile_m": int(self.caps.acc_tile_m),
            "acc_tile_n": int(self.caps.acc_tile_n),
            "acc_tile_k": int(self.caps.acc_tile_k),
        }

    def _adopt_cap(self, snap: Dict[str, Any]) -> None:
        """Geometry comes from the card snapshot, local or from the TCP hello."""
        for key in (
            "macs_per_cycle",
            "acc_tile_m",
            "acc_tile_n",
            "acc_tile_k",
            "clusters",
        ):
            if key in snap:
                setattr(self.caps, key, int(snap[key]))

    def _run_tile(
        self,
        a_rows: Sequence[Sequence[int]],
        b_rows: Sequence[Sequence[int]],
        ticket: int,
        flag: int,
        reuse_en: bool,
    ) -> Tuple[List[List[int]], bool, bool, bool]:
        if self._local is not None:
            self._local.set_reuse_en(reuse_en)
            partial = self._local.gemm_s8(a_rows, b_rows, ticket=ticket, flags=flag)
            return (
                partial,
                self._local.last_read_a(),
                self._local.last_read_b(),
                self._local.reuse_enabled(),
            )
        if self._client is None:
            raise RuntimeError("virt-card session not open")
        partial = self._client.gemm_s8(
            a_rows, b_rows, ticket=ticket, flags=flag, reuse_en=reuse_en
        )
        return (
            partial,
            bool(self._client.last_read_a),
            bool(self._client.last_read_b),
            bool(self._client.reuse_enabled),
        )

    def reports_directed_tile(self) -> bool:
        """True when the card CAP, local or TCP, is the 8-MAC 1024×512×16 tile."""
        if self._local is None and self._client is None:
            return False
        from ai_tensor.device import VA_TURBO_TEST_MACS, VA_TURBO_TEST_TILE

        return int(self.caps.macs_per_cycle) == VA_TURBO_TEST_MACS and (
            int(self.caps.acc_tile_m),
            int(self.caps.acc_tile_n),
            int(self.caps.acc_tile_k),
        ) == VA_TURBO_TEST_TILE

    def run_va_turbo_test_s8(
        self,
        m: int,
        n: int,
        k: int,
        a: Sequence[int],
        b: Sequence[int],
        ticket: int = 1,
    ) -> Dict[str, Any]:
        """Directed schedule on the local card or the TCP agent.

        The default 512-MAC CAP is refused. Exact reuse is enabled only
        when a planned tile can skip an operand. A K-split leaves it off.
        """
        from ai_tensor.device import (
            Caps,
            _adjacent_reuse,
            choose_va_blocking,
            tile_can_reuse,
            tile_gemm,
        )
        from ai_tensor.policy import FLAG_REUSE_A, FLAG_REUSE_B

        if (self._local is None and self._client is None) or not self.reports_directed_tile():
            raise ValueError(
                "VaTurbo test schedule requires the 8-MAC 1024x512x16 directed tile"
            )
        if min(m, n, k) <= 0 or len(a) < m * k or len(b) < k * n:
            raise ValueError("invalid shape or short S8 operands")
        caps = Caps(
            acc_tile_m=int(self.caps.acc_tile_m),
            acc_tile_n=int(self.caps.acc_tile_n),
            acc_tile_k=int(self.caps.acc_tile_k),
            macs_per_cycle=int(self.caps.macs_per_cycle),
            noc_width=int(self.caps.noc_width),
            clusters=int(self.caps.clusters),
        )
        bm, bn, bk = choose_va_blocking(
            m, n, k, caps.acc_tile_m, caps.acc_tile_n, caps.acc_tile_k, caps.macs_per_cycle
        )
        tiles = tile_gemm(m, n, k, bm, bn, bk)
        if not tiles:
            raise ValueError("empty tile plan")
        can_a, can_b = tile_can_reuse(m, n, k, caps)
        reuse_en = can_a or can_b
        c = [0] * (m * n)
        flags: List[int] = []
        hit_a = False
        hit_b = False
        read_a = True
        read_b = True
        enabled = False
        for idx, (i0, j0, t0, tm, tn, tk) in enumerate(tiles):
            flag = 0
            if idx:
                reuse_a, reuse_b = _adjacent_reuse(tiles[idx - 1], (i0, j0, t0, tm, tn, tk))
                if reuse_b:
                    flag |= FLAG_REUSE_B
                if reuse_a:
                    flag |= FLAG_REUSE_A
            a_rows = _rows_a(a, k, i0, t0, tm, tk)
            b_rows = _rows_b(b, n, j0, t0, tn, tk)
            partial, read_a, read_b, enabled = self._run_tile(
                a_rows, b_rows, ticket, flag, reuse_en
            )
            hit_a = hit_a or not read_a
            hit_b = hit_b or not read_b
            for ii in range(tm):
                for jj in range(tn):
                    dst = (i0 + ii) * n + (j0 + jj)
                    value = (c[dst] + int(partial[ii][jj])) & 0xFFFFFFFF
                    c[dst] = value - (1 << 32) if value & (1 << 31) else value
            flags.append(flag)
            ticket += 1
        self._last_ticket = ticket - 1
        return {
            "c": c,
            "flags": flags,
            "read_a": read_a,
            "read_b": read_b,
            "hit_a": hit_a,
            "hit_b": hit_b,
            "reuse_enabled": enabled,
            "requested_level": 0,
            "applied_level": 0,
        }


def _rows_a(
    a: Sequence[int], k: int, i0: int, t0: int, tm: int, tk: int
) -> List[List[int]]:
    rows: List[List[int]] = []
    for ii in range(tm):
        base = (i0 + ii) * k + t0
        rows.append([int(a[base + t]) for t in range(tk)])
    return rows


def _rows_b(
    b: Sequence[int], n: int, j0: int, t0: int, tn: int, tk: int
) -> List[List[int]]:
    rows: List[List[int]] = []
    for t in range(tk):
        base = (t0 + t) * n + j0
        rows.append([int(b[base + jj]) for jj in range(tn)])
    return rows
