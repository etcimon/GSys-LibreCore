# g6lc_rename (+ g6lc_rat, g6lc_freelist, g6lc_bp_ckpt coupling) — analysis (T1, loop + latency)

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


Source of logic: `core/ooo/g6lc_rename.sv` (906 lines; map/amap per hart, shared `free_q`/`busy_q`, split FP class, `CKPT_DEPTH` ring of checkpoints, A147 recovery repair). Board: 130.4 structural (in→out, `valid_i … → prd_o`) / 115.1 adjusted. Contract §1: architectural→physical maps per hart, checkpoints per branch, busy bits; §3: mispredict restores map/free/busy from the branch's checkpoint level (`mispredict_level_i` via the dispatch `tid_ckpt` table), `flush_i` restores from `amap`, `flush_hart_i` per hart.

## 1. State and writers

| State | Writers (one `always_comb`) |
|---|---|
| `map_q[NH][32]` (speculative map) | per-port write of `prd` for `need_rd` lanes (later lanes override earlier), mispredict restore from checkpoint, flush restore from `amap_q`, per-hart flush |
| `amap_q[NH][32]` (architectural map) | `commit_valid_i` per commit port (younger port wins) |
| `free_q[PRF]` | allocate (lowest-free isolate per lane, lanes serial), `free_i` at commit (old physical), mispredict restore (free set at checkpoint ∪ frees since — the A147 repair), flush rebuild from `amap` |
| `busy_q[PRF]` | set on allocate, cleared on `wb_valid_i` (per WB port), restore on recovery |
| checkpoint ring (`CKPT_DEPTH` × {map, free, busy}) | push on `is_branch_i` lanes, retire on `ckpt_retire_i`, unwind on mispredict |
| FP twins (`fmap`, `ffree`, `fbusy`, `famap`) | same |

Loop-carried: lane p's `prs1/prs2` read `map_q` **after** lanes < p wrote it (intra-group bypass: "newest matching destination wins, incl. `prd_old` for WAW"); `rs*_ready_o` reads `busy` after this cycle's WB clears and this group's allocations; the free-list isolate for lane 1 reads the vector after lane 0's pick.

## 2. Execution paths

| Event | Chain | Reaches |
|---|---|---|
| dispatch group (`valid_i`, `enable_i` = `can_go`) | `rs` → map read (32:1 × 2–3 per lane) → older-lane bypass compare (4 compares for 2 lanes) → `prs*_o`; `need_rd` → free isolate (PRF-wide incrementer, lanes serial) → `prd_o`, `prd_old_o` (= map read before write); `busy` read ∧ WB clear → `rs*_ready_o`; `is_branch` → checkpoint push; all in the admit cycle | `g6lc_ooo_dispatch` → IQ dispatch (`disp_prs*`, `disp_rs*_ready`), ROB alloc, LSQ alloc, `tid_prd/old/ckpt` tables — same cycle |
| WB (`wb_valid_i/wb_prd_i`) | `busy_d` clear; also feeds the same-cycle `rs*_ready_o` | — |
| commit (`commit_valid_i`, `free_i`, `ckpt_retire_i`) | `amap_d`, `free_d`, ring head | — |
| mispredict (`mispredict_i`, `mispredict_level_i`) | checkpoint select (ring index) → map/free/busy restore (+ repair: frees that happened since, busy clears since) | A147: `enable_i` must be low in the recovery cycle (`$error` otherwise) |
| flush | restore `map` ← `amap`, rebuild `free` from `amap`, clear busy/ring | — |

