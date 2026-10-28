// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai I1/I3-lite: INT8 GEMM over AXI with banked tc_sram tiles + PE array.
//
//   C[i,j] (i32) = sum_t A[i,t]*B[j,t]
//
// AI-X9 operand layout (descriptor ContractVersion 2):
//   A row-major   [m][k], lda strides i, contiguous along t
//   B **k-major** [n][k], ldb strides j, contiguous along t
//   C row-major   [m][n], ldc = n
//
// Both operands have the REDUCTION axis contiguous. That is what lets one
// traversal and one format-scaling rule serve both, and it is what makes a
// sub-byte format expressible: two INT4 elements packed in a byte must feed the
// same C[i,j] accumulator, so they must be consecutive t. Rationale and the
// rejected alternatives: architecture/ai-matrix/numeric-formats-datapath.md §8.
//
// Phases:
//   1) Load A → banked tile SRAM (bank = t % PeLanes)
//      Multi-byte unpack; AXI INCR burst (up to MaxBurstBeats) along the row.
//   2) Load B → banked tile SRAM (bank = t % PeLanes), identical traversal to
//      A with j as the row index. One beat spreads across PeLanes banks at one
//      address each, so the tile is 1R1W like A's.
//   3) MAC: PeLanes parallel products/cycle via g6lc_ai_pe_dot
//   4) Store C: one 8-byte pair (or one 4-byte tail) per W beat, placed at
//      addr % BytesPerBeat. On a 64-bit bus that lane is 0. A wider bus keeps
//      aw.size at 8 (or 4) bytes so the pair does not fill the beat.
//      Multi-beat INCR AW (up to MaxBurstBeats pair-beats) along a C row;
//      dual-bank combo read so each W is one cycle when PeLanes>=2.
//      I3: trail-store completed rows during MAC (stc_i < mac_i) so C AW/W
//      rides free AXI cycles; drain tail after last MAC row.
//
// C multi-banked (j % PeLanes). Beat packing parameterized by DataWidth.
// Bursts stay within a single A row (k), B row (k), or C row (n); never cross.
//
// Bounds: m,n,k ∈ [1, MaxM/MaxN/MaxK], or MaxDim when those are 0.
// (MaxAROut) hides inter-burst memory latency on A/B loads; one AW.

module g6lc_ai_gemm_seq #(
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned DataWidth = 64,
    parameter int unsigned IdWidth   = 4,
    parameter int unsigned MaxDim    = 8,
    // 0 keeps the square MaxDim bound. The live island sets these apart
    // so 1024×128 and 512×256 fit without a 1024-cube.
    parameter int unsigned MaxM      = 0,
    parameter int unsigned MaxN      = 0,
    parameter int unsigned MaxK      = 0,
    parameter int unsigned PeLanes   = 4,  // K lanes per dot (power of two)
    // V2 column array: OutCols dot units share one A word and each reads its own
    // B row, so OutCols consecutive output columns complete per K step and the
    // MAC rate is OutCols x PeLanes. B is banked by column group (j % OutCols),
    // each group OperandWordsB/OutCols words, so the byte capacity is unchanged.
    // 1 is the single-dot engine (bit- and cycle-identical to the pre-V2 RTL).
    // Accumulate-mode jobs run one column at a time (their seed read owns the
    // single C read port); columns past n are masked.
    parameter int unsigned OutCols   = 1,
    parameter bit          DotPipeFloat = 1'b0, // 0: combinational g6lc_ai_pe_dot_float; 1: pipelined dot product with valid handshake
    // 0: combinational g6lc_ai_pe_dot (128 FO4 class); 1: g6lc_ai_pe_dot_pipe,
    // one tree level per stage on the SAME latency as the float pipe.
    parameter bit          DotPipeInt   = 1'b0,
    parameter int unsigned MaxAROut  = 2,  // I3: multi-outstanding AR; live = 2
    // Shared DRAM stripe (g6lc_ai_island_cfg_pkg). N=1 leaves MaxBurstBeats
    // at 255 so the live 256³ fixture stays bit-identical. N>1 caps each
    // INCR at the 64 B stripe so GEMM and core L2 fills share one map.
    parameter int unsigned NrChannels = 1,
    parameter int unsigned ChanShift  = 6,
    parameter bit          ReuseBEn  = 1'b0,
    // Resident-B directory depth (VA-Turbo). With 2 slots the B bank is split in
    // halves and two panels that each fit a half stay resident together, so a
    // layer whose N spans two panels (the decode case that alternates them every
    // token) still hits. A panel that needs more than a half takes the whole bank
    // ("big") and evicts the other slot. 1 = the single resident key.
    parameter int unsigned ReuseBSlots = 2,
    parameter bit          ReuseAEn   = 1'b0,
    parameter int unsigned MaxElementBytes = 4,
    // Hyp timing seam: three elastic boundaries (AR, AW/W, R/B). Bypass is
    // available for ablation; job-visible completion still waits for B/R drain.
    parameter bit          AxiCuts = 1'b1,
    parameter type         axi_req_t  = logic,
    parameter type         axi_resp_t = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,
    input  logic        start_i,
    input  logic [31:0] m_i,
    input  logic [31:0] n_i,
    input  logic [31:0] k_i,
    input  logic [15:0] lda_i,
    input  logic [15:0] ldb_i,
    // C row pitch in elements (0 = n, the single-engine contract). A cluster
    // dispatch hands each engine a column slice of one C panel, so the slice's
    // rows are `ldc` apart while its width is the slice's n.
    input  logic [15:0] ldc_i,
    input  logic [2:0]  numfmt_i,
    // flags.accmode == 01: seed every C[i][j] reduction from the word already in
    // memory (ST_LC loads the C tile first). The top grants/refuses; this only executes.
    input  logic        accumulate_i,
    input  logic [3:0]  ar_max_i,  // 0 = use parameter MaxAROut
    input  logic [AddrWidth-1:0] ptr_a_i,
    input  logic [AddrWidth-1:0] ptr_b_i,
    input  logic [AddrWidth-1:0] ptr_c_i,
    output logic        ready_o,
    output logic        done_o,
    output logic        err_o,
    // I3 PMU: sticky after last job (cleared on next start)
    output logic [31:0] pmu_r_beats_o,
    output logic [31:0] pmu_w_beats_o,
    output logic [31:0] pmu_cycles_o,
    // Stage-2 characterization: per-job cycles in each phase and stalled handshakes.
    // {STC, MAC, LB, LA} phase cycles; AR held without ready, R valid without ready
    // (MAC-side backpressure), W held without ready. Reset at job start like the others.
    output logic [3:0][31:0] pmu_phase_o,
    output logic [2:0][31:0] pmu_stall_o,
    input  logic        reuse_b_i,
    input  logic [31:0] reuse_b_epoch_i,
    input  logic        reuse_b_invalidate_i,
    output logic        pmu_reuse_b_hit_o,
    input  logic        reuse_a_i,
    input  logic [31:0] reuse_a_epoch_i,
    input  logic        reuse_a_invalidate_i,
    output logic        pmu_reuse_a_hit_o,
    output axi_req_t    axi_req_o,
    input  axi_resp_t   axi_resp_i
);

  // Bit-granular copies of the AXI aggregates. The master's ready signals may depend
  // on the slave's valids (legal), but on a whole-struct view that reads as a
  // request<->response loop; splitting keeps Verilator's cycle check exact.
  axi_req_t  axi_req_d /*verilator split_var*/;
  axi_resp_t axi_resp_s /*verilator split_var*/;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_gemm_seq  region=6870  makespan=14.500 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ar_hold_q  ready_cycle=2  ready_fo4=14.500  OpenSTA: report_timing -from clk_i -to ar_hold_q
