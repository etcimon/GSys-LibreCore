# Island completion FIFO

**Status:** **RTL landed + SoC HARD green** (`g6lc_ai_cpl_fifo.sv` + `g6lc_ai_island_top`) ·
Complements host `SoftIsland` completion history and `HostRuntime` drain.

**HARD (post-FIFO, 2026-08-10):** `work-ver-ai/Variane_testharness` rebuilt with CPL FIFO;
`AI_TENSOR_RTL_HARD=1 AI_MATRIX_VERI_REBUILD=0` → `ai_island_mmio_smoke` (1144 cy) +
`ai_gemm_s8_smoke` (1067 cy) **PASS** (`pass=2 fail=0`).

## Problem

The island used a **single** DONE sticky (overwrite). Host software therefore risked
losing intermediate completions if SW did not claim between jobs.

## Implementation

| Item | Value |
|---|---|
| Module | `corev_apu/ai_island/g6lc_ai_cpl_fifo.sv` |
| Depth | `min(IslandCfg.QueueDepth, 16)` (min 4 if QueueDepth=0) |
| Push | engine `done_valid` or DMA fetch error |
| Pop | write `0x10C` bit0 (claim) |
| `0x10C` sticky | `!empty` |
| `0x110/0x114` | FIFO **head** (oldest unclaimed) |
| `irq_o` | sticky && head.irq |

## Host software

| Mechanism | Role |
|---|---|
| SoftIsland FIFO head + history | Mirrors claim/pop semantics |
| `soak_history_poll` | Multi-ticket observability |
| `HostRuntime` | Host job queue; engine still single-outstanding compute |

## Acceptance

- [x] Module synthesizable; wired in top (`Makefile` flist + standalone)
- [x] Standalone `ai-island-veri` green (incl. multi-claim directed: tickets 20→21→22)
- [x] Full SoC HARD rebuild + `ai_island_mmio_smoke` + `ai_gemm_s8_smoke` (lab; 2026-08-10)
- Timing: push/pop same clock domain; no new async reset/clock

## Non-goals

- Out-of-order retire (still one engine).
- Multi-queue independent engines (I2 cluster track).
