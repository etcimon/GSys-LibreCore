# ai-tensor

Host software package: **PyTorch / TensorFlow backend** for LibreCore **`Xg6lcai` / `ai_island`**.

Architecture (M0): [`architecture/README.md`](architecture/README.md) · Agent entry: [`AGENTS.md`](AGENTS.md)

## Quick start (sim — no RTL)

```bash
cd ai-tensor
# Rust tests + goldens (+ cosim harness) + Python smoke
python tools/ait.py test
python tools/ait.py golden
python tools/ait.py cosim
python tools/ait.py rtl          # soft lab probe

# High-level PyTorch / TensorFlow (optional)
PYTHONPATH=python python python/examples/torch_island_smoke.py
PYTHONPATH=python python python/examples/tf_island_smoke.py

# CLI
cargo run -p ai-tensor-cli -- doctor
cargo run -p ai-tensor-cli -- sim-gemm --m 4 --n 4 --k 4
cargo run -p ai-tensor-cli -- stream-gemm --m 4 --n 4 --k 4
cargo run -p ai-tensor-cli -- queue-soak --backend mmio
cargo run -p ai-tensor-cli -- irq-soak --backend mmio
cargo run -p ai-tensor-cli -- stream-policy --policy dma --submit fetch --backend mmio
cargo run -p ai-tensor-cli -- depth-soak --depth 4 --mode latch
cargo run -p ai-tensor-cli -- golden-check
python tools/check_c_abi.py
```

Monorepo host (spawn only, no crate path deps):

```bash
# from monorepo root
bun run build-platform/src/cli/index.ts tensor status
bun run build-platform/src/cli/index.ts tensor test
```


Default backend is **hostless sim**: packs island-compatible 64 B descriptors, AI-3 region checks,
optional INT8 reference GEMM, completion word — enough to exercise the software path **before**
more island RTL.

## Layout

| Path | Role |
|------|------|
| `crates/ai-tensor-abi` | Desc64 / completion / MMIO constants |
| `crates/ai-tensor-ir` | GEMM IR → descriptor |
| `crates/ai-tensor-rt` | Runtime + **sim** device |
| `crates/ai-tensor-cli` | `ai-tensor` binary |
| `crates/ai-tensor-py` | Optional PyO3 native module |
| `python/ai_tensor` | High-level API + `torch_ops` / `tf_ops` |
| `include/ai_tensor.h` | C ABI (Desc64 / completion / MMIO) |
| `frameworks/tensorflow/` | TF attachment notes (out-of-tree C++ later) |
| `profiles/sim-v0.toml` | Version pin profile |

## Cross-connect

Pins and profiles: [`architecture/VERSIONING.md`](architecture/VERSIONING.md).  
Upstream ISA: `../architecture/ai-matrix/isa-encoding.md`.  
Live MMIO: `../corev_apu/ai_island/README.md`.
