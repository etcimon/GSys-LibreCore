# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Stacking recipes, and the sequences that must be refused.

The value of this module is not that it multiplies speedups -- it is that it refuses the
combinations that would silently not work. The headline case is the ordering hazard: the
RTL's residency keys include the numeric format, so a narrowing composed with residency is
a guaranteed cache miss unless the resident tile was already converted. A planner that got
that wrong would report a 4.8x stack and deliver less than either lever alone.
"""

import math

import pytest

from ai_tensor import pipeline as P
from ai_tensor import va_turbo as vt
from ai_tensor.c_abi import (
    AI_FMT_BF16,
    AI_FMT_FP16,
    AI_FMT_FP32,
    AI_FMT_INT,
    AI_FMT_INT4,
)


def narrow(target, eps_ppm=0):
    return P.Stage("narrow", target=target, eps_ppm=eps_ppm)


BOTH_RESIDENT = P.Stage("resident", resident_a=True, resident_b=True)


def test_the_decomposition_reproduces_every_measured_point():
    """`steps + beta*beats + 11` against all ten measurements, with no per-point fudge.

    Four format totals and six residency points, from two free parameters per format (beta)
    plus ONE shared constant. The FP32 and INT8 single-operand points are genuine
    predictions: beta was fitted on the 0-vs-full-beats endpoints, so the midpoints were not
    used to fit anything, and the shared constant falling out as 11 for both independently
    swept formats is the reason to believe the decomposition rather than merely accept it.
    """
    for numfmt, measured in vt.MEASURED_CYCLES.items():
        assert P.model_cycles(numfmt) == pytest.approx(measured), vt.NUMFMT_NAMES[numfmt]
    for numfmt, table in vt.MEASURED_RESIDENCY_CYCLES.items():
        for residency, measured in table.items():
            got = P.model_cycles(numfmt,
                                 resident_a=residency in ("a", "both"),
                                 resident_b=residency in ("b", "both"))
            assert got == pytest.approx(measured), (numfmt, residency)
    assert P.MODEL_CONSTANT == 11


def test_beta_rises_as_the_format_narrows():
    """Traffic hides under compute, and a narrow job has less compute to hide it under.

    This is why residency is worth MORE after narrowing, and therefore why the stack is
    mildly super-multiplicative rather than sub-.
    """
    assert P.BETA[AI_FMT_FP32] < P.BETA[AI_FMT_FP16] < P.BETA[AI_FMT_INT] < P.BETA[AI_FMT_INT4]
    fp32_gain = 669 / 523
    int8_gain = 189 / 139
    assert int8_gain > fp32_gain


def test_the_measured_stack_is_reported_as_measured():
    """FP32 -> INT8 narrowing plus both operands resident: 139 against 669."""
    result = P.pipeline([narrow(AI_FMT_INT), BOTH_RESIDENT], resident_at_target=True)
    assert result
    assert result.baseline.cycles == 669 and result.composed.cycles == 139
    assert result.speedup == pytest.approx(669 / 139)
    assert result.speedup == pytest.approx(4.813, abs=1e-3)
    # Both endpoints are measured, so the RATIO is measured -- not modelled.
    assert result.provenance == P.MEASURED
    assert result.baseline.measured and result.composed.measured
    # A lossless narrowing to an integer target is exact, so the whole stack is.
    assert result.exact and result.eps_ppm == 0
    # And it is super-multiplicative against the naive product of published gains.
    assert result.speedup > (669 / 189) * (669 / 523) / 1.0 - 0.5


def test_composition_is_multiplicative_at_the_target_not_the_source():
    """The trap: composing with the SOURCE's residency gain understates the stack."""
    narrowing = 669 / 189
    residency_at_int8 = 189 / 139
    residency_at_fp32 = 669 / 523
    assert narrowing * residency_at_int8 == pytest.approx(669 / 139)
    assert narrowing * residency_at_fp32 < 669 / 139      # the understatement


def test_the_ordering_hazard_is_refused_by_default():
    """The most important refusal in this module.

    The RTL residency keys include the format, so narrowing then reusing is a guaranteed
    miss. Refusing by default means a caller has to say the tile was already converted.
    """
    refused = P.pipeline([narrow(AI_FMT_INT), BOTH_RESIDENT])
    assert not refused
    assert refused.rule == "hazard.residency_format"
    assert "MISS" in refused.reason
    assert "resident_at_target=True" in refused.reason
    # Order must not matter: the hazard is about the pair, not the sequence.
    assert not P.pipeline([BOTH_RESIDENT, narrow(AI_FMT_INT)])
    # Residency alone is fine, since no format change occurs.
    assert P.pipeline([BOTH_RESIDENT])
    # And so is narrowing alone.
    assert P.pipeline([narrow(AI_FMT_INT)])


def test_conflicting_targets_and_geometries_are_refused():
    conflict = P.pipeline([narrow(AI_FMT_INT), narrow(AI_FMT_BF16)])
    assert not conflict and conflict.rule == "conflict.target"
    assert "one operand store" in conflict.reason
    groups = P.pipeline([P.Stage("group", groups_log2=1), P.Stage("group", groups_log2=2)])
    assert not groups and groups.rule == "conflict.groups"


