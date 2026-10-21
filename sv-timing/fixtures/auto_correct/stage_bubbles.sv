// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// svt-stage bubble-up fixture (PIPELINE-PRAGMAS §19.1): one child module
// with four publishing stages and a parent that consumes them.
//
//   V1 class=value   port flop captured by a parent flop      -> covered
//   R1               port flop feeding the parent's `cycle` d -> drag
//                    (class_source=recurrence, collides with the cycle line)
//   D1               internal flop read by `issue_valid_o`    -> drag
//                    (readiness heuristic on the reader LHS)
//   E1               flop inside an elastic `protocol … ready=`
//                    domain                                  -> absorbed
//   A1               declared `absorb … by=spec-wakeup` but no
//                    latency-class/wakeup state is visible      -> absorbed
//                    with an `unverified-cover` finding
//   A2               declared `absorb … by=read-ahead`; the
//                    registered table read `tbl_q[idx]` is
//                    visible                                 -> absorbed
module sb_child (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic        ready_i,
    output logic        valid_o,
    output logic [31:0] val_o,
    output logic [31:0] rec_o,
    output logic        issue_valid_o,
    output logic [31:0] e_val_o,
    output logic        grant_a1_o,
    output logic [31:0] a2_o
);
  // svt-pipe: protocol e valid=valid_o ready=ready_i
  // svt-pipe: cut-ok e on=e_q
  // svt-stage: order sb_child V1,R1,D1,E1,A1,A2
  // svt-stage: class V1 value
  // svt-stage: absorb A1 by=spec-wakeup cond="producer latency class fixed; replay re-arms"
  // svt-stage: absorb A2 by=read-ahead cond="table read one cycle ahead"

  logic        issue_q;
  logic [31:0] e_q;
  logic        a1_q;
  logic [3:0]  tbl_q;
  logic [31:0] rd2_q;

  assign valid_o = 1'b1;

  // svt-stage: begin V1
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      val_o <= '0;
    end else begin
      val_o <= a_i + b_i;
    end
  end
  // svt-stage: end V1

  // svt-stage: begin R1
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rec_o <= '0;
    end else begin
      rec_o <= a_i ^ b_i;
    end
  end
  // svt-stage: end R1

  // svt-stage: begin D1
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      issue_q <= 1'b0;
    end else begin
      issue_q <= a_i[0] & b_i[0];
    end
  end
  // svt-stage: end D1
  assign issue_valid_o = issue_q;

  // svt-stage: begin E1
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      e_q <= '0;
    end else begin
      e_q <= a_i - b_i;
    end
  end
  // svt-stage: end E1
  assign e_val_o = e_q;

  // svt-stage: begin A1
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a1_q <= 1'b0;
    end else begin
      a1_q <= a_i[2] & b_i[2];
    end
  end
  // svt-stage: end A1
  assign grant_a1_o = a1_q;

  // svt-stage: begin A2
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tbl_q  <= '0;
      rd2_q  <= '0;
    end else begin
      tbl_q  <= a_i[3:0];
      rd2_q  <= {28'b0, tbl_q[a_i[1:0]]};
    end
  end
  // svt-stage: end A2
  assign a2_o = rd2_q;
endmodule

module sb_parent (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic        hold_i,
    output logic [31:0] res_o
);
  // svt-pipe: protocol cyc valid=cyc_valid
  // svt-pipe: cycle cyc q=state_q d=state_d hold=hold_i steps=1

  logic [31:0] val_w;
  logic [31:0] rec_w;
  logic        iss_w;
  logic [31:0] e_w;
  logic        a1_w;
  logic [31:0] a2_w;
  logic [31:0] state_d;
  logic [31:0] state_q;
  logic        cyc_valid;
  logic [31:0] sink_q;
  logic        grant_q;

  assign cyc_valid = 1'b1;

  sb_child i_child (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .a_i           (a_i),
      .b_i           (b_i),
      .ready_i       (hold_i),
      .valid_o       (),
      .val_o         (val_w),
      .rec_o         (rec_w),
      .issue_valid_o (iss_w),
      .e_val_o       (e_w),
      .grant_a1_o    (a1_w),
      .a2_o          (a2_w)
  );

  // decision reader for the spec-wakeup-covered stage A1 (listed verbatim
  // even though the stage verdict is `absorbed`).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      grant_q <= 1'b0;
    end else begin
      grant_q <= a1_w;
    end
  end

  // covered: a plain flop captures the value stage's output.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sink_q <= '0;
    end else begin
      sink_q <= val_w;
    end
  end

  // recurrence: state_d is the `cycle` domain's d name fed by R1's output.
  always_comb begin
    state_d = state_q ^ rec_w;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= '0;
    end else if (!hold_i) begin
      state_q <= state_d;
    end
  end

  assign res_o = sink_q + state_q + e_w + a2_w + {31'b0, iss_w};
endmodule
