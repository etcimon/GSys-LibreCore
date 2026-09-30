# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""The recorded model-level qualification results stay self-consistent and pinned.

This does not rerun the models (that needs the pinned checkpoint and minutes); it keeps
the evidence files honest: schema, 40-hex revision, verdicts derived from the numbers,
the PASS recipes still passing their recorded budget, and the VA-Turbo selection being
the cheapest recipe that met the budget on both the calibration and the held-out text.
"""

import json
from pathlib import Path

import pytest

QUAL_DIR = Path(__file__).resolve().parents[2] / "fixtures" / "qual"
RECORDS = sorted(p for p in QUAL_DIR.glob("*.json") if json.loads(p.read_text())["schema"] == "ai-tensor.qualify-llm.v1")
SELECTIONS = sorted(p for p in QUAL_DIR.glob("*.json") if json.loads(p.read_text())["schema"] == "ai-tensor.va-select.v1")


@pytest.mark.parametrize("path", RECORDS, ids=lambda p: p.stem)
def test_record_is_consistent(path):
    d = json.loads(path.read_text())
    assert len(d["revision"]) == 40
    assert "virtual" in d["evidence"]
    rel = (d["ppl_island"] - d["ppl_reference"]) / d["ppl_reference"]
    assert abs(rel - d["ppl_rel_increase"]) < 1e-9
    v = d["verdict"]
    assert v["ppl_within_budget"] == (rel <= d["budget"]["ppl_rel"])
    assert v["top1_within_budget"] == (d["top1_agreement"] >= d["budget"]["top1"])
    assert v["no_fallback"] == (d["offload_stats"]["fallback_calls"] == 0)
    assert d["pass"] == all(v.values())


def test_the_passing_recipes_are_grouped_int8_with_float_lm_head_and_fp32_accumulate():
    passing = {p.stem: json.loads(p.read_text()) for p in RECORDS if json.loads(p.read_text())["pass"]}
    assert sorted(passing) == ["distilgpt2-fp32-accumulate", "distilgpt2-int8-dynamic-g128-fp-lmhead"]
    d = passing["distilgpt2-int8-dynamic-g128-fp-lmhead"]
    assert d["group_k"] == 128 and d["skip"] == ["lm_head"] and d["offload_ratio"] == 1.0
    f = passing["distilgpt2-fp32-accumulate"]
    # Every layer offloaded in float through accmode 01 K-chaining: exact top-1, ppl to 1e-5.
    assert f["quant"] == "none" and f["layers_replaced"] == 25 and f["offload_ratio"] == 1.0
    assert f["top1_agreement"] == 1.0 and abs(f["ppl_rel_increase"]) < 1e-5
    assert f["caps"]["accumulate"] is True


def _within(m, budget):
    return m["ppl_rel"] <= budget["ppl_rel"] and m["top1"] >= budget["top1"]


@pytest.mark.parametrize("path", SELECTIONS, ids=lambda p: p.stem)
def test_va_selection_is_cheapest_recipe_within_budget_on_both_texts(path):
    d = json.loads(path.read_text())
    assert len(d["revision"]) == 40 and "virtual" in d["evidence"]
    budget = d["budget"]
    recipes = d["recipes"]
    for r in recipes:
        assert r["calib_within_budget"] == _within(r["calib"], budget)
        assert r["fallback_calls"] == 0
        assert r["weight_bytes_total"] == r["weight_bytes_island"] + r["weight_bytes_host_float"]
    sel = next(r for r in recipes if r["name"] == d["selected"])
    assert sel["calib_within_budget"] and sel["holdout_within_budget"] == _within(sel["holdout"], budget)
    assert sel["holdout_within_budget"]
    # No cheaper recipe met the budget on both texts (anything cheaper that passed
    # calibration must carry a failed held-out result).
    for r in recipes:
        if r["weight_bytes_total"] < sel["weight_bytes_total"] and r["calib_within_budget"]:
            assert r.get("holdout_within_budget") is False
    assert abs(d["bytes_ratio_selected"] - sel["weight_bytes_total"] / d["reference"]["weight_bytes_fp32"]) < 1e-12


def test_distilgpt2_selection_is_int8_blocks_with_fp16_lm_head():
    d = json.loads((QUAL_DIR / "distilgpt2-va-select.json").read_text())
    assert d["selected"] == "int8-g128-fp16-lmhead"
    assert d["bytes_ratio_selected"] < 0.4
    names = {r["name"]: r for r in d["recipes"]}
    # FP8 alone is measurably worse than INT8 at the same byte cost on this model.
    assert names["fp8-e4m3-g128"]["calib"]["ppl_rel"] > names["int8-g128"]["calib"]["ppl_rel"]
    assert not names["fp8-e5m2-g128"]["calib_within_budget"]


DIFFUSION = sorted(p for p in QUAL_DIR.glob("*.json") if json.loads(p.read_text())["schema"] == "ai-tensor.qualify-diffusion.v1")


@pytest.mark.parametrize("path", DIFFUSION, ids=lambda p: p.stem)
def test_diffusion_record_is_consistent(path):
    """Pinned pipeline, verdict derived from the recorded PSNR / mean-abs-diff / fallback
    numbers, evidence class stated; the recipe ladder on the tiny pipeline keeps the
    expected ordering (INT8 g128 beats FP8 E4M3 at equal bytes, BF16 beats both)."""
    d = json.loads(path.read_text())
    assert len(d["revision"]) == 40 and "virtual" in d["evidence"]
    v = d["verdict"]
    assert v["psnr_within_budget"] == (d["psnr_db"] >= d["budget"]["psnr_db"])
    assert v["mad_within_budget"] == (d["mean_abs_diff"] <= d["budget"]["mad"])
    assert v["no_fallback"] == (d["offload_stats"]["fallback_calls"] == 0)
    assert d["pass"] == all(v.values())
    assert d["offload_ratio"] == 1.0 and d["layers_replaced"] > 0


def test_tiny_pipeline_recipe_ladder_orders_by_precision():
    by = {json.loads(p.read_text())["quant"]: json.loads(p.read_text()) for p in DIFFUSION
          if "tiny-stable-diffusion-pipe" in json.loads(p.read_text())["model"] and not json.loads(p.read_text())["conv2d"]}
    if not {"int8-dynamic", "fp8-e4m3", "bf16"} <= set(by):
        pytest.skip("tiny pipeline ladder not recorded")
    assert by["bf16"]["psnr_db"] > by["int8-dynamic"]["psnr_db"] > by["fp8-e4m3"]["psnr_db"] > 30.0
