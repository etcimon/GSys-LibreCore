# AI island HARD / directed verification map

**Status:** live lab gates green (2026-08-11) · **Package:** `g6lc64_ai` · **TB:** `work-ver-ai`  
**Host entry:** `cva6-build tensor rtl-hard|virt-impl` · **Regress:** `verif/regress/ai-matrix-veri.sh`

This document is the **source of truth for what HARD means** for `ai_island` / `Xg6lcai`: which
directed ELFs exist, which narrow Verilator surfaces run them, and how that maps to software
(soft virt-ai-pcie) vs silicon RTL.

Related: [`frameworks-virt-pcie.md`](frameworks-virt-pcie.md) · [`completion-fifo.md`](completion-fifo.md) ·
[`board-uio-eventfd.md`](board-uio-eventfd.md) · [`scaling-100tops.md`](scaling-100tops.md) ·
monorepo `AGENTS-todo.md` (AI-S3) · `AGENTS-build-platform.md` (tensor host).

---

## 1. Layers (do not conflate)

| Layer | What runs | Gate command | Proves |
|---|---|---|---|
| **soft** | Python `Device(virt-card)` + optional PyTorch | `tensor pytorch` / `virt-impl --impl soft` | Host ABI / frameworks path |
| **HARD narrow** | Variane + 2 directed ELFs | `tensor rtl-hard --suite narrow` | Live SV CAP/CTL + INT8 GEMM |
| **HARD smoke/ci/peak/full** | Variane + curated ELF sets | `tensor rtl-hard --suite …` or `run-ai-matrix-hard-suite.sh` | FIFO / IRQ / desc / scale GEMM |
| **virt-impl hard** | soft → HARD chained | `tensor virt-impl --impl hard --suite narrow` | Software **and** RTL under one host CLI |
| **sv-timing** | FO4 package validate | `--from-timing DIR` on tensor | Structural timing package (not STA) |

**Default pytorch/virt-impl HARD surface is `narrow`** (diag-style ownership of target/tests/library).

---

## 2. Narrow Verilator surfaces (`TENSOR_RTL_SURFACES`)

Owned in `build-platform/src/tooling/tensor.ts` (same idea as `diag` per-test `verilator{}`):

| Suite id | `DV_TARGET` | Library | Directed tests | Typical use |
|---|---|---|---|---|
| **`narrow`** | `g6lc64_ai` | `work-ver-ai` | `ai_island_mmio_smoke` `ai_gemm_s8_smoke` | Default `--rtl-hard` / virt-impl hard |
| **`smoke`** | same | same | + `ai_cpl_fifo_multi_claim` | FIFO multi-claim lab |
| **`ci`** | same | same | 27 ELFs (no 128/256 peak) | CI HARD suite |
| **`peak`** | same | same | `ai_gemm_s8_128x128_smoke` `ai_gemm_s8_256x256_smoke` | Peak wall-time GEMM |
| **`full`** | same | same | `ai-matrix-veri` DEFAULT_TESTS | Full lab |

CLI:

```bash
cva6-build tensor rtl-hard --suite narrow --target g6lc64_ai --ver-library work-ver-ai
cva6-build tensor virt-impl --impl hard --suite narrow --board virt-ai-pcie --core g6lc64_ai --require-hard
cva6-build tensor rtl-hard --tests ai_island_mmio_smoke,ai_gemm_s8_smoke --time-out 8000000
```

Env (also re-exported under WSL by `runRegressUnderWsl`):

| Variable | Role |
|---|---|
| `DV_TARGET` / `AI_TENSOR_CORE` | Config package (`g6lc64_ai`) |
| `AI_MATRIX_VER_LIBRARY` | Variane dir (`work-ver-ai`) |
| `AI_MATRIX_VERI_TESTS` | Space-separated ELF basenames |
| `AI_MATRIX_TIME_OUT` | Max cycles |
| `AI_MATRIX_VERI_REBUILD` | `1` → rebuild harness |
| `AI_TENSOR_RTL_SUITE` | Surface id for logs |

---

## 3. Directed ELF catalog (`verif/tests/custom/ai/`)

Runner: `verif/regress/ai-matrix-veri.sh` (reuse or rebuild `work-ver-ai/Variane_testharness`).

### 3.1 Island MMIO / completion (T2 device)

| Test | Feature | HARD note |
|---|---|---|
| `ai_island_mmio_smoke` | CAP/CTL/doorbell/DONE @ `0x4000_0000` | **narrow** PASS ~1144 cy |
| `ai_cpl_fifo_multi_claim` | CPL FIFO multi-ticket claim order | smoke / CI |
| `ai_irq_plic_smoke` | PLIC source 8 + claim discipline | CI |
| `ai_cap_bringup_smoke` | CAP window geometry | CI |
| `ai_bw_pmu_smoke` | PMU @0x180 | CI |

