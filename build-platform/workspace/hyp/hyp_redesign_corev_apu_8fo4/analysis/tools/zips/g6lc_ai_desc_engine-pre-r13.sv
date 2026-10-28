// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai T2 descriptor engine spine (P3 + I1-lite).
//
// Accepts a software-pushed 64-byte descriptor (doorbell path) on a given
// queue, validates version/op, runs AI-3 address checks on every pointer,
// then for OP_GEMM hands off to the sequential GEMM unit (I1-lite). Other
// ops complete after pointer checks (no compute). Bad pointers never reach
// a DMA/compute master.
//
// Timing: multi-cycle FSM; idle when not busy. Address check is combo and
// does not lengthen a critical path beyond one region compare.

module g6lc_ai_desc_engine
  import g6lc_ai_desc_pkg::*;
#(
    parameter int unsigned NumQueues = 2,
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned QidWidth  = (NumQueues > 1) ? $clog2(NumQueues) : 1,
    parameter int unsigned MaxPrio   = 15,
    // When 1: structural write path present (ports live). Runtime gate is wr_cpl_en_i.
    parameter bit          WriteCompletion = 1'b0,
    // When 1: OP_GEMM enters ST_GEMM (I1-lite). When 0: P3 accept-only for GEMM.
    parameter bit          ExecuteGemm     = 1'b0,
    // Granted numeric formats, one bit per config_pkg::AI_FMT_* index. Must be
    // the SAME value the capability window publishes at CAP_OFF_DTYPE_MASK,
    // otherwise software discovers a format the engine then refuses. The island
    // top passes one constant to both; do not default this to all-ones.
    parameter logic [15:0] DtypeMask       = 16'h0001,
    // CAP_OFF_ACCMODE bit 0: flags.accmode 01 is executable by the attached sequencer.
    parameter bit          AccumulateEn    = 1'b0,
    // A/B loads are one full beat of this many bytes. Live SoC is 8.
    parameter int unsigned BeatBytes       = 8
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  testmode_i,
    // Global enable (island control)
    input  logic                  enable_i,
    // Runtime gate for completion-word DMA (CTL[1]); only used if WriteCompletion=1
    input  logic                  wr_cpl_en_i,
    // Submit (doorbell / ai.enq host path)
    input  logic                  submit_valid_i,
    output logic                  submit_ready_o,
    input  logic [QidWidth-1:0]   submit_qid_i,
    input  logic [31:0]           submit_ticket_i,
    input  desc_bits_t            submit_desc_i,
    // Completion
    output logic                  done_valid_o,
    output logic [31:0]           done_ticket_o,
    output logic [15:0]           done_status_o,
    output logic                  done_irq_o,
    // AI-3 address-check programming + query (shared unit)
    output logic                  prog_we_o,
    output logic [QidWidth-1:0]   prog_qid_o,
    output logic [AddrWidth-1:0]  prog_base_o,
    output logic [AddrWidth-1:0]  prog_limit_o,
    output logic [1:0]            prog_perm_o,
    // External program port (BAR) muxed over same prog_* when prog_ext_we_i
    input  logic                  prog_ext_we_i,
    input  logic [QidWidth-1:0]   prog_ext_qid_i,
    input  logic [AddrWidth-1:0]  prog_ext_base_i,
    input  logic [AddrWidth-1:0]  prog_ext_limit_i,
    input  logic [1:0]            prog_ext_perm_i,
    // Checker combo port
    output logic                  check_req_o,
    output logic [QidWidth-1:0]   check_qid_o,
    output logic [AddrWidth-1:0]  check_addr_o,
    output logic [AddrWidth-1:0]  check_len_o,
    output logic                  check_need_r_o,
    output logic                  check_need_w_o,
    input  logic                  check_ok_i,
    // Status
    output logic                  busy_o,
    output logic [15:0]           last_status_o,
    // Optional memory write of completion word at ptr_done (P3+)
    // When WriteCompletion=0, wr_* are idle and ST_WR_DONE is skipped.
    output logic                  wr_start_o,
    output logic [AddrWidth-1:0]  wr_addr_o,
    output logic [63:0]           wr_data_o,
    input  logic                  wr_ready_i,
    input  logic                  wr_done_i,
    input  logic                  wr_err_i,
    // I1-lite sequential GEMM (island instantiates unit; engine kicks it)
    output logic                  gemm_start_o,
    output logic [31:0]           gemm_m_o,
    output logic [31:0]           gemm_n_o,
    output logic [31:0]           gemm_k_o,
    output logic [15:0]           gemm_lda_o,
    output logic [15:0]           gemm_ldb_o,
    output logic [2:0]            gemm_numfmt_o,
    output logic [AddrWidth-1:0]  gemm_ptr_a_o,
    output logic [AddrWidth-1:0]  gemm_ptr_b_o,
    output logic [AddrWidth-1:0]  gemm_ptr_c_o,
    output logic [31:0]           gemm_flags_o,
    input  logic                  gemm_ready_i,
    input  logic                  gemm_done_i,
    input  logic                  gemm_err_i
);

  typedef enum logic [3:0] {
    ST_IDLE       = 4'd0,
    ST_PARSE      = 4'd1,
    ST_CHK_A      = 4'd2,
    ST_CHK_B      = 4'd3,
    ST_CHK_C      = 4'd4,
    ST_CHK_SCALE  = 4'd5,
    ST_CHK_DONE   = 4'd6,
    ST_GEMM       = 4'd7,
    ST_WR_DONE    = 4'd8,
    ST_SPAN       = 4'd10,
    ST_COMPLETE   = 4'd9
  } state_e;

  state_e state_q, state_d, prev_state_q;
  // r7 R4: ST_SPAN computes the descriptor's three spans through
  // g6lc_ai_mul_seq instead of the in-check combinational functions.
  logic        sp_kick, spa_seen_q, spb_seen_q, spc_seen_q;
  logic        spa_done, spb_done, spc_done;
  logic [95:0] spa_prod, spb_prod;
  logic [63:0] spc_prod;
  logic [63:0] span_a_q, span_b_q, span_c_q;
  logic [63:0] sp_tail_b, sp_stride_a, sp_stride_b;
  logic [63:0] sp_prod_a, sp_prod_b;
  logic [2:0]  sp_fmt;
  desc_t  desc_q, desc_d;
  logic [QidWidth-1:0] qid_q, qid_d;
  logic [31:0] ticket_q, ticket_d;
  logic [15:0] status_q, status_d;
  logic        irq_q, irq_d;
  logic        done_valid_q, done_valid_d;
  logic [15:0] last_status_q;
  logic        wr_issued_q, wr_issued_d;
  logic        gemm_issued_q, gemm_issued_d;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_desc_engine  region=6656  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: desc_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to desc_q
