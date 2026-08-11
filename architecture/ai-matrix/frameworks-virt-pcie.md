# Framework tests via virtual PCIe AI board (`virt-ai-pcie`)

**Status:** hostless CI path landed · **Board:** `corev-mb/boards/virt-ai-pcie`  
**Core config:** `g6lc64_ai` (ai_island package) · **Host CLI:** `cva6-build tensor …`  
**Package:** `ai-tensor` (no Cargo path dep into monorepo)

This document is the **test map** for validating that **ai-tensor** implements the
software side of **ai_island** features (INT8 GEMM, AccTile, multi-ticket claim,
soft UIO / eventfd, CAP geometry) **through** the virtual PCIe card path that
stands in for the real endpoint (virtio-SSH + BAR4 bulk + UIO).

Related:

| Doc | Role |
|---|---|
| [`board-uio-eventfd.md`](board-uio-eventfd.md) | PLIC-8 / DONE claim / UIO contract |
| [`../uncore/pcie-endpoint.md`](../uncore/pcie-endpoint.md) | Real PCIe BAR / virtio plan |
| [`../../corev-mb/boards/virt-ai-pcie/board.json`](../../corev-mb/boards/virt-ai-pcie/board.json) | Board machine spec |
| [`../../ai-tensor/architecture/FRAMEWORKS.md`](../../ai-tensor/architecture/FRAMEWORKS.md) | Framework attach design |
| [`../../ai-tensor/architecture/HOST.md`](../../ai-tensor/architecture/HOST.md) | build-platform spawn boundary |

---

## 1. What is under test

```text
  PyTorch (optional) / Device API
           │
           ▼
  ai_tensor.Device(backend=virt-card)
           │
     ┌─────┴──────────────────────┐
     │ local                      │ tcp
     ▼                            ▼
 VirtualUioDevice           HostClient ──TCP──► CardAgent
 soft UIO + eventfd         VirtualPcieLink     VirtualUioDevice
 virt://virt-ai-pcie/…                          (card side)
           │                            │
           └────────────┬───────────────┘
                        ▼
              INT8 GEMM ref (ai_island contract)
              AccTile caps · multi-ticket · board_id
```

**Island features exercised (software model of RTL):**

| Feature | How the test hits it | RTL / contract locus |
|---|---|---|
| INT8 GEMM → i32 C | `gemm_s8` / torch `int8` matmul | OP_GEMM, Desc64, `ai_gemm_s8_smoke` |
| AccTile 256 geometry | `Device.caps()` + optional host tile stream | CAP AccTile / I1 freeze |
| Multi-ticket sequential | tickets 20–22 / FIFO claim order | CPL FIFO + DONE @0x10C |
| Soft UIO path | `AI_TENSOR_UIO=virt://virt-ai-pcie/island0` | board-uio-eventfd soft-sticky |
| Virtual PCIe / SSH stand-in | `--virt-mode tcp` CardAgent | pcie-endpoint virtio-SSH |
| Core package selection | `--core g6lc64_ai` → `AI_TENSOR_CORE` | `g6lc64_ai_config_pkg` + island |

**Default `tensor pytorch` is still host-only** (soft virt-card). To also exercise
**SV `ai_island` RTL HARD** and/or **sv-timing**, use the **virtual implementation**
structure (`--impl` / `--rtl-hard` / `tensor virt-impl`) in §2.1a.

---

## 2. Select configuration (board + ai_island core)

### 2.1 Preferred: build-platform `tensor` (no mb required)

```bash
# from monorepo root (build-platform) — soft host only
bun run src/cli/index.ts tensor pytorch \
  --board virt-ai-pcie \
  --core g6lc64_ai

# full hostless gate (virt smoke + frameworks + pytorch)
bun run src/cli/index.ts tensor regress \
  --board virt-ai-pcie \
  --core g6lc64_ai
```

`--board` loads `corev-mb/boards/<id>/board.json` `ai{}` and exports
`AI_TENSOR_BOARD_ID`, `AI_TENSOR_BACKEND=virt-card`, `AI_TENSOR_UIO`, AccTile pins.  
`--core` sets `AI_TENSOR_CORE` / `CVA6_CORE_CONFIG` to the **ai_island** package
(`g6lc64_ai`). Defaults for `pytorch`/`regress`/`frameworks`: board
`virt-ai-pcie`, core `g6lc64_ai` when unset.

### 2.1a Virtual implementation structure (soft + optional SV HARD + sv-timing)

Multi-phase gate that answers three different questions without conflating them:

| Phase | What runs | Answers |
|---|---|---|
| **soft** | `test_torch_virt_ai_island.py` + `run-virt-ai-card.sh` | Does **ai-tensor** / PyTorch match the island **contract** on virt-ai-pcie? |
| **hard** | `run-ai-tensor-rtl-hard.sh` → `ai_island_mmio_smoke` + `ai_gemm_s8_smoke` on **work-ver-ai** | Does **SV ai_island** RTL pass the lab HARD pair under `g6lc64_ai`? |
| **timing** | re-check env package after host `applyFromTimingFlags` + FO4 dashboard | Is a **sv-timing** precompile package structurally valid for this core? (**not STA**) |

