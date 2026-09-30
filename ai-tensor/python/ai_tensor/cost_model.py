# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Island cost model and archetype recipe table (WP6 of the AI scaling plan).

Everything here is DERIVED: the cycle model is calibrated from measured ``AI_JOB``
records (bytes per cycle, cycles per beat, MAC issue rate, C-store rate) and applied to
shapes the island has not run. It exists so a host partitioner can decide *offload vs
host* and *which recipe* per layer from the published capability window, without
naming a model. It never overrides a measured record and never turns a projection into
a TOPS claim.

Archetypes (methodology H1): decisions key on the workload class, not on a network.
  A1 decode   m == 1 (or tiny), weight-panel reuse across tokens -> bytes-bound
  A2 prefill  m large -> MAC-bound
  A3 conv     im2col GEMM, K-group sensitive (measured on the diffusion UNet)
  A4 k-chain  K beyond the bank box -> accumulate chain (seed cost per block)
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional

from .c_abi import AI_FMT_BF16, AI_FMT_FP16, AI_FMT_FP32, AI_FMT_FP8_E4M3, AI_FMT_INT, AI_FMT_INT4

ELEM_BYTES = {AI_FMT_INT: 1, AI_FMT_INT4: 0.5, AI_FMT_FP8_E4M3: 1, AI_FMT_FP16: 2, AI_FMT_BF16: 2, AI_FMT_FP32: 4}


@dataclass(frozen=True)
class IslandModel:
    """Calibrated per-SKU constants. Defaults are the live g6lc64_ai SoC bench SKU
    (measured 2026-09-29/30): 8 B/cycle port at 1.005 cycles/beat, 512 K lanes, one
    output column per cycle, 8 B/cycle C store, ~70 cycles fixed per job."""

    bytes_per_cycle: float = 8.0
    cycles_per_beat: float = 1.005
    lanes: int = 512
    out_cols: int = 1
    store_bytes_per_cycle: float = 8.0
    fixed_cycles: float = 70.0
    clock_ghz: float = 2.0

    @classmethod
    def from_caps(cls, caps) -> "IslandModel":
        """Derive from a Caps view (dram_gbps nameplate, clock, macs_cycle)."""
        ghz = getattr(caps, "clock_khz", 2_000_000) / 1e6
        bpc = getattr(caps, "dram_gbps", 16) / ghz if ghz else 8.0
        macs = getattr(caps, "macs_cycle", 512)
        lanes = min(512, macs)
        return cls(bytes_per_cycle=bpc, lanes=lanes, out_cols=max(1, macs // lanes), clock_ghz=ghz)


def archetype(m: int, n: int, k: int, conv: bool = False) -> str:
    if conv:
        return "A3"
    return "A1" if m <= 4 else "A2"


def gemm_cycles(model: IslandModel, m: int, n: int, k: int, fmt: int, *, resident_b: bool = False,
                resident_a: bool = False) -> Dict[str, float]:
    """Derived cycles of one island job (no K chain). Returns the phase breakdown."""
    eb = ELEM_BYTES[fmt]
    a_bytes = m * k * eb
    b_bytes = n * k * eb
    la = 0.0 if resident_a else (a_bytes / model.bytes_per_cycle) * model.cycles_per_beat
    lb = 0.0 if resident_b else (b_bytes / model.bytes_per_cycle) * model.cycles_per_beat
    ksteps = -(-int(k * eb) // model.lanes)
    mac = m * (-(-n // model.out_cols)) * ksteps
    store = m * n * 4 / min(model.bytes_per_cycle, model.store_bytes_per_cycle)
    # the trail store overlaps the MAC; only the tail past the last MAC issue is exposed
    tail = max(0.0, store - mac)
    total = model.fixed_cycles + la + lb + mac + tail
    return {"la": la, "lb": lb, "mac": mac, "store_tail": tail, "cycles": total,
            "macs_per_cycle": (m * n * k) / total if total else 0.0,
            "us": total / (model.clock_ghz * 1e3)}


def host_gemm_cycles(m: int, n: int, k: int, fmt: int, *, host_macs_per_cycle: float = 8.0,
                     host_ghz: float = 1.0) -> float:
    """Host-side estimate (in island clock cycles) for the offload decision: a scalar/T0
    path at ``host_macs_per_cycle`` (the measured T0 dot4 is ~1 MAC/cycle; 8 is generous)."""
    return (m * n * k) / host_macs_per_cycle * (1.0 if host_ghz == 0 else 1.0)


def offload_decision(model: IslandModel, m: int, n: int, k: int, fmt: int, **kw) -> Dict[str, object]:
    isl = gemm_cycles(model, m, n, k, fmt, **kw)
    host = host_gemm_cycles(m, n, k, fmt)
    return {"archetype": archetype(m, n, k), "island_cycles": isl["cycles"], "host_cycles": host,
            "offload": isl["cycles"] < host, "speedup": host / isl["cycles"] if isl["cycles"] else 0.0,
            "bound": "bytes" if (isl["la"] + isl["lb"]) > isl["mac"] else "mac"}


# Recipe table by archetype: the measured-best recipe per class (qualified on the pinned
# fixtures, see fixtures/qual/README.md), chosen from the formats the caps grant.
RECIPES = {
    "A1": {"weights": AI_FMT_INT, "k_group": 128, "head": AI_FMT_FP16,
           "why": "distilgpt2 va-select: INT8 g128 + FP16 lm_head at 0.369x FP32 bytes, ppl -0.1 %"},
    "A2": {"weights": AI_FMT_INT, "k_group": 128, "head": AI_FMT_FP16,
           "why": "same recipe; MAC-bound, bytes matter less, quality budget identical"},
    "A3": {"weights": AI_FMT_INT, "k_group": 64, "head": None,
           "why": "segmind/tiny-sd: INT8 g128 30.7 dB FAIL, g64 35.0 dB PASS; BF16 48.5 dB when granted"},
    "A4": {"weights": AI_FMT_INT, "k_group": 128, "head": AI_FMT_FP16,
           "why": "K chain: accumulate seed costs ~2 % per block; prefer one flat-panel job when the banks admit it"},
}


def recipe_for(arch: str, granted: Optional[set] = None, prefer_bf16_conv: bool = False) -> Dict[str, object]:
    r = dict(RECIPES[arch])
    if granted is not None:
        if r["weights"] not in granted:
            raise ValueError(f"recipe weight format {r['weights']} is not granted")
        if r.get("head") is not None and r["head"] not in granted:
            r["head"] = None
        if arch == "A3" and prefer_bf16_conv and AI_FMT_BF16 in granted:
            r["weights"], r["k_group"] = AI_FMT_BF16, 0
    return r
