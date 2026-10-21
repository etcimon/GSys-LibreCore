# scoreboard — analysis (T1, loop + latency)

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


Source of logic: `core/scoreboard.sv` (1341 lines). Board: 145.8 structural (reg→out, `mem_n → issue_instr_valid_o`) / 101.2 adjusted. Contract §1: slot allocation in program order, `trans_id`, in-order commit pointer, younger-than-branch cancel mask; §2: `reclaim_ptr_o` is the age anchor; §3: `cancelled_mask` (sticky per slot + same-cycle bmiss window), `flush_i`, memory-order violation → `cancelled + replay`, commit drop + `flush_commit` refetch; T6b-4b per-hart commit heads (only under `MixedSmt`; hyp8 is single-hart/drained → legacy commit select, bit-identical).

In this core "issue" at the scoreboard means *allocation into the window* (decode → `issue_instr_o` → `issue_read_operands` → `g6lc_ooo_dispatch`); operand readiness lives in `g6lc_iq`. The scoreboard is the ROB: results and exceptions land in `mem_q[tid].sbe`, commit reads the head.

## 1. State and writers

| State | Writers (`issue_fifo` block → `mem_n`; separate blocks for pointers/masks) |
|---|---|
| `mem_q[NR_SB]` (issued, cancelled, replay, is_rd_fpr_flag, sbe{valid,result,ex,...}) | allocate (`decoded_instr_valid & ack`, per port, `issue_pointer[i]`), writeback install (per WB port: `trans_id_i[w]` → `sbe.result/ex/valid`; CVXIF `x_*`), branch resolve (`resolved_branch_i` → cancel younger: sticky `cancelled`), mem violation / `lu_replay` → `cancelled + replay` for the slot and younger, commit (`commit_ack_i` → `issued = 0`), `flush_unissued`, `flush_i` |
| `issue_pointer_q`, `commit_pointer_q[NrCommitPorts]`, `issue_cnt_q` | `num_issue`, `num_commit` deltas |
| `cancelled_mask_o` | sticky `mem_q[].cancelled` OR same-cycle bmiss window (`gen_bmiss_window`: younger-than-branch by age) |
| head scan (`sb_head_scan`): per-hart oldest issued slot from `commit_pointer_q[0]` by rotated lowest-set | combinational on `mem_q` |
| `fwd_o` (forwarding to `issue_read_operands`) | result/valid per slot, same cycle as WB install (the in-order bypass; under OoO the PRF write-through is the data path — check in Phase 3 which consumers read `fwd_o` when `OoOEn`) |

Loop-carried: `mem_n` is one next-state function with 5 writer classes; the cancel mask of this cycle (bmiss window) is read by the IQ/LSQ/PRF the same cycle; `commit_instr_o` is read combinationally from `mem_q[commit_sel_slot]` and `commit_ack_i` comes back the same cycle from `commit_stage` (which evaluates CSR/exception/interrupt conditions on it).

## 2. Execution paths

| Event | Chain | Reaches (same cycle) |
|---|---|---|
| WB result (`wt_valid_i[w]`, `trans_id_i`) | 32-way decode → `mem_n[tid].sbe.result/ex/valid`; `fwd_o` | `issue_read_operands` forwarding; `g6lc_ooo_dispatch` (PRF write-through uses `wb_*` directly, not through the scoreboard) |
| branch resolve (`resolved_branch_i`) | age compare vs every slot → `cancelled` sticky + `cancelled_mask_o` (bmiss window) | IQ, ROB, LSQ, PRF write gate, FU owner tables, LSU pre-grant queue — all read `cancelled_mask_o` this cycle |
| mem violation / lu_replay | id → slot + younger → `cancelled + replay` | commit (drop/replay), frontend refetch at commit |
| commit (`commit_ack_i`) | `issued = 0`, pointer += num_commit | `reclaim_ptr_o` → dispatch/IQ/LSQ/store buffer age anchor; `g6lc_ooo_dispatch` free-list/map update; `csr_regfile` ack |
| allocate (`decoded_instr_valid_i & ~issue_full`) | `mem_n[issue_pointer+i]` | `issue_instr_o` to `issue_read_operands` (same cycle) |

The 145.8 cone is: WB install + branch-resolve age compares + violation marking + commit clear composed into `mem_n`, with the head scan / commit select and `issue_full` (from `issue_cnt`) hanging off it.

## 3. Callers and callees

