# Model-level qualification records

Produced by `tools/qualify_llm.py` (schema `ai-tensor.qualify-llm.v1`). Each file pins the
model revision, quantization recipe, device geometry and budget, and records perplexity,
next-token top-1 agreement and the offload ratio on a fixed 256-token passage.

All records are **virtual** executions of the descriptor contract on the software reference
with the live AccTile geometry; none is hardware timing or silicon evidence.

| record | recipe | ppl (ref -> island) | top-1 | verdict |
|---|---|---|---|---|
| `distilgpt2-int8-dynamic-perrow.json` | W8A8, per-row/per-channel scales | 46.51 -> 72.59 (+56%) | 0.553 | FAIL (retained baseline) |
| `distilgpt2-int8-dynamic-g128.json` | W8A8, K-group 128, lm_head quantized | 46.51 -> 48.57 (+4.4%) | 0.855 | FAIL (top-1) |
| `distilgpt2-int8-dynamic-g64.json` | W8A8, K-group 64, lm_head quantized | 46.51 -> 47.92 (+3.0%) | 0.847 | FAIL (top-1) |
| `distilgpt2-int8-dynamic-g128-fp-lmhead.json` | W8A8, K-group 128, lm_head float | 46.51 -> 46.44 (-0.1%) | 0.973 | **PASS** |
| `distilgpt2-fp32-accumulate.json` | FP32, all 25 layers, K chained through `accmode=01` | 46.5066 -> 46.5064 | 1.000 | **PASS** (needs `CAP_ACCMODE`; software reference grants it, live island does not yet) |

Budget (inferred, pending ratification): relative perplexity increase <= 10 %, top-1
agreement >= 90 %, zero fallbacks among replaced layers.

## VA-Turbo bounded approximation (`tools/va_select.py`, schema `ai-tensor.va-select.v1`)

`distilgpt2-va-select.json`: 12 recipes on the calibration passage; the cheapest one within
budget is re-measured on a disjoint held-out passage (Moby-Dick opening) before acceptance.
Cost is the bytes of weights the island streams per forward pass (the live geometry is
B-load bound), including float layers left on the host.

| recipe | weight bytes (x fp32) | calib ppl | calib top-1 | verdict |
|---|---:|---:|---:|---|
| fp32-accumulate | 1.000 | -0.0 % | 1.000 | ok (baseline) |
| fp8-e5m2-g128 | 0.250 | +359 % | 0.431 | over budget |
| fp8-e4m3-g128 | 0.250 | +45 % | 0.600 | over budget |
| int8-g128 | 0.250 | +4.4 % | 0.855 | over budget (top-1) |
| int8-g128-int8g32-lmhead | 0.250 | +3.4 % | 0.863 | over budget (top-1) |
| int8-g128-fp8e4m3g32-lmhead | 0.250 | +33 % | 0.627 | over budget |
| **int8-g128-fp16-lmhead** | **0.369** | **-0.1 %** | **0.973** | **selected; held-out -0.3 % / 0.9745** |
| int8-g128-bf16-lmhead | 0.369 | +0.4 % | 0.945 | ok (tie broken by ppl) |
| bf16-all | 0.500 | +0.5 % | 0.965 | ok |
| int8-g128-fp-lmhead | 0.607 | -0.1 % | 0.973 | ok |
| int8-g64-fp-lmhead | 0.607 | +0.3 % | 0.969 | ok |
| fp8-e4m3-g128-fp-lmhead | 0.607 | +1.8 % | 0.933 | ok |

Findings: the tied `lm_head` is both the quality-sensitive layer and the largest byte
stream; FP16 there costs half of FP32 and is exact enough, while INT8/FP8 there fails the
top-1 budget at any tested group size. FP8 (both encodings) is worse than INT8 at equal
bytes on this model. Virtual evidence at live geometry; bytes are contract operand traffic,
not a timing measurement.

## Diffusion pipelines (`tools/qualify_diffusion.py`, schema `ai-tensor.qualify-diffusion.v1`)

The denoiser's `nn.Linear` layers (and with `--conv2d` its ungrouped `nn.Conv2d` through
im2col) are swapped for the island module; the same prompt is rendered at the same seed in
FP32 and through the island, and the images are compared (PSNR in dB, mean absolute pixel
difference, images in [0, 1]) against an explicit budget (default PSNR >= 30 dB, MAD <= 0.02,
zero fallbacks). Scheduler, VAE and text encoder stay in float unless named in `--components`.

| record | pipeline | recipe | layers | PSNR | MAD | verdict |
|---|---|---|---|---|---|---|
| `tiny-sd-pipe-int8-dynamic.json` | `hf-internal-testing/tiny-stable-diffusion-pipe@3ee6c9f2` (random-weight UNet, plumbing/quality-ordering fixture) | W8A8 K-group 128 | 74 Linear | 60.4 dB | 7e-4 | **PASS** |
| `tiny-sd-pipe-fp8-e4m3.json` | same | FP8 E4M3 K-group 128 | 74 | 48.7 dB | 2.8e-3 | **PASS** (worse than INT8 at equal bytes, as on the LLM) |
| `tiny-sd-pipe-bf16.json` | same | BF16 cast, K chained through `accmode=01` | 74 | 71.3 dB | 2e-4 | **PASS** |
| `tiny-sd-pipe-int8-dynamic-conv2d.json` | same, `--conv2d` | W8A8 K-group 128, Linear + im2col Conv2d | 121 | 41.6 dB | 6.3e-3 | **PASS** |
| `segmind-tiny-sd-int8-dynamic-g128.json` | `segmind/tiny-sd@cad0bd74` (pretrained 512x512 distilled SD, 3 steps) | W8A8 K-group 128 | 101 Linear | 30.7 dB | 0.0205 | FAIL (MAD budget 0.02; retained) |
| `segmind-tiny-sd-int8-dynamic-g64.json` | same | W8A8 K-group 64 | 101 | 35.0 dB | 0.0124 | **PASS** |
| `segmind-tiny-sd-bf16.json` | same | BF16 cast, K chained through `accmode=01` | 101 | 48.5 dB | 0.0026 | **PASS** |

The tiny test pipeline has random weights: its records prove the offload path and the
recipe ordering, not perceptual quality. The pretrained `segmind/tiny-sd` records are the
quality data: the UNet is more K-group-sensitive than GPT-2 (g128 misses the MAD budget by
2.5 %, g64 clears it with 4 dB to spare), so the diffusion recipe of record is **INT8 K-group
64** (or BF16 where bytes allow). Island passes run on the software reference (549 s vs 33 s
for FP32 torch on this host) -- a virtual-execution cost, not a device projection. Budgets are inferred (PSNR 30 dB is the usual "visually identical"
threshold for 8-bit images) and await ratification.
