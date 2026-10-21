# g6lc_iq — analysis (T1, loop kernel)

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


Source of logic: `core/ooo/g6lc_iq.sv` (716 lines). Board: 156.0 structural / 112.3 adjusted, path kind reg→reg (`older_d → q_after_issue` / `issue_valid_o`). Contract: `core/ooo/AGENTS-ooo-contract.md` §1 (stationary entries, DEPTH² age matrix, oldest-ready select up to `NrIssuePorts`; loads wait on older *unresolved* stores unless `may_bypass`; stores issue in age order among stores (T24); CSR in IQ-age order (N1d); fence/system CSR, AMO, CVXIF only at the commit head), §2 (age key = circular `trans_id` distance from `commit_ptr_i`), §3 (kill = `cancelled_mask_i` per slot, `flush_i`).

## 1. State and writers

| State | Writers (one `always_comb` → `q_d`/`older_d`) | Class |
|---|---|---|
| `q_q[DEPTH]` (valid, rs1/2/3_rdy, prs1/2, prd, fprs1/2/3, fpr_rs*, may_bypass, sbe, orig) | cancel squash (`cancel_hit_q`), WB wakeup (NR_WB tag compares × 2–3 sources per entry), issue removal (`grant & issue_ack_i`), dispatch allocate (lowest/highest free slot, same-cycle WB capture), flush | composed in that priority order |
| `older_q[DEPTH][DEPTH]` | removed rows/cols cleared on `!valid_after`, newcomer column = `valid_after`, same-cycle dispatch pair order, flush | composed |
| `count_q` | delta: − cancels − acks + allocs | derived |
| `cancel_hit_q[DEPTH]` | registered `cancelled_mask_i[trans_id]` per slot (A112) | one-cycle late by design |

Loop-carried (`cut_surface`): `ready[e]` reads `q_chain` (all entries) and `older_q` (all rows) — the select is a DEPTH-wide function; `older_st_iq`/`older_csr_iq` scan all other entries; `older_unresolved_st` scans `NR_SB_ENTRIES` mask bits with an age compare each.

## 2. Execution paths (per cycle)

| Event | Chain | Cost driver | Reaches |
|---|---|---|---|
| WB tag arrives | `wb_prd_i` → DEPTH×NR_WB×3 compares → `q_wake.rs*_rdy` → `ready` → rank (A119 any/many trees over `older_t`) → `grant` → `issue_*_o` | compares + DEPTH-wide any/many tree + one-hot AND-OR select of a wide `sbe` | `issue_read_operands` (same cycle), `q_after_issue` (next state) |
| issue ack | `issue_ack_i` → removal → `valid_after` → `older_d` row/col clear, dispatch allocate | DEPTH-wide | next state only |
| dispatch | `disp_*` → free-slot isolate (`free & (~free+1)`) → `q_d[slot]` + newcomer column | incrementer + DEPTH decode | next state |
| cancel | `cancel_hit_q` (registered) → `q_wake.valid` | one AND per entry | select |
| unresolved-store mask | `st_unresolved_mask_i` (from LSQ, combinational on its registered state) × per-entry age compare over 32 slots → `ready` | 32 age compares × DEPTH | select |

The 112 adjusted FO4 is the WB-tag → wake → ready (with the 32-slot age scan) → rank tree → one-hot select of the payload → `issue_valid_o`/`issue_sbe_o` into `issue_read_operands` (which consumes the payload the same cycle — a combinational cross-module continuation measured by `cross_module_paths`).

## 3. Callers and callees

| Port | Reader | Kind | Kill identity | Tolerance |
|---|---|---|---|---|
| `issue_valid_o/issue_sbe_o/issue_orig_o/issue_prd_o` | `g6lc_ooo_dispatch` → `issue_read_operands` (operand read from PRF, FU dispatch, `issue_ack`) | comb (same cycle), ack returns comb | `cancelled_mask` at WB; `flush_unissued_i` | none today (ack in the same cycle; selection must not read the ack — the A104 rule) |
| `disp_ack_o` | `g6lc_ooo_dispatch.can_go` → scoreboard `issue_ack`/rename/ROB/LSQ alloc (all-or-nothing group) | comb | `flush_i`, `flush_unissued_i` | none |
| `full_o`, `empty_o` | `can_go`, drained-handoff seam (`ooo_drained_o`) | comb/flop | — | — |
| `wb_valid_i/wb_prd_i`, `fwb_*` | from `g6lc_ooo_dispatch` (`tid_prd_q[wb_id_i]` lookup) | input | WB of a cancelled tid is masked upstream (`wb_value_valid`) | — |
| `st_unresolved_mask_i`, `st_hart_mask_i`, `commit_ptr_i` | from LSQ / scoreboard | input (comb from LSQ registered state) | — | — |
| `mem_stall_i` | from LSQ/store pressure | input | — | — |

## 4. Functional separation

