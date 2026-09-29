# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Model-level qualification of the island offload path on a pinned pretrained LLM.

Runs one causal LM twice on a fixed text: as published (float) and with every
linear-like projection routed through ``ai_tensor.torch_backend.replace_linear``.
Reports perplexity, next-token top-1 agreement, offload ratio and the reasons for
any fallback, then judges against an explicit quality budget.

Evidence boundary: the default device is the software reference, i.e. a *virtual*
execution of the descriptor contract with the live AccTile geometry. It qualifies
model support and numerical behaviour of the offload path, not hardware speed.

Example (inferred defaults, see architecture/ai-matrix/log-2026-09.md):
    PYTHONPATH=python python tools/qualify_llm.py --model distilgpt2 \
        --revision 2290a62682d06624634c1f46a6ad5be0f47f38aa --quant int8-dynamic \
        --out fixtures/qual/distilgpt2-int8-dynamic.json
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

# A fixed public-domain passage so the run needs no dataset download and is reproducible.
TEXT = (
    "It is a truth universally acknowledged, that a single man in possession of a good "
    "fortune, must be in want of a wife. However little known the feelings or views of such "
    "a man may be on his first entering a neighbourhood, this truth is so well fixed in the "
    "minds of the surrounding families, that he is considered the rightful property of some "
    "one or other of their daughters. My dear Mr. Bennet, said his lady to him one day, have "
    "you heard that Netherfield Park is let at last? Mr. Bennet replied that he had not. But "
    "it is, returned she; for Mrs. Long has just been here, and she told me all about it. Mr. "
    "Bennet made no answer. Do you not want to know who has taken it? cried his wife "
    "impatiently. You want to tell me, and I have no objection to hearing it. This was "
    "invitation enough. Why, my dear, you must know, Mrs. Long says that Netherfield is taken "
    "by a young man of large fortune from the north of England; that he came down on Monday in "
    "a chaise and four to see the place, and was so much delighted with it, that he agreed "
    "with Mr. Morris immediately; that he is to take possession before Michaelmas, and some of "
    "his servants are to be in the house by the end of next week."
)


def _ppl_and_top1(model, ids):
    import torch

    with torch.no_grad():
        logits = model(input_ids=ids).logits[0, :-1]
    targets = ids[0, 1:]
    nll = torch.nn.functional.cross_entropy(logits.float(), targets, reduction="mean")
    return math.exp(nll.item()), logits.argmax(dim=-1), logits.float()


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", required=True)
    p.add_argument("--revision", required=True, help="pinned commit hash; a branch name is refused")
    p.add_argument("--quant", default="int8-dynamic",
                   choices=["none", "int8-dynamic", "fp8-e4m3", "fp8-e5m2", "bf16", "fp16"])
    p.add_argument("--backend", default="software-reference-v2")
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--group-k", type=int, default=128, help="INT8 K-group length (<= AccTile K)")
    p.add_argument("--budget-ppl", type=float, default=0.10, help="max relative perplexity increase")
    p.add_argument("--budget-top1", type=float, default=0.90, help="min next-token top-1 agreement")
    p.add_argument("--skip", action="append", default=[], help="module name to leave in float (repeatable)")
    p.add_argument("--out", type=Path, default=None)
    args = p.parse_args(argv)
    if len(args.revision) != 40:
        p.error("--revision must be a 40-hex commit hash so the run is reproducible")

    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    from ai_tensor.device import Device
    from ai_tensor import torch_backend as tb

    torch.manual_seed(0)
    tok = AutoTokenizer.from_pretrained(args.model, revision=args.revision)
    model = AutoModelForCausalLM.from_pretrained(args.model, revision=args.revision, torch_dtype=torch.float32).eval()
    ids = tok(TEXT, return_tensors="pt").input_ids[:, : args.max_tokens]

    t0 = time.time()
    ppl_ref, top1_ref, logits_ref = _ppl_and_top1(model, ids)
    t_ref = time.time() - t0

    dev = Device(args.backend)
    report = tb.replace_linear(model, dev, quant=args.quant, group_k=args.group_k, skip=args.skip)
    t0 = time.time()
    ppl_isl, top1_isl, logits_isl = _ppl_and_top1(model, ids)
    t_isl = time.time() - t0

    agree = float((top1_ref == top1_isl).float().mean().item())
    rel_ppl = (ppl_isl - ppl_ref) / ppl_ref
    stats = report.stats.as_dict()
    total_calls = stats["offloaded_calls"] + stats["fallback_calls"]
    offload_ratio = stats["offloaded_calls"] / total_calls if total_calls else 0.0
    verdict = {
        "ppl_within_budget": rel_ppl <= args.budget_ppl,
        "top1_within_budget": agree >= args.budget_top1,
        "no_fallback": stats["fallback_calls"] == 0,
    }
    result = {
        "schema": "ai-tensor.qualify-llm.v1",
        "model": args.model, "revision": args.revision, "quant": args.quant, "group_k": args.group_k, "skip": args.skip,
        "backend": dev.backend, "caps": dev.caps().as_dict(),
        "tokens": int(ids.shape[1]),
        "layers_replaced": len(report.replaced), "layers_skipped": report.skipped,
        "offload_stats": stats, "offload_ratio": offload_ratio,
        "ppl_reference": ppl_ref, "ppl_island": ppl_isl, "ppl_rel_increase": rel_ppl,
        "top1_agreement": agree,
        "max_abs_logit_diff": float((logits_ref - logits_isl).abs().max().item()),
        "seconds_reference": t_ref, "seconds_island": t_isl,
        "budget": {"ppl_rel": args.budget_ppl, "top1": args.budget_top1},
        "verdict": verdict, "pass": all(verdict.values()),
        "evidence": "virtual execution of the descriptor contract; not hardware timing or silicon",
    }
    text = json.dumps(result, indent=2, sort_keys=True)
    print(text)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
