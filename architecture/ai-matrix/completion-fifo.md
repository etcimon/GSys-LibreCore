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
| Doorbell | one-cycle pulse. If the engine is busy or the FIFO is full, the latched doorbell is held and submitted when a slot is free. A newer doorbell replaces that held ticket. A fetch doorbell clears the hold. A sideband kick waiting for the same free slot runs before the held doorbell, and the held doorbell still runs after it. |

## Completion word and FIFO status

The DMA completion word is `{reserved[15:0], status[15:0], ticket[31:0]}`,
written from the GEMM result before the write response comes back.

| What failed | Stored word | FIFO / sticky `0x114` |
|---|---|---|
| GEMM, including a C-store SLVERR | that GEMM status | the same status |
| The completion beat itself | GEMM status (0 when the GEMM succeeded) | `ST_ERR` |

A discarded completion beat can also leave the previous bytes in place. Host
`DmaThenClaim` reads the word and returns the FIFO status. It does not treat
the word's status as the result. A completion-beat failure does not drop a
resident operand. A GEMM or C-store failure does. The QEMU island
model posts the same pair: the guest store keeps the GEMM status, and
the status register shows `ST_ERR` when that beat fails. The guest
store is that GEMM word; it is not rewritten after the beat fails. A
doorbell through the published window still multiplies, stores that
word, and shows `ST_ERR` in the status register. An oversize tile is
the other case: no C is written, and the stored word is status 1. The
virtual card does the same on a 2×2 product: C is 19, 22, 43, 50, the
stored word is status 0, and the FIFO status is `ST_ERR`.

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
- [x] SoC directed multi-claim (ai_cpl_fifo_multi_claim, tickets 20->21->22) HARD PASS (~20k cy)
- [x] HARD suite CI (AI_MATRIX_HARD_SUITE=ci): 27/27 PASS on work-ver-ai post-FIFO (2026-08-11)
- [x] Peak HARD GEMM 128x128 (21938 cy) + 256x256 (83705 cy) PASS (AI_MATRIX_HARD_SUITE=peak, 2026-08-11)
- Timing: push/pop same clock domain; no new async reset/clock

## Non-goals

- Out-of-order retire (still one engine).
- Multi-queue independent engines (I2 cluster track).
