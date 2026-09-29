# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
V/A-Turbo throughput-vs-quality selection, from Python, on the caller's own tensors.

Approximation is reframed here from a blocker into a *measurable trade-off* with two
independent axes, which this module never mixes:

**Throughput axis** — predicted cycles per job, from RTL simulation of
``g6lc_ai_gemm_seq``.  Every number is either MEASURED (recorded below with its shape and
harness) or ``inferred_from_k_bytes`` (derived from a format with identical operand
traffic), and the distinction is carried in every returned object.  A cycle count is a
traffic/latency proxy on a class-0 SRAM memory model: it is **not silicon, not MAC/s and
not a DRAM-controller result**.

**Quality axis** — how closely a recipe's arithmetic fits the caller's ACTUAL tensors,
obtained by emulating that arithmetic on host torch tensors and comparing against the FP32
reference.  This is a *host emulation*, and it exists to predict what the arithmetic would
cost in accuracy if a consumer existed.

.. warning::
   **The island RTL has no approximate execution consumer.**  Only the exact recipes run:
   recipe 0 (native) and recipe 16 (operand residency, and that one only in the
   verification harness — production ``g6lc_ai_island_top`` ties runtime reuse off).  Every
   approximate recipe in this module is ``hardware_execution="emulated-only"`` and produces
   plans with ``executable_on_hardware=False``.  The speedup attached to such a plan is what
   the *format's traffic* costs today, i.e. what a consumer **would** be worth — it is not
   a measurement of approximate hardware, because none exists.

Nothing is refused merely for being inexact.  The caller parameterises the trade-off
(``max_rel_error_ppm`` / ``min_sqnr_db`` / ``min_speedup``) and :func:`autotune` picks; when
nothing satisfies the constraint the result is a :class:`NoCandidate` object, never a
silent downgrade to native and never an exception.

Independence (AGENTS.md §1 KD0): this module imports nothing from the monorepo.  The
equivalent bound arithmetic lives at ``verif/tb/ai_island/policy_approx.py`` and the
geometric ladder at ``corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv``
(``va_turbo_budget_ppm``); both were read, neither is imported.  ``torch`` is an optional
import, exactly as in :mod:`ai_tensor.torch_ops`, so the cycle model, the recipe catalog and
the ladder all work with no ML stack installed.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

from .c_abi import (
    AI_FMT_BF16,
    AI_FMT_FP8_E4M3,
    AI_FMT_FP8_E5M2,
    AI_FMT_FP16,
    AI_FMT_FP32,
    AI_FMT_INT,
    AI_FMT_INT4,
    NUMFMT_NAMES,
)

try:  # torch is optional, as in ai_tensor.torch_ops; the numpy-only path must still import.
    import torch
except ImportError:  # pragma: no cover - exercised by the no-torch CI leg
    torch = None  # type: ignore[assignment]

HAVE_TORCH = torch is not None

__all__ = [
    "BASELINE_CYCLES",
    "CYCLE_PROVENANCE_NOTE",
    "HAVE_TORCH",
    "LADDER_MAX_LEVEL",
    "LADDER_MAX_PPM",
    "LADDER_MIN_PPM",
    "MEASURED_CYCLES",
    "MEASURED_RESIDENCY_CYCLES",
    "RECIPES",
    "RESIDENCIES",
    "RESIDENCY_RECIPE_ID",
    "CycleEstimate",
    "NoCandidate",
    "Plan",
    "Quality",
    "Recipe",
    "Speedup",
    "budget_ppm",
    "cycles",
    "emulate",
    "error_budget_level",
    "get_recipe",
    "pareto",
    "quality",
    "residency_speedup",
    "score_against_reference",
    "speedup",
    "autotune",
]

# --------------------------------------------------------------------------------------
# Provenance vocabulary.  Three values, because "we measured it", "we derived it from a
# format with the same operand traffic" and "we have nothing" are three different claims and
# collapsing them is how an invented number becomes a quoted number.
MEASURED = "measured"
INFERRED_FROM_K_BYTES = "inferred_from_k_bytes"
UNAVAILABLE = "unavailable"

# Hardware-execution classes.
#
# The earlier two-way split (exact / "emulated-only") was wrong about the whole
# conversion family, and wrong in the direction that understated the hardware.  The engine
# executes ALL SEVEN numeric formats natively - that is where the measured 189/109/189/189/
# 349/349/669 cycle numbers come from - and a conversion recipe's entire throughput gain is
# narrower STORAGE, i.e. fewer operand read beats.  So the approximation happens once, in
# software, on the way in, and the GEMM that follows is an ordinary native one.  Nothing new
# is needed in RTL to collect that speedup.
#
# What genuinely has no consumer is approximate ARITHMETIC: mantissa truncation, Mitchell,
# and quantising without narrowing storage.  Those also measure exactly 1.000x here, because
# they change no operand traffic - so an RTL consumer for them would add area for zero
# throughput in this datapath.  Both facts belong in the class name.
EXACT_NATIVE = "exact-native"
EXACT_RESIDENCY = "exact-residency"
#: Approximate arithmetic done by the software conversion; executed by the NATIVE datapath
#: at the narrower format.  Executable today, subject to the active profile advertising the
#: target format in its ``dtype_mask``.
NATIVE_NARROWED = "native-narrowed"
#: Needs approximate arithmetic in the datapath, which does not exist - and would buy no
#: throughput if it did, since these recipes narrow no storage.
NEEDS_RTL_CONSUMER = "needs-rtl-consumer"
#: Retained so an older pickled/serialised plan still names something real.
EMULATED_ONLY = NEEDS_RTL_CONSUMER

RESIDENCIES = ("none", "a", "b", "both")

#: Recipe 16 is what the ``residency`` argument selects; it is an ID on the arithmetic axis
#: in the RTL namespace but an orthogonal, *exact* lever here, so it is a parameter rather
#: than a member of the narrowing catalog.
RESIDENCY_RECIPE_ID = 16

#: Lane count of the configuration every measured cycle number below was taken from.
#: It is not a free parameter here: change it and the cycle table no longer describes the
#: machine that produced it. It also sets `mac_step`, and therefore the accumulation
#: window, which `ai_tensor.lossless` needs.
PE_LANES = 8

CYCLE_PROVENANCE_NOTE = (
    "RTL simulation of g6lc_ai_gemm_seq at m=n=8, k=16, PeLanes=8, NCH=1, one engine, "
    "class-0 SRAM memory model, VA_TURBO=1. Verilator cycles are a traffic/latency PROXY: "
    "not silicon, not MAC/s, and not a real DRAM controller's queueing. Evidence: "
    "remote-runs/ai-gemm-reuse-20260907T133950Z-9edd1ab08350 simulation.log; per-job cycles "
    "are the `cold_prime` field of the `REUSE ... eng=1 concurrent=0` lines (the `baseline` "
    "field there covers 2 batches), and the residency matrix is the `DUAL` lines."
)

# ---------------------------------------------------------------------------- cycle data
#: MEASURED cycles per job, keyed by ABI numfmt.  Provenance: CYCLE_PROVENANCE_NOTE.
#:
#: All seven formats were measured at this shape, taken from the `cold_prime` field of the
#: `REUSE fmt=<f> ... signed=1 enabled=1 eng=1 concurrent=0` lines — `signed=1` matters,
#: because that is the fixture that checks every C element against an independent reference,
#: so these are cycles from a run that also proved the results correct.
#:
#: INT8 (fmt=0) 189, INT4 (fmt=1) 109, FP8 E4M3 (fmt=3) 189, FP8 E5M2 (fmt=4) 189,
#: FP16 (fmt=5) 349, BF16 (fmt=6) 349, FP32 (fmt=7) 669.
MEASURED_CYCLES: Dict[int, int] = {
    AI_FMT_INT: 189,
    AI_FMT_INT4: 109,
    AI_FMT_FP8_E4M3: 189,
    AI_FMT_FP8_E5M2: 189,
    AI_FMT_FP16: 349,
    AI_FMT_BF16: 349,
    AI_FMT_FP32: 669,
}

#: MEASURED residency matrix (none / A / B / both) from the `DUAL` lines of the same run.
#: Only INT8 and FP32 were swept this way; every other format's residency is UNAVAILABLE,
#: which is reported as such rather than interpolated.
MEASURED_RESIDENCY_CYCLES: Dict[int, Dict[str, int]] = {
    AI_FMT_INT: {"none": 189, "a": 164, "b": 164, "both": 139},
    AI_FMT_FP32: {"none": 669, "a": 596, "b": 596, "both": 523},
}

#: Formats NOT measured at this shape.  Each maps to the measured format with identical
#: operand traffic (same bytes per element), which is the only defensible substitution: the
#: measured lane rule says a dot consumes `k_bytes`, so two formats with equal `k_bytes`
#: issue the same operand beats.  Anything derived through this table is flagged
#: `inferred_from_k_bytes` all the way out to the returned plan.
#:
#: Currently EMPTY, and that is a result rather than an oversight: BF16 and FP8 E5M2 were
#: first carried here as inferred, then the cited log was re-read and found to contain
#: `REUSE fmt=6 ... signed=1 ... cold_prime=349` and `REUSE fmt=4 ... signed=1 ...
#: cold_prime=189` — the harness does exercise and fully check all seven formats at this
#: shape, so both were promoted into MEASURED_CYCLES. The inference values had agreed
#: exactly with the measurements, which is reassuring about the equal-traffic rule but is
#: not a reason to keep quoting a derived number when a measured one exists.
#:
#: The mechanism stays because it is needed the moment a format is added, or the shape,
#: lane count or memory class changes and a format is not re-measured. Its behaviour is
#: still covered by a test that injects an entry, so it cannot rot while unused.
INFERRED_TRAFFIC_TWIN: Dict[int, int] = {}

#: Denominator for every reported cycle speedup: the native FP32 job with no residency.
BASELINE_CYCLES = MEASURED_CYCLES[AI_FMT_FP32]

# ------------------------------------------------------------------------------- recipes