| Block | In | Out | State | Kernel / stage | Intended cost |
|---|---|---|---|---|---|
| `g6lc_iq_bank` × IqBanks (4 entries each) | bank-local wake tags (registered xbar output), own dispatch lanes, cancel bits, legality bits precomputed per entry | up to 2 ranked bank candidates (entry one-hot, age key, FU class, payload pointer), `free` vector | 4 entries, 4×4 `older`, per-entry `countdown[2:0]` + `spec` bit | **kernel**: 2-source × 4-entry tag compare on 2 wake ports (≈3 FO4) → `ready` (AND of 3 rdy + legality bit, 1 FO4) → 4-way oldest/second-oldest via 4×4 matrix (≈2 FO4) → grant one-hot (1 FO4) | ≤ 8 FO4 |
| `g6lc_iq_xbar` | selected producers (prd, class latency) from all banks this cycle; WB tags | per-bank wake tags **registered** (+1 to other banks; same-bank tags also go through the register but the bank keeps a same-cycle local copy of its own select — see steering) | wake tag registers | stage | 4 FO4 |
| `g6lc_iq_arb` | ≤ 2 candidates per bank (8 banks → 16) | `issue_valid_o[NP]`, payload select, `issue_ack` routing back to the banks | candidate registers | 2 stages: per-pair merge (oldest of two banks) then port select (oldest of 4 pairs) — both on registered candidates | ≤ 8 FO4 each |
| `g6lc_iq_legal` (per entry, precomputed at dispatch + updated by events) | FU class, `may_bypass`, head position, older-store/CSR gates | one legality bit per entry | per-entry bits | updated by registered events: `st_unresolved_mask` change, `commit_ptr` change, store/CSR issue; each a 1-cycle-late recompute off the loop | 6 FO4 |
| `g6lc_iq_payload` | dispatch `sbe/orig` | payload read by `issue_sbe_o` | payload array indexed by (bank, entry) | stage (read after grant, registered) | 4 FO4 |

Boundary moves: operand-ready bits already live here (not in the scoreboard); the scoreboard's readiness path (`issue_instr_valid_o`) in hyp8 is dispatch-only (see `scoreboard.md`). The head/legality gates (`commit_ptr_i == trans_id`, older-store/CSR scans) leave the select and become registered per-entry legality bits recomputed by events (they change only when `commit_ptr` moves or a store/CSR issues/resolves — one cycle late is safe in the *conservative* direction: a legality bit may stay 0 one cycle longer, never 1 too early, because the inputs that set it are registered facts about older instructions).

## 5. Latency and throughput target

- Dependent issue distance (producer selected at cycle t, consumer selectable at t + latency): **unchanged at 1 for in-bank ALU chains** (speculative wakeup: the producer's select broadcasts its `prd` with countdown = class latency − 1 into its own bank the same cycle; the consumer's `rdy` is set when the countdown reaches the bypass slot). Cross-bank: +1 (xbar register). Loads: countdown from the D$ hit latency (`LoadUseExtra`); a miss or an LSQ verdict `wait/violation` raises `replay` for the load's tid → every entry woken speculatively by it (and transitively, via a `spec_src` tag) is re-armed (`rdy` cleared) and the entry stays valid; a non-speculative WB (the real completion) sets `rdy` firmly.
- Throughput: 2 grants per cycle sustained from 16 candidates (8 banks × 2), payload read the cycle after grant (the `issue_read_operands` operand read moves one cycle later — the operand read is already a stage in hyp8, see `issue_read_operands` row of tier2).
- Cost: issue → operand-read gains 1 cycle (payload register), mispredict penalty +1 from the same; cross-bank dependent pairs +1. Steering (`IqSteer`): dispatch puts a consumer in the bank of its most recent producer if that bank has room, else lowest-occupancy bank.

## 6. Decision

Files (new): `core/ooo/g6lc_iq.sv` (bank array + xbar + arb wiring, replaces the old module with the same ports plus `replay_valid_i/replay_tid_i`, `issue_spec_o[NP]`, `steer_hint_i[NP]`), `core/ooo/g6lc_iq_bank.sv`, `core/ooo/g6lc_iq_xbar.sv`, `core/ooo/g6lc_iq_arb.sv`, `core/ooo/g6lc_iq_legal.sv`. `g6lc_ooo_pkg.sv` gains `ooo_lat_class(fu, op)` (ALU 2, MUL `MultStages`, LD `3+LoadUseExtra`, FP via LAT_*, other = non-speculative) and the replay broadcast type. `HypCfg` fields: `IqBanks`, `IqBankEntries`, `IqSpecWakeup`, `IqSteer`. Ports kept for the contract's consumers: `cancelled_mask_i`, `sb_live_i` (assertions), `st_unresolved_mask_i`, `st_hart_mask_i`, `commit_ptr_i`, `mem_stall_i`.

Kill identities: `cancelled_mask_i[tid]` clears entries in every bank and the candidate registers in `g6lc_iq_arb` (a candidate whose tid is cancelled is dropped before port select); `flush_i` clears all; `replay` (new) only re-arms readiness, it never removes an entry.

Expected `// hyp8:` departures: (1) `issue_valid_o` is registered (one cycle after the bank grant); `issue_ack_i` now acknowledges the registered candidate, and an un-acked candidate is held (not re-selected) until acked or killed — the A104 "selection never reads the ack" rule is preserved by construction. (2) Legality gates are one-cycle-late registered bits (conservative). (3) Speculative wakeup/replay is new behaviour; `IqSpecWakeup=0` restores wake-on-WB only.
