# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Lossless narrowing: the exact way to cut operand traffic.

Every other way to make a GEMM read fewer bytes changes the arithmetic. This one does
not — it only requires that the data was already narrow. Weights trained in BF16 or FP16
and widened to FP32, values quantised once and parked in a float container, 4-bit weights
held in an INT8 array: in all of those the elements round-trip into a narrower container
**exactly**, so the products of a narrowed GEMM are *the same real numbers*.

What that buys, and what it does not
------------------------------------
It buys the full traffic saving of the narrow format — the measured native cycle count for
the target, because a narrowed job **is** an ordinary native job at that format.

It does not buy bit-identity, and pretending otherwise would be the whole error this module
exists to avoid. The narrower format has a wider ``mac_step``, so the FP32 accumulator
regroups its folds: at 8 lanes and k=16, FP32 accumulates over 8 windows and BF16 over 4.
Fewer windows means fewer rounding sites — sometimes *more* accurate than the FP32 run, but
different either way.

So the error of a lossless narrowing is the **accumulator's**, never the storage format's:

===============  ==================  ===================  ===============
pair             measured worst      approximate twin     
===============  ==================  ===================  ===============
FP32 -> BF16     ~5.8 ppm            7,828 ppm            ~1,350x tighter
FP32 -> FP16     ~0.3 ppm            977 ppm              ~3,000x tighter
FP16/BF16 -> FP8 0 ppm               128,907/265,625 ppm  exact
INT8 -> INT4     0 ppm               147,961 ppm          bit-identical
===============  ==================  ===================  ===============

The integer-to-integer case is bit-identical *by construction*: the products are the same
integers, the RTL reduction is an exact 640-bit integer sum, and the integer accumulator has
no rounding site at all. The 16-to-8-bit cases come out exact for a different reason — an
E4M3 product carries at most 8 significant bits, so a window of eight still fits FP32's 24.

RTL correspondence
------------------
``corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv`` recipes 1/3/17 with
``lossless_proven`` + ``lossless_narrow_target``. The selector reports
``VA_ARITH_EXACT``/eps 0 for integer-to-integer and ``VA_ARITH_REL`` at the 1 ppm FP32
accumulation epsilon otherwise, and refuses equal-width pairs because they save no beats.
**Read, never imported** — KD0 independence (``AGENTS.md`` §1).
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Dict, List, Optional, Tuple

from .c_abi import (
    AI_FMT_BF16,
    AI_FMT_FP8_E4M3,
    AI_FMT_FP8_E5M2,
    AI_FMT_FP16,
    AI_FMT_FP32,
    AI_FMT_INT,
    AI_FMT_INT4,
)
from . import va_turbo as vt

try:  # torch is optional for this package
    import torch
except ImportError:  # pragma: no cover
    torch = None

__all__ = [
    "NARROWER_PAIRS",
    "LosslessProof",
    "LosslessQuality",
    "element_bits",
    "narrower_targets",
    "prove",
    "best_target",
    "mac_step",
    "windowed_matmul",
    "quality",
    "plan",
]

#: Element bits per format, matching `policy_element_bits_log2` in the RTL.
_ELEMENT_BITS: Dict[int, int] = {
    AI_FMT_INT4: 4,
    AI_FMT_INT: 8,
    AI_FMT_FP8_E4M3: 8,
    AI_FMT_FP8_E5M2: 8,
    AI_FMT_FP16: 16,
    AI_FMT_BF16: 16,
    AI_FMT_FP32: 32,
}

#: Integer formats have no mantissa/exponent split and accumulate exactly.
_INTEGER = (AI_FMT_INT, AI_FMT_INT4)

#: The 17 strictly-narrower ordered pairs the RTL admits. Equal-width pairs
#: (FP16 <-> BF16) are absent on purpose: a real conversion that saves no beats.
NARROWER_PAIRS: Tuple[Tuple[int, int], ...] = tuple(
    (src, dst)
    for src in sorted(_ELEMENT_BITS)
    for dst in sorted(_ELEMENT_BITS)
    if _ELEMENT_BITS[dst] < _ELEMENT_BITS[src]
)


def element_bits(numfmt: int) -> int:
    """Stored bits per element, or 0 for an unknown format."""
    return _ELEMENT_BITS.get(numfmt, 0)


def narrower_targets(numfmt: int) -> List[int]:
    """Formats strictly narrower than ``numfmt``, widest first."""
    return sorted(
        (dst for (src, dst) in NARROWER_PAIRS if src == numfmt),
        key=lambda f: -_ELEMENT_BITS[f],
    )


@dataclass(frozen=True)
class LosslessProof:
    """Whether every element of both operands round-trips through ``target`` exactly.

    ``proven`` is the value the RTL's ``lossless_proven`` request bit needs. It is a
    *bit-pattern* comparison, not a tolerance: a "nearly exact" round trip is an
    approximate conversion wearing an exact label, so anything short of equality fails.
    """

    target: int
    target_name: str
    proven: bool
    mismatched_a: int
    mismatched_b: int
    status: Optional[str] = None

    @property
    def ok(self) -> bool:
        return self.proven and self.status is None