```text
  tensor pytorch|virt-impl --board virt-ai-pcie --core g6lc64_ai
           │
           ├─[--impl soft]──────────► soft only          (default CI)
           ├─[--impl hard|--rtl-hard]► soft → hard
           └─[--impl full --from-timing DIR]
                                      soft → hard → timing
```

```bash
# Soft + SV HARD (needs work-ver-ai; soft-skips hard if missing unless --require-hard)
bun run src/cli/index.ts tensor pytorch \
  --board virt-ai-pcie --core g6lc64_ai --rtl-hard

# Full virtual implementation + sv-timing package (like test --from-timing)
bun run src/cli/index.ts tensor virt-impl \
  --impl full \
  --board virt-ai-pcie \
  --core g6lc64_ai \
  --from-timing workspace/build/sv-timing/host-g6lc64_ai

# Same via pytorch:
bun run src/cli/index.ts tensor pytorch \
  --impl full \
  --board virt-ai-pcie --core g6lc64_ai \
  --from-timing workspace/build/sv-timing/host-g6lc64_ai \
  --require-hard

# Expert: export corrected flist env (does not auto-merge into core/)
bun run src/cli/index.ts tensor virt-impl --impl hard \
  --from-timing workspace/build/sv-timing/host-g6lc64_ai --use-emit
```

| Flag / env | Role |
|---|---|
| `--impl soft\|hard\|full\|hard-only` | Phase set (`hard` = soft+hard; `full` adds timing) |
| `--rtl-hard` | Include HARD after soft (pytorch convenience) |
| `--require-hard` | Fail if `work-ver-ai` missing (else soft-skip hard) |
| `--suite\|--rtl-suite narrow\|smoke\|ci\|peak\|full` | **Narrow HARD surface** (diag-style target/tests/library) |
| `--target\|--core g6lc64_ai` | `DV_TARGET` / config package for Verilator sim |
| `--tests LIST` | Override directed ELF basenames |
| `--ver-library work-ver-ai` | Variane library dir |
| `--time-out N` | `AI_MATRIX_TIME_OUT` cycles |
| `--rebuild` | `AI_MATRIX_VERI_REBUILD=1` |
| `--from-timing DIR` | Host: `applyFromTimingFlags` + FO4 dashboard; child: `CVA6_FROM_TIMING` |
| `--use-emit` | Expert corrected flist env (`CVA6_TIMINGS_USE_EMIT=1`); needs `--from-timing` |
| `--require-timing` | Fail timing phase if no FROM_TIMING |

**HARD surfaces** (`TENSOR_RTL_SURFACES` in `build-platform/src/tooling/tensor.ts`) mirror
diag’s per-test `verilator{}` ownership: each suite pins `target`, `verLibrary`, `tests`,
`timeOut` instead of a monolithic sim config.

| Suite | Tests | Use |
|---|---|---|
| `narrow` (default) | `ai_island_mmio_smoke` + `ai_gemm_s8_smoke` | pytorch `--rtl-hard` |
| `smoke` | + `ai_cpl_fifo_multi_claim` | lab FIFO path |
| `ci` / `peak` / `full` | hard-suite maps | longer gates |

**Orchestrator:** `monorepo-soak/run-ai-tensor-virt-impl.sh`  
**Honest split:** soft never loads Verilator; hard never runs PyTorch inside the TB;
timing never claims STA sign-off.  
**WSL note:** `runRegressUnderWsl` re-exports `AI_TENSOR_*` / `AI_MATRIX_*` / `CVA6_FROM_TIMING`
explicitly (Bun Windows env is not inherited).

### 2.2 Optional: `mb select` then tensor

```bash
bun run src/cli/index.ts mb select virt-ai-pcie
# writes corev-mb/boards/virt-ai-pcie/generated/ai-tensor.env (+ dtsi/profile)
source corev-mb/boards/virt-ai-pcie/generated/ai-tensor.env   # if present
bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai
```

`mb select` adapts `soc.coreConfig` to the board’s core (`g6lc64_ai` for
virt-ai-pcie) and generates AI env/profile artifacts — see
`AGENTS-motherboard.md` + `build-platform/src/tooling/ai-board.ts`.

### 2.3 Direct soak scripts

```bash
bash monorepo-soak/run-ai-tensor-pytorch.sh
bash monorepo-soak/run-ai-tensor.sh pytorch
bash monorepo-soak/run-ai-tensor.sh regress
AI_TENSOR_REQUIRE_TORCH=1 bash monorepo-soak/run-ai-tensor-pytorch.sh   # fail if no torch
```

---

## 3. Test artifacts

