// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Auto-correct fixture (A122): the three exact expression identities
// abstracted from measured hand rewrites, each at the end of a cone so the
// path is over a 10-FO4 budget, plus shapes the detector must refuse.
//
//   CircularCompare    (a - h) < (b - h)        -> (a < b) ^ (a < h) ^ (b < h)
//   ZeroDetectEquality (a - b) == 0 / !(a - b)  -> a == b
//   PushSelect         pc + (taken ? x : y)     -> taken ? (pc + x) : (pc + y)
//
// Equivalence of the emitted file against this one is proved by
// verif/regress/remote/run_fo4_control_review.py (CONTROL_MODE=offset-fixture
// with CONTROL_FIXTURE=expr_identities), matched state, every output.
module expr_identities (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [5:0]  tag_a_i,
    input  logic [5:0]  tag_b_i,
    input  logic [5:0]  head_i,
    input  logic [15:0] x_i,
    input  logic [15:0] y_i,
    input  logic [63:0] pc_i,
    input  logic [63:0] imm_a_i,
    input  logic [63:0] imm_b_i,
    input  logic [7:0]  ctl_i,
    output logic        older_o,
    output logic        older_eq_o,
    output logic        match_o,
    output logic        differ_o,
    output logic [63:0] target_o,
    output logic        signed_keep_o,
    output logic        wrap_keep_o,
    output logic [5:0]  guard_pick_o,
    output logic        guard_hit_o
);
  logic [5:0]  tag_a_q, tag_b_q, head_q;
  logic [15:0] x_q, y_q;
  logic [63:0] pc_q, imm_a_q, imm_b_q;
  logic [7:0]  ctl_q;
  logic signed [5:0] s_a_q, s_b_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tag_a_q <= '0; tag_b_q <= '0; head_q <= '0; x_q <= '0; y_q <= '0;
      pc_q <= '0; imm_a_q <= '0; imm_b_q <= '0; ctl_q <= '0; s_a_q <= '0; s_b_q <= '0;
    end else begin
      tag_a_q <= tag_a_i; tag_b_q <= tag_b_i; head_q <= head_i; x_q <= x_i; y_q <= y_i;
      pc_q <= pc_i; imm_a_q <= imm_a_i; imm_b_q <= imm_b_i; ctl_q <= ctl_i;
      s_a_q <= $signed(tag_a_i); s_b_q <= $signed(tag_b_i);
    end
  end

  // A deep control cone so every consumer below is over budget.
  logic [5:0] a_adj, b_adj;
  logic taken;
  always_comb begin
    a_adj = tag_a_q ^ {ctl_q[5:0] & {6{ctl_q[7]}}};
    b_adj = tag_b_q ^ {ctl_q[5:0] & {6{ctl_q[6]}}};
    taken = ((x_q + y_q) > 16'd200) ^ ((x_q & y_q) == (x_q | ctl_q)) ^ (^ctl_q);
  end

  // circular ordering of two tags against a moving head (unsigned, equal widths)
  logic older, older_eq, match, differ, signed_keep, wrap_keep;
  logic [63:0] target;
  assign older    = (a_adj - head_q) < (b_adj - head_q);
  assign older_eq = (a_adj - head_q) <= (b_adj - head_q);
  // zero detect of a difference, two spellings
  assign match  = (a_adj - b_adj) == 6'd0;
  assign differ = |(x_q - (y_q ^ {8'b0, ctl_q}));
  // a late select ahead of a 64-bit add
  assign target = pc_q + (taken ? imm_a_q : imm_b_q);
  // refused: signed operands (the ring rotates differently)
  assign signed_keep = (s_a_q - $signed(head_q)) < (s_b_q - $signed(head_q));
  // refused: an operand that wraps itself under an unsized zero
  assign wrap_keep = (x_q + y_q - 16'd7) == 0;
  // the codebase's dominant form: the compare guards an assignment
  logic [5:0] guard_pick;
  logic guard_hit;
  always_comb begin
    guard_pick = head_q;
    guard_hit  = 1'b0;
    if ((a_adj - head_q) < (b_adj - head_q)) guard_pick = a_adj;
    else guard_pick = b_adj;
    if ((x_q - y_q) != 16'd0) guard_hit = ctl_q[0];
  end
  // registered outputs so a module board times the cones register to register
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      older_o <= 1'b0; older_eq_o <= 1'b0; match_o <= 1'b0; differ_o <= 1'b0;
      target_o <= '0; signed_keep_o <= 1'b0; wrap_keep_o <= 1'b0;
      guard_pick_o <= '0; guard_hit_o <= 1'b0;
    end else begin
      older_o <= older; older_eq_o <= older_eq; match_o <= match; differ_o <= differ;
      target_o <= target; signed_keep_o <= signed_keep; wrap_keep_o <= wrap_keep;
      guard_pick_o <= guard_pick; guard_hit_o <= guard_hit;
    end
  end
endmodule
