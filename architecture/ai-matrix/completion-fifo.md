# Island completion FIFO

**Status:** **RTL landed** (`g6lc_ai_cpl_fifo.sv` + `g6lc_ai_island_top`) · Complements host
`SoftIsland` completion history and `HostRuntime` drain.

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

- [x] Module synthesizable; wired in top
- [ ] Standalone `ai-island-veri` + lab HARD `mmio`/`gemm_s8` still green
- [ ] Optional directed: N completes then N claims
- Timing: push/pop same clock domain; no new async reset/clock

## Non-goals

- Out-of-order retire (still one engine).
- Multi-queue independent engines (I2 cluster track).
