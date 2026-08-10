# Island completion FIFO (future RTL)

**Status:** scaffold / design note · **Not compiled** · Complements host
`SoftIsland` completion history and `HostRuntime` drain.

## Problem

`g6lc_ai_island_top` keeps a **single** DONE sticky (`done_sticky_q` + ticket/status
hold). Host software therefore must **submit → wait → next**. Concurrent
multi-outstanding tickets need a hardware completion FIFO.

## Host today (software)

| Mechanism | Role |
|---|---|
| SoftIsland `comp_history` | Ring of last `queue_depth` completions for poll-by-ticket |
| `soak_history_poll` | Validates multi-ticket observability after sticky moves |
| `HostRuntime` | Host FIFO of jobs; still drains one engine job at a time |

## Proposed RTL (when scheduled)

1. Parameter `CplFifoDepth` (default = CAP `queue_depth`, e.g. 4).
2. On engine `done_valid`: push `{ticket, status}` into FIFO; assert sticky if non-empty.
3. DONE claim (write `0x10C`): pop head (or clear sticky only when empty).
4. Optional MMIO: read sideband history index (debug); keep ABI of `0x110/0x114` as **head**.
5. CAP: advertise `queue_depth` = FIFO depth (already exposed).

## Acceptance

- Directed: N sequential doorbells without host wait between submits, then claim N times.
- No change to single-job smokes (`ai_gemm_s8_smoke`, PLIC-8).
- Timing: FIFO push on same edge as today sticky set; no new async clock.

## Non-goals

- Out-of-order retire (still one engine).
- Multi-queue independent engines (I2 cluster track).
