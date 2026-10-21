# g6lc_lsq — analysis (T1, loop + latency)

<!-- hyp8-status -->
> **Status: indicative, subject to further information.** Goal: **8 FO4 per
> cycle (5 GHz nameplate at `fo4_ps = 20`, margin 0.2)**. Every FO4 figure,
> stage count and kernel size here is a hypothesis read from the original RTL,
> the prior boards and the sv-timing reports (`reports/board.md`,
> `cut_surface.md`, `bottlenecks.md`, `carry_over.md`, `propagation.md`,
> `refusals.md`); the fresh 8-FO4 board's deciding value `D` is in
> `analysis/cut-ledger.md` and `analysis/coverage.md`. The cut-minimization
> protocol (`analysis/cut_minimization.md`) takes precedence over any planned
> cut listed below. Nothing here has been linted, simulated or measured on a
> board; a rewritten file may follow this analysis, the emitted sv-timing file
> (as-is or adapted), or the original RTL, as `coverage.md` records.


Source of logic: `core/ooo/g6lc_lsq.sv` (661 lines). Board: 216.9 structural (reg→out into `ld_d`/`st_d`, generate-loop cone) / 104.2 adjusted. Contract §1: entries allocated at dispatch, live AGU addresses, store data, CAM/STL hazard verdict, alias validation (`mem_violation`); a store entry is the reservation of its speculative-queue slot and lives until commit; a completed load stays until no older store is unresolved. §2: age = `ooo_age_older/ooo_age_dist` vs `commit_ptr_i`. §3: kill = `cancelled_mask_i[id]`, `flush_i`; violation → scoreboard `cancelled + replay`, commit refetch.

## 1. State and writers