@dataclass(frozen=True)
class Recipe:
    """One selectable point on the throughput/quality plane.

    ``id`` is the V/A-Turbo 5-bit recipe id where one applies.  The map is read from
    ``corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv`` (``va_turbo_arith``) and
    ``architecture/ai-matrix/va-turbo.md`` §8/§9; it is **not** imported (KD0).  Where the
    RTL namespace has no unambiguous slot the id is ``None`` and the ambiguity is stated in
    ``id_note`` rather than guessed.

    ``hardware_execution`` is the honest capability statement, not a preference:
    ``exact-native`` and ``exact-residency`` can run today; ``emulated-only`` means the
    arithmetic exists only in this module's host emulation.
    """

    name: str
    numfmt: int
    k_bytes_per_element: float
    exact: bool
    hardware_execution: str
    id: Optional[int] = None
    id_note: str = ""
    #: `approx_param` the RTL recipe needs, where it is caller-selected. Recipe 18 uses it as
    #: the conversion-target code (0 FP16, 1 BF16, 2 INT8, 3 FP8 E5M2) and recipe 21 as the
    #: retained mantissa bits. `None` when the recipe takes no parameter.
    approx_param: Optional[int] = None
    #: Analytic per-product bound from the RTL tables (va-turbo.md §9), in ppm. Worst case,
    #: at kappa = 1; it is NOT the measured error on the caller's tensors.
    eps_ppm: Optional[int] = None
    #: Retained explicit mantissa bits, for the truncation recipes (RTL `approx_param`).
    mantissa_bits: Optional[int] = None
    #: Symmetric quantisation levels, for the integer recipes (127 = INT8, 7 = INT4).
    quant_levels: Optional[int] = None
    #: Emulation kernel; see `_KERNELS`.
    kernel: str = "native"
    #: Residency assumed when the caller does not name one (recipe 16 only).
    default_residency: Optional[str] = None
    note: str = ""

    @property
    def storage_format(self) -> str:
        """ABI numfmt name (``fp32``/``fp16``/``bf16``/``fp8e4m3``/``int``/``int4``...)."""
        return NUMFMT_NAMES[self.numfmt]

    @property
    def approximate(self) -> bool:
        return not self.exact


# INT4 is 0.5 bytes/element and is deliberately NOT rounded up to 1: rounding it would
# overstate its operand traffic by 2x, which is the whole quantity the traffic model is
# made of.
_K_BYTES = {
    AI_FMT_FP32: 4.0,
    AI_FMT_FP16: 2.0,
    AI_FMT_BF16: 2.0,
    AI_FMT_FP8_E4M3: 1.0,
    AI_FMT_FP8_E5M2: 1.0,
    AI_FMT_INT: 1.0,
    AI_FMT_INT4: 0.5,
}

_RECIPE_LIST: Tuple[Recipe, ...] = (
    Recipe(
        name="native-fp32",
        id=0,
        numfmt=AI_FMT_FP32,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP32],
        exact=True,
        hardware_execution=EXACT_NATIVE,
        eps_ppm=0,
        kernel="native",
        note="Recipe 0, the exact native datapath. The reference both axes are measured against.",
    ),
    Recipe(
        name="resident-ab-fp32",
        id=RESIDENCY_RECIPE_ID,
        numfmt=AI_FMT_FP32,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP32],
        exact=True,
        hardware_execution=EXACT_RESIDENCY,
        eps_ppm=0,
        kernel="native",
        default_residency="both",
        note=(
            "Recipe 16: reuse resident A and B. Arithmetic is untouched, so the quality axis "
            "is identically exact; the gain is removed operand traffic. Wired to real GEMM "
            "execution in the verification harness only."
        ),
    ),
    Recipe(
        name="convert-fp16",
        id=18,
        id_note="recipe 18 with approx_param=0 (conversion target FP16); recipe 4 is the fixed-target twin",
        numfmt=AI_FMT_FP16,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP16],
        exact=False,
        hardware_execution=NATIVE_NARROWED,
        eps_ppm=977,
        kernel="storage",
        note="FP32 operands stored as FP16 (u = 2^-11).",
    ),
    Recipe(
        name="convert-bf16",
        id=18,
        id_note="recipe 18 with approx_param=1 (conversion target BF16); recipe 5 is the fixed-target twin",
        numfmt=AI_FMT_BF16,
        k_bytes_per_element=_K_BYTES[AI_FMT_BF16],
        exact=False,
        hardware_execution=NATIVE_NARROWED,
        eps_ppm=7828,
        kernel="storage",
        note="FP32 operands stored as BF16 (u = 2^-8). Same k_bytes as FP16, ~8x the bound.",
    ),
    Recipe(
        name="convert-fp8-e4m3",
        id=7,
        id_note="recipe 7 carries the E4M3 rounding epsilon (precision code 3 -> 128,907 ppm)",
        numfmt=AI_FMT_FP8_E4M3,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP8_E4M3],
        exact=False,
        hardware_execution=NATIVE_NARROWED,
        eps_ppm=128907,
        kernel="storage_scaled",
        note="FP32 operands stored as FP8 E4M3 with a per-tensor scale (u = 2^-4).",
    ),
    Recipe(
        name="convert-fp8-e5m2",
        id=18,
        approx_param=3,
        id_note=(
            "Recipe 18 with conversion code 3. This was reported as UNCERTAIN / None: no id "
            "carried the E5M2 epsilon at all - recipes 4/5/7 pin FP16/BF16/E4M3 and 18's "
            "caller-selected map covered only FP16/BF16/INT8, so `round_eps_ppm(2)` = 265,625 "
            "ppm existed with nothing able to reach it, and code 3 returned INT8 as a target "
            "while va_turbo_arith gave the same code VA_ARITH_NONE. The RTL now assigns code "
            "3 to E5M2 and requires scale metadata for both FP8 targets."
        ),
        numfmt=AI_FMT_FP8_E5M2,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP8_E5M2],
        exact=False,
        hardware_execution=NATIVE_NARROWED,
        eps_ppm=265625,
        kernel="storage_scaled",
        note="FP32 operands stored as FP8 E5M2 with a per-tensor scale (u = 2^-3).",
    ),
    Recipe(
        name="convert-int8",
        id=20,
        id_note="recipe 20 = INT8 quantisation that narrows storage; 19 is the same quantisation without narrowing",
        numfmt=AI_FMT_INT,
        k_bytes_per_element=_K_BYTES[AI_FMT_INT],
        exact=False,
        hardware_execution=NATIVE_NARROWED,
        eps_ppm=7892,
        quant_levels=127,
        kernel="quant",
        note="Symmetric per-tensor INT8, 127 levels. FULL-scale bound kind: a small element may be perturbed 100%.",
    ),
    Recipe(
        name="quantise-int8-in-place",
        id=19,
        numfmt=AI_FMT_FP32,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP32],
        exact=False,
        hardware_execution=EMULATED_ONLY,
        eps_ppm=7892,
        quant_levels=127,
        kernel="quant",
        note=(
            "Recipe 19 quantises without narrowing storage: it pays INT8's error and keeps "
            "FP32's operand traffic. Kept in the catalog precisely because the trade-off is "
            "negative — it makes the two axes visibly independent."
        ),
    ),
    Recipe(
        name="convert-int4",
        id=29,
        id_note="recipe 29 is the only FULL/quant_levels=7 slot that narrows storage in va_turbo_arith",
        numfmt=AI_FMT_INT4,
        k_bytes_per_element=_K_BYTES[AI_FMT_INT4],
        exact=False,
        hardware_execution=NATIVE_NARROWED,
        eps_ppm=147961,
        quant_levels=7,
        kernel="quant",
        note="Symmetric per-tensor INT4, 7 levels.",
    ),
    Recipe(
        name="truncate-mantissa-10",
        id=21,
        numfmt=AI_FMT_FP32,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP32],
        exact=False,
        hardware_execution=EMULATED_ONLY,
        eps_ppm=1953,
        mantissa_bits=10,
        kernel="truncate",
        note=(
            "Recipe 21 keeps 10 explicit mantissa bits of each FP32 operand. A cheaper "
            "multiplier at the SAME element width, so it buys multiplier area/depth and "
            "exactly zero operand traffic."
        ),
    ),
    Recipe(
        name="truncate-mantissa-4",
        id=21,
        numfmt=AI_FMT_FP32,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP32],
        exact=False,
        hardware_execution=EMULATED_ONLY,
        eps_ppm=121094,
        mantissa_bits=4,
        kernel="truncate",
        note="Recipe 21 with approx_param=4.",
    ),
    Recipe(
        name="mitchell",
        id=27,
        id_note=(
            "recipes 27 and 28 carry IDENTICAL arithmetic metadata (REL, 250,000 ppm) and the "
            "RTL does not specify how 28's correction differs, so only 27 is emulated; "
            "emulating 28 would mean inventing its correction term."
        ),
        numfmt=AI_FMT_FP32,
        k_bytes_per_element=_K_BYTES[AI_FMT_FP32],
        exact=False,
        hardware_execution=EMULATED_ONLY,
        eps_ppm=250000,
        kernel="mitchell",
        note=(
            "Mitchell logarithmic multiply, (1+ma)(1+mb) ~= 1+ma+mb: an adder replaces the "
            "multiplier array. Buys no operand traffic. The 250,000 ppm figure is the "
            "supremum of THIS formulation; the textbook 11.1% belongs to the log-domain "
            "formulation and is not interchangeable with it."
        ),
    ),
)

RECIPES: Dict[str, Recipe] = {r.name: r for r in _RECIPE_LIST}


def get_recipe(recipe: "Recipe | str") -> Recipe:
    """Accept a :class:`Recipe` or its name; refuse anything else by name."""
    if isinstance(recipe, Recipe):
        return recipe
    try:
        return RECIPES[recipe]
    except KeyError:
        raise ValueError(
            f"unknown recipe {recipe!r}; known: {sorted(RECIPES)}"
        ) from None


# ------------------------------------------------------------------- the geometric ladder
LADDER_MAX_LEVEL = 15
LADDER_MIN_PPM = 100
LADDER_MAX_PPM = 1_000_000


def budget_ppm(level: int) -> int:
    """Error budget of a V/A-Turbo runtime level, in ppm.

    Mirrors ``g6lc_ai_policy_pkg::va_turbo_budget_ppm`` exactly: level 0 is off (budget 0),
    level 1 is 100 ppm, every step doubles, and the ladder saturates at 1,000,000 ppm
    (100%).  A level outside 0..15 does not exist in the 4-bit field and raises rather than
    being clamped into range — clamping is how an out-of-budget candidate becomes admissible.
    """
    if isinstance(level, bool) or not isinstance(level, int):
        raise ValueError(f"level must be an int in 0..{LADDER_MAX_LEVEL}, got {level!r}")
    if not 0 <= level <= LADDER_MAX_LEVEL:
        raise ValueError(f"level {level} is outside the 4-bit ladder 0..{LADDER_MAX_LEVEL}")
    if level == 0:
        return 0
    return min(LADDER_MIN_PPM << (level - 1), LADDER_MAX_PPM)


def error_budget_level(ppm: float) -> int:
    """Smallest ladder level whose budget covers ``ppm`` — the inverse of :func:`budget_ppm`.

    This is the RTL's ``error_bound_q4`` convention: a caller's own bound expressed as an
    index on the same ladder, **rounded up**, so it compares directly against the authorised
    level.  ``ppm == 0`` maps to level 0 (off / exact).

    Fails closed: a negative, nonfinite or above-100% budget raises.  Saturating such a value
    into level 15 would silently turn "I cannot express this bound" into "admitted".
    """
    if isinstance(ppm, bool) or not isinstance(ppm, (int, float)):
        raise ValueError(f"ppm must be a real number, got {ppm!r}")
    value = float(ppm)
    if not math.isfinite(value):
        raise ValueError("ppm must be finite; a nonfinite error has no ladder level")
    if value < 0:
        raise ValueError("ppm must be non-negative")
    if value > LADDER_MAX_PPM:
        raise ValueError(
            f"ppm {value} exceeds the ladder maximum {LADDER_MAX_PPM} (100%); "
            "the ladder cannot express it and will not saturate it into range"
        )
    if value == 0:
        return 0
    for level in range(1, LADDER_MAX_LEVEL + 1):
        if budget_ppm(level) >= value:
            return level
    raise AssertionError("unreachable: level 15 saturates at 100%")  # pragma: no cover


