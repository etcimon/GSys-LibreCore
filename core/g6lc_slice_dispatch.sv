// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U4 slice dispatch top: IST + steer + A/B IQs + RMT + select.
//
// Sits between the scoreboard's dispatch stream and issue_read_operands.
// Scoreboard allocates in program order on dispatch_ack (issue_ack into SB);
// this module may present A-queue heads to IRO ahead of older B heads when
// the RMT says operands are ready and runahead < SliceMaxRunahead.
//
// Invariants:
//   * No associative wakeup — only FIFO heads are candidates.
//   * IST is a hint (flush anytime).
//   * Retire order remains scoreboard/commit (program-order alloc).

module g6lc_slice_dispatch
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type scoreboard_entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,              // full pipeline flush → clear IQs/IST/RMT
    input  logic flush_unissued_i,     // stop new dispatch; keep IQ contents
    // From scoreboard dispatch stream (program order, trans_id already set)
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       dispatch_sbe_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] dispatch_orig_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]       dispatch_valid_i,
    output logic              [CVA6Cfg.NrIssuePorts-1:0]       dispatch_ack_o,
    // To issue_read_operands
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       issue_sbe_o,
    output logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] issue_orig_o,
    output logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_valid_o,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_ack_i,
    // Complete (writeback) for RMT
    input  logic [CVA6Cfg.NrWbPorts-1:0]                            wb_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] wb_id_i
);

  // ---- IST ----
  logic ist_is_slice;
  logic train_valid;
  logic [CVA6Cfg.VLEN-1:0] train_pc;

  g6lc_slice_ist #(
      .CVA6Cfg   (CVA6Cfg),
      .NR_ENTRIES(CVA6Cfg.SliceIstEntries)
  ) i_ist (
      .clk_i,
      .rst_ni,
      .flush_i         (flush_i),
      .lookup_pc_i     (dispatch_sbe_i[0].pc),
      .is_slice_o      (ist_is_slice),
      .train_valid_i   (train_valid),
      .train_pc_i      (train_pc),
      .train_is_slice_i(1'b1)
  );

  // Train IST on every LOAD dispatch (seed the address-slice set)
  assign train_valid = dispatch_valid_i[0] && dispatch_ack_o[0] &&
                       (dispatch_sbe_i[0].fu == LOAD);
  assign train_pc    = dispatch_sbe_i[0].pc;

  // ---- Steer ----
  logic to_a;
  g6lc_slice_steer #(
      .CVA6Cfg(CVA6Cfg),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_steer (
      .instr_i       (dispatch_sbe_i[0]),
      .ist_is_slice_i(ist_is_slice),
      .to_a_o        (to_a),
      .is_load_o     ()
  );

  // ---- Dual IQs ----
  logic a_ready, b_ready;
  logic a_head_valid, b_head_valid;
  scoreboard_entry_t a_head_sbe, b_head_sbe;
  logic [31:0] a_head_orig, b_head_orig;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] a_head_age, b_head_age;
  logic a_pop, b_pop;
  logic a_push, b_push;

  g6lc_slice_iq #(
      .CVA6Cfg(CVA6Cfg),
      .DEPTH  (CVA6Cfg.SliceAiqDepth),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_a_iq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .push_i      (a_push),
      .push_sbe_i  (dispatch_sbe_i[0]),
      .push_orig_i (dispatch_orig_i[0]),
      .push_age_i  (dispatch_sbe_i[0].trans_id),
      .ready_o     (a_ready),
      .head_valid_o(a_head_valid),
      .head_sbe_o  (a_head_sbe),
      .head_orig_o (a_head_orig),
      .head_age_o  (a_head_age),
      .pop_i       (a_pop),
      .count_o     ()
  );

  g6lc_slice_iq #(
      .CVA6Cfg(CVA6Cfg),
      .DEPTH  (CVA6Cfg.SliceBiqDepth),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_b_iq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .push_i      (b_push),
      .push_sbe_i  (dispatch_sbe_i[0]),
      .push_orig_i (dispatch_orig_i[0]),
      .push_age_i  (dispatch_sbe_i[0].trans_id),
      .ready_o     (b_ready),
      .head_valid_o(b_head_valid),
      .head_sbe_o  (b_head_sbe),
      .head_orig_o (b_head_orig),
      .head_age_o  (b_head_age),
      .pop_i       (b_pop),
      .count_o     ()
  );

  // Do not accept new dispatch while unissued flush is asserted (SB also gates).
  assign a_push = dispatch_valid_i[0] && to_a && a_ready && !flush_unissued_i;
  assign b_push = dispatch_valid_i[0] && !to_a && b_ready && !flush_unissued_i;
  assign dispatch_ack_o[0] = a_push | b_push;

  for (genvar p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin : gen_port_stall
    assign dispatch_ack_o[p] = 1'b0;
  end

  // ---- RMT (shared state, dual query) ----
  logic a_rs1_ready, a_rs2_ready, b_rs1_ready, b_rs2_ready;
  logic rmt_complete;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] rmt_complete_id;

  always_comb begin
    rmt_complete    = 1'b0;
    rmt_complete_id = '0;
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
      if (wb_valid_i[w]) begin
        rmt_complete    = 1'b1;
        rmt_complete_id = wb_id_i[w];
      end
    end
  end

  g6lc_slice_rmt #(
      .CVA6Cfg(CVA6Cfg)
  ) i_rmt (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_i         (dispatch_ack_o[0]),
      .alloc_rd_i      (dispatch_sbe_i[0].rd),
      .alloc_rd_is_fp_i(CVA6Cfg.FpPresent && is_rd_fpr(dispatch_sbe_i[0].op)),
      .alloc_from_a_i  (to_a),
      .alloc_id_i      (dispatch_sbe_i[0].trans_id),
      .complete_i      (rmt_complete),
      .complete_id_i   (rmt_complete_id),
      .a_rs1_i         (a_head_sbe.rs1),
      .a_rs1_is_fp_i   (CVA6Cfg.FpPresent && is_rs1_fpr(a_head_sbe.op)),
      .a_rs2_i         (a_head_sbe.rs2),
      .a_rs2_is_fp_i   (CVA6Cfg.FpPresent && is_rs2_fpr(a_head_sbe.op)),
      .a_rs1_ready_o   (a_rs1_ready),
      .a_rs2_ready_o   (a_rs2_ready),
      .b_rs1_i         (b_head_sbe.rs1),
      .b_rs1_is_fp_i   (CVA6Cfg.FpPresent && is_rs1_fpr(b_head_sbe.op)),
      .b_rs2_i         (b_head_sbe.rs2),
      .b_rs2_is_fp_i   (CVA6Cfg.FpPresent && is_rs2_fpr(b_head_sbe.op)),
      .b_rs1_ready_o   (b_rs1_ready),
      .b_rs2_ready_o   (b_rs2_ready)
  );

  logic a_op_ready, b_op_ready;
  assign a_op_ready = a_head_valid && a_rs1_ready && a_rs2_ready;
  assign b_op_ready = b_head_valid && b_rs1_ready && b_rs2_ready;

  // ---- Runahead counter ----
  localparam int unsigned RA_W = CVA6Cfg.TRANS_ID_BITS + 1;
  logic [RA_W-1:0] runahead_q, runahead_d;
  logic issue_a, issue_b;

  // Select: prefer program-older ready head; else A-runahead if B blocked
  always_comb begin
    issue_a = 1'b0;
    issue_b = 1'b0;
    if (a_op_ready && b_op_ready) begin
      if (a_head_age <= b_head_age) issue_a = 1'b1;
      else issue_b = 1'b1;
    end else if (a_op_ready && !b_op_ready) begin
      if (!b_head_valid || a_head_age <= b_head_age ||
          (runahead_q < RA_W'(CVA6Cfg.SliceMaxRunahead)))
        issue_a = 1'b1;
    end else if (b_op_ready && !a_op_ready) begin
      if (!a_head_valid || b_head_age <= a_head_age) issue_b = 1'b1;
    end
  end

  assign a_pop = issue_a && issue_ack_i[0];
  assign b_pop = issue_b && issue_ack_i[0];

  always_comb begin
    issue_sbe_o   = '0;
    issue_orig_o  = '0;
    issue_valid_o = '0;
    if (issue_a) begin
      issue_sbe_o[0]   = a_head_sbe;
      issue_orig_o[0]  = a_head_orig;
      issue_valid_o[0] = 1'b1;
    end else if (issue_b) begin
      issue_sbe_o[0]   = b_head_sbe;
      issue_orig_o[0]  = b_head_orig;
      issue_valid_o[0] = 1'b1;
    end
  end

  always_comb begin
    runahead_d = runahead_q;
    if (flush_i) begin
      runahead_d = '0;
    end else begin
      if (a_pop && b_head_valid && (a_head_age > b_head_age))
        runahead_d = runahead_q + RA_W'(1);
      if (b_pop && runahead_q != '0)
        runahead_d = runahead_q - RA_W'(1);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) runahead_q <= '0;
    else runahead_q <= runahead_d;
  end

endmodule
