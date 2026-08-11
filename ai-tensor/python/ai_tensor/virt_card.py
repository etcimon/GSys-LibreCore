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
    acc_tile_m: int = 256
    acc_tile_n: int = 256
    acc_tile_k: int = 256
    macs_per_cycle: int = 256
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
            acc_tile_m=int(_env("AI_TENSOR_ACC_TILE_M", "256") or "256"),
            acc_tile_n=int(_env("AI_TENSOR_ACC_TILE_N", "256") or "256"),
            acc_tile_k=int(_env("AI_TENSOR_ACC_TILE_K", "256") or "256"),
            macs_per_cycle=int(_env("AI_TENSOR_MACS", "256") or "256"),
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
            self._local = VirtualUioDevice(eventfd=efd, path=self.caps.uio)
            self._local.enable(True)
            return

        # TCP / virtual PCIe path
        from virt_ai_card.card_agent import CardAgent
        from virt_ai_card.host_client import HostClient

        if self._host and self._port:
            host, port = self._host, int(self._port)
            self._owns_agent = False
        else:
            self._agent = CardAgent(host=self._host or "127.0.0.1", port=self._port or 0)
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
