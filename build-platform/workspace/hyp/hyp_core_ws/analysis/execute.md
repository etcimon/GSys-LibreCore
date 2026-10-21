# execute group — alu, branch_unit, ex_stage (FLU), issue_read_operands, multiplier/mult — analysis (T1, latency class)

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


Boards: `alu` 90.5 adjusted (453 lines), `ex_stage` FLU 42.8 adjusted (930 lines), `branch_unit` 53.6 structural (251 lines), `issue_read_operands` 56.8 structural (1743 lines), `multiplier` 92.0 structural / 101.9 adjusted (494 lines, `MultStages=4` today, final add segmented A147), `mult.sv` (owner table, T2). Contract §1: FU owner tables (`mult.sv`, `fpu_wrap.sv`) hold one live token per tid; cancelled result suppression; §4: ALU/branch/mul/FP issue out of order; fence/system/AMO/CVXIF at the head; `ex_stage` snapshots fence operands at issue.

## 1. State and paths

| Module | Chain today | Writers/state |
|---|---|---|
| `alu` | operand select (fwd mux in IRO) → 64-bit add/sub (CPA) ∥ logic ∥ shifter (barrel 64) ∥ compare (slt/sltu/eq) → result mux → `result_o` → `ex_stage` FLU mux → `flu_result_o` → writeback bus → scoreboard WB install / PRF write / IQ wake / IRO bypass — all in one cycle | combinational |
| `branch_unit` | `target_address = base + imm` (VLEN add) → compare vs predicted → `resolved_branch_o` (is_mispredict, target, cf_type) → `controller` (flush_unissued, kill), `frontend` redirect, scoreboard cancel (bmiss window), dispatch `mispredict_i` → rename restore; `branch_exception_o` | combinational, same cycle as the ALU compare |
| `ex_stage` FLU | `one_cycle_select`: ALU / branch / CSR / AES / mult(`mult_valid`) share one `flu_result_o`/`flu_trans_id_o`/`flu_valid_o`; multiplier latency collisions resolved by `mult_valid` priority (A139 note: completion collisions) | FLU mux |
| `issue_read_operands` | operand read (regfile/PRF) + forwarding mux (from WB bus `fwd_o`, PRF write-through) + `fus_busy` reservation for the multiplier (`issue_read_operands.sv:427-434`) + FU dispatch valid/ack to each unit; CSR credit; CVXIF port-0 rule | `operand_a/b_q`, `fu_data_q`, `issue_ack` |
| `multiplier` | `MultStages` pipeline: operand condition → partial products (CSA tree) → segmented final add → `mult_result_d`; `prod_sum_q` | pipeline regs |

Loop-carried: none architecturally (value class) — but the **bypass loop** IRO fwd mux → ALU → FLU → fwd mux is the 1-cycle ALU-to-ALU dependent chain. With `AluStages=2` the dependent distance becomes 2 unless the staggered low-half forward is used.

## 2. Callers of the ports that change

| Port | Reader | Kind | Kill | Adaptation |
|---|---|---|---|---|
| `flu_result_o/flu_valid_o/flu_trans_id_o` → WB bus | scoreboard WB capture, PRF write, IQ wake (tag), IRO bypass | flop/comb | `cancelled_mask` on the tid | per-unit WB slots: each FU gets its own registered WB record; the bus becomes `NrWbPorts` fixed lanes (ALU0, ALU1/branch, MUL, LSU, FPU, CSR/AES) — `WbReserve`: issue reserves the shared lane `k` cycles ahead when two FUs of different latency would complete together (the `fus_busy` precedent) |
| `resolved_branch_o` | controller/frontend/scoreboard/dispatch | comb → flops | — | registered (+2): `is_mispredict` arrives 2 cycles after issue; the scoreboard cancel window and rename restore follow; `misp_outranked` ordering kept because the arch redirect is also registered through the commit bundle (both +1/+2 — order preserved by construction: a trap at commit for an *older* instruction cannot be younger than this branch) |
| `branch_exception_o` | WB (exception into the slot) | — | — | with the result |
| `issue_ack` → IQ | comb | — | — | ack of the registered candidate (IQ analysis) |
| `fus_busy`, FU valid/ready | FUs | — | — | reservation table extended to all fixed-latency units |

