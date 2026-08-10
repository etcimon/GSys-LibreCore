# fixtures

Package-local cosim goldens live as **code** in `crates/ai-tensor-rt/src/cosim.rs`
(`builtin_goldens`) so `cargo test` stays self-contained. The Python dual list in
`tools/cosim_harness.py` (`BUILTIN`) must stay in lockstep.

## Offline dual oracle (always)

```bash
cargo run -p ai-tensor-cli -- golden-check
# or
python tools/ait.py golden --no-harness
```

Runs each golden on **sim** and **SoftIsland** MMIO backends.

## External harness (`AI_TENSOR_COSIM_CMD`)

Concrete adapter (package-local, no monorepo Cargo deps):

```bash
export AI_TENSOR_COSIM_CMD='python3 tools/cosim_harness.py'
cargo run -p ai-tensor-cli -- golden-check
# or
python tools/ait.py cosim
```

Protocol (JSON on stdin → status line on stdout):

| Job | Response |
|-----|----------|
| `{"ping":true}` | `pong ok=1 harness=cosim_harness.py` |
| `{"op":"gemm_s8", m,n,k,a,b,c_expect?}` | `status=0 c_hex=... name=...` |
| `{"op":"suite"}` | pure-Python goldens + cargo dual-oracle |
| `{"op":"rtl_smoke"}` | soft monorepo probe (optional) |

Optional RTL:

```bash
# soft probe (default adapter discovers monorepo-soak/run-ai-tensor-rtl.sh)
AI_TENSOR_RUN_RTL=1 python tools/ait.py cosim --rtl
bash monorepo-soak/run-ai-tensor.sh rtl

# hard: live ai-matrix-veri subset (needs work-ver-ai; long rebuild if missing)
bash monorepo-soak/run-ai-tensor-rtl-hard.sh
# proven pair: ai_island_mmio_smoke + ai_gemm_s8_smoke (PASS on lab host)
```

## Monorepo spawn (does not link RTL into crates)

```bash
bash monorepo-soak/run-ai-tensor.sh test
bash monorepo-soak/run-ai-tensor.sh cosim
bash monorepo-soak/run-ai-tensor.sh golden
```
