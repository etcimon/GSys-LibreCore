# Cut-minimization protocol (priority rule for every >8 FO4 file)

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


A *cut* is a register added on a path that today completes in one cycle. Every cut costs latency on that path; a cut on a dependent (low-latency) function costs IPC on every use. The redesign therefore ranks mechanisms, per execution path, in this order, and takes the first that fits 8 FO4:

| Rank | Mechanism | Latency cost | When it applies |
|---|---|---|---|
| 0 | **Restructure the function** — serial chain → parallel/prefix form, priority scan → one-hot + tournament, N-way compare → banked compare + small merge, wide mux → one-hot AND-OR, carry chain → split with a registered carry only when unavoidable | 0 | always try first; most of the structural FO4 in this core is serial `for … if` chains and composed next-state writers |
| 1 | **Move the decision earlier** — compute at a point in the path that already has slack or is not dependent (dispatch-time side tables, registered legality bits updated by events, class/latency decided at decode) | 0 on the dependent path (the work moves to an earlier, non-critical cycle) | readiness gates, legality, steering, table lookups whose inputs are known early |
| 2 | **Retime an existing register** — move a register that already exists (an FU output register, a response register, a FIFO stage) so it sits where the cut is needed; the stage count of the path does not change | 0 | WB capture (use the FU lane register), I$/D$ responses (use the array output register), handshake stages (use the existing valid/ready register) |
| 3 | **Overlap** — start the long function speculatively in parallel with the decision it waits for, and gate only the *publication* (checked bit, forward_possible bit, epoch) | 0 on the common path; a replay/squash on the rare path | loads vs the LSQ verdict, fetch vs the override predictors, store forward vs the cache access |
| 4 | **Cut on a value path the window already hides** — a register on a multi-cycle unit, a response, a drain path, bookkeeping | +1 on that value only | multiplier, FP, cache fill, drain, counters, observers |
| 5 | **Cut on a readiness/dependent path** — only when 0–4 are exhausted; must be recorded with the dependent-latency cost | +1 per dependent use | should be rare; each one is listed in `notes/decisions.md` with the reason |

Execution-path awareness: each module's analysis lists its paths; the **dependent paths** (the ones that end in a wake, a readiness bit, a next address, a forward, a bypass) get ranks 0–3 only; the **value/bookkeeping paths** may take rank 4. A rank-5 cut needs a named reason.

## Planned cuts in the T1 analyses, re-examined under the protocol

