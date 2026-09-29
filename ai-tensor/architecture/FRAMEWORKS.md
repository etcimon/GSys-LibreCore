# Framework backends (PyTorch / TensorFlow)

**Package purpose (from `AGENTS.md`):** `ai-tensor` **is** the PyTorch/TensorFlow backend for the
LibreCore AI island — not an optional demo.

---

## 1. Shared rule

All frameworks:

1. Accept framework tensors (or DLPack).
2. Lower to **`ai-tensor-ir`** (op + shapes + dtype + layout).
3. Lower to **`Desc64` + regions** via **`ai-tensor-abi`**.
4. Submit/wait through **`ai-tensor-rt`** (C ABI at the boundary).

No framework-private descriptor layout.

The generic `ai_tensor.torch_ops.gemm` and `ai_tensor.numpy_ops.gemm` functions preserve
matching operand dtypes, explicitly transpose B to the v2 native `[n][k]` layout and
submit byte views to `Device.gemm_native`. They return i32 for integers and f32 for floats.
Unsupported dtype, mixed dtype, big-endian input or oversized native tiles are refused;
there is no implicit int8 conversion or FP K-split fallback. The explicit `gemm_s8`
convenience functions retain their documented int8 conversions. TensorFlow remains
S8-only; no generic native TF lowering is claimed. Pure Python native bytes and
`pack_bits` require neither NumPy nor PyTorch. See `RUNTIME.md` §4a for API signatures.

```
torch.mm / tf.linalg.matmul
        │
        ▼
HostRuntime.enqueue / drain  (profile wait_policy + submit_mode)
        │
        ▼
ai_tensor IR (Gemm { m,n,k, dtype, ptrs }) → stream tiles
        │
        ▼
Desc64 + program_region + submit|submit_fetch + WaitPolicy
        │
        ▼
sim | SoftIsland | linux-uio → ai_island
```

---

## 2. PyTorch (primary)

### 2.1 Phase M4 — custom ops (recommended first)

- Library: `torch.ops.ai_tensor.gemm_s8`, `…` (names track IR ops).
- Built as a **separate** extension (`frameworks/torch`) linking:
  - libtorch (user/env provided)
  - `libai_tensor` (C ABI from this package)
- Default Rust workspace **does not** depend on libtorch (keeps KD0 independence).

**Dispatcher sketch:**

- Check device / dtype / contiguity / size limits from Caps.
- Pin storage, ensure AI-3 region covers buffers (or expand region API).
- Build desc (flags.IRQ optional), submit, wait, return output tensor.

### 2.1a Module-level offload (landed, virtual backends)

`ai_tensor.torch_backend` is the first surface that runs a **model's own layers** through
the device path:

- `AiTensorLinear(nn.Linear, Device, quant=...)`: the `[out, in]` weight *is* the island's
  k-major `B[n][k]`, so it is prepacked once; forwards flatten to `[M, K]`, split M/N/K
  into AccTile blocks and call `Device.gemm_native`. Integer blocks accumulate exactly
  across K; float formats keep the island's ordered FP32 reduction and **refuse** a K-split.
  `quant="int8-dynamic"` = weight-only per-channel INT8 + per-row dynamic INT8 activations
  with exact i32 accumulation (a quantization; the caller owns the quality budget).
- `AiTensorConv2d`: groups=1 conv via `F.unfold` im2col onto the same linear path.
- `replace_linear(model, device, quant=..., conv2d=...)`: in-place swap over Transformers /
  Diffusers / plain modules; returns a `SwapReport` with one shared `OffloadStats`.
- Fallback to torch is **explicit and counted** (`OffloadStats.fallback_reasons`); a
  `allow_fallback=False` layer raises instead. A prepacked-byte corruption test proves the
  island path executed.
- `register_custom_op()` exposes `torch.ops.ai_tensor.gemm(a, b_kmajor)` with a fake kernel
  when `torch.library.custom_op` exists.

GPT-2-family `Conv1D` (transposed `[in, out]` weight) is folded once into the same path.

Tests: `python/tests/test_torch_backend.py` (10, incl. a tiny BERT layer through swapped
linears, a conv->conv block, and a GPT-2 greedy `generate()` decode loop with KV cache whose
tokens match the float model exactly). Evidence boundary: `sim` / `software-reference-v2` /
`mmio` are **virtual** executions of the descriptor contract; only `qemu-uio` against a
real island is hardware evidence. Model-quality qualification of a full pretrained LLM
and diffusion pipeline remains open.

