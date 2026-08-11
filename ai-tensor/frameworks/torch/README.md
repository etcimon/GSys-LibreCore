# PyTorch attachment

**Rule:** libtorch headers never enter `ai-tensor` Rust crates (KD0).

## Phase M4 — high-level Python (landed)

```bash
pip install torch   # optional for full suite; Device cases run without torch
PYTHONPATH=python python python/examples/torch_island_smoke.py
# Virtual PCIe AI board (ai_island feature validation):
PYTHONPATH=python:tools python python/tests/test_torch_virt_ai_island.py
# Monorepo (select board + g6lc64_ai core):
#   cva6-build tensor pytorch --board virt-ai-pcie --core g6lc64_ai
```

API: `ai_tensor.torch_ops.gemm_s8` / `check_close_to_torch` → `Device`
(`sim` | `mmio-soft` | **`virt-card`**). Large mats auto-tile via AccTile streaming.

Structured test: `python/tests/test_torch_virt_ai_island.py` (unittest classes for
GEMM golden, AccTile stream, multi-ticket, TCP CardAgent, env propagation).  
Architecture map: monorepo `architecture/ai-matrix/frameworks-virt-pcie.md`.

## Phase M8 — C++ extension (later)

- `torch.ops.ai_tensor.gemm_s8` out-of-tree under this directory
- Include `include/ai_tensor.h`; link future `libai_tensor` C ABI
- Pin `abi_rev` major; default CI remains pure Python + sim

## Host runtime

Frameworks should prefer **enqueue + drain** (`HostRuntime` in Rust, or Python
`Device.gemm_s8` loops) rather than ad-hoc doorbell programming.