## 3. Functional separation

| Block | Kernel / stage | Cost |
|---|---|---|
| `alu` stage A1: 32-bit low add (CPA 32, ≈5 FO4) + low-half logic ops; carry out registered; shift amount decode; compare partials (low equality, low magnitude) | stage | ≤ 8 FO4 |
| `alu` stage A2: high 32-bit add with the registered carry (5 FO4) + flags; barrel shift stage 2 (the 64-bit shift is split: A1 shifts by the low amount bits (0–7), A2 by the high bits (8–63), 2 × 3-level mux ≈ 4 FO4 each); compare finalize; result mux | stage | ≤ 8 FO4 |
| `alu_fwd_low`: A1's low 32-bit result is forwardable to a dependent ALU op's A1 **next cycle** (its high half arrives in the dependent's A2 — exactly when the dependent needs it for its own high add); shifts/compares that need the full 64 bits of the source wait for A2 (the IQ countdown class distinguishes `ALU_ADD_LOGIC` (lat 1 via staggered forward) from `ALU_SHIFT_CMP` (lat 2)) | kernel: forward mux 4:1 on 32 bits ≈ 3 FO4 inside A1's budget | — |
| `branch_unit` B1: target add low/high staggered like the ALU; B2: compare + `is_mispredict` + `resolved_branch_o` registered | stage | ≤ 8 FO4 |
| `ex_stage` writeback lanes: per-unit result registers; `WbReserve` table (per cycle-ahead slot, per shared lane) | stage | 5 FO4 |
| `issue_read_operands`: I1 operand read (PRF registered read, 2 steps — `g6lc_prf` T2) ∥ reservation check; I2 bypass select (4 sources: A1-low forward, A2 result, WB lanes, PRF data) + FU dispatch | stage/stage | 8 FO4 |
| `multiplier`: `MultStages` 8 — operand condition (1), Booth/CSA tree (4 stages of 3:2 compressor rows, ≈6 FO4 each), final add 64-bit split in 2 (32-bit CPAs), result/flags (1) | stages | ≤ 8 FO4 |
| `mult.sv` owner table: tid token per in-flight op, cancel suppression | stage (as today) | 5 FO4 |

## 4. Latency and throughput target

- ALU add/logic dependent distance: **1 cycle** via the staggered low-half forward (`AluStaggered=1`); shift/compare/branch dependent distance: 2. The IQ speculative countdown uses the per-op class.
- Branch resolve: +2 after issue (B1/B2) → mispredict penalty +2 vs today from this group.
- Multiplier: 8 cycles (today 4); throughput 1/cycle; the scoreboard/IQ latency parameter co-emitted (`MultStagesOverride`).
- Writeback: no collisions by construction (per-unit lanes or reservation); `NrWbPorts` grows to the lane count — the scoreboard WB capture and PRF write ports follow (PRF T2 row: registered write, 2 steps).
- Cost: A1/A2 registers (2 × 64 + flags), per-unit WB records, reservation table, 4 more multiplier stages.

## 5. Decision

Files (new): `core/alu.sv` (A1/A2, `AluStages`/`AluStaggered`), `core/branch_unit.sv` (B1/B2), `core/ex_stage.sv` (lanes + reservation; `one_cycle_select` removed), `core/issue_read_operands.sv` (I1/I2; `fus_busy` generalized into `wb_reserve`), `core/multiplier.sv` (8 stages), `core/mult.sv` (owner table over 8 stages). `HypCfg`: `AluStages`, `AluStaggered`, `WbReserve`, `MultStagesOverride`, `WbLanes`.

Kill identities: a result lane record carries its tid and is dropped by `cancelled_mask` at the scoreboard capture / PRF gate as today; `flush_i` clears A1/A2/B1/B2 and lane records (the owner tables handle multi-cycle units).

Expected `// hyp8:` departures: (1) `resolved_branch_o` +2; (2) `flu_*` replaced by lanes; (3) `MultStages` 8 and the IQ class table; (4) the IRO forward network reads A1-low.