### 3.2 Descriptor / DMA / enqueue

| Test | Feature | HARD note |
|---|---|---|
| `ai_desc_fetch_smoke` | DMA desc fetch | CI |
| `ai_enq_fetch_smoke` | Enqueue + fetch | CI |
| `ai_enq_sideband_smoke` | T0 enq sideband | CI |
| `ai_dual_enq_poll` | Dual enq / poll | CI |
| `ai_ptr_done_smoke` | ptr_done path | CI |
| `ai_queue_doorbell` | Queue doorbell | CI |

### 3.3 INT8 GEMM compute (I1-lite)

| Test | Feature | HARD note |
|---|---|---|
| `ai_gemm_s8_smoke` | Small INT8 GEMM golden | **narrow** PASS ~1067 cy |
| `ai_gemm_s8_lda_smoke` | lda/ldb stride | CI |
| `ai_gemm_dim_err_smoke` | Dimension error status | CI |
| `ai_gemm_s8_{4,8,16,32,64}x*` | Scale GEMMs | CI |
| `ai_gemm_s8_128x128_smoke` | Peak mid | peak ~21.9k cy |
| `ai_gemm_s8_256x256_smoke` | AccTile full | peak ~83.7k cy |

### 3.4 Core-attached plane (T0/T1 / CSR)

| Test | Feature | HARD note |
|---|---|---|
| `ai_csr_aistatus_xs` | `aistatus.ais` / `mstatus.xs` summary | CI |
| `ai_setcfg_readback` | `aicfg` | CI |
| `ai_illegal_when_off` | Off gate | CI |
| `ai_dot4_s8_smoke` | T0/T1 style | CI |
| `ai_mma_s8_golden` | MMA golden | CI |
| `ai_requant_rhe_golden` | Requant round-half-even | CI |
| `ai_pmu_group4_smoke` | Core PMU AI events | CI |
| `ai_aiperm_umode` | aiperm | CI |

---

## 4. Recorded green results (lab)

| Date | Gate | Result |
|---|---|---|
| 2026-08-10 | narrow HARD (post-FIFO rebuild) | mmio 1144 cy + gemm_s8 1067 cy PASS |
| 2026-08-11 | `AI_MATRIX_HARD_SUITE=ci` | **27/27 PASS** |
| 2026-08-11 | peak 128 + 256 | 21.9k / 83.7k cy PASS |
| 2026-08-11 | `tensor virt-impl --impl hard --suite narrow --require-hard` | soft PASS + hard 2/2 PASS |

Scripts:

- `monorepo-soak/run-ai-tensor-rtl-hard.sh` → narrow default tests  
- `monorepo-soak/run-ai-matrix-hard-suite.sh` → full|ci|smoke|peak  
- `monorepo-soak/run-ai-tensor-virt-impl.sh` → soft[,hard[,timing]]  

---

## 5. Progress vs island track (I0–I4)

| Track | Status | HARD/test coverage |
|---|---|---|
| **I0** sizing / SKU | **Done** (`scaling-100tops.md`) | docs only |
| **I1** one cluster AccTile/PeLanes 256 | **Partial live** | gemm_s8_* + CAP; PE/`tc_sram` cluster still lite |
| **I3-lite** bus/PMU/C-store/multi-out AR | **Live** | bw_pmu, gemm scale, mmio |
| **CPL FIFO** multi-claim | **Live** | `ai_cpl_fifo_multi_claim` |
| **I3** measured memory bandwidth to model | **Open** | need dedicated BW soak beyond PMU |
| **I2** NoC + N clusters + QoS | **Not started** | no multi-cluster directed suite yet |
| **I4** PD / UPF / thermal | **Open** | — |

**Next for clustering/scaling:** keep AccTile/`T`/CAP frozen; measure I3 bandwidth; then I2
cluster replication without breaking narrow/ci HARD bit-identity on the single-cluster path
(see `scaling-100tops.md` §5.1 staging rule).

---

## 6. Acceptance for agents

Before claiming “AI HARD green”:

1. Name the **suite** (`narrow` / `smoke` / `ci` / …), not “the tests”.  
2. Record **target + library + pass/fail counts + cycles** for golden smokes.  
3. Soft virt-ai-pcie alone is **not** SV proof — use `virt-impl --impl hard` or `rtl-hard`.  
4. Do not grow AccTile with TOPS target; cluster count is I2 only.
