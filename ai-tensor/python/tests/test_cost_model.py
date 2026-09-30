# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Cost model: calibrated against the measured SoC points, decisions by archetype."""
from ai_tensor.c_abi import AI_FMT_BF16, AI_FMT_FP32, AI_FMT_INT
from ai_tensor.cost_model import IslandModel, archetype, gemm_cycles, offload_decision, recipe_for


def test_calibration_matches_the_measured_decode_points():
    m = IslandModel()
    cold = gemm_cycles(m, 1, 512, 512, AI_FMT_INT)
    # measured: 34,136 cycles cold (bench SKU, mmio); the model must land within 3 %
    assert abs(cold["cycles"] - 34136) / 34136 < 0.03, cold
    res = gemm_cycles(m, 1, 512, 512, AI_FMT_INT, resident_b=True)
    # measured: 590 cycles resident after the trail store; within 20 % (fixed-cost dominated)
    assert abs(res["cycles"] - 590) / 590 < 0.20, res
    fp32 = gemm_cycles(m, 1, 256, 1024, AI_FMT_FP32)
    # measured: 134,542 cycles cold FP32 one flat-panel job
    assert abs(fp32["cycles"] - 134542) / 134542 < 0.03, fp32


def test_archetypes_and_bounds():
    m = IslandModel()
    assert archetype(1, 4096, 4096) == "A1"
    assert archetype(512, 4096, 4096) == "A2"
    assert offload_decision(m, 1, 4096, 4096, AI_FMT_INT)["bound"] == "bytes"
    assert offload_decision(m, 512, 4096, 4096, AI_FMT_INT)["bound"] == "mac"
    assert offload_decision(m, 512, 4096, 4096, AI_FMT_INT)["offload"]


def test_ladder_steps_move_the_right_regime():
    live = IslandModel()
    # the wide C store rides the wide port (StoreWordsMax = DataWidth/32)
    v1 = IslandModel(bytes_per_cycle=64.0, store_bytes_per_cycle=64.0)               # wide port
    v2 = IslandModel(bytes_per_cycle=64.0, store_bytes_per_cycle=64.0, out_cols=8)   # + column array
    dec = lambda mo: gemm_cycles(mo, 1, 4096, 4096, AI_FMT_INT)["cycles"]
    pre = lambda mo: gemm_cycles(mo, 512, 4096, 4096, AI_FMT_INT)["cycles"]
    assert dec(v1) < dec(live) / 5          # decode is bytes-bound: the port moves it
    assert abs(dec(v2) - dec(v1)) / dec(v1) < 0.15   # columns barely move decode (bytes-bound)
    assert pre(v2) < pre(v1) / 4            # prefill is MAC-bound: columns move it


def test_recipes_follow_grants():
    r = recipe_for("A1", granted={AI_FMT_INT})
    assert r["weights"] == AI_FMT_INT and r["head"] is None
    r = recipe_for("A3", granted={AI_FMT_INT, AI_FMT_BF16}, prefer_bf16_conv=True)
    assert r["weights"] == AI_FMT_BF16 and r["k_group"] == 0
    assert recipe_for("A3")["k_group"] == 64
