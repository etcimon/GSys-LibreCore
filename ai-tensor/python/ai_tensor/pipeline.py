# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Stacking recipes: the host mirror of the RTL's ``va_turbo_compose``.

The 32 V/A-Turbo recipes are not alternatives. Fitting the measured per-job cycles against
work terms decomposes them, and that decomposition **is** the composition rule::

    cycles ~= steps + beta(fmt) * read_beats + 11
    steps   = m * n * ceil(k_bytes / PeLanes)
    beta    = 1.14 (FP32)  1.28 (FP16)  1.56 (INT8)  2.13 (INT4)

``beta`` comes straight off the measured residency sweeps (FP32 669->523 over 128 beats,
INT8 189->139 over 32) and the ``+11`` constant falls out identically for both. It *rises*
as the format narrows, because operand traffic hides under compute and a narrow job has less
compute to hide it under -- which is why residency is worth **more** after narrowing.

So each family reduces a different term:

===================================  =======  =======  ===========
family                               steps    beats    retirement
===================================  =======  =======  ===========
narrowing (1/3/17, 4-7, 18-20, 29)   yes      yes      -
residency (16, 17)                   -        yes      -
zero-skip (2)                        yes      -        -
grouping (9-15)                      -        -        yes (blocked)
approx arithmetic (21/25/27/28/...)  -        -        -
===================================  =======  =======  ===========

The measured stack: FP32 -> INT8 lossless narrowing with both operands resident is 139
cycles against FP32's 669, i.e. **4.813x**, and ``3.540 * 1.359 = 4.81`` exactly. Note which
residency figure -- composing with FP32's 1.279x instead predicts 4.53x and understates it.

Why this is not a loop
----------------------
Two structural facts remove the need for a loopback over the 32 recipes:

1. **Narrowing collapses.** Exact representability is transitive downward, so
   FP32 -> BF16 -> FP8 is identical to FP32 -> FP8. Iterating gains nothing beyond picking
   the narrowest exact target once, which :func:`ai_tensor.lossless.best_target` already
   does. ``compose(a, a) == a`` is an exact law in the RTL too.
2. **Every lever strictly decreases a monotone quantity** (``k_bytes``, then ``steps``, then
   ``beats``), so a staged pipeline terminates by construction.

The ordering hazard
-------------------
Both residency keys in ``g6lc_ai_gemm_seq`` include the numeric format, so **a narrowing
that changes the format is a residency miss by construction**. Stacking them is only valid
when the resident tile is already stored at the target format -- convert once at load, then
reuse across many jobs. This module refuses the combination unless the caller says so, for
the same reason the RTL does: a planner that narrowed *inside* a reuse window would silently
destroy the residency it was trying to stack with.