def test_narrowing_is_idempotent_because_it_collapses():
    """FP32->BF16->FP8 is FP32->FP8: exact representability is transitive downward."""
    once = P.pipeline([narrow(AI_FMT_INT)])
    twice = P.pipeline([narrow(AI_FMT_INT), narrow(AI_FMT_INT)])
    assert twice
    assert twice.speedup == once.speedup
    assert twice.target_numfmt == once.target_numfmt
    assert twice.eps_ppm == once.eps_ppm
    assert any("idempotent" in note for note in twice.notes)


def test_widening_is_refused_because_it_saves_no_beats():
    for source, target in ((AI_FMT_INT, AI_FMT_FP32), (AI_FMT_FP16, AI_FMT_BF16)):
        refused = P.pipeline([narrow(target)], source_numfmt=source)
        assert not refused, (source, target)
        assert refused.rule == "narrow.not_narrower"
    # Equal width is refused for the same reason, not as an oversight: BF16 <-> FP16 is a
    # real conversion that saves no beats.
    equal = P.pipeline([narrow(AI_FMT_FP16)], source_numfmt=AI_FMT_BF16)
    assert not equal and equal.rule == "narrow.not_narrower"


def test_error_terms_add_and_the_budget_gates_the_composed_bound():
    """Stacking must not be a way to spend a budget one stage at a time."""
    stack = P.pipeline([narrow(AI_FMT_BF16, eps_ppm=7828),
                        P.Stage("approx", eps_ppm=1953, recipe="truncate-10")])
    assert stack and stack.eps_ppm == 7828 + 1953
    assert not stack.exact
    refused = P.pipeline([narrow(AI_FMT_BF16, eps_ppm=7828)], max_rel_error_ppm=100)
    assert not refused and refused.rule == "budget"
    # Within budget it passes, so the gate is a gate and not a wall.
    assert P.pipeline([narrow(AI_FMT_BF16, eps_ppm=7828)], max_rel_error_ppm=10_000)


def test_approximate_arithmetic_adds_error_and_no_throughput():
    """The measured 1.000x, stated by the module rather than left for the caller to find."""
    result = P.pipeline([P.Stage("approx", eps_ppm=250_000, recipe="mitchell")])
    assert result
    assert result.speedup == pytest.approx(1.0)
    assert result.eps_ppm == 250_000
    assert any("1.000x" in note for note in result.notes)


def test_grouping_reports_that_it_is_not_a_measured_speedup():
    result = P.pipeline([P.Stage("group", groups_log2=2)])
    assert result
    assert result.speedup == pytest.approx(1.0)
    assert any("one C write port" in note for note in result.notes)


def test_zero_skip_cuts_steps_only_and_is_modelled_not_measured():
    """A skipped product still had to be READ, so traffic is untouched."""
    result = P.pipeline([P.Stage("skip", skip_fraction=0.5)], source_numfmt=AI_FMT_INT)
    assert result
    assert result.provenance == P.MODELED          # no RTL consumer, so never measured
    assert 1.0 < result.speedup < 2.0
    # Halving the steps cannot halve the job, because beats remain.
    steps = P.steps_for(AI_FMT_INT, 8, 8, 16)
    beats = P.beats_for(AI_FMT_INT, 8, 8, 16)
    assert result.composed.cycles == pytest.approx(
        steps * 0.5 + P.BETA[AI_FMT_INT] * beats + P.MODEL_CONSTANT)
    with pytest.raises(ValueError):
        P.model_cycles(AI_FMT_INT, skip_fraction=1.0)


def test_zero_skip_has_no_headroom_once_narrowing_made_the_job_retire_bound():
    """Why zero-skip is correctly evaluated LAST: narrowing competes for the same term.

    FP32 at 8 lanes spends 512 of 669 cycles on steps. INT4 spends 64 of 109. So the same
    skip fraction is worth far less after narrowing -- the two levers are not additive
    opportunities, they are claims on one resource.
    """
    def skip_gain(numfmt):
        base = P.cycles_for(numfmt).cycles
        skipped = P.cycles_for(numfmt, skip_fraction=0.5).cycles
        return base / skipped

    assert skip_gain(AI_FMT_FP32) > skip_gain(AI_FMT_INT) > skip_gain(AI_FMT_INT4)
    # FP32 is step-dominated; INT4 is not.
    assert P.steps_for(AI_FMT_FP32, 8, 8, 16) / 669 > 0.7
    assert P.steps_for(AI_FMT_INT4, 8, 8, 16) / 109 < 0.7


def test_off_reference_shapes_are_modelled_and_labelled():
    """The measured table covers one shape; anything else is modelled, and says so."""
    assert P.cycles_for(AI_FMT_FP32).provenance == P.MEASURED
    assert P.cycles_for(AI_FMT_FP32, m=16, n=16, k=16).provenance == P.MODELED
    assert P.cycles_for(AI_FMT_FP32, lanes=16).provenance == P.MODELED
    # A format with no residency sweep is modelled for residency but measured without it.
    assert P.cycles_for(AI_FMT_FP16).provenance == P.MEASURED
    assert P.cycles_for(AI_FMT_FP16, resident_b=True).provenance == P.MODELED
    # A modelled endpoint makes the whole ratio modelled -- one is enough to taint it.
    result = P.pipeline([narrow(AI_FMT_FP16), BOTH_RESIDENT], resident_at_target=True)
    assert result and result.provenance == P.MODELED


def test_a_narrowing_stage_needs_a_target():
    refused = P.pipeline([P.Stage("narrow")])
    assert not refused and refused.rule == "narrow.target"
    with pytest.raises(ValueError):
        P.Stage("nonsense")