| Module | Cut planned in the analysis | Path class | Re-examination | Result |
|---|---|---|---|---|
| g6lc_iq | `issue_valid_o` registered candidate (+1 issue→operand read) | dependent (issue) | Rank 2: the IRO operand read already has a register boundary at `operand_a/b_q` (`issue_read_operands`); the candidate register *replaces* it rather than adding to it — the payload read and the PRF read happen in the cycle the operands used to be latched. Rank 1: legality gates become event-updated bits (no cut). Rank 0: 4-entry banks keep select single-cycle. | **0 added cycles** on issue→execute for in-bank chains; cross-bank wake +1 (rank 5, recorded: the xbar register is the price of banking; mitigated by steering) |
| g6lc_iq | speculative wakeup countdown | — | rank 1/3 (decision moved to select time, publication gated by the real WB or replay) | removes the WB→wake dependency from the loop |
| g6lc_lsq | event register (+1), CAM/age/reduce/verdict (+3) | load verdict (dependent for loads) | Rank 3: the load's cache access overlaps the verdict; publication gated by `ld_checked`. Rank 0: banked CAM + tournament replaces the serial scan. Rank 2: the event register *is* the AGU output register retimed (the AGU result was already latched in the LSU before the live update — the live update path is removed, the latch moves to the LSQ input). | **0 added cycles** on load-use when the verdict is "no hazard" (verdict +3 but hidden under the 4–5-cycle D$ hit); violation detection +3 (value path, rank 4) |
| g6lc_lsq | release scan via registered per-load mask | bookkeeping | rank 1 | 0 |
| scoreboard | WB capture register (+1 WB→commit) | value | **Rank 2: the FU lane register (execute group) is the capture** — no second register; the scoreboard's slot write reads the lane record directly | 0 added |
| scoreboard | commit bundle (+1 commit) | commit (value) | Rank 1: the head's completion is known when its WB lane record is written (one cycle before the slot update); form the bundle from (head pointer, lane record match) in that cycle → the bundle appears when the entry update would have, i.e. **same cycle as today's `commit_instr_o`**, and the ack returns the cycle after as today's consumers already register it (CSR excepted) | 0 on the common path; CSR ops +1 (rank 4, serialized anyway) |
| scoreboard | `cancelled_mask_o` from the registered branch (+1) | readiness (kills) | Rank 2: `resolved_branch_o` is registered in the branch unit (B2) — that register is the one; the scoreboard computes the window from it directly. The IQ already assumed +1 (A112). | 0 beyond B2 |
| g6lc_rename | R1/R2/R3 (+2 dispatch) | dependent? — dispatch latency is front-end depth, not an issue bubble (rename → IQ dispatch; the IQ wakes on WB/countdown, not on rename) | Rank 0 first: free-list isolate as a banked pick (per-lane bank, 4 FO4) and map read 32:1 (3 FO4) fit one 8-FO4 stage **with** the intra-group bypass (2 FO4) if the previous-group bypass compares are precomputed (rank 1: the previous group's `rd/prd` are registered at publish, so the compare runs from registers). Checkpoint capture and `busy` reads in parallel. | **1 stage (R1 = read+pick+bypass), publish in the same cycle through the late-write RAT** → +0 or +1 depending on the board's reading of the combined cone; plan R2 only if the fresh board says the combined kernel exceeds 8 — then +1 (rank 4, front-end depth) |
| frontend | line predictor + override stages | next-PC (dependent) | Rank 0/1/3: untagged next-line (kernel), tagged BTB and predictors as overrides with epoch kill (overlap) | 0 on the common path; overrides on disagreement only |
| frontend | response path +2 (realign/scan) | front-end depth (value) | rank 4 | +2 mispredict penalty component |
| wt_dcache_wbuffer | W1/W2 (+1 `data_gnt`) | store acceptance (value: committed stores) | Rank 2: the store unit already registers the request to the cache (`req_port` is a registered handshake); W1's compare starts from that register — the +1 grant is the existing register's position, not a new one. Pending-export keeps forward visibility at +0. | 0 on load forwarding; grant as today's handshake |
| store_buffer | F1–F3 forward (+3) | load forward (dependent for store→load) | Rank 3: overlapped with the D$ access (4–5 cycles) | 0 on load-use |
| store_buffer | `ready_o` registered | store issue (value) | rank 2 (the store unit's request register) | 0 |
| execute | A1/A2 ALU (+1 dependent) | **dependent** | Rank 0: 64-bit add in one 8-FO4 cycle is not available; Rank 0 variant: **staggered** low-half-first keeps add/logic dependents at distance 1 (the P4 "double-pumped" form without the double clock) | 0 for add/logic/branch-compare-low; +1 for shifts, compares needing the high half, and `slt` (rank 5, recorded) |
| execute | B1/B2 branch (+2 resolve) | mispredict penalty (value) | B1 shares A1 (target add low half); resolve direction known at A1 for equality compares (low+high XOR tree 2 FO4 each) → `is_mispredict` for `beq/bne` at B1, for `blt*` at B2 | +1 average |
| execute | per-unit WB lanes | — | rank 2 (lanes are the FU output registers) | 0 |
| execute | multiplier 8 stages | value | rank 4 | +4 on multiply only |
| csr_regfile | C1/C2/C3 | commit-head only (value) | rank 4 | +1, serialized |
| load_unit | L1–L5 | load-use (dependent) | L4/L5 are the cache response register + the publish gate (rank 2/3); L1/L2 are today's FSM states | +0 beyond the D$ hit extra (`DcacheHitExtra` is the cache's own cut, rank 4 on the array path) |
| decode group | D1–D3 (+2) | front-end depth | rank 4 | +2 mispredict component |
| TLB group | T1–T3 (+2) | load-use via translation | Rank 3: the D$ tag lookup is already indexed by VA bits and overlapped with translation (VIPT); the +2 is hidden if `DcacheHitExtra` ≥ 2 | 0 beyond the cache extra |
| g6lc_ooo_dispatch | group register + table writes | dispatch (front-end depth) | rank 2: the group register *is* rename's publish register | 0 beyond rename |
| g6lc_rob | completion from lane records | value | rank 2 | 0 |
| g6lc_icache | +1 response | fetch depth (value) | rank 2 (array output register) | +0/+1 |
| wt_dcache_mem | +2 hit | load-use | **the one unavoidable rank-5 cut class**: tag compare + way select + 128-bit align does not fit 8 FO4; `DcacheHitExtra=2` is the cost every load pays; everything else in the LSU hides under it | +2 load-use (recorded) |
| serdiv | +1 | value | rank 4 | — |

## Net dependent-latency budget after the protocol (targets for Phase 3)

- ALU add/logic → dependent ALU: **1** (unchanged); shift/compare/slt: 2.
- Branch resolve → redirect: +1 average (beq/bne 1, blt 2) + the register in the scoreboard window (already assumed).
- Load-use (hit, no hazard): today's + 2 (`DcacheHitExtra`), everything else overlapped.
- Store→load forward: hidden under the load-use.
- Issue → operand read: 0 added (candidate replaces the operand latch); cross-bank wake +1.
- Front-end depth (mispredict penalty): +2 (decode) +2 (realign/scan) +0..1 (rename) +0..1 (branch) — front-end depth, not a dependent bubble; partially recovered by the next-line predictor (taken branches no longer cost the I$ round trip).
- Commit: 0 added on the common path; CSR +1.

Every Phase 3 hand-off states, per rewritten file, the rank used for each path and the added cycles, and `notes/decisions.md` records every rank-5 cut.
