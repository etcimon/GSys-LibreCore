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