| Artifact | Role |
|---|---|
| `ai-tensor/python/tests/test_torch_virt_ai_island.py` | **Structured** unittest: GEMM, AccTile stream, multi-ticket, env, local+tcp |
| `ai-tensor/python/examples/torch_virt_card_smoke.py` | Thin smoke example |
| `ai-tensor/tools/frameworks_regress.py` | Multi-framework harness (device/numpy/torch/tf) |
| `ai-tensor/tools/virt_ai_card/` | Virtual UIO, eventfd, CardAgent, HostClient |
| `monorepo-soak/run-ai-tensor-pytorch.sh` | Monorepo adapter for pytorch suite (soft) |
| `monorepo-soak/run-ai-tensor-virt-impl.sh` | **Multi-phase** soft → HARD → timing orchestrator |
| `monorepo-soak/run-ai-tensor-rtl-hard.sh` | SV HARD mmio+gemm_s8 on work-ver-ai |
| `monorepo-soak/run-ai-tensor-frameworks.sh` | Frameworks harness adapter |
| `monorepo-soak/run-ai-tensor-regress.sh` | Full hostless gate |
| `build-platform` `tensor pytorch\|virt-impl\|frameworks\|regress` | Host CLI + `--board`/`--core`/`--impl`/`--from-timing` |

### 3.1 PyTorch suite classes

| Class | Covers |
|---|---|
| `TestAiIslandGemmThroughVirtPcie` | env/core select, 2×2 golden, random match torch.mm, multi-ticket |
| `TestAiIslandAccTileThroughVirtPcie` | single-tile meta; forced multi-tile stream |
| `TestAiIslandVirtualPcieLink` | TCP CardAgent path vs torch |
| `TestAiIslandDeviceEnvPropagation` | `Device.from_env()` + UIO virt:// |
| `TestVirtCardDeviceWithoutTorch` | **Always-on** Device golden local+tcp (CI without torch wheels) |

Without PyTorch installed the Device cases still **PASS** (exit 0).  
`AI_TENSOR_REQUIRE_TORCH=1` or `--require-torch` makes missing torch a hard fail.

---

## 4. Env contract (host → package)

| Variable | Example | Set by |
|---|---|---|
| `AI_TENSOR_BOARD_ID` | `virt-ai-pcie` | `--board` / board.json / `mb select` env |
| `AI_TENSOR_BACKEND` | `virt-card` | board soft-sticky / `--backend` |
| `AI_TENSOR_CORE` | `g6lc64_ai` | `--core` |
| `AI_TENSOR_UIO` | `virt://virt-ai-pcie/island0` | board `ai.uioConnectors` |
| `AI_TENSOR_VIRT_MODE` | `local` \| `tcp` \| `auto` | `--virt-mode` |
| `AI_TENSOR_ACC_TILE_*` / `AI_TENSOR_MACS` | `256` | board `ai{}` |
| `CVA6_FROM_TIMING` / `FROM_TIMING` | timings out-dir | `--from-timing` preflight |
| `AI_TENSOR_REQUIRE_TORCH` | `1` | optional hard torch gate |

Package never path-depends monorepo crates (KD0). Spawn only via soak scripts.

---

## 5. Acceptance

| Gate | Command | Expect |
|---|---|---|
| Device virt-card (soft) | `tensor pytorch --board virt-ai-pcie --core g6lc64_ai` | Device local+tcp golden PASS; torch classes if installed |
| Frameworks | `tensor frameworks --board virt-ai-pcie --core g6lc64_ai` | device (+ numpy/torch/tf soft-skip) |
| Full hostless | `tensor regress --board virt-ai-pcie --core g6lc64_ai` | virt smoke + frameworks + pytorch |
| Soft + SV HARD | `tensor pytorch --rtl-hard --board virt-ai-pcie --core g6lc64_ai` | soft PASS + HARD mmio/gemm_s8 (or hard SKIP if no work-ver) |
| Full virt-impl + timing | `tensor virt-impl --impl full --from-timing <pkg> --core g6lc64_ai` | soft → hard → timing; FO4 dashboard on host |
| Lab HARD only | `tensor rtl-hard` | mmio + gemm_s8 on work-ver-ai |

**Pass criteria for frameworks path:** all run Device cases green; when torch is
present, every `TestAiIsland*` case matches torch int32 matmul of int8 inputs
and reports `board_id=virt-ai-pcie` with AccTile/Macs 256.

**Pass criteria for HARD phase:** `ai_island_mmio_smoke` + `ai_gemm_s8_smoke` SUCCESS
under `AI_TENSOR_CORE=g6lc64_ai` / `work-ver-ai` (same as historical lab gate).

---

## 6. Next (not this gate)

- Live `/dev/uio*` + eventfd on Variane/FPGA (`board-uio-eventfd.md` § kernel)
- `torch.ops.ai_tensor.gemm_s8` C++ extension (`frameworks/torch/`)
- TensorFlow C++ custom op (M6b); XLA custom call later
- Wire real PCIe BAR4 when `verilog-pcie` endpoint is in flist