def compose_ppm(eps_ppm: int, kappa_q8: int):
    """``(eps_ppm * kappa_q8 + 255) >> 8``.

    ``kappa_q8`` is kappa times 256. A value below 256 is kappa below 1 and
    fails closed. A composed bound above 100% fails closed. This does not
    change a product.
    """
    if isinstance(eps_ppm, bool) or isinstance(kappa_q8, bool):
        return None
    if not isinstance(eps_ppm, int) or not isinstance(kappa_q8, int):
        return None
    if eps_ppm < 0 or kappa_q8 < 256:
        return None
    composed = (eps_ppm * kappa_q8 + 255) >> 8
    if composed > LADDER_MAX_PPM:
        return None
    return composed


# Documented INT8 tile error in va-turbo.md. Not re-measured here.
DOC_INT8_PPM = 18_527


def measurement_fits(level: int, measured_ppm: Optional[int]) -> bool:
    """Level 0 needs no measurement. A higher level with none fails closed."""
    if level == 0:
        return measured_ppm is None or measured_ppm == 0
    try:
        budget = budget_ppm(level)
    except ValueError:
        return False
    if measured_ppm is None:
        return False
    return measured_ppm <= budget


def recipe_admitted(level: int, eps_ppm: int, kappa_q8: int, caller_ppm: int) -> bool:
    """Analytic bound and caller bound both fit ``level``. The MAC path still applies 0."""
    try:
        budget = budget_ppm(level)
        bound = error_budget_level(caller_ppm)
    except ValueError:
        return False
    composed = compose_ppm(eps_ppm, kappa_q8)
    if composed is None:
        return False
    return composed <= budget and level <= bound


# Untightened quantisation flatness, fa + fb = 2 in Q8.
FLAT_WORST_Q8 = 512

_ROUND_EPS = (
    None, 562_500, 265_625, 128_907, 63_477, 31_495, 15_687, 7_828, 3_911, 1_955,
    977, 489, 245, 123, 62, 31, 16, 8, 4, 2, 1, 1, 1, 1,
)
_TRUNC_EPS = (
    1_000_000, 750_000, 437_500, 234_375, 121_094, 61_524, 31_006, 15_564, 7_798,
    3_903, 1_953, 977, 489, 245, 123, 62, 31, 16, 8, 4, 2, 1, 1, 1,
)
_EXACT_RECIPE_IDS = frozenset(
    (0, 1, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 22, 23, 24)
)


def _table_ppm(table: tuple, bits: object):
    if isinstance(bits, bool) or not isinstance(bits, int) or bits < 0 or bits >= len(table):
        return None
    return table[bits]


def quant_eps_ppm(levels: int, flat_q8: int):
    """Full-scale quantisation ppm. A flatness above 512 fails closed."""
    if isinstance(levels, bool) or isinstance(flat_q8, bool):
        return None
    if not isinstance(levels, int) or not isinstance(flat_q8, int):
        return None
    flat = FLAT_WORST_Q8 if flat_q8 == 0 else flat_q8
    if flat < 0 or flat > FLAT_WORST_Q8:
        return None
    if levels == 127:
        per_unit, constant_term = 3_938, 16
    elif levels == 7:
        per_unit, constant_term = 71_429, 5_103
    else:
        return None
    total = (((per_unit * flat) + 255) >> 8) + constant_term
    if total > LADDER_MAX_PPM:
        return None
    return total


def recipe_eps_ppm(recipe: int, approx_param: Optional[int] = None, flat_q8: Optional[int] = None):
    """Per-recipe analytic epsilon. Exact ids are 0. Recipe 26 is refused.

    A recipe that needs ``approx_param`` returns ``None`` without one.
    Absent flatness uses :data:`FLAT_WORST_Q8`.
    """
    if isinstance(recipe, bool) or not isinstance(recipe, int) or recipe < 0 or recipe > 31:
        return None
    flat = FLAT_WORST_Q8 if flat_q8 in (None, 0) else flat_q8
    if recipe in _EXACT_RECIPE_IDS:
        return 0
    if recipe == 4:
        return _table_ppm(_ROUND_EPS, 10)
    if recipe == 5:
        return _table_ppm(_ROUND_EPS, 7)
    if recipe == 6:
        return quant_eps_ppm(127, flat)
    if recipe == 7:
        return _table_ppm(_ROUND_EPS, 3)
    if recipe == 18:
        if isinstance(approx_param, bool) or not isinstance(approx_param, int):
            return None
        arm = approx_param & 3
        if arm == 0:
            return _table_ppm(_ROUND_EPS, 10)
        if arm == 1:
            return _table_ppm(_ROUND_EPS, 7)
        if arm == 2:
            return quant_eps_ppm(127, flat)
        return _table_ppm(_ROUND_EPS, 2)
    if recipe in (19, 20):
        return quant_eps_ppm(127, flat)
    if recipe in (21, 25, 30, 31):
        if isinstance(approx_param, bool) or not isinstance(approx_param, int):
            return None
        return _table_ppm(_TRUNC_EPS, approx_param)
    if recipe == 26:
        return None
    if recipe in (27, 28):
        return 250_000
    if recipe == 29:
        return quant_eps_ppm(7, flat)
    return None


@dataclass(frozen=True)
class Decode:
    """One bank entry. The action fields stay clear.

    ``supported`` means the id has an arithmetic class. ``apply``, reuse,
    convert, and the other action fields are false for every id.
    """

    kind: str
    eps_ppm: Optional[int]
    needs_param: bool
    narrows_storage: bool
    quant_levels: Optional[int]
    supported: bool
    apply: bool = False
    reuse_a: bool = False
    reuse_b: bool = False
    convert: bool = False
    approx_products: bool = False
    skip_products: bool = False
    split_rows: bool = False
    groups_log2: int = 0
    rewrites_format: bool = False

    def actions_clear(self) -> bool:
        return not (
            self.apply
            or self.reuse_a
            or self.reuse_b
            or self.convert
            or self.approx_products
            or self.skip_products
            or self.split_rows
            or self.groups_log2
            or self.rewrites_format
        )


def decode(recipe: int, approx_param: Optional[int] = None, flat_q8: Optional[int] = None) -> Decode:
    """Decode one recipe id. An id above 31 is unsupported and still has no actions."""
    idle = Decode("none", None, False, False, None, False)
    if isinstance(recipe, bool) or not isinstance(recipe, int) or recipe < 0 or recipe > 31:
        return idle
    if recipe in _EXACT_RECIPE_IDS:
        kind, needs_param, narrows, quant = "exact", False, False, None
    elif recipe in (4, 5, 7):
        kind, needs_param, narrows, quant = "rel", False, True, None
    elif recipe == 6:
        kind, needs_param, narrows, quant = "full", False, True, 127
    elif recipe == 18:
        quant = 127 if isinstance(approx_param, int) and not isinstance(approx_param, bool) and (approx_param & 3) == 2 else None
        kind, needs_param, narrows = "rel", True, True
    elif recipe == 19:
        kind, needs_param, narrows, quant = "full", False, False, 127
    elif recipe == 20:
        kind, needs_param, narrows, quant = "full", False, True, 127
    elif recipe in (21, 25, 30, 31, 26):
        kind, needs_param, narrows, quant = "rel", True, False, None
    elif recipe in (27, 28):
        kind, needs_param, narrows, quant = "rel", False, False, None
    elif recipe == 29:
        kind, needs_param, narrows, quant = "full", False, True, 7
    else:
        return idle
    return Decode(
        kind,
        recipe_eps_ppm(recipe, approx_param, flat_q8),
        needs_param,
        narrows,
        quant,
        True,
    )


@dataclass(frozen=True)
class PromotionGates:
    """All four have to be present, or promotion stays off.

    The documented 18,527 ppm tile figure is not one of these gates.
    """

    concurrency_measured: bool = False
    held_out_pair: bool = False
    gain_threshold_recorded: bool = False
    beyond_tile_proxy: bool = False

    def ready(self) -> bool:
        return (
            self.concurrency_measured
            and self.held_out_pair
            and self.gain_threshold_recorded
            and self.beyond_tile_proxy
        )


LIVE_VA_TURBO_EN = False


def va_turbo_en_allowed(exact_reuse_ok: bool, gates: PromotionGates) -> bool:
    """Bare gate flags are claims, not measurements. They never allow.

    Use :func:`va_turbo_from_witnesses`. This does not write the live bit.
    """
    _ = (exact_reuse_ok, gates)
    return False


PROMOTION_GATES = (
    "concurrency_measured",
    "held_out_pair",
    "gain_threshold_recorded",
    "beyond_tile_proxy",
)


@dataclass(frozen=True)
class VaTurboDecision:
    """What still blocks the live bit. ``allowed`` does not write it."""

    exact_reuse_ok: bool
    allowed: bool
    missing: tuple


def va_turbo_decision(exact_reuse_ok: bool, gates: PromotionGates) -> VaTurboDecision:
    """Name every unchecked gate. Bare flags do not allow the live bit."""
    missing = []
    if exact_reuse_ok is not True:
        missing.append("exact_reuse")
    for name in PROMOTION_GATES:
        if not getattr(gates, name):
            missing.append(name)
    return VaTurboDecision(exact_reuse_ok is True, False, tuple(missing))


@dataclass(frozen=True)
class GateWitness:
    """One measured requirement. ``status`` is passed, failed, or absent.

    A passed witness needs a ``source``. ``lane-groups`` cannot pass
    concurrency. ``huggingface-bert-random`` cannot pass beyond-tile
    accuracy.
    """

    name: str
    status: str
    source: str = ""


def known_promotion_witnesses() -> tuple:
    """Witnesses the tree actually has.

    Lane groups were measured and do not add MAC/s, so concurrency failed.
    The other three gates have no measurement.
    """
    return (
        GateWitness("concurrency_measured", "failed", "lane-groups"),
        GateWitness("held_out_pair", "absent", ""),
        GateWitness("gain_threshold_recorded", "absent", ""),
        GateWitness("beyond_tile_proxy", "absent", ""),
    )


def accept_witness(proposed: GateWitness) -> GateWitness:
    """Drop a passed witness that has no source, or that reuses a refuted run."""
    status = proposed.status
    if status not in ("passed", "failed", "absent"):
        status = "absent"
    elif status == "passed" and not proposed.source:
        status = "absent"
    elif (
        proposed.name == "concurrency_measured"
        and status == "passed"
        and proposed.source == "lane-groups"
    ):
        status = "failed"
    elif (
        proposed.name == "beyond_tile_proxy"
        and status == "passed"
        and proposed.source == "huggingface-bert-random"
    ):
        status = "absent"
    return GateWitness(proposed.name, status, proposed.source)