// order expect: done_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to done_valid_q
// order expect: gemm_issued_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to gemm_issued_q
// order expect: irq_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to irq_q
// order expect: last_status_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to last_status_q
// order expect: qid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to qid_q
// order expect: state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to state_q
// order expect: status_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to status_q
// order expect: ticket_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ticket_q
// order expect: wr_issued_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to wr_issued_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     desc_q <= …; // sv-timing: cycle 1/1 on clk_i
//     done_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     gemm_issued_q <= …; // sv-timing: cycle 1/1 on clk_i
//     irq_q <= …; // sv-timing: cycle 1/1 on clk_i
//     last_status_q <= …; // sv-timing: cycle 1/1 on clk_i
//     qid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     status_q <= …; // sv-timing: cycle 1/1 on clk_i
//     ticket_q <= …; // sv-timing: cycle 1/1 on clk_i
//     wr_issued_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23406 c=3.50 slack=1.00 */
//     /* node23407 c=3.50 slack=1.00 */
//     /* node23408 c=3.50 slack=1.00 */
//     /* node23409 c=3.50 slack=1.00 */
//     /* node23410 c=3.50 slack=1.00 */
//     /* node23411 c=3.50 slack=1.00 */
//     /* node23412 c=3.50 slack=1.00 */
//     /* node23413 c=3.50 slack=1.00 */
//     /* node23414 c=3.50 slack=1.00 */
//     /* node23415 c=3.50 slack=1.00 */
//     /* node23416 c=3.50 slack=1.00 */
//     /* node23417 c=3.50 slack=1.00 */
//     /* node23418 c=3.50 slack=1.00 */
//     /* node23419 c=3.50 slack=1.00 */
//     /* node23420 c=3.50 slack=1.00 */
//     /* node23421 c=3.50 slack=1.00 */
//     /* node23422 c=3.50 slack=1.00 */
//     /* node23423 c=3.50 slack=1.00 */
//     /* node23424 c=3.50 slack=1.00 */
//     /* node23425 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // r7 R1: job-event outputs are flops at the module boundary; pulses
  // become one-cycle-delayed pulses; busy/last_status register the next
  // state. submit_ready stays combinational -- the island submit arm
  // samples it in the same edge that drives submit_valid.
  logic        busy_q, wr_start_q, gemm_start_q;
  logic [15:0] last_status_o_q;
  desc_t       gemm_desc_q;
  assign busy_o         = busy_q;
  assign submit_ready_o = (state_q == ST_IDLE) && enable_i;
  assign done_valid_o   = done_valid_q;
  assign done_ticket_o  = ticket_q;
  assign done_status_o  = status_q;
  assign done_irq_o     = done_valid_q && irq_q;
  assign last_status_o  = last_status_o_q;

  // Programming is external-only for this unit
  assign prog_we_o    = prog_ext_we_i;
  assign prog_qid_o   = prog_ext_qid_i;
  assign prog_base_o  = prog_ext_base_i;
  assign prog_limit_o = prog_ext_limit_i;
  assign prog_perm_o  = prog_ext_perm_i;

  // Completion word write (only asserted in ST_WR_DONE)
  logic wr_start_n;
  assign wr_start_o = wr_start_q;
  assign wr_addr_o  = AddrWidth'(desc_q.ptr_done);
  assign wr_data_o  = make_completion(ticket_q, status_q);

  // GEMM params from latched descriptor -- captured with the start pulse.
  logic gemm_start_n;
  assign gemm_start_o = gemm_start_q;
  assign gemm_m_o     = gemm_desc_q.m;
  assign gemm_n_o     = gemm_desc_q.n;
  assign gemm_k_o     = gemm_desc_q.k;
  assign gemm_lda_o   = gemm_desc_q.ld_ab[15:0];
  assign gemm_ldb_o   = gemm_desc_q.ld_ab[31:16];
  assign gemm_numfmt_o= desc_compute_numfmt(gemm_desc_q);
  assign gemm_ptr_a_o = AddrWidth'(gemm_desc_q.ptr_a);
  assign gemm_ptr_b_o = AddrWidth'(gemm_desc_q.ptr_b);
  assign gemm_ptr_c_o = AddrWidth'(gemm_desc_q.ptr_c);
  assign gemm_flags_o = gemm_desc_q.flags;

  // r7 R1 output registers: one always_ff, own register group.
  // r7 R4: ST_SPAN machinery -- prev_state for the kick edge, sticky
  // done flags (cleared on IDLE), span registers latched at each mul's
  // done with the functions' saturation arithmetic.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_state_q <= ST_IDLE;
      spa_seen_q   <= 1'b0; spb_seen_q <= 1'b0; spc_seen_q <= 1'b0;
      span_a_q     <= '0; span_b_q <= '0; span_c_q <= '0;
    end else begin
      prev_state_q <= state_q;
      if (state_q == ST_IDLE) begin
        spa_seen_q <= 1'b0; spb_seen_q <= 1'b0; spc_seen_q <= 1'b0;
      end else begin
        if (spa_done) spa_seen_q <= 1'b1;
        if (spb_done) spb_seen_q <= 1'b1;
        if (spc_done) spc_seen_q <= 1'b1;
      end
      // r7 R4: replicate the functions' degenerate early returns --
      // rows==0 (operand) and rows==0||cols==0 (result) return 1; the
      // (rows-1) mul operand underflows to all-ones without this.
      if (spa_done)
        span_a_q <= (desc_q.m == 0)                             ? 64'd1
                  : (|spa_prod[95:64])                          ? {64{1'b1}}
                  : (sp_tail_b > ({64{1'b1}} - sp_prod_a))      ? {64{1'b1}}
                  : ((sp_prod_a + sp_tail_b) == '0)             ? 64'd1
                  :  sp_prod_a + sp_tail_b;
      if (spb_done)
        span_b_q <= (desc_q.n == 0)                             ? 64'd1
                  : (|spb_prod[95:64])                          ? {64{1'b1}}
                  : (sp_tail_b > ({64{1'b1}} - sp_prod_b))      ? {64{1'b1}}
                  : ((sp_prod_b + sp_tail_b) == '0)             ? 64'd1
                  :  sp_prod_b + sp_tail_b;
      if (spc_done)
        span_c_q <= (desc_q.m == 0 || desc_q.n == 0)            ? 64'd1
                  : (spc_prod > ({64{1'b1}} >> 2))              ? {64{1'b1}}
                  : spc_prod << 2;
    end
  end

  // Operand composition (ai_row_bytes = elems << elem shift): strides at
  // kick time from desc_q; tails are the k-element row bytes shared by A/B.
  assign sp_fmt      = desc_compute_numfmt(desc_q);
  assign sp_stride_a = 64'(g6lc_ai_island_cfg_pkg::ai_row_bytes(
      sp_fmt, 32'(desc_q.ld_ab[15:0])));
  assign sp_stride_b = 64'(g6lc_ai_island_cfg_pkg::ai_row_bytes(
      sp_fmt, 32'(desc_q.ld_ab[31:16])));
  assign sp_tail_b   = 64'(g6lc_ai_island_cfg_pkg::ai_row_bytes(
      sp_fmt, desc_q.k));
  assign sp_prod_a   = spa_prod[63:0];
  assign sp_prod_b   = spb_prod[63:0];
  assign sp_kick     = (state_q == ST_SPAN) && (prev_state_q != ST_SPAN);

  g6lc_ai_mul_seq #(.WA(32), .WB(64)) i_span_a_mul (
      .clk_i, .rst_ni,
      .start_i   (sp_kick),
      .a_i       (32'(desc_q.m) - 32'd1),
      .b_i       (sp_stride_a),
      .done_o    (spa_done),
      .product_o (spa_prod));
  g6lc_ai_mul_seq #(.WA(32), .WB(64)) i_span_b_mul (
      .clk_i, .rst_ni,
      .start_i   (sp_kick),
      .a_i       (32'(desc_q.n) - 32'd1),
      .b_i       (sp_stride_b),
      .done_o    (spb_done),
      .product_o (spb_prod));
  g6lc_ai_mul_seq #(.WA(32), .WB(32)) i_span_c_mul (
      .clk_i, .rst_ni,
      .start_i   (sp_kick),
      .a_i       (desc_q.m),
      .b_i       (desc_q.n),
      .done_o    (spc_done),
      .product_o (spc_prod));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q           <= 1'b0;
      wr_start_q       <= 1'b0;
      gemm_start_q     <= 1'b0;
      last_status_o_q  <= '0;
      gemm_desc_q      <= '0;
    end else begin
      busy_q           <= (state_d != ST_IDLE);
      wr_start_q       <= wr_start_n;
      gemm_start_q     <= gemm_start_n;
      last_status_o_q  <= last_status_q;
      if (gemm_start_n) gemm_desc_q <= desc_q;
    end
  end

  // After checks (and optional GEMM): completion DMA or done pulse
  function automatic logic want_wr_cpl(input desc_t d, input logic wr_en);
    return WriteCompletion && wr_en && (d.ptr_done != '0);
  endfunction

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
  // --- BalanceMux arm staging (latency-neutral) ---
  logic svt_bm_p6654_n23316_0;
  logic [64-1:0] svt_bm_p6654_n23316_1;
  var type(check_addr_o) svt_bm_top_p6654_n23316;
  always_comb begin : svt_bm_top_p6654_n23316_stage
    svt_bm_p6654_n23316_0 = state_q == ST_CHK_A;
    svt_bm_p6654_n23316_1 = svt_bm_p6654_n23316_0 ? desc_q.ptr_a : desc_q.ptr_b;
    svt_bm_top_p6654_n23316 = type(check_addr_o)'(g6lc_ai_island_cfg_pkg::ai_beat_lo(svt_bm_p6654_n23316_1, BeatBytes));
  end
  // END sv-timing auto-correct (balance_mux rewrite)
  always_comb begin
    check_req_o = 1'b0;
    check_qid_o = qid_q;
    check_addr_o = '0;
    check_len_o = AddrWidth'(8);
    check_need_r_o = 1'b0;
    check_need_w_o = 1'b0;
    case (state_q)
      ST_CHK_A, ST_CHK_B: begin
        check_req_o = 1'b1;
        check_addr_o = svt_bm_top_p6654_n23316; // sv-timing: BalanceMux/rebalance #658 RHS rewrite
            // sv-timing: (RHS rewrite continuation removed) state_q == ST_CHK_A ? desc_q.ptr_a : desc_q.ptr_b, BeatBytes);
        check_len_o = AddrWidth'(g6lc_ai_island_cfg_pkg::ai_bus_len(
            state_q == ST_CHK_A ? desc_q.ptr_a : desc_q.ptr_b,
            state_q == ST_CHK_A ? span_a_q : span_b_q, BeatBytes));
        check_need_r_o = 1'b1;
      end
      ST_CHK_C: begin
        check_req_o = 1'b1;
        check_addr_o = desc_q.ptr_c;
        check_len_o = AddrWidth'(span_c_q);
        check_need_w_o = 1'b1;
      end
      ST_CHK_SCALE: begin
        check_req_o = desc_q.ptr_scale != '0;
        check_addr_o = desc_q.ptr_scale;
        check_need_r_o = desc_q.ptr_scale != '0;
      end
      ST_CHK_DONE: begin
        check_req_o = desc_q.ptr_done != '0;
        check_addr_o = desc_q.ptr_done;
        check_need_w_o = desc_q.ptr_done != '0;
      end
      default: ;
    endcase
  end

  // Default check idle
  always_comb begin
    state_d       = state_q;
    desc_d        = desc_q;
    qid_d         = qid_q;
    ticket_d      = ticket_q;
    status_d      = status_q;
    irq_d         = irq_q;
    done_valid_d  = 1'b0;
    wr_start_n    = 1'b0;
    wr_issued_d   = wr_issued_q;
    gemm_start_n  = 1'b0;
    gemm_issued_d = gemm_issued_q;

    // Pointer-sized probes (completion, scale). A/B/C override this with the
    // byte length of the tensor so a matrix cannot start in-window and
    // finish past the limit.

    unique case (state_q)
      ST_IDLE: begin
        if (submit_valid_i && submit_ready_o) begin
          desc_d        = bits_to_desc(submit_desc_i);
          qid_d         = submit_qid_i;
          ticket_d      = submit_ticket_i;
          status_d      = ST_OK;
          irq_d         = 1'b0;
          wr_issued_d   = 1'b0;
          gemm_issued_d = 1'b0;
          state_d       = ST_PARSE;
        end else if (submit_valid_i && !enable_i) begin
          // Drop with disabled status if kicked while off
          desc_d   = bits_to_desc(submit_desc_i);
          qid_d    = submit_qid_i;
          ticket_d = submit_ticket_i;
          status_d = ST_DISABLED;
          irq_d    = 1'b0;
          state_d  = ST_COMPLETE;
        end
      end

      ST_PARSE: begin
        if (desc_q.version != 16'(ContractVersion)) begin
          status_d = ST_BAD_VER;
          state_d  = ST_COMPLETE;
        end else if (!(desc_q.op inside {OP_GEMM, OP_CONV2D, OP_LAYOUT, OP_PREFETCH})) begin
          status_d = ST_BAD_OP;
          state_d  = ST_COMPLETE;
        end else if (int'(qid_q) >= NumQueues) begin
          status_d = ST_BAD_QID;
          state_d  = ST_COMPLETE;
        end else if (desc_q.flags[FLAG_REQUANT_SHIFT]) begin
          // A set requant flag would otherwise run the integer GEMM and
          // report success. The products would not be the requested post-op.
          status_d = ST_BAD_OP;
          state_d  = ST_COMPLETE;
        end else if (!desc_numfmt_granted(desc_q, DtypeMask) ||
                     (desc_accumulate(desc_q) && !AccumulateEn)) begin
          // Fail closed on an ungranted numeric format. Checked here, in PARSE,
          // alongside version/op/qid rather than in the GEMM sequencer, because
          // this is a contract check on the descriptor and not a property of the
          // datapath -- and because refusing before any operand fetch means an
          // unsupported format costs no DRAM traffic. Demotion to INT8 is
          // deliberately not offered: it would produce plausible wrong numbers.
          status_d = ST_BAD_FMT;
          state_d  = ST_COMPLETE;
        end else begin
          // Priority is clamped by software/S-mode policy; engine accepts 0..15.
          state_d = ST_SPAN;
        end
      end

      ST_SPAN: begin
        if (spa_seen_q && spb_seen_q && spc_seen_q) state_d = ST_CHK_A;
      end

      ST_CHK_A: begin
        if (!g6lc_ai_island_cfg_pkg::ai_elem_aligned(
                desc_q.ptr_a, desc_compute_numfmt(desc_q)) || !check_ok_i) begin
          status_d = ST_BAD_PTR;
          state_d  = ST_COMPLETE;
        end else state_d = ST_CHK_B;
      end

      ST_CHK_B: begin
        if (!g6lc_ai_island_cfg_pkg::ai_elem_aligned(
                desc_q.ptr_b, desc_compute_numfmt(desc_q)) || !check_ok_i) begin
          status_d = ST_BAD_PTR;
          state_d  = ST_COMPLETE;
        end else state_d = ST_CHK_C;
      end

      ST_CHK_C: begin
        if (!g6lc_ai_island_cfg_pkg::ai_c_aligned(desc_q.ptr_c, desc_q.n[0])
            || !check_ok_i) begin
          status_d = ST_BAD_PTR;
          state_d  = ST_COMPLETE;
        end else state_d = ST_CHK_SCALE;
      end

      ST_CHK_SCALE: begin
        // ptr_scale is optional, so a null pointer skips the check rather than
        // failing it; only a non-null pointer has to be inside the region.
        if (desc_q.ptr_scale == '0) begin
          state_d = ST_CHK_DONE;
        end else begin
          if (!check_ok_i) begin
            status_d = ST_BAD_PTR;
            state_d  = ST_COMPLETE;
          end else state_d = ST_CHK_DONE;
        end
      end


      ST_CHK_DONE: begin
        // Null ptr_done: no completion word; else check writable before execute
        if (desc_q.ptr_done != '0) begin
          if (!g6lc_ai_island_cfg_pkg::ai_completion_aligned(desc_q.ptr_done)
              || !check_ok_i) begin
            status_d = ST_BAD_PTR;
            state_d  = ST_COMPLETE;
          end else begin
            // fall through to execute decision below
            if (ExecuteGemm && desc_q.op == OP_GEMM) begin
              gemm_issued_d = 1'b0;
              state_d       = ST_GEMM;
            end else begin
              status_d = ST_OK;
              irq_d    = desc_irq(desc_q);
              if (want_wr_cpl(desc_q, wr_cpl_en_i)) state_d = ST_WR_DONE;
              else state_d = ST_COMPLETE;
            end
          end
        end else if (ExecuteGemm && desc_q.op == OP_GEMM) begin
          gemm_issued_d = 1'b0;
          state_d       = ST_GEMM;
        end else begin
          status_d = ST_OK;
          irq_d    = desc_irq(desc_q);
          state_d  = ST_COMPLETE;
        end
      end

      ST_GEMM: begin
        // gemm_issued_q makes start a one-shot: gemm_start_o is combinational
        // out of this state, so without the latch it would re-fire every cycle
        // the sequencer is still ready.
        if (!gemm_issued_q && gemm_ready_i) begin
          gemm_start_n  = 1'b1;
          gemm_issued_d = 1'b1;
        end
        if (gemm_issued_q && gemm_done_i) begin
          if (gemm_err_i) status_d = ST_ERR;
          else            status_d = ST_OK;
          irq_d = desc_irq(desc_q);
          if (want_wr_cpl(desc_q, wr_cpl_en_i)) state_d = ST_WR_DONE;
          else state_d = ST_COMPLETE;
        end
      end

      ST_WR_DONE: begin
        // One-shot start when store unit is ready; wait for done
        if (!wr_issued_q && wr_ready_i) begin
          wr_start_n  = 1'b1;
          wr_issued_d = 1'b1;
        end
        if (wr_issued_q && wr_done_i) begin
          if (wr_err_i) status_d = ST_ERR;
          state_d = ST_COMPLETE;
        end
      end

      ST_COMPLETE: begin
        done_valid_d = 1'b1;
        state_d      = ST_IDLE;
      end

      default: state_d = ST_IDLE;
    endcase

    // testmode: hold idle for scan observability of prog path
    if (testmode_i && state_q == ST_IDLE) begin
      state_d = ST_IDLE;
    end

  end

  // pragma translate_off
  // r7 R4: the registered span must equal the function evaluated on the
  // same descriptor the checker sees -- per check state, with a counter.
  int unsigned g6lc_ai_span_eq;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) g6lc_ai_span_eq <= 0;
    else if (check_req_o) begin
      g6lc_ai_span_eq <= g6lc_ai_span_eq + 1;
      if (state_q == ST_CHK_A)
        assert (check_len_o == AddrWidth'(g6lc_ai_island_cfg_pkg::ai_bus_len(
            desc_q.ptr_a,
            g6lc_ai_island_cfg_pkg::ai_operand_span(
                desc_q.m, 32'(desc_q.ld_ab[15:0]), desc_q.k,
                desc_compute_numfmt(desc_q)), BeatBytes)))
          else $error("desc_engine: span_a mismatch span=%0d fn=%0d",
                      span_a_q, g6lc_ai_island_cfg_pkg::ai_operand_span(
                          desc_q.m, 32'(desc_q.ld_ab[15:0]), desc_q.k,
                          desc_compute_numfmt(desc_q)));
      if (state_q == ST_CHK_B)
        assert (check_len_o == AddrWidth'(g6lc_ai_island_cfg_pkg::ai_bus_len(
            desc_q.ptr_b,
            g6lc_ai_island_cfg_pkg::ai_operand_span(
                desc_q.n, 32'(desc_q.ld_ab[31:16]), desc_q.k,
                desc_compute_numfmt(desc_q)), BeatBytes)))
          else $error("desc_engine: span_b mismatch span=%0d fn=%0d",
                      span_b_q, g6lc_ai_island_cfg_pkg::ai_operand_span(
                          desc_q.n, 32'(desc_q.ld_ab[31:16]), desc_q.k,
                          desc_compute_numfmt(desc_q)));
      if (state_q == ST_CHK_C)
        assert (check_len_o == AddrWidth'(
            g6lc_ai_island_cfg_pkg::ai_result_span(desc_q.m, desc_q.n)))
          else $error("desc_engine: span_c mismatch span=%0d fn=%0d",
                      span_c_q,
                      g6lc_ai_island_cfg_pkg::ai_result_span(desc_q.m, desc_q.n));
    end
  end
  final $display("[equiv] g6lc_ai_desc_engine span_eq: checked=%0d",
                 g6lc_ai_span_eq);
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= ST_IDLE;
      desc_q         <= '0;
      qid_q          <= '0;
      ticket_q       <= '0;
      status_q       <= '0;
      irq_q          <= 1'b0;
      done_valid_q   <= 1'b0;
      last_status_q  <= '0;
      wr_issued_q    <= 1'b0;
      gemm_issued_q  <= 1'b0;
    end else begin
      state_q       <= state_d;
      desc_q        <= desc_d;
      qid_q         <= qid_d;
      ticket_q      <= ticket_d;
      status_q      <= status_d;
      irq_q         <= irq_d;
      done_valid_q  <= done_valid_d;
      wr_issued_q   <= wr_issued_d;
      gemm_issued_q <= gemm_issued_d;
      // last_status_q is sticky for STATUS[31:16]: status_q is reused by the
      // next job, so the MMIO view has to latch it at completion.
      if (done_valid_d) last_status_q <= status_d;
    end
  end

endmodule
