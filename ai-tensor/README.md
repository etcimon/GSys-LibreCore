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

# Structured PyTorch validation via virtual PCIe board (virt-card / ai_island features)
PYTHONPATH=python:tools python python/tests/test_torch_virt_ai_island.py

# CLI
cargo run -p ai-tensor-cli -- doctor
cargo run -p ai-tensor-cli -- sim-gemm --m 4 --n 4 --k 4
cargo run -p ai-tensor-cli -- stream-gemm --m 4 --n 4 --k 4
cargo run -p ai-tensor-cli -- queue-soak --backend mmio
cargo run -p ai-tensor-cli -- irq-soak --backend mmio
cargo run -p ai-tensor-cli -- stream-policy --policy dma --submit fetch --backend mmio
cargo run -p ai-tensor-cli -- depth-soak --depth 4 --mode latch
cargo run -p ai-tensor-cli -- history-soak --n 4 --backend mmio
cargo run -p ai-tensor-cli -- probe --profile profiles/island-p3-v1.toml
cargo run -p ai-tensor-cli -- host-run --jobs 3 --backend sim
cargo run -p ai-tensor-cli -- golden-check
python tools/check_c_abi.py
```

Monorepo host (spawn only, no crate path deps):

```bash
# from monorepo root — select virt board + ai_island core package
bun run build-platform/src/cli/index.ts tensor status
bun run build-platform/src/cli/index.ts tensor pytorch \
  --board virt-ai-pcie --core g6lc64_ai
bun run build-platform/src/cli/index.ts tensor regress \
  --board virt-ai-pcie --core g6lc64_ai
# optional: --from-timing <timings-out-dir>  (diag-style preflight)
```

Test map: `../architecture/ai-matrix/frameworks-virt-pcie.md`.


Default backend is **hostless sim**: packs island-compatible 64 B descriptors, checks
AI-3 regions, and executes a reference GEMM with completion reporting. Its default
grant remains INT8-only; discovered device grants are not replaced by software capabilities.

## Native formats and current status

The package uses **descriptor v2**: A `[m][k]`, native B `[n][k]`, and element-count
strides `lda/ldb >= k`. Public `A @ B` APIs preserve conventional matrix semantics
by transposing/repacking B at the boundary. Old v1 profiles/buffers are refused,
not silently reinterpreted; retained profile filenames contain explicit v2 pins.

Rust SimDevice/SoftIsland and the independent Python reference support signed
INT4/INT8, FP8 E4M3/E5M2, FP16, BF16 and FP32. Integer C wraps in i32; floating C
uses ordered, separate binary32 multiply/add with canonical NaN output. The
`software-reference-v2.toml` mask `0x00fb` is an explicit reference profile, not a
hardware grant. SP24 and unsupported arithmetic modes are refused. Legacy
INT/EW1 descriptors require the effective INT4 grant before any computed C write.

```python
from ai_tensor.numfmt import gemm_native

c32 = gemm_native(bytes([1, 2]), bytes([3, 4]), 1, 1, 2, numfmt=0, dtype_mask=1)
assert int.from_bytes(c32, "little", signed=True) == 11
```

For device submission, use `Device.gemm_native` or `QemuUioSession.gemm_native`
with native buffers and the discovered format mask. Generic Torch/NumPy paths
preserve matching source dtypes; they do not quantize unsupported input to INT8.
NumPy coverage skips explicitly when unavailable. TensorFlow remains S8-only,
virtual-card native-byte transport is not implemented, and non-S8 multi-tile
streaming and extension import/runtime validation remain open.

### Optimization path and verification

Keep native numerical/layout correctness separate from scheduling. The optional
host adapter compares this package's reference bytes with a separately built
`g6lc_qemu tensor-eval`, then exports successful work for RTL policy replay.
Neither package links the other, and reference support does not enable floating
GEMM in the physical island. The next hardware-facing step is validated format-aware
load/store and accumulation, followed by guarded policy consumption and measured
memory/compute utilization—not silent precision reduction.

`python tools/ait.py test` passes ABI lockstep, 5 ABI / 10 IR / 48 runtime tests,
external local cosim ping/job, Python reference tests (16 run, one optional NumPy
skip), 22 QEMU-UIO protocol tests and PyTorch smoke. The virtual-card local/TCP
smoke also passes unsupported-mode rejection. These are software/protocol checks,
not an RTL or QEMU guest benchmark. On Windows the external harness needs `sh`
on the child PATH; Git's `usr/bin` supplies it. Pinned PyO3 0.22.6 rejects Python
3.14; typechecking passed with an existing Python 3.11 interpreter without bypassing
that check. See [runtime](architecture/RUNTIME.md) and [versioning](architecture/VERSIONING.md).

## Layout

| Path | Role |
|------|------|
| `crates/ai-tensor-abi` | Desc64 / completion / MMIO constants |
| `crates/ai-tensor-ir` | GEMM IR → descriptor |
| `crates/ai-tensor-rt` | Runtime + **sim** device |
| `crates/ai-tensor-cli` | `ai-tensor` binary |
| `crates/ai-tensor-py` | Optional PyO3 native module |
| `python/ai_tensor` | High-level API + `torch_ops` / `tf_ops` / `virt_card` |
| `python/tests/test_torch_virt_ai_island.py` | Structured PyTorch + Device suite via virt-ai-pcie |
| `tools/virt_ai_card/` | Virtual PCIe UIO / CardAgent / HostClient |
| `include/ai_tensor.h` | C ABI (Desc64 / completion / MMIO) |
| `frameworks/torch/` | Torch attachment notes |
| `frameworks/tensorflow/` | TF attachment notes (out-of-tree C++ later) |
| `profiles/sim-v0.toml` | Version pin profile |

## Cross-connect

Pins and profiles: [`architecture/VERSIONING.md`](architecture/VERSIONING.md).  
Upstream ISA: `../architecture/ai-matrix/isa-encoding.md`.  
Live MMIO: `../corev_apu/ai_island/README.md`.
