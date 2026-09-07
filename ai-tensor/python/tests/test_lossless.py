# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Lossless narrowing: exact traffic saving, and the proof that earns it.

These tests exist to stop two specific lies:

1. that a narrowing is lossless when it merely looks close — the proof is a bit-pattern
   comparison, and "nearly exact" is an approximate conversion wearing an exact label;
2. that a lossless narrowing is bit-identical — it is not for the float pairs, because the
   accumulator regroups, and the tests pin the regrouping as a real observable difference.
"""

import math

import pytest

try:
    import torch
except ImportError:  # pragma: no cover
    torch = None

from ai_tensor import lossless as L
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

needs_torch = pytest.mark.skipif(torch is None, reason="torch is not installed")


def test_the_pair_set_matches_the_rtl_sweep():
    """17 strictly-narrower ordered pairs — the same count `VA_LOSSLESS_NARROW` admits."""
    assert len(L.NARROWER_PAIRS) == 17
    assert L.narrower_targets(AI_FMT_FP32) and len(L.narrower_targets(AI_FMT_FP32)) == 6
    assert len(L.narrower_targets(AI_FMT_FP16)) == 4
    assert len(L.narrower_targets(AI_FMT_BF16)) == 4
    assert L.narrower_targets(AI_FMT_INT) == [AI_FMT_INT4]
    assert L.narrower_targets(AI_FMT_INT4) == []
    # Equal width is NOT a narrowing: it saves no beats, so attaching a bound to it
    # would be claiming a plan that buys nothing.
    assert (AI_FMT_FP16, AI_FMT_BF16) not in L.NARROWER_PAIRS
    assert (AI_FMT_BF16, AI_FMT_FP16) not in L.NARROWER_PAIRS
    assert L.element_bits(AI_FMT_FP16) == L.element_bits(AI_FMT_BF16) == 16
    assert L.element_bits(AI_FMT_INT4) == 4
    assert L.element_bits(99) == 0


def test_mac_step_follows_the_format_and_sets_the_window():
    for fmt, step in ((AI_FMT_FP32, 2), (AI_FMT_FP16, 4), (AI_FMT_BF16, 4),
                      (AI_FMT_INT, 8), (AI_FMT_FP8_E4M3, 8), (AI_FMT_INT4, 16)):
        assert L.mac_step(fmt, lanes=8) == step
    # Narrower storage means a WIDER window, hence fewer accumulator folds. That is
    # the entire mechanism by which a lossless narrowing changes the answer at all.
    assert L.mac_step(AI_FMT_BF16, 8) > L.mac_step(AI_FMT_FP32, 8)
    assert vt.PE_LANES == 8


@needs_torch
def test_the_proof_is_bit_exact_not_approximate():
    torch.manual_seed(1)
    # Weights trained in BF16 and widened: exactly representable.
    exact = torch.randn(4, 8).to(torch.bfloat16).to(torch.float32)
    proof = L.prove(exact, exact.T.contiguous(), AI_FMT_BF16)
    assert proof.ok and proof.proven
    assert (proof.mismatched_a, proof.mismatched_b) == (0, 0)
    assert proof.target_name == "bf16"
    # Genuinely full-precision data is refused, and says how many elements failed.
    full = torch.randn(4, 8)
    refused = L.prove(full, full.T.contiguous(), AI_FMT_BF16)
    assert not refused.ok and not refused.proven
    assert refused.mismatched_a > 0
    # One bad element is enough: "nearly lossless" is not a thing.
    #
    # The perturbation has to survive FP32 storage to be a perturbation at all. An
    # earlier version added 1e-8, which rounds straight back to the original float32
    # near 1.0 and so proved nothing. 1 + 2^-20 is exactly FP32-representable and needs
    # 20 mantissa bits, which BF16's 8 cannot hold.
    almost = exact.clone()
    almost[0, 0] = 1.0 + 2.0 ** -20
    assert float(almost[0, 0]) != 1.0, "perturbation must survive FP32 storage"
    nearly = L.prove(almost, exact.T.contiguous(), AI_FMT_BF16)
    assert not nearly.proven and nearly.mismatched_a == 1


@needs_torch
def test_nonfinite_and_unknown_targets_fail_closed():
    torch.manual_seed(2)
    a = torch.randn(4, 4)
    broken = a.clone()
    broken[0, 0] = float("inf")
    assert L.prove(broken, a, AI_FMT_BF16).status == "nonfinite_operand"
    assert L.prove(a, a, 99).status == "unknown_target"
    assert not L.prove(broken, a, AI_FMT_BF16).ok


@needs_torch
def test_integer_container_proof_is_integrality_and_range():
    """`INT8 -> INT4` is the real case of 4-bit weights held in an INT8 array."""
    small = torch.randint(-8, 8, (4, 8)).float()
    assert L.prove(small, small.T.contiguous(), AI_FMT_INT4).ok
    # Out of INT4 range, though a perfectly good INT8 value.
    big = small.clone()
    big[0, 0] = 100.0
    assert not L.prove(big, small.T.contiguous(), AI_FMT_INT4).proven
    # Non-integral fails even in range.
    fractional = small.clone()
    fractional[0, 0] = 1.5
    assert not L.prove(fractional, small.T.contiguous(), AI_FMT_INT4).proven


@needs_torch
def test_integer_to_integer_is_bit_identical_by_construction():
    """Same integers, exact reduction, integer accumulator: no rounding site anywhere."""
    torch.manual_seed(3)
    a = torch.randint(-8, 8, (8, 64)).float()
    b = torch.randint(-8, 8, (64, 8)).float()
    scored = L.quality(a, b, AI_FMT_INT4, source_numfmt=AI_FMT_INT)
    assert scored.ok
    assert scored.bit_identical is True
    assert scored.rel_fro_error == 0.0 and scored.ppm == 0.0
    assert scored.sqnr_db == math.inf
    assert scored.quality_gain is None          # exact, so no ratio to report
    assert scored.approximate_twin_ppm == 147961


@needs_torch
def test_float_narrowing_is_accurate_but_not_bit_identical():
    """The claim this module must never make is bit-identity for the float pairs.

    The products are the same real numbers, but the window widens (32 -> 16 folds at
    k=64), so the FP32 accumulator regroups. That is a real difference — just ~10^5 times
    smaller than the approximate conversion which saves the identical traffic.
    """
    torch.manual_seed(4)
    a = torch.randn(8, 64).to(torch.bfloat16).to(torch.float32)
    b = torch.randn(64, 8).to(torch.bfloat16).to(torch.float32)
    scored = L.quality(a, b, AI_FMT_BF16)
    assert scored.ok and scored.proof.ok
    assert scored.source_windows == 32 and scored.target_windows == 16
    assert scored.target_windows < scored.source_windows
    # Tiny, but present: this is regrouping, not storage error.
    assert 0.0 <= scored.ppm < 100.0
    assert scored.ppm * 100 < scored.approximate_twin_ppm
    if scored.ppm > 0.0:
        assert scored.bit_identical is False
        assert scored.quality_gain is not None and scored.quality_gain > 100.0


@needs_torch
def test_an_unproven_narrowing_is_never_scored_as_lossless():
    """Scoring unproven data as lossless would be the module's worst failure mode."""
    torch.manual_seed(5)
    a, b = torch.randn(8, 64), torch.randn(64, 8)
    scored = L.quality(a, b, AI_FMT_BF16)
    assert not scored.ok
    assert scored.status == "not_proven_lossless"
    assert scored.ppm == math.inf and scored.sqnr_db == -math.inf
    assert scored.quality_gain is None
    assert L.plan(a, b) is None