| Port | Reader | Kind | Kill | Tolerance |
|---|---|---|---|---|
| `cancelled_mask_o` | IQ (`cancel_hit_q` is already registered — one cycle late by design, A112), LSQ (live), PRF write gate (live), ROB (live), owner tables, LSU pre-grant | comb | — | the IQ already tolerates one cycle; the others must either tolerate it (a cancelled op's late WB must not write — the PRF gate is the one that must stay same-cycle with the WB it gates, so it reads the *registered* mask plus the same-cycle bmiss window computed locally from the registered branch) |
| `commit_instr_o/commit_drop_o/commit_replay_o` → `commit_ack_i` | `commit_stage` (same cycle, decides ack from CSR/exception/interrupt/halt/dcache flush) | comb loop | — | the commit bundle (M8) breaks it: decision at t, ack and side effects at t+1 |
| `issue_instr_o/issue_instr_valid_o` → `issue_ack_i` | `issue_read_operands` (dispatch into the OoO backend; ack is `can_go`) | comb loop | `flush_unissued_i` | a registered handoff adds 1 to dispatch; acceptable (dispatch is already +2 in hyp8 from rename) |
| `reclaim_ptr_o` | dispatch/IQ/LSQ/store buffer | comb on registered pointer | — | — |
| `fwd_o` | `issue_read_operands` | comb | — | in hyp8 the bypass is the PRF/stage-2 forward; `fwd_o` keeps the port, registered |
| `sb_live_o`, `sb_head_pc_o/valid_o` | assertions, thread select (drained) | — | — | — |
| RVFI pointers | `g6lc_rvfi_probes` | — | — | re-anchored to the bundle |

## 4. Functional separation

| Block | In | Out | State | Kernel / stage | Cost |
|---|---|---|---|---|---|
| `sb_alloc` | `decoded_instr_*`, `issue_ack_i`, `flush_unissued` | `mem` allocate writes, `issue_instr_o` (registered handoff), `issue_pointer` | pointers | stage | 5 FO4 |
| `sb_wb_capture` | `wt_valid_i/trans_id_i/wbdata_i/ex_i`, CVXIF | **registered WB records** (one per WB port), killed by the registered cancel mask | NR_WB records | stage | 3 FO4 |
| `sb_lifecycle` (per slot) | WB records (5-bit id compare per port), cancel events, violation events, commit clear | slot bits + `sbe.result/ex/valid` | per-slot | stage: id compare + priority write; the writers are serialized by the record registers so no two live events compose combinationally | 5 FO4 |
| `sb_cancel` | `resolved_branch_i` (registered copy), `mem_violation_*`/`lu_replay` (registered) | `cancelled_mask_o` = sticky bits OR the window of the *registered* branch | sticky bits | **kernel**: 32 age compares (5-bit distance) vs one registered branch id → mask: ≈ 5 FO4 | ≤ 8 FO4 |
| `sb_head` | `mem_q.issued/hart`, `commit_pointer_q` | `head_slot/valid`, `reclaim_ptr_o` | registered head candidates | 2 steps: per-8-slot lowest-set (4 FO4) → merge of 4 + rotation select (4 FO4) | 8 FO4 |
| `sb_commit_bundle` | head entry, drop/replay bits, `checked` (from LSQ) | `commit_instr_o` **registered** at t; `commit_ack_i` returns at t+1 and clears `issued` at t+1 (the slot presented at t is held) | bundle register | stage | 6 FO4 |
| `sb_count` | alloc/commit/cancel deltas | `issue_full`, `sb_full_o/empty_o` | counters | stage (delta form as today) | 4 FO4 |

Boundary moves: readiness (`issue_instr_valid_o` as a gate on dispatch) stays here as "window not full", nothing else; `fwd_o` is no longer a bypass path (PRF stage-2 forward owns it). The commit bundle's consumers (`commit_stage`, `csr_regfile`, `store_buffer` commit, `g6lc_ooo_dispatch` free/map, LSQ commit release, RVFI) all see the committed slot one cycle after the head decision — see `callers.md`.

## 5. Latency and throughput target

- 2 commits/cycle sustained (legacy pair rule unchanged); commit-to-free +1 (bundle); commit-to-redirect (exception/xRET/fence flush) +1.
- WB-to-commit: +1 (capture register). WB-to-wake is not through the scoreboard (IQ wakes on the WB bus / speculative countdown).
- Cancel latency: a branch resolved at t cancels at t+1 (registered branch); the IQ already assumed one cycle (A112). The PRF write gate uses the registered mask + the registered-branch window, so a cancelled op's WB arriving at t+1 is still blocked; an op's WB arriving at t (the resolve cycle) writes the PRF but the slot is marked cancelled at t+1 and the register is freed by the commit-drop path (no architectural map update) — this is the existing semantics for the one-cycle A112 window, stated.
- Cost: WB records (2 × ~80 bits), bundle register (2 × sbe), +1 commit, +1 cancel.

## 6. Decision

Files (new): `core/scoreboard.sv` (same ports + `ld_checked_i[NR_SB]`, `commit_bundle_valid_o`), `core/sb_wb_capture.sv`, `core/sb_cancel.sv`, `core/sb_head.sv`, `core/sb_commit_bundle.sv`. `HypCfg`: `CommitBundleStages` (0 = today's same-cycle ack, 1 = bundle), `WbCaptureStages` (0|1).

Kill identities: WB record of a cancelled tid is dropped at capture; commit bundle of a cancelled slot commits as *drop* (as today); `flush_i` clears records and bundle; `flush_unissued_i` only blocks allocation.

Expected `// hyp8:` departures: (1) `cancelled_mask_o` one cycle after the resolve; (2) `commit_instr_o` registered, ack one cycle later; (3) `fwd_o` registered and documented as non-bypass; (4) `issue_instr_o` handoff registered.
