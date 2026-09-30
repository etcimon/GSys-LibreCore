#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Qualify a pinned Diffusers pipeline against the island contract.

Runs the pipeline once in FP32 (the reference), swaps every eligible ``nn.Linear``
(and, with ``--conv2d``, every ungrouped ``nn.Conv2d`` through im2col) of the denoiser
for the island module, renders the same prompt at the same seed again, and judges the
two images against an explicit budget: peak signal-to-noise ratio in dB, mean absolute
pixel difference, and zero fallbacks. The scheduler, VAE and text encoder stay in float
unless asked, because they are not where the bytes are.

The output is a JSON record in the shape of ``qualify_llm.py``'s (schema
``ai-tensor.qualify-diffusion.v1``) so ``test_qual_records.py`` can keep the numbers and
verdict consistent. Evidence class: virtual execution of the descriptor contract on the
software reference; not hardware timing, not silicon.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

PROMPT = "a small red boat on a calm lake at sunrise, oil painting"


def _psnr(a, b) -> float:
    import numpy as np

    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    return math.inf if mse == 0.0 else 10.0 * math.log10(1.0 / mse)  # images are in [0, 1]


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", required=True, help="Diffusers pipeline id or local path")
    p.add_argument("--revision", required=True, help="pinned commit hash; a branch name is refused")
    p.add_argument("--quant", default="int8-dynamic",
                   choices=["none", "int8-dynamic", "fp8-e4m3", "fp8-e5m2", "bf16", "fp16"])
    p.add_argument("--backend", default="software-reference-v2")
    p.add_argument("--group-k", type=int, default=128)
    p.add_argument("--steps", type=int, default=4, help="denoising steps (small: the reference is the same pipeline)")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--prompt", default=PROMPT)
    p.add_argument("--conv2d", action="store_true", help="also offload ungrouped Conv2d through im2col")
    p.add_argument("--components", default="unet", help="comma list of pipeline components to swap (unet[,text_encoder,vae])")
    p.add_argument("--budget-psnr", type=float, default=30.0, help="min PSNR (dB) of the island image vs the FP32 image")
    p.add_argument("--budget-mad", type=float, default=0.02, help="max mean absolute pixel difference (images in [0,1])")
    p.add_argument("--skip", action="append", default=[], help="module name to leave in float (repeatable)")
    p.add_argument("--out", type=Path, default=None)
    args = p.parse_args(argv)
    if len(args.revision) != 40:
        p.error("--revision must be a 40-hex commit hash so the run is reproducible")

    import numpy as np
    import torch
    from diffusers import DiffusionPipeline

    from ai_tensor.device import Device
    from ai_tensor import torch_backend as tb

    pipe = DiffusionPipeline.from_pretrained(args.model, revision=args.revision, torch_dtype=torch.float32,
                                             safety_checker=None)
    pipe.set_progress_bar_config(disable=True)

    def render():
        g = torch.Generator().manual_seed(args.seed)
        return pipe(args.prompt, num_inference_steps=args.steps, generator=g, output_type="np").images[0]

    t0 = time.time()
    ref = render()
    t_ref = time.time() - t0

    dev = Device(args.backend)
    reports = {}
    for name in [c.strip() for c in args.components.split(",") if c.strip()]:
        component = getattr(pipe, name, None)
        if component is None:
            p.error(f"pipeline has no component {name!r}")
        reports[name] = tb.replace_linear(component, dev, quant=args.quant, group_k=args.group_k,
                                          skip=args.skip, conv2d=args.conv2d)
    t0 = time.time()
    isl = render()
    t_isl = time.time() - t0

    stats = {"offloaded_calls": 0, "fallback_calls": 0, "offloaded_blocks": 0}
    replaced, skipped = 0, []
    for r in reports.values():
        s = r.stats.as_dict()
        for k in stats:
            stats[k] += s.get(k, 0)
        replaced += len(r.replaced)
        skipped += list(r.skipped)
    total_calls = stats["offloaded_calls"] + stats["fallback_calls"]
    offload_ratio = stats["offloaded_calls"] / total_calls if total_calls else 0.0
    psnr = _psnr(ref, isl)
    mad = float(np.mean(np.abs(ref.astype(np.float64) - isl.astype(np.float64))))
    verdict = {
        "psnr_within_budget": psnr >= args.budget_psnr,
        "mad_within_budget": mad <= args.budget_mad,
        "no_fallback": stats["fallback_calls"] == 0,
    }
    result = {
        "schema": "ai-tensor.qualify-diffusion.v1",
        "model": args.model, "revision": args.revision, "quant": args.quant, "group_k": args.group_k,
        "components": sorted(reports), "conv2d": args.conv2d, "skip": args.skip,
        "backend": dev.backend, "caps": dev.caps().as_dict(),
        "prompt": args.prompt, "seed": args.seed, "steps": args.steps,
        "image_shape": list(ref.shape),
        "layers_replaced": replaced, "layers_skipped": skipped,
        "offload_stats": stats, "offload_ratio": offload_ratio,
        "psnr_db": psnr, "mean_abs_diff": mad,
        "max_abs_diff": float(np.max(np.abs(ref.astype(np.float64) - isl.astype(np.float64)))),
        "seconds_reference": t_ref, "seconds_island": t_isl,
        "budget": {"psnr_db": args.budget_psnr, "mad": args.budget_mad},
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
