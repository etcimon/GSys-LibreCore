# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Host probe dict (mirrors Rust ProbeReport JSON keys)."""

from __future__ import annotations

from typing import Any, Dict, Optional

from .c_abi import PLIC_SOURCE_ISLAND_P3
from .device import Caps, Device, Pmu
from .profile import Profile


def probe_dict(
    *,
    device: Optional[Device] = None,
    profile: Optional[Profile] = None,
    profile_path: Optional[str] = None,
) -> Dict[str, Any]:
    """Build a discovery dict for host adapters (stable keys)."""
    pr = profile
    if pr is None and profile_path:
        pr = Profile.load_file(profile_path)
    if pr is None:
        pr = Profile(id="sim-v0", backend="sim", wait_policy="poll", submit_mode="latch")
    dev = device or Device("sim")
    caps: Caps = dev.caps()
    pmu: Pmu = dev.pmu()
    return {
        "package": "ai-tensor",
        "abi_rev": "0.1.0",
        "profile_id": pr.id,
        "backend": dev.backend,
        "wait_policy": getattr(pr, "wait_policy", "poll") or "poll",
        "submit_mode": getattr(pr, "submit_mode", "latch") or "latch",
        "mmio_base": pr.mmio_base,
        "plic_source": pr.plic_source or PLIC_SOURCE_ISLAND_P3,
        "caps": {
            "acc_tile_m": caps.acc_tile_m,
            "acc_tile_n": caps.acc_tile_n,
            "acc_tile_k": caps.acc_tile_k,
            "macs_per_cycle": caps.macs_per_cycle,
            "noc_width": caps.noc_width,
            "clusters": caps.clusters,
        },
        "pmu": pmu.as_dict(),
        "irq": {
            "plic_source": PLIC_SOURCE_ISLAND_P3,
            "clear_before_plic_complete": True,
        },
        "features": list(getattr(pr, "features", []) or []),
    }
