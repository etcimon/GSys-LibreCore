# ai-tensor

Host software package: **PyTorch / TensorFlow backend** for LibreCore **`Xg6lcai` / `ai_island`**.

Architecture (M0): [`architecture/README.md`](architecture/README.md) · Agent entry: [`AGENTS.md`](AGENTS.md)

## Quick start (sim — no RTL)

```bash
cd ai-tensor
# Rust tests + Python smoke
python tools/ait.py test

# High-level PyTorch (optional: pip install torch)
PYTHONPATH=python python python/examples/torch_island_smoke.py

# CLI
cargo run -p ai-tensor-cli -- doctor
cargo run -p ai-tensor-cli -- sim-gemm --m 4 --n 4 --k 4
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
| `python/ai_tensor` | High-level API + `torch_ops` |
| `profiles/sim-v0.toml` | Version pin profile |

## Cross-connect

Pins and profiles: [`architecture/VERSIONING.md`](architecture/VERSIONING.md).  
Upstream ISA: `../architecture/ai-matrix/isa-encoding.md`.  
Live MMIO: `../corev_apu/ai_island/README.md`.
