# Island completion FIFO

**Status:** implemented, with source-bound correctness repairs under qualification.
The historical SoC results below do not qualify the later admission/datapath changes.
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
| Push | engine completion, retained fetch error, or retained pre-fetch refusal; error records retain their own ticket/status until accepted |
| Pop | write `0x10C` bit0 (claim) |
| `0x10C` sticky | `!empty` |
| `0x110/0x114` | FIFO **head** (oldest unclaimed) |
| `irq_o` | sticky && head.irq |
| Doorbell | one-cycle pulse. If the engine is busy or the FIFO is full, the latched doorbell is held and submitted when a slot is free. A newer doorbell replaces that held ticket. A fetch doorbell clears the hold. A sideband kick waiting for the same free slot runs before the held doorbell, and the held doorbell still runs after it. |

### Current conservation boundaries (2026-09-28)

The FIFO accepts push on full only when a valid pop occurs in the same cycle. That
replacement keeps occupancy constant. Pop on empty has no effect; push on empty with
pop still creates one entry. Pointers wrap explicitly for non-power-of-two depths and
stay at zero for depth one. The count width must represent the configured depth.

Pending latch submissions own descriptor snapshots. A successfully read descriptor
keeps its issued qid/ticket and has a retained engine-submission slot; a later doorbell
cannot rename that fetch. New compute submission waits while a descriptor fetch owns
the DMA path. FIFO-full refused/failing fetch records are retained rather than emitted
as lossy pulses. Software still must not infer unlimited admission from a doorbell
write: legacy pending replacement remains, and there is no complete sideband ready/
credit contract yet. The UIO bring-up session intentionally serializes ownership.

The directed remote suite covers full-FIFO retention, mutated latch data, and a second
latch doorbell while descriptor R beats are deliberately held. The independent FIFO
scoreboard checks ticket/status/IRQ/count and pointer bounds at depths 1, 3 and 16.
Depth one has bounded safety; depths 3 and 16 have reset base cases plus inductive
stored-order/pointer/count safety, a ticket-bit negative control and reached full
replacement. The original direct depth-16 bounded run timed out and is not proof evidence. DMA synthesis at reduced
8-MAC geometry has no latches/SCCs; aggregate-AXI Verilator findings, full admission,
reset/error-drain, live geometry and SoC/physical qualification remain open. Exact run
identities and invalidated observer experiments are recorded in `log-2026-09.md`.

## Queued command extension v1 (integration candidate; default off)

`IslandCfg.CommandDepth=0` preserves legacy behavior and publishes zero at CAP `0x0090`.
A nonzero depth enables a 128-bit descriptor-pointer command FIFO through registered
`tc_sram`; CAP `0x0090` is `{depth[15:0], version[7:0]=1, flags[7:0]=7}` (present,
pointer-only, sideband-ready). Desc64 v2 and the completion word are unchanged. This
extension stays outside `cva6_cfg_t`. The queue context windows must end before `0x0f00`.

| Offset | Queued-mode register |
|---|---|
| 0x0f20 | MODE bit0; reset0, change only after commands, active work and completions drain |
| 0x0f24 / 0x0f28 | descriptor pointer low/high staging |
| 0x0f2c | full 32-bit ticket staging |
| 0x0f30 | qid staging, low8 bits |
| 0x0f34 | SUBMIT bit0; one attempt, never an implicit retry |
| 0x0f38 | current free command slots; advisory, not a reservation |
| 0x0f3c / 0x0f40 | last MMIO attempt ticket / receipt: 0 accepted, 1 full or lost arbitration, 2 disabled |
| 0x0f44 / 0x0f48 | accepted / rejected MMIO attempt counters, wrapping u32 |

A software owner serializes MMIO staging/receipt access. Only receipt0 transfers buffer
ownership; descriptor and operand storage stays alive and immutable until completion.
Sideband uses held VALID/READY and transfers on their conjunction, with round-robin
arbitration against simultaneous MMIO attempts. Its ticket is returned by the core adapter
only after acceptance. Credit reads alone cannot authorize release/reuse of a buffer.
Zero queued descriptor pointers are rejected; they never mean the legacy latch.

Mode changes require quiescence and entering queued mode requires CTL.enable. While queued
mode is enabled, CTL, AI-3 region, legacy doorbell and reuse/policy configuration writes are
rejected with APB slave error and have no effect. Thus queued requests retain their protection
context. Staging registers remain writable and each accepted tuple owns its values. Dispatch
is single-engine and reserves completion room before consuming the FIFO head; errors retain
the accepted ticket. Completed work must be claimed to allow a full completion FIFO to drain.

Capability zero forbids use of these registers. No live package enables this candidate until
RTL/runtime/emulator acceptance, fairness, refusal, mutation and reset tests qualify it.

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
