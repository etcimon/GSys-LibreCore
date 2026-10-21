# store_buffer — analysis (T1, loop + latency)

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


Source of logic: `core/store_buffer.sv` (1194 lines; A141 landed the stationary-slot reshape: age matrix at insertion, one-hot head, per-byte youngest-writer merge). Board: 76.8 structural (reg→reg) / 90.1 adjusted. Contract §1: speculative queue (age-sorted under OoO) + committed queue; byte-exact forward; committed entries exempt from age compare; a store entry's slot is reserved by the LSQ (`LsqStoreEntries <= DEPTH_SPEC`); under `COH_OOO` the page-offset stall is released for an unpublished head load (not hyp8's WT config — keep the ports). §3: `cancelled_mask_i[$id]`, `flush_i` (speculative queue only; committed entries survive), commit by head match (`spec_head_mismatch` stalls `commit_ready_o`).

## 1. State and writers

| State | Writers |
|---|---|
| `speculative_queue_q[DEPTH_SPEC]` (pa, data, be, size, cbo_op, tid, hart, valid, generation) + `spec_older` age matrix | insert on `valid_i & ready` (free slot, age row = all live), pop to the committed queue on `commit_i` (one-hot head), cancel verdict per entry (`cancelled_mask_i[tid]`), flush (clears speculative) |
| `commit_queue_q[DEPTH_COMMIT]` | push from the speculative head on commit; pop on `data_gnt_i` from the cache (write-through issue); `rvalid` tracking |
| forward path (comb) | for a load address (`page_offset_i` / full PA compare), per-byte youngest-older-writer merge across both queues → `rdata`/`forward` bits (consumed by `load_unit` through `lsu_bypass`) |
| `ready_o`, `commit_ready_o`, `no_st_pending_o`, `store_buffer_empty_o` | registered counts/head |

Loop-carried: `spec_rewrite` (insert + age row + count in one transaction); the forward merge reads both queues and the insertion of the same cycle? (today's `speculative_queue_n` is read by the forwarding compare — the contract note "no-cut on=speculative_queue_n"); `spec_older_n` written at insertion from `valid_i`.

## 2. Execution paths

| Event | Chain | Reaches |
|---|---|---|
| store issue (`valid_i`, `trans_id_i`, pa/data/be) | free slot isolate → write entry → age row (compare tids vs `oldest_live_tid_i`) | `ready_o` next cycle; `spec_visible` for younger loads |
| load address (from `load_unit`) | per-entry pa compare (page offset or full PA) + byte overlap + age (speculative entries younger than the load excluded via `ooo_older`) → per-byte youngest-writer merge over DEPTH_SPEC + DEPTH_COMMIT → forward data/valid → `load_unit` | same cycle into the load's request/response path |
| commit (`commit_i`) | head match (`spec_head_mismatch`) → pop → push to the committed queue | `commit_ready_o`, `commit_ack` |
| cache grant (`data_gnt_i`) | committed head → cache write request issued; pop | `wt_dcache` via `req_port_o` |
| cancel/flush | drop speculative entries | — |

The 90 adjusted FO4 chain is the load forward: address compare × DEPTH → age exclude → per-byte youngest select (tournament) → data mux, plus the insertion `spec_rewrite`.

## 3. Callers and callees

| Port | Reader | Kind | Kill | Tolerance |
|---|---|---|---|---|
| forward data/valid → `load_unit` (via `lsu_bypass`) | comb into the load pipeline | — | — | the load's own hazard verdict (LSQ) is +3 in hyp8; the forward may take 2–3 cycles if the load unit samples it in its response stage (the data is needed when the cache data arrives, 4–5 cycles after the request) |
| `ready_o` → `store_unit` | valid/ready | — | — | registered ready is fine (the store unit waits) |
| `commit_ready_o`/`commit_ack` ↔ `commit_stage` | handshake at commit | — | — | commit bundle (+1) |
| `req_port_o` → `wt_dcache` (write-through) | valid/gnt | — | — | handshake |
| `no_st_pending_o`, `store_buffer_empty_o` | `load_unit` non-idempotent rule, controller fence/flush drain, thread select | comb on registered | — | one cycle late is conservative |

## 4. Functional separation

| Block | In | Out | State | Kernel / stage | Cost |
|---|---|---|---|---|---|
| `stb_insert` (S1/S2) | `valid_i`, payload, tid, `oldest_live_tid_i` | S1: free slot one-hot + age row (8 tid age compares, 5-bit) registered; S2: entry write + matrix row write | queues | stage/stage | 6 / 4 FO4 |
| `stb_fwd_match` (F1) | load pa, size, tid, hart | per-entry match bits (pa compare, byte overlap, age-exclude for speculative entries, hart) — registered | — | stage: 16 pa compares (≈4 FO4) + overlap + age (parallel) | ≤ 8 FO4 |
| `stb_fwd_select` (F2) | match bits per byte | per-byte youngest writer (8-way tournament per byte over the spec matrix; committed entries ordered by queue position) → registered byte-select one-hots | — | stage | 7 FO4 |
| `stb_fwd_data` (F3) | byte-select one-hots | forwarded bytes + `forward_possible` bit (conservative: 0 if an older entry's pa was unknown at F1 — in this WT design a speculative entry always has its pa, so the bit is the "all covering bytes come from entries with data" test) | registered | stage | 4 FO4 |
| `stb_commit` | `commit_i`, head one-hot | pop/push; `spec_head_mismatch` stall | head regs | **kernel**: head tid compare (5 FO4) | ≤ 6 FO4 |
| `stb_drain` | committed head, `data_gnt_i` | `req_port_o` | — | stage | 4 FO4 |

Why the forward can be 3 cycles: the load's data from the cache arrives 4–5 cycles after the request at 8 FO4 (`DcacheHitExtra` = 2 on top of today's 2); the forward result is needed only at the load's merge point, so F1–F3 run in parallel with the cache access. A store inserted *after* the load's F1 cycle but older in program order cannot exist (stores reach the buffer at issue in program-ordered age terms only if the LSQ verdict allowed the load to pass; the LSQ checked-bit/verdict covers the race: a load whose verdict is "wait" is replayed).

## 5. Latency and throughput target

- Store insertion: 1 per cycle (S1/S2); `ready_o` registered.
- Forward: 3 cycles from the load address, overlapped with the cache access → load-use unchanged by the buffer in hyp8.
- Commit: head pop one cycle after `commit_i` (bundle timing).
- Cost: match/select registers (DEPTH × bytes one-hots), forward_possible bit, +1 `ready_o`.

## 6. Decision

Files (new): `core/store_buffer.sv` (ports unchanged; forward outputs become `fwd_valid_o` one-shot 3 cycles after `fwd_req`), `stb_insert.sv`, `stb_fwd.sv` (F1–F3), `stb_commit.sv`, `stb_drain.sv`. `HypCfg`: `StoreFwdCycles` (1 = today's same-cycle merge, 3 = F1–F3), consumed by `load_unit`/`lsu_bypass`.

Kill identities: `cancelled_mask_i[tid]` per speculative entry (as today, registered verdict is already the A141 form); `flush_i` clears speculative, committed survive; a forward result for a load that was cancelled is discarded by the load unit (tid carried with the forward request).

Expected `// hyp8:` departures: (1) forward is a 3-cycle pipeline with a request/response pair instead of a combinational function of the address; (2) `ready_o` registered; (3) commit pop one cycle after `commit_i`.