// order expect: ar_hold_slot_q  ready_cycle=2  ready_fo4=14.500  OpenSTA: report_timing -from clk_i -to ar_hold_slot_q
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node24100 c=3.50 slack=11.00 */
//     /* node24101 c=3.50 slack=11.00 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ar_hold_q <= …; // sv-timing: cycle 2/2 on clk_i
//     ar_hold_slot_q <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node24102 c=13.50 slack=1.00 */
//     /* node24103 c=13.50 slack=1.00 */
//     /* node24104 c=14.50 slack=0.00 */
//     /* node24105 c=14.50 slack=0.00 */
//     /* node24106 c=14.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_gemm_seq  region=6883  makespan=5.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: dot_cv_pipe  ready_cycle=1  ready_fo4=5.500  OpenSTA: report_timing -from clk_i -to dot_cv_pipe
// order expect: dot_first_pipe  ready_cycle=1  ready_fo4=5.500  OpenSTA: report_timing -from clk_i -to dot_first_pipe
// order expect: dot_i_pipe  ready_cycle=1  ready_fo4=5.500  OpenSTA: report_timing -from clk_i -to dot_i_pipe
// order expect: dot_j_pipe  ready_cycle=1  ready_fo4=5.500  OpenSTA: report_timing -from clk_i -to dot_j_pipe
// order expect: dot_last_pipe  ready_cycle=1  ready_fo4=5.500  OpenSTA: report_timing -from clk_i -to dot_last_pipe
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     dot_cv_pipe <= …; // sv-timing: cycle 1/1 on clk_i
//     dot_first_pipe <= …; // sv-timing: cycle 1/1 on clk_i
//     dot_i_pipe <= …; // sv-timing: cycle 1/1 on clk_i
//     dot_j_pipe <= …; // sv-timing: cycle 1/1 on clk_i
//     dot_last_pipe <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node24134 c=3.50 slack=2.00 */
//     /* node24135 c=3.50 slack=2.00 */
//     /* node24136 c=3.50 slack=2.00 */
//     /* node24137 c=3.50 slack=2.00 */
//     /* node24138 c=3.50 slack=2.00 */
//     /* node24139 c=5.50 slack=0.00 */
//     /* node24140 c=5.50 slack=0.00 */
//     /* node24141 c=5.50 slack=0.00 */
//     /* node24142 c=5.50 slack=0.00 */
//     /* node24143 c=5.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_gemm_seq  region=6916  makespan=65.500 FO4  cycle_count=9  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: b_base_q  ready_cycle=9  ready_fo4=65.500  OpenSTA: report_timing -from clk_i -to b_base_q
// order expect: big_q  ready_cycle=2  ready_fo4=15.500  OpenSTA: report_timing -from clk_i -to big_q
// order expect: cacheable_q  ready_cycle=2  ready_fo4=14.500  OpenSTA: report_timing -from clk_i -to cacheable_q
// order expect: cur_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to cur_q
// order expect: epoch_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to epoch_q
// order expect: fmt_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to fmt_q
// order expect: invalidated_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to invalidated_q
// order expect: job_epoch_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to job_epoch_q
// order expect: k_saved_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to k_saved_q
// order expect: ldb_saved_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to ldb_saved_q
// order expect: n_saved_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to n_saved_q
// order expect: pmu_reuse_b_hit_o  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to pmu_reuse_b_hit_o
// order expect: ptr_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to ptr_q
// order expect: reuse_b_skip_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to reuse_b_skip_q
// order expect: valid_q  ready_cycle=2  ready_fo4=15.500  OpenSTA: report_timing -from clk_i -to valid_q
// order expect: victim_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to victim_q
// --- factor stage 1/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node24180 c=3.50 slack=62.00 */
//     /* node24181 c=3.50 slack=62.00 */
//     /* node24182 c=3.50 slack=62.00 */
//     /* node24183 c=3.50 slack=62.00 */
//     /* node24184 c=3.50 slack=62.00 */
//     /* node24185 c=3.50 slack=62.00 */
//     /* node24186 c=3.50 slack=62.00 */
//     /* node24187 c=3.50 slack=62.00 */
//     /* node24188 c=3.50 slack=62.00 */
//     /* node24189 c=3.50 slack=62.00 */
//     /* node24190 c=3.50 slack=62.00 */
//     /* node24191 c=3.50 slack=62.00 */
//     /* node24192 c=3.50 slack=62.00 */
//     /* node24193 c=3.50 slack=62.00 */
//     /* node24194 c=3.50 slack=62.00 */
//     /* node24195 c=3.50 slack=62.00 */
//     /* node24219 c=4.50 slack=61.00 */
//     /* node24220 c=4.50 slack=61.00 */
//     /* node24221 c=4.50 slack=61.00 */
//   end
// end
// --- factor stage 2/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     big_q <= …; // sv-timing: cycle 2/9 on clk_i
//     cacheable_q <= …; // sv-timing: cycle 2/9 on clk_i
//     cur_q <= …; // sv-timing: cycle 2/9 on clk_i
//     epoch_q <= …; // sv-timing: cycle 2/9 on clk_i
//     fmt_q <= …; // sv-timing: cycle 2/9 on clk_i
//     invalidated_q <= …; // sv-timing: cycle 2/9 on clk_i
//     job_epoch_q <= …; // sv-timing: cycle 2/9 on clk_i
//     k_saved_q <= …; // sv-timing: cycle 2/9 on clk_i
//     ldb_saved_q <= …; // sv-timing: cycle 2/9 on clk_i
//     n_saved_q <= …; // sv-timing: cycle 2/9 on clk_i
//     pmu_reuse_b_hit_o <= …; // sv-timing: cycle 2/9 on clk_i
//     ptr_q <= …; // sv-timing: cycle 2/9 on clk_i
//     reuse_b_skip_q <= …; // sv-timing: cycle 2/9 on clk_i
//     valid_q <= …; // sv-timing: cycle 2/9 on clk_i
//     victim_q <= …; // sv-timing: cycle 2/9 on clk_i
//     /* node24196 c=13.50 slack=52.00 */
//     /* node24197 c=13.50 slack=52.00 */
//     /* node24198 c=13.50 slack=52.00 */
//     /* node24199 c=13.50 slack=52.00 */
//     /* node24200 c=13.50 slack=52.00 */
//     /* node24201 c=13.50 slack=52.00 */
//     /* node24202 c=13.50 slack=52.00 */
//     /* node24203 c=14.50 slack=51.00 */
//     /* node24205 c=15.50 slack=50.00 */
//     /* node24206 c=15.50 slack=50.00 */
//     /* node24207 c=15.50 slack=50.00 */
//     /* node24208 c=15.50 slack=50.00 */
//     /* node24209 c=15.50 slack=50.00 */
//     /* node24210 c=9.50 slack=56.00 */
//     /* node24211 c=12.50 slack=53.00 */
//     /* node24212 c=12.50 slack=53.00 */
//     /* node24213 c=12.50 slack=53.00 */
//     /* node24214 c=12.50 slack=53.00 */
//     /* node24215 c=12.50 slack=53.00 */
//     /* node24216 c=12.50 slack=53.00 */
//     /* node24217 c=12.50 slack=53.00 */
//     /* node24218 c=11.50 slack=54.00 */
//   end
// end
// --- factor stage 3/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 3: no capture on this edge (slack) */
//   end
// end
// --- factor stage 4/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 4: no capture on this edge (slack) */
//   end
// end
// --- factor stage 5/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 5: no capture on this edge (slack) */
//   end
// end
// --- factor stage 6/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 6: no capture on this edge (slack) */
//   end
// end
// --- factor stage 7/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 7: no capture on this edge (slack) */
//   end
// end
// --- factor stage 8/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 8: no capture on this edge (slack) */
//   end
// end
// --- factor stage 9/9  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     b_base_q <= …; // sv-timing: cycle 9/9 on clk_i
//     /* node24204 c=65.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_gemm_seq  region=6929  makespan=18.300 FO4  cycle_count=3  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: cacheable_q  ready_cycle=2  ready_fo4=14.500  OpenSTA: report_timing -from clk_i -to cacheable_q
// order expect: epoch_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to epoch_q
// order expect: fmt_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to fmt_q
// order expect: invalidated_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to invalidated_q
// order expect: job_epoch_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to job_epoch_q
// order expect: k_saved_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to k_saved_q
// order expect: lda_saved_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to lda_saved_q
// order expect: m_saved_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to m_saved_q
// order expect: pmu_reuse_a_hit_o  ready_cycle=2  ready_fo4=15.500  OpenSTA: report_timing -from clk_i -to pmu_reuse_a_hit_o
// order expect: ptr_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to ptr_q
// order expect: reuse_a_skip_q  ready_cycle=3  ready_fo4=18.300  OpenSTA: report_timing -from clk_i -to reuse_a_skip_q
// order expect: valid_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to valid_q
// --- factor stage 1/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node24234 c=3.50 slack=14.80 */
//     /* node24235 c=3.50 slack=14.80 */
//     /* node24236 c=3.50 slack=14.80 */
//     /* node24237 c=3.50 slack=14.80 */
//     /* node24238 c=3.50 slack=14.80 */
//     /* node24239 c=3.50 slack=14.80 */
//     /* node24240 c=3.50 slack=14.80 */
//     /* node24241 c=3.50 slack=14.80 */
//     /* node24242 c=3.50 slack=14.80 */
//     /* node24243 c=3.50 slack=14.80 */
//     /* node24244 c=3.50 slack=14.80 */
//     /* node24245 c=3.50 slack=14.80 */
//     /* node24261 c=4.85 slack=13.45 */
//     /* node24262 c=4.85 slack=13.45 */
//     /* node24263 c=4.85 slack=13.45 */
//     /* node24264 c=4.85 slack=13.45 */
//   end
// end
// --- factor stage 2/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cacheable_q <= …; // sv-timing: cycle 2/3 on clk_i
//     epoch_q <= …; // sv-timing: cycle 2/3 on clk_i
//     fmt_q <= …; // sv-timing: cycle 2/3 on clk_i
//     invalidated_q <= …; // sv-timing: cycle 2/3 on clk_i
//     job_epoch_q <= …; // sv-timing: cycle 2/3 on clk_i
//     k_saved_q <= …; // sv-timing: cycle 2/3 on clk_i
//     lda_saved_q <= …; // sv-timing: cycle 2/3 on clk_i
//     m_saved_q <= …; // sv-timing: cycle 2/3 on clk_i
//     pmu_reuse_a_hit_o <= …; // sv-timing: cycle 2/3 on clk_i
//     ptr_q <= …; // sv-timing: cycle 2/3 on clk_i
//     valid_q <= …; // sv-timing: cycle 2/3 on clk_i
//     /* node24246 c=13.50 slack=4.80 */
//     /* node24248 c=13.50 slack=4.80 */
//     /* node24249 c=13.50 slack=4.80 */
//     /* node24250 c=13.50 slack=4.80 */
//     /* node24251 c=13.50 slack=4.80 */
//     /* node24252 c=14.50 slack=3.80 */
//     /* node24253 c=15.50 slack=2.80 */
//     /* node24254 c=11.50 slack=6.80 */
//     /* node24255 c=11.50 slack=6.80 */
//     /* node24256 c=11.50 slack=6.80 */
//     /* node24257 c=11.50 slack=6.80 */
//     /* node24258 c=11.50 slack=6.80 */
//     /* node24259 c=11.50 slack=6.80 */
//     /* node24260 c=11.50 slack=6.80 */
//   end
// end
// --- factor stage 3/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     reuse_a_skip_q <= …; // sv-timing: cycle 3/3 on clk_i
//     /* node24247 c=18.30 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_gemm_seq  region=6941  makespan=19.300 FO4  cycle_count=3  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: pmu_phase_q  ready_cycle=3  ready_fo4=19.300  OpenSTA: report_timing -from clk_i -to pmu_phase_q
// order expect: pmu_stall_q  ready_cycle=3  ready_fo4=19.300  OpenSTA: report_timing -from clk_i -to pmu_stall_q
// --- factor stage 1/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node24276 c=3.50 slack=15.80 */
//     /* node24277 c=3.50 slack=15.80 */
//   end
// end
// --- factor stage 2/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 2: no capture on this edge (slack) */
//     /* node24278 c=13.50 slack=5.80 */
//     /* node24279 c=13.50 slack=5.80 */
//   end
// end
// --- factor stage 3/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     pmu_phase_q <= …; // sv-timing: cycle 3/3 on clk_i
//     pmu_stall_q <= …; // sv-timing: cycle 3/3 on clk_i
//     /* node24280 c=19.30 slack=0.00 */
//     /* node24281 c=19.30 slack=0.00 */
//     /* node24282 c=19.30 slack=0.00 */
//     /* node24283 c=19.30 slack=0.00 */
//     /* node24284 c=19.30 slack=0.00 */
//     /* node24285 c=19.30 slack=0.00 */
//     /* node24286 c=19.30 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_gemm_seq  region=6953  makespan=40.000 FO4  cycle_count=5  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: acc_mode_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to acc_mode_q
// order expect: acc_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to acc_q
// order expect: ar_i_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to ar_i_q
// order expect: ar_inflight_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to ar_inflight_q
// order expect: ar_j_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to ar_j_q
// order expect: ar_lane_mem_q  ready_cycle=2  ready_fo4=9.350  OpenSTA: report_timing -from clk_i -to ar_lane_mem_q
// order expect: ar_slot_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to ar_slot_q
// order expect: ar_t_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to ar_t_q
// order expect: aw_sent_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to aw_sent_q
// order expect: burst_first_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to burst_first_q
// order expect: c_cols_done_q  ready_cycle=5  ready_fo4=40.000  OpenSTA: report_timing -from clk_i -to c_cols_done_q
// order expect: c_cols_row_q  ready_cycle=3  ready_fo4=19.700  OpenSTA: report_timing -from clk_i -to c_cols_row_q
// order expect: c_lo_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to c_lo_q
// order expect: c_pair_hold_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to c_pair_hold_q
// order expect: c_rows_done_q  ready_cycle=3  ready_fo4=18.500  OpenSTA: report_timing -from clk_i -to c_rows_done_q
// order expect: done_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to done_q
// order expect: dot_pending_q  ready_cycle=3  ready_fo4=17.665  OpenSTA: report_timing -from clk_i -to dot_pending_q
// order expect: err_q  ready_cycle=2  ready_fo4=10.500  OpenSTA: report_timing -from clk_i -to err_q
// order expect: i_q  ready_cycle=3  ready_fo4=22.500  OpenSTA: report_timing -from clk_i -to i_q
// order expect: j_q  ready_cycle=3  ready_fo4=22.500  OpenSTA: report_timing -from clk_i -to j_q
// order expect: k_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to k_q
// order expect: lda_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to lda_q
// order expect: ldb_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to ldb_q
// order expect: ldc_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to ldc_q
// order expect: m_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to m_q
// order expect: n_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to n_q
// order expect: numfmt_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to numfmt_q
// order expect: pa_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to pa_q
// order expect: pb_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to pb_q
// order expect: pc_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to pc_q
// order expect: pitch_sh_q  ready_cycle=2  ready_fo4=14.500  OpenSTA: report_timing -from clk_i -to pitch_sh_q
// order expect: pmu_cy_q  ready_cycle=3  ready_fo4=18.300  OpenSTA: report_timing -from clk_i -to pmu_cy_q
// order expect: pmu_r_q  ready_cycle=3  ready_fo4=20.300  OpenSTA: report_timing -from clk_i -to pmu_r_q
// order expect: pmu_w_q  ready_cycle=3  ready_fo4=20.300  OpenSTA: report_timing -from clk_i -to pmu_w_q
// order expect: state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to state_q
// order expect: stc_elem_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to stc_elem_q
// order expect: stc_i_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to stc_i_q
// order expect: stc_j_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to stc_j_q
// order expect: stc_w_left_q  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to stc_w_left_q
// order expect: sum_cv_q  ready_cycle=2  ready_fo4=9.000  OpenSTA: report_timing -from clk_i -to sum_cv_q
// order expect: sum_first_q  ready_cycle=2  ready_fo4=9.000  OpenSTA: report_timing -from clk_i -to sum_first_q
// order expect: sum_i_q  ready_cycle=2  ready_fo4=9.000  OpenSTA: report_timing -from clk_i -to sum_i_q
// order expect: sum_j_q  ready_cycle=2  ready_fo4=9.000  OpenSTA: report_timing -from clk_i -to sum_j_q
// order expect: sum_last_q  ready_cycle=2  ready_fo4=9.000  OpenSTA: report_timing -from clk_i -to sum_last_q
// order expect: sum_q  ready_cycle=2  ready_fo4=9.000  OpenSTA: report_timing -from clk_i -to sum_q
// order expect: sum_v_q  ready_cycle=2  ready_fo4=8.500  OpenSTA: report_timing -from clk_i -to sum_v_q
// order expect: t_q  ready_cycle=3  ready_fo4=22.500  OpenSTA: report_timing -from clk_i -to t_q
// order expect: w_sent_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_sent_q
// order expect: wide_c_q  ready_cycle=2  ready_fo4=14.500  OpenSTA: report_timing -from clk_i -to wide_c_q
// order expect: wsh_q  ready_cycle=3  ready_fo4=17.000  OpenSTA: report_timing -from clk_i -to wsh_q
// --- factor stage 1/5  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     acc_q <= …; // sv-timing: cycle 1/5 on clk_i
//     aw_sent_q <= …; // sv-timing: cycle 1/5 on clk_i
//     c_lo_q <= …; // sv-timing: cycle 1/5 on clk_i
//     done_q <= …; // sv-timing: cycle 1/5 on clk_i
//     state_q <= …; // sv-timing: cycle 1/5 on clk_i
//     w_sent_q <= …; // sv-timing: cycle 1/5 on clk_i
//     /* node24807 c=3.50 slack=36.50 */
//     /* node24808 c=3.50 slack=36.50 */
//     /* node24809 c=3.50 slack=36.50 */
//     /* node24810 c=3.50 slack=36.50 */
//     /* node24811 c=3.50 slack=36.50 */
//     /* node24812 c=3.50 slack=36.50 */
//     /* node24813 c=3.50 slack=36.50 */
//     /* node24814 c=3.50 slack=36.50 */
//     /* node24815 c=3.50 slack=36.50 */
//     /* node24816 c=3.50 slack=36.50 */
//     /* node24817 c=3.50 slack=36.50 */
//     /* node24818 c=3.50 slack=36.50 */
//     /* node24819 c=3.50 slack=36.50 */
//     /* node24820 c=3.50 slack=36.50 */
//     /* node24821 c=3.50 slack=36.50 */
//     /* node24822 c=3.50 slack=36.50 */
//     /* node24823 c=3.50 slack=36.50 */
//     /* node24824 c=3.50 slack=36.50 */
//     /* node24825 c=3.50 slack=36.50 */
//     /* node24826 c=3.50 slack=36.50 */
//     /* node24827 c=3.50 slack=36.50 */
//     /* node24828 c=3.50 slack=36.50 */
//     /* node24829 c=3.50 slack=36.50 */
//     /* node24830 c=3.50 slack=36.50 */
//     /* node24831 c=3.50 slack=36.50 */
//     /* node24832 c=3.50 slack=36.50 */
//     /* node24833 c=3.50 slack=36.50 */
//     /* node24834 c=3.50 slack=36.50 */
//     /* node24835 c=3.50 slack=36.50 */
//     /* node24836 c=3.50 slack=36.50 */
//     /* node24837 c=3.50 slack=36.50 */
//     /* node24838 c=3.50 slack=36.50 */
//     /* node24839 c=3.50 slack=36.50 */
//     /* node24840 c=3.50 slack=36.50 */
//     /* node24841 c=3.50 slack=36.50 */
//     /* node24842 c=3.50 slack=36.50 */
//     /* node24843 c=3.50 slack=36.50 */
//     /* node24844 c=3.50 slack=36.50 */
//     /* node24845 c=3.50 slack=36.50 */
//     /* node24846 c=3.50 slack=36.50 */
//     /* node24847 c=3.50 slack=36.50 */
//     /* node24848 c=3.50 slack=36.50 */
//     /* node24849 c=3.50 slack=36.50 */
//     /* node24850 c=3.50 slack=36.50 */
//     /* node24851 c=3.50 slack=36.50 */
//     /* node24852 c=3.50 slack=36.50 */
//     /* node24853 c=3.50 slack=36.50 */
//     /* node24854 c=3.50 slack=36.50 */
//     /* node24855 c=3.50 slack=36.50 */
//     /* node24856 c=3.50 slack=36.50 */
//     /* node24857 c=3.50 slack=36.50 */
//     /* node24858 c=3.50 slack=36.50 */
//     /* node24873 c=3.50 slack=36.50 */
//     /* node24877 c=3.50 slack=36.50 */
//     /* node24878 c=3.50 slack=36.50 */
//     /* node24879 c=3.50 slack=36.50 */
//     /* node24880 c=3.50 slack=36.50 */
//     /* node24881 c=4.50 slack=35.50 */
//     /* node24882 c=4.50 slack=35.50 */
//     /* node24883 c=4.50 slack=35.50 */
//     /* node24889 c=0.00 slack=40.00 */
//     /* node24890 c=0.00 slack=40.00 */
//     /* node24891 c=0.00 slack=40.00 */
//     /* node24892 c=0.00 slack=40.00 */
//     /* node24893 c=0.00 slack=40.00 */
//     /* node24894 c=0.00 slack=40.00 */
//     /* node24895 c=0.00 slack=40.00 */
//     /* node24896 c=0.00 slack=40.00 */
//     /* node24897 c=0.00 slack=40.00 */
//     /* node24898 c=0.00 slack=40.00 */
//     /* node24899 c=3.50 slack=36.50 */
//     /* node24900 c=3.50 slack=36.50 */
//     /* node24901 c=3.50 slack=36.50 */
//     /* node24903 c=4.50 slack=35.50 */
//     /* node24907 c=3.50 slack=36.50 */
//     /* node24970 c=4.50 slack=35.50 */
//     /* node24971 c=4.50 slack=35.50 */
//     /* node24972 c=6.50 slack=33.50 */
//   end
// end
// --- factor stage 2/5  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     acc_mode_q <= …; // sv-timing: cycle 2/5 on clk_i
//     ar_i_q <= …; // sv-timing: cycle 2/5 on clk_i
//     ar_inflight_q <= …; // sv-timing: cycle 2/5 on clk_i
//     ar_j_q <= …; // sv-timing: cycle 2/5 on clk_i
//     ar_lane_mem_q <= …; // sv-timing: cycle 2/5 on clk_i
//     ar_slot_q <= …; // sv-timing: cycle 2/5 on clk_i
//     ar_t_q <= …; // sv-timing: cycle 2/5 on clk_i
//     burst_first_q <= …; // sv-timing: cycle 2/5 on clk_i
//     c_pair_hold_q <= …; // sv-timing: cycle 2/5 on clk_i
//     err_q <= …; // sv-timing: cycle 2/5 on clk_i
//     k_q <= …; // sv-timing: cycle 2/5 on clk_i
//     lda_q <= …; // sv-timing: cycle 2/5 on clk_i
//     ldb_q <= …; // sv-timing: cycle 2/5 on clk_i
//     ldc_q <= …; // sv-timing: cycle 2/5 on clk_i
//     m_q <= …; // sv-timing: cycle 2/5 on clk_i
//     n_q <= …; // sv-timing: cycle 2/5 on clk_i
//     numfmt_q <= …; // sv-timing: cycle 2/5 on clk_i
//     pa_q <= …; // sv-timing: cycle 2/5 on clk_i
//     pb_q <= …; // sv-timing: cycle 2/5 on clk_i
//     pc_q <= …; // sv-timing: cycle 2/5 on clk_i
//     pitch_sh_q <= …; // sv-timing: cycle 2/5 on clk_i
//     stc_elem_q <= …; // sv-timing: cycle 2/5 on clk_i
//     stc_i_q <= …; // sv-timing: cycle 2/5 on clk_i
//     stc_j_q <= …; // sv-timing: cycle 2/5 on clk_i
//     stc_w_left_q <= …; // sv-timing: cycle 2/5 on clk_i
//     sum_cv_q <= …; // sv-timing: cycle 2/5 on clk_i
//     sum_first_q <= …; // sv-timing: cycle 2/5 on clk_i
//     sum_i_q <= …; // sv-timing: cycle 2/5 on clk_i
//     sum_j_q <= …; // sv-timing: cycle 2/5 on clk_i
//     sum_last_q <= …; // sv-timing: cycle 2/5 on clk_i
//     sum_q <= …; // sv-timing: cycle 2/5 on clk_i
//     sum_v_q <= …; // sv-timing: cycle 2/5 on clk_i
//     wide_c_q <= …; // sv-timing: cycle 2/5 on clk_i
//     /* node24859 c=9.00 slack=31.00 */
//     /* node24860 c=9.00 slack=31.00 */
//     /* node24861 c=8.50 slack=31.50 */
//     /* node24862 c=9.00 slack=31.00 */
//     /* node24863 c=9.00 slack=31.00 */
//     /* node24864 c=9.00 slack=31.00 */
//     /* node24865 c=9.00 slack=31.00 */
//     /* node24866 c=8.50 slack=31.50 */
//     /* node24867 c=8.50 slack=31.50 */
//     /* node24868 c=8.50 slack=31.50 */
//     /* node24869 c=8.50 slack=31.50 */
//     /* node24870 c=8.50 slack=31.50 */
//     /* node24871 c=8.50 slack=31.50 */
//     /* node24872 c=8.50 slack=31.50 */
//     /* node24874 c=14.50 slack=25.50 */
//     /* node24875 c=14.50 slack=25.50 */
//     /* node24884 c=8.35 slack=31.65 */
//     /* node24885 c=9.35 slack=30.65 */
//     /* node24886 c=9.35 slack=30.65 */
//     /* node24887 c=9.35 slack=30.65 */
//     /* node24888 c=9.35 slack=30.65 */
//     /* node24911 c=13.50 slack=26.50 */
//     /* node24912 c=13.50 slack=26.50 */
//     /* node24913 c=13.50 slack=26.50 */
//     /* node24914 c=13.50 slack=26.50 */
//     /* node24915 c=13.50 slack=26.50 */
//     /* node24916 c=13.50 slack=26.50 */
//     /* node24917 c=13.50 slack=26.50 */
//     /* node24918 c=13.50 slack=26.50 */
//     /* node24919 c=13.50 slack=26.50 */
//     /* node24920 c=13.50 slack=26.50 */
//     /* node24921 c=13.50 slack=26.50 */
//     /* node24922 c=13.50 slack=26.50 */
//     /* node24923 c=13.50 slack=26.50 */
//     /* node24924 c=13.50 slack=26.50 */
//     /* node24925 c=13.50 slack=26.50 */
//     /* node24926 c=13.50 slack=26.50 */
//     /* node24927 c=13.50 slack=26.50 */
//     /* node24928 c=13.50 slack=26.50 */
//     /* node24929 c=13.50 slack=26.50 */
//     /* node24930 c=13.50 slack=26.50 */
//     /* node24931 c=13.50 slack=26.50 */
//     /* node24932 c=13.50 slack=26.50 */
//     /* node24933 c=13.50 slack=26.50 */
//     /* node24934 c=13.50 slack=26.50 */
//     /* node24935 c=13.50 slack=26.50 */
//     /* node24936 c=13.50 slack=26.50 */
//     /* node24937 c=13.50 slack=26.50 */
//     /* node24938 c=13.50 slack=26.50 */
//     /* node24939 c=13.50 slack=26.50 */
//     /* node24940 c=13.50 slack=26.50 */
//     /* node24941 c=13.50 slack=26.50 */
//     /* node24942 c=12.50 slack=27.50 */
//     /* node24943 c=12.50 slack=27.50 */
//     /* node24944 c=12.50 slack=27.50 */
//     /* node24945 c=12.50 slack=27.50 */
//     /* node24946 c=12.50 slack=27.50 */
//     /* node24947 c=12.50 slack=27.50 */
//     /* node24948 c=11.50 slack=28.50 */
//     /* node24949 c=11.50 slack=28.50 */
//     /* node24950 c=11.50 slack=28.50 */
//     /* node24951 c=10.50 slack=29.50 */
//     /* node24958 c=10.50 slack=29.50 */
//   end
// end
// --- factor stage 3/5  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     c_cols_row_q <= …; // sv-timing: cycle 3/5 on clk_i
//     c_rows_done_q <= …; // sv-timing: cycle 3/5 on clk_i
//     dot_pending_q <= …; // sv-timing: cycle 3/5 on clk_i
//     i_q <= …; // sv-timing: cycle 3/5 on clk_i
//     j_q <= …; // sv-timing: cycle 3/5 on clk_i
//     pmu_cy_q <= …; // sv-timing: cycle 3/5 on clk_i
//     pmu_r_q <= …; // sv-timing: cycle 3/5 on clk_i
//     pmu_w_q <= …; // sv-timing: cycle 3/5 on clk_i
//     t_q <= …; // sv-timing: cycle 3/5 on clk_i
//     wsh_q <= …; // sv-timing: cycle 3/5 on clk_i
//     /* node24876 c=17.00 slack=23.00 */
//     /* node24902 c=17.66 slack=22.34 */
//     /* node24904 c=18.50 slack=21.50 */
//     /* node24905 c=19.70 slack=20.30 */
//     /* node24908 c=18.30 slack=21.70 */
//     /* node24909 c=20.30 slack=19.70 */
//     /* node24910 c=20.30 slack=19.70 */
//     /* node24952 c=21.50 slack=18.50 */
//     /* node24953 c=21.50 slack=18.50 */
//     /* node24954 c=21.50 slack=18.50 */
//     /* node24955 c=21.50 slack=18.50 */
//     /* node24956 c=21.50 slack=18.50 */
//     /* node24957 c=21.50 slack=18.50 */
//     /* node24959 c=21.50 slack=18.50 */
//     /* node24960 c=21.50 slack=18.50 */
//     /* node24961 c=21.50 slack=18.50 */
//     /* node24962 c=21.50 slack=18.50 */
//     /* node24963 c=21.50 slack=18.50 */
//     /* node24964 c=21.50 slack=18.50 */
//     /* node24965 c=22.50 slack=17.50 */
//     /* node24966 c=22.50 slack=17.50 */
//     /* node24967 c=22.50 slack=17.50 */
//     /* node24968 c=22.50 slack=17.50 */
//     /* node24969 c=22.50 slack=17.50 */
//   end
// end
// --- factor stage 4/5  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 4: no capture on this edge (slack) */
//   end
// end
// --- factor stage 5/5  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     c_cols_done_q <= …; // sv-timing: cycle 5/5 on clk_i
//     /* node24906 c=40.00 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_gemm_seq  region=6954  makespan=89.200 FO4  cycle_count=12  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: lc_ar_busy_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to lc_ar_busy_q
// order expect: lc_beats_q  ready_cycle=12  ready_fo4=89.200  OpenSTA: report_timing -from clk_i -to lc_beats_q
// order expect: lc_buf_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to lc_buf_q
// order expect: lc_buf_v_q  ready_cycle=3  ready_fo4=17.500  OpenSTA: report_timing -from clk_i -to lc_buf_v_q
// order expect: lc_burst_left_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to lc_burst_left_q
// order expect: lc_e_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to lc_e_q
// order expect: lc_i_q  ready_cycle=3  ready_fo4=16.500  OpenSTA: report_timing -from clk_i -to lc_i_q
// order expect: lc_issued_q  ready_cycle=3  ready_fo4=16.500  OpenSTA: report_timing -from clk_i -to lc_issued_q
// order expect: lc_j_q  ready_cycle=3  ready_fo4=16.500  OpenSTA: report_timing -from clk_i -to lc_j_q
// order expect: lc_recv_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to lc_recv_q
// order expect: lc_total_q  ready_cycle=8  ready_fo4=62.500  OpenSTA: report_timing -from clk_i -to lc_total_q
// order expect: lc_word_q  ready_cycle=3  ready_fo4=17.500  OpenSTA: report_timing -from clk_i -to lc_word_q
// --- factor stage 1/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node24973 c=3.50 slack=85.70 */
//     /* node24974 c=3.50 slack=85.70 */
//     /* node24975 c=3.50 slack=85.70 */
//     /* node24976 c=3.50 slack=85.70 */
//     /* node24977 c=3.50 slack=85.70 */
//     /* node24978 c=3.50 slack=85.70 */
//     /* node24979 c=3.50 slack=85.70 */
//     /* node24980 c=3.50 slack=85.70 */
//     /* node24981 c=3.50 slack=85.70 */
//     /* node24982 c=3.50 slack=85.70 */
//     /* node24983 c=3.50 slack=85.70 */
//     /* node24984 c=3.50 slack=85.70 */
//   end
// end
// --- factor stage 2/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     lc_ar_busy_q <= …; // sv-timing: cycle 2/12 on clk_i
//     lc_buf_q <= …; // sv-timing: cycle 2/12 on clk_i
//     lc_burst_left_q <= …; // sv-timing: cycle 2/12 on clk_i
//     lc_e_q <= …; // sv-timing: cycle 2/12 on clk_i
//     lc_recv_q <= …; // sv-timing: cycle 2/12 on clk_i
//     /* node24987 c=11.50 slack=77.70 */
//     /* node24988 c=11.50 slack=77.70 */
//     /* node24989 c=11.50 slack=77.70 */
//     /* node24990 c=11.50 slack=77.70 */
//     /* node24991 c=11.50 slack=77.70 */
//     /* node24992 c=11.50 slack=77.70 */
//     /* node24993 c=11.50 slack=77.70 */
//     /* node24994 c=11.50 slack=77.70 */
//     /* node24995 c=11.50 slack=77.70 */
//     /* node24996 c=11.50 slack=77.70 */
//     /* node24997 c=12.50 slack=76.70 */
//     /* node24998 c=12.50 slack=76.70 */
//     /* node25000 c=12.50 slack=76.70 */
//     /* node25001 c=12.50 slack=76.70 */
//     /* node25002 c=12.50 slack=76.70 */
//     /* node25003 c=12.50 slack=76.70 */
//     /* node25004 c=12.50 slack=76.70 */
//     /* node25005 c=12.50 slack=76.70 */
//     /* node25006 c=12.50 slack=76.70 */
//     /* node25012 c=13.50 slack=75.70 */
//   end
// end
// --- factor stage 3/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     lc_buf_v_q <= …; // sv-timing: cycle 3/12 on clk_i
//     lc_i_q <= …; // sv-timing: cycle 3/12 on clk_i
//     lc_issued_q <= …; // sv-timing: cycle 3/12 on clk_i
//     lc_j_q <= …; // sv-timing: cycle 3/12 on clk_i
//     lc_word_q <= …; // sv-timing: cycle 3/12 on clk_i
//     /* node24999 c=16.50 slack=72.70 */
//     /* node25007 c=16.50 slack=72.70 */
//     /* node25008 c=16.50 slack=72.70 */
//     /* node25009 c=16.50 slack=72.70 */
//     /* node25010 c=17.50 slack=71.70 */
//     /* node25011 c=17.50 slack=71.70 */
//   end
// end
// --- factor stage 4/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 4: no capture on this edge (slack) */
//   end
// end
// --- factor stage 5/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 5: no capture on this edge (slack) */
//   end
// end
// --- factor stage 6/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 6: no capture on this edge (slack) */
//   end
// end
// --- factor stage 7/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 7: no capture on this edge (slack) */
//   end
// end
// --- factor stage 8/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     lc_total_q <= …; // sv-timing: cycle 8/12 on clk_i
//     /* node24985 c=62.50 slack=26.70 */
//   end
// end
// --- factor stage 9/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 9: no capture on this edge (slack) */
//   end
// end
// --- factor stage 10/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 10: no capture on this edge (slack) */
//   end
// end
// --- factor stage 11/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 11: no capture on this edge (slack) */
//   end
// end
// --- factor stage 12/12  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     lc_beats_q <= …; // sv-timing: cycle 12/12 on clk_i
//     /* node24986 c=89.20 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // Local acceptance reserves metadata before a request crosses the cut.
  // The spill cells retain payload under stall and cut the reverse ready path;
  // simply delaying ready/valid would duplicate or lose AXI transactions.
  localparam int ArCutW = $bits(axi_req_d.ar);
  localparam int AwCutW = $bits(axi_req_d.aw);
  localparam int WCutW  = $bits(axi_req_d.w);
  localparam int RCutW  = $bits(axi_resp_i.r);
  localparam int BCutW  = $bits(axi_resp_i.b);
  logic [ArCutW-1:0] ar_cut_data;
  logic [AwCutW-1:0] aw_cut_data;
  logic [WCutW-1:0] w_cut_data;
  logic [RCutW-1:0] r_cut_data;
  logic [BCutW-1:0] b_cut_data;
  spill_register #(.T(logic [ArCutW-1:0]), .Bypass(!AxiCuts)) i_ar_cut (
    .clk_i, .rst_ni, .valid_i(axi_req_d.ar_valid), .ready_o(axi_resp_s.ar_ready),
    .data_i(axi_req_d.ar), .valid_o(axi_req_o.ar_valid),
    .ready_i(axi_resp_i.ar_ready), .data_o(ar_cut_data));
  spill_register #(.T(logic [AwCutW-1:0]), .Bypass(!AxiCuts)) i_aw_cut (
    .clk_i, .rst_ni, .valid_i(axi_req_d.aw_valid), .ready_o(axi_resp_s.aw_ready),
    .data_i(axi_req_d.aw), .valid_o(axi_req_o.aw_valid),
    .ready_i(axi_resp_i.aw_ready), .data_o(aw_cut_data));
  spill_register #(.T(logic [WCutW-1:0]), .Bypass(!AxiCuts)) i_w_cut (
    .clk_i, .rst_ni, .valid_i(axi_req_d.w_valid), .ready_o(axi_resp_s.w_ready),
    .data_i(axi_req_d.w), .valid_o(axi_req_o.w_valid),
    .ready_i(axi_resp_i.w_ready), .data_o(w_cut_data));
  spill_register #(.T(logic [RCutW-1:0]), .Bypass(!AxiCuts)) i_r_cut (
    .clk_i, .rst_ni, .valid_i(axi_resp_i.r_valid), .ready_o(axi_req_o.r_ready),
    .data_i(axi_resp_i.r), .valid_o(axi_resp_s.r_valid),
    .ready_i(axi_req_d.r_ready), .data_o(r_cut_data));
  spill_register #(.T(logic [BCutW-1:0]), .Bypass(!AxiCuts)) i_b_cut (
    .clk_i, .rst_ni, .valid_i(axi_resp_i.b_valid), .ready_o(axi_req_o.b_ready),
    .data_i(axi_resp_i.b), .valid_o(axi_resp_s.b_valid),
    .ready_i(axi_req_d.b_ready), .data_o(b_cut_data));
  assign axi_req_o.ar = ar_cut_data;
  assign axi_req_o.aw = aw_cut_data;
  assign axi_req_o.w = w_cut_data;
  assign axi_resp_s.r = r_cut_data;
  assign axi_resp_s.b = b_cut_data;

  localparam int unsigned LimM = (MaxM != 0) ? MaxM : MaxDim;
  localparam int unsigned LimN = (MaxN != 0) ? MaxN : MaxDim;
  localparam int unsigned LimK = (MaxK != 0) ? MaxK : MaxDim;
  localparam int unsigned LimHi = (LimM > LimN) ?
      ((LimM > LimK) ? LimM : LimK) : ((LimN > LimK) ? LimN : LimK);
  // C: j runs to LimN. A rows are LimM, B rows are LimN, K is LimK.
  localparam int unsigned KPerBank     = (LimN + PeLanes - 1) / PeLanes;
  localparam int unsigned BankWords    = LimM * KPerBank;
  localparam int unsigned BankAddrW    = (BankWords > 1) ? $clog2(BankWords) : 1;
  localparam int unsigned OperandKPerBank = (MaxElementBytes * LimK + PeLanes - 1) / PeLanes;
  localparam int unsigned OperandWordsA = LimM * OperandKPerBank;
  localparam int unsigned OperandWordsB = LimN * OperandKPerBank;
  localparam int unsigned OperandBankWords = (OperandWordsA > OperandWordsB) ?
      OperandWordsA : OperandWordsB;
  localparam int unsigned OperandBankAddrW = (OperandBankWords > 1) ? $clog2(OperandBankWords) : 1;
  localparam int unsigned LaneW        = (PeLanes > 1) ? $clog2(PeLanes) : 1;
  localparam int unsigned ColShift     = (OutCols > 1) ? $clog2(OutCols) : 0;
  localparam int unsigned ColW         = (OutCols > 1) ? $clog2(OutCols) : 1;
  // B bank words per column group (the flat pitch applies per group).
  localparam int unsigned OperandWordsBGrp = OperandWordsB >> ColShift;
  // Flat panel mapping (K-split-to-residency): operand rows are stored at a
  // per-job pitch of 2^pitch_sh_q bank words (pitch = next power of two of
  // ceil(k_bytes / PeLanes)), not at the fixed LimK pitch. The K box therefore
  // becomes a BYTE capacity -- n * pitch <= OperandWordsB and m * pitch <=
  // OperandWordsA -- so a 256 x 1024 INT8 panel occupies the same bank as a
  // 512 x 512 one and is one job (one resident key) instead of two chained K
  // blocks. The power-of-two pitch keeps the row address a shift (no runtime
  // multiplier); its cost is up to 2x row slack for k_bytes that are not a
  // power-of-two multiple of PeLanes. PeLanes must be a power of two.
  localparam int unsigned LaneShift    = (PeLanes > 1) ? $clog2(PeLanes) : 0;
  localparam int unsigned PitchShW     = $clog2(OperandBankAddrW + 1);
  // VA-turbo reuse keys must hold every accepted m and n; k is 16 bits (lda/ldb width).
  localparam int unsigned DimW = $clog2(LimHi + 1);
  // AXI beat geometry (I3: wider DataWidth raises BytesPerBeat without RTL rewrite)
  localparam int unsigned BytesPerBeat  = DataWidth / 8;
  localparam int unsigned ElemsPerBeat  = (BytesPerBeat > PeLanes) ? PeLanes : BytesPerBeat;
  localparam int unsigned ElemsPerBeatShift = (ElemsPerBeat > 1) ? $clog2(ElemsPerBeat) : 0;
  localparam int unsigned BeatAlignW    = (BytesPerBeat > 1) ? $clog2(BytesPerBeat) : 1;
  localparam int unsigned BeatLaneW     = (BytesPerBeat > 1) ? $clog2(BytesPerBeat) : 1;
  // Max beats per AR/AW (AXI4 max 256 → len=255; keep ≤255 for 8-bit counters)
  localparam int unsigned MaxBurstBeats = 255;
  // Inflight counter width; live MaxAROut=2 → AROutW=2 (bit-identical).
  localparam int unsigned AROutW = (MaxAROut <= 1) ? 1 : $clog2(MaxAROut + 1);
  // Dynamic AR cap from policy prefetch_depth (0 = fall back to MaxAROut)
  logic [AROutW-1:0] ar_max_eff;
  // The runtime input can only LOWER the depth, never raise it past the
  // parameterised MaxAROut the AR bookkeeping (ar_slot_q, ar_lane_mem_q) is
  // sized for; out-of-range and zero both fall back to the parameter.
  assign ar_max_eff = (ar_max_i != '0 && ar_max_i <= AROutW'(MaxAROut))
                      ? AROutW'(ar_max_i)
                      : AROutW'(MaxAROut);
  // N=1 keeps a single AXI ID (cookie / HARD identity). N>1 with a full-beat
  // drain uses one ID per outstanding AR so UNIQUE_IDS=1 can issue into two
  // channels at once. PeLanes < BytesPerBeat keeps the leftover-beat path
  // and therefore the in-order single-ID sequence.
  localparam bit          SplitArId = (NrChannels > 1) && (PeLanes >= BytesPerBeat);
  localparam int unsigned ARSlotW   = (MaxAROut <= 1) ? 1 : $clog2(MaxAROut);
  localparam logic [IdWidth-1:0] ArIdBase = IdWidth'(2);
  // pragma translate_off
  initial begin
    assert (MaxElementBytes inside {1, 2, 4})
      else $error("g6lc_ai_gemm_seq: MaxElementBytes must be 1, 2 or 4");
    assert (MaxAROut >= 1 && MaxAROut <= 8)
      else $error("g6lc_ai_gemm_seq: MaxAROut=%0d not in [1,8] (I3)", MaxAROut);
    assert (g6lc_ai_island_cfg_pkg::dram_channels_ok(NrChannels))
      else $error("g6lc_ai_gemm_seq: NrChannels=%0d not in {1,2,4,8}", NrChannels);
    assert (ChanShift >= 3 && ChanShift <= 16)
      else $error("g6lc_ai_gemm_seq: ChanShift=%0d out of range", ChanShift);
    // The held-beat absorber was removed with the B oct-drain. A beat wider
    // than PeLanes would drop the bytes this cycle does not take.
    assert (PeLanes >= (DataWidth / 8))
      else $error("g6lc_ai_gemm_seq: PeLanes=%0d < %0d bytes/beat",
                  PeLanes, DataWidth / 8);
    assert ((PeLanes & (PeLanes - 1)) == 0)
      else $error("g6lc_ai_gemm_seq: PeLanes=%0d must be a power of two (flat panel pitch is a shift)", PeLanes);
    assert (OutCols >= 1 && (OutCols & (OutCols - 1)) == 0 && OutCols <= PeLanes && OutCols <= LimN)
      else $error("g6lc_ai_gemm_seq: OutCols=%0d must be a power of two, <= PeLanes and <= LimN", OutCols);
  end
  // pragma translate_on

  typedef enum logic [3:0] {
    ST_IDLE  = 4'd0,
    ST_CHK   = 4'd1,
    ST_LA    = 4'd2,
    ST_LB    = 4'd3,
    ST_MAC   = 4'd4,
    ST_STC   = 4'd5,
    ST_DONE  = 4'd6,
    ST_LC    = 4'd7   // accumulate: load the existing C tile before the MAC
  } state_e;

  state_e state_q, state_d;
  logic [31:0] m_q, n_q, k_q;
  logic [15:0] lda_q, ldb_q;
  logic [2:0]  numfmt_q;
  logic [31:0] mac_step;
  logic [31:0] k_bytes;
  logic [AddrWidth-1:0] pa_q, pb_q, pc_q;

  // i,j element indices; t is reduction base (multiple of PeLanes during MAC
  // for INT8, multiple of 2*PeLanes for INT4)
  logic [31:0] i_q, j_q, t_q;
  logic [15:0] ldc_q;
  logic [31:0] ldc_eff;
  assign ldc_eff = (ldc_q == 16'd0) ? n_q : 32'(ldc_q);
  logic [31:0] acc_q [OutCols];
  logic [31:0] acc_d [OutCols];
  // F0b-2: one-cycle pipeline between the PE's pure reduction and the
  // accumulator. The pipeline carries not just the sum, but the i/j address
  // and first/last flags, because the C write and accumulator reset now happen
  // one cycle after the operands were issued.
  logic [31:0] sum_q [OutCols];
  logic [31:0] sum_d [OutCols];
  logic        sum_cv_q [OutCols];  // column g of the drained group is a real column
  logic        sum_cv_d [OutCols];
  logic        sum_v_q, sum_v_d;
  logic        sum_first_q, sum_first_d;
  logic        sum_last_q, sum_last_d;
  logic [31:0] sum_i_q, sum_i_d;
  logic [31:0] sum_j_q, sum_j_d;
  logic        err_q, err_d;
  logic        done_q;
  // Accumulate mode (latched from accumulate_i at start).
  logic        acc_mode_q;
  // ST_LC loader: one outstanding burst, one 32-bit C word written per cycle.
  localparam int unsigned WordsPerBeat = (DataWidth >= 32) ? DataWidth / 32 : 1;
  localparam int unsigned LcWordW      = (WordsPerBeat > 1) ? $clog2(WordsPerBeat) : 1;
  logic [31:0]            lc_total_q, lc_beats_q;   // words, beats
  logic [31:0]            lc_issued_q, lc_recv_q;   // beats issued / received
  logic [7:0]             lc_burst_left_q;
  logic                   lc_ar_busy_q;
  logic [DataWidth-1:0]   lc_buf_q;
  logic                   lc_buf_v_q;
  logic [LcWordW-1:0]     lc_word_q;
  logic [31:0]            lc_e_q, lc_i_q, lc_j_q;
  // next-state (driven in the main process)
  logic                   lc_ar_fire, lc_r_fire, lc_w_fire;
  logic [7:0]             lc_ar_beats;
  // Multi-outstanding AR count (0..MaxAROut); AW still single-outstanding
  logic [AROutW-1:0] ar_inflight_q, ar_inflight_d;
  logic        aw_sent_q, aw_sent_d;
  logic        w_sent_q, w_sent_d;
  // First R of head outstanding AR uses stored lane0; later Rs beat-aligned
  logic        burst_first_q, burst_first_d;
  // Issue cursor (AR address) vs receive cursor (i_q/j_q/t_q write position)
  logic [31:0] ar_i_q, ar_t_q, ar_j_q;  // A: (ar_i,ar_t); B: (ar_t,ar_j)
  logic        ar_i_en, ar_t_en, ar_j_en;
  logic [31:0] ar_i_d, ar_t_d, ar_j_d;
  // Per-outstanding first-byte lane (in-order R, same AR id)
  logic [BeatLaneW-1:0] ar_lane_mem_q [MaxAROut];
  logic [BeatLaneW-1:0] ar_lane_push;
  logic                 ar_lane_push_en;
  logic                 ar_lane_pop_en;
  logic [BeatLaneW-1:0] ar_head_lane;
  // N>1: per-outstanding write cursor so R may complete out of order.
  typedef struct packed {
    logic                 valid;
    logic                 first;
    logic [BeatLaneW-1:0] lane0;
    logic [31:0]          row;
    logic [31:0]          col;
  } ar_slot_t;
  ar_slot_t             ar_slot_q [MaxAROut];
  logic                 ar_slot_we;
  logic [ARSlotW-1:0]   ar_slot_widx;
  logic [31:0]          ar_slot_push_row, ar_slot_push_col;
  logic                 ar_slot_r_en;
  logic                 ar_slot_r_last;
  logic [ARSlotW-1:0]   ar_slot_ridx;
  logic [31:0]          ar_slot_ntake;
  logic                 ar_hold_q;
  logic [ARSlotW-1:0]   ar_hold_slot_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_hold_q <= 1'b0;
      ar_hold_slot_q <= '0;
    end else if (state_q == ST_IDLE && start_i) begin
      ar_hold_q <= 1'b0;
      ar_hold_slot_q <= '0;
    end else if (axi_req_d.ar_valid) begin
      if (axi_resp_s.ar_ready) ar_hold_q <= 1'b0;
      else if (!ar_hold_q) begin
        ar_hold_q <= 1'b1;
        ar_hold_slot_q <= SplitArId ? ARSlotW'(axi_req_d.ar.id - ArIdBase) : '0;
      end
    end
  end

  // Multi-byte unpack count for this R cycle. AI-X9 made the two loads the same
  // shape, so lb_n_d is now the same width as la_n_d (it was [3:0], capped at 8
  // by the deleted oct-drain) and both count elements along t.
  logic [7:0]  la_n_d;
  logic [7:0]  lb_n_d;

  // C dual-store: dual-bank combo read of C[j],C[j+1] → one W/cycle (PeLanes≥2).
  // Multi-beat: AW once with len=nbeats-1; stream W; advance j on B by stc_elem.
  // PeLanes==1 falls back to pair-hold (same bank for j and j+1).
  // Trail cursor (stc_i/stc_j) is independent of MAC (i_q/j_q): store only rows
  // whose C writes have committed; i_q==m means issue, not retirement, finished.
  localparam int unsigned RowCountW = (LimM < 2) ? 1 : $clog2(64'(LimM) + 64'd1);
  logic [RowCountW-1:0] c_rows_done_q;
  // Intra-row trailing (single-row / decode jobs): the C row being computed is
  // stored pair by pair behind the MAC. `c_cols_row_q` is the row of the last C
  // write and `c_cols_done_q` the number of its columns written so far (the MAC
  // writes columns in order), so a burst may cover pairs strictly below that
  // count. Only the even-n pair path trails inside a row; odd n keeps the
  // row-complete rule (AI-X8 kept its single/pair transition out of the MAC).
  logic [RowCountW-1:0] c_cols_row_q;
  logic [31:0]          c_cols_done_q;
  logic        c_pair_hold_q, c_pair_hold_d;
  logic [31:0] c_lo_q;
  logic        c_lo_we_d;
  logic [8:0]  stc_w_left_q, stc_w_left_d;  // remaining W beats (1..256)
  logic [15:0] stc_elem_q, stc_elem_d;      // elements covered by open AW
  logic [15:0] stc_n_d;                     // elements retired on B
  logic [31:0] stc_i_q, stc_j_q;            // store cursor (row/col)
  logic        stc_i_en, stc_j_en;          // advance store cursor this cycle
  logic [31:0] stc_i_d, stc_j_d;
  localparam bit DualCRead = (PeLanes >= 2);
  // Wide C store (V1/V2): on a bus wider than 64 bits a C beat can carry
  // DataWidth/32 consecutive columns (read from as many distinct banks) instead of
  // one 8-byte pair. Taken per job when the row pitch keeps every row base beat-
  // aligned (n % StoreWordsMax == 0 and ptr_c aligned); otherwise the pair path.
  // Words per beat are a shift (wsh: 1 = pair, StoreShMax = wide), so the 64-bit
  // path is arithmetically the pre-change one.
  localparam int unsigned StoreWordsMax = (DataWidth >= 64) ? DataWidth / 32 : 2;
  localparam int unsigned StoreShMax    = $clog2(StoreWordsMax);
  localparam int unsigned StoreShW      = (StoreShMax > 1) ? $clog2(StoreShMax + 1) : 1;
  localparam bit          WideCStore    = DualCRead && (StoreWordsMax > 2) && (PeLanes >= StoreWordsMax);
  logic [StoreShW-1:0] wsh_q;      // words-per-beat shift for this job's C store
  logic                wide_c_q;   // this job's rows are beat-aligned: use the wide store

  // ---- Banked A/B tile ports ----
  logic                 a_r_req  [PeLanes];
  logic [OperandBankAddrW-1:0] a_r_addr [PeLanes];
  logic [7:0]           a_r_data [PeLanes];
  logic                 a_w_req  [PeLanes];
  logic [OperandBankAddrW-1:0] a_w_addr [PeLanes];
  logic [7:0]           a_w_data [PeLanes];

  logic                 b_r_req  [OutCols][PeLanes];
  logic [OperandBankAddrW-1:0] b_r_addr [OutCols][PeLanes];
  logic [7:0]           b_r_data [OutCols][PeLanes];
  logic                 b_w_req  [OutCols][PeLanes];
  logic [OperandBankAddrW-1:0] b_w_addr [OutCols][PeLanes];
  logic [7:0]           b_w_data [OutCols][PeLanes];
  // AI-X9: the I3 same-bank multi-write ports (w2..w8) are gone. They existed
  // only because a row-major B burst ran along j and therefore landed a whole
  // beat in ONE bank. k-major B spreads a beat across PeLanes banks at one
  // address each, so 1W is enough -- same as A.

  // C multi-bank (bank = j % PeLanes). Dual concurrent reads for pair-store:
  // j and j+1 always hit different banks when PeLanes >= 2 (live: 128).
  logic                 c_r0_req, c_r1_req, c_w_req;
  // Extra C write ports for output columns 1..OutCols-1 (column 0 uses c_w_*).
  // Consecutive columns land in distinct banks (OutCols <= PeLanes), so every
  // bank sees at most one writer per cycle.
  logic                 c_wx_req  [OutCols];
  logic [LaneW-1:0]     c_wx_bank [OutCols];
  logic [BankAddrW-1:0] c_wx_addr [OutCols];
  logic [31:0]          c_wx_data [OutCols];
  logic [LaneW-1:0]     c_r0_bank, c_r1_bank, c_w_bank;
  logic [BankAddrW-1:0] c_r0_addr, c_r1_addr, c_w_addr;
  logic [31:0]          c_r0_data, c_r1_data, c_w_data;
  logic [31:0]          c_r_data_b [PeLanes];
  // Wide-store read ports for columns 2..StoreWordsMax-1 (0 and 1 are c_r0/c_r1).
  logic                 c_rx_req  [StoreWordsMax];
  logic [LaneW-1:0]     c_rx_bank [StoreWordsMax];
  logic [BankAddrW-1:0] c_rx_addr [StoreWordsMax];
  logic [31:0]          c_rx_data [StoreWordsMax];
  logic                 c_wp_req  [PeLanes];
  logic [BankAddrW-1:0] c_wp_addr [PeLanes];
  logic [31:0]          c_wp_data [PeLanes];
  always_comb begin
    for (int unsigned p = 0; p < PeLanes; p++) begin
      c_wp_req[p]  = c_w_req && (c_w_bank == LaneW'(p));
      c_wp_addr[p] = c_w_addr;
      c_wp_data[p] = c_w_data;
      for (int unsigned g = 1; g < OutCols; g++)
        if (c_wx_req[g] && c_wx_bank[g] == LaneW'(p)) begin
          c_wp_req[p]  = 1'b1;
          c_wp_addr[p] = c_wx_addr[g];
          c_wp_data[p] = c_wx_data[g];
        end
    end
  end
  // Alias for single-element paths (single store / MAC write uses r0)
  logic                 c_r_req;
  logic [LaneW-1:0]     c_r_bank;
  logic [BankAddrW-1:0] c_r_addr;
  logic [31:0]          c_r_data;
  assign c_r_req  = c_r0_req;
  assign c_r_bank = c_r0_bank;
  assign c_r_addr = c_r0_addr;
  assign c_r_data = c_r0_data;

  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_a_banks
    g6lc_ai_tile_sram #(
        .NumWords (OperandWordsA),
        .DataWidth(8),
        .NumPorts (2),
        .ImplKey  ("g6lc_ai_tile_a")
    ) i_tile_a (
        .clk_i, .rst_ni, .testmode_i,
        .r_req_i (a_r_req[p]), .r_addr_i(a_r_addr[p]), .r_data_o(a_r_data[p]),
        .w_req_i (a_w_req[p]), .w_addr_i(a_w_addr[p]), .w_data_i(a_w_data[p]),
        .w2_req_i(1'b0), .w2_addr_i('0), .w2_data_i('0),
        .w3_req_i(1'b0), .w3_addr_i('0), .w3_data_i('0),
        .w4_req_i(1'b0), .w4_addr_i('0), .w4_data_i('0),
        .w5_req_i(1'b0), .w5_addr_i('0), .w5_data_i('0),
        .w6_req_i(1'b0), .w6_addr_i('0), .w6_data_i('0),
        .w7_req_i(1'b0), .w7_addr_i('0), .w7_data_i('0),
        .w8_req_i(1'b0), .w8_addr_i('0), .w8_data_i('0)
    );
  end

  for (genvar g = 0; g < int'(OutCols); g++) begin : gen_b_grp
  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_b_banks
    g6lc_ai_tile_sram #(
        .NumWords (OperandWordsBGrp),
        .DataWidth(8),
        .NumPorts (2),  // AI-X9: 1R1W, same as A (was 8 for the oct drain)
        .ImplKey  ("g6lc_ai_tile_b")
    ) i_tile_b (
        .clk_i, .rst_ni, .testmode_i,
        .r_req_i (b_r_req[g][p]), .r_addr_i(b_r_addr[g][p]), .r_data_o(b_r_data[g][p]),
        .w_req_i (b_w_req[g][p]), .w_addr_i(b_w_addr[g][p]), .w_data_i(b_w_data[g][p]),
        .w2_req_i(1'b0), .w2_addr_i('0), .w2_data_i('0),
        .w3_req_i(1'b0), .w3_addr_i('0), .w3_data_i('0),
        .w4_req_i(1'b0), .w4_addr_i('0), .w4_data_i('0),
        .w5_req_i(1'b0), .w5_addr_i('0), .w5_data_i('0),
        .w6_req_i(1'b0), .w6_addr_i('0), .w6_data_i('0),
        .w7_req_i(1'b0), .w7_addr_i('0), .w7_data_i('0),
        .w8_req_i(1'b0), .w8_addr_i('0), .w8_data_i('0)
    );
  end
  end

  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_c_banks
    g6lc_ai_tile_sram #(
        .NumWords (BankWords),
        .DataWidth(32),
        .NumPorts (2),
        .ImplKey  ("g6lc_ai_tile_c")
    ) i_tile_c (
        .clk_i, .rst_ni, .testmode_i,
        // Multi-read: r0/r1 (pair j, j+1) and the wide-store ports select
        // different banks (consecutive columns, StoreWordsMax <= PeLanes).
        .r_req_i (c_rp_req[p]),
        .r_addr_i(c_rp_addr[p]),
        .r_data_o(c_r_data_b[p]),
        .w_req_i (c_wp_req[p]),
        .w_addr_i(c_wp_addr[p]),
        .w_data_i(c_wp_data[p]),
        .w2_req_i(1'b0), .w2_addr_i('0), .w2_data_i('0),
        .w3_req_i(1'b0), .w3_addr_i('0), .w3_data_i('0),
        .w4_req_i(1'b0), .w4_addr_i('0), .w4_data_i('0),
        .w5_req_i(1'b0), .w5_addr_i('0), .w5_data_i('0),
        .w6_req_i(1'b0), .w6_addr_i('0), .w6_data_i('0),
        .w7_req_i(1'b0), .w7_addr_i('0), .w7_data_i('0),
        .w8_req_i(1'b0), .w8_addr_i('0), .w8_data_i('0)
    );
  end

  // Per-bank read request: r0, r1 or one of the wide ports (at most one per bank).
  logic                 c_rp_req  [PeLanes];
  logic [BankAddrW-1:0] c_rp_addr [PeLanes];
  always_comb begin
    for (int unsigned p = 0; p < PeLanes; p++) begin
      c_rp_req[p]  = (c_r0_req && (c_r0_bank == LaneW'(p))) || (c_r1_req && (c_r1_bank == LaneW'(p)));
      c_rp_addr[p] = (c_r1_req && (c_r1_bank == LaneW'(p))) ? c_r1_addr : c_r0_addr;
      for (int unsigned w = 2; w < StoreWordsMax; w++)
        if (c_rx_req[w] && c_rx_bank[w] == LaneW'(p)) begin
          c_rp_req[p]  = 1'b1;
          c_rp_addr[p] = c_rx_addr[w];
        end
    end
  end

  // Latency=0 read muxes
  always_comb begin
    c_r0_data = c_r_data_b[0];
    c_r1_data = c_r_data_b[0];
    for (int unsigned p = 1; p < PeLanes; p++) begin
      if (c_r0_bank == LaneW'(p))
        c_r0_data = c_r_data_b[p];
      if (c_r1_bank == LaneW'(p))
        c_r1_data = c_r_data_b[p];
    end
    for (int unsigned w = 0; w < StoreWordsMax; w++) begin
      c_rx_data[w] = c_r_data_b[0];
      for (int unsigned p = 1; p < PeLanes; p++)
        if (c_rx_bank[w] == LaneW'(p)) c_rx_data[w] = c_r_data_b[p];
    end
    c_rx_data[0] = c_r0_data;
    if (StoreWordsMax > 1) c_rx_data[1] = c_r1_data;
  end


  // PE: multi-lane MAC (driven only in ST_MAC)
  logic signed [7:0] pe_a [PeLanes];
  logic signed [7:0] pe_b [OutCols][PeLanes];
  logic        [31:0] pe_a_float [PeLanes];
  logic        [31:0] pe_b_float [OutCols][PeLanes];
  logic              pe_v [PeLanes];
  logic       [31:0] pe_sum [OutCols];
  logic       [31:0] pe_sum_int [OutCols];
  logic       [31:0] pe_sum_float [OutCols];
  // Column g of the current group is a real output column (masked past n; a
  // single column in accumulate mode).
  logic              col_v [OutCols];
  logic [31:0]       cols_eff;
  assign cols_eff = acc_mode_q ? 32'd1 : 32'(OutCols);
  // B column group feeding dot g: col_grp(j_q + g). With the OutCols stride this
  // is g itself; accumulate mode advances one column at a time, so dot 0 must
  // follow the column's own group.
  logic [ColW-1:0]   grp_of [OutCols];
  always_comb for (int unsigned g = 0; g < OutCols; g++) grp_of[g] = col_grp(j_q + 32'(g));
  // Registers only (j_q, n_q, acc_mode_q): its own process so no read-data path
  // feeds back into the bank-request process through it.
  always_comb for (int unsigned g = 0; g < OutCols; g++)
    col_v[g] = (32'(g) < cols_eff) && (j_q + 32'(g) < n_q);

  for (genvar g = 0; g < int'(OutCols); g++) begin : gen_pe_cols
    // Integer/INT4 path
    if (!DotPipeInt) begin : gen_pe_int_comb
      g6lc_ai_pe_dot #(.Lanes(PeLanes)) i_pe_int (
          .a_i     (pe_a),
          .b_i     (pe_b[g]),
          .valid_i (pe_v),
          .numfmt_i(numfmt_q),
          .sum_o   (pe_sum_int[g])
      );
    end else begin : gen_pe_int_pipe_only
      assign pe_sum_int[g] = '0;
    end

    // Floating path (FP8/FP16/BF16/FP32) — combinational baseline
    g6lc_ai_pe_dot_float #(.Lanes(PeLanes)) i_pe_float (
        .a_i     (pe_a_float),
        .b_i     (pe_b_float[g]),
        .valid_i (pe_v),
        .numfmt_i(numfmt_q),
        .sum_o   (pe_sum_float[g]),
        .flags_o ()
    );
  end

  // Pipelined dot-product handshake (float and/or int pipes).
  // dot_start is asserted with each MAC issue; dot_sum/dot_first/... are valid
  // DOT_LATENCY-1 cycles later, matching dot_valid_o.  DOT_LATENCY is the
  // dot product's registered Latency plus the one-cycle output register.
  // Both pipes have the same Latency, so one metadata pipe serves either.
  localparam bit DotPipeAny = DotPipeFloat || DotPipeInt;
  localparam int unsigned DOT_LATENCY = DotPipeAny ?
      ($clog2(PeLanes < 1 ? 1 : PeLanes) + 5) : 1;

  logic dot_start;
  logic dot_valid;
  logic [31:0] dot_sum [OutCols];
  logic        dot_valid_f, dot_valid_i;
  logic [31:0] dot_sum_f [OutCols];
  logic [31:0] dot_sum_i [OutCols];
  logic        dot_cv_out [OutCols];
  logic dot_first_out, dot_last_out;
  logic [31:0] dot_i_out, dot_j_out;
  logic dot_first_issue, dot_last_issue;
  logic [31:0] dot_i_issue, dot_j_issue;
  logic pe_float_en;
  logic dot_pipe_en;
  // F0b-2: outstanding dot-product transactions so the MAC does not exit before
  // all pipelined results have returned and their C writes have been issued.
  logic [$clog2(PeLanes)+4:0] dot_pending_q;

  generate
    if (DotPipeFloat) begin : gen_dot_pipe_float
      logic dot_valid_col [OutCols];
      for (genvar g = 0; g < int'(OutCols); g++) begin : gen_dot_pipe_fcols
        g6lc_ai_pe_dot_float_pipe #(.Lanes(PeLanes)) i_pe_float_pipe (
            .clk_i    (clk_i),
            .rst_ni   (rst_ni),
            .start_i  (dot_start && pe_float_en),
            .a_i      (pe_a_float),
            .b_i      (pe_b_float[g]),
            .valid_i  (pe_v),
            .numfmt_i (numfmt_q),
            .sum_o    (dot_sum_f[g]),
            .flags_o  (),
            .valid_o  (dot_valid_col[g])
        );
      end
      // All column pipes share start and latency; column 0 is the handshake.
      assign dot_valid_f = dot_valid_col[0];
    end else begin : gen_dot_float_off
      assign dot_valid_f = 1'b0;
      always_comb for (int unsigned g = 0; g < OutCols; g++) dot_sum_f[g] = '0;
    end

    if (DotPipeInt) begin : gen_dot_pipe_int
      logic dot_valid_col_i [OutCols];
      for (genvar g = 0; g < int'(OutCols); g++) begin : gen_dot_pipe_icols
        g6lc_ai_pe_dot_pipe #(.Lanes(PeLanes)) i_pe_int_pipe (
            .clk_i    (clk_i),
            .rst_ni   (rst_ni),
            .start_i  (dot_start && !pe_float_en),
            .a_i      (pe_a),
            .b_i      (pe_b[g]),
            .valid_i  (pe_v),
            .numfmt_i (numfmt_q),
            .sum_o    (dot_sum_i[g]),
            .valid_o  (dot_valid_col_i[g])
        );
      end
      assign dot_valid_i = dot_valid_col_i[0];
    end else begin : gen_dot_int_off
      assign dot_valid_i = 1'b0;
      always_comb for (int unsigned g = 0; g < OutCols; g++) dot_sum_i[g] = '0;
    end

    if (DotPipeAny) begin : gen_dot_pipe
      // Static per job (numfmt_q is latched at start): the format select.
      assign dot_valid = pe_float_en ? dot_valid_f : dot_valid_i;
      always_comb for (int unsigned g = 0; g < OutCols; g++)
        dot_sum[g] = pe_float_en ? dot_sum_f[g] : dot_sum_i[g];

      logic [DOT_LATENCY-1:0] dot_first_pipe, dot_last_pipe;
      logic [DOT_LATENCY-1:0][31:0] dot_i_pipe, dot_j_pipe;
      logic [DOT_LATENCY-1:0][OutCols-1:0] dot_cv_pipe;
      logic [OutCols-1:0] col_v_vec;
      always_comb for (int unsigned g = 0; g < OutCols; g++) col_v_vec[g] = col_v[g];

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          dot_first_pipe <= '0;
          dot_last_pipe  <= '0;
          dot_i_pipe     <= '0;
          dot_j_pipe     <= '0;
          dot_cv_pipe    <= '0;
        end else begin
          dot_first_pipe <= {dot_first_pipe[DOT_LATENCY-2:0],
                             dot_start ? dot_first_issue : 1'b0};
          dot_last_pipe  <= {dot_last_pipe[DOT_LATENCY-2:0],
                             dot_start ? dot_last_issue : 1'b0};
          dot_i_pipe     <= {dot_i_pipe[DOT_LATENCY-2:0],
                             dot_start ? dot_i_issue : 32'd0};
          dot_j_pipe     <= {dot_j_pipe[DOT_LATENCY-2:0],
                             dot_start ? dot_j_issue : 32'd0};
          dot_cv_pipe    <= {dot_cv_pipe[DOT_LATENCY-2:0],
                             dot_start ? col_v_vec : {OutCols{1'b0}}};
        end
      end

      assign dot_first_out = dot_first_pipe[DOT_LATENCY-1];
      assign dot_last_out  = dot_last_pipe[DOT_LATENCY-1];
      assign dot_i_out     = dot_i_pipe[DOT_LATENCY-1];
      assign dot_j_out     = dot_j_pipe[DOT_LATENCY-1];
      always_comb for (int unsigned g = 0; g < OutCols; g++) dot_cv_out[g] = dot_cv_pipe[DOT_LATENCY-1][g];
    end else begin : gen_dot_float_comb
      assign dot_valid     = 1'b0;
      always_comb for (int unsigned g = 0; g < OutCols; g++) begin dot_sum[g] = '0; dot_cv_out[g] = 1'b0; end
      assign dot_first_out = 1'b0;
      assign dot_last_out  = 1'b0;
      assign dot_i_out     = '0;
      assign dot_j_out     = '0;
    end
  endgenerate

  // Format selection: integer/INT4 vs floating.
  // numfmt_q is constant for a tile, so the mux is a per-job static select.
  localparam logic [2:0] AI_FMT_INT  = 3'd0;
  localparam logic [2:0] AI_FMT_INT4 = 3'd1;
  // Only dispatch to the float dot for implemented FP families
  // (FP8 E4M3/E5M2, FP16, BF16, FP32).  SP24 and reserved codes stay on the
  // integer path where the sequencer's numfmt check / descriptor grant will
  // reject them before the MAC.
  // Static per job (numfmt_q is latched at start), so this is a configuration
  // select rather than a per-cycle mux in the MAC's critical path.
  assign pe_float_en = (numfmt_q inside {3'd3, 3'd4, 3'd5, 3'd6, 3'd7});
  // Pipelined datapath live for this job's format.
  assign dot_pipe_en = (DotPipeFloat && pe_float_en) ||
                       (DotPipeInt && !pe_float_en);
  always_comb for (int unsigned g = 0; g < OutCols; g++)
    pe_sum[g] = pe_float_en ? pe_sum_float[g] : pe_sum_int[g];

  // ---------------------------------------------------------------------------
  // F1-F5 format scaling: bytes per element for the live numerical formats.
  // INT4 packs two elements per byte; all other live formats use the natural
  // byte width. This is a local copy so g6lc_ai_gemm_seq stays unit-testable
  // without pulling config_pkg into every backend runner.
  function automatic logic [31:0] ai_fmt_bytes();
    return g6lc_ai_island_cfg_pkg::ai_elem_bytes(numfmt_q);
  endfunction
  // Element size as a shift (0/1/2): byte<->element scaling in the datapath is a
  // shift, never a multiply or divide by the runtime element size.
  function automatic logic [1:0] ai_fmt_shift();
    return g6lc_ai_island_cfg_pkg::ai_elem_shift(numfmt_q);
  endfunction

  // F1: number of elements issued per MAC cycle (PeLanes byte lanes / element bytes).
  assign mac_step = (numfmt_q == 3'd1) ? 32'(2 * PeLanes)
                                       : (32'(PeLanes) >> ai_fmt_shift());

  // F1: bytes in one operand row (k elements). This is the bound the LOAD states
  // run to; ST_MAC still bounds against k_q in elements. For INT8 the two are
  // equal, which is why the INT8 path is bit-identical.
  assign k_bytes = fmt_row_bytes(k_q);

  // Row pitch of the operand banks for this job (see the flat-panel note above).
  // The arithmetic is g6lc_ai_island_cfg_pkg's flat-panel functions, proven bounded
  // in corev_apu/ai_island/formal/g6lc_ai_gemm_flat_props.sv.
  logic [PitchShW-1:0] pitch_sh_c, pitch_sh_q;
  logic                cap_ok_c;
  assign pitch_sh_c  = PitchShW'(g6lc_ai_island_cfg_pkg::ai_flat_pitch_shift(k_bytes, LaneShift));
  // pragma translate_off
  // D1 equivalence: the clz-tree pitch must equal the serial-loop reference.
  int unsigned g6lc_ai_pitch_eq;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) g6lc_ai_pitch_eq <= 0;
    else begin
      g6lc_ai_pitch_eq <= g6lc_ai_pitch_eq + 1;
      assert (pitch_sh_c == PitchShW'(g6lc_ai_island_cfg_pkg::ai_flat_pitch_shift_ref(k_bytes, LaneShift)))
        else $error("g6lc_ai_gemm_seq: pitch_eq mismatch %0d != %0d",
                    pitch_sh_c, g6lc_ai_island_cfg_pkg::ai_flat_pitch_shift_ref(k_bytes, LaneShift));
    end
  end
  final $display("[equiv] g6lc_ai_gemm_seq pitch_eq: checked=%0d", g6lc_ai_pitch_eq);
  // pragma translate_on


  // Byte-capacity box: both operand panels must fit their banks at this pitch,
  // and k must fit the 16-bit lda/ldb it is compared against.
  // B rows are spread over OutCols groups of OperandWordsBGrp words each.
  logic [31:0] n_grp_c;
  assign n_grp_c = (n_q + 32'(OutCols) - 32'd1) >> ColShift;
  assign cap_ok_c = k_q <= 32'h0000_FFFF &&
                    g6lc_ai_island_cfg_pkg::ai_flat_fits(n_grp_c, pitch_sh_c, OperandWordsBGrp) &&
                    g6lc_ai_island_cfg_pkg::ai_flat_fits(m_q, pitch_sh_c, OperandWordsA);

  // F0b-2: the accumulator is now fed from the PIPELINE register, so
  // `mac_acc_next` is a function of state (sum_q, acc_q) rather than of the
  // live combinational tree output. The cycle-accurate expression:
  //   sum_q   is pe_sum from one cycle ago
  //   first_q is (t_q == 0) from one cycle ago, i.e. a new element
  //   acc_q   is the running sum after the previous drain
  //   acc_d   = (first_q ? '0 : acc_q) + sum_q
  //
  // This is the structural pipeline. Timing closure (depth, retiming,
  // placement) is sv-timing's job later; this is just the state-machine split.
  //
  // Bit-identical to the previous pe_acc_out only if the pipeline is empty at
  // the start and the FSM drains before changing state.
  // purpose is structural: `acc_q <= acc_q + tree` is a recurrence, so a
  // pipeline register cannot be placed on `acc_o` without feeding a stale
  // `acc_i` back into the next step and silently dropping terms. Splitting the
  // reduction (a pure function) from the accumulator (state) puts the register
  // site inside this module, where the sequencer can also delay the matching
  // C-write address and the element's first/last flags.
  //
  // F0b-2 replaces this with:
  //   sum_q <= pe_sum;  acc_d = (first_q ? '0 : acc_q) + sum_q;
  // plus delayed i/j for the C write and a one-cycle drain before leaving
  // ST_MAC. Landing that needs its own verification pass: the C-write port is
  // shared with the trail-store path in ST_MAC, so moving the MAC write one
  // cycle later changes that arbitration.
  logic [31:0] mac_acc_next [OutCols];
  logic [36:0] mac_fp32_add [OutCols];
  // Float tiles accumulate with RNE FP32 addition; integer tiles with i32 add.
  // Timing note: fp32_add is a combinational decode/align/add/normalise block.
  // Together with the multi-byte gather mux it lengthens the MAC combinational
  // path vs the integer path. A future pass should either retime it around the
  // existing one-cycle pe_sum -> acc_q pipeline or pipeline fp32_add itself;
  // this is not a throughput change and does not affect the load/store FSM.
  // Accumulate mode: the first partial of an element is added onto the C word
  // that ST_LC placed in the tile (read on port r0 in the drain cycle) instead of
  // starting from zero, so a K-split chained through C is one ordered reduction.
  logic [31:0] mac_seed;
  logic [31:0] mac_seed_q;
  logic seed_capture;
  logic [31:0] seed_i, seed_j;
  logic [36:0] mac_fp32_seed_add;
  // The seed (accumulate mode) belongs to column 0: accumulate jobs run one
  // column at a time, so no other column ever needs it.
  // Read C alongside the incoming partial, one edge before accumulation.
  // The seed and sum/first/i/j enter their registers on the SAME edge. This
  // cuts bank-address/decode/read from FP addition without moving its recurrence
  // or changing dot-product latency. In pipelined mode use the returning tag,
  // never the live issue cursor (which can be several output elements ahead).
  assign seed_capture = state_q == ST_MAC && acc_mode_q &&
      (dot_pipe_en ? (dot_valid && dot_first_out) : (sum_v_d && sum_first_d));
  assign seed_i = dot_pipe_en ? dot_i_out : sum_i_d;
  assign seed_j = dot_pipe_en ? dot_j_out : sum_j_d;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mac_seed_q <= '0;
    else if (seed_capture) mac_seed_q <= c_r0_data;
  end
  assign mac_seed          = acc_mode_q ? mac_seed_q : 32'd0;
  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == ST_MAC && acc_mode_q && sum_v_q && sum_first_q |->
      $past(seed_capture) && sum_i_q == $past(seed_i) && sum_j_q == $past(seed_j));
  // pragma translate_on
  assign mac_fp32_seed_add = g6lc_ai_fp_pkg::fp32_add(mac_seed, sum_q[0]);
  for (genvar g = 0; g < OutCols; g++) begin : gen_accumulate_column
    logic [31:0] int_base, int_next, float_next;
    assign mac_fp32_add[g] = g6lc_ai_fp_pkg::fp32_add(acc_q[g], sum_q[g]);
    assign int_base = sum_first_q ? ((g == 0) ? mac_seed : 32'd0) : acc_q[g];
    assign int_next = int_base + sum_q[g];
    assign float_next = sum_first_q ?
        ((acc_mode_q && g == 0) ? mac_fp32_seed_add[31:0] : sum_q[g]) :
        mac_fp32_add[g][31:0];
    assign mac_acc_next[g] = pe_float_en ? float_next : int_next;
  end

  logic reuse_b_skip_q, reuse_b_safe;
  // Row base of the B panel in the operand bank: 0, or the slot's half when the
  // resident-B directory placed this job's panel in a slot (see gen_reuse_b).
  logic [OperandBankAddrW-1:0] b_base_q;
  if (ReuseBEn) begin : gen_reuse_b
    localparam int unsigned SlotsB     = (ReuseBSlots < 1) ? 1 : ReuseBSlots;
    // Slot words are group-local (each column group holds 1/OutCols of a panel).
    localparam int unsigned SlotWordsB = OperandWordsBGrp / SlotsB;
    localparam int unsigned SlotW      = (SlotsB > 1) ? $clog2(SlotsB) : 1;
    logic [SlotsB-1:0] valid_q, big_q, hit_vec;
    logic cacheable_q, invalidated_q, hit_any;
    logic [AddrWidth-1:0] ptr_q [SlotsB];
    logic [DimW-1:0] n_saved_q [SlotsB];
    logic [15:0]     k_saved_q [SlotsB];
    logic [15:0]     ldb_saved_q [SlotsB];
    logic [2:0]      fmt_q [SlotsB];
    logic [31:0]     epoch_q [SlotsB];
    logic [SlotW-1:0] cur_q, victim_q, hit_idx;
    logic [31:0] job_epoch_q;
    logic [31:0] b_span, c_span;
    logic [AddrWidth:0] b_end, c_end;
    logic geometry_ok, disjoint, response_error, small_c;

    // The incoming job's key against every slot; the first hit wins (keys are
    // unique per slot because a slot is invalidated before it is refilled).
    always_comb begin
      hit_idx = '0;
      for (int unsigned s = 0; s < SlotsB; s++)
        hit_vec[s] = valid_q[s] && ptr_q[s] == ptr_b_i &&
                     32'(n_saved_q[s]) == n_i && 32'(k_saved_q[s]) == k_i &&
                     ldb_saved_q[s] == ldb_i && fmt_q[s] == numfmt_i &&
                     epoch_q[s] == reuse_b_epoch_i;
      for (int s = SlotsB - 1; s >= 0; s--)
        if (hit_vec[s]) hit_idx = SlotW'(s);
    end
    assign hit_any = |hit_vec;
    // Fits one slot at this job's pitch; otherwise the panel takes the whole bank.
    assign small_c = SlotsB > 1 && g6lc_ai_island_cfg_pkg::ai_slot_small(n_grp_c, pitch_sh_c, SlotWordsB);

    assign b_span = 32'(n_q - 32'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes;
    assign c_span = ((32'(m_q) - 32'd1) * ldc_eff + 32'(n_q)) << 2;
    assign b_end = {1'b0, pb_q} + (AddrWidth+1)'(b_span);
    assign c_end = {1'b0, pc_q} + (AddrWidth+1)'(c_span);
    assign geometry_ok = m_q > 0 && m_q <= LimM && n_q > 0 && n_q <= LimN &&
                         k_q > 0 && cap_ok_c && ldb_q >= k_q[15:0] &&
                         numfmt_q inside {3'd0, 3'd1, 3'd3, 3'd4, 3'd5, 3'd6, 3'd7};
    assign disjoint = !b_end[AddrWidth] && !c_end[AddrWidth] &&
                      ({1'b0, pc_q} >= b_end || {1'b0, pb_q} >= c_end);
    // Combinational, not `cacheable_q`: the skip is now decided in ST_CHK too
    // (when A is also resident) and `cacheable_q` is still clear at that point.
    // The job's shape and pointers are latched at start and do not move, so this
    // is the same value `cacheable_q` carries from ST_CHK onward.
    assign reuse_b_safe = geometry_ok && disjoint && !invalidated_q;
    assign response_error = (axi_resp_s.r_valid && axi_req_d.r_ready && axi_resp_s.r.resp[1]) ||
                            (axi_resp_s.b_valid && axi_req_d.b_ready && axi_resp_s.b.resp[1]);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid_q <= '0;
        big_q <= '0;
        cacheable_q <= 1'b0;
        invalidated_q <= 1'b0;
        for (int unsigned s = 0; s < SlotsB; s++) begin
          ptr_q[s] <= '0;
          n_saved_q[s] <= '0;
          k_saved_q[s] <= '0;
          ldb_saved_q[s] <= '0;
          fmt_q[s] <= '0;
          epoch_q[s] <= '0;
        end
        cur_q <= '0;
        victim_q <= '0;
        b_base_q <= '0;
        job_epoch_q <= '0;
        reuse_b_skip_q <= 1'b0;
        pmu_reuse_b_hit_o <= 1'b0;
      end else begin
        if (state_q == ST_IDLE && start_i) begin
          job_epoch_q <= reuse_b_epoch_i;
          reuse_b_skip_q <= reuse_b_i && hit_any;
          // The job owns the slot it hit, else the round-robin victim; that slot's
          // key is dropped now (its rows are rewritten unless the skip is taken)
          // and re-established at ST_DONE with this job's key.
          cur_q <= hit_any ? hit_idx : victim_q;
          valid_q[hit_any ? hit_idx : victim_q] <= 1'b0;
          cacheable_q <= 1'b0;
          invalidated_q <= 1'b0;
          pmu_reuse_b_hit_o <= 1'b0;
        end
        if (state_q == ST_CHK) begin
          cacheable_q <= geometry_ok && disjoint;
          // Placement: a panel that fits a slot lives at the slot's half; a bigger
          // one takes the whole bank and evicts every other slot. A small panel
          // landing next to a "big" resident also evicts it (they overlap).
          if (small_c) begin
            b_base_q <= OperandBankAddrW'(g6lc_ai_island_cfg_pkg::ai_slot_base(cur_q, SlotWordsB));
            big_q[cur_q] <= 1'b0;
            for (int unsigned s = 0; s < SlotsB; s++)
              if (SlotW'(s) != cur_q && big_q[s]) valid_q[s] <= 1'b0;
          end else begin
            b_base_q <= '0;
            big_q[cur_q] <= 1'b1;
            for (int unsigned s = 0; s < SlotsB; s++)
              if (SlotW'(s) != cur_q) valid_q[s] <= 1'b0;
          end
        end
        // ST_LA -> ST_MAC is a B skip with A loaded; ST_CHK -> ST_MAC is a B
        // skip with A resident too.  Both must report, or the counter would
        // under-report exactly when the engine saved the most traffic.
        if ((state_q == ST_LA || state_q == ST_CHK) && state_d == ST_MAC)
          pmu_reuse_b_hit_o <= 1'b1;
        if (state_q == ST_DONE) begin
          valid_q[cur_q] <= cacheable_q && !invalidated_q && !err_q;
          ptr_q[cur_q] <= pb_q;
          n_saved_q[cur_q] <= n_q[DimW-1:0];
          k_saved_q[cur_q] <= k_q[15:0];
          ldb_saved_q[cur_q] <= ldb_q;
          fmt_q[cur_q] <= numfmt_q;
          epoch_q[cur_q] <= job_epoch_q;
          // Round robin after use: with two slots this is exactly LRU.
          victim_q <= (32'(cur_q) + 1 >= SlotsB) ? '0 : cur_q + SlotW'(1);
        end
        if (reuse_b_invalidate_i || response_error) begin
          valid_q <= '0;
          reuse_b_skip_q <= 1'b0;
          invalidated_q <= 1'b1;
        end
      end
    end
  end else begin : gen_no_reuse_b
    assign reuse_b_skip_q = 1'b0;
    assign reuse_b_safe = 1'b0;
    assign pmu_reuse_b_hit_o = 1'b0;
    assign b_base_q = '0;
  end

  // Resident A, the mirror of the B path above and the same recipe 16.  B
  // residency serves one weight tile against many activations; A residency
  // serves one activation tile against many weight tiles, which is the other
  // half of the workload and costs the same key registers.  N is deliberately
  // absent from the A key exactly as M is absent from the B key: neither
  // dimension addresses the tile it is excluded from.
  logic reuse_a_skip_q, reuse_a_safe;
  if (ReuseAEn) begin : gen_reuse_a
    logic valid_q, cacheable_q, invalidated_q;
    logic [AddrWidth-1:0] ptr_q;
    logic [DimW-1:0] m_saved_q;
    logic [15:0]     k_saved_q;
    logic [15:0] lda_saved_q;
    logic [2:0] fmt_q;
    logic [31:0] epoch_q, job_epoch_q;
    logic [31:0] a_span, c_span;
    logic [AddrWidth:0] a_end, c_end;
    logic geometry_ok, disjoint, response_error;

    assign a_span = 32'(m_q - 32'd1) * fmt_row_bytes({16'd0, lda_q}) + k_bytes;
    assign c_span = ((32'(m_q) - 32'd1) * ldc_eff + 32'(n_q)) << 2;
    assign a_end = {1'b0, pa_q} + (AddrWidth+1)'(a_span);
    assign c_end = {1'b0, pc_q} + (AddrWidth+1)'(c_span);
    assign geometry_ok = m_q > 0 && m_q <= LimM && n_q > 0 && n_q <= LimN &&
                         k_q > 0 && cap_ok_c && lda_q >= k_q[15:0] &&
                         numfmt_q inside {3'd0, 3'd1, 3'd3, 3'd4, 3'd5, 3'd6, 3'd7};
    assign disjoint = !a_end[AddrWidth] && !c_end[AddrWidth] &&
                      ({1'b0, pc_q} >= a_end || {1'b0, pa_q} >= c_end);
    // Combinational for the same reason as the B side, and here it is load
    // bearing: A's skip is decided in ST_CHK, where `cacheable_q` has just been
    // cleared by the start handshake, so keying off it would make the skip dead
    // code while the PMU still claimed a hit.
    assign reuse_a_safe = geometry_ok && disjoint && !invalidated_q;
    assign response_error = (axi_resp_s.r_valid && axi_req_d.r_ready && axi_resp_s.r.resp[1]) ||
                            (axi_resp_s.b_valid && axi_req_d.b_ready && axi_resp_s.b.resp[1]);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid_q <= 1'b0;
        cacheable_q <= 1'b0;
        invalidated_q <= 1'b0;
        ptr_q <= '0;
        m_saved_q <= '0;
        k_saved_q <= '0;
        lda_saved_q <= '0;
        fmt_q <= '0;
        epoch_q <= '0;
        job_epoch_q <= '0;
        reuse_a_skip_q <= 1'b0;
        pmu_reuse_a_hit_o <= 1'b0;
      end else begin
        if (state_q == ST_IDLE && start_i) begin
          job_epoch_q <= reuse_a_epoch_i;
          reuse_a_skip_q <= reuse_a_i && valid_q && ptr_q == ptr_a_i &&
                            32'(m_saved_q) == m_i && 32'(k_saved_q) == k_i &&
                            lda_saved_q == lda_i && fmt_q == numfmt_i && epoch_q == reuse_a_epoch_i;
          valid_q <= 1'b0;
          cacheable_q <= 1'b0;
          invalidated_q <= 1'b0;
          pmu_reuse_a_hit_o <= 1'b0;
        end
        if (state_q == ST_CHK) begin
          cacheable_q <= geometry_ok && disjoint;
          // Exactly the FSM's skip condition, so the flag cannot disagree.
          if (reuse_a_skip_q && reuse_a_safe && !reuse_a_invalidate_i)
            pmu_reuse_a_hit_o <= 1'b1;
        end
        if (state_q == ST_DONE) begin
          valid_q <= cacheable_q && !invalidated_q && !err_q;
          ptr_q <= pa_q;
          m_saved_q <= m_q[DimW-1:0];
          k_saved_q <= k_q[15:0];
          lda_saved_q <= lda_q;
          fmt_q <= numfmt_q;
          epoch_q <= job_epoch_q;
        end
        if (reuse_a_invalidate_i || response_error) begin
          valid_q <= 1'b0;
          reuse_a_skip_q <= 1'b0;
          invalidated_q <= 1'b1;
          pmu_reuse_a_hit_o <= 1'b0;
        end
      end
    end
  end else begin : gen_no_reuse_a
    assign reuse_a_skip_q = 1'b0;
    assign reuse_a_safe = 1'b0;
    assign pmu_reuse_a_hit_o = 1'b0;
  end

  // I3 PMU accumulators (active while not IDLE/DONE)
  logic [31:0] pmu_r_q, pmu_w_q, pmu_cy_q;

  assign ready_o       = (state_q == ST_IDLE);
  assign done_o        = done_q;
  assign err_o         = err_q;
  assign pmu_r_beats_o = pmu_r_q;
  assign pmu_w_beats_o = pmu_w_q;
  assign pmu_cycles_o  = pmu_cy_q;

  logic [3:0][31:0] pmu_phase_q;
  logic [2:0][31:0] pmu_stall_q;
  assign pmu_phase_o = pmu_phase_q;
  assign pmu_stall_o = pmu_stall_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pmu_phase_q <= '0;
      pmu_stall_q <= '0;
    end else if (state_q == ST_IDLE && start_i) begin
      pmu_phase_q <= '0;
      pmu_stall_q <= '0;
    end else begin
      // ST_LC (accumulate seed load) is a load phase too; it is billed to the A bucket
      // so the four published words stay {STC, MAC, LB, LA} without a fifth register.
      if (state_q == ST_LA || state_q == ST_LC) pmu_phase_q[0] <= pmu_phase_q[0] + 32'd1;
      if (state_q == ST_LB)  pmu_phase_q[1] <= pmu_phase_q[1] + 32'd1;
      if (state_q == ST_MAC) pmu_phase_q[2] <= pmu_phase_q[2] + 32'd1;
      if (state_q == ST_STC) pmu_phase_q[3] <= pmu_phase_q[3] + 32'd1;
      if (axi_req_d.ar_valid && !axi_resp_s.ar_ready) pmu_stall_q[0] <= pmu_stall_q[0] + 32'd1;
      if (axi_resp_s.r_valid && !axi_req_d.r_ready)   pmu_stall_q[1] <= pmu_stall_q[1] + 32'd1;
      if (axi_req_d.w_valid && !axi_resp_s.w_ready)   pmu_stall_q[2] <= pmu_stall_q[2] + 32'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // F1 format scaling. TWO cursor conventions, deliberately:
  //
  //   * the LOAD states (ST_LA/ST_LB) count t in **BYTES** along the row;
  //   * ST_MAC counts t in **ELEMENTS**, because only elements bound against k
  //     and only elements decide nibble validity on an odd-k tail.
  //
  // `t_q` is reset at every state transition, so the two meanings never overlap
  // -- the same reuse `i_q`/`j_q` already rely on. Making the load count bytes
  // is what makes the ENTIRE load path format-agnostic: the tile stores bytes
  // keyed by byte position (bank = byte % PeLanes, addr = row*KPerBank +
  // byte/PeLanes), which is exactly what the MAC reads back. So a format only
  // has to say how many bytes a row of k elements occupies, and neither loader
  // needs a per-format branch. FP8 reuses this unchanged; BF16/FP16/FP32 will
  // need only their MAC-side gather, not a new loader.
  function automatic logic [31:0] fmt_row_bytes(
      input logic [31:0] elems
  );
    // INT4 packs two elements per byte; ceil so an odd count keeps its last
    // element. FP8/INT8 are one byte. FP16/BF16 are two bytes. FP32 is four.
    return g6lc_ai_island_cfg_pkg::ai_row_bytes(numfmt_q, elems);
  endfunction

  function automatic logic [31:0] fmt_ld_to_stride(
      input logic [15:0] ld
  );
    return fmt_row_bytes(32'(ld));
  endfunction

  // `t` is a BYTE offset within the row (load-state convention above), so no
  // conversion happens here -- the caller already scaled it.
  function automatic logic [AddrWidth-1:0] a_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] i, t,
      input logic [15:0] lda
  );
    return base + AddrWidth'((i * fmt_ld_to_stride(lda) + t));
  endfunction

  // AI-X9: B is k-major. `ldb` strides j; elements run contiguously along t,
  // exactly like A. So this is a_addr with the row index swapped, which is what
  // lets one traversal and one format-scaling rule serve both operands, and what
  // makes sub-byte packing expressible (two INT4 elements in a byte are
  // consecutive t and therefore feed the same C[i,j]).
  function automatic logic [AddrWidth-1:0] b_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] t, j,
      input logic [15:0] ldb
  );
    return base + AddrWidth'((j * fmt_ld_to_stride(ldb) + t));
  endfunction

  function automatic logic [AddrWidth-1:0] c_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] i, j, n
  );
    return base + AddrWidth'(((i * n + j) << 2));
  endfunction

  function automatic logic signed [7:0] byte_from_beat(
      input logic [DataWidth-1:0] data,
      input logic [BeatLaneW-1:0] lane
  );
    return data[8*lane +: 8];
  endfunction

  // Align AR address to beat boundary
  function automatic logic [AddrWidth-1:0] beat_align(input logic [AddrWidth-1:0] a);
    return {a[AddrWidth-1:BeatAlignW], BeatAlignW'(0)};
  endfunction

  // Beats needed to transfer `rem` elements starting at byte offset `lane0`
  // (row-contiguous). Caps at MaxBurstBeats. Assumes PeLanes >= BytesPerBeat
  // so each full beat is absorbed in one cycle for A; B oct-drain does the same
  // at DataWidth=64 (up to 8 B/cycle).
  function automatic logic [7:0] beats_for_rem(
      input logic [31:0] rem,
      input logic [BeatLaneW-1:0] lane0
  );
    // Elements absorbed per beat is min(BytesPerBeat, PeLanes), both powers of
    // two, so the ceiling division is a constant shift (no divider cell).
    return 8'(g6lc_ai_island_cfg_pkg::ai_beats_for_rem(rem, 32'(lane0), BytesPerBeat,
                                                       ElemsPerBeatShift, MaxBurstBeats));
  endfunction

  // N=1: identity (return nb). N>1: do not cross DramChanShift stripe.
  function automatic logic [7:0] cap_beats_to_stripe(
      input logic [AddrWidth-1:0] addr,
      input logic [7:0] nb
  );
    automatic int unsigned maxb;
    maxb = g6lc_ai_island_cfg_pkg::dram_beats_in_stripe(
        NrChannels, ChanShift, BytesPerBeat, 64'(addr));
    if (32'(nb) > maxb) return maxb[7:0];
    return nb;
  endfunction

  function automatic logic [31:0] cap_nbeats_to_stripe(
      input logic [AddrWidth-1:0] addr,
      input logic [31:0] nbeats
  );
    automatic int unsigned maxb;
    maxb = g6lc_ai_island_cfg_pkg::dram_beats_in_stripe(
        NrChannels, ChanShift, BytesPerBeat, 64'(addr));
    if (nbeats > maxb) return 32'(maxb);
    return nbeats;
  endfunction

  // C beats are 8 bytes (aw.size=3), not the A/B beat. At DataWidth=64 the
  // two widths match, so the stripe cap is the same number as cap_nbeats.
  function automatic logic [31:0] cap_c_nbeats(
      input logic [AddrWidth-1:0] addr,
      input logic [31:0] nbeats
  );
    automatic int unsigned maxb;
    maxb = g6lc_ai_island_cfg_pkg::dram_beats_in_stripe(
        NrChannels, ChanShift, 8, 64'(addr));
    if (nbeats > maxb) return 32'(maxb);
    return nbeats;
  endfunction

  typedef struct packed {
    logic [DataWidth-1:0]   data;
    logic [DataWidth/8-1:0] strb;
  } wbeat_t;

  // Put `nbytes` (4 or 8) of `payload` on the byte lane `addr` selects.
  // DataWidth=64 and an 8-byte-aligned pair lands in [63:0] with strobe 8'hFF.
  // Bytes past the beat edge drop; the loop form is kept as wbeat_at_ref.
  function automatic wbeat_t wbeat_at_ref(
      input logic [63:0] payload,
      input int unsigned nbytes,
      input logic [31:0] addr
  );
    automatic wbeat_t b;
    automatic int unsigned lane, i, at;
    b.data = '0;
    b.strb = '0;
    lane = unsigned'(addr) & (BytesPerBeat - 1);
    for (i = 0; i < 8; i++) begin
      at = lane + i;
      if (i < nbytes && at < BytesPerBeat) begin
        b.data[8*at +: 8] = payload[8*i +: 8];
        b.strb[at]        = 1'b1;
      end
    end
    return b;
  endfunction

  function automatic wbeat_t wbeat_at(
      input logic [63:0] payload,
      input int unsigned nbytes,
      input logic [31:0] addr
  );
    // Barrel-shift form (D4): clamp the byte count to what fits past the
    // lane, mask the payload, one shift for data and one for the strobe.
    // `nfit` = bytes of payload surviving the beat edge (drops partial
    // byte lane, matching the reference loop's `at < BytesPerBeat`).
    automatic wbeat_t b;
    automatic int unsigned nfit;
    nfit  = (nbytes > BytesPerBeat - (unsigned'(addr) & (BytesPerBeat - 1)))
          ? BytesPerBeat - (unsigned'(addr) & (BytesPerBeat - 1)) : nbytes;
`ifdef G6LC_MUT_AI_WBEAT_LANE0
    // Review mutant: lane forced to 0 � misaligned beats fail.
    b.data = ((nfit >= 8) ? payload
             : payload & ((64'd1 << (8 * nfit)) - 64'd1));
    b.strb = BytesPerBeat'((8'd1 << nfit) - 8'd1);
`else
    b.data = ((nfit >= 8) ? payload
             : payload & ((64'd1 << (8 * nfit)) - 64'd1))
             << (8 * (unsigned'(addr) & (BytesPerBeat - 1)));
    b.strb = BytesPerBeat'(((8'd1 << nfit) - 8'd1))
             << (unsigned'(addr) & (BytesPerBeat - 1));
`endif
    return b;
  endfunction

  // One C beat: the `nwords` (a power of two, 2 or StoreWordsMax) consecutive
  // 32-bit words placed at the byte lane the address selects (0 when aligned).
  function automatic wbeat_t wbeat_words_ref(
      input logic [31:0] addr,
      input int unsigned nwords
  );
    automatic wbeat_t bt;
    automatic int unsigned lane, w, at;
    bt.data = '0;
    bt.strb = '0;
    lane = unsigned'(addr) & (BytesPerBeat - 1);
    for (w = 0; w < StoreWordsMax; w++) begin
      at = lane + 4 * w;
      if (w < nwords && at + 3 < BytesPerBeat) begin
        bt.data[8*at +: 32] = c_rx_data[w];
        bt.strb[at +: 4]    = 4'hF;
      end
    end
    return bt;
  endfunction

  function automatic wbeat_t wbeat_words(
      input logic [31:0] addr,
      input int unsigned nwords
  );
    // Barrel-shift form (D4): pack c_rx_data, clamp to words that fit a
    // beat (a word lands only when all 4 bytes do: at+3 < BytesPerBeat),
    // one shift for data and strobe.
    automatic wbeat_t bt;
    automatic int unsigned wfit;
    automatic logic [StoreWordsMax*32-1:0] pw;
    for (int unsigned w = 0; w < StoreWordsMax; w++)
      pw[32*w +: 32] = c_rx_data[w];
    wfit = (nwords > (BytesPerBeat - (unsigned'(addr) & (BytesPerBeat - 1))) / 4)
         ? (BytesPerBeat - (unsigned'(addr) & (BytesPerBeat - 1))) / 4 : nwords;
    bt.data = (DataWidth'(pw) & ((DataWidth'(1) << (32 * wfit)) - 1))
              << (8 * (unsigned'(addr) & (BytesPerBeat - 1)));
    bt.strb = BytesPerBeat'(((8'd1 << (4 * wfit)) - 8'd1))
              << (unsigned'(addr) & (BytesPerBeat - 1));
    return bt;
  endfunction

  // Elements covered by `nb` beats starting at byte lane `lane0`, cap `rem`
  function automatic logic [31:0] elems_for_burst(
      input logic [31:0] rem,
      input logic [BeatLaneW-1:0] lane0,
      input logic [7:0] nb
  );
    automatic logic [31:0] first, cap, nbb;
    if (rem == 0) return 32'd0;
    first = 32'(BytesPerBeat) - 32'(lane0);
    if (first > rem) first = rem;
    nbb = 32'(nb);
    if (nbb <= 32'd1) return first;
    cap = first + (nbb - 32'd1) * 32'(BytesPerBeat);
    if (cap > rem) cap = rem;
    return cap;
  endfunction

  // Bank map: bank = t % PeLanes (or t for A / B along reduction);
  // local index = i * KPerBank + t / PeLanes  (A); for B: j * KPerBank + t / PeLanes
  // PeLanes is a power of two (asserted): bank select is a mask, row index a shift,
  // so no $div/$mod cell survives synthesis on the bank address paths.
  function automatic logic [LaneW-1:0] t_bank(input logic [31:0] t);
    return LaneW'(t & 32'(PeLanes - 1));
  endfunction

  // Flat panel: row i of A (row j of B) starts at i << pitch_sh_q bank words;
  // `t` is the byte offset in the row, PeLanes bytes per word.
  function automatic logic [OperandBankAddrW-1:0] a_bank_addr(
      input logic [31:0] i, t
  );
    return OperandBankAddrW'(g6lc_ai_island_cfg_pkg::ai_flat_row_word(i, pitch_sh_q, t, LaneShift));
  endfunction

  // Column group of B row j and its row index inside the group.
  function automatic logic [ColW-1:0] col_grp(input logic [31:0] j);
    return ColW'(j & 32'(OutCols - 1));
  endfunction
  function automatic logic [OperandBankAddrW-1:0] b_bank_addr(
      input logic [31:0] t, j
  );
    return OperandBankAddrW'(g6lc_ai_island_cfg_pkg::ai_flat_row_word(j >> ColShift, pitch_sh_q, t, LaneShift)) + b_base_q;
  endfunction

  // C bank map: bank = j % PeLanes; local = i * KPerBank + j / PeLanes
  function automatic logic [LaneW-1:0] c_bank(input logic [31:0] j);
    return LaneW'(j & 32'(PeLanes - 1));
  endfunction

  // pragma translate_off
  initial assert (KPerBank == 0 || (KPerBank & (KPerBank - 1)) == 0)
    else $fatal(1, "g6lc_ai_gemm_seq: KPerBank %0d not power-of-two", KPerBank);
  // pragma translate_on
  function automatic logic [BankAddrW-1:0] c_bank_addr(
      input logic [31:0] i, j
  );
    // D2b: KPerBank is asserted power-of-two (LimN and PeLanes are powers
    // of two in every shipped cfg); the row*KPerBank is then a shift.
    return BankAddrW'((int'(i) << $clog2(KPerBank)) + int'(j >> LaneShift));
  endfunction

  logic [AddrWidth-1:0] a_cur, b_cur, a_ar_cur, b_ar_cur, c_store_addr;
  // The trail store may run: the cursor row is complete, or (even n) it is the
  // row under computation and at least one whole pair beyond the cursor is written.
  // A burst inside the row waits for TrailMinPairs written pairs, and rows shorter
  // than TrailMinCols are stored only once complete: on a 16-column row the split
  // into two AWs cost 2-5 cycles on the 8-lane bench, while a 512-column decode row
  // hides its whole ~n/2-beat store tail behind the MAC (778 -> ~530 cycles).
  localparam int unsigned TrailMinPairs = 4;
  localparam int unsigned TrailMinCols  = 32;
  logic trail_ready;
  assign trail_ready = stc_i_q < 32'(c_rows_done_q) ||
                       (!n_q[0] && n_q >= 32'(TrailMinCols) &&
                        32'(c_cols_row_q) == stc_i_q &&
                        c_cols_done_q >= stc_j_q + 32'(2 * TrailMinPairs));
  // Receive cursors (tile write / MAC)
  // D2a registered cursors: a_cur_q/b_cur_q carry the receive element
  // address; a_addr/b_addr stay as translate_off miters below. The row
  // bases and per-job strides are job-constant registers latched at start.
  logic [AddrWidth-1:0] a_cur_q, b_cur_q;
  logic [AddrWidth-1:0] a_row_base_q, b_row_base_q;
  logic [31:0]          stride_a_q, stride_b_q, stride_b_grp_q;
  assign a_cur        = a_cur_q;
  assign b_cur        = b_cur_q;
  assign a_ar_cur     = a_addr(pa_q, ar_i_q, ar_t_q, lda_q);
  assign b_ar_cur     = b_addr(pb_q, ar_t_q, ar_j_q, ldb_q);
  assign c_store_addr = c_addr(pc_q, stc_i_q, stc_j_q, ldc_eff);
  // Issue cursors (AR address may run ahead of receive)
  // Store address uses trail cursor (not MAC i/j)
  assign ar_head_lane = ar_lane_mem_q[0];

  always_comb begin
    logic [31:0] byte_base, byte_idx;
    byte_base = numfmt_q == 3'd1 ? t_q >> 1 : t_q << ai_fmt_shift();
    byte_idx = '0;
    for (int unsigned p = 0; p < PeLanes; p++) begin
      a_r_req[p] = 1'b0;
      a_r_addr[p] = '0;
      for (int unsigned g = 0; g < OutCols; g++) begin
        b_r_req[g][p] = 1'b0;
        b_r_addr[g][p] = '0;
      end
      byte_idx = byte_base + 32'(p);
      if (state_q == ST_MAC && i_q < m_q &&
          ((numfmt_q == 3'd1) ? t_q + 32'(p << 1) < k_q : byte_idx < k_bytes)) begin
        a_r_req[p] = 1'b1;
        a_r_addr[p] = a_bank_addr(i_q, byte_idx);
        // Static destination index (a dynamic first index on the write side is a
        // read-modify-write of the array to a synthesis frontend -> logic loop).
        for (int unsigned g = 0; g < OutCols; g++)
          for (int unsigned gg = 0; gg < OutCols; gg++)
            if (col_v[g] && grp_of[g] == ColW'(gg)) begin
              b_r_req[gg][p] = 1'b1;
              b_r_addr[gg][p] = b_bank_addr(byte_idx, j_q + 32'(g));
            end
      end
    end
  end

  always_comb begin
    logic trail, pair_store;
    logic [31:0] beats_done, column;
    pair_store = DataWidth >= 64 && !n_q[0];
    trail = state_q == ST_MAC && DualCRead && DataWidth >= 64 && dot_pending_q == '0 &&
        !acc_mode_q && trail_ready;
    beats_done = 32'(stc_elem_q >> wsh_q) - 32'(stc_w_left_q);
    column = stc_j_q + (beats_done << wsh_q);
    c_r0_req = 1'b0;
    c_r0_bank = '0;
    c_r0_addr = '0;
    c_r1_req = 1'b0;
    c_r1_bank = '0;
    c_r1_addr = '0;
    for (int unsigned w = 0; w < StoreWordsMax; w++) begin
      c_rx_req[w]  = 1'b0;
      c_rx_bank[w] = '0;
      c_rx_addr[w] = '0;
    end
    if (seed_capture) begin
      // Capture alongside the first partial; the accumulator consumes it next cycle.
      c_r0_req  = 1'b1;
      c_r0_bank = c_bank(seed_j);
      c_r0_addr = c_bank_addr(seed_i, seed_j);
    end else if (trail || state_q == ST_STC) begin
      if (!pair_store) begin
        c_r0_req = 1'b1;
        c_r0_bank = c_bank(stc_j_q);
        c_r0_addr = c_bank_addr(stc_i_q, stc_j_q);
      end else if (aw_sent_q && stc_w_left_q != 0) begin
        c_r0_req = 1'b1;
        if (DualCRead) begin
          c_r0_bank = c_bank(column);
          c_r0_addr = c_bank_addr(stc_i_q, column);
          c_r1_req = 1'b1;
          c_r1_bank = c_bank(column + 32'd1);
          c_r1_addr = c_bank_addr(stc_i_q, column + 32'd1);
          // Wide beat: columns 2..W-1 of the beat as well.
          if (wide_c_q)
            for (int unsigned w = 2; w < StoreWordsMax; w++) begin
              c_rx_req[w]  = 1'b1;
              c_rx_bank[w] = c_bank(column + 32'(w));
              c_rx_addr[w] = c_bank_addr(stc_i_q, column + 32'(w));
            end
        end else begin
          c_r0_bank = c_bank(column + 32'(c_pair_hold_q));
          c_r0_addr = c_bank_addr(stc_i_q, column + 32'(c_pair_hold_q));
        end
      end
    end
  end

  always_comb begin
    logic [31:0] t_byte_base;
    t_byte_base = numfmt_q == 3'd1 ? t_q >> 1 : t_q << ai_fmt_shift();
    for (int unsigned p = 0; p < PeLanes; p++) begin
      pe_a[p] = '0;
      pe_a_float[p] = '0;
      pe_v[p] = 1'b0;
      for (int unsigned g = 0; g < OutCols; g++) begin
        pe_b[g][p] = '0;
        pe_b_float[g][p] = '0;
      end
    end
    if (state_q == ST_MAC && i_q < m_q) begin
      for (int unsigned p = 0; p < PeLanes; p++) begin
        if (numfmt_q == 3'd1) begin
          // INT4: two elements per byte. Lane p covers elements
          // (t_q + 2p) and (t_q + 2p + 1) in the same byte.
          automatic logic [31:0] e0, e1;
          e0 = t_q + 32'(p << 1);
          e1 = e0 + 32'd1;
          if (e0 < k_q) begin
            // Mask the invalid nibble(s) to 0; the PE sign-extends the
            // remaining nibble and computes two products, one of which is 0.
            pe_a[p] = {(e1 < k_q) ? a_r_data[p][7:4] : 4'b0000,
                       (e0 < k_q) ? a_r_data[p][3:0] : 4'b0000};
            for (int unsigned g = 0; g < OutCols; g++)
              pe_b[g][p] = {(e1 < k_q) ? b_r_data[grp_of[g]][p][7:4] : 4'b0000,
                            (e0 < k_q) ? b_r_data[grp_of[g]][p][3:0] : 4'b0000};
            pe_v[p] = 1'b1;
          end
        end else begin
          // INT8/FP8/BF16/FP16/FP32: load bytes, then assemble elements
          // into 32-bit float lanes.  `byte_idx` is the byte position
          // along the K row; `k_bytes` comes from fmt_row_bytes().
          automatic logic [31:0] byte_idx;
          byte_idx = t_byte_base + 32'(p);
          if (byte_idx < k_bytes) begin
            pe_a[p] = $signed(a_r_data[p]);
            for (int unsigned g = 0; g < OutCols; g++)
              pe_b[g][p] = $signed(b_r_data[grp_of[g]][p]);
          end
        end
      end

      // Assemble multi-byte floating operands (BF16/FP16/FP32) from the
      // byte-lane read data. For INT8/FP8 this is a zero-extend; for
      // FP16/BF16 it is two bytes little-endian; for FP32 it is four.
      // INT4 stays in its own branch above.
      if (numfmt_q != 3'd1) begin
        // Bounded by the PeLanes parameter, not by the runtime mac_step:
        // on this branch (numfmt != INT4) mac_step is PeLanes/bytes, so it
        // can never exceed PeLanes and the extra iterations are inert.  A
        // constant bound is what makes this loop elaborate under an open
        // synthesis frontend -- with the runtime bound, Yosys read_slang
        // tries to unroll it and exhausts its limit, which left the whole
        // GEMM datapath without any gate-level area or timing evidence.
        for (int unsigned e = 0; e < PeLanes; e++) begin
          automatic logic [31:0] elem_t;
          automatic logic [31:0] off;
          elem_t = t_q + 32'(e);
          off = 32'(e) << ai_fmt_shift();
          if (int'(e) < int'(mac_step) && elem_t < k_q) begin
            case (ai_fmt_bytes())
              32'd1: begin
                pe_a_float[e] = {24'b0, a_r_data[off]};
                for (int unsigned g = 0; g < OutCols; g++)
                  pe_b_float[g][e] = {24'b0, b_r_data[grp_of[g]][off]};
              end
              32'd2: begin
                pe_a_float[e] = {16'b0, a_r_data[off+1], a_r_data[off]};
                for (int unsigned g = 0; g < OutCols; g++)
                  pe_b_float[g][e] = {16'b0, b_r_data[grp_of[g]][off+1], b_r_data[grp_of[g]][off]};
              end
              32'd4: begin
                pe_a_float[e] = {a_r_data[off+3], a_r_data[off+2], a_r_data[off+1], a_r_data[off]};
                for (int unsigned g = 0; g < OutCols; g++)
                  pe_b_float[g][e] = {b_r_data[grp_of[g]][off+3], b_r_data[grp_of[g]][off+2],
                                      b_r_data[grp_of[g]][off+1], b_r_data[grp_of[g]][off]};
              end
              default: begin
                pe_a_float[e] = 32'd0;
                for (int unsigned g = 0; g < OutCols; g++) pe_b_float[g][e] = 32'd0;
              end
            endcase
            pe_v[e] = 1'b1;
          end
        end
      end
    end
  end

  // D6 hoist: AR/store issue address math moved out of the mega-block.
  // Each *_pre wire is a pure function of registered state + axi_resp_s;
  // the mega-block only selects/consumes them (same expressions, evaluated
  // unconditionally -- functionally identical).
  logic [AddrWidth-1:0] ar_a_pre_addr,  ar_b_pre_addr;
  logic [BeatLaneW-1:0] ar_a_pre_lane,  ar_b_pre_lane;
  logic [31:0]          ar_a_pre_rem,   ar_b_pre_rem;
  logic [7:0]           ar_a_pre_nb,    ar_b_pre_nb;
  logic [31:0]          ar_a_pre_elems, ar_b_pre_elems;
  logic                 ar_a_pre_row_last, ar_b_pre_row_last;
`ifdef G6LC_AI_GEMM_LEGACY_CONTROL
  always_comb begin
    ar_a_pre_lane     = a_ar_cur[BeatAlignW-1:0];
    ar_a_pre_addr     = beat_align(a_ar_cur);
    ar_a_pre_rem      = beats_for_rem(k_bytes - ar_t_q, ar_a_pre_lane);
    ar_a_pre_nb       = cap_beats_to_stripe(ar_a_pre_addr, ar_a_pre_rem);
    ar_a_pre_elems    = elems_for_burst(k_bytes - ar_t_q, ar_a_pre_lane, ar_a_pre_nb);
    ar_a_pre_row_last = (ar_t_q + ar_a_pre_elems) >= k_bytes;
  end
  always_comb begin
    ar_b_pre_lane     = b_ar_cur[BeatAlignW-1:0];
    ar_b_pre_addr     = beat_align(b_ar_cur);
    ar_b_pre_rem      = beats_for_rem(k_bytes - ar_t_q, ar_b_pre_lane);
    ar_b_pre_nb       = cap_beats_to_stripe(ar_b_pre_addr, ar_b_pre_rem);
    ar_b_pre_elems    = elems_for_burst(k_bytes - ar_t_q, ar_b_pre_lane, ar_b_pre_nb);
    ar_b_pre_row_last = (ar_t_q + ar_b_pre_elems) >= k_bytes;
  end
`else
  // The issue cursor remains owned by the sequencer. Plan exactly one burst
  // from that stable cursor, hold all facts together until local AR acceptance,
  // then resample the updated cursor. No speculative cursor or FIFO replay.
  logic [2:0] ar_plan_phase_q;
  logic ar_plan_b_q, ar_plan_valid;
  logic [AddrWidth-1:0] ar_plan_addr_q;
  logic [BeatLaneW-1:0] ar_plan_lane_q;
  logic [31:0] ar_plan_rem_q, ar_plan_capacity_q, ar_plan_elems_q;
  logic [7:0] ar_plan_nb_q;
  logic ar_plan_last_q;
  assign ar_plan_valid = ar_plan_phase_q == 3'd5 &&
      ((state_q == ST_LA && !ar_plan_b_q) || (state_q == ST_LB && ar_plan_b_q));
  always_ff @(posedge clk_i or negedge rst_ni) begin : plan_operand_burst
    if (!rst_ni) begin
      ar_plan_phase_q <= '0;
      ar_plan_b_q <= 1'b0;
      ar_plan_addr_q <= '0;
      ar_plan_lane_q <= '0;
      ar_plan_rem_q <= '0;
      ar_plan_nb_q <= '0;
      ar_plan_capacity_q <= '0;
      ar_plan_elems_q <= '0;
      ar_plan_last_q <= 1'b0;
    end else if (!(state_q == ST_LA || state_q == ST_LB) ||
                 (ar_plan_phase_q != 0 && ar_plan_b_q != (state_q == ST_LB))) begin
      ar_plan_phase_q <= '0;
    end else begin
      unique case (ar_plan_phase_q)
        3'd0: begin
          ar_plan_b_q <= state_q == ST_LB;
          ar_plan_addr_q <= beat_align(state_q == ST_LA ? a_ar_cur : b_ar_cur);
          ar_plan_lane_q <= BeatLaneW'(state_q == ST_LA ? a_ar_cur : b_ar_cur);
          ar_plan_rem_q <= k_bytes - ar_t_q;
          ar_plan_phase_q <= 3'd1;
        end
        3'd1: begin
          ar_plan_nb_q <= beats_for_rem(ar_plan_rem_q, ar_plan_lane_q);
          ar_plan_phase_q <= 3'd2;
        end
        3'd2: begin
          ar_plan_nb_q <= cap_beats_to_stripe(ar_plan_addr_q, ar_plan_nb_q);
          ar_plan_phase_q <= 3'd3;
        end
        3'd3: begin
          // nb is >=1 on an offered burst. Count bytes, not numeric elements.
          ar_plan_capacity_q <= (32'(ar_plan_nb_q) << BeatAlignW) - 32'(ar_plan_lane_q);
          ar_plan_phase_q <= 3'd4;
        end
        3'd4: begin
          ar_plan_elems_q <= ar_plan_rem_q < ar_plan_capacity_q ?
                             ar_plan_rem_q : ar_plan_capacity_q;
          ar_plan_last_q <= ar_plan_rem_q <= ar_plan_capacity_q;
          ar_plan_phase_q <= 3'd5;
        end
        3'd5: if (axi_req_d.ar_valid && axi_resp_s.ar_ready) ar_plan_phase_q <= '0;
        default: ar_plan_phase_q <= '0;
      endcase
    end
  end
  assign ar_a_pre_addr = ar_plan_addr_q;
  assign ar_b_pre_addr = ar_plan_addr_q;
  assign ar_a_pre_lane = ar_plan_lane_q;
  assign ar_b_pre_lane = ar_plan_lane_q;
  assign ar_a_pre_rem = ar_plan_rem_q;
  assign ar_b_pre_rem = ar_plan_rem_q;
  assign ar_a_pre_nb = ar_plan_nb_q;
  assign ar_b_pre_nb = ar_plan_nb_q;
  assign ar_a_pre_elems = ar_plan_elems_q;
  assign ar_b_pre_elems = ar_plan_elems_q;
  assign ar_a_pre_row_last = ar_plan_last_q;
  assign ar_b_pre_row_last = ar_plan_last_q;
`endif

`ifndef G6LC_AI_GEMM_LEGACY_CONTROL
  // r16 hand split. Each next-state/output family has one owner. Cross-family
  // dependencies are transaction events, never partially assigned request structs.
  // The legacy arm is retained only for same-source ablation with the cuts bypassed.
  axi_req_t read_req, store_req;
  logic load_a, load_b, load_active, load_ar_fire, load_r_fire;
  logic load_r_match, load_done, skip_b, bad_job, seed_done;
  logic [ARSlotW-1:0] issue_slot, receive_slot;
  logic [31:0] receive_row, receive_col, receive_count, receive_rem, receive_room;
  logic [BeatLaneW-1:0] receive_lane;
  logic [31:0] issued_row_next;
  logic [AddrWidth-1:0] lc_plan_addr;
  logic [7:0] lc_plan_beats;
  logic store_active, store_pair, store_reset, store_b_fire, store_rows_done;
  logic [31:0] store_beats, store_row_beats, store_safe_beats, store_beats_done;
  logic [31:0] store_beat_addr;
  logic [15:0] store_retire_elems;
  wbeat_t store_word;

  assign load_a = state_q == ST_LA;
  assign load_b = state_q == ST_LB;
  assign load_active = load_a || load_b;
  assign skip_b = ReuseBEn && reuse_b_skip_q && reuse_b_safe &&
                  !reuse_b_invalidate_i && !err_q &&
                  !(load_r_fire && axi_resp_s.r.resp[1]);
  assign seed_done = lc_e_q >= lc_total_q && !lc_buf_v_q && !lc_ar_busy_q;
  assign bad_job = m_q == 0 || n_q == 0 || k_q == 0 ||
      m_q > LimM || n_q > LimN || !cap_ok_c ||
      ai_fmt_bytes() > MaxElementBytes || lda_q < k_q[15:0] ||
      ldb_q < k_q[15:0] ||
      !g6lc_ai_island_cfg_pkg::ai_elem_aligned(pa_q, numfmt_q) ||
      !g6lc_ai_island_cfg_pkg::ai_elem_aligned(pb_q, numfmt_q) ||
      !g6lc_ai_island_cfg_pkg::ai_c_aligned(pc_q, n_q[0]);

  // Slot selection is shared by AR allocation and R matching. A stalled offer
  // keeps its reserved ID even if an older response frees a lower-numbered slot.
  always_comb begin : select_load_slots
    logic found_free;
    found_free = 1'b0;
    issue_slot = '0;
    receive_slot = '0;
    load_r_match = !SplitArId;
    if (SplitArId) begin
      for (int unsigned s = 0; s < MaxAROut; s++) begin
        if (!ar_slot_q[s].valid && !found_free) begin
          issue_slot = ARSlotW'(s);
          found_free = 1'b1;
        end
        if (ar_slot_q[s].valid &&
            axi_resp_s.r.id == (ArIdBase + IdWidth'(s))) begin
          receive_slot = ARSlotW'(s);
          load_r_match = 1'b1;
        end
      end
    end
    if (ar_hold_q) issue_slot = ar_hold_slot_q;
  end

  // AR presentation, including the separate accumulate-C reader.
  always_comb begin : plan_seed_read
    logic [31:0] left;
    lc_plan_addr = beat_align(pc_q) + AddrWidth'(lc_issued_q) * AddrWidth'(BytesPerBeat);
    left = lc_beats_q - lc_issued_q;
    lc_plan_beats = cap_beats_to_stripe(lc_plan_addr,
        (left > MaxBurstBeats) ? 32'(MaxBurstBeats) : left);
  end

  always_comb begin : present_read_channels
    read_req = '0;
    read_req.ar.id = IdWidth'(2);
    read_req.ar.size = axi_pkg::size_t'($clog2(BytesPerBeat));
    read_req.ar.burst = axi_pkg::BURST_INCR;
    read_req.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    if (load_active) begin
      read_req.ar.addr = load_a ? ar_a_pre_addr : ar_b_pre_addr;
      read_req.ar.len = axi_pkg::len_t'((load_a ? ar_a_pre_nb : ar_b_pre_nb) - 8'd1);
      if (SplitArId) read_req.ar.id = ArIdBase + IdWidth'(issue_slot);
      read_req.ar_valid = !load_complete_q && ar_plan_valid && (ar_hold_q || ar_inflight_q < ar_max_eff) &&
                         (load_a ? ar_i_q < m_q : ar_j_q < n_q);
      read_req.r_ready = ar_inflight_q != '0 &&
                        (!SplitArId || !axi_resp_s.r_valid || load_r_match);
    end else if (state_q == ST_LC) begin
      read_req.ar.addr = lc_plan_addr;
      read_req.ar.len = axi_pkg::len_t'(lc_plan_beats - 8'd1);
      read_req.ar_valid = !lc_ar_busy_q && lc_issued_q < lc_beats_q;
      read_req.r_ready = lc_ar_busy_q && !lc_buf_v_q;
    end
  end
  assign load_ar_fire = load_active && read_req.ar_valid && axi_resp_s.ar_ready;
  assign load_r_fire = load_active && read_req.r_ready && axi_resp_s.r_valid;
  assign lc_ar_fire = state_q == ST_LC && read_req.ar_valid && axi_resp_s.ar_ready;
  assign lc_ar_beats = lc_plan_beats;
  assign lc_r_fire = state_q == ST_LC && read_req.r_ready && axi_resp_s.r_valid;
  assign lc_w_fire = state_q == ST_LC && lc_buf_v_q && lc_e_q < lc_total_q;

  // R metadata is independent of AR issue. The accepted response owns its lane,
  // cursor and ID until the bank write edge.
  always_comb begin : decode_load_response
    logic first;
    receive_row = SplitArId ? ar_slot_q[receive_slot].row : (load_a ? i_q : j_q);
    receive_col = SplitArId ? ar_slot_q[receive_slot].col : t_q;
    first = SplitArId ? ar_slot_q[receive_slot].first : burst_first_q;
    receive_lane = first ?
        (SplitArId ? ar_slot_q[receive_slot].lane0 : ar_head_lane) : BeatLaneW'(0);
    receive_rem = k_bytes - receive_col;
    receive_room = 32'(BytesPerBeat) - 32'(receive_lane);
    receive_count = receive_rem < receive_room ? receive_rem : receive_room;
    if (receive_count > PeLanes) receive_count = PeLanes;
  end

  always_comb begin : write_operand_banks
    for (int unsigned p = 0; p < PeLanes; p++) begin
      a_w_req[p] = 1'b0;
      a_w_addr[p] = '0;
      a_w_data[p] = '0;
      for (int unsigned g = 0; g < OutCols; g++) begin
        b_w_req[g][p] = 1'b0;
        b_w_addr[g][p] = '0;
        b_w_data[g][p] = '0;
      end
    end
    if (load_r_fire) begin
      for (int unsigned p = 0; p < PeLanes; p++) begin
        if (32'(p) < receive_count) begin
          if (load_a) begin
            a_w_req[t_bank(receive_col + 32'(p))] = 1'b1;
            a_w_addr[t_bank(receive_col + 32'(p))] =
                a_bank_addr(receive_row, receive_col + 32'(p));
            a_w_data[t_bank(receive_col + 32'(p))] =
                byte_from_beat(axi_resp_s.r.data, BeatLaneW'(32'(receive_lane) + p));
          end else begin
            for (int unsigned g = 0; g < OutCols; g++) begin
              if (col_grp(receive_row) == ColW'(g)) begin
                b_w_req[g][t_bank(receive_col + 32'(p))] = 1'b1;
                b_w_addr[g][t_bank(receive_col + 32'(p))] =
                    b_bank_addr(receive_col + 32'(p), receive_row);
                b_w_data[g][t_bank(receive_col + 32'(p))] =
                    byte_from_beat(axi_resp_s.r.data, BeatLaneW'(32'(receive_lane) + p));
              end
            end
          end
        end
      end
    end
  end

  always_comb begin : account_load_transactions
    ar_inflight_d = ar_inflight_q;
    burst_first_d = burst_first_q;
    if (state_q == ST_IDLE || (state_q == ST_CHK && !bad_job)) begin
      ar_inflight_d = '0;
      burst_first_d = 1'b0;
    end else if (load_active) begin
      unique case ({load_ar_fire, load_r_fire && axi_resp_s.r.last})
        2'b10: begin
          ar_inflight_d = ar_inflight_q + AROutW'(1);
          if (ar_inflight_q == '0) burst_first_d = 1'b1;
        end
        2'b01: begin
          ar_inflight_d = ar_inflight_q - AROutW'(1);
          burst_first_d = ar_inflight_q > AROutW'(1);
        end
        2'b11: burst_first_d = 1'b1;
        default: ;
      endcase
      if (load_r_fire && !axi_resp_s.r.last) burst_first_d = 1'b0;
    end
  end
  assign issued_row_next = (load_a ? ar_i_q : ar_j_q) +
      32'(load_ar_fire && (load_a ? ar_a_pre_row_last : ar_b_pre_row_last));
  logic load_complete_q, load_done_event;
  assign load_done_event = load_active && (SplitArId ?
      (issued_row_next >= (load_a ? m_q : n_q) && ar_inflight_d == '0) :
      (load_r_fire && receive_col + receive_count >= k_bytes &&
       receive_row + 32'd1 == (load_a ? m_q : n_q)));
  // A short panel can finish before the seed-product window. Preserve the
  // receive completion while that join holds this load state; do not reissue it.
  assign load_done = load_complete_q || load_done_event;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) load_complete_q <= 1'b0;
    else if (!load_active || state_d != state_q) load_complete_q <= 1'b0;
    else if (load_done_event) load_complete_q <= 1'b1;
  end

  assign ar_lane_push_en = load_ar_fire;
  assign ar_lane_push = load_a ? ar_a_pre_lane : ar_b_pre_lane;
  assign ar_lane_pop_en = load_r_fire && axi_resp_s.r.last;
  assign ar_slot_we = SplitArId && load_ar_fire;
  assign ar_slot_widx = issue_slot;
  assign ar_slot_push_row = load_a ? ar_i_q : ar_j_q;
  assign ar_slot_push_col = ar_t_q;
  assign ar_slot_r_en = SplitArId && load_r_fire;
  assign ar_slot_ridx = receive_slot;
  assign ar_slot_r_last = axi_resp_s.r.last;
  assign ar_slot_ntake = receive_count;
  assign la_n_d = (load_a && load_r_fire) ? receive_count[7:0] : 8'd0;
  assign lb_n_d = (load_b && load_r_fire) ? receive_count[7:0] : 8'd0;
  always_comb begin : advance_issue_cursor
    ar_i_en = 1'b0; ar_j_en = 1'b0; ar_t_en = 1'b0;
    ar_i_d = ar_i_q; ar_j_d = ar_j_q; ar_t_d = ar_t_q;
    if (load_ar_fire) begin
      ar_t_en = 1'b1;
      if (load_a ? ar_a_pre_row_last : ar_b_pre_row_last) begin
        ar_t_d = '0;
        if (load_a) begin ar_i_en = 1'b1; ar_i_d = ar_i_q + 32'd1; end
        else begin ar_j_en = 1'b1; ar_j_d = ar_j_q + 32'd1; end
      end else ar_t_d = ar_t_q + (load_a ? ar_a_pre_elems : ar_b_pre_elems);
    end
    if ((state_q == ST_CHK && !bad_job) || (load_a && load_done)) begin
      ar_i_en = 1'b1; ar_i_d = '0;
      ar_j_en = 1'b1; ar_j_d = '0;
      ar_t_en = 1'b1; ar_t_d = '0;
    end
  end

  // One C-store engine serves the MAC trail and the dedicated drain state.
  // All burst limits are functions of registers, upstream of channel acceptance.
  assign store_active = state_q == ST_STC ||
      (state_q == ST_MAC && DualCRead && DataWidth >= 64 && !acc_mode_q &&
       dot_pending_q == '0 && trail_ready);
  assign store_pair = DataWidth >= 64 && !n_q[0];
  assign store_rows_done = stc_i_q + 32'd1 >= m_q &&
                           stc_j_q + 32'(store_retire_elems) >= n_q;
  assign store_reset = state_q == ST_IDLE ||
      (state_q == ST_MAC && (!DualCRead || acc_mode_q) &&
       i_q >= m_q && dot_pending_q == '0);

  always_comb begin : plan_store_burst
    store_row_beats = (n_q - stc_j_q) >> wsh_q;
    store_safe_beats = store_row_beats;
    if (state_q == ST_MAC && !(stc_i_q < 32'(c_rows_done_q)) &&
        store_safe_beats > ((c_cols_done_q - stc_j_q) >> wsh_q))
      store_safe_beats = (c_cols_done_q - stc_j_q) >> wsh_q;
    if (store_safe_beats > MaxBurstBeats) store_safe_beats = MaxBurstBeats;
    store_beats = wide_c_q ? cap_nbeats_to_stripe(c_store_addr, store_safe_beats) :
                            cap_c_nbeats(c_store_addr, store_safe_beats);
    if (store_beats == 0) store_beats = 1;
  end
  assign store_beats_done = 32'(stc_elem_q >> wsh_q) - 32'(stc_w_left_q);
  assign store_beat_addr = 32'(c_store_addr) +
                          (store_beats_done << (32'd2 + 32'(wsh_q)));
  always_comb begin : pack_store_data
    if (!store_pair) store_word = wbeat_at(64'(c_r0_data), 4, 32'(c_store_addr));
    else if (DualCRead) store_word = wbeat_words(store_beat_addr, wide_c_q ? StoreWordsMax : 2);
    else store_word = wbeat_at({c_r0_data, c_lo_q}, 8,
                              32'(c_store_addr) + (store_beats_done << 3));
  end
  always_comb begin : present_store_channels
    store_req = '0;
    store_req.aw.id = IdWidth'(2);
    store_req.aw.addr = c_store_addr;
    store_req.aw.burst = axi_pkg::BURST_INCR;
    store_req.aw.size = axi_pkg::size_t'(2);
    store_req.w.data = store_word.data;
    store_req.w.strb = store_word.strb;
    store_req.w.last = 1'b1;
    if (store_pair) begin
      store_req.aw.len = axi_pkg::len_t'(store_beats - 32'd1);
      store_req.aw.size = axi_pkg::size_t'(32'd2 + 32'(wsh_q));
      store_req.w.last = stc_w_left_q == 9'd1;
    end
    if (store_active) begin
      store_req.aw_valid = !aw_sent_q;
      if (store_pair) begin
        store_req.w_valid = aw_sent_q && stc_w_left_q != '0 &&
                            (DualCRead || c_pair_hold_q);
        store_req.b_ready = aw_sent_q && stc_w_left_q == '0;
      end else begin
        store_req.w_valid = !w_sent_q;
        // Hold an early buffered B until both local AW and W have been accepted.
        store_req.b_ready = aw_sent_q && w_sent_q;
      end
    end
  end
  assign store_b_fire = store_req.b_ready && axi_resp_s.b_valid;
  assign store_retire_elems = store_pair ? stc_elem_q : 16'd1;
  always_comb begin : advance_store
    aw_sent_d = aw_sent_q;
    w_sent_d = w_sent_q;
    c_pair_hold_d = c_pair_hold_q;
    c_lo_we_d = 1'b0;
    stc_w_left_d = stc_w_left_q;
    stc_elem_d = stc_elem_q;
    stc_n_d = store_pair ? stc_elem_q : 16'd1;
    stc_i_en = 1'b0; stc_i_d = stc_i_q;
    stc_j_en = 1'b0; stc_j_d = stc_j_q;
    if (store_req.aw_valid && axi_resp_s.aw_ready) begin
      aw_sent_d = 1'b1;
      stc_elem_d = store_pair ? (store_beats[15:0] << wsh_q) : 16'd1;
      if (store_pair) begin
        stc_w_left_d = store_beats[8:0];
        w_sent_d = 1'b0;
        c_pair_hold_d = 1'b0;
      end
    end
    if (store_active && store_pair && aw_sent_q && stc_w_left_q != '0 &&
        !DualCRead && !c_pair_hold_q) begin
      c_lo_we_d = 1'b1;
      c_pair_hold_d = 1'b1;
    end
    if (store_req.w_valid && axi_resp_s.w_ready) begin
      if (store_pair) begin
        stc_w_left_d = stc_w_left_q - 9'd1;
        if (!DualCRead) c_pair_hold_d = 1'b0;
        if (stc_w_left_q == 9'd1) w_sent_d = 1'b1;
      end else w_sent_d = 1'b1;
    end
    if (store_b_fire) begin
      aw_sent_d = 1'b0; w_sent_d = 1'b0;
      c_pair_hold_d = 1'b0;
      stc_elem_d = '0;
      stc_j_en = 1'b1;
      if (stc_j_q + 32'(store_retire_elems) >= n_q) begin
        stc_j_d = '0;
        stc_i_en = 1'b1; stc_i_d = stc_i_q + 32'd1;
      end else stc_j_d = stc_j_q + 32'(store_retire_elems);
    end
    if (store_reset) begin
      aw_sent_d = 1'b0; w_sent_d = 1'b0;
      c_pair_hold_d = 1'b0;
      stc_w_left_d = '0; stc_elem_d = '0;
    end
  end

  always_comb begin : assemble_axi_request
    axi_req_d = '0;
    axi_req_d.ar = read_req.ar;
    axi_req_d.ar_valid = read_req.ar_valid;
    axi_req_d.r_ready = read_req.r_ready;
    axi_req_d.aw = store_req.aw;
    axi_req_d.aw_valid = store_req.aw_valid;
    axi_req_d.w = store_req.w;
    axi_req_d.w_valid = store_req.w_valid;
    axi_req_d.b_ready = store_req.b_ready;
  end

  // FSM depends on completion events, not on fields assigned in channel blocks.
  always_comb begin : advance_job
    state_d = state_q;
    unique case (state_q)
      ST_IDLE: if (start_i) state_d = ST_CHK;
      ST_CHK: begin
        if (bad_job) state_d = ST_DONE;
        else if (ReuseAEn && reuse_a_skip_q && reuse_a_safe && !reuse_a_invalidate_i)
          state_d = skip_b ? ST_MAC : ST_LB;
        else state_d = ST_LA;
      end
      ST_LA: if (load_done) state_d = skip_b ? ST_MAC : ST_LB;
      ST_LB: if (load_done) state_d = ST_MAC;
      ST_LC: begin
        if (err_q) begin
          if (!lc_ar_busy_q) state_d = ST_DONE;
        end else if (seed_done) state_d = ST_MAC;
      end
      ST_MAC: begin
        if (i_q >= m_q && stc_i_q >= m_q && !aw_sent_q && !sum_v_q &&
            dot_pending_q == '0) state_d = ST_DONE;
        else if (store_reset) state_d = ST_STC;
      end
      ST_STC: if (store_b_fire && store_rows_done) state_d = ST_DONE;
      ST_DONE: state_d = ST_IDLE;
      default: state_d = ST_IDLE;
    endcase
    if (acc_mode_q && state_d == ST_MAC && state_q != ST_MAC && state_q != ST_LC)
      state_d = lc_mul_ready_q ? ST_LC : state_q;
  end
  always_comb begin : job_error
    err_d = err_q;
    if (state_q == ST_IDLE && start_i) err_d = 1'b0;
    if (state_q == ST_CHK && bad_job) err_d = 1'b1;
    if ((store_b_fire && axi_resp_s.b.resp[1]) ||
        (lc_r_fire && axi_resp_s.r.resp[1])) err_d = 1'b1;
  end

  always_comb begin : issue_and_accumulate
    for (int unsigned g = 0; g < OutCols; g++) begin
      acc_d[g] = acc_q[g];
      sum_d[g] = '0;
      sum_cv_d[g] = 1'b0;
    end
    sum_v_d = 1'b0; sum_first_d = 1'b0; sum_last_d = 1'b0;
    sum_i_d = '0; sum_j_d = '0;
    dot_start = 1'b0; dot_first_issue = 1'b0; dot_last_issue = 1'b0;
    dot_i_issue = '0; dot_j_issue = '0;
    if (state_q == ST_MAC) begin
      for (int unsigned g = 0; g < OutCols; g++)
        if (sum_v_q && sum_cv_q[g]) acc_d[g] = mac_acc_next[g];
      if (i_q < m_q) begin
        dot_start = dot_pipe_en;
        dot_first_issue = t_q == 0;
        dot_last_issue = t_q + mac_step >= k_q;
        dot_i_issue = i_q; dot_j_issue = j_q;
        if (!(DotPipeFloat && pe_float_en)) begin
          for (int unsigned g = 0; g < OutCols; g++) begin
            sum_d[g] = pe_sum[g]; sum_cv_d[g] = col_v[g];
          end
          sum_v_d = 1'b1; sum_first_d = t_q == 0;
          sum_last_d = t_q + mac_step >= k_q;
          sum_i_d = i_q; sum_j_d = j_q;
        end
      end
    end else if (state_d == ST_MAC) begin
      for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
    end
  end
  always_comb begin : write_result_banks
    c_w_req = 1'b0; c_w_bank = '0; c_w_addr = '0; c_w_data = '0;
    for (int unsigned g = 0; g < OutCols; g++) begin
      c_wx_req[g] = 1'b0; c_wx_bank[g] = '0;
      c_wx_addr[g] = '0; c_wx_data[g] = '0;
    end
    if (state_q == ST_MAC && sum_v_q && sum_last_q) begin
      for (int unsigned g = 0; g < OutCols; g++) begin
        if (sum_cv_q[g]) begin
          if (g == 0) begin
            c_w_req = 1'b1; c_w_bank = c_bank(sum_j_q);
            c_w_addr = c_bank_addr(sum_i_q, sum_j_q); c_w_data = mac_acc_next[0];
          end else begin
            c_wx_req[g] = 1'b1; c_wx_bank[g] = c_bank(sum_j_q + 32'(g));
            c_wx_addr[g] = c_bank_addr(sum_i_q, sum_j_q + 32'(g));
            c_wx_data[g] = mac_acc_next[g];
          end
        end
      end
    end else if (lc_w_fire) begin
      c_w_req = 1'b1; c_w_bank = c_bank(lc_j_q);
      c_w_addr = c_bank_addr(lc_i_q, lc_j_q);
      c_w_data = lc_buf_q[32 * lc_word_q +: 32];
    end
  end
`else
  always_comb begin
    // Reference control for ablation; not part of the default r16 implementation.
    // defaults: idle banks + AXI
    for (int unsigned p = 0; p < PeLanes; p++) begin
      a_w_req[p]  = 1'b0;
      a_w_addr[p] = '0;
      a_w_data[p] = '0;
      for (int unsigned g = 0; g < OutCols; g++) begin
        b_w_req[g][p]  = 1'b0;
        b_w_addr[g][p] = '0;
        b_w_data[g][p] = '0;
      end
    end
    c_w_req  = 1'b0;
    c_w_bank = '0;
    c_w_addr = '0;
    c_w_data = '0;
    for (int unsigned g = 0; g < OutCols; g++) begin
      c_wx_req[g]  = 1'b0;
      c_wx_bank[g] = '0;
      c_wx_addr[g] = '0;
      c_wx_data[g] = '0;
    end

    axi_req_d = '0;
    axi_req_d.b_ready  = 1'b0;
    axi_req_d.r_ready  = 1'b0;
    axi_req_d.ar_valid = 1'b0;
    axi_req_d.aw_valid = 1'b0;
    axi_req_d.w_valid  = 1'b0;
    axi_req_d.ar.id    = IdWidth'(2);
    axi_req_d.ar.len   = '0;
    axi_req_d.ar.size  = axi_pkg::size_t'($clog2(DataWidth / 8));
    axi_req_d.ar.burst = axi_pkg::BURST_INCR;
    axi_req_d.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    axi_req_d.aw.id    = IdWidth'(2);
    axi_req_d.aw.len   = '0;
    axi_req_d.aw.size  = axi_pkg::size_t'(2);  // default 4B; pair path uses 8B
    axi_req_d.aw.burst = axi_pkg::BURST_INCR;
    axi_req_d.aw.cache = '0;
    axi_req_d.w.last   = 1'b1;
    axi_req_d.w.strb   = '0;

    state_d     = state_q;
    for (int unsigned g = 0; g < OutCols; g++) begin
      acc_d[g]    = acc_q[g];
      sum_d[g]    = '0;
      sum_cv_d[g] = 1'b0;
    end
    // F0b-2: pipeline defaults (and empty-pipe on state entry).
    sum_v_d     = 1'b0;
    sum_first_d = 1'b0;
    sum_last_d  = 1'b0;
    sum_i_d     = '0;
    sum_j_d     = '0;
    // Dot-product issue metadata defaults (used only when DotPipeFloat is set).
    dot_start       = 1'b0;
    dot_first_issue = 1'b0;
    dot_last_issue  = 1'b0;
    dot_i_issue     = '0;
    dot_j_issue     = '0;
    // acc_d keeps the current accumulator unless a drain overrides it.
    err_d       = err_q;
    ar_inflight_d = ar_inflight_q;
    aw_sent_d   = aw_sent_q;
    w_sent_d    = w_sent_q;
    ar_i_en     = 1'b0;
    ar_t_en     = 1'b0;
    ar_j_en     = 1'b0;
    ar_i_d      = ar_i_q;
    ar_t_d      = ar_t_q;
    ar_j_d      = ar_j_q;

    ar_lane_push    = '0;
    ar_lane_push_en = 1'b0;
    ar_lane_pop_en  = 1'b0;
    ar_slot_we         = 1'b0;
    ar_slot_widx       = '0;
    ar_slot_push_row   = '0;
    ar_slot_push_col   = '0;
    ar_slot_r_en       = 1'b0;
    ar_slot_r_last     = 1'b0;
    ar_slot_ridx       = '0;
    ar_slot_ntake      = '0;
    la_n_d          = 8'd0;
    lb_n_d          = 8'd0;
    burst_first_d   = burst_first_q;
    c_pair_hold_d   = c_pair_hold_q;
    c_lo_we_d       = 1'b0;
    stc_w_left_d    = stc_w_left_q;
    stc_elem_d      = stc_elem_q;
    // Default is the FULL open-AW element count: one B response retires the
    // whole multi-beat burst, so the cursor advance must match what the AW
    // covered rather than a single element.
    stc_n_d         = stc_elem_q;  // default: retire full open AW on B
    stc_i_en        = 1'b0;
    stc_j_en        = 1'b0;
    stc_i_d         = stc_i_q;
    stc_j_d         = stc_j_q;
    lc_ar_fire      = 1'b0;
    lc_r_fire       = 1'b0;
    lc_w_fire       = 1'b0;
    lc_ar_beats     = 8'd0;

    unique case (state_q)
      ST_IDLE: begin
        ar_inflight_d = '0;
        aw_sent_d     = 1'b0;
        w_sent_d      = 1'b0;
        burst_first_d = 1'b0;
        c_pair_hold_d = 1'b0;
        stc_w_left_d  = 8'd0;
        stc_elem_d    = 8'd0;
        if (start_i) begin
          err_d   = 1'b0;
          state_d = ST_CHK;
        end
      end

      ST_CHK: begin
        // AI-X9: B is k-major, so ldb must hold a row of k elements (was n).
        // A/B must be aligned to the element. Even n stores 8-byte C pairs;
        // odd n stores 4-byte C words.
        if (m_q == 0 || n_q == 0 || k_q == 0
            || m_q > LimM || n_q > LimN || !cap_ok_c
            || ai_fmt_bytes() > MaxElementBytes
            || lda_q < k_q[15:0] || ldb_q < k_q[15:0]
            || !g6lc_ai_island_cfg_pkg::ai_elem_aligned(pa_q, numfmt_q)
            || !g6lc_ai_island_cfg_pkg::ai_elem_aligned(pb_q, numfmt_q)
            || !g6lc_ai_island_cfg_pkg::ai_c_aligned(pc_q, n_q[0])) begin
          err_d   = 1'b1;
          state_d = ST_DONE;
        end else begin
          ar_inflight_d = '0;
          burst_first_d = 1'b0;
          ar_i_en = 1'b1; ar_i_d = '0;
          ar_t_en = 1'b1; ar_t_d = '0;
          ar_j_en = 1'b1; ar_j_d = '0;
          state_d       = ST_LA;
          // A resident: skip its load.  If B is resident too there is nothing
          // left to fetch, so go straight to the MAC with a cleared
          // accumulator, which is what ST_LB's exit would otherwise do.
          if (ReuseAEn && reuse_a_skip_q && reuse_a_safe && !reuse_a_invalidate_i) begin
            if (ReuseBEn && reuse_b_skip_q && reuse_b_safe && !reuse_b_invalidate_i) begin
              state_d = ST_MAC;
              for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
            end else
              state_d = ST_LB;
          end
        end
      end

      // Load A: multi-beat INCR + multi-outstanding AR (issue runs ahead of R)
      ST_LA: begin
        begin
          automatic logic       ar_push, r_fire, r_match;
          automatic logic [7:0] nb;
          automatic logic [31:0] elems;
          automatic logic [ARSlotW-1:0] free_s, match_s;
          ar_push = 1'b0;
          r_fire  = 1'b0;
          r_match = 1'b0;
          free_s  = '0;
          match_s = '0;
          if (SplitArId) begin
            automatic logic found_free;
            found_free = 1'b0;
            for (int unsigned s = 0; s < MaxAROut; s++) begin
              if (!ar_slot_q[s].valid && !found_free) begin
                found_free = 1'b1;
                free_s = ARSlotW'(s);
              end
              if (ar_slot_q[s].valid &&
                  axi_resp_s.r.id == (ArIdBase + IdWidth'(s))) begin
                r_match = 1'b1;
                match_s = ARSlotW'(s);
              end
            end
          end
          // ---- Issue AR (may run concurrent with R) ----
          if (ar_hold_q) free_s = ar_hold_slot_q;
          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_i_q < m_q) begin
            axi_req_d.ar.addr  = ar_a_pre_addr;
            nb                 = ar_a_pre_nb;
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            if (SplitArId)
              axi_req_d.ar.id = ArIdBase + IdWidth'(free_s);
            axi_req_d.ar_valid = 1'b1;
            if (axi_resp_s.ar_ready) begin
              ar_push         = 1'b1;
              ar_lane_push_en = 1'b1;
              ar_lane_push    = ar_a_pre_lane;
              ar_slot_we       = SplitArId;
              ar_slot_widx     = free_s;
              ar_slot_push_row = ar_i_q;
              ar_slot_push_col = ar_t_q;
              elems = ar_a_pre_elems;
              if (ar_a_pre_row_last) begin
                ar_t_en = 1'b1; ar_t_d = '0;
                ar_i_en = 1'b1; ar_i_d = ar_i_q + 32'd1;
              end else begin
                ar_t_en = 1'b1; ar_t_d = ar_t_q + elems;
              end
            end
          end
          // ---- Receive R ----
          axi_req_d.r_ready = (ar_inflight_q != '0) &&
                              (!SplitArId || !axi_resp_s.r_valid || r_match);
          if (ar_inflight_q != '0 && axi_resp_s.r_valid &&
              (!SplitArId || r_match)) begin
            automatic logic [BeatLaneW-1:0] lane0;
            automatic logic [31:0] n_take, rem_k, rem_beat, recv_i, recv_t;
            automatic logic recv_first;
            r_fire   = 1'b1;
            recv_i   = SplitArId ? ar_slot_q[match_s].row : i_q;
            recv_t   = SplitArId ? ar_slot_q[match_s].col : t_q;
            recv_first = SplitArId ? ar_slot_q[match_s].first : burst_first_q;
            lane0    = recv_first
                     ? (SplitArId ? ar_slot_q[match_s].lane0 : ar_head_lane)
                     : BeatLaneW'(0);
            rem_k    = k_bytes - recv_t;
            rem_beat = 32'(BytesPerBeat) - 32'(lane0);
            n_take   = rem_k;
            if (n_take > rem_beat) n_take = rem_beat;
            if (n_take > PeLanes)  n_take = PeLanes;
            la_n_d = n_take[7:0];
            ar_slot_r_en   = SplitArId;
            ar_slot_ridx   = match_s;
            ar_slot_r_last = axi_resp_s.r.last;
            ar_slot_ntake  = n_take;
            for (int unsigned p = 0; p < PeLanes; p++) begin
              if (32'(p) < n_take) begin
                automatic logic [31:0] tt;
                tt = recv_t + 32'(p);
                a_w_req [t_bank(tt)] = 1'b1;
                a_w_addr[t_bank(tt)] = a_bank_addr(recv_i, tt);
                a_w_data[t_bank(tt)] = byte_from_beat(
                    axi_resp_s.r.data, BeatLaneW'(unsigned'(lane0) + p));
              end
            end
            if (axi_resp_s.r.last)
              ar_lane_pop_en = 1'b1;
            if (!SplitArId && (t_q + n_take >= k_bytes) && (i_q + 1 == m_q)) begin
              ar_t_en = 1'b1; ar_t_d = '0;
              ar_j_en = 1'b1; ar_j_d = '0;
              ar_i_en = 1'b1; ar_i_d = '0;
              state_d = ST_LB;
            end else
              state_d = ST_LA;
          end
          // Net inflight + burst_first (handles AR+R same cycle)
          unique case ({ar_push, r_fire && axi_resp_s.r.last})
            2'b10: begin
              ar_inflight_d = ar_inflight_q + AROutW'(1);
              if (ar_inflight_q == '0) burst_first_d = 1'b1;
            end
            2'b01: begin
              ar_inflight_d = ar_inflight_q - AROutW'(1);
              burst_first_d = (ar_inflight_q > AROutW'(1));
            end
            2'b11: begin
              ar_inflight_d = ar_inflight_q;  // pop+push
              burst_first_d = 1'b1;           // new head (pushed or shifted)
            end
            default: ;
          endcase
          if (r_fire && !axi_resp_s.r.last)
            burst_first_d = 1'b0;
          if (SplitArId) begin
            if ((ar_i_en ? ar_i_d : ar_i_q) >= m_q && ar_inflight_d == '0)
              state_d = ST_LB;
          end else if (state_d == ST_LB)
            ar_inflight_d = '0;
          if (state_d == ST_LB && ReuseBEn && reuse_b_skip_q && reuse_b_safe &&
              !reuse_b_invalidate_i && !err_q &&
              !(axi_resp_s.r_valid && axi_req_d.r_ready && axi_resp_s.r.resp[1])) begin
            state_d = ST_MAC;
            for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
            ar_inflight_d = '0;
            ar_i_en = 1'b1; ar_i_d = '0;
            ar_j_en = 1'b1; ar_j_d = '0;
            ar_t_en = 1'b1; ar_t_d = '0;
          end
        end
      end

      // Load B: k-major (AI-X9), so this is ST_LA with the row index swapped --
      // the burst runs along t (contiguous) and the row cursor is j.
      //
      // The oct-drain that used to live here is DELETED. When B was row-major
      // the burst ran along j, so one 64-bit beat landed in ONE bank at up to 8
      // different local addresses; that is the only reason the B tile needed
      // NumPorts(8) and the only reason a held-beat path
      // (beat_q/beat_lane_q/beat_left_q) existed. Under k-major a beat spreads
      // across PeLanes DIFFERENT banks at one address each -- exactly what A
      // already sustains with a single write port -- so the 8 ports and the
      // whole leftover path were buying nothing. Byte traffic is unchanged:
      // k bursts of row_bytes(n) becomes n bursts of row_bytes(k).
      ST_LB: begin
        begin
          automatic logic       ar_push, r_fire, r_match;
          automatic logic [7:0] nb;
          automatic logic [31:0] elems;
          automatic logic [ARSlotW-1:0] free_s, match_s;
          ar_push = 1'b0;
          r_fire  = 1'b0;
          r_match = 1'b0;
          free_s  = '0;
          match_s = '0;
          if (SplitArId) begin
            automatic logic found_free;
            found_free = 1'b0;
            for (int unsigned s = 0; s < MaxAROut; s++) begin
              if (!ar_slot_q[s].valid && !found_free) begin
                found_free = 1'b1;
                free_s = ARSlotW'(s);
              end
              if (ar_slot_q[s].valid &&
                  axi_resp_s.r.id == (ArIdBase + IdWidth'(s))) begin
                r_match = 1'b1;
                match_s = ARSlotW'(s);
              end
            end
          end
          // ---- Issue AR (may run concurrent with R) ----
          if (ar_hold_q) free_s = ar_hold_slot_q;
          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_j_q < n_q) begin
            axi_req_d.ar.addr  = ar_b_pre_addr;
            nb                 = ar_b_pre_nb;
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            if (SplitArId)
              axi_req_d.ar.id = ArIdBase + IdWidth'(free_s);
            axi_req_d.ar_valid = 1'b1;
            if (axi_resp_s.ar_ready) begin
              ar_push         = 1'b1;
              ar_lane_push_en = 1'b1;
              ar_lane_push    = ar_b_pre_lane;
              ar_slot_we       = SplitArId;
              ar_slot_widx     = free_s;
              ar_slot_push_row = ar_j_q;
              ar_slot_push_col = ar_t_q;
              elems = ar_b_pre_elems;
              if (ar_b_pre_row_last) begin
                ar_t_en = 1'b1; ar_t_d = '0;
                ar_j_en = 1'b1; ar_j_d = ar_j_q + 32'd1;
              end else begin
                ar_t_en = 1'b1; ar_t_d = ar_t_q + elems;
              end
            end
          end
          // ---- Receive R ----
          axi_req_d.r_ready = (ar_inflight_q != '0) &&
                              (!SplitArId || !axi_resp_s.r_valid || r_match);
          if (ar_inflight_q != '0 && axi_resp_s.r_valid &&
              (!SplitArId || r_match)) begin
            automatic logic [BeatLaneW-1:0] lane0;
            automatic logic [31:0] n_take, rem_k, rem_beat, recv_j, recv_t;
            automatic logic recv_first;
            r_fire   = 1'b1;
            recv_j   = SplitArId ? ar_slot_q[match_s].row : j_q;
            recv_t   = SplitArId ? ar_slot_q[match_s].col : t_q;
            recv_first = SplitArId ? ar_slot_q[match_s].first : burst_first_q;
            lane0    = recv_first
                     ? (SplitArId ? ar_slot_q[match_s].lane0 : ar_head_lane)
                     : BeatLaneW'(0);
            rem_k    = k_bytes - recv_t;
            rem_beat = 32'(BytesPerBeat) - 32'(lane0);
            n_take   = rem_k;
            if (n_take > rem_beat) n_take = rem_beat;
            if (n_take > PeLanes)  n_take = PeLanes;
            lb_n_d = n_take[7:0];
            ar_slot_r_en   = SplitArId;
            ar_slot_ridx   = match_s;
            ar_slot_r_last = axi_resp_s.r.last;
            ar_slot_ntake  = n_take;
            for (int unsigned p = 0; p < PeLanes; p++) begin
              if (32'(p) < n_take) begin
                automatic logic [31:0] tt;
                tt = recv_t + 32'(p);
                for (int unsigned gg = 0; gg < OutCols; gg++)
                  if (col_grp(recv_j) == ColW'(gg)) begin
                    b_w_req [gg][t_bank(tt)] = 1'b1;
                    b_w_addr[gg][t_bank(tt)] = b_bank_addr(tt, recv_j);
                    b_w_data[gg][t_bank(tt)] = byte_from_beat(
                        axi_resp_s.r.data, BeatLaneW'(unsigned'(lane0) + p));
                  end
              end
            end
            if (axi_resp_s.r.last)
              ar_lane_pop_en = 1'b1;
            if (!SplitArId && (t_q + n_take >= k_bytes) && (j_q + 1 == n_q)) begin
              state_d = ST_MAC;
              for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
            end else
              state_d = ST_LB;
          end
          // Net inflight + burst_first (handles AR+R same cycle)
          unique case ({ar_push, r_fire && axi_resp_s.r.last})
            2'b10: begin
              ar_inflight_d = ar_inflight_q + AROutW'(1);
              if (ar_inflight_q == '0) burst_first_d = 1'b1;
            end
            2'b01: begin
              ar_inflight_d = ar_inflight_q - AROutW'(1);
              burst_first_d = (ar_inflight_q > AROutW'(1));
            end
            2'b11: begin
              ar_inflight_d = ar_inflight_q;  // pop+push
              burst_first_d = 1'b1;           // new head (pushed or shifted)
            end
            default: ;
          endcase
          if (r_fire && !axi_resp_s.r.last)
            burst_first_d = 1'b0;
          if (SplitArId) begin
            if ((ar_j_en ? ar_j_d : ar_j_q) >= n_q && ar_inflight_d == '0) begin
              state_d = ST_MAC;
              for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
            end
          end else if (state_d == ST_MAC)
            ar_inflight_d = '0;
        end
      end

      // Parallel MAC: lanes cover t_q .. t_q+PeLanes-1
      // Trail-store: when DualCRead and stc_i < i_q, stream completed rows on
      // free AXI (MAC does not use AXI). i_q==m means MAC finished all rows.
      //
      // F0b-2: the PE is one stage ahead of the accumulator. In each cycle:
      //   * issue operands from (i_q,j_q,t_q) and capture pe_sum as sum_d;
      //   * drain the previous cycle's sum_q into acc_q and, if it was the
      //     last step of (sum_i_q,sum_j_q), write the tile C at that address.
      //   * index (i,j,t) advance at issue rate.
      //
      // Throughput is preserved: operands issue every cycle. Only the C write
      // and accumulator update are delayed by one cycle. The drain uses the
      // captured (sum_i_q,sum_j_q) because (i_q,j_q) have already advanced.
      ST_MAC: begin
        begin
          automatic logic mac_active;
          automatic logic can_trail;
          automatic logic        can_pair;
          automatic logic [31:0] pairs_rem, nbeats, beats_done, j_eff;
          automatic logic [31:0] t_next;
          automatic logic        last_step;
          mac_active = (i_q < m_q);
          t_next     = t_q + mac_step;
          last_step  = (t_next >= k_q);
          // Trail-store only when no float dot is in flight: a pending result
          // still has to write its C bank, and that write must not race an AXI
          // read of the same bank from the store side.
          can_trail  = DualCRead && (DataWidth >= 64) && !acc_mode_q &&
                       (dot_pending_q == '0) && trail_ready;

          // ---- drain the previous issue -----------------------------------
          // The previous cycle's sum is now stable; add it to the accumulator
          // and write the tile if that issue completed an element.
          //
          // This is intentionally OUTSIDE the `mac_active` guard, so the last
          // in-flight sum drains even when the issue cursor has already
          // reached i_q == m and no new operands are being fed.
          if (sum_v_q) begin
            for (int unsigned g = 0; g < OutCols; g++) begin
              if (sum_cv_q[g]) begin
                acc_d[g] = mac_acc_next[g];
                if (sum_last_q) begin
                  if (g == 0) begin
                    c_w_req  = 1'b1;
                    c_w_bank = c_bank(sum_j_q);
                    c_w_addr = c_bank_addr(sum_i_q, sum_j_q);
                    c_w_data = mac_acc_next[0];
                  end else begin
                    c_wx_req[g]  = 1'b1;
                    c_wx_bank[g] = c_bank(sum_j_q + 32'(g));
                    c_wx_addr[g] = c_bank_addr(sum_i_q, sum_j_q + 32'(g));
                    c_wx_data[g] = mac_acc_next[g];
                  end
                end
              end
            end
          end

          // ---- issue the next step ----------------------------------------
          if (mac_active) begin
            // Tag the pipelined dot product when this is a float tile.
            dot_start      = mac_active && dot_pipe_en;
            dot_first_issue= (t_q == 0);
            dot_last_issue = last_step;
            dot_i_issue    = i_q;
            dot_j_issue    = j_q;

            // Capture what the PE produced this cycle. (i,j,t) are the issue
            // coordinates; they advance in the index logic below.
            if (DotPipeFloat && pe_float_en) begin
              // Dot output is captured directly in the main always_ff below;
              // these always_comb values are not used for the pipelined path.
              for (int unsigned g = 0; g < OutCols; g++) sum_d[g] = '0;
              sum_v_d    = 1'b0;
              sum_first_d= 1'b0;
              sum_last_d = 1'b0;
              sum_i_d    = '0;
              sum_j_d    = '0;
            end else begin
              for (int unsigned g = 0; g < OutCols; g++) begin
                sum_d[g]    = pe_sum[g];
                sum_cv_d[g] = col_v[g];
              end
              sum_v_d    = 1'b1;
              sum_first_d= (t_q == 0);
              sum_last_d = last_step;
              sum_i_d    = i_q;
              sum_j_d    = j_q;
            end
          end

          // Trail C-store (same pair path as ST_STC, cursor stc_i/stc_j)
          if (can_trail) begin
            // AI-X8: pair on EVEN n only, decided per ROW rather than per
            // position, so a row never transitions pair -> single midway.
            //
            // The old predicate was `!stc_j_q[0] && (stc_j_q + 1 < n_q)`, which
            // for odd n stores ceil(n/2)-1 pairs and then one single, i.e. TWO
            // AW transactions for one row. That transition is the AI-X8 defect:
            // m=2/n=3 returned a wrong C[0][2] with ST_OK and a correct ticket.
            // Bisected on one unchanged netlist:
            //   n=1     (single path only)          PASS
            //   n=4/n=6 (pair path only)            PASS
            //   m=1 n=3 (transition, no trailing)   PASS
            //   m=2 n=3 (transition, trailing)      FAIL
            // So neither path is wrong alone, and ST_STC's identical transition
            // is fine; only the trail store racing an active MAC breaks. The
            // race itself is NOT root-caused -- this removes the construct
            // rather than explaining it, which is why the fixtures stay.
            //
            // Cost: an odd-n C row now takes n beats instead of ceil(n/2).
            // C store is overlapped with MAC and is not the bottleneck, and odd
            // n is the rare shape, so this is the cheap side of the trade.
            can_pair = !n_q[0];
            if (can_pair) begin
              if (!aw_sent_q) begin
                pairs_rem = (n_q - stc_j_q) >> wsh_q;
                nbeats    = pairs_rem;
                // Inside the row still being computed only the beats whose C words
                // are already written may be burst; the AW length is fixed at issue.
                if (!(stc_i_q < 32'(c_rows_done_q)) && nbeats > ((c_cols_done_q - stc_j_q) >> wsh_q))
                  nbeats = (c_cols_done_q - stc_j_q) >> wsh_q;
                if (nbeats > MaxBurstBeats) nbeats = MaxBurstBeats;
                nbeats    = wide_c_q ? cap_nbeats_to_stripe(c_store_addr, nbeats)
                                     : cap_c_nbeats(c_store_addr, nbeats);
                if (nbeats == 0) nbeats = 1;
                axi_req_d.aw.addr  = c_store_addr;
                axi_req_d.aw.len   = axi_pkg::len_t'(nbeats - 32'd1);
                axi_req_d.aw.size  = axi_pkg::size_t'(32'd2 + 32'(wsh_q));
                axi_req_d.aw_valid = 1'b1;
                if (axi_resp_s.aw_ready) begin
                  aw_sent_d     = 1'b1;
                  stc_w_left_d  = nbeats[8:0];
                  stc_elem_d    = nbeats[15:0] << wsh_q;
                  w_sent_d      = 1'b0;
                  c_pair_hold_d = 1'b0;
                end
              end else if (stc_w_left_q != 9'd0) begin
                beats_done = 32'(stc_elem_q >> wsh_q) - 32'(stc_w_left_q);
                j_eff      = stc_j_q + (beats_done << wsh_q);
                begin
                  automatic wbeat_t wb;
                  wb = wbeat_words(32'(c_store_addr) + (beats_done << (32'd2 + 32'(wsh_q))),
                                   wide_c_q ? StoreWordsMax : 2);
                  axi_req_d.w.data = wb.data;
                  axi_req_d.w.strb = wb.strb;
                end
                axi_req_d.w.last  = (stc_w_left_q == 9'd1);
                axi_req_d.w_valid = 1'b1;
                if (axi_resp_s.w_ready) begin
                  stc_w_left_d = stc_w_left_q - 9'd1;
                  if (stc_w_left_q == 9'd1)
                    w_sent_d = 1'b1;
                end
              end else begin
                axi_req_d.b_ready = 1'b1;
                stc_n_d = stc_elem_q;
                if (axi_resp_s.b_valid) begin
                  if (axi_resp_s.b.resp inside {axi_pkg::RESP_DECERR,
                                                axi_pkg::RESP_SLVERR})
                    err_d = 1'b1;
                  aw_sent_d     = 1'b0;
                  w_sent_d      = 1'b0;
                  c_pair_hold_d = 1'b0;
                  stc_elem_d    = '0;
                  // advance store cursor
                  if (stc_j_q + 32'(stc_elem_q) >= n_q) begin
                    stc_j_en = 1'b1;
                    stc_j_d  = '0;
                    stc_i_en = 1'b1;
                    stc_i_d  = stc_i_q + 32'd1;
                  end else begin
                    stc_j_en = 1'b1;
                    stc_j_d  = stc_j_q + 32'(stc_elem_q);
                  end
                end
              end
            end else begin
              // Single i32 (odd n tail)
              axi_req_d.aw.addr = c_store_addr;
              axi_req_d.aw.size = axi_pkg::size_t'(2);
              begin
                automatic wbeat_t wb;
                wb = wbeat_at(64'(c_r0_data), 4, 32'(c_store_addr));
                axi_req_d.w.data = wb.data;
                axi_req_d.w.strb = wb.strb;
              end
              stc_n_d = 16'd1;
              if (!aw_sent_q) begin
                axi_req_d.aw_valid = 1'b1;
                if (axi_resp_s.aw_ready) begin
                  aw_sent_d  = 1'b1;
                  stc_elem_d = 16'd1;
                end
              end
              if (!w_sent_q) begin
                axi_req_d.w_valid = 1'b1;
                if (axi_resp_s.w_ready) w_sent_d = 1'b1;
              end
              axi_req_d.b_ready = 1'b1;
              if (aw_sent_q && w_sent_q && axi_resp_s.b_valid) begin
                if (axi_resp_s.b.resp inside {axi_pkg::RESP_DECERR,
                                              axi_pkg::RESP_SLVERR})
                  err_d = 1'b1;
                aw_sent_d     = 1'b0;
                w_sent_d      = 1'b0;
                c_pair_hold_d = 1'b0;
                stc_elem_d    = '0;
                if (stc_j_q + 1 >= n_q) begin
                  stc_j_en = 1'b1;
                  stc_j_d  = '0;
                  stc_i_en = 1'b1;
                  stc_i_d  = stc_i_q + 32'd1;
                end else begin
                  stc_j_en = 1'b1;
                  stc_j_d  = stc_j_q + 32'd1;
                end
              end
            end
          end

          // Exit: MAC done (i>=m) and store done (stc_i>=m). The pipeline
          // must be empty before leaving: a valid in-flight sum has its C
          // write one cycle later and cannot be cancelled.
          if (i_q >= m_q && stc_i_q >= m_q && !aw_sent_q && !sum_v_q &&
              dot_pending_q == '0)
            state_d = ST_DONE;
          else if (i_q >= m_q && stc_i_q >= m_q && aw_sent_q &&
                   dot_pending_q == '0)
            state_d = ST_MAC;  // finish open AW/B
          else if ((!DualCRead || acc_mode_q) && i_q >= m_q && dot_pending_q == '0) begin
            // PeLanes==1 (or accumulate mode, whose seed reads own port r0 during
            // the MAC): fall back to dedicated ST_STC
            state_d       = ST_STC;
            aw_sent_d     = 1'b0;
            w_sent_d      = 1'b0;
            c_pair_hold_d = 1'b0;
            stc_w_left_d  = '0;
            stc_elem_d    = '0;
          end else
            state_d = ST_MAC;
        end
      end

      // Accumulate: stream the existing C tile (contiguous, ldc = n) into the C
      // banks. One outstanding burst; each received beat is drained one 32-bit
      // word per cycle through the single C write port (R is held meanwhile).
      ST_LC: begin
        begin
          automatic logic [AddrWidth-1:0] lc_addr;
          automatic logic [31:0] beats_left;
          automatic logic [7:0]  nb;
          lc_addr    = beat_align(pc_q) + AddrWidth'(lc_issued_q) * AddrWidth'(BytesPerBeat);
          beats_left = lc_beats_q - lc_issued_q;
          nb         = (beats_left > MaxBurstBeats) ? 8'(MaxBurstBeats) : beats_left[7:0];
          nb         = cap_beats_to_stripe(lc_addr, nb);
          if (!lc_ar_busy_q && lc_issued_q < lc_beats_q) begin
            axi_req_d.ar.addr  = lc_addr;
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            axi_req_d.ar_valid = 1'b1;
            lc_ar_beats        = nb;
            if (axi_resp_s.ar_ready) lc_ar_fire = 1'b1;
          end
          axi_req_d.r_ready = lc_ar_busy_q && !lc_buf_v_q;
          if (lc_ar_busy_q && !lc_buf_v_q && axi_resp_s.r_valid) begin
            lc_r_fire = 1'b1;
            if (axi_resp_s.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
              err_d = 1'b1;
          end
          if (lc_buf_v_q && lc_e_q < lc_total_q) begin
            c_w_req   = 1'b1;
            c_w_bank  = c_bank(lc_j_q);
            c_w_addr  = c_bank_addr(lc_i_q, lc_j_q);
            c_w_data  = lc_buf_q[32 * lc_word_q +: 32];
            lc_w_fire = 1'b1;
          end
          if (err_q) begin
            if (!lc_ar_busy_q) state_d = ST_DONE;
          end else if (lc_e_q >= lc_total_q && !lc_buf_v_q && !lc_ar_busy_q) begin
            state_d = ST_MAC;
            for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
          end
        end
      end

      ST_STC: begin
        // Fallback single-lane / non-trail path (also used if trail disabled).
        // Multi-beat pair path (≥64-bit) on stc_i/stc_j cursor.
        begin
          automatic logic        can_pair;
          automatic logic [31:0] pairs_rem, nbeats, beats_done, j_eff;
          // AI-X8: even n only, per row -- see the trail-store copy in ST_MAC.
          // Kept identical to the trail predicate so the two store sites cannot
          // disagree about how a row is chunked.
          can_pair = (DataWidth >= 64) && !n_q[0];

          if (can_pair) begin
            if (!aw_sent_q) begin
              pairs_rem = (n_q - stc_j_q) >> wsh_q;
              nbeats    = pairs_rem;
              if (nbeats > MaxBurstBeats) nbeats = MaxBurstBeats;
              nbeats    = wide_c_q ? cap_nbeats_to_stripe(c_store_addr, nbeats)
                                   : cap_c_nbeats(c_store_addr, nbeats);
              if (nbeats == 0) nbeats = 1;
              axi_req_d.aw.addr  = c_store_addr;
              axi_req_d.aw.len   = axi_pkg::len_t'(nbeats - 32'd1);
              axi_req_d.aw.size  = axi_pkg::size_t'(32'd2 + 32'(wsh_q));
              axi_req_d.aw_valid = 1'b1;
              if (axi_resp_s.aw_ready) begin
                aw_sent_d     = 1'b1;
                stc_w_left_d  = nbeats[8:0];
                stc_elem_d    = nbeats[15:0] << wsh_q;
                w_sent_d      = 1'b0;
                c_pair_hold_d = 1'b0;
              end
            end else if (stc_w_left_q != 9'd0) begin
              beats_done = 32'(stc_elem_q >> wsh_q) - 32'(stc_w_left_q);
              j_eff      = stc_j_q + (beats_done << wsh_q);
              if (DualCRead) begin
                begin
                  automatic wbeat_t wb;
                  wb = wbeat_words(32'(c_store_addr) + (beats_done << (32'd2 + 32'(wsh_q))),
                                   wide_c_q ? StoreWordsMax : 2);
                  axi_req_d.w.data = wb.data;
                  axi_req_d.w.strb = wb.strb;
                end
                axi_req_d.w.last  = (stc_w_left_q == 9'd1);
                axi_req_d.w_valid = 1'b1;
                if (axi_resp_s.w_ready) begin
                  stc_w_left_d = stc_w_left_q - 9'd1;
                  if (stc_w_left_q == 9'd1)
                    w_sent_d = 1'b1;
                end
              end else if (!c_pair_hold_q) begin
                c_lo_we_d     = 1'b1;
                c_pair_hold_d = 1'b1;
              end else begin
                begin
                  automatic wbeat_t wb;
                  wb = wbeat_at({c_r0_data, c_lo_q}, 8,
                                32'(c_store_addr) + (beats_done << 3));
                  axi_req_d.w.data = wb.data;
                  axi_req_d.w.strb = wb.strb;
                end
                axi_req_d.w.last  = (stc_w_left_q == 9'd1);
                axi_req_d.w_valid = 1'b1;
                if (axi_resp_s.w_ready) begin
                  stc_w_left_d  = stc_w_left_q - 9'd1;
                  c_pair_hold_d = 1'b0;
                  if (stc_w_left_q == 9'd1)
                    w_sent_d = 1'b1;
                end
              end
            end else begin
              axi_req_d.b_ready = 1'b1;
              stc_n_d = stc_elem_q;
              if (axi_resp_s.b_valid) begin
                if (axi_resp_s.b.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
                  err_d = 1'b1;
                aw_sent_d     = 1'b0;
                w_sent_d      = 1'b0;
                c_pair_hold_d = 1'b0;
                stc_elem_d    = '0;
                if (stc_j_q + 32'(stc_elem_q) >= n_q) begin
                  stc_j_en = 1'b1;
                  stc_j_d  = '0;
                  stc_i_en = 1'b1;
                  stc_i_d  = stc_i_q + 32'd1;
                  if (stc_i_q + 1 >= m_q)
                    state_d = ST_DONE;
                  else
                    state_d = ST_STC;
                end else begin
                  stc_j_en = 1'b1;
                  stc_j_d  = stc_j_q + 32'(stc_elem_q);
                  state_d  = ST_STC;
                end
              end
            end
          end else begin
            axi_req_d.aw.addr = c_store_addr;
            axi_req_d.aw.size = axi_pkg::size_t'(2);
            begin
              automatic wbeat_t wb;
              wb = wbeat_at(64'(c_r0_data), 4, 32'(c_store_addr));
              axi_req_d.w.data = wb.data;
              axi_req_d.w.strb = wb.strb;
            end
            stc_n_d = 16'd1;
            if (!aw_sent_q) begin
              axi_req_d.aw_valid = 1'b1;
              if (axi_resp_s.aw_ready) begin
                aw_sent_d  = 1'b1;
                stc_elem_d = 16'd1;
              end
            end
            if (!w_sent_q) begin
              axi_req_d.w_valid = 1'b1;
              if (axi_resp_s.w_ready) w_sent_d = 1'b1;
            end
            axi_req_d.b_ready = 1'b1;
            if (aw_sent_q && w_sent_q && axi_resp_s.b_valid) begin
              if (axi_resp_s.b.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
                err_d = 1'b1;
              aw_sent_d     = 1'b0;
              w_sent_d      = 1'b0;
              c_pair_hold_d = 1'b0;
              stc_elem_d    = '0;
              if (stc_j_q + 1 >= n_q) begin
                stc_j_en = 1'b1;
                stc_j_d  = '0;
                stc_i_en = 1'b1;
                stc_i_d  = stc_i_q + 32'd1;
                if (stc_i_q + 1 >= m_q)
                  state_d = ST_DONE;
                else
                  state_d = ST_STC;
              end else begin
                stc_j_en = 1'b1;
                stc_j_d  = stc_j_q + 32'd1;
                state_d  = ST_STC;
              end
            end
          end
        end
      end

      ST_DONE: state_d = ST_IDLE;
      default: state_d = ST_IDLE;
    endcase
    // Accumulate mode enters the MAC through ST_LC so the tile holds C first.
    if (acc_mode_q && state_d == ST_MAC && state_q != ST_MAC && state_q != ST_LC)
      state_d = lc_mul_ready_q ? ST_LC : state_q;  // hold until the seed product is ready

  end
`endif

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= ST_IDLE;
      m_q <= '0; n_q <= '0; k_q <= '0;
      lda_q <= '0; ldb_q <= '0; ldc_q <= '0;
      numfmt_q <= '0;
      acc_mode_q <= 1'b0;
      pa_q <= '0; pb_q <= '0; pc_q <= '0;
      i_q <= '0; j_q <= '0; t_q <= '0;
      stride_a_q <= '0; stride_b_q <= '0; stride_b_grp_q <= '0;
      a_row_base_q <= '0; b_row_base_q <= '0;
      a_cur_q <= '0; b_cur_q <= '0;

      for (int unsigned g = 0; g < OutCols; g++) begin acc_q[g] <= '0; sum_q[g] <= '0; sum_cv_q[g] <= 1'b0; end
      pitch_sh_q <= '0;
      err_q <= 1'b0;
      done_q <= 1'b0;
      ar_inflight_q <= '0;
      aw_sent_q <= 1'b0;
      w_sent_q <= 1'b0;
      burst_first_q <= 1'b0;
      ar_i_q <= '0;
      ar_t_q <= '0;
      ar_j_q <= '0;
      // F0b-2: the reduction pipeline is empty at reset.
      sum_v_q    <= 1'b0;
      wide_c_q   <= 1'b0;
      wsh_q      <= StoreShW'(1);
      sum_first_q<= 1'b0;
      sum_last_q <= 1'b0;
      sum_i_q    <= '0;
      sum_j_q    <= '0;
      for (int unsigned k = 0; k < MaxAROut; k++) begin
        ar_lane_mem_q[k] <= '0;
        ar_slot_q[k]     <= '0;
      end
      c_pair_hold_q <= 1'b0;
      c_lo_q <= '0;
      stc_w_left_q <= '0;
      stc_elem_q <= '0;
      stc_i_q <= '0;
      stc_j_q <= '0;
      c_rows_done_q <= '0;
      c_cols_row_q <= '0;
      c_cols_done_q <= '0;
      dot_pending_q <= '0;
      pmu_r_q  <= '0;
      pmu_w_q  <= '0;
      pmu_cy_q <= '0;
    end else begin
      state_q       <= state_d;
      for (int unsigned g = 0; g < OutCols; g++) acc_q[g] <= acc_d[g];
      // F0b-2: advance the pipeline stage. For the pipelined floating path the
      // dot product valid/data are sampled directly from the pipe output; the
      // non-pipelined path continues to use the combinational `sum_*_d` values.
      if (dot_pipe_en) begin
        for (int unsigned g = 0; g < OutCols; g++) begin
          sum_q[g]    <= dot_valid ? dot_sum[g] : '0;
          sum_cv_q[g] <= dot_valid ? dot_cv_out[g] : 1'b0;
        end
        sum_v_q     <= dot_valid;
        sum_first_q <= dot_valid ? dot_first_out : 1'b0;
        sum_last_q  <= dot_valid ? dot_last_out  : 1'b0;
        sum_i_q     <= dot_valid ? dot_i_out     : '0;
        sum_j_q     <= dot_valid ? dot_j_out     : '0;
      end else begin
        for (int unsigned g = 0; g < OutCols; g++) begin
          sum_q[g]    <= sum_d[g];
          sum_cv_q[g] <= sum_cv_d[g];
        end
        sum_v_q     <= sum_v_d;
        sum_first_q <= sum_first_d;
        sum_last_q  <= sum_last_d;
        sum_i_q     <= sum_i_d;
        sum_j_q     <= sum_j_d;
      end
      err_q       <= err_d;
      // The pitch is fixed for the job at ST_CHK; every bank address from ST_LA on
      // uses the registered value (the reuse key compares k, so a resident panel
      // always carries the pitch the new job computes).
      if (state_q == ST_CHK) pitch_sh_q <= pitch_sh_c;
      // Wide C store when every row base is beat-aligned: n a multiple of the
      // words per beat (ldc = n) and ptr_c aligned to the beat. Pairs otherwise.
      if (state_q == ST_CHK) begin
        wide_c_q <= WideCStore && !n_q[0] &&
                    ((n_q & 32'(StoreWordsMax - 1)) == 32'd0) &&
                    ((ldc_eff & 32'(StoreWordsMax - 1)) == 32'd0) &&
                    ((pc_q & AddrWidth'(BytesPerBeat - 1)) == '0);
        wsh_q    <= (WideCStore && !n_q[0] &&
                     ((n_q & 32'(StoreWordsMax - 1)) == 32'd0) &&
                     ((ldc_eff & 32'(StoreWordsMax - 1)) == 32'd0) &&
                     ((pc_q & AddrWidth'(BytesPerBeat - 1)) == '0)) ? StoreShW'(StoreShMax) : StoreShW'(1);
      end
      ar_inflight_q <= ar_inflight_d;
      aw_sent_q     <= aw_sent_d;
      w_sent_q      <= w_sent_d;
      burst_first_q <= burst_first_d;
      if (ar_i_en) ar_i_q <= ar_i_d;
      if (ar_t_en) ar_t_q <= ar_t_d;
      if (ar_j_en) ar_j_q <= ar_j_d;
    end
  end

  // D3: one-cycle-ahead AR candidates -- own always_ff per the rank-0
  // register-group rule (they must not compose with the cursor ff).
  // Sampled with the cursors that produced the payload and the job tag;
  // validity is a comb compare of the sampled context against the live
  // registers, so any cursor-write path is caught.

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
    end else begin


      // Lane FIFO: push on AR accept, pop on r.last (shift-register depth MaxAROut)
      if (ar_lane_push_en && ar_lane_pop_en) begin
        // pop head, push new at tail; depth unchanged (= ar_inflight_q)
        for (int unsigned k = 0; k < MaxAROut - 1; k++)
          ar_lane_mem_q[k] <= ar_lane_mem_q[k + 1];
        // after shift, free slot index is ar_inflight_q-1 (depth stays same)
        if (ar_inflight_q != '0)
          ar_lane_mem_q[ar_inflight_q - AROutW'(1)] <= ar_lane_push;
        else
          ar_lane_mem_q[0] <= ar_lane_push;
      end else if (ar_lane_push_en) begin
        ar_lane_mem_q[ar_inflight_q] <= ar_lane_push;
      end else if (ar_lane_pop_en) begin
        for (int unsigned k = 0; k < MaxAROut - 1; k++)
          ar_lane_mem_q[k] <= ar_lane_mem_q[k + 1];
      end
      if (SplitArId) begin
        if (ar_slot_we) begin
          ar_slot_q[ar_slot_widx].valid <= 1'b1;
          ar_slot_q[ar_slot_widx].first <= 1'b1;
          ar_slot_q[ar_slot_widx].lane0 <= ar_lane_push;
          ar_slot_q[ar_slot_widx].row   <= ar_slot_push_row;
          ar_slot_q[ar_slot_widx].col   <= ar_slot_push_col;
        end
        if (ar_slot_r_en) begin
          if (ar_slot_r_last)
            ar_slot_q[ar_slot_ridx].valid <= 1'b0;
          else begin
            ar_slot_q[ar_slot_ridx].first <= 1'b0;
            // AI-X9/F1: `col` is a BYTE offset along the operand row in BOTH load
            // states now, so both bound against k_bytes. ST_LB used to bound
            // against n_q because row-major B ran along j -- keeping that after
            // the k-major rewrite retired the slot's column at the wrong point
            // and corrupted C whenever a row straddled a beat boundary. It only
            // showed on SplitArId (NrChannels>1) with a row stride that does not
            // divide BytesPerBeat, which no power-of-two fixture produces;
            // ai_gemm_s8_asym_smoke (k=6) on ai-sc2 is the gate.
            if (ar_slot_q[ar_slot_ridx].col + ar_slot_ntake >= k_bytes) begin
              ar_slot_q[ar_slot_ridx].col <= '0;
              ar_slot_q[ar_slot_ridx].row <=
                  ar_slot_q[ar_slot_ridx].row + 32'd1;
            end else
              ar_slot_q[ar_slot_ridx].col <=
                  ar_slot_q[ar_slot_ridx].col + ar_slot_ntake;
          end
        end
      end
      c_pair_hold_q <= c_pair_hold_d;
      stc_w_left_q  <= stc_w_left_d;
      stc_elem_q    <= stc_elem_d;
      // Outstanding pipelined dot transactions. This is the ONLY thing that
      // keeps ST_MAC from exiting while results are still in the FP pipe --
      // i_q reaching m only means issue finished, not that C is written.
      dot_pending_q <= dot_pipe_en
                       ? dot_pending_q
                         + (dot_start ? 1'd1 : 1'd0)
                         - ((dot_valid && dot_pending_q != '0) ? 1'd1 : 1'd0)
                       : '0;
      if (c_lo_we_d)   c_lo_q <= c_r_data;
      // Column 0 of a group always writes when the group completes, and the
      // group's valid columns are consecutive from sum_j_q, so the written count
      // is min(sum_j_q + cols_eff, n) -- except in ST_LC, whose C writes are the
      // seed load and not MAC progress.
      if (state_q == ST_MAC && c_w_req && sum_j_q + cols_eff >= n_q)
        c_rows_done_q <= RowCountW'(sum_i_q) + RowCountW'(1);
      if (state_q == ST_MAC && c_w_req) begin
        c_cols_row_q  <= RowCountW'(sum_i_q);
        c_cols_done_q <= (sum_j_q + cols_eff > n_q) ? n_q : sum_j_q + cols_eff;
      end
      done_q        <= (state_q == ST_DONE);

      // I3: accumulate traffic while job is running
      // W counts data beats (w handshake), not B responses — multi-beat AW safe
      if (state_q != ST_IDLE && state_q != ST_DONE)
        pmu_cy_q <= pmu_cy_q + 32'd1;
      if (state_q != ST_IDLE && state_q != ST_DONE &&
          axi_req_d.r_ready && axi_resp_s.r_valid)
        pmu_r_q <= pmu_r_q + 32'd1;
      // Count W handshakes, not B responses: a multi-beat AW produces one B for
      // many beats, so counting B would understate write traffic in the PMU.
      if (state_q != ST_IDLE && state_q != ST_DONE &&
          axi_req_d.w_valid && axi_resp_s.w_ready)
        pmu_w_q <= pmu_w_q + 32'd1;

      if (state_q == ST_IDLE && start_i) begin
        m_q   <= m_i;
        n_q   <= n_i;
        k_q   <= k_i;
        lda_q <= lda_i;
        ldb_q <= ldb_i;
        ldc_q <= ldc_i;
        numfmt_q <= numfmt_i;
        acc_mode_q <= accumulate_i;
        pa_q  <= ptr_a_i;
        pb_q  <= ptr_b_i;
        pc_q  <= ptr_c_i;
        i_q   <= '0;
        j_q   <= '0;
        t_q   <= '0;
        // Incoming format owns these strides; numfmt_q still names the prior job.
        stride_a_q <= g6lc_ai_island_cfg_pkg::ai_row_bytes(numfmt_i, {16'd0, lda_i});
        stride_b_q <= g6lc_ai_island_cfg_pkg::ai_row_bytes(numfmt_i, {16'd0, ldb_i});
        stride_b_grp_q <= (accumulate_i ? 32'd1 : 32'(OutCols)) *
            g6lc_ai_island_cfg_pkg::ai_row_bytes(numfmt_i, {16'd0, ldb_i});
        a_row_base_q   <= ptr_a_i;
        b_row_base_q   <= ptr_b_i;
        a_cur_q        <= ptr_a_i;
        b_cur_q        <= ptr_b_i;

        burst_first_q <= 1'b0;
        ar_inflight_q <= '0;
        ar_i_q <= '0;
        ar_t_q <= '0;
        ar_j_q <= '0;
        for (int unsigned s = 0; s < MaxAROut; s++)
          ar_slot_q[s] <= '0;
        c_pair_hold_q <= 1'b0;
        stc_w_left_q  <= '0;
        stc_elem_q    <= '0;
        stc_i_q  <= '0;
        stc_j_q  <= '0;
        c_rows_done_q <= '0;
        c_cols_row_q <= '0;
        c_cols_done_q <= '0;
        pmu_r_q  <= '0;
        pmu_w_q  <= '0;
        pmu_cy_q <= '0;
      end

      if (state_q == ST_CHK && (state_d == ST_LB || state_d == ST_MAC)) begin
        i_q <= '0;
        j_q <= '0;
        t_q <= '0;
      end
      if (state_q == ST_LA && (state_d == ST_LB || state_d == ST_MAC)) begin
        i_q <= '0;
        j_q <= '0;
        t_q <= '0;
      end
      if (state_q == ST_LB && state_d == ST_MAC) begin
        i_q <= '0;
        j_q <= '0;
        t_q <= '0;
        a_row_base_q <= pa_q; b_row_base_q <= pb_q;
        a_cur_q      <= pa_q; b_cur_q      <= pb_q;
      end

      // A load: advance t by la_n_d (multi-byte unpack)
      if (!SplitArId && state_q == ST_LA && ar_inflight_q != '0 && axi_resp_s.r_valid) begin
        if (axi_resp_s.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
        if (t_q + 32'(la_n_d) >= k_bytes) begin
          t_q <= '0;
          if (i_q + 1 != m_q) begin
            i_q <= i_q + 1;
            a_row_base_q <= a_row_base_q + AddrWidth'(stride_a_q);
            a_cur_q      <= a_row_base_q + AddrWidth'(stride_a_q);
          end else begin
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
            a_row_base_q <= pa_q;
            a_cur_q      <= pa_q;
          end
        end else begin
          t_q     <= t_q + 32'(la_n_d);
          a_cur_q <= a_cur_q + AddrWidth'(32'(la_n_d));
        end
      end

      // B load: advance t by lb_n_d, then j -- the same shape as the A load
      // above, because AI-X9 made B k-major. There is no held-beat term any
      // more; the oct-drain that needed one is gone.
      if (!SplitArId && state_q == ST_LB && ar_inflight_q != '0 && axi_resp_s.r_valid) begin
        if (axi_resp_s.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
        if (t_q + 32'(lb_n_d) >= k_bytes) begin
          t_q <= '0;
          if (j_q + 1 != n_q) begin
            j_q <= j_q + 1;
            b_row_base_q <= b_row_base_q + AddrWidth'(stride_b_q);
            b_cur_q      <= b_row_base_q + AddrWidth'(stride_b_q);
          end else begin
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
            b_row_base_q <= pb_q;
            b_cur_q      <= pb_q;
          end
        end else begin
          t_q     <= t_q + 32'(lb_n_d);
          b_cur_q <= b_cur_q + AddrWidth'(32'(lb_n_d));
        end
      end

      // MAC: t_q is reduction base; advance by PeLanes, then (i,j).
      // When last cell finishes, i_q := m (one past end) so trail store sees
      // stc_i < i_q for all rows; j_q stays 0.
      //
      // F0b-2: the accumulator is NOT reset here anymore. Reset is now
      // `sum_first_q` in the next drain, which adds the first partial to 0.
      // Resetting acc_q at the element boundary would clear the running total
      // before the last partial has been drained into it.
      if (state_q == ST_MAC && i_q < m_q) begin
        if (t_q + mac_step >= k_q) begin
          t_q   <= '0;
          if (j_q + cols_eff >= n_q) begin
            j_q <= '0;
            i_q <= i_q + 1;  // becomes m when last row completes
`ifdef G6LC_MUT_AI_CURSOR_STRIDE
            // Review mutant: row base advances by 1, not the job stride.
            a_row_base_q <= a_row_base_q + AddrWidth'(1);
            a_cur_q      <= a_row_base_q + AddrWidth'(1);
`else
            a_row_base_q <= a_row_base_q + AddrWidth'(stride_a_q);
            a_cur_q      <= a_row_base_q + AddrWidth'(stride_a_q);
`endif
            b_row_base_q <= pb_q;
            b_cur_q      <= pb_q;
          end else begin
            j_q <= j_q + cols_eff;
            b_row_base_q <= b_row_base_q + AddrWidth'(stride_b_grp_q);
            b_cur_q      <= b_row_base_q + AddrWidth'(stride_b_grp_q);
            a_cur_q      <= a_row_base_q;
          end
        end else begin
          t_q <= t_q + mac_step;
          a_cur_q <= a_cur_q + AddrWidth'(fmt_row_bytes(mac_step));
          b_cur_q <= b_cur_q + AddrWidth'(fmt_row_bytes(mac_step));
        end
      end

      // Store cursor (trail during MAC or dedicated ST_STC)
      if (stc_i_en) stc_i_q <= stc_i_d;
      if (stc_j_en) stc_j_q <= stc_j_d;
      if (SplitArId && axi_resp_s.r_valid && axi_req_d.r_ready && axi_resp_s.r.resp[1])
        err_q <= 1'b1;
    end
  end

  // D2b: the lc_total/lc_beats job product m*n is computed once at job
  // start by a 32-cycle shift-add accumulator (g6lc_ai_mul_seq) instead of
  // an atomic multiplier evaluated every cycle.
  logic        lc_mul_done, lc_mul_ready_q, lc_mul_started_q, lc_mul_start;
  logic [63:0] lc_mul_prod;
  // A pulse can complete during the A/B loads, long before ST_LC is reached.
  // Retain its completion for this descriptor. Launch once, only for a checked
  // accumulate job, so rejected/non-accumulate jobs cannot leave a stale multiply.
  assign lc_mul_start = state_q == ST_CHK && !bad_job && acc_mode_q && !lc_mul_started_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin lc_mul_ready_q <= 1'b0; lc_mul_started_q <= 1'b0; end
    else if (state_q == ST_IDLE && start_i) begin
      lc_mul_ready_q <= 1'b0; lc_mul_started_q <= 1'b0;
    end else begin
      if (lc_mul_start) lc_mul_started_q <= 1'b1;
      if (lc_mul_done) lc_mul_ready_q <= 1'b1;
    end
  end
  g6lc_ai_mul_seq #(.WA(32), .WB(32)) i_lc_mul (
    .clk_i, .rst_ni,
    .start_i   (lc_mul_start),
    .a_i       (m_q),
    .b_i       (n_q),
    .done_o    (lc_mul_done),
    .product_o (lc_mul_prod)
  );

  // ST_LC loader state. Idle outside ST_LC so entry always starts clean.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lc_total_q <= '0; lc_beats_q <= '0; lc_issued_q <= '0; lc_recv_q <= '0;
      lc_burst_left_q <= '0; lc_ar_busy_q <= 1'b0; lc_buf_q <= '0; lc_buf_v_q <= 1'b0;
      lc_word_q <= '0; lc_e_q <= '0; lc_i_q <= '0; lc_j_q <= '0;
    end else if (state_q != ST_LC) begin
      lc_total_q <= lc_mul_prod[31:0];
      lc_beats_q <= (32'((pc_q >> 2) & AddrWidth'(WordsPerBeat - 1)) + lc_mul_prod[31:0]
                     + 32'(WordsPerBeat) - 32'd1) >> LcWordW;
      lc_issued_q <= '0; lc_recv_q <= '0; lc_burst_left_q <= '0; lc_ar_busy_q <= 1'b0;
      lc_buf_q <= '0; lc_buf_v_q <= 1'b0; lc_word_q <= '0;
      lc_e_q <= '0; lc_i_q <= '0; lc_j_q <= '0;
    end else begin
      if (lc_ar_fire) begin
        lc_ar_busy_q    <= 1'b1;
        lc_burst_left_q <= lc_ar_beats;
        lc_issued_q     <= lc_issued_q + 32'(lc_ar_beats);
      end
      if (lc_r_fire) begin
        lc_buf_q   <= axi_resp_s.r.data;
        lc_buf_v_q <= 1'b1;
        // First beat starts at the word lane of ptr_c; later beats at lane 0.
        lc_word_q  <= (lc_recv_q == 32'd0) ? LcWordW'((pc_q >> 2) & AddrWidth'(WordsPerBeat - 1)) : '0;
        lc_recv_q  <= lc_recv_q + 32'd1;
        lc_burst_left_q <= lc_burst_left_q - 8'd1;
        if (lc_burst_left_q == 8'd1 || axi_resp_s.r.last) lc_ar_busy_q <= 1'b0;
      end
      if (lc_w_fire) begin
        lc_e_q <= lc_e_q + 32'd1;
        if (lc_j_q + 32'd1 >= n_q) begin lc_j_q <= '0; lc_i_q <= lc_i_q + 32'd1; end
        else lc_j_q <= lc_j_q + 32'd1;
        if (lc_word_q == LcWordW'(WordsPerBeat - 1) || lc_e_q + 32'd1 >= lc_total_q)
          lc_buf_v_q <= 1'b0;
        else
          lc_word_q <= lc_word_q + LcWordW'(1);
      end else if (lc_buf_v_q && lc_e_q >= lc_total_q) begin
        lc_buf_v_q <= 1'b0;  // trailing pad words of the last beat
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Layer contracts (L3 of the feedback-latency ladder): fire on the cycle of the
  // violation in every simulation -- backend bench, island gates, SoC suite --
  // instead of surfacing as a wrong C word or a stray AXI beat downstream. Each
  // rule is the run-time face of a property proven over the pure functions in
  // corev_apu/ai_island/formal/g6lc_ai_gemm_flat_props.sv. Simulation only.
  // ---------------------------------------------------------------------------
  // pragma translate_off
  always_ff @(posedge clk_i) if (rst_ni) begin
    // C1  Operand bank writes/reads stay inside the panel banks.
    for (int unsigned p = 0; p < PeLanes; p++) begin
      if (a_w_req[p]) assert (32'(a_w_addr[p]) < OperandWordsA)
        else $error("g6lc_ai_gemm_seq C1: A bank write %0d beyond OperandWordsA %0d", a_w_addr[p], OperandWordsA);
      for (int unsigned g = 0; g < OutCols; g++)
        if (b_w_req[g][p]) assert (32'(b_w_addr[g][p]) < OperandWordsBGrp)
          else $error("g6lc_ai_gemm_seq C1: B bank write %0d beyond OperandWordsBGrp %0d", b_w_addr[g][p], OperandWordsBGrp);
      if (a_r_req[p] && state_q == ST_MAC) assert (32'(a_r_addr[p]) < OperandWordsA)
        else $error("g6lc_ai_gemm_seq C1: A bank read %0d beyond OperandWordsA", a_r_addr[p]);
      for (int unsigned g = 0; g < OutCols; g++)
        if (b_r_req[g][p] && state_q == ST_MAC) assert (32'(b_r_addr[g][p]) < OperandWordsBGrp)
          else $error("g6lc_ai_gemm_seq C1: B bank read %0d beyond OperandWordsBGrp", b_r_addr[g][p]);
    end
    // C2  C bank writes stay inside the result bank.
    if (c_w_req) assert (32'(c_w_addr) < BankWords)
      else $error("g6lc_ai_gemm_seq C2: C bank write %0d beyond BankWords %0d", c_w_addr, BankWords);
    // C3  No AXI burst crosses a DRAM channel stripe (N>1 only; N=1 is one channel).
    if (NrChannels > 1 && axi_req_d.ar_valid)
      assert (g6lc_ai_island_cfg_pkg::dram_burst_fits_stripe(NrChannels, ChanShift, 64'(axi_req_d.ar.addr),
                                                   (32'(axi_req_d.ar.len) + 32'd1) << axi_req_d.ar.size))
        else $error("g6lc_ai_gemm_seq C3: AR burst at %h len %0d crosses the %0d B stripe",
                    axi_req_d.ar.addr, axi_req_d.ar.len, 1 << ChanShift);
    if (NrChannels > 1 && axi_req_d.aw_valid)
      assert (g6lc_ai_island_cfg_pkg::dram_burst_fits_stripe(NrChannels, ChanShift, 64'(axi_req_d.aw.addr),
                                                   (32'(axi_req_d.aw.len) + 32'd1) << axi_req_d.aw.size))
        else $error("g6lc_ai_gemm_seq C3: AW burst at %h len %0d crosses the %0d B stripe",
                    axi_req_d.aw.addr, axi_req_d.aw.len, 1 << ChanShift);
    // C4  The trail store never reads a C pair the MAC has not written yet (intra-row
    //     trailing is bounded by the written-column count).
    if (state_q == ST_MAC && c_r0_req && !acc_mode_q && !(stc_i_q < 32'(c_rows_done_q)))
      assert (32'(c_cols_row_q) == stc_i_q && 32'(c_r0_addr) <= c_bank_addr(stc_i_q, c_cols_done_q - 32'd1))
        else $error("g6lc_ai_gemm_seq C4: trail store reads C row %0d word %0d beyond %0d written columns",
                    stc_i_q, c_r0_addr, c_cols_done_q);
  end
  // pragma translate_on

  // pragma translate_off
  // r7 R1: ready_o stays combinational (desc_engine same-cycle start
  // coupling); every start must land while the sequencer is idle.
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      start_i |-> ready_o);

  // pragma translate_off
  // D4 equivalence: barrel-shift wbeat forms vs the loop references,
  // addr swept by a free-running counter so every byte lane / word-fit
  // combination is exercised (incl. the drop-at-edge corner cases).
  int unsigned g6lc_ai_wbeat_eq;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) g6lc_ai_wbeat_eq <= 0;
    else begin
      g6lc_ai_wbeat_eq <= g6lc_ai_wbeat_eq + 1;
      assert (wbeat_words(32'(c_store_addr) + g6lc_ai_wbeat_eq[5:0],
                          wide_c_q ? StoreWordsMax : 2)
              == wbeat_words_ref(32'(c_store_addr) + g6lc_ai_wbeat_eq[5:0],
                                 wide_c_q ? StoreWordsMax : 2))
        else $error("g6lc_ai_gemm_seq: wbeat_eq words mismatch");
      assert (wbeat_at({c_r0_data, c_lo_q}, 8,
                       32'(c_store_addr) + g6lc_ai_wbeat_eq[5:0])
              == wbeat_at_ref({c_r0_data, c_lo_q}, 8,
                              32'(c_store_addr) + g6lc_ai_wbeat_eq[5:0]))
        else $error("g6lc_ai_gemm_seq: wbeat_eq at8 mismatch");
      assert (wbeat_at(64'(c_r0_data), 4,
                       32'(c_store_addr) + g6lc_ai_wbeat_eq[5:0])
              == wbeat_at_ref(64'(c_r0_data), 4,
                              32'(c_store_addr) + g6lc_ai_wbeat_eq[5:0]))
        else $error("g6lc_ai_gemm_seq: wbeat_eq at4 mismatch");
    end
  end
  final $display("[equiv] g6lc_ai_gemm_seq wbeat_eq: checked=%0d", g6lc_ai_wbeat_eq);

  // D2a equivalence at the owning phase: load t is bytes; MAC t is elements.
  // The other panel's cursor is intentionally idle while A or B loads.
  int unsigned g6lc_ai_acur_eq, g6lc_ai_bcur_eq;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin g6lc_ai_acur_eq <= 0; g6lc_ai_bcur_eq <= 0; end
    else begin
      if ((!SplitArId && state_q == ST_LA) || (state_q == ST_MAC && i_q < m_q)) begin
        g6lc_ai_acur_eq <= g6lc_ai_acur_eq + 1;
        assert (a_cur_q == a_addr(pa_q, i_q, state_q == ST_MAC ? fmt_row_bytes(t_q) : t_q, lda_q))
          else $error("g6lc_ai_gemm_seq: acur_eq mismatch");
      end
      if ((!SplitArId && state_q == ST_LB) || (state_q == ST_MAC && i_q < m_q)) begin
        g6lc_ai_bcur_eq <= g6lc_ai_bcur_eq + 1;
        assert (b_cur_q == b_addr(pb_q, state_q == ST_MAC ? fmt_row_bytes(t_q) : t_q, j_q, ldb_q))
          else $error("g6lc_ai_gemm_seq: bcur_eq mismatch");
      end
    end
  end
  final $display("[equiv] g6lc_ai_gemm_seq acur_eq: checked=%0d", g6lc_ai_acur_eq);
  final $display("[equiv] g6lc_ai_gemm_seq bcur_eq: checked=%0d", g6lc_ai_bcur_eq);

  // pragma translate_on
endmodule
