## r91 — g6lc_ai_exec requant tweaks + Dot4Stages parameter

`core/cvxif_g6lc_ai/g6lc_ai_exec.sv` (+ `g6lc_ai_coprocessor.sv` param
plumbing, `verif/tb/ai_island/tb_g6lc_ai_exec_dot.sv` latency-agnostic
t0_check + D4S param). Baseline r90-ai: 79.5 in_to_reg L814.

### A. Exact requant tweaks (rank 0)
- `rq_half_q <= rq_half_sh[rq_sh]` registered at `ST_RQ && rq_ph_q==3`
  (same arm as `rq_sh0_q`); `rq_bump` reads it — the one-hot table
  lookup left the ST_RQ_R phase-0 cone.
- `rq_adj`/`rq_neg_rnd`/`rq_t_rnd` narrowed to 32 bits (only
  `rq_adj[31:0]` is consumed; two's complement mod 2^32 is exact).
  translate_off: `rq_neg_rnd == 32'(-rq_t_rnd)` + `rq_adj ==
  32'(rq_adj_ref48)` with the 48-bit form retained.
- `rq_mask_q` SKIPPED: `rq_mask` feeds the ST_RQ_S captures; that path
  is ~45 (well under the 77.4 module row), so no register was added.

### B. Dot4Stages parameter (rank 1)
- `parameter int unsigned Dot4Stages = 1` on g6lc_ai_exec and on
  g6lc_ai_coprocessor (passed to i_exec); legality `inside {1,2}`.
- `state_e` widened to logic [3:0]; `ST_DOT4 = 4'd8`.
- Dot4Stages==2: IDLE DOT4 arms capture `dot_p_q[4]` (17-bit
  `{ps[15],ps}`/`{1'b0,pu}` per opcode), `dot_acc_q` (DOT4A,
  NrRgprPorts>=3 else 0), `dot_sext_q`, and the mma_*_q identity;
  `state_d = ST_DOT4`. ST_DOT4 computes `dot_sum32` (5-operand add),
  `result_n = dot_sext_q ? XLEN'(signed'(dot_sum32)) : XLEN'(dot_sum32)`,
  we_n/valid_n/pmu_t0_n=1, `state_d = ST_IDLE`. dirty_n not set.
- Dot4Stages==1 arms are the original three case items byte-identical
  (dot4a_* temps hoisted to continuous assigns so result_n keeps a
  single select; NrRgprPorts>=3 kept as a procedural if/else).
- Header note: DOT4 latency 1->2, throughput 1/2 cycles under D4S=2.
- Coprocessor result handling: res_* tracks valid_o/result_o of i_exec;
  multi-cycle ops already hold issue while busy_o = (state_q != ST_IDLE)
  — the extra ST_DOT4 cycle reuses that handshake unchanged.

### Boards (board.sh <tag> g6lc_ai_exec [pmap])
- r91-ai1 (r88 map, Dot4Stages=1): **77.4 in_to_reg L920**
  (top path: ba 4.9 -> rs[bi] 18.1 -> ps 17.0 -> dot4_s_p -> dot4_s_sum
  13.0 -> dot4a_prod 0.0 -> result_n 23.5). vs r90-ai 79.5: -2.1.
- r91-ai2 (analysis/r91/param-map-dot4-2.json, Dot4Stages=2):
  **40.9 in_to_reg L341** (ba 4.9 -> rs[bi] 18.1 -> ps 17.0 -> dot4_s_p;
  the lane-product capture into dot_p_q is the new limiter; the 4-lane
  + result arms left the issue cycle). Second row 36.4 (dot_ff bundle).
  Iterations: merged case items regressed D1 to 102.9 (one result_n
  billed the merged cone); un-merge -> 83.9; hoisted dot4a_* + if/else
  -> 77.4.

### Gates (WSL, analysis/r91/run_hyp8_ai_exec_local.sh)
- tb_g6lc_ai_enq_ready: %Error at g6lc_ai_exec.sv:109 "index geometry is
  the hyp8 AiCfgOff normalisation" — identical pre-existing fatal
  (unchanged).
- tb_g6lc_ai_exec_dot D4S=1: PASS tb_g6lc_ai_exec_dot checks=452
- tb_g6lc_ai_exec_dot D4S=2: PASS tb_g6lc_ai_exec_dot checks=452
  (t0_check waits bounded for valid_o; check count unchanged).

Lead review: diff accepted (17-bit per-opcode product extension, 5-operand
completion sum, identity via the mma_*_q record, Dot4Stages=1 arm
byte-identical); line endings of the tb/board.sh restored to LF; gate
re-run by the lead: `PASS tb_g6lc_ai_exec_dot checks=452` at Dot4Stages=1
and =2 (`analysis/r91/ai-exec-gate.log`). Boards of record `r91-ai1`
(77.4, Dot4Stages=1) and `r91-ai2` (40.9, Dot4Stages=2).
