# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""VA-Turbo bounded approximation: pick the cheapest offload recipe that meets a quality budget.

Scaling on the live island is bandwidth-bound (the 1x512x512 decode tile is B-load bound:
32768 beats against 512 MAC cycles), so the cost axis here is the **bytes of weights the
island streams per forward pass**, exactly the quantity a numeric recipe changes. Each
recipe is run through ``replace_linear`` on a pinned model:

  1. quality on a *calibration* text -> candidates within budget;
  2. cheapest candidate re-measured on a disjoint *held-out* text -> accept only if it
     still meets the budget there (a recipe fitted to its own evidence is not accepted);
  3. everything is recorded, including the rejected recipes, so the choice is auditable.

Evidence boundary: virtual execution of the descriptor contract on the software
reference at live geometry. Bytes are the contract's operand traffic, not a timing claim.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from qualify_llm import TEXT as CALIB_TEXT  # noqa: E402  (same passage as the single-recipe tool)

HOLDOUT_TEXT = (
    "Call me Ishmael. Some years ago, never mind how long precisely, having little or no "
    "money in my purse, and nothing particular to interest me on shore, I thought I would "
    "sail about a little and see the watery part of the world. It is a way I have of driving "
    "off the spleen and regulating the circulation. Whenever I find myself growing grim about "
    "the mouth; whenever it is a damp, drizzly November in my soul; whenever I find myself "
    "involuntarily pausing before coffin warehouses, and bringing up the rear of every funeral "
    "I meet; and especially whenever my hypos get such an upper hand of me, that it requires a "
    "strong moral principle to prevent me from deliberately stepping into the street, and "
    "methodically knocking people's hats off, then I account it high time to get to sea as "
    "soon as I can. This is my substitute for pistol and ball. With a philosophical flourish "
    "Cato throws himself upon his sword; I quietly take to the ship. There is nothing "
    "surprising in this. If they but knew it, almost all men in their degree, some time or "
    "other, cherish very nearly the same feelings towards the ocean with me."
)

# The ladder, cheapest first is decided by measured bytes, not by this order.
RECIPES = [
    {"name": "fp32-accumulate", "quant": "none", "group_k": 128, "skip": []},
    {"name": "fp8-e5m2-g128", "quant": "fp8-e5m2", "group_k": 128, "skip": []},
    {"name": "fp8-e4m3-g128", "quant": "fp8-e4m3", "group_k": 128, "skip": []},
    {"name": "fp8-e4m3-g128-fp-lmhead", "quant": "fp8-e4m3", "group_k": 128, "skip": ["lm_head"]},
    {"name": "int8-g128", "quant": "int8-dynamic", "group_k": 128, "skip": []},
    {"name": "int8-g128-fp-lmhead", "quant": "int8-dynamic", "group_k": 128, "skip": ["lm_head"]},
    {"name": "int8-g64-fp-lmhead", "quant": "int8-dynamic", "group_k": 64, "skip": ["lm_head"]},
    # Mixed recipes: the tied lm_head (50257 x 768) is the quality-sensitive layer AND the
    # largest byte stream, so it gets its own format.
    {"name": "bf16-all", "quant": "bf16", "group_k": 128, "skip": []},
    {"name": "int8-g128-bf16-lmhead", "quant": "int8-dynamic", "group_k": 128, "skip": ["lm_head"],
     "lm_head": {"quant": "bf16", "group_k": 128}},
    {"name": "int8-g128-fp16-lmhead", "quant": "int8-dynamic", "group_k": 128, "skip": ["lm_head"],
     "lm_head": {"quant": "fp16", "group_k": 128}},
    {"name": "int8-g128-int8g32-lmhead", "quant": "int8-dynamic", "group_k": 128, "skip": ["lm_head"],
     "lm_head": {"quant": "int8-dynamic", "group_k": 32}},
    {"name": "int8-g128-fp8e4m3g32-lmhead", "quant": "int8-dynamic", "group_k": 128, "skip": ["lm_head"],
     "lm_head": {"quant": "fp8-e4m3", "group_k": 32}},
]


def _metrics(model, ids, ref_top1=None):
    import torch

    with torch.no_grad():
        logits = model(input_ids=ids).logits[0, :-1].float()
    nll = torch.nn.functional.cross_entropy(logits, ids[0, 1:], reduction="mean")
    top1 = logits.argmax(dim=-1)
    agree = None if ref_top1 is None else float((top1 == ref_top1).float().mean().item())
    return math.exp(nll.item()), top1, agree


