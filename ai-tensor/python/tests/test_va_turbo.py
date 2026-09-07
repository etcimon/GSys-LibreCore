# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""V/A-Turbo throughput-vs-quality selection: the two axes, and the honesty gate.

These tests pin three things that rot silently if nothing watches them:

1. **Provenance.** A measured cycle count and one inferred from equal operand traffic must
   stay distinguishable, and the inference flag must survive into the returned plan. The
   moment those merge, an invented number becomes a quoted number.
2. **The ladder.** ``error_budget_level`` / ``budget_ppm`` must match
   ``g6lc_ai_policy_pkg::va_turbo_budget_ppm`` exactly, because a Python-side budget is only
   meaningful if it is the RTL's own encoding.
3. **The hardware gate.** ``executable_on_hardware`` must be False for every approximate
   recipe. The island has no approximate execution consumer; a test that let this drift to
   True would let the API imply a capability that does not exist.

Torch-dependent cases skip cleanly when torch is absent; the cycle model, the catalog and
the ladder are checked with no ML stack at all.
"""

from __future__ import annotations

import importlib.util
import math
import sys
from pathlib import Path
from unittest import mock

import pytest

from ai_tensor import va_turbo as vt
from ai_tensor.c_abi import (
    AI_FMT_BF16,
    AI_FMT_FP8_E4M3,
    AI_FMT_FP8_E5M2,
    AI_FMT_FP16,
    AI_FMT_FP32,
    AI_FMT_INT,
    AI_FMT_INT4,
)

torch = pytest.importorskip("torch", reason="quality axis needs torch") if vt.HAVE_TORCH else None
needs_torch = pytest.mark.skipif(not vt.HAVE_TORCH, reason="requires PyTorch")


@pytest.fixture(scope="module")
def fixture_tensors():
    """A well-conditioned FP32 pair: no cancellation pathology, real dynamic range.

    Fixed seed, so the quality ordering assertions below are reproducible rather than
    resampled until they pass.
    """
    torch.manual_seed(1234)
    return torch.randn(32, 64), torch.randn(64, 32)


# ------------------------------------------------------------------ the geometric ladder


def test_ladder_starts_at_one_hundred_ppm_and_doubles():
    assert vt.budget_ppm(0) == 0, "level 0 is off, not 'a tiny budget'"
    assert vt.budget_ppm(1) == 100
    for level in range(2, 15):
        assert vt.budget_ppm(level) == 2 * vt.budget_ppm(level - 1)
    # The two anchors va-turbo.md §2.2 quotes.
    assert vt.budget_ppm(5) == 1_600
    assert vt.budget_ppm(8) == 12_800


def test_level_fifteen_saturates_at_one_hundred_percent():
    """100 << 14 is 1,638,400; the ladder must clamp, not report a >100% budget."""
    assert vt.budget_ppm(14) == 819_200
    assert vt.budget_ppm(15) == vt.LADDER_MAX_PPM == 1_000_000


@pytest.mark.parametrize("level", range(0, 16))
def test_level_and_budget_round_trip(level):
    assert vt.error_budget_level(vt.budget_ppm(level)) == level


def test_level_rounds_the_budget_up():
    """`error_bound_q4` is rounded UP, so a bound is never admitted by a rounding artefact."""
    assert vt.error_budget_level(1) == 1
    assert vt.error_budget_level(100) == 1
    assert vt.error_budget_level(101) == 2
    assert vt.error_budget_level(819_201) == 15


@pytest.mark.parametrize("bad", [-1, 16, 100, 1.5, True, "3"])
def test_budget_ppm_fails_closed_outside_the_four_bit_field(bad):
    with pytest.raises(ValueError):
        vt.budget_ppm(bad)


@pytest.mark.parametrize("bad", [-1.0, 1_000_000.5, math.inf, math.nan, "1000", True])
def test_error_budget_level_fails_closed(bad):
    """An inexpressible bound must raise, never saturate into level 15.

    Saturating would turn "I cannot express this" into "admitted at 100%", which is exactly
    the defect va-turbo.md §9 records and withdraws.
    """
    with pytest.raises(ValueError):
        vt.error_budget_level(bad)


# ------------------------------------------------------------------------- provenance


def test_measured_cycle_table_is_the_recorded_run():
    """All seven formats are measured, and none is inferred.

    BF16 and FP8 E5M2 were briefly carried as inferred; re-reading the cited log showed the
    harness exercises and fully checks all seven at this shape (`signed=1`, so every C
    element is verified), so both were promoted. A derived number must not outlive the
    measurement that replaces it.
    """
    assert vt.MEASURED_CYCLES == {
        AI_FMT_INT: 189,
        AI_FMT_INT4: 109,
        AI_FMT_FP8_E4M3: 189,
        AI_FMT_FP8_E5M2: 189,
        AI_FMT_FP16: 349,
        AI_FMT_BF16: 349,
        AI_FMT_FP32: 669,
    }
    assert vt.INFERRED_TRAFFIC_TWIN == {}
    assert vt.BASELINE_CYCLES == 669
    assert "g6lc_ai_gemm_seq" in vt.CYCLE_PROVENANCE_NOTE
    assert "not silicon" in vt.CYCLE_PROVENANCE_NOTE.lower()


@pytest.mark.parametrize(
    "recipe",
    [
        "native-fp32",
        "convert-fp16",
        "convert-int8",
        "convert-int4",
        "convert-fp8-e4m3",
        "convert-bf16",
        "convert-fp8-e5m2",
    ],
)
def test_every_format_is_measured_not_inferred(recipe):
    est = vt.cycles(recipe)
    assert est.provenance == vt.MEASURED
    assert est.inferred is False
    assert est.inferred_from is None


def test_e4m3_and_e5m2_agree_in_cycles_because_traffic_is_equal():
    """Equal operand traffic gives equal cycles — now measured on both, not inferred.

    This is the observation that justified the inference rule in the first place, so it is
    worth keeping as a check on the rule even though neither side needs it any more.
    """
    e4m3 = vt.cycles("convert-fp8-e4m3")
    e5m2 = vt.cycles("convert-fp8-e5m2")
    assert e4m3.cycles == e5m2.cycles == 189
    assert e4m3.provenance == e5m2.provenance == vt.MEASURED
    assert vt.cycles("convert-fp16").cycles == vt.cycles("convert-bf16").cycles == 349


def test_the_inference_mechanism_still_works_when_a_format_is_unmeasured(monkeypatch):
    """The inference path is currently unused, so it is tested by injection.

    A later shape, lane count or memory class will leave some format unmeasured, and this is
    the machinery that must then flag it instead of inventing a measured-looking number.
    """
    monkeypatch.setitem(vt.INFERRED_TRAFFIC_TWIN, AI_FMT_BF16, AI_FMT_FP16)
    monkeypatch.delitem(vt.MEASURED_CYCLES, AI_FMT_BF16)
    est = vt.cycles("convert-bf16")
    assert est.provenance == vt.INFERRED_FROM_K_BYTES
    assert est.inferred is True
    assert est.inferred_from == "fp16"
    assert est.cycles == 349
    # And the flag has to reach the caller, not stop at the estimate.
    assert vt.speedup("convert-bf16").inferred_from_k_bytes is True
    assert vt.speedup("convert-fp16").inferred_from_k_bytes is False


def test_no_speedup_is_flagged_inferred_today():
    for name in vt.RECIPES:
        est = vt.cycles(name)
        if est.cycles is not None:
            assert vt.speedup(name).inferred_from_k_bytes is False


@needs_torch
def test_provenance_survives_into_plans(fixture_tensors):
    a, b = fixture_tensors
    by_name = {p.name: p for p in vt.plans(a, b)}
    assert by_name["convert-bf16"].inferred_from_k_bytes is False
    assert by_name["convert-bf16"].as_dict()["inferred_from_k_bytes"] is False
    assert by_name["convert-fp8-e4m3"].inferred_from_k_bytes is False


def test_unmeasured_residency_is_unavailable_not_interpolated():
    """FP16 residency was never swept. The answer is 'no data', not a plausible number."""
    est = vt.cycles("convert-fp16", "both")
    assert est.cycles is None
    assert est.provenance == vt.UNAVAILABLE
    assert vt.speedup("convert-fp16", "both").cycle_speedup is None
    assert vt.residency_speedup("convert-fp16", "both") is None


# ------------------------------------------------------------------- the throughput axis


def test_native_fp32_is_the_baseline_exactly():
    sp = vt.speedup("native-fp32")
    assert sp.cycles == 669
    assert sp.cycle_speedup == 1.0
    assert sp.traffic_speedup == 1.0


@pytest.mark.parametrize(
    "recipe,cycles_,cycle_x,traffic_x",
    [
        ("convert-fp16", 349, 669 / 349, 2.0),
        ("convert-int8", 189, 669 / 189, 4.0),
        ("convert-int4", 109, 669 / 109, 8.0),
    ],
)
def test_cycle_speedup_and_traffic_model_are_reported_separately(recipe, cycles_, cycle_x, traffic_x):
    """The two estimates disagree, and that disagreement is the point.

    The traffic model sees only k_bytes; the measured cycles also carry the fixed per-job
    transaction cost and the one-element-per-cycle retire bound. INT4's model says 8x and the
    measurement says 6.14x. Silently reporting either as the other would fabricate evidence.
    """
    sp = vt.speedup(recipe)
    assert sp.cycles == cycles_
    assert sp.cycle_speedup == pytest.approx(cycle_x)
    assert sp.traffic_speedup == pytest.approx(traffic_x)
    assert sp.cycle_speedup < sp.traffic_speedup
    assert sp.traffic_provenance == "model_from_k_bytes"


@pytest.mark.parametrize(
    "recipe,residency,expected",
    [
        ("convert-int8", "none", 189),
        ("convert-int8", "a", 164),
        ("convert-int8", "b", 164),
        ("convert-int8", "both", 139),
        ("native-fp32", "none", 669),
        ("native-fp32", "a", 596),
        ("native-fp32", "b", 596),
        ("native-fp32", "both", 523),
    ],
)
def test_residency_matrix_matches_the_measured_dual_lines(recipe, residency, expected):
    assert vt.cycles(recipe, residency).cycles == expected


def test_residency_speedups_match_the_published_figures():
    """va-turbo.md §10 / the DUAL `speedup_x1000` fields, which are truncated to 3 decimals."""
    assert vt.residency_speedup("convert-int8", "a") == pytest.approx(1.152, abs=1e-3)
    assert vt.residency_speedup("convert-int8", "b") == pytest.approx(1.152, abs=1e-3)
    assert vt.residency_speedup("convert-int8", "both") == pytest.approx(1.359, abs=1e-3)
    assert vt.residency_speedup("native-fp32", "a") == pytest.approx(1.122, abs=1e-3)
    assert vt.residency_speedup("native-fp32", "both") == pytest.approx(1.279, abs=1e-3)


def test_resident_recipe_defaults_to_both_and_is_recipe_sixteen():
    rec = vt.RECIPES["resident-ab-fp32"]
    assert rec.id == vt.RESIDENCY_RECIPE_ID == 16
    assert rec.exact is True
    assert vt.speedup(rec).cycles == 523
    # An explicit residency still wins over the default.
    assert vt.speedup(rec, "none").cycles == 669


def test_an_unknown_residency_or_recipe_is_refused():
    with pytest.raises(ValueError):
        vt.cycles("native-fp32", "sometimes")
    with pytest.raises(ValueError):
        vt.speedup("convert-fp6")


# ------------------------------------------------------------------------ the recipe map


def test_recipe_ids_track_the_rtl_namespace():
    assert vt.RECIPES["native-fp32"].id == 0
    assert vt.RECIPES["resident-ab-fp32"].id == 16
    assert {vt.RECIPES[n].id for n in ("convert-fp16", "convert-bf16", "convert-int8",
                                       "quantise-int8-in-place")} == {18, 19, 20}
    assert vt.RECIPES["truncate-mantissa-10"].id == 21
    assert vt.RECIPES["truncate-mantissa-10"].mantissa_bits == 10
    assert vt.RECIPES["mitchell"].id == 27


def test_an_uncertain_id_is_left_none_with_the_reason():
    """FP8 E5M2 has no slot in va_turbo_arith; guessing one would be a fabricated mapping."""
    rec = vt.RECIPES["convert-fp8-e5m2"]
    assert rec.id is None
    assert "UNCERTAIN" in rec.id_note


def test_int4_storage_is_half_a_byte_not_rounded_up():
    assert vt.RECIPES["convert-int4"].k_bytes_per_element == 0.5
    assert vt.RECIPES["convert-int8"].k_bytes_per_element == 1.0


def test_in_place_quantisation_buys_no_traffic():
    """Recipe 19 pays INT8's error at FP32's traffic: the axes really are independent."""
    rec = vt.RECIPES["quantise-int8-in-place"]
    assert rec.numfmt == AI_FMT_FP32
    sp = vt.speedup(rec)
    assert sp.cycle_speedup == 1.0 and sp.traffic_speedup == 1.0
    assert rec.exact is False


# --------------------------------------------------------------------- the honesty gate


@needs_torch
def test_every_approximate_recipe_is_not_executable(fixture_tensors):
    a, b = fixture_tensors
    for plan in vt.plans(a, b):
        if plan.recipe.exact:
            assert plan.executable_on_hardware is True, plan.name
            assert plan.hardware_execution in (vt.EXACT_NATIVE, vt.EXACT_RESIDENCY)
        else:
            assert plan.executable_on_hardware is False, plan.name
            assert plan.hardware_execution == vt.EMULATED_ONLY
            assert "NOT EXECUTABLE" in plan.why
            assert "HOST EMULATION" in plan.why


@needs_torch
def test_the_exact_plans_state_their_own_caveat(fixture_tensors):
    a, b = fixture_tensors
    by_name = {p.name: p for p in vt.plans(a, b)}
    assert "native datapath" in by_name["native-fp32"].why
    resident = by_name["resident-ab-fp32"]
    assert resident.executable_on_hardware is True
    # True, but the caveat must travel with it: production runtime reuse is tied off.
    assert "verification harness" in resident.why
    assert "ties runtime reuse off" in resident.why


def test_only_exact_recipes_claim_hardware_execution():
    for rec in vt.RECIPES.values():
        if rec.exact:
            assert rec.hardware_execution in (vt.EXACT_NATIVE, vt.EXACT_RESIDENCY)
        else:
            assert rec.hardware_execution == vt.EMULATED_ONLY


# ---------------------------------------------------------------------- the quality axis


@needs_torch
def test_native_has_zero_error_and_unit_speedup(fixture_tensors):
    a, b = fixture_tensors
    q = vt.quality(a, b, "native-fp32")
    assert q.ok and q.rel_fro_error == 0.0 and q.ppm == 0.0
    assert q.sqnr_db == math.inf and q.cosine == pytest.approx(1.0)
    assert q.budget_level == 0
    assert vt.speedup("native-fp32").cycle_speedup == 1.0


@needs_torch
def test_residency_is_faster_and_still_exact(fixture_tensors):
    """The one place both axes improve at once, because recipe 16 changes no arithmetic."""
    a, b = fixture_tensors
    q = vt.quality(a, b, "resident-ab-fp32")
    assert q.rel_fro_error == 0.0
    assert vt.speedup("resident-ab-fp32").cycle_speedup > 1.0


@needs_torch
@pytest.mark.parametrize("recipe", ["convert-fp16", "convert-int8", "convert-int4"])
def test_narrowing_is_a_real_trade_in_both_directions(recipe, fixture_tensors):
    a, b = fixture_tensors
    sp = vt.speedup(recipe)
    q = vt.quality(a, b, recipe)
    assert sp.cycle_speedup > 1.0, "narrowing must buy throughput"
    assert q.rel_fro_error > 0.0, "…and must cost accuracy; a free lunch here is a bug"
    assert q.ok and math.isfinite(q.sqnr_db)


@needs_torch
def test_quality_is_monotone_in_aggressiveness(fixture_tensors):
    """FP16 better than FP8 E4M3 better than INT4 on a well-conditioned fixture.

    Checked on all four metrics at once so a single lucky metric cannot carry the claim.
    """
    a, b = fixture_tensors
    fp16 = vt.quality(a, b, "convert-fp16")
    fp8 = vt.quality(a, b, "convert-fp8-e4m3")
    int4 = vt.quality(a, b, "convert-int4")
    assert fp16.rel_fro_error < fp8.rel_fro_error < int4.rel_fro_error
    assert fp16.ppm < fp8.ppm < int4.ppm
    assert fp16.sqnr_db > fp8.sqnr_db > int4.sqnr_db
    assert fp16.cosine > fp8.cosine > int4.cosine
    assert fp16.max_abs_error < fp8.max_abs_error < int4.max_abs_error
    # And the ladder orders them the same way, since it is the same quantity.
    assert fp16.budget_level < fp8.budget_level < int4.budget_level


@needs_torch
def test_ppm_is_the_relative_error_on_the_ladder_scale(fixture_tensors):
    a, b = fixture_tensors
    q = vt.quality(a, b, "convert-fp16")
    assert q.ppm == pytest.approx(q.rel_fro_error * 1e6)
    assert q.budget_level == vt.error_budget_level(q.ppm)
    assert vt.budget_ppm(q.budget_level) >= q.ppm


@needs_torch
def test_emulate_is_deterministic_and_shape_dtype_correct(fixture_tensors):
    a, b = fixture_tensors
    for name in ("convert-fp16", "convert-int8", "truncate-mantissa-10", "mitchell"):
        first = vt.emulate(a, b, name)
        second = vt.emulate(a, b, name)
        assert first.shape == (a.shape[0], b.shape[1]), name
        assert first.dtype == torch.float32, name
        assert torch.equal(first, second), f"{name} is not deterministic"


@needs_torch
def test_emulate_actually_changes_the_numbers(fixture_tensors):
    """A round trip that silently returns the input would score as a perfect approximation."""
    a, b = fixture_tensors
    exact = vt.emulate(a, b, "native-fp32")
    for name in ("convert-fp16", "convert-bf16", "convert-int8", "convert-int4",
                 "truncate-mantissa-10", "mitchell"):
        assert not torch.equal(vt.emulate(a, b, name), exact), name


@needs_torch
def test_emulate_refuses_bad_operands(fixture_tensors):
    a, b = fixture_tensors
    with pytest.raises(ValueError):
        vt.emulate(a, a, "convert-fp16")          # shape mismatch
    with pytest.raises(ValueError):
        vt.emulate(a.reshape(-1), b, "convert-fp16")  # not 2-D
    with pytest.raises(TypeError):
        vt.emulate(a.to(torch.int8), b, "convert-fp16")  # quantising is the recipe's job
    with pytest.raises(TypeError):
        vt.emulate([[1.0]], b, "convert-fp16")


@needs_torch
@pytest.mark.parametrize("bad", [math.inf, -math.inf, math.nan])
def test_nonfinite_fails_closed(fixture_tensors, bad):
    """A nonfinite must never be reported as a good score, and must never win a frontier."""
    a, b = fixture_tensors
    poisoned = a.clone()
    poisoned[0, 0] = bad
    q = vt.quality(poisoned, b, "convert-fp16")
    assert not q.ok
    assert q.status is not None
    assert q.rel_fro_error == math.inf and q.sqnr_db == -math.inf
    assert q.ppm == math.inf and q.budget_level is None
    assert vt.pareto(poisoned, b) == []
    result = vt.autotune(poisoned, b, max_rel_error_ppm=1_000_000)
    assert isinstance(result, vt.NoCandidate)


@needs_torch
def test_quality_of_a_zero_reference_is_not_called_perfect():
    zeros = torch.zeros(4, 4)
    q = vt.quality(zeros, zeros, "convert-int8")
    assert q.rel_fro_error == 0.0 and q.ok, "0 == 0 is genuinely exact"
    ones = torch.ones(4, 4)
    q2 = vt.quality(ones, -ones + ones, "convert-fp16")  # reference is all zeros
    assert q2.ok and q2.rel_fro_error == 0.0


# ------------------------------------------------------------------- frontier / autotune


@needs_torch
def test_pareto_is_non_dominated_and_sorted(fixture_tensors):
    a, b = fixture_tensors
    front = vt.pareto(a, b)
    assert front, "a nonempty catalog must produce a nonempty frontier"
    speeds = [p.cycle_speedup for p in front]
    errors = [p.quality.rel_fro_error for p in front]
    assert speeds == sorted(speeds, reverse=True)
    # Non-domination on a frontier sorted by descending speed means the error must fall in
    # lockstep: if a slower plan were also less accurate, it would be dominated.
    assert errors == sorted(errors, reverse=True)
    assert len(set(speeds)) == len(speeds)
    # The dominated in-place quantiser (INT8 error at FP32 traffic) must not survive.
    assert "quantise-int8-in-place" not in {p.name for p in front}


@needs_torch
def test_autotune_respects_a_ppm_budget(fixture_tensors):
    a, b = fixture_tensors
    plan = vt.autotune(a, b, max_rel_error_ppm=5_000)
    assert isinstance(plan, vt.Plan)
    assert plan.quality.ppm <= 5_000
    assert plan.name == "convert-fp16"
    # Loosening the budget must not make it slower.
    looser = vt.autotune(a, b, max_rel_error_ppm=50_000)
    assert looser.cycle_speedup >= plan.cycle_speedup


@needs_torch
def test_autotune_respects_an_sqnr_floor(fixture_tensors):
    a, b = fixture_tensors
    plan = vt.autotune(a, b, min_sqnr_db=35.0)
    assert isinstance(plan, vt.Plan)
    assert plan.quality.sqnr_db >= 35.0
    assert plan.name == "convert-int8"


@needs_torch
def test_autotune_respects_a_speedup_floor(fixture_tensors):
    a, b = fixture_tensors
    plan = vt.autotune(a, b, min_speedup=3.0, max_rel_error_ppm=20_000)
    assert isinstance(plan, vt.Plan)
    assert plan.cycle_speedup >= 3.0 and plan.quality.ppm <= 20_000
    assert plan.name == "convert-int8"


@needs_torch
def test_a_speedup_floor_alone_maximises_quality_not_speed(fixture_tensors):
    """Which axis is optimised follows which axis was CONSTRAINED.

    ``min_speedup`` alone leaves accuracy free, so the answer must be the most accurate
    recipe that clears the bar. Maximising speed here would return INT4 at ~190,000 ppm when
    INT8 at ~9,000 ppm also cleared 3x — spending accuracy the caller never offered. Both
    are ``>= 3x``, so only the objective distinguishes them.
    """
    a, b = fixture_tensors
    plan = vt.autotune(a, b, min_speedup=3.0)
    assert isinstance(plan, vt.Plan)
    assert plan.name == "convert-int8"
    assert plan.cycle_speedup >= 3.0
    int4 = {p.name: p for p in vt.plans(a, b)}["convert-int4"]
    assert int4.cycle_speedup > plan.cycle_speedup       # INT4 was faster ...
    assert int4.quality.ppm > plan.quality.ppm           # ... and was not chosen.
    # A floor only INT4 can reach still selects INT4: the constraint binds first.
    assert vt.autotune(a, b, min_speedup=6.0).name == "convert-int4"
    # A gentle floor picks the most accurate recipe above it, not the fastest.
    assert vt.autotune(a, b, min_speedup=1.5).name == "convert-fp16"
    # Adding an explicit quality floor hands the objective back to speed. Asserted as a
    # property rather than a name: which recipe wins depends on where the fixture's errors
    # fall relative to the floor, and pinning a name here would only test the fixture.
    both = vt.autotune(a, b, min_speedup=3.0, max_rel_error_ppm=200_000)
    eligible = [p for p in vt.plans(a, b)
                if p.cycle_speedup is not None and p.quality is not None and p.quality.ok
                and p.cycle_speedup >= 3.0 and p.quality.ppm <= 200_000]
    assert both.cycle_speedup == max(p.cycle_speedup for p in eligible)
    # Whereas the speedup-only form maximises the other axis over its own eligible set.
    speed_only = [p for p in vt.plans(a, b)
                  if p.cycle_speedup is not None and p.quality is not None and p.quality.ok
                  and p.cycle_speedup >= 3.0]
    assert plan.quality.ppm == min(p.quality.ppm for p in speed_only)


@needs_torch
def test_autotune_combines_constraints(fixture_tensors):
    a, b = fixture_tensors
    plan = vt.autotune(a, b, min_speedup=1.5, min_sqnr_db=60.0)
    assert isinstance(plan, vt.Plan)
    assert plan.name == "convert-fp16"


@needs_torch
def test_an_impossible_budget_returns_no_candidate_not_an_exception(fixture_tensors):
    """No exception, and above all no silent downgrade to native.

    Native would satisfy the accuracy half of this request perfectly, which is exactly why
    returning it here would be a wrong answer dressed as a right one.
    """
    a, b = fixture_tensors
    result = vt.autotune(a, b, max_rel_error_ppm=1, min_speedup=2.0)
    assert isinstance(result, vt.NoCandidate)
    assert not result
    assert result.executable_on_hardware is False
    assert result.constraints["max_rel_error_ppm"] == 1
    assert result.rejected, "the reason each candidate lost must be reported"
    names = {name for name, _ in result.rejected}
    assert "native-fp32" in names and "convert-int4" in names


@needs_torch
def test_autotune_without_a_constraint_is_a_programming_error(fixture_tensors):
    a, b = fixture_tensors
    with pytest.raises(ValueError):
        vt.autotune(a, b)


@needs_torch
def test_a_selected_approximate_plan_still_says_it_cannot_run(fixture_tensors):
    a, b = fixture_tensors
    plan = vt.autotune(a, b, min_speedup=2.0)
    assert isinstance(plan, vt.Plan)
    assert plan.recipe.approximate
    assert plan.executable_on_hardware is False
    assert plan.as_dict()["executable_on_hardware"] is False


@needs_torch
def test_autotune_skips_recipes_with_no_cycle_data(fixture_tensors):
    """At residency=both only INT8 and FP32 have measurements; the rest are excluded, loudly."""
    a, b = fixture_tensors
    result = vt.autotune(a, b, min_speedup=4.0, residency="both")
    assert isinstance(result, vt.Plan)
    assert result.name == "convert-int8" and result.residency == "both"
    assert result.cycle_speedup == pytest.approx(669 / 139)
    rejections = vt.autotune(a, b, min_speedup=99.0, residency="both").rejected
    assert any("no cycle data" in why for _, why in rejections)


# ------------------------------------------------------------------------ no-torch path


def test_module_imports_and_works_without_torch():
    """The cycle model, the catalog and the ladder must not need an ML stack.

    Loaded as a separate module object with `torch` blocked, so the rest of the session keeps
    the real one.
    """
    name = "ai_tensor._va_turbo_no_torch_probe"
    spec = importlib.util.spec_from_file_location(name, Path(vt.__file__))
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, {"torch": None, name: module}):
        spec.loader.exec_module(module)
    assert module.HAVE_TORCH is False
    assert module.budget_ppm(8) == 12_800
    assert module.error_budget_level(12_800) == 8
    assert module.speedup("convert-int4").cycle_speedup == pytest.approx(669 / 109)
    assert module.cycles("convert-bf16").provenance == module.MEASURED
    assert len(module.RECIPES) == len(vt.RECIPES)
    with pytest.raises(ImportError):
        module.emulate(None, None, "convert-fp16")
    with pytest.raises(ImportError):
        module.quality(None, None, "convert-fp16")