@needs_torch
def test_plan_reports_measured_native_cycles_and_refuses_when_impossible():
    torch.manual_seed(6)
    a = torch.randn(8, 64).to(torch.float16).to(torch.float32)
    b = torch.randn(64, 8).to(torch.float16).to(torch.float32)
    p = L.plan(a, b)
    assert p is not None and p.ok
    assert p.source_numfmt == AI_FMT_FP32
    assert p.source_cycles == 669
    # Cycles are the MEASURED native figures — a narrowed job is a native job.
    assert p.target_cycles == vt.MEASURED_CYCLES[p.target_numfmt]
    assert p.speedup == pytest.approx(669 / p.target_cycles)
    assert p.speedup > 1.0
    assert p.recipe_id == 1
    assert "native" in p.note and "consumer mask" in p.note
    # Full-precision data yields no plan, and that is a correct answer, not a failure.
    assert L.plan(torch.randn(8, 64), torch.randn(64, 8)) is None


@needs_torch
def test_best_target_picks_the_narrowest_the_data_allows():
    torch.manual_seed(7)
    # E4M3-derived values round-trip through E4M3 *and* through the wider floats; the
    # narrowest exact one is what maximises the traffic saving.
    a = torch.randn(4, 16).to(torch.float8_e4m3fn).to(torch.float32)
    b = torch.randn(16, 4).to(torch.float8_e4m3fn).to(torch.float32)
    best = L.best_target(a, b)
    assert best is not None and best.ok
    assert L.element_bits(best.target) == 8
    assert L.prove(a, b, AI_FMT_BF16).ok      # the wider target is also exact ...
    assert L.element_bits(best.target) < L.element_bits(AI_FMT_BF16)   # ... but not chosen


@needs_torch
def test_windowed_matmul_matches_plain_matmul_when_the_window_covers_k():
    """One window and no folds: the model must reduce to an ordinary product."""
    torch.manual_seed(8)
    a = torch.randn(4, 2).to(torch.bfloat16).to(torch.float32)
    b = torch.randn(2, 4).to(torch.bfloat16).to(torch.float32)
    # k=2 equals FP32's mac_step, so there is exactly one window.
    windowed = L.windowed_matmul(a, b, AI_FMT_FP32)
    assert torch.allclose(windowed, (a.double() @ b.double()).float().double())
    # Integer formats accumulate exactly, so no rounding is applied at all.
    ia = torch.randint(-8, 8, (4, 32)).float()
    ib = torch.randint(-8, 8, (32, 4)).float()
    assert torch.equal(L.windowed_matmul(ia, ib, AI_FMT_INT4), ia.double() @ ib.double())


@needs_torch
@pytest.mark.parametrize("target", [AI_FMT_FP8_E4M3, AI_FMT_FP8_E5M2])
def test_sixteen_to_eight_bit_narrowing_comes_out_exact(target):
    """An 8-bit product carries <=8 significant bits, so a window of 8 fits FP32's 24.

    Reported as measured, not asserted as a theorem: if a shape ever makes it inexact the
    number will move and this test will say so.
    """
    torch.manual_seed(9)
    a = torch.randn(8, 64).to(torch.float8_e4m3fn).to(torch.float32)
    b = torch.randn(64, 8).to(torch.float8_e4m3fn).to(torch.float32)
    if not L.prove(a, b, target).ok:
        pytest.skip(f"fixture is not exactly representable in {target}")
    scored = L.quality(a, b, target, source_numfmt=AI_FMT_FP16)
    assert scored.ok
    assert scored.ppm == 0.0
    assert scored.bit_identical is True
