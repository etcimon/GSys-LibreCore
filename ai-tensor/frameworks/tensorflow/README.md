# TensorFlow attachment (M6)

**Rule:** TF headers and C++ custom-op builds stay **here** (or a future wheel),
never in `ai-tensor` Rust crates. Same Desc64 path as PyTorch.

## Phase 1 (landed) — high-level Python

```bash
pip install tensorflow   # optional
PYTHONPATH=python python python/examples/tf_island_smoke.py
```

API: `ai_tensor.tf_ops.gemm_s8` / `check_close_to_tf` → `Device` (sim or mmio-soft).

## Phase 2 (later) — C++ custom op

- Op name sketch: `AiTensorGemm`
- Link `include/ai_tensor.h` + future `libai_tensor` C ABI
- Build out of tree; pin `abi_rev` major

## Phase 3 — XLA custom call

Only after eager custom ops are stable.