def evaluate(base_model, dev, recipe, calib_ids, hold_ids, refs):
    import torch
    from ai_tensor import torch_backend as tb

    model = copy.deepcopy(base_model)
    report = tb.replace_linear(model, dev, quant=recipe["quant"], group_k=recipe["group_k"], skip=recipe["skip"])
    if recipe.get("lm_head"):
        model.lm_head = tb.AiTensorLinear(model.lm_head, dev, quant=recipe["lm_head"]["quant"],
                                          group_k=recipe["lm_head"]["group_k"], stats=report.stats)
        report.replaced.append("lm_head")
    island = [m for m in model.modules() if isinstance(m, tb.AiTensorLinear)]
    bytes_island = sum(m.weight_bytes() for m in island)
    # Float-kept (skipped) layers still cost their float bytes on the host side; count them so a
    # recipe cannot look cheap by leaving the biggest layer off the island. GPT-2 blocks are
    # Conv1D, so "linear-like" means anything replace_linear would take.
    bytes_host = sum(m.weight.numel() * m.weight.element_size() for m in model.modules()
                     if isinstance(m, torch.nn.Linear) and not isinstance(m, tb.AiTensorLinear))
    bytes_fp32_equiv = sum(m.weight.numel() * 4 for m in island) + bytes_host
    t0 = time.time()
    ppl_c, _, agree_c = _metrics(model, calib_ids, refs["calib_top1"])
    t_calib = time.time() - t0
    out = {
        **recipe,
        "layers_replaced": len(report.replaced), "fallback_calls": report.stats.fallback_calls,
        "weight_bytes_island": bytes_island, "weight_bytes_host_float": bytes_host,
        "weight_bytes_total": bytes_island + bytes_host, "weight_bytes_fp32_equiv": bytes_fp32_equiv,
        "calib": {"ppl": ppl_c, "ppl_rel": ppl_c / refs["calib_ppl"] - 1.0, "top1": agree_c,
                  "seconds": t_calib},
    }
    return model, out


def within(m, budget):
    return m["ppl_rel"] <= budget["ppl_rel"] and m["top1"] >= budget["top1"]


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", required=True)
    p.add_argument("--revision", required=True)
    p.add_argument("--backend", default="software-reference-v2")
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--budget-ppl", type=float, default=0.10)
    p.add_argument("--budget-top1", type=float, default=0.90)
    p.add_argument("--recipes", default=",".join(r["name"] for r in RECIPES))
    p.add_argument("--skip-holdout", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--out", type=Path, default=None)
    args = p.parse_args(argv)
    if len(args.revision) != 40:
        p.error("--revision must be a 40-hex commit hash")

    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from ai_tensor.device import Device

    torch.manual_seed(0)
    tok = AutoTokenizer.from_pretrained(args.model, revision=args.revision)
    base = AutoModelForCausalLM.from_pretrained(args.model, revision=args.revision, dtype=torch.float32).eval()
    calib_ids = tok(CALIB_TEXT, return_tensors="pt").input_ids[:, : args.max_tokens]
    hold_ids = tok(HOLDOUT_TEXT, return_tensors="pt").input_ids[:, : args.max_tokens]
    ppl_c, top1_c, _ = _metrics(base, calib_ids)
    ppl_h, top1_h, _ = _metrics(base, hold_ids)
    refs = {"calib_ppl": ppl_c, "calib_top1": top1_c, "hold_ppl": ppl_h, "hold_top1": top1_h}
    budget = {"ppl_rel": args.budget_ppl, "top1": args.budget_top1}
    dev = Device(args.backend)

    wanted = set(args.recipes.split(","))
    results = []
    models = {}
    for recipe in RECIPES:
        if recipe["name"] not in wanted:
            continue
        model, res = evaluate(base, dev, recipe, calib_ids, hold_ids, refs)
        res["calib_within_budget"] = within(res["calib"], budget)
        results.append(res)
        models[recipe["name"]] = model
        print(f"[va_select] {recipe['name']:28s} bytes={res['weight_bytes_total']:>10d} "
              f"ppl_rel={res['calib']['ppl_rel']:+.4f} top1={res['calib']['top1']:.3f} "
              f"{'ok' if res['calib_within_budget'] else 'over budget'}", file=sys.stderr)

    float_bytes = results[0]["weight_bytes_fp32_equiv"] if results else 0
    # Cheapest candidate first; the first one that also holds on the held-out text wins.
    selected = None
    # Ties on bytes go to the better calibration perplexity.
    for res in sorted((r for r in results if r["calib_within_budget"]),
                      key=lambda r: (r["weight_bytes_total"], r["calib"]["ppl_rel"])):
        ppl, _, agree = _metrics(models[res["name"]], hold_ids, refs["hold_top1"])
        res["holdout"] = {"ppl": ppl, "ppl_rel": ppl / refs["hold_ppl"] - 1.0, "top1": agree}
        res["holdout_within_budget"] = within(res["holdout"], budget)
        if res["holdout_within_budget"]:
            selected = res["name"]
            break
    record = {
        "schema": "ai-tensor.va-select.v1",
        "model": args.model, "revision": args.revision, "backend": dev.backend, "caps": dev.caps().as_dict(),
        "tokens": {"calib": int(calib_ids.shape[1]), "holdout": int(hold_ids.shape[1])},
        "reference": {"calib_ppl": ppl_c, "holdout_ppl": ppl_h, "weight_bytes_fp32": float_bytes},
        "recipes_list": [r["name"] for r in results],
        "budget": budget, "recipes": results, "selected": selected,
        "bytes_ratio_selected": (next(r["weight_bytes_total"] for r in results if r["name"] == selected) / float_bytes)
        if selected else None,
        "evidence": "virtual execution of the descriptor contract at live geometry; bytes are operand traffic, not timing",
    }
    text = json.dumps(record, indent=2, sort_keys=True)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n")
    print(json.dumps({k: record[k] for k in ("selected", "bytes_ratio_selected", "budget")}, indent=2))
    return 0 if selected else 1


if __name__ == "__main__":
    sys.exit(main())