def refuse_unapplied_recipe(recipe: Optional[str]) -> None:
    """The high-level GEMM applies no explicit recipe until witnesses allow it.

    The default call passes ``None`` and stays the exact integer or native
    product. A named recipe, including a narrowed or approximate one, is
    refused while the known witnesses are not all passed.
    """
    if recipe is None:
        return
    decision = va_turbo_from_witnesses(
        GateWitness("exact_reuse", "passed", "high-level-call"),
        known_promotion_witnesses(),
    )
    if not decision.allowed:
        raise NotImplementedError(
            f"{recipe} is not applied on the high-level GEMM. missing={list(decision.missing)}"
        )


def va_turbo_from_witnesses(exact: GateWitness, gates: tuple) -> VaTurboDecision:
    """Allow only when exact reuse and every gate witness passed.

    This does not write the live bit.
    """
    exact = accept_witness(exact)
    exact_ok = exact.name == "exact_reuse" and exact.status == "passed"
    by_name = {item.name: item.status for item in (accept_witness(item) for item in gates)}
    missing = []
    if not exact_ok:
        missing.append("exact_reuse")
    for name in PROMOTION_GATES:
        status = by_name.get(name, "absent")
        if status != "passed":
            missing.append(f"{name}:{status}")
    return VaTurboDecision(exact_ok, not missing, tuple(missing))


SECTION11_OPEN = (
    "lane_groups",
    "float_reductions",
    "converters",
    "proof_producers",
    "approximate_consumers",
    "multi_cluster",
)


def ppm_satisfies_promotion(_ppm: int) -> bool:
    """A ppm figure does not satisfy a promotion gate."""
    return False


def section11_selected() -> bool:
    return False


def _width_ok(bits: int) -> bool:
    return (
        isinstance(bits, int)
        and not isinstance(bits, bool)
        and 64 <= bits <= 4096
        and bits & (bits - 1) == 0
    )


@dataclass(frozen=True)
class PortSetting:
    """Configurable fabric. The live setting is not promoted.

    Legal widths are powers of two from 64 through 4096.
    """

    island_bits: int = 512
    fabric_bits: int = 64

    @staticmethod
    def live() -> "PortSetting":
        return PortSetting()

    def carried_bytes(self) -> int:
        if not _width_ok(self.island_bits) or not _width_ok(self.fabric_bits):
            return 0
        return min(self.island_bits, self.fabric_bits) // 8

    def promoted(self) -> bool:
        return self.carried_bytes() > 8


@dataclass(frozen=True)
class TrackFeatures:
    """Section 11 settings. Defaults match the live package.

    Lane groups do not add MAC/s. Approximate consumers apply only when
    every promotion gate is present, and that still does not write the
    live bit.
    """

    lane_groups: bool = False
    float_reductions: bool = False
    converters: bool = False
    proof_producers: bool = False
    approximate_consumers: bool = False
    clusters: int = 1
    macs: int = 512

    @staticmethod
    def live() -> "TrackFeatures":
        return TrackFeatures()

    def effective_macs(self, port: PortSetting) -> int:
        if port.promoted() and isinstance(self.macs, int) and not isinstance(self.macs, bool) and self.macs > 0:
            return self.macs
        return 512

    def effective_clusters(self, port: PortSetting) -> int:
        if port.promoted() and isinstance(self.clusters, int) and not isinstance(self.clusters, bool) and self.clusters > 0:
            return self.clusters
        return 1

    def approximate_apply(self, gates: PromotionGates) -> bool:
        return bool(self.approximate_consumers) and gates.ready()


LIVE_CLUSTERS = 1
LIVE_MACS = 512
LIVE_CLOCK_KHZ = 2_000_000
SKU_CLUSTERS = 8
SKU_MACS = 4096
SKU_CLOCK_KHZ = 1_500_000


