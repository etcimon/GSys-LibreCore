// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// svt-stage fixture (PIPELINE-PRAGMAS §19): three declared regions.
//
//   S1              short comb, single-cycle.
//   S2 cycles=2     declared two-cycle window: the long cone exceeds the
//     after=S1      base budget but must close at 2x. `after=S1` and a
//                   deliberate combinational S1->S2 crossing produce the
//                   boundary finding.
//   S3 window=1     register-bounded behind S2 (no finding); a comb path
//     after=S2      launched in the unstaged `-` region enters S3 and is
//                   judged at (1+1) x budget.
//
// `s2_aux` is driven by an assign outside every region and claimed for S2
// through `use ... on=`. `stage_pragmas_top` instantiates the staged
// module twice for the stage_users table.
module stage_pragmas (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    output logic [31:0] res_o
);
  // svt-stage: order stage_pragmas S1,S2,S3

  logic [31:0] s1_q;
  logic [31:0] s2_q;
  logic [31:0] s2x_q;
  logic [31:0] s3_q;
  logic [31:0] s1_d;
  logic [31:0] s1x_d;
  logic [31:0] s2_d;
  logic [31:0] s2x_d;
  logic [31:0] s3_d;
  logic [31:0] s2_aux;
  logic [31:0] u_d;

  // svt-stage: use S2 on=s2_aux
  assign s2_aux = s1_q ^ 32'h5a5a_5a5a;

  // Unstaged comb: the S3 cone reads this without a flop between, so the
  // path enters S3 from the `-` stage (into-stage, window applies).
  assign u_d = a_i + 32'd7;

  // svt-stage: begin S1
  always_comb begin
    s1_d  = a_i & b_i;
    s1x_d = a_i | b_i;
  end
  // svt-stage: end S1

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_q <= '0;
    end else begin
      s1_q <= s1_d;
    end
  end

  // svt-stage: begin S2 cycles=2 after=S1
  always_comb begin
    logic [31:0] t;
    t = s1_q + s2_aux;
    s2_d = t ^ (s1_q & s2_aux);
    // Deliberate combinational crossing: s1x_d is driven inside S1 and
    // read here with no flop between (after=S1 must flag this path).
    s2x_d = s1x_d & s2_aux;
  end
  // svt-stage: end S2

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_q  <= '0;
      s2x_q <= '0;
    end else begin
      s2_q  <= s2_d;
      s2x_q <= s2x_d;
    end
  end

  // svt-stage: begin S3 window=1 after=S2
  always_comb begin
    s3_d = s2_q & u_d;
  end
  // svt-stage: end S3

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s3_q <= '0;
    end else begin
      s3_q <= s3_d;
    end
  end

  assign res_o = s3_q + s2x_q;
endmodule

module stage_pragmas_top (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    output logic [31:0] res_o
);
  stage_pragmas i_first (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .a_i    (a_i),
      .b_i    (b_i),
      .res_o  ()
  );
  stage_pragmas i_second (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .a_i    (a_i),
      .b_i    (b_i),
      .res_o  (res_o)
  );
endmodule