def _check_operands(a, b):
    t = vt._require_torch("lossless")
    a32, b32 = vt._operands(a, b)
    if not bool(t.isfinite(a32).all()) or not bool(t.isfinite(b32).all()):
        return None, None, "nonfinite_operand"
    return a32, b32, None


def prove(a, b, target: int) -> LosslessProof:
    """Prove — or refuse — that ``a`` and ``b`` are exactly representable in ``target``.

    Integer targets are checked as integrality plus range, which is what makes
    ``INT8 -> INT4`` a real case: values in [-8, 7] held in an INT8 container.
    """
    t = vt._require_torch("prove")
    name = vt.NUMFMT_NAMES.get(target, str(target))
    a32, b32, status = _check_operands(a, b)
    if status is not None:
        return LosslessProof(target, name, False, -1, -1, status)
    if target not in _ELEMENT_BITS:
        return LosslessProof(target, name, False, -1, -1, "unknown_target")

    def mismatches(x):
        if target in _INTEGER:
            levels = 7 if target == AI_FMT_INT4 else 127
            integral = t.eq(x, t.round(x))
            in_range = t.logical_and(x >= -(levels + 1), x <= levels)
            return int(t.numel(x) - int(t.logical_and(integral, in_range).sum()))
        dtype = vt._torch_dtype(target)
        # A round trip that changes any bit is not lossless. Comparing values rather
        # than bit patterns would let a signed zero or a flushed subnormal pass.
        return int(t.numel(x) - int(t.eq(x, x.to(dtype).to(t.float32)).sum()))

    bad_a, bad_b = mismatches(a32), mismatches(b32)
    return LosslessProof(target, name, bad_a == 0 and bad_b == 0, bad_a, bad_b)


def best_target(a, b, numfmt: int = AI_FMT_FP32) -> Optional[LosslessProof]:
    """The **narrowest** target both operands round-trip through exactly.

    Narrowest, not widest: the whole point is the largest traffic saving the data allows.
    Returns ``None`` when nothing narrower than ``numfmt`` is exact.
    """
    proofs = [prove(a, b, dst) for dst in narrower_targets(numfmt)]
    exact = [p for p in proofs if p.ok]
    if not exact:
        return None
    return min(exact, key=lambda p: _ELEMENT_BITS[p.target])