**Read, never imported** -- KD0 independence (``AGENTS.md`` §1).
"""

from __future__ import annotations

from dataclasses import dataclass, field
import math
from typing import Dict, List, Optional, Sequence, Tuple

from .c_abi import AI_FMT_FP32, AI_FMT_INT, AI_FMT_INT4
from . import lossless
from . import va_turbo as vt

__all__ = [
    "BETA",
    "MODEL_CONSTANT",
    "CycleModel",
    "DECODE_N16_RESIDUAL",
    "MEASURED_DECODE",
    "MEASURED_DECODE_N16",
    "MEASURED_DOT_CELLS",
    "MEASURED_ENGINE_CELLS",
    "MEASURED_LANE_SWEEP",
    "MODEL_CONSTANT_BY_HARNESS",
    "RetireAnalysis",
    "ShapeAnalysis",
    "Stage",
    "PipelineRefused",
    "PipelineResult",
    "row_bytes",
    "lane_groups",
    "area_to_lanes",
    "optimal_lanes",
    "decode_b_share",
    "decode_residency_ceiling",
    "shape_analysis",
    "retire_analysis",
    "steps_for",
    "beats_for",
    "model_cycles",
    "cycles_for",
    "pipeline",
]

#: Marginal cycles per operand read beat, per format.
#:
#: VALIDATED OUT-OF-SAMPLE ACROSS THE LANE AXIS. These were first fitted on the
#: `tb_g6lc_ai_gemm_concurrent` residency sweeps at PeLanes=8 -- FP32 (669-523)/128 and
#: INT8 (189-139)/32 -- and then checked against the independent
#: `ai-gemm-codec-basis` lane sweeps on `tb_g6lc_ai_gemm_backend`, which cover
#: PeLanes 8/16/32/64. Solving `beta = (cycles - steps - c)/beats` at every one of those
#: 16 points (4 formats x 4 lane counts) gives a spread of EXACTLY zero per format and
#: reproduces the numbers below to the digit. See `MEASURED_LANE_SWEEP`.
#:
#: Two consequences worth stating, because they are what make the model usable off the
#: reference shape:
#:
#: * `beta` is INDEPENDENT of lane count. Lanes move the `steps` term only, which is why
#:   the same constant predicts a 64-lane job from an 8-lane fit.
#: * the two testbenches differ by exactly ONE cycle in the additive constant (11 for
#:   `gemm_concurrent`, 10 for `gemm_backend`) and not at all in `beta`, so the constant
#:   is per-harness overhead while `beta` is the machine.
BETA: Dict[int, float] = {
    AI_FMT_FP32: 1.140625,
    vt.AI_FMT_FP16: 1.28125,
    vt.AI_FMT_BF16: 1.28125,
    AI_FMT_INT: 1.5625,
    vt.AI_FMT_FP8_E4M3: 1.5625,
    vt.AI_FMT_FP8_E5M2: 1.5625,
    AI_FMT_INT4: 2.125,
}

#: Fixed per-job cost on `tb_g6lc_ai_gemm_concurrent`, which is where the measured cycle
#: table comes from. Falls out identically for the two independently swept formats there,
#: and the backend testbench's own sweeps land on 10 with the SAME beta -- see `BETA`.
MODEL_CONSTANT = 11

#: Per-harness overhead. Not a tuning knob: the difference between these two is one cycle
#: of testbench, and any new harness should be fitted rather than assumed.
MODEL_CONSTANT_BY_HARNESS: Dict[str, int] = {
    "gemm_concurrent": 11,
    "gemm_backend": 10,
}

#: The out-of-sample validation set: `tb_g6lc_ai_gemm_backend` +measure at m=n=8, k=16,
#: from `ai-gemm-codec-basis` runs, as {format: {lanes: cycles}}. Every entry is
#: reproduced exactly by `steps + BETA*beats + 10`, which is the evidence that the
#: decomposition is the machine's and not the fit's.
#:
#: It also shows the lane optima *as a consequence* rather than as a table: cycles stop
#: falling once `lanes >= row_bytes`, i.e. INT4 saturates at 8, INT8 at 16, FP16 at 32 and
#: FP32 at 64. That is `optimal_lanes` below.
MEASURED_LANE_SWEEP: Dict[int, Dict[int, int]] = {
    AI_FMT_INT:  {8: 188, 16: 124, 32: 124, 64: 124},
    AI_FMT_INT4: {8: 108, 16: 108, 32: 108, 64: 108},
    vt.AI_FMT_FP16: {8: 348, 16: 220, 32: 156, 64: 156},
    AI_FMT_FP32: {8: 668, 16: 412, 32: 284, 64: 220},
}

MEASURED = vt.MEASURED
MODELED = "modeled_from_decomposition"


def row_bytes(numfmt: int, k: int) -> int:
    """Operand row in bytes -- what a dot product actually consumes."""
    return int(math.ceil(k * vt._K_BYTES[numfmt]))


#: MEASURED area of the combinational MAC array (`g6lc_ai_pe_dot`), isolated synthesis,
#: {lanes: generic cells}. Zero sequential cells at every point.
#:
#: The headline: at 8 lanes the array is **5,867 of the engine's 7,530 cells, i.e. 78%**,
#: at a near-constant ~733 cells per lane. The engine is essentially all multiplier.
#:
#: That is the number that decides the approximate-arithmetic family (truncation 21/25/
#: 30/31, Mitchell 27/28). Those recipes are cycle-neutral BY CONSTRUCTION -- they change
#: no operand byte and no reduction step -- so cycles are the wrong instrument for them.
#: Their only path to throughput is AREA -> LANES -> steps, and this table says the area
#: target is large rather than marginal, which is the opposite of what "cycle-neutral"
#: might suggest.
MEASURED_DOT_CELLS: Dict[int, int] = {4: 2868, 8: 5867, 16: 11834}

#: Whole-engine cells at 8 lanes, for the fraction above.
MEASURED_ENGINE_CELLS = 7530


def area_to_lanes(numfmt: int, k: int, shrink: float,
                  base_lanes: int = vt.PE_LANES) -> Tuple[int, float]:
    """What a `shrink`-times-smaller multiplier buys, as (lanes, cycle speedup).

    The array is linear and dominates, so a constant AREA budget buys `shrink` times the
    lanes. Lanes then reduce `steps` until `lanes >= row_bytes`, after which they are pure
    area -- measured: 32 -> 64 lanes gave FP16 exactly nothing.

    So the trade has a hard ceiling, and for FP32 at k=16 it is `668/220 = 3.04x`, needing
    an 8x smaller multiplier. Lossless narrowing to INT8 already gives 3.54x at zero error
    *and* frees area, so it dominates whenever the data permits it. The niche that remains
    for truncation is data whose RANGE forbids conversion: it drops mantissa bits while
    keeping the FP32 exponent, and `truncate-10` at 1,953 ppm is 4x more accurate than
    BF16 while preserving FP32 range -- a point no conversion recipe covers.
    """
    if shrink <= 0:
        raise ValueError("shrink must be positive")
    lanes = min(int(base_lanes * shrink), optimal_lanes(numfmt, k))
    lanes = max(lanes, 1)
    base = model_cycles(numfmt, 8, 8, k, lanes=base_lanes)
    got = model_cycles(numfmt, 8, 8, k, lanes=lanes)
    return lanes, base / got


def optimal_lanes(numfmt: int, k: int) -> int:
    """Lanes beyond which a single dot gains nothing: ``row_bytes``.

    The RTL ends a reduction when ``mac_step >= k``, so a dot can use at most
    ``row_bytes`` lanes and `steps` bottoms out when ``ceil(row_bytes/lanes) == 1``.

    This *derives* the measured lane optima instead of tabulating them. The policy
    package records the rule as "twice the element width in lanes" with a warning that the
    fit is k=16-specific; that is this rule evaluated at k=16, where ``row_bytes`` happens
    to equal twice the element width in bytes. `MEASURED_LANE_SWEEP` confirms all four
    saturation points (INT4 8, INT8 16, FP16 32, FP32 64), and the general form is what
    should be used at other k.
    """
    return row_bytes(numfmt, k)


def lane_groups(numfmt: int, k: int, lanes: int = vt.PE_LANES) -> int:
    """Independent dots a provisioned lane array can host, i.e. IDLE-LANE GROUPS.

    A dot consumes ``row_bytes`` of lanes, so anything beyond that is idle and can only
    be useful on a *different* output. This is the quantity narrowing manufactures: at
    64 lanes and k=16, FP32 uses all 64 (``groups=1``) while INT8 uses 16
    (``groups=4``) and INT4 uses 8 (``groups=8``).
    """
    needed = row_bytes(numfmt, k)
    return max(1, lanes // needed) if needed <= lanes else 1


def steps_for(numfmt: int, m: int, n: int, k: int, lanes: int = vt.PE_LANES,
              c_ports: int = 1) -> int:
    """Reduction steps: one per ``mac_step`` window per output element.

    Note the floor: ``ceil(k_bytes/lanes)`` bottoms out at 1, so ``steps >= m*n``. That
    floor **is** the retirement ceiling -- the RTL writes one C element on its last
    reduction step through a single ``c_w_req`` port, so an engine cannot retire faster
    than one element per cycle however many lanes it has.

    ``c_ports`` models widening that port. It divides the step count only up to the
    number of idle-lane groups actually available, because two C ports cannot retire two
    elements per cycle unless two dots finished in that cycle. That joint constraint is
    the whole result: see :func:`retire_analysis`.
    """
    if c_ports < 1:
        raise ValueError("c_ports must be >= 1")
    raw = m * n * max(1, int(math.ceil(row_bytes(numfmt, k) / lanes)))
    usable = min(c_ports, lane_groups(numfmt, k, lanes))
    return int(math.ceil(raw / usable))


def beats_for(numfmt: int, m: int, n: int, k: int, resident_a: bool = False,
              resident_b: bool = False, beat_bytes: int = 8) -> int:
    """Operand read beats. A resident operand issues none, which is the whole of its gain."""
    row = k * vt._K_BYTES[numfmt]
    a = 0 if resident_a else int(math.ceil(m * row / beat_bytes))
    b = 0 if resident_b else int(math.ceil(n * row / beat_bytes))
    return a + b


def model_cycles(numfmt: int, m: int = 8, n: int = 8, k: int = 16,
                 resident_a: bool = False, resident_b: bool = False,
                 lanes: int = vt.PE_LANES, skip_fraction: float = 0.0,
                 c_ports: int = 1) -> float:
    """`steps + beta*beats + 11`, the decomposition above.

    ``skip_fraction`` models zero-skip, which removes a fraction of the STEP term only --
    never the traffic, because a skipped product still had to be read. ``c_ports`` models
    widening the single C write port, which is a PROJECTION: no such RTL exists.
    """
    if not 0.0 <= skip_fraction < 1.0:
        raise ValueError("skip_fraction must be in [0, 1)")
    steps = steps_for(numfmt, m, n, k, lanes, c_ports) * (1.0 - skip_fraction)
    beats = beats_for(numfmt, m, n, k, resident_a, resident_b)
    # CEIL the work terms before adding the constant. Every square-tile point has an
    # integral `beta*beats`, so this was invisible until the decode measurement: at
    # m=1 every fractional case landed on .125 and measured exactly one cycle higher.
    # A partial beat still costs a whole cycle.
    return math.ceil(steps + BETA[numfmt] * beats) + MODEL_CONSTANT


@dataclass(frozen=True)
class ShapeAnalysis:
    """Where a shape's cycles actually go, and therefore which lever applies.

    The two terms scale differently -- `steps` with ``m*n`` and `beats` with ``m+n`` --
    so the optimisation priority INVERTS between shapes. A square prefill tile is
    compute-bound and wants lanes and steps; a decode row (m=1) is traffic-bound and
    almost all of that traffic is B, the weight matrix, re-read for every token.
    """

    numfmt: int
    m: int
    n: int
    k: int
    lanes: int
    steps: int
    beats: int
    a_beats: int
    b_beats: int
    cycles: float
    traffic_share: float
    b_share_of_traffic: float
    resident_b_speedup: float
    resident_both_speedup: float


#: MEASURED decode residency, m=1 n=8 k=16 PeLanes=8, one engine, from the
#: `DECODE` lines of `tb_g6lc_ai_gemm_concurrent`:
#: {format: (cold, warm_a, warm_b, warm_both)}.
#:
#: Against the SQUARE tile's 1.1225x (B) and 1.2792x (both) for FP32, decode measures
#: 1.859x and 2.107x -- confirming that a square tile is the least favourable shape for
#: residency. But it also corrects the projection: at 8 lanes the decode gain SATURATES
#: near 2x, and the cap is `steps + c`, not traffic. For INT4 the constant alone is 58%
#: of the resident-both time, which is why INT4 has the WORST decode ratio (1.773x)
#: despite B being the same 8/9 of its traffic.
MEASURED_DECODE: Dict[int, Tuple[int, int, int, int]] = {
    AI_FMT_INT:  (56, 52, 31, 27),
    AI_FMT_INT4: (39, 36, 22, 19),
    vt.AI_FMT_FP16: (90, 84, 49, 43),
    AI_FMT_FP32: (158, 148, 85, 75),
}

#: The same experiment at n=16, reached by deriving the harness memory slots from the
#: geometry (the fixed 512 B B-sub-slot had refused FP32 at n=16, k=16, which needs
#: 1,024 B). FP32 resident-B measures 298 -> 153 = **1.948x** and resident-both
#: 298 -> 143 = 2.084x, against predictions of 1.980x / 2.122x -- right to ~1.6%. B's
#: share came out 941/1000, exactly `n/(m+n) = 16/17`.
MEASURED_DECODE_N16: Dict[int, Tuple[int, int, int, int]] = {
    AI_FMT_INT:  (100, 96, 51, 47),
    AI_FMT_INT4: (67, 64, 34, 31),
    vt.AI_FMT_FP16: (166, 160, 85, 79),
    AI_FMT_FP32: (298, 288, 153, 143),
}

#: KNOWN MODEL RESIDUAL at decode n=16: the model is 3 cycles LOW for every one of the
#: four formats, and exact at n=8.
#:
#: Recorded rather than fitted away, because two points cannot determine the term and
#: the obvious candidate is already refuted: C write beats double from 4 to 8 between
#: those points, and a 0.75 cy/beat write term fits BOTH decode points exactly -- then
#: over-predicts the square 8x8 tile by 22 cycles (32 write beats). So the C drain
#: appears to be hidden under compute when `steps` is large (512 on the square tile) and
#: exposed when it is small (128 at decode), which is a `max`-shaped effect rather than a
#: linear one. Pinning it needs a third n.
#:
#: The residual is format-INDEPENDENT, so it is not a beta error.
DECODE_N16_RESIDUAL = 3


def decode_b_share(m: int, n: int) -> float:
    """B's share of read beats: ``n/(m+n)``, and nothing else.

    Measured identically at 888/1000 for every format, because `row_bytes` and `beta`
    cancel. B's dominance of decode traffic is a property of the SHAPE ALONE, so it does
    not need re-measuring per format -- which is why one number covered all four.
    """
    return n / (m + n) if (m + n) else 0.0


def decode_residency_ceiling(numfmt: int, k: int, lanes: int = vt.PE_LANES) -> float:
    """The ``n -> inf`` limit of decode resident-B: ``1 + beta*(row_bytes/8)/steps_per_elem``.

    This reconciles two figures that looked contradictory. At m=1 both `steps` and
    `beats` grow linearly in n, so the ratio converges rather than diverging -- which is
    the "saturates near 2x" the measurement found at 8 lanes. But the limit is divided by
    ``ceil(row_bytes/lanes)``, so it RISES as lanes shrink the step term:

        FP32 k=16 at 8 lanes   -> 2.14x   (measured 1.859x at n=8, approaching it)
        FP32 k=16 at 64 lanes  -> 10.12x
        FP32 k=256 at 1024     -> ~147x

    So decode residency is worth much more on a well-provisioned array than on the
    8-lane test corner, and the shipped SKU (PeLanes=256) has ``steps_per_elem == 1``
    for every format at k <= 256. The ceiling ignores the additive constant, so it is
    approached from below and is an upper bound at finite n.
    """
    rb = row_bytes(numfmt, k)
    return 1.0 + BETA[numfmt] * (rb / 8.0) / max(1, math.ceil(rb / lanes))


def shape_analysis(numfmt: int, m: int, n: int, k: int,
                   lanes: int = vt.PE_LANES) -> ShapeAnalysis:
    """Quantify the prefill/decode inversion for one shape.

    The decode case is the one worth running: at m=1 the weight matrix is essentially all
    of the traffic, so resident-B -- recipe 16, already implemented and verified -- is
    worth far more than the 1.279x measured on a square tile, which is the least
    favourable shape for it.
    """
    rb = row_bytes(numfmt, k)
    a_beats = math.ceil(m * rb / 8)
    b_beats = math.ceil(n * rb / 8)
    steps = steps_for(numfmt, m, n, k, lanes)
    total = model_cycles(numfmt, m, n, k, lanes=lanes)
    traffic = BETA[numfmt] * (a_beats + b_beats)
    warm_b = model_cycles(numfmt, m, n, k, resident_b=True, lanes=lanes)
    warm_both = model_cycles(numfmt, m, n, k, resident_a=True, resident_b=True, lanes=lanes)
    return ShapeAnalysis(
        numfmt=numfmt, m=m, n=n, k=k, lanes=lanes,
        steps=steps, beats=a_beats + b_beats, a_beats=a_beats, b_beats=b_beats,
        cycles=total,
        traffic_share=traffic / total,
        b_share_of_traffic=b_beats / (a_beats + b_beats) if a_beats + b_beats else 0.0,
        resident_b_speedup=total / warm_b,
        resident_both_speedup=total / warm_both,
    )


@dataclass(frozen=True)
class RetireAnalysis:
    """Why more lanes, or more C ports, buy nothing on their own."""

    numfmt: int
    lanes: int
    k: int
    row_bytes: int
    steps: int
    elements: int
    groups: int
    bound_by: str
    lanes_alone: float
    c_ports_alone: float
    both: float


def retire_analysis(numfmt: int, m: int = 8, n: int = 8, k: int = 16,
                    lanes: int = vt.PE_LANES, widen: int = 2) -> RetireAnalysis:
    """Quantify the JOINT constraint that the measured refutations were both halves of.

    Three separate RTL measurements looked like dead ends individually:

    * INT4 gained **0%** past 8 lanes, and INT8/FP8 nothing past 16;
    * 16 -> 32 lanes was **byte-identical** for INT8 at the reference shape;
    * grouping (recipes 9-15) produced no speedup at all.

    The model explains all three with one mechanism, and shows they are not independent
    failures. ``steps >= m*n`` because one C port retires one element per cycle, so:

    * more **lanes** stop helping the moment ``row_bytes <= lanes`` (retire-bound);
    * more **C ports** cannot help while ``groups == 1``, since two ports need two dots
      to have finished;
    * and ``groups > 1`` only exists when ``lanes > row_bytes`` -- which is exactly what
      **narrowing manufactures**.

    So lanes and C ports are a joint requirement on a narrowed format, and testing either
    alone correctly measured nothing. FP32 is the clean control: at 64 lanes it uses all
    64 (``groups == 1``), so no number of C ports helps it.
    """
    base = model_cycles(numfmt, m, n, k, lanes=lanes)
    wider_lanes = model_cycles(numfmt, m, n, k, lanes=lanes * widen)
    more_ports = model_cycles(numfmt, m, n, k, lanes=lanes, c_ports=widen)
    both = model_cycles(numfmt, m, n, k, lanes=lanes * widen, c_ports=widen)
    steps = steps_for(numfmt, m, n, k, lanes)
    groups = lane_groups(numfmt, k, lanes)
    return RetireAnalysis(
        numfmt=numfmt, lanes=lanes, k=k, row_bytes=row_bytes(numfmt, k),
        steps=steps, elements=m * n, groups=groups,
        bound_by="retire" if steps == m * n else "lanes",
        lanes_alone=base / wider_lanes,
        c_ports_alone=base / more_ports,
        both=base / both,
    )


@dataclass(frozen=True)
class CycleModel:
    """Cycles for a configuration, with the provenance that produced them."""

    cycles: float
    provenance: str
    numfmt: int
    resident_a: bool
    resident_b: bool
    skip_fraction: float

    @property
    def measured(self) -> bool:
        return self.provenance == MEASURED


def cycles_for(numfmt: int, m: int = 8, n: int = 8, k: int = 16,
               resident_a: bool = False, resident_b: bool = False,
               lanes: int = vt.PE_LANES, skip_fraction: float = 0.0) -> CycleModel:
    """Measured cycles where a measurement exists; the model elsewhere, labelled.

    The measured table only covers the reference shape (m=n=8, k=16, PeLanes=8), so any
    other shape is modelled even for a format that was swept.
    """
    reference_shape = (m, n, k, lanes) == (8, 8, 16, vt.PE_LANES)
    if reference_shape and skip_fraction == 0.0:
        residency = ("both" if resident_a and resident_b else
                     "a" if resident_a else "b" if resident_b else "none")
        table = vt.MEASURED_RESIDENCY_CYCLES.get(numfmt)
        if table is not None and residency in table:
            return CycleModel(float(table[residency]), MEASURED, numfmt,
                              resident_a, resident_b, 0.0)
        if residency == "none" and numfmt in vt.MEASURED_CYCLES:
            return CycleModel(float(vt.MEASURED_CYCLES[numfmt]), MEASURED, numfmt,
                              False, False, 0.0)
    return CycleModel(
        model_cycles(numfmt, m, n, k, resident_a, resident_b, lanes, skip_fraction),
        MODELED, numfmt, resident_a, resident_b, skip_fraction,
    )


@dataclass(frozen=True)
class Stage:
    """One step of a pipeline.

    ``kind`` is the resource the stage acts on, which is what decides composability:
    ``narrow`` (steps + beats), ``resident`` (beats), ``skip`` (steps), ``group``
    (retirement), ``approx`` (error only).
    """

    kind: str
    target: Optional[int] = None
    resident_a: bool = False
    resident_b: bool = False
    skip_fraction: float = 0.0
    groups_log2: int = 0
    eps_ppm: int = 0
    recipe: str = ""

    def __post_init__(self):
        if self.kind not in ("narrow", "resident", "skip", "group", "approx"):
            raise ValueError(f"unknown stage kind {self.kind!r}")


@dataclass(frozen=True)
class PipelineRefused:
    """A sequence that must not be applied, and why.

    Refusal is the point: silently dropping one stage's requirement would be worse than
    not composing at all.
    """

    reason: str
    rule: str

    def __bool__(self) -> bool:
        return False


@dataclass(frozen=True)
class PipelineResult:
    """A validated stack, with its composed cost and error."""

    stages: Tuple[Stage, ...]
    source_numfmt: int
    target_numfmt: int
    baseline: CycleModel
    composed: CycleModel
    eps_ppm: int
    exact: bool
    notes: Tuple[str, ...] = field(default_factory=tuple)

    def __bool__(self) -> bool:
        return True

    @property
    def speedup(self) -> float:
        return self.baseline.cycles / self.composed.cycles

    @property
    def provenance(self) -> str:
        """MEASURED only when BOTH endpoints are, since the ratio needs both."""
        return MEASURED if (self.baseline.measured and self.composed.measured) else MODELED


def pipeline(stages: Sequence[Stage], source_numfmt: int = AI_FMT_FP32,
             m: int = 8, n: int = 8, k: int = 16, lanes: int = vt.PE_LANES,
             *, resident_at_target: bool = False,
             max_rel_error_ppm: Optional[float] = None):
    """Validate an ordered stack and report its composed cost.

    Enforces the same rules as the RTL ``va_turbo_compose``:

    * two narrowings to **different** targets conflict -- one operand store, one target;
    * two narrowings to the **same** target collapse to one (narrowing is idempotent);
    * a narrowing that changes the format plus a residency stage is **refused** unless
      ``resident_at_target`` says the resident tile is already at the target format;
    * conflicting group geometries are refused;
    * per-product error terms **add**, so stacking cannot launder error;
    * the budget, if given, is checked against the **composed** bound, not per stage.

    Returns a :class:`PipelineResult`, or a :class:`PipelineRefused` which is falsey.
    """
    target = source_numfmt
    resident_a = resident_b = False
    skip_fraction = 0.0
    groups_log2 = 0
    eps_ppm = 0
    notes: List[str] = []
    seen_narrow = False

    for stage in stages:
        if stage.kind == "narrow":
            if stage.target is None:
                return PipelineRefused("a narrowing stage needs a target format", "narrow.target")
            if seen_narrow and stage.target != target:
                return PipelineRefused(
                    f"two different conversion targets ({vt.NUMFMT_NAMES.get(target)} then "
                    f"{vt.NUMFMT_NAMES.get(stage.target)}): there is one operand store, so "
                    "one target, and honouring either would violate the other's bound",
                    "conflict.target",
                )
            if seen_narrow:
                notes.append(
                    "second narrowing to the same target collapsed: exact representability "
                    "is transitive downward, so narrowing is idempotent"
                )
                continue
            if lossless.element_bits(stage.target) >= lossless.element_bits(target):
                return PipelineRefused(
                    f"{vt.NUMFMT_NAMES.get(stage.target)} is not narrower than "
                    f"{vt.NUMFMT_NAMES.get(target)}, so it saves no beats and a bound "
                    "attached to it would be a claim about a plan that buys nothing",
                    "narrow.not_narrower",
                )
            target = stage.target
            seen_narrow = True
            eps_ppm += stage.eps_ppm
        elif stage.kind == "resident":
            resident_a = resident_a or stage.resident_a
            resident_b = resident_b or stage.resident_b
        elif stage.kind == "skip":
            skip_fraction = max(skip_fraction, stage.skip_fraction)
        elif stage.kind == "group":
            if groups_log2 and stage.groups_log2 and groups_log2 != stage.groups_log2:
                return PipelineRefused(
                    "two different group geometries: one engine retires one shape",
                    "conflict.groups",
                )
            groups_log2 = stage.groups_log2 or groups_log2
            notes.append(
                "grouping is selection metadata only: one C write port caps retirement at "
                "one element per cycle, so no group count is a measured speedup"
            )
        else:  # approx
            eps_ppm += stage.eps_ppm
            notes.append(
                f"{stage.recipe or 'approximate arithmetic'} adds error and no throughput: "
                "it narrows no storage, so its measured cycle speedup is exactly 1.000x"
            )

    # THE ORDERING HAZARD. The residency keys include the format, so a format change is a
    # miss by construction unless the resident tile is already at the target.
    if (resident_a or resident_b) and target != source_numfmt and not resident_at_target:
        return PipelineRefused(
            f"narrowing to {vt.NUMFMT_NAMES.get(target)} composed with residency, but the "
            "residency key includes the numeric format, so the resident tile would MISS. "
            "Convert once at load and pass resident_at_target=True, or drop the residency "
            "stage -- narrowing inside a reuse window silently destroys the reuse",
            "hazard.residency_format",
        )

    if max_rel_error_ppm is not None and eps_ppm > max_rel_error_ppm:
        return PipelineRefused(
            f"composed error {eps_ppm} ppm exceeds the {max_rel_error_ppm:g} ppm budget; "
            "stacking is not a way to spend a budget one stage at a time",
            "budget",
        )

    baseline = cycles_for(source_numfmt, m, n, k, lanes=lanes)
    composed = cycles_for(target, m, n, k, resident_a, resident_b, lanes, skip_fraction)
    return PipelineResult(
        stages=tuple(stages),
        source_numfmt=source_numfmt,
        target_numfmt=target,
        baseline=baseline,
        composed=composed,
        eps_ppm=eps_ppm,
        exact=eps_ppm == 0,
        notes=tuple(notes),
    )
