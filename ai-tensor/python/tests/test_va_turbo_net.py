# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""End-to-end error propagation through a real architecture.

`test_va_turbo.py` scores a recipe on ONE matmul. That cannot answer the question a network
actually poses: does per-tile error COMPOUND across layers, or wash out? These tests pin the
answer and the properties it rests on.

The measured answer is that error grows as roughly `depth**0.21` (R^2 0.95-0.99), i.e. 12x the
depth costs about 1.7x the error, so a single-tile figure is a conservative proxy rather than
a per-layer tax. That is a claim about ERROR PROPAGATION THROUGH A REAL ARCHITECTURE with
random weights, not about a trained model's accuracy.
"""

import math

import pytest

try:
    import torch
except ImportError:  # pragma: no cover - torch is optional for this package
    torch = None

from ai_tensor import va_turbo as vt
from ai_tensor import va_turbo_net as net

needs_torch = pytest.mark.skipif(torch is None, reason="torch is not installed")

#: Small enough to keep the suite quick, deep enough for propagation to be visible.
SMALL = dict(d_model=32, n_heads=2, d_ff=64, seq_len=8, batch=2, n_classes=16)


def config(**kw):
    merged = dict(SMALL)
    merged.update(kw)
    return net.NetConfig(**merged)


@needs_torch
def test_the_reference_run_is_ordinary_fp32_torch():
    """The baseline must be plain torch, or every error below is measured against a fiction."""
    cfg = config(depth=2)
    reference = net.reference_run(cfg)
    native = net.run(cfg, "native-fp32")
    assert torch.equal(native.logits, reference.logits)
    assert len(reference.hidden_per_depth) == cfg.depth
    assert len(reference.logits_per_depth) == cfg.depth


@needs_torch
def test_native_is_exactly_zero_error_and_perfect_agreement():
    report = net.evaluate("native-fp32", config(depth=4))
    final = report.final
    assert final.tensor.ok
    assert final.tensor.rel_fro_error == 0.0 and final.tensor.ppm == 0.0
    assert final.tensor.sqnr_db == math.inf
    assert final.top1_agreement == 1.0
    assert final.kl_nats == 0.0
    assert len(report.per_layer) == 4


@needs_torch
def test_determinism_under_a_fixed_seed():
    cfg = config(depth=3)
    first = net.evaluate("convert-int8", cfg).final
    second = net.evaluate("convert-int8", cfg).final
    assert first.tensor.rel_fro_error == second.tensor.rel_fro_error
    assert first.top1_agreement == second.top1_agreement
    # A different seed is a different network, so it must NOT be bit-identical.
    other = net.evaluate("convert-int8", config(depth=3, seed=99)).final
    assert other.tensor.rel_fro_error != first.tensor.rel_fro_error


@needs_torch
@pytest.mark.parametrize("depth", [1, 2, 4])
def test_error_is_monotone_in_aggressiveness_at_fixed_depth(depth):
    """FP16 < BF16 < INT8 < INT4 end to end, at a fixed depth.

    If a coarser format ever scored better here it would mean the emulation, not the format,
    was deciding the ranking.
    """
    cfg = config(depth=depth)
    ladder = ["convert-fp16", "convert-bf16", "convert-int8", "convert-int4"]
    errors = [net.evaluate(name, cfg).final.tensor.rel_fro_error for name in ladder]
    assert errors == sorted(errors), dict(zip(ladder, errors))
    assert errors[0] > 0.0


@needs_torch
def test_top1_agreement_degrades_with_aggressiveness():
    """The metric a user actually cares about: did the decision change?

    Relative error can look alarming while every decision survives, which is why agreement is
    reported next to it rather than derived from it.
    """
    cfg = config(depth=4)
    fp16 = net.evaluate("convert-fp16", cfg).final
    int4 = net.evaluate("convert-int4", cfg).final
    assert fp16.top1_agreement >= int4.top1_agreement
    assert fp16.kl_nats <= int4.kl_nats
    assert 0.0 <= int4.top1_agreement <= 1.0


@needs_torch
def test_per_layer_capture_has_one_entry_per_layer_and_grows():
    report = net.evaluate("convert-int8", config(depth=6))
    assert len(report.per_layer) == 6
    depths = [q.depth for q in report.per_layer]
    assert depths == sorted(depths) and depths[0] == 1 and depths[-1] == 6
    errors = [q.tensor.rel_fro_error for q in report.per_layer]
    assert all(math.isfinite(e) for e in errors)
    # Deeper hidden states carry at least as much accumulated error as the first layer.
    assert errors[-1] >= errors[0]


@needs_torch
def test_error_grows_sub_linearly_in_depth():
    """The compounding question, answered with a number rather than an adjective.

    A per-layer multiplicative tax would give an exponent near or above 1. The measurement is
    ~0.2, so error accumulates far more slowly than depth — which is why a single-tile bound
    is a usable proxy for a deep stack.
    """
    sweep = net.depth_sweep("convert-int8", depths=(1, 2, 4, 8), config=config())
    assert sweep.monotone_in_depth
    assert sweep.growth == "sub-linear"
    assert sweep.growth_exponent is not None and 0.0 < sweep.growth_exponent < 1.0
    assert sweep.growth_r2 is not None and sweep.growth_r2 > 0.8
    # 8x the depth must cost much less than 8x the error.
    assert 1.0 <= sweep.ratio_first_last < 8.0


@needs_torch
def test_the_sweep_table_reports_random_weights_prominently():
    sweeps = net.sweep_table(("convert-fp16", "convert-int8"), depths=(1, 2), config=config())
    text = net.render_depth_table(sweeps)
    assert "convert-fp16" in text and "convert-int8" in text
    assert "RANDOM WEIGHTS" in text
    assert "not a trained checkpoint" in text or "not model accuracy" in text
    for sweep in sweeps.values():
        assert len(sweep.points) == 2


@needs_torch
def test_nonfinite_fails_closed_like_the_tile_metric():
    cfg = config(depth=1)
    reference = net.reference_run(cfg).logits
    broken = reference.clone()
    broken[0, 0] = float("nan")
    scored = vt.score_against_reference(broken, reference, "broken")
    assert not scored.ok
    assert scored.rel_fro_error == math.inf and scored.sqnr_db == -math.inf


@needs_torch
def test_the_report_carries_the_same_execution_verdict_as_a_plan():
    """One vocabulary: the net layer must not invent a second capability story."""
    report = net.evaluate("convert-int8", config(depth=1))
    assert report.hardware_execution == vt.NATIVE_NARROWED
    assert report.executable_on_hardware is True
    arithmetic = net.evaluate("mitchell", config(depth=1))
    assert arithmetic.hardware_execution == vt.NEEDS_RTL_CONSUMER
    assert arithmetic.executable_on_hardware is False
    assert "accumulate" in report.accumulation