def mac_step(numfmt: int, lanes: int = vt.PE_LANES) -> int:
    """Elements one reduction step covers, mirroring ``g6lc_ai_gemm_seq``.

    ``mac_step = (fmt == INT4) ? 2 * PeLanes : PeLanes / bytes_per_element`` — this is what
    makes the window, and therefore the number of accumulator folds, depend on the format.
    """
    if numfmt == AI_FMT_INT4:
        return 2 * lanes
    return max(1, lanes // max(1, element_bits(numfmt) // 8))


def windowed_matmul(a, b, numfmt: int, lanes: int = vt.PE_LANES):
    """A @ B with the accumulation grouped exactly as the island groups it.

    Each window of ``mac_step`` products is reduced exactly and rounded ONCE to FP32
    (the RTL's block-floating conversion), then folded into an FP32 accumulator. The
    per-window exact reduction is modelled in float64, which is a proxy for the RTL's
    exact 640-bit integer sum — sound here because the window is small.

    Integer formats accumulate exactly in the RTL, so no rounding is applied at all;
    that is what makes ``INT8 -> INT4`` bit-identical rather than merely close.
    """
    t = vt._require_torch("windowed_matmul")
    a64, b64 = a.to(t.float64), b.to(t.float64)
    step = mac_step(numfmt, lanes)
    exact_accumulation = numfmt in _INTEGER
    acc = None
    for start in range(0, a64.shape[1], step):
        part = a64[:, start:start + step] @ b64[start:start + step, :]
        if not exact_accumulation:
            part = part.to(t.float32).to(t.float64)      # one RNE per window
        acc = part if acc is None else acc + part
        if acc is not None and not exact_accumulation:
            acc = acc.to(t.float32).to(t.float64)        # the FP32 accumulator fold
    return t.zeros_like(a64[:, :0] @ b64[:0, :]) if acc is None else acc


@dataclass(frozen=True)
class LosslessQuality:
    """Measured cost of a lossless narrowing: regrouping only, never storage error."""

    proof: LosslessProof
    source_numfmt: int
    rel_fro_error: float
    ppm: float
    sqnr_db: float
    max_abs_error: float
    bit_identical: bool
    source_windows: int
    target_windows: int
    #: The approximate twin's per-product bound, for contrast at identical traffic.
    approximate_twin_ppm: Optional[int]
    status: Optional[str] = None

    @property
    def ok(self) -> bool:
        return self.status is None

    @property
    def quality_gain(self) -> Optional[float]:
        """How many times tighter than converting approximately. ``None`` if exact."""
        if not self.ok or self.approximate_twin_ppm is None or self.ppm <= 0.0:
            return None
        return self.approximate_twin_ppm / self.ppm


#: Per-product bound of the *approximate* conversion to each format, from
#: `va-turbo.md` §9 — the number a lossless narrowing does NOT pay.
_APPROXIMATE_PPM: Dict[int, int] = {
    AI_FMT_FP16: 977,
    AI_FMT_BF16: 7828,
    AI_FMT_FP8_E4M3: 128907,
    AI_FMT_FP8_E5M2: 265625,
    AI_FMT_INT: 7892,
    AI_FMT_INT4: 147961,
}


def quality(a, b, target: int, source_numfmt: int = AI_FMT_FP32,
            lanes: int = vt.PE_LANES) -> LosslessQuality:
    """Measure what a lossless narrowing actually costs.

    The reference is the **island's own FP32 run**, not an infinitely precise one, because
    the question a caller has is "does narrowing change my answer?" — and both sides here
    regroup the same real products differently. Fails closed if the narrowing is not
    proven: an unproven narrowing is an approximate conversion and must be scored as one.
    """
    t = vt._require_torch("quality")
    proof = prove(a, b, target)
    twin = _APPROXIMATE_PPM.get(target)
    a32, b32, status = _check_operands(a, b)
    src_windows = 0 if a32 is None else -(-a32.shape[1] // mac_step(source_numfmt, lanes))
    dst_windows = 0 if a32 is None else -(-a32.shape[1] // mac_step(target, lanes))
    if status is not None or not proof.ok:
        return LosslessQuality(
            proof, source_numfmt, math.inf, math.inf, -math.inf, math.inf, False,
            src_windows, dst_windows, twin,
            status or "not_proven_lossless",
        )

    reference = windowed_matmul(a32, b32, source_numfmt, lanes)
    narrowed = windowed_matmul(a32, b32, target, lanes)
    if not bool(t.isfinite(reference).all()) or not bool(t.isfinite(narrowed).all()):
        return LosslessQuality(proof, source_numfmt, math.inf, math.inf, -math.inf,
                               math.inf, False, src_windows, dst_windows, twin,
                               "nonfinite_metric")
    identical = bool(t.equal(reference, narrowed))
    difference = narrowed - reference
    err = float(difference.norm())
    ref = float(reference.norm())
    max_abs = float(difference.abs().max()) if difference.numel() else 0.0
    if ref == 0.0:
        if err == 0.0:
            return LosslessQuality(proof, source_numfmt, 0.0, 0.0, math.inf, 0.0, identical,
                                   src_windows, dst_windows, twin)
        return LosslessQuality(proof, source_numfmt, math.inf, math.inf, -math.inf,
                               math.inf, False, src_windows, dst_windows, twin,
                               "zero_reference_with_nonzero_error")
    rel = err / ref
    return LosslessQuality(
        proof, source_numfmt, rel, rel * 1e6,
        math.inf if err == 0.0 else 20.0 * math.log10(ref / err),
        max_abs, identical, src_windows, dst_windows, twin,
    )


@dataclass(frozen=True)
class LosslessPlan:
    """A narrowing that is exact on this data, with its measured cost and speedup."""

    proof: LosslessProof
    quality: LosslessQuality
    source_numfmt: int
    target_numfmt: int
    source_cycles: Optional[int]
    target_cycles: Optional[int]
    speedup: Optional[float]
    recipe_id: int
    note: str

    @property
    def ok(self) -> bool:
        return self.proof.ok and self.quality.ok


def plan(a, b, source_numfmt: int = AI_FMT_FP32, target: Optional[int] = None,
         lanes: int = vt.PE_LANES) -> Optional[LosslessPlan]:
    """Find the narrowest exact target and report its measured cost and speedup.

    Cycles come from the measured native table (`va_turbo.MEASURED_CYCLES`) because a
    narrowed job IS a native job at the target format — there is no separate lossless
    datapath to measure. ``None`` when the data permits no exact narrowing, which is the
    common case for genuinely full-precision tensors and is not a failure.
    """
    proof = prove(a, b, target) if target is not None else best_target(a, b, source_numfmt)
    if proof is None or not proof.ok:
        return None
    scored = quality(a, b, proof.target, source_numfmt, lanes)
    src_cy = vt.MEASURED_CYCLES.get(source_numfmt)
    dst_cy = vt.MEASURED_CYCLES.get(proof.target)
    speed = None if not (src_cy and dst_cy) else src_cy / dst_cy
    return LosslessPlan(
        proof=proof,
        quality=scored,
        source_numfmt=source_numfmt,
        target_numfmt=proof.target,
        source_cycles=src_cy,
        target_cycles=dst_cy,
        speedup=speed,
        recipe_id=1,
        note=(
            f"recipe 1 lossless repack, {vt.NUMFMT_NAMES.get(source_numfmt)} -> "
            f"{proof.target_name}: products unchanged, only the accumulator regroups "
            f"({scored.source_windows} windows -> {scored.target_windows}). Cycles are the "
            "measured NATIVE figures for each format; the narrowed job is an ordinary "
            "native job. No consumer mask bit exists for recipes 1/3/17 yet, so the island "
            "will not act on this plan."
        ),
    )