### 2.2 Phase M8 — optional deeper integration

| Mechanism | Benefit | Cost |
|---|---|---|
| PrivateUse1 device `aitensor` | `tensor.to("aitensor")` | Large surface |
| `torch.compile` / Inductor lowering | Fused graphs | Pattern fragility |
| Autograd | Training | Need epilogue contracts |

Ship **inference custom ops** before autograd or Inductor.

### 2.3 Testing

- Sim backend in CI (no FPGA): `python/examples/torch_island_smoke.py`.
- **Virtual PCIe AI board (hostless, preferred monorepo gate):** structured unittest
  `python/tests/test_torch_virt_ai_island.py` through `Device(backend=virt-card)` /
  board `virt-ai-pcie` (soft UIO + optional TCP CardAgent). Covers INT8 GEMM golden,
  AccTile host stream, multi-ticket, env/`AI_TENSOR_CORE=g6lc64_ai` selection, local+tcp.
  - Package: `PYTHONPATH=python:tools python python/tests/test_torch_virt_ai_island.py`
  - Host: `cva6-build tensor pytorch --board virt-ai-pcie --core g6lc64_ai`
  - Full gate: `cva6-build tensor regress --board virt-ai-pcie --core g6lc64_ai`
  - Map: monorepo `architecture/ai-matrix/frameworks-virt-pcie.md`
- Optional monorepo HARD: `tensor rtl-hard` / Variane ELFs (orthogonal to frameworks path).
- Without torch wheels, Device-only cases still PASS; `AI_TENSOR_REQUIRE_TORCH=1` hard-fails.

---

## 3. TensorFlow (secondary)

### 3.1 Phase M6a — high-level Python (landed)

- `ai_tensor.tf_ops.gemm_s8` / `check_close_to_tf` (optional `tensorflow` import).
- Same `Device` / Desc64 path as PyTorch; example `python/examples/tf_island_smoke.py`.
- Docs: `frameworks/tensorflow/README.md`.

### 3.2 Phase M6b — C++ custom ops (later)

- `AiTensorGemm` via TF custom op / pluggable device C API.
- Include **`include/ai_tensor.h`**; never pull TF headers into Rust crates.
- Build out of tree under `frameworks/tensorflow/`.

### 3.3 XLA

Custom call only after eager custom ops are stable; not on the M0–M5 critical path.

---

## 4. Python ergonomics

- `pip install ai-tensor` (sim + native).
- `ai_tensor.device("sim")` / `ai_tensor.device("uio:0")`.
- NumPy `__array_interface__` / DLPack import-export for framework-free tests.

Torch/TF packages depend on this wheel or embed the `.so`.

---

## 5. Versioning for frameworks

Framework packages declare:

```text
requires: ai-tensor-abi >= X.Y, < X+1
profile: sim-v0 | linux-island-rN
```

Breaking desc/status changes bump **major** `abi_rev` (see VERSIONING). Frameworks pin majors.

---

## 6. Non-goals

- Replacing CUDA for arbitrary PyTorch ops in M4–M6.
- Shipping prebuilt wheels that embed a full LibreCore bitstream.
- Silent fallback to CPU matmul without an explicit policy flag (debugging only).

## Bounded approximation recipes (VA-Turbo, measured)

`AiTensorLinear(quant=...)` now offers `int8-dynamic`, `fp8-e4m3`, `fp8-e5m2` (per-(row,
K-group) scaled codes; the island multiplies raw pairs, the host applies the two group scales
and sums groups in f32), and `bf16` / `fp16` (cast recipes on the island's float datapath
with the ordered FP32 accumulation, K-chained through accmode 01). `tools/va_select.py`
runs a recipe ladder on a pinned model, keeps only recipes within the quality budget on a
calibration text, re-measures the cheapest on a disjoint held-out text and records every
candidate (`fixtures/qual/*-va-select.json`, checked by `test_qual_records.py`). Cost is
the island's weight byte stream (the live geometry is B-load bound). On distilgpt2 the
selection is INT8 K-group-128 blocks with an FP16 `lm_head`: 0.369x the FP32 bytes at
-0.1 % / -0.3 % perplexity and 0.973 / 0.9745 top-1 on calibration / held-out. FP8 is
measurably worse than INT8 at equal bytes on this model. Virtual evidence.
