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
    "RetireAnalysis",
    "Stage",
    "PipelineRefused",
    "PipelineResult",
    "row_bytes",
    "lane_groups",
    "retire_analysis",
    "steps_for",
    "beats_for",
    "model_cycles",
    "cycles_for",
    "pipeline",
]

#: Marginal cycles per operand read beat, per format, measured from the residency sweeps.
#: FP32 (669-523)/128 = 1.14 and INT8 (189-139)/32 = 1.5625 are DIRECT measurements; FP16
#: and INT4 are solved from their measured totals against the same +11 constant, so they are
#: consistent with the model rather than independently observed.
BETA: Dict[int, float] = {
    AI_FMT_FP32: 1.140625,
    vt.AI_FMT_FP16: 1.28125,
    vt.AI_FMT_BF16: 1.28125,
    AI_FMT_INT: 1.5625,
    vt.AI_FMT_FP8_E4M3: 1.5625,
    vt.AI_FMT_FP8_E5M2: 1.5625,
    AI_FMT_INT4: 2.125,
}

#: Fixed per-job cost. Falls out identically (11) for the two independently swept formats,
#: which is the reason to believe the decomposition rather than merely fit it.
MODEL_CONSTANT = 11

MEASURED = vt.MEASURED
MODELED = "modeled_from_decomposition"


def row_bytes(numfmt: int, k: int) -> int:
    """Operand row in bytes -- what a dot product actually consumes."""
    return int(math.ceil(k * vt._K_BYTES[numfmt]))


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
    return steps + BETA[numfmt] * beats + MODEL_CONSTANT


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
