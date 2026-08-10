# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Profile-driven host job queue (mirrors Rust HostRuntime; pure Python)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple

from .device import Device, ST_OK
from .profile import Profile


@dataclass
class HostJobResult:
    ticket: int
    c: List[int]
    status: int
    tiles: int
    meta: dict


@dataclass
class HostRuntime:
    profile: Profile = field(default_factory=Profile)
    max_pending: int = 64
    _pending: List[Tuple[int, int, int, List[int], List[int]]] = field(default_factory=list)
    _next_ticket: int = 1

    @classmethod
    def from_profile(cls, profile: Profile) -> "HostRuntime":
        return cls(profile=profile)

    def pending_len(self) -> int:
        return len(self._pending)

    def enqueue_gemm_s8(
        self,
        m: int,
        n: int,
        k: int,
        a: Sequence[int],
        b: Sequence[int],
    ) -> None:
        if len(self._pending) >= self.max_pending:
            raise RuntimeError(f"host queue full ({self.max_pending})")
        if len(a) < m * k or len(b) < k * n:
            raise ValueError("buffer sizes")
        self._pending.append((m, n, k, [int(x) for x in a], [int(x) for x in b]))

    def drain(
        self,
        device: Optional[Device] = None,
        limit: int = 0,
    ) -> List[HostJobResult]:
        dev = device or Device(self.profile.backend if self.profile.backend in ("sim", "mmio") else "sim")
        n = len(self._pending) if limit <= 0 else min(limit, len(self._pending))
        out: List[HostJobResult] = []
        for _ in range(n):
            m, n_, k, a, b = self._pending.pop(0)
            ticket = self._next_ticket
            self._next_ticket += 1
            c, tix, status, meta = dev.gemm_s8(m, n_, k, a, b, ticket=ticket, auto_tile=True)
            if status != ST_OK:
                raise RuntimeError(f"host job status={status}")
            out.append(
                HostJobResult(
                    ticket=tix,
                    c=c,
                    status=status,
                    tiles=int(meta.get("tiles", 1)),
                    meta=meta,
                )
            )
        return out

    def run_one_gemm_s8(
        self,
        m: int,
        n: int,
        k: int,
        a: Sequence[int],
        b: Sequence[int],
        device: Optional[Device] = None,
    ) -> HostJobResult:
        self.enqueue_gemm_s8(m, n, k, a, b)
        return self.drain(device=device, limit=1)[0]
