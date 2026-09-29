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