def sketch_milli_tops(clusters: int, macs: int, clock_khz: int, fmt: int) -> int:
    """Parameter sketch in milli-ops. Not a measurement.

    INT8 is ``2 × clusters × macs × (clock_khz/1000) / 1000``, which is two
    operations per MAC. INT4 is twice that, FP8 matches INT8, FP16 and BF16
    are half, and FP32 is a quarter. Structured 2:4 and an unknown code are 0.
    A VA level is not an argument.
    """
    if any(isinstance(v, bool) or not isinstance(v, int) for v in (clusters, macs, clock_khz, fmt)):
        return 0
    if clusters < 0 or macs < 0 or clock_khz < 0 or fmt < 0:
        return 0
    base = (2 * clusters * macs * (clock_khz // 1000)) // 1000
    if fmt in (0, 3, 4):
        return base
    if fmt == 1:
        return base * 2
    if fmt in (5, 6):
        return base // 2
    if fmt == 7:
        return base // 4
    return 0


def format_sketch(clusters: int, macs: int, clock_khz: int, fmt: int) -> tuple:
    """``(macs_per_s, milli_ops)``. The MAC rate does not depend on format."""
    if any(isinstance(v, bool) or not isinstance(v, int) for v in (clusters, macs, clock_khz)):
        return (0, 0)
    if clusters < 0 or macs < 0 or clock_khz < 0:
        return (0, 0)
    macs_per_s = clusters * macs * clock_khz * 1000
    return (macs_per_s, sketch_milli_tops(clusters, macs, clock_khz, fmt))


NARROW_BEAT_BYTES = 8


@dataclass(frozen=True)
class ControlSetting:
    """Descriptor, C, and completion width. The live setting is 8 bytes.

    A legal width is a power of two from 8 through 512.
    """

    beat_bytes: int = 8

    @staticmethod
    def live() -> "ControlSetting":
        return ControlSetting()

    def bytes(self) -> int:
        width = self.beat_bytes
        if isinstance(width, bool) or not isinstance(width, int):
            return 0
        if 8 <= width <= 512 and width & (width - 1) == 0:
            return width
        return 0


def carried_bytes_per_cycle(island_bits: int, fabric_bits: int) -> int:
    """Bytes that move. The join carries the narrower of the two widths."""
    if any(isinstance(v, bool) or not isinstance(v, int) for v in (island_bits, fabric_bits)):
        return 0
    if island_bits < 0 or fabric_bits < 0:
        return 0
    return min(island_bits, fabric_bits) // 8


def macs_may_rise(bytes_per_cycle: int) -> bool:
    """True only after the carried port is wider than 8 bytes/cycle."""
    return isinstance(bytes_per_cycle, int) and not isinstance(bytes_per_cycle, bool) and bytes_per_cycle > NARROW_BEAT_BYTES


def carried_nameplate_gbps(island_bits: int, fabric_bits: int, clock_khz: int) -> int:
    """Class-0 nameplate of the carried width. Round only the final GB/s result."""
    return _bytes_nameplate_gbps(carried_bytes_per_cycle(island_bits, fabric_bits), clock_khz)


def _bytes_nameplate_gbps(width: int, clock_khz: int) -> int:
    if isinstance(clock_khz, bool) or not isinstance(clock_khz, int) or clock_khz < 0:
        return 0
    return min(0xFFFFFFFF, width * clock_khz // 1_000_000)


def configured_rate(port: PortSetting, features: TrackFeatures, clock_khz: int, fmt: int) -> dict:
    """Sketch for one port setting. Not a measurement.

    The live setting stays 1×512. A promoted fabric may use the configured
    cluster and MAC counts. Control beats stay 8 bytes. Lane groups,
    reductions, converters, and proof producers do not change the rate.
    """
    clusters = features.effective_clusters(port)
    macs = features.effective_macs(port)
    macs_per_s, milli_ops = format_sketch(clusters, macs, clock_khz, fmt)
    return {
        "clusters": clusters,
        "macs": macs,
        "macs_per_s": macs_per_s,
        "milli_ops": milli_ops,
        "carried_bytes": port.carried_bytes(),
        "control_beat_bytes": NARROW_BEAT_BYTES,
        "clock_khz": clock_khz,
        "promoted": port.promoted(),
    }


def with_control(rate: dict, control: ControlSetting) -> dict:
    """Replace the control-beat width. The live rate uses 8."""
    opened = dict(rate)
    opened["control_beat_bytes"] = control.bytes()
    return opened


LIVE_MACS_PER_BYTE = 64


def port_balance(rate: dict) -> dict:
    """Whether the data port and the control beats feed the array.

    ``keeps_pace`` is the carried data width. ``control_keeps_pace`` is
    the descriptor, C, and completion path. ``fed`` is both. A wide data
    fabric does not widen those beats.
    """
    total = rate["clusters"] * rate["macs"]
    carried = rate["carried_bytes"]
    control = rate["control_beat_bytes"]
    keeps = carried > 0 and total <= carried * LIVE_MACS_PER_BYTE
    control_keeps = control > 0 and total <= control * LIVE_MACS_PER_BYTE
    return {
        "macs_per_cycle": total,
        "macs_per_byte": 0 if carried == 0 else total // carried,
        "bytes_to_keep_pace": (total + LIVE_MACS_PER_BYTE - 1) // LIVE_MACS_PER_BYTE,
        "keeps_pace": keeps,
        "control_macs_per_byte": 0 if control == 0 else total // control,
        "control_keeps_pace": control_keeps,
        "fed": keeps and control_keeps,
        "data_nameplate_gbps": _bytes_nameplate_gbps(carried, rate["clock_khz"]),
        "control_nameplate_gbps": _bytes_nameplate_gbps(control, rate["clock_khz"]),
        "demand_gbps": _bytes_nameplate_gbps(
            (total + LIVE_MACS_PER_BYTE - 1) // LIVE_MACS_PER_BYTE, rate["clock_khz"]),
    }


def dram_cap_gbps(dram_class: int, channels: int, data_nameplate_gbps: int) -> int:
    """Class 0 is the data nameplate. Class 1 is ``channels × 19``. Class 2 is 400."""
    if isinstance(dram_class, bool) or not isinstance(dram_class, int):
        return 0
    if dram_class == 0:
        return data_nameplate_gbps
    if dram_class == 1:
        if isinstance(channels, bool) or not isinstance(channels, int) or channels < 0:
            return 0
        return channels * 19
    if dram_class == 2:
        return 400
    return 0


def dram_covers(balance: dict, dram_class: int, channels: int) -> bool:
    """True when the setting is fed and the DRAM cap meets ``demand_gbps``."""
    cap = dram_cap_gbps(dram_class, channels, balance["data_nameplate_gbps"])
    return balance["fed"] and balance["demand_gbps"] > 0 and cap >= balance["demand_gbps"]


def dram_claim_matches(dram_class: int, channels: int, data_nameplate_gbps: int, claimed_gbps: int) -> bool:
    """The claimed GB/s equals the class formula.

    Class 2 is 400, and that claim is rejected when it is also the class-0
    nameplate. A match does not change the live DRAM class.
    """
    if isinstance(dram_class, bool) or not isinstance(dram_class, int) or dram_class > 2:
        return False
    cap = dram_cap_gbps(dram_class, channels, data_nameplate_gbps)
    if claimed_gbps != cap:
        return False
    return not (dram_class == 2 and claimed_gbps == data_nameplate_gbps)


def ddr4_channels_to_cover(demand_gbps: int) -> int:
    """DDR4-2400×64 channels needed. Each channel is 19 GB/s."""
    if isinstance(demand_gbps, bool) or not isinstance(demand_gbps, int) or demand_gbps <= 0:
        return 0
    return (demand_gbps + 18) // 19


def tops_gap(fmt: int) -> tuple:
    """``(live_milli, sku_milli, ratio)``. The ratio is 48 where the sketch is nonzero."""
    live = sketch_milli_tops(LIVE_CLUSTERS, LIVE_MACS, LIVE_CLOCK_KHZ, fmt)
    sku = sketch_milli_tops(SKU_CLUSTERS, SKU_MACS, SKU_CLOCK_KHZ, fmt)
    return (live, sku, 0 if live == 0 else sku // live)


POLICY_BULK = 0
POLICY_WIDE = 1
POLICY_TALL = 2
POLICY_DECODE = 3
POLICY_MOVEMENT = 7


@dataclass(frozen=True)
class WorkloadChoice:
    """Automatic exact choice for one shape. Approximate ids stay withheld.

    A decode shape selects resident B, recipe 16. The transposed shape
    selects resident A, the same recipe. The two are never both set.
    ``large_decode`` is B's share of reads at least 99%. ``large_resident``
    is the selected operand's share at that same line. ``apply`` stays
    false, and this record does not enable reuse on a device.
    """

    code: int
    exact_recipe: Optional[int]
    reuse_b: bool
    reuse_a: bool
    apply: bool
    large_decode: bool
    large_resident: bool
    b_share_millis: int
    a_share_millis: int
    withheld: int


def select_workload(m: int, n: int, k: int) -> WorkloadChoice:
    """Choose the exact optimization for a shape. ``apply`` stays false."""
    if isinstance(m, bool) or isinstance(n, bool) or isinstance(k, bool):
        code = POLICY_MOVEMENT
        m = n = k = 0
    elif not all(isinstance(v, int) and v >= 0 for v in (m, n, k)):
        code = POLICY_MOVEMENT
        m = n = k = 0
    elif m == 0 or n == 0 or k == 0:
        code = POLICY_MOVEMENT
    elif m <= 1 and n >= 2 and k >= 2:
        code = POLICY_DECODE
    elif n > m:
        code = POLICY_WIDE
    elif m > n:
        code = POLICY_TALL
    else:
        code = POLICY_BULK
    denom = m + n
    b_share = 0 if denom == 0 else (n * 1000) // denom
    a_share = 0 if denom == 0 else (m * 1000) // denom
    reuse_b = code == POLICY_DECODE
    reuse_a = code == POLICY_TALL and n <= 1 and m >= 2 and k >= 2
    withheld = sum(1 for recipe in range(32) if decode(recipe).kind != "exact")
    return WorkloadChoice(
        code,
        16 if reuse_a or reuse_b else None,
        reuse_b,
        reuse_a,
        False,
        reuse_b and b_share >= 990,
        (reuse_b and b_share >= 990) or (reuse_a and a_share >= 990),
        b_share,
        a_share,
        withheld,
    )


@dataclass(frozen=True)
class WithheldAdmission:
    """Withheld ids that pass permission and the analytic bound.

    ``apply`` stays false. Listing an id does not arm an evidence window
    and does not change a product.
    """

    ids: tuple
    apply: bool


def admit_withheld(
    gates: Gates,
    *,
    level: int,
    measured_ppm: Optional[int],
    kappa_q8: Optional[int],
    consumer_mask: int,
    profile_mask: int,
    window_valid: bool,
    approx_param: Optional[int] = None,
) -> WithheldAdmission:
    """Consider withheld recipes. Exact ids are not in this set."""
    found = []
    for recipe in range(32):
        if decode(recipe, approx_param).kind == "exact":
            continue
        allowed = permission(
            gates,
            level=level,
            recipe=recipe,
            consumer_mask=consumer_mask,
            profile_mask=profile_mask,
            window_valid=window_valid,
        )
        if not allowed.permitted:
            continue
        if recipe_claim_fits(level, recipe, measured_ppm, kappa_q8, approx_param):
            found.append(recipe)
    return WithheldAdmission(tuple(found), False)


def recipe_claim_fits(
    level: int,
    recipe: int,
    measured_ppm: Optional[int],
    kappa_q8: Optional[int] = None,
    approx_param: Optional[int] = None,
) -> bool:
    """Analytic bound and measured ppm both fit ``level``. Exact ids need no kappa."""
    if not measurement_fits(level, measured_ppm):
        return False
    eps = recipe_eps_ppm(recipe, approx_param, None)
    if eps is None:
        return False
    if eps == 0:
        return recipe_admitted(level, 0, 256, 0 if measured_ppm is None else measured_ppm)
    if kappa_q8 is None or measured_ppm is None:
        return False
    return recipe_admitted(level, eps, kappa_q8, measured_ppm)


# --------------------------------------------------------------------------- cycle model


@dataclass(frozen=True)
class CycleEstimate:
    """Predicted cycles per job, with the provenance of the prediction attached."""

    cycles: Optional[int]
    provenance: str
    numfmt: int
    residency: str
    #: The measured format the number was inferred from, when `provenance` is inferred.
    inferred_from: Optional[str] = None
    note: str = ""

    @property
    def inferred(self) -> bool:
        return self.provenance == INFERRED_FROM_K_BYTES

    @property
    def available(self) -> bool:
        return self.cycles is not None


def _check_residency(residency: str) -> str:
    if residency not in RESIDENCIES:
        raise ValueError(f"residency must be one of {RESIDENCIES}, got {residency!r}")
    return residency


def cycles(recipe: "Recipe | str", residency: Optional[str] = None) -> CycleEstimate:
    """Predicted cycles per job for ``recipe`` at ``residency``.

    ``residency`` selects the recipe-16 operand-residency variant (``none``/``a``/``b``/
    ``both``); ``None`` uses the recipe's own default.  A combination with no measurement and
    no equal-traffic twin returns ``cycles=None`` and ``provenance="unavailable"`` — the one
    thing it never does is interpolate.
    """
    rec = get_recipe(recipe)
    res = _check_residency(residency if residency is not None else (rec.default_residency or "none"))
    fmt = rec.numfmt
    twin = INFERRED_TRAFFIC_TWIN.get(fmt)
    source = twin if twin is not None else fmt
    provenance = INFERRED_FROM_K_BYTES if twin is not None else MEASURED
    inferred_from = NUMFMT_NAMES[twin] if twin is not None else None

    if res == "none":
        value = MEASURED_CYCLES.get(source)
        if value is None:
            return CycleEstimate(None, UNAVAILABLE, fmt, res, inferred_from,
                                 f"no measured per-job cycles for {NUMFMT_NAMES[source]}")
        return CycleEstimate(value, provenance, fmt, res, inferred_from, CYCLE_PROVENANCE_NOTE)

    table = MEASURED_RESIDENCY_CYCLES.get(source)
    if table is None:
        return CycleEstimate(
            None, UNAVAILABLE, fmt, res, inferred_from,
            f"residency was swept only for {', '.join(NUMFMT_NAMES[f] for f in sorted(MEASURED_RESIDENCY_CYCLES))}; "
            f"{NUMFMT_NAMES[fmt]} at residency={res} would have to be interpolated, and is not",
        )
    return CycleEstimate(table[res], provenance, fmt, res, inferred_from, CYCLE_PROVENANCE_NOTE)


@dataclass(frozen=True)
class Speedup:
    """Two throughput estimates for one recipe, reported side by side and never merged.

    ``cycle_speedup`` is ``FP32-native cycles / recipe cycles`` from the measured (or
    equal-traffic-inferred) RTL data.  ``traffic_speedup`` is a *model*: FP32's bytes per
    element over this recipe's, i.e. what the operand traffic alone would predict.  They
    disagree on purpose — the measured INT8 job is 3.54x, the traffic model says 4x — because
    fixed per-job cost and the one-element-per-cycle retire bound are real and the model
    cannot see them.  Presenting either as the other would be a fabricated measurement.
    """

    recipe: str
    residency: str
    cycle_speedup: Optional[float]
    cycle_provenance: str
    cycles: Optional[int]
    baseline_cycles: int
    traffic_speedup: float
    traffic_provenance: str = "model_from_k_bytes"
    inferred_from_k_bytes: bool = False
    note: str = ""

    @property
    def available(self) -> bool:
        return self.cycle_speedup is not None


def speedup(recipe: "Recipe | str", residency: Optional[str] = None) -> Speedup:
    """Throughput estimate for ``recipe``: measured-cycle ratio *and* traffic model.

    The denominator of ``cycle_speedup`` is always the native FP32 job with no residency
    (669 cycles), so numbers from different recipes are comparable.  For the same-format
    "what did residency buy" ratio the doc quotes (1.359x INT8, 1.279x FP32), use
    :func:`residency_speedup`.
    """
    rec = get_recipe(recipe)
    est = cycles(rec, residency)
    ratio = None if est.cycles is None else BASELINE_CYCLES / est.cycles
    return Speedup(
        recipe=rec.name,
        residency=est.residency,
        cycle_speedup=ratio,
        cycle_provenance=est.provenance,
        cycles=est.cycles,
        baseline_cycles=BASELINE_CYCLES,
        traffic_speedup=_K_BYTES[AI_FMT_FP32] / rec.k_bytes_per_element,
        inferred_from_k_bytes=est.inferred,
        note=est.note,
    )


def residency_speedup(recipe: "Recipe | str", residency: str) -> Optional[float]:
    """Same-format gain from operand residency: ``cycles(none) / cycles(residency)``.

    ``None`` when either end is unavailable.  This is the figure ``va-turbo.md`` §10 reports
    (INT8 both = 1.359x, FP32 both = 1.279x); it is not comparable across formats, which is
    why :func:`speedup` uses the FP32 baseline instead.
    """
    rec = get_recipe(recipe)
    cold = cycles(rec, "none")
    warm = cycles(rec, residency)
    if cold.cycles is None or warm.cycles is None:
        return None
    return cold.cycles / warm.cycles


# ------------------------------------------------------------------------ host emulation
#: Guard on the per-product kernels, which materialise an (M, K, N) tensor. A silent 40 GB
#: allocation is not a better failure than a refusal.
MAX_PRODUCT_ELEMENTS = 1 << 24


def _require_torch(what: str):
    if torch is None:  # pragma: no cover - exercised by the no-torch CI leg
        raise ImportError(
            f"ai_tensor.va_turbo.{what} requires PyTorch; the cycle model, the recipe "
            "catalog and the ppm ladder do not"
        )
    return torch


def _operands(a, b):
    """Validate and round both operands to the FP32 reference storage.

    A float64 caller is rounded to FP32 first, on purpose: the reference this module scores
    against is the FP32 datapath, so an unrounded float64 input would charge the native
    recipe for the caller's own downcast.
    """
    t = _require_torch("emulate")
    for name, x in (("a", a), ("b", b)):
        if not isinstance(x, t.Tensor):
            raise TypeError(f"{name} must be a torch.Tensor, got {type(x).__name__}")
        if x.dim() != 2:
            raise ValueError(f"{name} must be 2-D, got shape {tuple(x.shape)}")
        if not x.is_floating_point():
            raise TypeError(f"{name} must be a floating tensor; quantisation is the recipe's job")
    if a.shape[1] != b.shape[0]:
        raise ValueError(f"shape mismatch {tuple(a.shape)} @ {tuple(b.shape)}")
    return (a.detach().to(t.float32).contiguous(),
            b.detach().to(t.float32).contiguous())


def _torch_dtype(numfmt: int):
    t = _require_torch("emulate")
    name = {
        AI_FMT_FP16: "float16",
        AI_FMT_BF16: "bfloat16",
        AI_FMT_FP8_E4M3: "float8_e4m3fn",
        AI_FMT_FP8_E5M2: "float8_e5m2",
    }[numfmt]
    dtype = getattr(t, name, None)
    if dtype is None:
        raise NotImplementedError(
            f"this torch build has no {name}; the storage round-trip cannot be emulated and "
            "will not be approximated by a nearby dtype"
        )
    return dtype


def _narrow_storage(x, numfmt: int, scaled: bool):
    """Storage narrowing by a real ``.to(dtype)`` round trip, optionally per-tensor scaled."""
    t = torch
    dtype = _torch_dtype(numfmt)
    if not scaled:
        return x.to(dtype).to(t.float64)
    # FP8's exponent range is small enough that an unscaled tensor can overflow outright;
    # per-tensor scaling is what any real FP8 path does, and policy_approx.py measures it the
    # same way. Without it FP8 would be scored on its raw exponent range, not its precision.
    amax = x.abs().max().to(t.float64)
    if not bool(t.isfinite(amax)) or float(amax) == 0.0:
        return x.to(t.float64)
    return (x.to(t.float64) / amax).to(dtype).to(t.float64) * amax


def _quantise(x, levels: int):
    """Symmetric per-tensor scale-and-round, the INT8/INT4 operand path."""
    t = torch
    xd = x.to(t.float64)
    amax = xd.abs().max()
    if not bool(t.isfinite(amax)) or float(amax) == 0.0:
        return xd
    scale = amax / levels
    return t.clamp(t.round(xd / scale), -levels - 1, levels) * scale


def _truncate_mantissa(x, keep: int):
    """Keep ``keep`` explicit mantissa bits of an FP32 operand by bit masking."""
    t = torch
    if not isinstance(keep, int) or not 0 <= keep <= 23:
        raise ValueError("retained mantissa bits must be in [0, 23]")
    bits = x.to(t.float32).contiguous().view(t.int32)
    mask = -1 << (23 - keep)
    return (bits & mask).view(t.float32).to(t.float64)


def _mitchell_matmul(a, b):
    """Logarithmic-multiply emulation: exponent add plus a linear mantissa term."""
    t = torch
    m, k = a.shape
    n = b.shape[1]
    if m * k * n > MAX_PRODUCT_ELEMENTS:
        raise ValueError(
            f"Mitchell emulation materialises {m}x{k}x{n} products, above the "
            f"{MAX_PRODUCT_ELEMENTS} guard; tile the call rather than allocating it"
        )
    ad, bd = a.to(t.float64), b.to(t.float64)
    aa, ab = ad.abs(), bd.abs()
    a_nz, b_nz = aa > 0, ab > 0
    ea = t.where(a_nz, t.floor(t.log2(t.where(a_nz, aa, t.ones_like(aa)))), t.zeros_like(aa))
    eb = t.where(b_nz, t.floor(t.log2(t.where(b_nz, ab, t.ones_like(ab)))), t.zeros_like(ab))
    ma = t.where(a_nz, aa / t.pow(2.0, ea) - 1.0, t.zeros_like(aa))
    mb = t.where(b_nz, ab / t.pow(2.0, eb) - 1.0, t.zeros_like(ab))
    products = t.pow(2.0, ea.unsqueeze(2) + eb.unsqueeze(0)) * (
        1.0 + ma.unsqueeze(2) + mb.unsqueeze(0)
    )
    products = products * (t.sign(ad).unsqueeze(2) * t.sign(bd).unsqueeze(0))
    products = t.where(a_nz.unsqueeze(2) & b_nz.unsqueeze(0), products, t.zeros_like(products))
    return products.sum(dim=1)


_KERNELS = ("native", "storage", "storage_scaled", "quant", "truncate", "mitchell")


def _emulate_f64(a32, b32, rec: Recipe):
    """Recipe arithmetic on FP32 operands, accumulated in float64.

    float64 accumulation is a deliberate PROXY for the RTL's exact 640-bit integer block
    reduction, and it is used for the candidate *and* the reference so the score is the
    recipe's own error rather than accumulator noise.  It is not the RTL FP32 accumulation
    contract; ``policy_approx.py`` carries the same caveat.
    """
    t = torch
    if rec.kernel == "native":
        return a32.to(t.float64) @ b32.to(t.float64)
    if rec.kernel in ("storage", "storage_scaled"):
        scaled = rec.kernel == "storage_scaled"
        return _narrow_storage(a32, rec.numfmt, scaled) @ _narrow_storage(b32, rec.numfmt, scaled)
    if rec.kernel == "quant":
        if rec.quant_levels is None:
            raise ValueError(f"recipe {rec.name} has no quant_levels")
        return _quantise(a32, rec.quant_levels) @ _quantise(b32, rec.quant_levels)
    if rec.kernel == "truncate":
        if rec.mantissa_bits is None:
            raise ValueError(f"recipe {rec.name} has no mantissa_bits")
        return _truncate_mantissa(a32, rec.mantissa_bits) @ _truncate_mantissa(b32, rec.mantissa_bits)
    if rec.kernel == "mitchell":
        return _mitchell_matmul(a32, b32)
    raise ValueError(f"recipe {rec.name} has unknown kernel {rec.kernel!r}")


def emulate(a, b, recipe: "Recipe | str"):
    """Apply ``recipe``'s arithmetic to FP32 torch tensors and return the approximate product.

    This is a **host emulation**.  It predicts what the arithmetic would cost in accuracy; it
    does not dispatch anything to the island, and for every approximate recipe there is no
    island path that could execute it (see the module warning).

    Deterministic: no sampling, no reduction reordering, no dependence on thread count for
    the shapes it is meant for.  Returns FP32 (the caller's storage), while :func:`quality`
    scores in the float64 accumulation domain so that FP32 result rounding is not charged to
    the recipe.

    Contrast :func:`execute`, which for a ``native-narrowed`` recipe performs the conversion
    and then really submits a native descriptor.  ``emulate`` predicts; ``execute`` runs.
    """
    t = _require_torch("emulate")
    rec = get_recipe(recipe)
    a32, b32 = _operands(a, b)
    return _emulate_f64(a32, b32, rec).to(t.float32)


# ----------------------------------------------------------------------------- execute


def narrowed_operands(a, b, recipe: "Recipe | str"):
    """Convert ``a``/``b`` to ``recipe``'s storage format, ready for a native submission.

    Returns ``(a_narrow, b_narrow, scale)``.  ``scale`` is ``None`` for the float formats,
    whose conversion is value-preserving in the sense that the stored tensor already *is* the
    approximated value.  For INT8/INT4 the operands are integers and ``scale`` is the factor
    the integer accumulator must be multiplied by to return to the caller's units:

        C_fp32 ~= C_int32 * scale_a * scale_b

    The scale is returned rather than folded in because the island returns integer
    accumulators, and handing a caller raw INT32 as if it were the FP32 answer is the classic
    way a quantised path silently reports nonsense.
    """
    t = _require_torch("narrowed_operands")
    rec = get_recipe(recipe)
    a32, b32 = _operands(a, b)
    if rec.kernel == "native":
        return a32, b32, None
    if rec.kernel in ("storage", "storage_scaled"):
        dtype = _torch_dtype(rec.numfmt)
        if rec.kernel == "storage":
            return a32.to(dtype), b32.to(dtype), None
        # FP8 needs the per-tensor scale to survive its exponent range; fold each operand's
        # own amax into the stored value and hand both scales back.
        sa = a32.abs().max().to(t.float64)
        sb = b32.abs().max().to(t.float64)
        sa = sa if bool(t.isfinite(sa)) and float(sa) != 0.0 else t.tensor(1.0, dtype=t.float64)
        sb = sb if bool(t.isfinite(sb)) and float(sb) != 0.0 else t.tensor(1.0, dtype=t.float64)
        an = (a32.to(t.float64) / sa).to(dtype)
        bn = (b32.to(t.float64) / sb).to(dtype)
        return an, bn, float(sa) * float(sb)
    if rec.kernel == "quant":
        levels = rec.quant_levels
        if not isinstance(levels, int) or levels < 1:
            raise ValueError(f"{rec.name}: quant recipe without quant_levels")
        ad, bd = a32.to(t.float64), b32.to(t.float64)
        amax, bmax = ad.abs().max(), bd.abs().max()
        sa = float(amax) / levels if bool(t.isfinite(amax)) and float(amax) != 0.0 else 1.0
        sb = float(bmax) / levels if bool(t.isfinite(bmax)) and float(bmax) != 0.0 else 1.0
        ai = t.clamp(t.round(ad / sa), -levels - 1, levels).to(t.int8)
        bi = t.clamp(t.round(bd / sb), -levels - 1, levels).to(t.int8)
        return ai, bi, sa * sb
    raise NotImplementedError(
        f"{rec.name} has kernel {rec.kernel!r}, which changes arithmetic rather than storage, "
        "so there is no narrowed operand to submit"
    )


@dataclass(frozen=True)
class Execution:
    """The result of really running a recipe, as opposed to predicting it.

    ``c`` is in the caller's units: for an integer recipe the integer accumulator has already
    been multiplied by ``scale``, and ``scale`` is reported so the raw path stays inspectable.
    ``meta`` is whatever the underlying native submission returned (ticket, status, PMU) —
    unmodified, because that is the evidence the run happened.
    """

    recipe: str
    c: "object"
    scale: Optional[float]
    numfmt: int
    meta: dict
    plan: "Plan"
    note: str

    @property
    def executed_natively(self) -> bool:
        return True


def execute(a, b, recipe: "Recipe | str", *, device=None, backend: str = "sim",
            ticket: int = 1, dtype_mask: Optional[int] = None):
    """Convert per ``recipe``, then submit a NATIVE descriptor at the narrower format.

    This is what makes a predicted narrowing speedup real: nothing approximate runs in the
    datapath, because the approximation already happened in the conversion.  The GEMM is an
    ordinary native one at a smaller ``k_bytes``, which is exactly where the measured cycle
    reduction comes from.

    Refuses, loudly, in two cases:

    * ``needs-rtl-consumer`` recipes (mantissa truncation, Mitchell, in-place quantisation) —
      they need approximate arithmetic that does not exist, and they measure 1.000x anyway;
    * a target format the active profile does not advertise in its ``dtype_mask``.

    Use :func:`emulate` when a prediction is what is wanted.
    """
    _require_torch("execute")
    rec = get_recipe(recipe)
    if rec.hardware_execution == NEEDS_RTL_CONSUMER:
        ok, why = _execution_verdict(rec, "none", dtype_mask)
        raise NotImplementedError(why)

    from . import torch_ops

    ok, why = _execution_verdict(rec, "none", dtype_mask)
    if not ok:
        raise ValueError(why)

    an, bn, scale = narrowed_operands(a, b, rec)
    if rec.kernel == "quant":
        c, meta = torch_ops.gemm_s8(an, bn, device=device, ticket=ticket, backend=backend)
        c = c.to(torch.float64) * scale
    else:
        c, meta = torch_ops.gemm(an, bn, device=device, backend=backend, ticket=ticket)
        c = c.to(torch.float64)
        if scale is not None:
            c = c * scale
    plan = _plan_for(a, b, rec, None, with_quality=False, dtype_mask=dtype_mask)
    return Execution(
        recipe=rec.name,
        c=c.to(torch.float32),
        scale=scale,
        numfmt=rec.numfmt,
        meta=meta,
        plan=plan,
        note=(
            f"converted to {NUMFMT_NAMES[rec.numfmt]} in software, then submitted a native "
            f"descriptor at that format via backend {backend!r}. The arithmetic approximation "
            "is the conversion; the GEMM was native."
        ),
    )


# ----------------------------------------------------------------------------- quality


@dataclass(frozen=True)
class Quality:
    """How well a recipe fits the caller's tensors, against the FP32 reference.

    ``status`` is ``None`` for a usable measurement.  Anything else means the numbers below
    are fail-closed placeholders (``inf`` error, ``-inf`` SQNR) and must not be read as a
    score — a nonfinite is never reported as good.
    """

    recipe: str
    rel_fro_error: float
    sqnr_db: float
    cosine: float
    max_abs_error: float
    ppm: float
    status: Optional[str] = None
    #: Ladder level that would cover `ppm`, or None when it is not expressible (>100%).
    budget_level: Optional[int] = None

    @property
    def ok(self) -> bool:
        return self.status is None


_FAILED_QUALITY = dict(
    rel_fro_error=math.inf,
    sqnr_db=-math.inf,
    cosine=float("nan"),
    max_abs_error=math.inf,
    ppm=math.inf,
    budget_level=None,
)


def _fail_closed(name: str, status: str) -> Quality:
    return Quality(recipe=name, status=status, **_FAILED_QUALITY)


def score_against_reference(candidate, reference, name: str) -> Quality:
    """Score an already-computed ``candidate`` tensor against its ``reference``.

    The metric half of :func:`quality`, factored out so that anything measuring the *same*
    quantities at a different site — :mod:`ai_tensor.va_turbo_net` scores the logits of a whole
    transformer stack — reports them in this exact vocabulary, with this exact fail-closed
    behaviour, rather than growing a second slightly different definition.

    Shapes must match; the tensors are compared in float64.  Fails closed on a nonfinite
    reference, a nonfinite candidate, a nonfinite metric, or a zero reference with nonzero
    error (where the relative metric is undefined).
    """
    t = _require_torch("score_against_reference")
    if tuple(candidate.shape) != tuple(reference.shape):
        raise ValueError(
            f"shape mismatch: candidate {tuple(candidate.shape)} vs reference {tuple(reference.shape)}"
        )
    reference = reference.to(t.float64)
    candidate = candidate.to(t.float64)
    if not bool(t.isfinite(reference).all()):
        return _fail_closed(name, "nonfinite_reference")
    if not bool(t.isfinite(candidate).all()):
        return _fail_closed(name, "nonfinite_approximation")

    difference = candidate - reference
    err = float(difference.norm())
    ref = float(reference.norm())
    max_abs = float(difference.abs().max()) if difference.numel() else 0.0
    if not (math.isfinite(err) and math.isfinite(ref) and math.isfinite(max_abs)):
        return _fail_closed(name, "nonfinite_metric")
    if ref == 0.0:
        if err == 0.0:
            return Quality(name, 0.0, math.inf, 1.0, 0.0, 0.0, None, 0)
        return _fail_closed(name, "zero_reference_with_nonzero_error")

    rel = err / ref
    sqnr = math.inf if err == 0.0 else 20.0 * math.log10(ref / err)
    denom = float(candidate.norm()) * ref
    cosine = float((candidate * reference).sum()) / denom if denom > 0 else float("nan")
    ppm = rel * 1e6
    if not (math.isfinite(rel) and math.isfinite(ppm)):
        return _fail_closed(name, "nonfinite_metric")
    level = error_budget_level(ppm) if 0 <= ppm <= LADDER_MAX_PPM else None
    return Quality(name, rel, sqnr, cosine, max_abs, ppm, None, level)


def quality(a, b, recipe: "Recipe | str") -> Quality:
    """Score ``recipe`` on the caller's actual tensors against the FP32 reference.

    Both the candidate and the reference are accumulated in float64 (see
    :func:`_emulate_f64`), so ``native-fp32`` scores exactly zero and every other number is
    the recipe's own arithmetic error rather than accumulator noise.

    Fails closed: a nonfinite operand, reference or result yields ``status`` set and
    ``rel_fro_error = inf`` / ``sqnr_db = -inf``.  A zero reference with a nonzero error is
    also a failure, because the relative metric is undefined there.
    """
    t = _require_torch("quality")
    rec = get_recipe(recipe)
    a32, b32 = _operands(a, b)
    if not bool(t.isfinite(a32).all()) or not bool(t.isfinite(b32).all()):
        return _fail_closed(rec.name, "nonfinite_operand")

    reference = a32.to(t.float64) @ b32.to(t.float64)
    if not bool(t.isfinite(reference).all()):
        return _fail_closed(rec.name, "nonfinite_reference")
    try:
        candidate = _emulate_f64(a32, b32, rec)
    except NotImplementedError as exc:
        return _fail_closed(rec.name, f"unsupported_by_torch: {exc}")
    return score_against_reference(candidate, reference, rec.name)


# -------------------------------------------------------------------------------- plans


#: `dtype_mask` bit per numfmt, as `numfmt.check_format` reads it.
def format_supported(numfmt: int, dtype_mask: int) -> bool:
    """Whether a profile advertising ``dtype_mask`` can run ``numfmt``."""
    if not isinstance(dtype_mask, int) or isinstance(dtype_mask, bool):
        return False
    return bool(dtype_mask >> numfmt & 1)


def _execution_verdict(rec: Recipe, residency: str,
                       dtype_mask: Optional[int] = None) -> Tuple[bool, str]:
    """The honesty gate: can the island actually run this, and why (not)?

    ``dtype_mask`` is the active profile's advertised format set.  It is what decides a
    ``native-narrowed`` recipe, because the narrowing is only useful if the datapath will
    accept a descriptor at the narrower format: ``sim-v0`` and ``island-p3-v1`` advertise
    ``0x0001`` (INT8 only) while ``software-reference-v2`` advertises ``0x00fb``.  Passing
    ``None`` means "no profile named", and the verdict then reports capability in principle
    without claiming a specific backend would accept it.
    """
    if rec.hardware_execution == NEEDS_RTL_CONSUMER:
        return False, (
            f"NOT EXECUTABLE: recipe {rec.id if rec.id is not None else '?'} "
            f"({rec.name}) needs approximate ARITHMETIC in the datapath, and no such consumer "
            "exists — va_turbo_select produces selection metadata only. It would also buy "
            "nothing here: this recipe narrows no storage, so its measured cycle speedup is "
            "exactly 1.000x. An RTL consumer for it would be area spent for zero throughput; "
            "the quality figures come from HOST EMULATION."
        )
    # The format check is NOT special to narrowing. A profile granting only INT8 refuses a
    # native FP32 descriptor too — `sim-v0` really does return `ST_BAD_FMT: numfmt 7 not
    # granted by 0x1` — so gating only the narrowed recipes would have claimed the exact
    # path was executable on a backend that rejects it.
    if dtype_mask is not None and not format_supported(rec.numfmt, dtype_mask):
        return False, (
            f"NOT EXECUTABLE HERE: {rec.name} needs numfmt {NUMFMT_NAMES[rec.numfmt]} "
            f"({rec.numfmt}), which the active profile does not advertise — dtype_mask "
            f"{dtype_mask:#06x} has bit {rec.numfmt} clear. The datapath supports the format "
            "(all seven are measured); this profile does not offer it. A wider mask (e.g. "
            "software-reference-v2, 0x00fb) can run it."
        )
    if rec.hardware_execution == NATIVE_NARROWED:
        if dtype_mask is None:
            return True, (
                f"EXECUTABLE (native-narrowed): the approximation is the SOFTWARE conversion "
                f"to {NUMFMT_NAMES[rec.numfmt]}; the GEMM that follows is an ordinary native "
                "one, which is where the measured cycle count comes from. No approximate "
                "hardware is involved and none is needed. No profile was named, so no backend "
                "is claimed to accept the descriptor — pass a dtype_mask to check one."
            )
        return True, (
            f"EXECUTABLE (native-narrowed): convert to {NUMFMT_NAMES[rec.numfmt]} in software, "
            f"then submit a NATIVE descriptor at that format; dtype_mask {dtype_mask:#06x} "
            "advertises it. The speedup is the measured native cycle count for the narrower "
            "operand traffic, not a claim about approximate hardware."
        )
    if residency != "none":
        return True, (
            "EXECUTABLE (exact): recipe 16 operand residency changes no arithmetic. It is "
            "wired to real GEMM execution in the verification harness (ReuseBEn / resident-A). "
            "Production g6lc_ai_island_top ties runtime reuse off because live VaTurboEn is 0. "
            "The epoch register is published. The selector still does not apply a recipe, "
            "and reuse_b_i is permission, not coherence."
        )
    return True, "EXECUTABLE (exact): recipe 0 is the native datapath the island runs today."


def _flag(value: object) -> bool:
    return isinstance(value, bool) and value


@dataclass(frozen=True)
class Gates:
    """Config-chain inputs of the selector's permission stage.

    Each bit is separate so a live package, the directed test config, or a
    chain with one gate clear can all be evaluated. An integer where a
    boolean is required fails closed.
    """

    va_turbo_en: object = False
    policy_subcode_en: object = False
    policy_benefit_en: object = False
    policy_codec_en: object = False
    island_fp_en: object = False
    matrix_en: object = False
    queues: object = 0
    enable: object = False

    @staticmethod
    def directed() -> "Gates":
        """``AiCfgVaTurboTest``: the chain set, one queue, runtime enable on."""
        return Gates(True, True, True, True, True, True, 1, True)

    def chain(self) -> bool:
        """``VaTurboEn`` through ``Queues > 0``. Runtime enable is predicate 2."""
        queues_ok = (
            isinstance(self.queues, int)
            and not isinstance(self.queues, bool)
            and self.queues > 0
        )
        return (
            _flag(self.va_turbo_en)
            and _flag(self.policy_subcode_en)
            and _flag(self.policy_benefit_en)
            and _flag(self.policy_codec_en)
            and _flag(self.island_fp_en)
            and _flag(self.matrix_en)
            and queues_ok
        )


@dataclass(frozen=True)
class Permission:
    """The five selector predicates, and the MAC result.

    ``permitted`` is their conjunction for any recipe id in ``0..31``.
    ``apply`` stays false. The selector is not connected to the MAC path,
    and the applied level is 0. This is not class eligibility inside
    ``va_turbo_select``.
    """

    gates: bool
    level_nonzero: bool
    consumer: bool
    profile: bool
    window: bool
    permitted: bool
    apply: bool


def _mask_has_recipe(mask: object, recipe: object) -> bool:
    if isinstance(mask, bool) or isinstance(recipe, bool):
        return False
    if not isinstance(mask, int) or not isinstance(recipe, int):
        return False
    if mask < 0 or recipe < 0 or recipe > 31:
        return False
    return bool(mask & (1 << recipe))


def permission(
    gates: Gates,
    *,
    level: int,
    recipe: int,
    consumer_mask: int,
    profile_mask: int,
    window_valid: bool,
) -> Permission:
    """Report the selector predicates for one recipe id."""
    level_ok = (
        _flag(gates.enable)
        and isinstance(level, int)
        and not isinstance(level, bool)
        and 0 < level <= 15
    )
    gates_ok = gates.chain()
    consumer = _mask_has_recipe(consumer_mask, recipe)
    profile = _mask_has_recipe(profile_mask, recipe)
    window = _flag(window_valid)
    return Permission(
        gates=gates_ok,
        level_nonzero=level_ok,
        consumer=consumer,
        profile=profile,
        window=window,
        permitted=gates_ok and level_ok and consumer and profile and window,
        apply=False,
    )


@dataclass(frozen=True)
class Plan:
    """One scored candidate: throughput, quality, and what the hardware can really do."""

    recipe: Recipe
    speedup: Speedup
    quality: Optional[Quality]
    executable_on_hardware: bool
    why: str
    hardware_execution: str
    residency: str
    inferred_from_k_bytes: bool

    @property
    def name(self) -> str:
        return self.recipe.name

    @property
    def cycle_speedup(self) -> Optional[float]:
        return self.speedup.cycle_speedup

    @property
    def ppm(self) -> float:
        if self.quality is None:
            return math.nan
        return self.quality.ppm

    def as_dict(self) -> dict:
        q = self.quality
        return {
            "recipe": self.recipe.name,
            "recipe_id": self.recipe.id,
            "storage_format": self.recipe.storage_format,
            "residency": self.residency,
            "cycle_speedup": self.speedup.cycle_speedup,
            "cycle_provenance": self.speedup.cycle_provenance,
            "cycles": self.speedup.cycles,
            "traffic_speedup": self.speedup.traffic_speedup,
            "traffic_provenance": self.speedup.traffic_provenance,
            "inferred_from_k_bytes": self.inferred_from_k_bytes,
            "rel_fro_error_ppm": None if q is None else q.ppm,
            "sqnr_db": None if q is None else q.sqnr_db,
            "cosine": None if q is None else q.cosine,
            "quality_status": None if q is None else q.status,
            "budget_level": None if q is None else q.budget_level,
            "executable_on_hardware": self.executable_on_hardware,
            "hardware_execution": self.hardware_execution,
            "why": self.why,
        }


@dataclass(frozen=True)
class NoCandidate:
    """Returned by :func:`autotune` when nothing satisfies the caller's constraints.

    Not an exception (the question was legitimate and the answer is informative), and not a
    silent fallback to native (which would answer a different question).  ``rejected`` lists
    every candidate with the reason it lost, so the caller can see whether the budget, the
    speedup floor or missing cycle data was the binding constraint.
    """

    constraints: dict
    rejected: List[Tuple[str, str]]
    #: The residency that was requested; ``None`` means each recipe's own default was used.
    residency: Optional[str]
    reason: str = "no recipe satisfies the requested throughput/quality constraints"

    executable_on_hardware: bool = False
    why: str = "no plan was selected, so nothing is claimed to be executable"

    def __bool__(self) -> bool:  # `if autotune(...)` reads as "did I get a plan?"
        return False


def _plan_for(a, b, rec: Recipe, residency: Optional[str], *, with_quality: bool,
              dtype_mask: Optional[int] = None) -> Plan:
    sp = speedup(rec, residency)
    q = quality(a, b, rec) if with_quality else None
    ok, why = _execution_verdict(rec, sp.residency, dtype_mask)
    return Plan(
        recipe=rec,
        speedup=sp,
        quality=q,
        executable_on_hardware=ok,
        why=why,
        hardware_execution=rec.hardware_execution,
        residency=sp.residency,
        inferred_from_k_bytes=sp.inferred_from_k_bytes,
    )


def _candidates(recipes: Optional[Sequence["Recipe | str"]]) -> List[Recipe]:
    if recipes is None:
        return list(_RECIPE_LIST)
    return [get_recipe(r) for r in recipes]


def plans(a, b, recipes: Optional[Sequence["Recipe | str"]] = None,
          residency: Optional[str] = None, dtype_mask: Optional[int] = None) -> List[Plan]:
    """Score every candidate recipe on the caller's tensors.  Unsorted, unfiltered."""
    return [_plan_for(a, b, rec, residency, with_quality=True, dtype_mask=dtype_mask)
            for rec in _candidates(recipes)]


def pareto(a, b, recipes: Optional[Sequence["Recipe | str"]] = None,
           residency: Optional[str] = None) -> List[Plan]:
    """Non-dominated (speedup, quality) frontier on the caller's tensors.

    ``p`` dominates ``q`` when it is at least as fast **and** at least as accurate, and
    strictly better in one of them.  Plans with no cycle data at this residency, or with a
    failed quality status, are excluded rather than ranked: a nonfinite score must never win
    a comparison.  Sorted fastest first.
    """
    scored = [p for p in plans(a, b, recipes, residency)
              if p.speedup.cycle_speedup is not None and p.quality is not None and p.quality.ok]
    frontier: List[Plan] = []
    for p in scored:
        dominated = False
        for q in scored:
            if q is p:
                continue
            faster_eq = q.speedup.cycle_speedup >= p.speedup.cycle_speedup
            better_eq = q.quality.rel_fro_error <= p.quality.rel_fro_error
            strictly = (q.speedup.cycle_speedup > p.speedup.cycle_speedup
                        or q.quality.rel_fro_error < p.quality.rel_fro_error)
            if faster_eq and better_eq and strictly:
                dominated = True
                break
        if not dominated:
            frontier.append(p)
    frontier.sort(key=lambda p: (-p.speedup.cycle_speedup, p.quality.rel_fro_error))
    return frontier


def autotune(a, b, *, max_rel_error_ppm: Optional[float] = None,
             min_sqnr_db: Optional[float] = None,
             min_speedup: Optional[float] = None,
             recipes: Optional[Sequence["Recipe | str"]] = None,
             residency: Optional[str] = None) -> "Plan | NoCandidate":
    """Best recipe meeting the caller's constraints, or a :class:`NoCandidate`.

    Constraints are ANDed and at least one must be given; calling with none is a programming
    error (it would silently mean "give me INT4"), so it raises rather than answering a
    question that was not asked.

    **Which axis is optimised depends on which axis was constrained**, because the other one
    is what the caller left free:

    * a quality constraint (``max_rel_error_ppm`` / ``min_sqnr_db``) means "I have accuracy
      to spend" -> maximise speedup;
    * ``min_speedup`` alone means "I need this much throughput" -> maximise QUALITY among the
      recipes that reach it. Returning the fastest here would hand back INT4 at 190,000 ppm
      when INT8 at 9,000 ppm also cleared the bar, i.e. spend accuracy the caller never
      offered;
    * both kinds together -> maximise speedup, since the quality floor is already explicit.

    ``max_rel_error_ppm`` is on the same ppm scale as the geometric ladder, so
    ``error_budget_level(max_rel_error_ppm)`` is the RTL level the choice corresponds to.

    The returned plan still carries ``executable_on_hardware`` — for every approximate
    recipe that is ``False``, and choosing one means choosing a *prediction*, not a run.
    """
    if max_rel_error_ppm is None and min_sqnr_db is None and min_speedup is None:
        raise ValueError(
            "autotune needs at least one of max_rel_error_ppm / min_sqnr_db / min_speedup; "
            "with no constraint it would just return the fastest recipe, which is not a "
            "trade-off decision"
        )
    constraints = {
        "max_rel_error_ppm": max_rel_error_ppm,
        "min_sqnr_db": min_sqnr_db,
        "min_speedup": min_speedup,
    }
    rejected: List[Tuple[str, str]] = []
    admitted: List[Plan] = []
    for p in plans(a, b, recipes, residency):
        if p.speedup.cycle_speedup is None:
            rejected.append((p.name, f"no cycle data at residency={p.residency} ({p.speedup.note})"))
            continue
        if p.quality is None or not p.quality.ok:
            status = "not scored" if p.quality is None else p.quality.status
            rejected.append((p.name, f"quality failed closed: {status}"))
            continue
        if max_rel_error_ppm is not None and p.quality.ppm > max_rel_error_ppm:
            rejected.append((p.name, f"{p.quality.ppm:.1f} ppm exceeds {max_rel_error_ppm} ppm"))
            continue
        if min_sqnr_db is not None and p.quality.sqnr_db < min_sqnr_db:
            rejected.append((p.name, f"{p.quality.sqnr_db:.2f} dB below {min_sqnr_db} dB"))
            continue
        if min_speedup is not None and p.speedup.cycle_speedup < min_speedup:
            rejected.append((p.name, f"{p.speedup.cycle_speedup:.3f}x below {min_speedup}x"))
            continue
        admitted.append(p)
    if not admitted:
        return NoCandidate(constraints=constraints, rejected=rejected, residency=residency)
    quality_constrained = max_rel_error_ppm is not None or min_sqnr_db is not None
    if quality_constrained:
        admitted.sort(key=lambda p: (-p.speedup.cycle_speedup, p.quality.rel_fro_error))
    else:
        admitted.sort(key=lambda p: (p.quality.rel_fro_error, -p.speedup.cycle_speedup))
    return admitted[0]