The admit path (`valid_i → prd_o`) is the 130 FO4 cone: free isolate over 72+ entries serial across lanes, plus map read + bypass + ready. `enable_i` (= `can_go`) is itself a function of `iq_full`, `rob_full`, `lsq_disp_block`, `ren_stall` (this module's `stall_o`) — a cross-module combinational cycle the dispatch avoids by deriving `can_go` from registered counts only.

## 3. Callers and callees

| Port | Reader | Kind | Kill | Tolerance |
|---|---|---|---|---|
| `prs1/2_o`, `prd_o`, `prd_old_o`, `fp*`, `rs*_ready_o`, `ckpt_id_o` | `g6lc_ooo_dispatch` (IQ `disp_*`, LSQ/ROB alloc, `tid_*` tables, memdep query) | comb, same cycle as `valid_i` | group is all-or-nothing on `can_go`; `flush_i`/`flush_unissued_i` block admission | the whole dispatch group can move one or two cycles later as a unit (scoreboard alloc already happened: the tid is fixed at `issue_instr`) |
| `stall_o` (free list empty) | `can_go` | comb | — | must stay a registered-count predicate |
| `wb_valid_i/wb_prd_i` | from dispatch `tid_prd_q[wb_id]` | input | masked for cancelled | the busy clear may be registered (+1 to `rs_ready` for a WB that lands in the admit cycle — the IQ's same-cycle capture handles the race today; in hyp8 the IQ wake path is the authority, so `rs*_ready_o` may be conservative) |
| `mispredict_i/level` | from `g6lc_ooo_dispatch` (branch resolve) | input | — | recovery is a full-group event; one extra stall cycle is fine (`recovering_q`) |
| `commit_*`, `free_i`, `ckpt_retire_i` | from commit bundle | input | — | +1 is fine (frees are not on the dispatch critical path except pool pressure) |

## 4. Functional separation

| Block | In | Out | State | Kernel / stage | Cost |
|---|---|---|---|---|---|
| `g6lc_rename_read` (stage R1) | `rs1/2/3_i`, `rd_i`, `need_rd_i`, `is_branch_i`, lane valids | registered: `map` reads (prs*, prd_old), free picks (prd), checkpoint slot reserved, busy reads | — (reads `map_q`, `free_q`, `busy_q`) | stage: 32:1 map read (3 FO4) ∥ free isolate as a **banked** pick (2 lanes pick from two halves of the pool, 4 FO4) ∥ busy read | ≤ 8 FO4 |
| `g6lc_rename_resolve` (stage R2) | R1 registers + **previous group's** publish (its `rd`/`prd` per lane, registered) | final `prs*`, `prd_old` after intra-group and prev-group bypass; `rs*_ready` (busy ∧ not produced by a group in flight) | prev-group record (2 lanes) | **kernel**: for each lane source, compare against ≤ 2 older lanes of this group and 2 lanes of the previous group (4 × 5-bit compares, 2 FO4) → priority mux newest-wins (2 FO4) | ≤ 6 FO4 |
| `g6lc_rename_publish` (stage R3) | R2 result, `can_go` for this group | `map_d` writes, `busy_d` set, checkpoint capture, outputs to dispatch | `map_q`, `busy_q`, checkpoint ring | stage | 4 FO4 |
| `g6lc_rename_recover` | `mispredict_i/level`, `flush_i`, `flush_hart_i` | map/free/busy restore; `recovering_q` | ring, repair sets | stage: restore is a wide copy (registered select of the ring entry, 1 cycle), repair applied the next cycle (`recovering_q` holds dispatch) | 6 FO4 |
| `g6lc_freelist` (banked) | `free_i` (commit), allocate picks | `free_q` halves, `stall_o` from registered counts | 2 × PRF/2 bitmaps + counts | stage | 5 FO4 |
| `g6lc_rat` | R3 writes, commit `amap` writes, restore | map arrays with a **late write + read bypass** (a read in R1 of a register written by R3 in the same cycle gets the new value through the bypass compare in R2, not through the array) | arrays | stage | 4 FO4 |

Why the loop shrinks: the only true single-cycle recurrence is "group k+1's lookup must see group k's destinations"; with groups in flight for 2 cycles (R1, R2) the compare set is this group's older lanes + the two previous groups' lanes (4 lanes) — `g6lc_rename_resolve` compares against a small registered record instead of the map array, so the map array may be written late. Free-list picks are made in R1 from registered bitmaps; a pick is committed to the bitmap in R3 (or returned on a stall/kill), and R1 picks for group k+1 avoid the registered "reserved" mask of groups in flight.

## 5. Latency and throughput target

- Dispatch latency +2 (R1, R2; R3 overlaps the IQ dispatch write). One group per cycle sustained (each stage holds one group; R1 may pick while R2 resolves).
- Mispredict: recovery restore at t+1 after the resolve (registered select), repair at t+2 with `recovering_q` holding dispatch; an older redirect arriving in the gap wins by age (A147 invariant kept: `enable_i` low in recovery cycles).
- `rs*_ready_o` may be conservative by one cycle (busy clear registered); the IQ wake is the authority.
- Cost: 2 group registers (~2 × (3×7 + 7 + 5 + flags) bits), prev-group record, +2 front-end depth (mispredict penalty +2 overall with the branch resolve +2 from the execute group).

## 6. Decision

Files (new): `core/ooo/g6lc_rename.sv` (same ports + `group_valid_o`/`group_ack` to dispatch, replaces the single-cycle module), `g6lc_rename_read.sv`, `g6lc_rename_resolve.sv`, `g6lc_rename_publish.sv`, `g6lc_rename_recover.sv`; `g6lc_rat.sv` (late write + bypass), `g6lc_freelist.sv` (banked, registered counts) rewritten. `HypCfg`: `RenameStages` (1 = today's single cycle, 3 = R1/R2/R3), `FreelistBanks` (2).

Kill identities: a group in R1/R2 is killed by `flush_i`, `flush_unissued_i`, or a mispredict (its picks return to the free list, its checkpoint reservation is released, exactly once); `cancelled_mask` does not apply (no tid is live before publish — the scoreboard slot was allocated at `issue_instr` time, so the dispatch group must be killed together with its scoreboard slots: `flush_unissued` covers that, as today).

Expected `// hyp8:` departures: (1) `prd_o` etc. appear 2 cycles after `valid_i`; dispatch (`g6lc_ooo_dispatch`) consumes them as a registered group with its own `can_go` re-evaluated at publish; (2) `recovering_q` stall; (3) busy clear registered.
