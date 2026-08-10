# PyTorch attachment

**Rule:** libtorch headers never enter `ai-tensor` Rust crates (KD0).

## Phase M4 — high-level Python (landed)

```bash
pip install torch   # optional
PYTHONPATH=python python python/examples/torch_island_smoke.py
```

API: `ai_tensor.torch_ops.gemm_s8` / `check_close_to_torch` → `Device` (sim or mmio-soft).
Large mats auto-tile via AccTile streaming.

## Phase M8 — C++ extension (later)

- `torch.ops.ai_tensor.gemm_s8` out-of-tree under this directory
- Include `include/ai_tensor.h`; link future `libai_tensor` C ABI
- Pin `abi_rev` major; default CI remains pure Python + sim

## Host runtime

Frameworks should prefer **enqueue + drain** (`HostRuntime` in Rust, or Python
`Device.gemm_s8` loops) rather than ad-hoc doorbell programming.