| State | Writers (single `always_comb` → `st_d`/`ld_d`) | Note |
|---|---|---|
| `st_q[ST]` (valid, addr_v, data_v, id, hart, addr, data, size) | alloc (lowest free, per port p in program order), AGU addr update (by id, NR_UPDATE ports), store-data update (by id), `PHYS_VALIDATE` physical update, commit release (by id, NrCommitPorts), cancel (by `cancelled_mask_i[id]`), flush | composed; the by-id updates are ST-wide compares each |
| `ld_q[LD]` (valid, addr_v, done, id, hart, addr, size, pc) | alloc, AGU addr update, complete → `done`, release when no older unresolved store (ST-wide age scan per load, reads `st_d` — i.e. *this cycle's* store updates), commit (PHYS), cancel, flush | **loop-carried**: `ld_d[i].valid` depends on `st_d[j]` of the same cycle |

Combinational outputs (from registered state + live inputs): `st_live_mask_o`, `st_unresolved_mask_o`, `st_hart_mask_o`, `store_pending_o`, `lsq_busy_o` (registered state only); STL query (`ld_query_*` live: ST-wide age + lane compare → youngest-store tournament → `stl_forward_o/stl_data_o/stl_stall_o`); violation scan (live `addr_valid_i[u]` store address vs every load's address — including loads whose address arrives *this cycle* on another update port — → oldest-violation tournament → `mem_violation_*`).

## 2. Execution paths

| Event | Chain | Cost | Reaches |
|---|---|---|---|
| AGU store address arrives (`addr_valid_i[u] && addr_is_st_i`) | id → entry (ST compares) → `st_d.addr`; same cycle: violation scan over LD entries (hart lookup by id over ST, per-load same_word + lane overlap + age compare, other-port load address override) → tournament → `mem_violation_o/id/pc` | ST + LD compares, LD age compares, 2 tournaments | scoreboard (cancel+replay, same cycle), memdep train |
| AGU load address arrives | id → entry → `ld_d.addr`; the load's own STL query is the live `ld_query_*` port the same cycle (from `load_unit`) | ST compares + lane + age → tournament | `load_unit` (stall/forward, same cycle) |
| store data arrives | id → entry | ST compares | — |
| WB complete | `done`; release scan (`st_d` after this cycle's updates) | ST age compares per LD | next state |
| commit store | release by id | ST compares | `st_live_mask_o` → IQ gate (same cycle, through registered state next cycle) |
| cancel/flush | masks | — | — |

The 216.9 structural cone is `addr_valid_i` → store hart lookup → violation scan with per-load override → tournament → `mem_violation_*` and, in the same block, the release scan reading `st_d`.

## 3. Callers and callees

| Port | Reader | Kind | Kill | Tolerance |
|---|---|---|---|---|
| `stl_stall_o`, `stl_forward_o`, `stl_data_o` | `load_unit` (issue of the load; stall gates the request) | comb | — | the load unit already waits on `stl_stall_o`; +N cycles = +N load latency |
| `mem_violation_o/id/pc` | `scoreboard` (cancel+replay), `g6lc_memdep` (train) | comb → flop | the scoreboard marks the slot `replay`; commit drops | a later report is fine as long as it arrives before that load commits (checked bit) |
| `st_live_mask_o`, `st_unresolved_mask_o`, `st_hart_mask_o` | `g6lc_iq` legality, `store_buffer` | comb on registered state | — | one cycle late is conservative |
| `store_pending_o`, `lsq_busy_o`, `ld_full_o/st_full_o/ld_free_o/st_free_o` | dispatch `can_go`, drained seam, `mem_stall` | comb on registered state | — | — |
| `phys_pending_o/phys_replay_o` | scoreboard (COH_OOO only; off in hyp8's WT config? — `CohPolicy` check in Phase 3; keep ports) | — | — | — |

## 4. Functional separation

| Block | In | Out | State | Kernel / stage | Cost |
|---|---|---|---|---|---|
| `g6lc_lsq_alloc` | `ld/st_alloc_i`, ids, harts, pcs | slot writes, `free` counts | free bitmaps | stage (lowest-free isolate per port, as today) | 5 FO4 |
| `g6lc_lsq_event` | `addr_valid_i`, `st_data_valid_i`, `complete_valid_i`, `commit_st_i`, `phys_*` | **registered event records** (kind, id, addr, size, data, hart) — one register per port | event queue (depth 1 per port, with `cancelled_mask`/`flush` kill) | stage | 3 FO4 |
| `g6lc_lsq_slot` (per entry) | event records (by id compare, 1 per port), cancel bit, release bit | entry fields | entry | stage: id compare (5-bit, 1.5 FO4) + field write | 4 FO4 |
| `g6lc_lsq_cam_bank` × 2 (loads) / × 2 (stores) | event address, 4 entry addresses | 4 match bits (same_word & lane overlap & hart) | — | kernel-free pipeline step 1 | 6 FO4 (addr compare 56 b ≈ 4 + lane AND) |
| `g6lc_lsq_age` | event id, 4 entry ids, `commit_ptr` | 4 older bits | — | pipeline step 2 (age dist + compare, 5-bit) | 5 FO4 |
| `g6lc_lsq_reduce` | per-bank match∧older vectors | candidate set + youngest/oldest tournament over 8 | — | pipeline step 3 | 6 FO4 |
| `g6lc_lsq_verdict` | reduce result + data_v bits | `stl_stall/forward/data`, `mem_violation_*`, `checked` | registered outputs | pipeline step 4 | 4 FO4 |
| `g6lc_lsq_release` | `done` bits, per-load "older unresolved store" mask (**registered**, updated by the event stream: set at alloc from `st_unresolved_mask`, cleared when the named stores resolve) | `valid` clear | per-load mask [ST] | stage; replaces the live `st_d` scan | 3 FO4 |
| `g6lc_lsq_publish` | verdict per load id | `ld_checked_o[NR_SB]` (new output) | per-slot checked bits | stage | 2 FO4 |

Boundary moves: the STL *data* forward belongs to `store_buffer` (contract: the LSQ is the hazard decision only) — keep `stl_data_o` as observability. New output `ld_checked_o` to the scoreboard/commit (M8): a load may commit only when its final verdict has been produced (no older store unresolved at verdict time, or a violation reported). New output `replay_o` for the IQ speculative-wakeup re-arm (same event as `mem_violation_o` plus "verdict = wait" for a load that was speculatively woken).

## 5. Latency and throughput target

- Load hazard verdict: today same cycle as the AGU address (`stl_stall_o` combinational); hyp8: 3 cycles after the address event (event reg → CAM → age/reduce → verdict). The load's D$ access proceeds speculatively in parallel (the load unit no longer waits on `stl_stall_o` to *issue* the request; it waits on the verdict to *publish* — the result is held in the load unit's response stage or replayed). Net load-use latency: +2 vs today when the verdict is "no hazard" (the D$ hit path at 8 FO4 is 4–5 cycles anyway, so the verdict arrives before the data).
- Violation detection: 3 cycles after the store address event (today: same cycle). Bound: a violating load cannot commit before the verdict because of the checked bit; the window during which younger dependents may have consumed stale data is what the existing replay (cancel + refetch from the load's PC) already covers.
- Throughput: one address event per update port per cycle, no stalls on events (the event register is a pipeline, not a queue: back-pressure never needed because each port delivers at most one event per cycle).
- Cost: event/candidate/verdict registers (~2 × (PLEN+XLEN+ID) bits per port + per-load ST-bit masks), +2 load-use in the no-hazard case, +3 violation latency.

## 6. Decision

Files (new): `core/ooo/g6lc_lsq.sv` (wrapper with the old ports + `ld_checked_o`, `replay_o`), `g6lc_lsq_event.sv`, `g6lc_lsq_slot.sv`, `g6lc_lsq_cam_bank.sv`, `g6lc_lsq_age.sv`, `g6lc_lsq_reduce.sv`, `g6lc_lsq_verdict.sv`, `g6lc_lsq_release.sv`. `HypCfg`: `LsqCamBanks` (2+2), `LoadUseExtra` (consumed by the load unit and the IQ latency class).

Kill identities: every event register and candidate carries its id; `cancelled_mask_i[id]` kills it in place (the slot write and the verdict are suppressed); `flush_i` clears all pipeline registers and entries; a verdict for a cancelled load produces no `mem_violation` and no `checked`.

Expected `// hyp8:` departures: (1) `stl_stall_o`/`stl_forward_o` become registered, 3 cycles after the query, and the load unit is rewritten to issue speculatively and publish on `ld_checked`; (2) `mem_violation_*` registered (+3); (3) release uses a registered per-load unresolved-store mask instead of the live `st_d` scan (conservative: a load may stay one cycle longer).
