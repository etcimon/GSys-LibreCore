// hyp8 provenance: REWRITTEN (sv-timing emit base, 8-stage multiplier)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
//
// Description: Multiplication Unit, 8-stage hyp8 pipeline.
//
// hyp8 (group 7): hyp_mult_stages(HypCfg, G6LCCfg.MultStages) == 8 selects
// the eight-stage form (rank 4; execute.md "multiplier"):
//   S1  operand condition: (XLEN+1)x(SB) tile partial products plus the
//       modular sign-correction row, registered.
//   S2-S5  four carry-save stages. Each stage runs two 3:2 compressor
//       levels over the shifted product terms and the folded-in -corr
//       rows (a+b+c preserved mod 2**RW; no carry propagation), so the
//       NOPS-row reduction needs no stage deeper than two CSA levels.
//   S6  first carry-propagate half: low RW/2 bits of sum+carry, with the
//       carry-out and both high halves registered.
//   S7  second carry-propagate half: high RW/2 bits + carry -> the full
//       product modulo 2**RW, registered (the "two CPAs" split; for
//       XLEN=64 each CPA covers a 64-bit half of the 128-bit product).
//   S8  result/flags: operator select (MUL/MULH/CLMUL/sext32), valid and
//       trans_id, into the output register.
// valid/trans_id/operator and both CLMUL results cross every boundary with
// the data (the A126 merge rule). mult.sv carries the cancellation
// liveness over the same MSTAGES stages and suppresses killed results.
// MultStages < 8 keeps the emit's two/three/four-stage forms; ==1 stays
// combinational.

module multiplier
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault
) (
    // Subsystem Clock - SUBSYSTEM
    input  logic                             clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                             rst_ni,
    // Multiplier transaction ID - Mult
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_i,
    // Multiplier instruction is valid - Mult
    input  logic                             mult_valid_i,
    // Multiplier operation - Mult
    input  fu_op                             operation_i,
    // A operand - Mult
    input  logic [         G6LCCfg.XLEN-1:0] operand_a_i,
    // B operand - Mult
    input  logic [         G6LCCfg.XLEN-1:0] operand_b_i,
    // Multiplier result - Mult
    output logic [         G6LCCfg.XLEN-1:0] result_o,
    // Mutliplier result is valid - Mult
    output logic                             mult_valid_o,
    // Multiplier transaction ID - Mult
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] mult_trans_id_o
);

  // hyp8: inline hyp_mult_stages() so structural const-eval can resolve
  // the live branch (a package function call is opaque to it) and the
  // config-dead forms stop billing. Identical semantics.
  localparam int unsigned MSTAGES = (HypCfg.MultStagesOverride != 0)
      ? HypCfg.MultStagesOverride : G6LCCfg.MultStages;

  // Carry-less multiplication
  logic [G6LCCfg.XLEN-1:0]
      clmul_q, clmul_d, clmulr_q, clmulr_d, operand_a, operand_b, operand_a_rev, operand_b_rev;
  logic clmul_rmode, clmul_hmode;

  if (G6LCCfg.RVB) begin : gen_bitmanip
    // checking for clmul_rmode and clmul_hmode
    assign clmul_rmode = (operation_i == CLMULR);
    assign clmul_hmode = (operation_i == CLMULH);

    // operand_a and b reverse generator
    for (genvar i = 0; i < G6LCCfg.XLEN; i++) begin
      assign operand_a_rev[i] = operand_a_i[(G6LCCfg.XLEN-1)-i];
      assign operand_b_rev[i] = operand_b_i[(G6LCCfg.XLEN-1)-i];
    end

    // operand_a and operand_b selection
    assign operand_a = (clmul_rmode | clmul_hmode) ? operand_a_rev : operand_a_i;
    assign operand_b = (clmul_rmode | clmul_hmode) ? operand_b_rev : operand_b_i;

    // implementation
    // hyp8: the serial XOR-accumulate bills as a 65-deep chain; the clmul
    // word is an XOR gather of the bit-selected shifted terms — write it
    // as a balanced pairwise XOR tree (associative op, identical value).
    // (the original loop's i == XLEN term is dead: operand_b >> XLEN is 0)
    // r42-T R1: in the eight-stage build the whole tree is dead — the
    // product is slice-accumulated in mult_clmul across S2-S7 instead, so
    // the in->reg cone disappears entirely (not just retimed into S2).
`ifdef G6LC_MUT_T2_MULT_CLMUL
    localparam bit CLM_TREE = 1'b1;
`else
    localparam bit CLM_TREE = (MSTAGES != 8);
`endif
    if (CLM_TREE) begin : gen_clm_tree
      localparam int unsigned CML = $clog2(G6LCCfg.XLEN);
      logic [G6LCCfg.XLEN-1:0] cm_t [CML+1][G6LCCfg.XLEN];
      for (genvar cl = 0; cl <= CML; cl++) begin : gen_cml
        for (genvar t = 0; t < G6LCCfg.XLEN; t++) begin : gen_cmt
          if (cl == 0) begin : gen_leaf
            assign cm_t[0][t] = operand_b[t] ? (operand_a << t) : '0;
          end else if (t < ((G6LCCfg.XLEN + (1 << cl) - 1) >> cl)) begin : gen_pair
            if (2 * t + 1 < ((G6LCCfg.XLEN + (1 << (cl - 1)) - 1) >> (cl - 1))) begin : gen_p2
              assign cm_t[cl][t] = cm_t[cl-1][2*t] ^ cm_t[cl-1][2*t+1];
            end else begin : gen_odd
              assign cm_t[cl][t] = cm_t[cl-1][2*t];
            end
          end else begin : gen_pad
            assign cm_t[cl][t] = '0;
          end
        end
      end
      assign clmul_d = cm_t[CML][0];

      // clmulr + clmulh result generator
      for (genvar i = 0; i < G6LCCfg.XLEN; i++) begin
        assign clmulr_d[i] = clmul_d[(G6LCCfg.XLEN-1)-i];
      end
    end else begin : gen_no_clm_tree
      assign clmul_d  = '0;
      assign clmulr_d = '0;
    end
  end else begin : gen_no_bitmanip
    assign clmul_rmode = 1'b0;
    assign clmul_hmode = 1'b0;
    assign operand_a_rev = '0;
    assign operand_b_rev = '0;
    assign operand_a = '0;
    assign operand_b = '0;
    assign clmul_d = '0;
    assign clmulr_d = '0;
  end

  // Pipeline register
  logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_q;
  logic                             mult_valid_q;
  fu_op operator_q;
  logic [G6LCCfg.XLEN-1:0] mult_result_q;

  // control registers
  logic sign_a, sign_b;
  logic mult_valid;

  // control signals
  assign mult_valid_o = mult_valid_q;
  assign mult_trans_id_o = trans_id_q;
  assign result_o = mult_result_q;

  assign mult_valid      = mult_valid_i && (operation_i inside {MUL, MULH, MULHU, MULHSU, MULW, CLMUL, CLMULH, CLMULR});

  // Sign Select MUX
  always_comb begin
    sign_a = 1'b0;
    sign_b = 1'b0;

    // signed multiplication
    if (operation_i == MULH) begin
      sign_a = 1'b1;
      sign_b = 1'b1;
      // signed - unsigned multiplication
    end else if (operation_i == MULHSU) begin
      sign_a = 1'b1;
      // unsigned multiplication
    end else begin
      sign_a = 1'b0;
      sign_b = 1'b0;
    end
  end


  // The signed (XLEN+1)-bit operands: the sign bit is the operation's, so
  // MULHU/MULHSU/MUL share one multiplier.
  logic signed [G6LCCfg.XLEN:0] op_a_s, op_b_s;
  assign op_a_s = $signed({operand_a_i[G6LCCfg.XLEN-1] & sign_a, operand_a_i});
  assign op_b_s = $signed({operand_b_i[G6LCCfg.XLEN-1] & sign_b, operand_b_i});

  // Constant-function scope must be outside generate blocks (IEEE 1800).
  function automatic int unsigned compressor_rows(
      input int unsigned initial_rows, input int unsigned level);
    int unsigned n;
    n = initial_rows;
    for (int unsigned l = 0; l < level; l++)
      n = 2 * (n / 3) + (n % 3);
    return n;
  endfunction

  if (MSTAGES == 8) begin : gen_eight_stage
    // ---------------------------------------------------------------
    // hyp8 eight-stage form. Unsigned partial products with a modular
    // sign correction (same algebra as the emit):
    //   A*B == A_u*B_u - 2**(XLEN+1)*(a_top*B_u + b_top*A_u)  (mod 2**RW)
    // ---------------------------------------------------------------
    localparam int unsigned AW = G6LCCfg.XLEN + 1;  // unsigned pattern of the signed operand
    localparam int unsigned NPART = AW;             // one AND row per b_u bit
    localparam int unsigned RW = G6LCCfg.XLEN * 2;
    localparam int unsigned HW = RW / 2;
    // r42-T R1' needs three correction rows (~a_sh, ~b_sh, +2) after
    // the sign-bit split; NOPS=NPART+2 parked rows0[NPART+2] one slot
    // out of bounds and the +2 never entered the ladder (caught by
    // g6lc_t2_mult_corr_eq on the first r43-T simulation).  Under the
    // mutant the extra slot carries the constant '0 it already wrote.
    localparam int unsigned NOPS = NPART + 3;
    localparam int unsigned LEVELS = 2 * $clog2(NOPS); // >= real depth; rows park at 2
    localparam int unsigned LPS = 3;                   // compressor levels per stage (67 rows need 10; extras park at 2)

    logic [AW-1:0] a_u, b_u;
    assign a_u = op_a_s;  // the (XLEN+1)-bit two's-complement pattern, read unsigned
    assign b_u = op_b_s;

    // svt-stage: begin S1
    // ---- S1: operand capture + correction row ----
    // hyp8 r4: the atomic tile products `a_u * b_u[slice]` are replaced by
    // explicit partial-product generation. S1 registers the operands and
    // the modular sign-correction row; S2 forms the AW AND-rows
    // ({AW{b_q[r]}} & a_q) shifted by r and feeds the same CSA ladder.
    // A*B == a_u*b_u - 2**(XLEN+1)*(a_top*B_u + b_top*A_u) (mod 2**RW)
    // unchanged.
    logic [AW-1:0] a_q, b_q;
    // r42-T R1': only the operand sign bits cross the S1 boundary; the two
    // sign-correction summands enter the S2 CSA ladder as AND-masked rows
    // (no carry-propagate add in the operand cycle).
    logic           atop_q, btop_q;
`ifdef G6LC_MUT_T2_MULT_CORR
    // Review mutant: pre-S1 correction CPA, the pre-r42 form.
    logic [AW:0]   corr_d, corr_q;
    assign corr_d = (a_u[AW-1] ? {1'b0, b_u} : '0) + (b_u[AW-1] ? {1'b0, a_u} : '0);
`endif

    logic [G6LCCfg.TRANS_ID_BITS-1:0] tid_sq[7];
    logic                             vld_sq[7];
    fu_op                             op_sq[7];
`ifdef G6LC_MUT_T2_MULT_CLMUL
    // Review mutant: pre-S1 CLMUL tree + shift chain, the pre-r42 form.
    logic [G6LCCfg.XLEN-1:0]          clm_sq[7], clmr_sq[7];
`else
    // r42-T R1: the CLMUL operands (already bit-reversed for CLMULR/H) are
    // registered once at the S1 edge; mult_clmul slices b_q from there.
    // a_q/b_q cannot be reused — they hold the 65-bit sign-extended a_u/b_u.
    logic [G6LCCfg.XLEN-1:0]          clm_a_q, clm_b_q;
`endif

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        a_q       <= '0;
        b_q       <= '0;
        atop_q    <= '0;
        btop_q    <= '0;
        vld_sq[0] <= 1'b0;
        tid_sq[0] <= '0;
        op_sq[0]  <= MUL;
`ifdef G6LC_MUT_T2_MULT_CORR
        corr_q    <= '0;
`endif
`ifdef G6LC_MUT_T2_MULT_CLMUL
        clm_sq[0] <= '0;
        clmr_sq[0]<= '0;
`else
        clm_a_q   <= '0;
        clm_b_q   <= '0;
`endif
      end else begin
        a_q       <= a_u;
        b_q       <= b_u;
        atop_q    <= a_u[AW-1];
        btop_q    <= b_u[AW-1];
        vld_sq[0] <= mult_valid;
        tid_sq[0] <= trans_id_i;
        op_sq[0]  <= operation_i;
`ifdef G6LC_MUT_T2_MULT_CORR
        corr_q    <= corr_d;
`endif
`ifdef G6LC_MUT_T2_MULT_CLMUL
        clm_sq[0] <= clmul_d;
        clmr_sq[0]<= clmulr_d;
`else
        clm_a_q   <= operand_a;
        clm_b_q   <= operand_b;
`endif
      end
    end

    // svt-stage: end S1
    // svt-stage: begin S2
    // ---- S2-S5: four carry-save stages, LPS compressor levels each ----
    // The stage-0 row vector is the shifted product terms plus the folded
    // -corr correction (~corr_sh + 1 participates in the same reduction).
    // Each stage runs LPS local compressor levels from the previous
    // register; no stage propagates a carry.
    logic [RW-1:0] term[NPART];
    for (genvar k = 0; k < NPART; k++) begin : gen_term
      assign term[k] = RW'({AW{b_q[k]}} & a_q) << k;
    end
`ifdef G6LC_MUT_T2_MULT_CORR
    logic [RW-1:0] corr_sh;
    assign corr_sh = RW'(corr_q) << AW;
`else
    // r42-T R1': the two correction summands are formed after the S1
    // register and land as two CSA rows (no pre-S1 CPA).  Algebra:
    // -( (corrA + corrB) << AW ) == ~corrA_sh + ~corrB_sh + 2  (mod 2**RW).
    logic [AW-1:0] corr_a_row, corr_b_row;
    assign corr_a_row = {AW{atop_q}} & b_q;
    assign corr_b_row = {AW{btop_q}} & a_q;
`endif

    logic [RW-1:0] rows0[NOPS];
    for (genvar k = 0; k < NPART; k++) begin : gen_row
      assign rows0[k] = term[k];
    end
`ifdef G6LC_MUT_T2_MULT_CORR
    assign rows0[NPART]   = ~corr_sh;
    assign rows0[NPART+1] = RW'(1);
    assign rows0[NPART+2] = '0;
`else
    assign rows0[NPART]   = ~(RW'(corr_a_row) << AW);
    assign rows0[NPART+1] = ~(RW'(corr_b_row) << AW);
    assign rows0[NPART+2] = RW'(2);
`endif

    logic [RW-1:0] rr_q[4][NOPS];
    // ---- S2: LPS compressor levels; no carry propagates ----
    if (1) begin : gen_red_s0
      wire [RW-1:0] in_row [NOPS];
      for (genvar r = 0; r < NOPS; r++) assign in_row[r] = rows0[r];
      wire [RW-1:0] srows [0:LPS][NOPS];
      for (genvar r = 0; r < NOPS; r++) assign srows[0][r] = in_row[r];
      for (genvar l = 0; l < LPS; l++) begin : gen_reduce
        localparam int unsigned N = compressor_rows(NOPS, l);
        localparam int unsigned GROUPS = N / 3;
        for (genvar g = 0; g < GROUPS; g++) begin : gen_compress
          wire [RW-1:0] a = srows[l][3*g];
          wire [RW-1:0] b = srows[l][3*g+1];
          wire [RW-1:0] c = srows[l][3*g+2];
          assign srows[l+1][2*g] = a ^ b ^ c;
          assign srows[l+1][2*g+1] = ((a & b) | (a & c) | (b & c)) << 1;
        end
        for (genvar r = 0; r < N % 3; r++) begin : gen_remainder
          assign srows[l+1][2*GROUPS+r] = srows[l][3*GROUPS+r];
        end
        for (genvar z = compressor_rows(NOPS, l+1); z < NOPS; z++) begin : gen_unused
          assign srows[l+1][z] = '0;
        end
      end
      // hyp8: per-row always_ff (a delayed write to an unpacked array
      // element inside a procedural loop trips Verilator BLKLOOPINIT once
      // NOPS no longer unrolls).
      for (genvar z = 0; z < NOPS; z++) begin : gen_rreg
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (~rst_ni) rr_q[0][z] <= '0;
          else         rr_q[0][z] <= srows[LPS][z];
        end
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          vld_sq[0+1] <= 1'b0;
          tid_sq[0+1] <= '0;
          op_sq[0+1]  <= MUL;
`ifdef G6LC_MUT_T2_MULT_CLMUL
          clm_sq[0+1] <= '0;
          clmr_sq[0+1]<= '0;
`endif
        end else begin
          vld_sq[0+1] <= vld_sq[0];
          tid_sq[0+1] <= tid_sq[0];
          op_sq[0+1]  <= op_sq[0];
`ifdef G6LC_MUT_T2_MULT_CLMUL
          clm_sq[0+1] <= clm_sq[0];
          clmr_sq[0+1]<= clmr_sq[0];
`endif
        end
      end
    end
    // svt-stage: end S2
    // svt-stage: begin S3
    // ---- S3: LPS compressor levels; no carry propagates ----
    if (1) begin : gen_red_s1
      wire [RW-1:0] in_row [NOPS];
      for (genvar r = 0; r < NOPS; r++) assign in_row[r] = rr_q[0][r];
      wire [RW-1:0] srows [0:LPS][NOPS];
      for (genvar r = 0; r < NOPS; r++) assign srows[0][r] = in_row[r];
      for (genvar l = 0; l < LPS; l++) begin : gen_reduce
        localparam int unsigned N = compressor_rows(NOPS, l);
        localparam int unsigned GROUPS = N / 3;
        for (genvar g = 0; g < GROUPS; g++) begin : gen_compress
          wire [RW-1:0] a = srows[l][3*g];
          wire [RW-1:0] b = srows[l][3*g+1];
          wire [RW-1:0] c = srows[l][3*g+2];
          assign srows[l+1][2*g] = a ^ b ^ c;
          assign srows[l+1][2*g+1] = ((a & b) | (a & c) | (b & c)) << 1;
        end
        for (genvar r = 0; r < N % 3; r++) begin : gen_remainder
          assign srows[l+1][2*GROUPS+r] = srows[l][3*GROUPS+r];
        end
        for (genvar z = compressor_rows(NOPS, l+1); z < NOPS; z++) begin : gen_unused
          assign srows[l+1][z] = '0;
        end
      end
      for (genvar z = 0; z < NOPS; z++) begin : gen_rreg
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (~rst_ni) rr_q[1][z] <= '0;
          else         rr_q[1][z] <= srows[LPS][z];
        end
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          vld_sq[1+1] <= 1'b0;
          tid_sq[1+1] <= '0;
          op_sq[1+1]  <= MUL;
`ifdef G6LC_MUT_T2_MULT_CLMUL
          clm_sq[1+1] <= '0;
          clmr_sq[1+1]<= '0;
`endif
        end else begin
          vld_sq[1+1] <= vld_sq[1];
          tid_sq[1+1] <= tid_sq[1];
          op_sq[1+1]  <= op_sq[1];
`ifdef G6LC_MUT_T2_MULT_CLMUL
          clm_sq[1+1] <= clm_sq[1];
          clmr_sq[1+1]<= clmr_sq[1];
`endif
        end
      end
    end
    // svt-stage: end S3
    // svt-stage: begin S4
    // ---- S4: LPS compressor levels; no carry propagates ----
    if (1) begin : gen_red_s2
      wire [RW-1:0] in_row [NOPS];
      for (genvar r = 0; r < NOPS; r++) assign in_row[r] = rr_q[1][r];
      wire [RW-1:0] srows [0:LPS][NOPS];
      for (genvar r = 0; r < NOPS; r++) assign srows[0][r] = in_row[r];
      for (genvar l = 0; l < LPS; l++) begin : gen_reduce
        localparam int unsigned N = compressor_rows(NOPS, l);
        localparam int unsigned GROUPS = N / 3;
        for (genvar g = 0; g < GROUPS; g++) begin : gen_compress
          wire [RW-1:0] a = srows[l][3*g];
          wire [RW-1:0] b = srows[l][3*g+1];
          wire [RW-1:0] c = srows[l][3*g+2];
          assign srows[l+1][2*g] = a ^ b ^ c;
          assign srows[l+1][2*g+1] = ((a & b) | (a & c) | (b & c)) << 1;
        end
        for (genvar r = 0; r < N % 3; r++) begin : gen_remainder
          assign srows[l+1][2*GROUPS+r] = srows[l][3*GROUPS+r];
        end
        for (genvar z = compressor_rows(NOPS, l+1); z < NOPS; z++) begin : gen_unused
          assign srows[l+1][z] = '0;
        end
      end
      for (genvar z = 0; z < NOPS; z++) begin : gen_rreg
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (~rst_ni) rr_q[2][z] <= '0;
          else         rr_q[2][z] <= srows[LPS][z];
        end
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          vld_sq[2+1] <= 1'b0;
          tid_sq[2+1] <= '0;
          op_sq[2+1]  <= MUL;
`ifdef G6LC_MUT_T2_MULT_CLMUL
          clm_sq[2+1] <= '0;
          clmr_sq[2+1]<= '0;
`endif
        end else begin
          vld_sq[2+1] <= vld_sq[2];
          tid_sq[2+1] <= tid_sq[2];
          op_sq[2+1]  <= op_sq[2];
`ifdef G6LC_MUT_T2_MULT_CLMUL
          clm_sq[2+1] <= clm_sq[2];
          clmr_sq[2+1]<= clmr_sq[2];
`endif
        end
      end
    end
    // svt-stage: end S4
    // svt-stage: begin S5
    // ---- S5: LPS compressor levels; no carry propagates ----
    if (1) begin : gen_red_s3
      wire [RW-1:0] in_row [NOPS];
      for (genvar r = 0; r < NOPS; r++) assign in_row[r] = rr_q[2][r];
      wire [RW-1:0] srows [0:LPS][NOPS];
      for (genvar r = 0; r < NOPS; r++) assign srows[0][r] = in_row[r];
      for (genvar l = 0; l < LPS; l++) begin : gen_reduce
        localparam int unsigned N = compressor_rows(NOPS, l);
        localparam int unsigned GROUPS = N / 3;
        for (genvar g = 0; g < GROUPS; g++) begin : gen_compress
          wire [RW-1:0] a = srows[l][3*g];
          wire [RW-1:0] b = srows[l][3*g+1];
          wire [RW-1:0] c = srows[l][3*g+2];
          assign srows[l+1][2*g] = a ^ b ^ c;
          assign srows[l+1][2*g+1] = ((a & b) | (a & c) | (b & c)) << 1;
        end
        for (genvar r = 0; r < N % 3; r++) begin : gen_remainder
          assign srows[l+1][2*GROUPS+r] = srows[l][3*GROUPS+r];
        end
        for (genvar z = compressor_rows(NOPS, l+1); z < NOPS; z++) begin : gen_unused
          assign srows[l+1][z] = '0;
        end
      end
      for (genvar z = 0; z < NOPS; z++) begin : gen_rreg
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (~rst_ni) rr_q[3][z] <= '0;
          else         rr_q[3][z] <= srows[LPS][z];
        end
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          vld_sq[3+1] <= 1'b0;
          tid_sq[3+1] <= '0;
          op_sq[3+1]  <= MUL;
`ifdef G6LC_MUT_T2_MULT_CLMUL
          clm_sq[3+1] <= '0;
          clmr_sq[3+1]<= '0;
`endif
        end else begin
          vld_sq[3+1] <= vld_sq[3];
          tid_sq[3+1] <= tid_sq[3];
          op_sq[3+1]  <= op_sq[3];
`ifdef G6LC_MUT_T2_MULT_CLMUL
          clm_sq[3+1] <= clm_sq[3];
          clmr_sq[3+1]<= clmr_sq[3];
`endif
        end
      end
    end
    // svt-stage: end S5

    wire [RW-1:0] reduce_sum   = rr_q[3][0];
    wire [RW-1:0] reduce_carry = rr_q[3][1];
    // svt-stage: begin S6
    // ---- S6: first CPA half (low HW bits + carry) ----
    logic [HW-1:0] lo_q;
    logic          lo_cout_q;
`ifdef G6LC_MUT_T2_MULT_CSEL
    // Review mutant: hi CPA deferred to S7, the pre-r42 form.
    logic [HW-1:0] hi_sum_q, hi_carry_q;
`else
    // r42-T R1": carry-select on the high half — both candidates are
    // formed here from the registered reduce rows; S7 only selects on
    // lo_cout_q.
    logic [HW-1:0] hi0_q, hi1_q;
    wire  [HW-1:0] hi0_d = reduce_sum[RW-1:HW] + reduce_carry[RW-1:HW];
    wire  [HW-1:0] hi1_d = hi0_d + HW'(1);
`endif
    wire  [HW:0]   lo_sum = {1'b0, reduce_sum[HW-1:0]} + {1'b0, reduce_carry[HW-1:0]};

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        lo_q        <= '0;
        lo_cout_q   <= 1'b0;
`ifdef G6LC_MUT_T2_MULT_CSEL
        hi_sum_q    <= '0;
        hi_carry_q  <= '0;
`else
        hi0_q       <= '0;
        hi1_q       <= '0;
`endif
        vld_sq[5]   <= 1'b0;
        tid_sq[5]   <= '0;
        op_sq[5]    <= MUL;
`ifdef G6LC_MUT_T2_MULT_CLMUL
        clm_sq[5]   <= '0;
        clmr_sq[5]  <= '0;
`endif
      end else begin
        lo_q        <= lo_sum[HW-1:0];
        lo_cout_q   <= lo_sum[HW];
`ifdef G6LC_MUT_T2_MULT_CSEL
        hi_sum_q    <= reduce_sum[RW-1:HW];
        hi_carry_q  <= reduce_carry[RW-1:HW];
`else
        hi0_q       <= hi0_d;
        hi1_q       <= hi1_d;
`endif
        vld_sq[5]   <= vld_sq[4];
        tid_sq[5]   <= tid_sq[4];
        op_sq[5]    <= op_sq[4];
`ifdef G6LC_MUT_T2_MULT_CLMUL
        clm_sq[5]   <= clm_sq[4];
        clmr_sq[5]  <= clmr_sq[4];
`endif
      end
    end

    // svt-stage: end S6
    // svt-stage: begin S7
    // ---- S7: second CPA half -> full product mod 2**RW ----
    logic [RW-1:0] prod_q;
    logic [G6LCCfg.XLEN-1:0] clmul_s7, clmulr_s7;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        prod_q      <= '0;
        vld_sq[6]   <= 1'b0;
        tid_sq[6]   <= '0;
        op_sq[6]    <= MUL;
`ifdef G6LC_MUT_T2_MULT_CLMUL
        clm_sq[6]   <= '0;
        clmr_sq[6]  <= '0;
`endif
      end else begin
`ifdef G6LC_MUT_T2_MULT_CSEL
        prod_q      <= {hi_sum_q + hi_carry_q + HW'(lo_cout_q), lo_q};
`else
        prod_q      <= {(lo_cout_q ? hi1_q : hi0_q), lo_q};
`endif
        vld_sq[6]   <= vld_sq[5];
        tid_sq[6]   <= tid_sq[5];
        op_sq[6]    <= op_sq[5];
`ifdef G6LC_MUT_T2_MULT_CLMUL
        clm_sq[6]   <= clm_sq[5];
        clmr_sq[6]  <= clmr_sq[5];
`endif
      end
    end
`ifdef G6LC_MUT_T2_MULT_CLMUL
    assign clmul_s7  = clm_sq[6];
    assign clmulr_s7 = clmr_sq[6];
`else
    // r42-T R1: the carry-less product is slice-accumulated across the
    // S2-S7 edges in mult_clmul (one 8-bit slice of b_q per stage, two
    // slices on S2 and S3); it publishes here in vld/tid/op lockstep.
    // svt-pipe: protocol cl valid=clm_vld_o id=clm_tid_o flush=flush_i
    logic                          clm_vld_o;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] clm_tid_o;
    fu_op                          clm_op_o;
    mult_clmul #(
        .G6LCCfg(G6LCCfg),
        .HypCfg (HypCfg)
    ) i_clmul (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        // Liveness is owned by mult.sv's cancellation pipe (the multiplier
        // module itself carries no flush); the slice pipeline need only
        // hold vld/tid/op in lockstep with the data.
        .flush_i     (1'b0),
        .valid_i     (vld_sq[0]),
        .trans_id_i  (tid_sq[0]),
        .operation_i (op_sq[0]),
        .a_i         (clm_a_q),
        .b_i         (clm_b_q),
        .clmul_o     (clmul_s7),
        .clmulr_o    (clmulr_s7),
        .valid_o     (clm_vld_o),
        .trans_id_o  (clm_tid_o),
        .operation_o (clm_op_o)
    );
`endif

    // the module-level clmul_q/clmulr_q registers only exist in the
    // legacy path; tie them off here so no signal is left undriven.
    assign clmul_q  = '0;
    assign clmulr_q = '0;

    // svt-stage: end S7
    // svt-stage: begin S8
    // ---- S8: result/flags -> output register ----
    logic [G6LCCfg.XLEN-1:0] result_d;
    always_comb begin : p_selmux
      unique case (op_sq[6])
        MULH, MULHU, MULHSU: result_d = prod_q[G6LCCfg.XLEN*2-1:G6LCCfg.XLEN];
        CLMUL:               result_d = clmul_s7;
        CLMULH:              result_d = clmulr_s7 >> 1;
        CLMULR:              result_d = clmulr_s7;
        // MUL performs an XLEN-bit x XLEN-bit multiplication and places the
        // lower XLEN bits in the destination register
        default: begin
          if (op_sq[6] == MULW && G6LCCfg.IS_XLEN64) result_d = sext32to64(prod_q[31:0]);
          else result_d = prod_q[G6LCCfg.XLEN-1:0];  // including MUL
        end
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        mult_valid_q  <= '0;
        trans_id_q    <= '0;
        operator_q    <= MUL;
        mult_result_q <= '0;
      end else begin
        mult_valid_q  <= vld_sq[6];
        trans_id_q    <= tid_sq[6];
        operator_q    <= op_sq[6];
        mult_result_q <= result_d;
      end
    end
    // svt-stage: end S8

    //pragma translate_off
    // r42-T equivalence: every rewritten expression keeps its pre-r42
    // reference form next to it and is compared every cycle; the counters
    // print under +equiv_report.
    int unsigned t2_mult_corr_n = 0, t2_mult_csel_n = 0, t2_mult_clmul_n = 0;
    // R1': the two CSA rows must equal the pre-S1 correction CPA shifted.
    logic [AW:0] corr_ref_d;
    assign corr_ref_d = (atop_q ? {1'b0, b_q} : '0) + (btop_q ? {1'b0, a_q} : '0);
    always_ff @(posedge clk_i) begin : p_t2_corr_eq
      if (rst_ni) begin
        t2_mult_corr_n <= t2_mult_corr_n + 1;
        g6lc_t2_mult_corr_eq: assert (
            rows0[NPART] + rows0[NPART+1] + rows0[NPART+2] ===
            (~(RW'(corr_ref_d) << AW) + RW'(1)))
          else $error("multiplier: equiv corr rows");
      end
    end
    // R1": the carry-select pair must equal the deferred hi CPA.
    logic [HW-1:0] hi_sum_ref_q, hi_carry_ref_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        hi_sum_ref_q   <= '0;
        hi_carry_ref_q <= '0;
      end else begin
        hi_sum_ref_q   <= reduce_sum[RW-1:HW];
        hi_carry_ref_q <= reduce_carry[RW-1:HW];
      end
    end
    // r43-T first-sim catch: prod_q is registered one edge AFTER the S6
    // carry-select pair, so the full-product check needs the reference
    // delayed a second edge -- the single-edge form compared prod_q to
    // the previous instruction's reduce halves.
    logic [HW-1:0] hi_sum_ref2_q, hi_carry_ref2_q, lo_ref_q;
    logic          lo_cout_ref_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        hi_sum_ref2_q   <= '0;
        hi_carry_ref2_q <= '0;
        lo_ref_q        <= '0;
        lo_cout_ref_q   <= 1'b0;
      end else begin
        hi_sum_ref2_q   <= hi_sum_ref_q;
        hi_carry_ref2_q <= hi_carry_ref_q;
        lo_ref_q        <= lo_q;
        lo_cout_ref_q   <= lo_cout_q;
      end
    end
    always_ff @(posedge clk_i) begin : p_t2_csel_eq
      if (rst_ni) begin
        t2_mult_csel_n <= t2_mult_csel_n + 1;
`ifndef G6LC_MUT_T2_MULT_CSEL
        g6lc_t2_mult_csel_eq: assert (
            (lo_cout_q ? hi1_q : hi0_q) ===
            (hi_sum_ref_q + hi_carry_ref_q + HW'(lo_cout_q)))
          else $error("multiplier: equiv csel");
`endif
        g6lc_t2_mult_csel_eq2: assert (
            prod_q === {hi_sum_ref2_q + hi_carry_ref2_q +
                        HW'(lo_cout_ref_q), lo_ref_q})
          else $error("multiplier: equiv csel prod");
      end
    end
`ifndef G6LC_MUT_T2_MULT_CLMUL
    // R1: reference = the pre-S1 XOR tree on the current operands, delayed
    // through the same seven edges the old shift chain used.
    logic [G6LCCfg.XLEN-1:0] cm_ref [7];
    logic [G6LCCfg.XLEN-1:0] cm_ref_d;
    always_comb begin : p_clm_ref_tree
      automatic logic [G6LCCfg.XLEN-1:0] acc;
      acc = '0;
      for (int unsigned t = 0; t < G6LCCfg.XLEN; t++)
        acc ^= operand_b[t] ? (operand_a << t) : '0;
      cm_ref_d = acc;
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) cm_ref <= '{default: '0};
      else begin
        cm_ref[0] <= cm_ref_d;
        for (int unsigned s = 1; s < 7; s++) cm_ref[s] <= cm_ref[s-1];
      end
    end
    always_ff @(posedge clk_i) begin : p_t2_clmul_eq
      if (rst_ni) begin
        t2_mult_clmul_n <= t2_mult_clmul_n + 1;
        g6lc_t2_mult_clmul_eq: assert (clmul_s7 === cm_ref[6])
          else $error("multiplier: equiv clmul");
        // clmulr_o is the bit-reverse of the same accumulated product.
        for (int unsigned i = 0; i < G6LCCfg.XLEN; i++) begin
          g6lc_t2_mult_clmulr_eq: assert (clmulr_s7[i] === clmul_s7[G6LCCfg.XLEN-1-i])
            else $error("multiplier: equiv clmulr");
        end
        // Lockstep: the module's record track equals the parent's S7 regs.
        g6lc_t2_mult_clmul_vld: assert (clm_vld_o === vld_sq[6])
          else $error("multiplier: equiv clmul vld");
        g6lc_t2_mult_clmul_tid: assert (clm_tid_o === tid_sq[6])
          else $error("multiplier: equiv clmul tid");
        g6lc_t2_mult_clmul_op: assert (clm_op_o === op_sq[6])
          else $error("multiplier: equiv clmul op");
      end
    end
`endif
    final begin
      if ($test$plusargs("equiv_report")) begin
        $display("[equiv] multiplier corr: checked=%0d", t2_mult_corr_n);
        $display("[equiv] multiplier csel: checked=%0d", t2_mult_csel_n);
        $display("[equiv] multiplier clmul: checked=%0d", t2_mult_clmul_n);
      end
    end
    //pragma translate_on
  end else if (MSTAGES > 1) begin : gen_legacy_pipe
    // ---------------------------------------------------------------
    // MSTAGES in {2,3,4}: the emit's tiled-product form, unchanged
    // (kept for HypDefault-class configurations).
    // ---------------------------------------------------------------
    localparam int unsigned SB = MSTAGES > 2 ? 8 : 16;
    localparam int unsigned NS = G6LCCfg.XLEN / SB;
    localparam int unsigned AW = G6LCCfg.XLEN + 1;
    localparam int unsigned AB = MSTAGES > 2 ? 16 : AW;
    localparam int unsigned NA = (AW + AB - 1) / AB;
    localparam int unsigned NPART = NS * NA;
    localparam int unsigned PW = AB + SB + 1;
    localparam int unsigned RW = G6LCCfg.XLEN * 2;
    logic [AW-1:0] a_u, b_u;
    assign a_u = op_a_s;
    assign b_u = op_b_s;
    logic [PW-1:0] pp_d[NPART], pp_q[NPART];
    logic [AW:0]   corr_d, corr_q;
    for (genvar k = 0; k < NPART; k++) begin : gen_pp
      localparam int unsigned AK = k / NS;
      localparam int unsigned BK = k % NS;
      wire [AB-1:0] a_slice;
      if (AK == NA - 1) begin : gen_a_top
        assign a_slice = AB'(a_u[AW-1:AB*AK]);
      end else begin : gen_a_mid
        assign a_slice = a_u[AB*AK+:AB];
      end
      if (BK == NS - 1) begin : gen_top
        assign pp_d[k] = a_slice * b_u[AW-1:SB*BK];
      end else begin : gen_mid
        assign pp_d[k] = a_slice * b_u[SB*BK+:SB];
      end
    end
    assign corr_d = (a_u[AW-1] ? {1'b0, b_u} : '0) + (b_u[AW-1] ? {1'b0, a_u} : '0);
    logic [RW-1:0] term[NPART];
    for (genvar k = 0; k < NPART; k++) begin : gen_term
      assign term[k] = RW'(pp_q[k]) << (AB * (k / NS) + SB * (k % NS));
    end
    logic [RW-1:0] corr_sh, prod_sum;
    assign corr_sh = RW'(corr_q) << AW;
    if (NS == 8) begin : gen_sum8
      assign prod_sum = ((term[0] + term[1]) + (term[2] + term[3])) +
                        ((term[4] + term[5]) + (term[6] + term[7]));
    end else if (NS == 4) begin : gen_sum4
      assign prod_sum = (term[0] + term[1]) + (term[2] + term[3]);
    end else if (NS == 2) begin : gen_sum2
      assign prod_sum = term[0] + term[1];
    end else begin : gen_sum_n
      // hyp8: balanced pairwise adder tree (log depth). The emit's serial
      // acc fold bills as one adder chain under the structural model; the
      // arithmetic (sum of the NS terms) is identical.
      localparam int unsigned SLVL = (NS > 1) ? $clog2(NS) : 1;
      wire [RW-1:0] stree [0:SLVL][NS];
      for (genvar k = 0; k < NS; k++) begin : gen_st0
        assign stree[0][k] = term[k];
      end
      for (genvar l = 0; l < SLVL; l++) begin : gen_sl
        for (genvar t = 0; t < NS; t++) begin : gen_sn
          if (t < ((NS + (1 << l) - 1) >> (l + 1))) begin : gen_snd
            if ((2 * t + 1) < ((NS + (1 << l) - 1) >> l)) begin : gen_spair
              assign stree[l+1][t] = stree[l][2*t] + stree[l][2*t+1];
            end else begin : gen_sodd
              assign stree[l+1][t] = stree[l][2*t];
            end
          end else begin : gen_spad
            assign stree[l+1][t] = '0;
          end
        end
      end
      assign prod_sum = stree[SLVL][0];
    end

    logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_s1;
    logic                             mult_valid_s1;
    fu_op                             operator_s1;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_sl;
    logic                             mult_valid_sl;
    fu_op                             operator_sl;
    logic [G6LCCfg.XLEN-1:0]          clmul_sl, clmulr_sl;
    logic [G6LCCfg.XLEN-1:0]          clmul_s1, clmulr_s1;
    logic [G6LCCfg.XLEN*2-1:0]        mult_result_d;
    fu_op                             operator_d;

    if (MSTAGES > 2) begin : gen_three_stage
      localparam int unsigned NOPS = NPART + 2;
      localparam int unsigned LEVELS = 2 * $clog2(NOPS);
      wire [RW-1:0] rows [0:LEVELS][NOPS];
      for (genvar k = 0; k < NPART; k++) begin : gen_row
        assign rows[0][k] = term[k];
      end
      assign rows[0][NPART] = ~corr_sh;
      assign rows[0][NPART+1] = RW'(1);
      for (genvar l = 0; l < LEVELS; l++) begin : gen_reduce
        localparam int unsigned N = compressor_rows(NOPS, l);
        localparam int unsigned GROUPS = N / 3;
        for (genvar g = 0; g < GROUPS; g++) begin : gen_compress
          wire [RW-1:0] a = rows[l][3*g];
          wire [RW-1:0] b = rows[l][3*g+1];
          wire [RW-1:0] c = rows[l][3*g+2];
          assign rows[l+1][2*g] = a ^ b ^ c;
          assign rows[l+1][2*g+1] = ((a & b) | (a & c) | (b & c)) << 1;
        end
        for (genvar r = 0; r < N % 3; r++) begin : gen_remainder
          assign rows[l+1][2*GROUPS+r] = rows[l][3*GROUPS+r];
        end
        for (genvar z = compressor_rows(NOPS, l+1); z < NOPS; z++) begin : gen_unused
          assign rows[l+1][z] = '0;
        end
      end
      wire [RW-1:0] reduce_sum = rows[LEVELS][0];
      wire [RW-1:0] reduce_carry = rows[LEVELS][1];
      logic [RW-1:0]                    prod_sum_q, prod_carry_q;
      logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_s2;
      logic                             mult_valid_s2;
      fu_op                             operator_s2;
      logic [G6LCCfg.XLEN-1:0]          clmul_s2, clmulr_s2;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          prod_sum_q    <= '0;
          prod_carry_q  <= '0;
          trans_id_s2   <= '0;
          mult_valid_s2 <= 1'b0;
          operator_s2   <= MUL;
          clmul_s2      <= '0;
          clmulr_s2     <= '0;
        end else begin
          prod_sum_q    <= reduce_sum;
          prod_carry_q  <= reduce_carry;
          trans_id_s2   <= trans_id_s1;
          mult_valid_s2 <= mult_valid_s1;
          operator_s2   <= operator_s1;
          clmul_s2      <= clmul_s1;
          clmulr_s2     <= clmulr_s1;
        end
      end
      if (MSTAGES > 3) begin : gen_four_stage
        localparam int unsigned HW = RW / 2;
        logic [HW:0]                      lo_sum;
        logic [HW-1:0]                    lo_q, hi_sum_q, hi_carry_q;
        logic                             lo_cout_q;
        logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_s3;
        logic                             mult_valid_s3;
        fu_op                             operator_s3;
        logic [G6LCCfg.XLEN-1:0]          clmul_s3, clmulr_s3;
        assign lo_sum = {1'b0, prod_sum_q[HW-1:0]} + {1'b0, prod_carry_q[HW-1:0]};
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (~rst_ni) begin
            lo_q          <= '0;
            lo_cout_q     <= 1'b0;
            hi_sum_q      <= '0;
            hi_carry_q    <= '0;
            trans_id_s3   <= '0;
            mult_valid_s3 <= 1'b0;
            operator_s3   <= MUL;
            clmul_s3      <= '0;
            clmulr_s3     <= '0;
          end else begin
            lo_q          <= lo_sum[HW-1:0];
            lo_cout_q     <= lo_sum[HW];
            hi_sum_q      <= prod_sum_q[RW-1:HW];
            hi_carry_q    <= prod_carry_q[RW-1:HW];
            trans_id_s3   <= trans_id_s2;
            mult_valid_s3 <= mult_valid_s2;
            operator_s3   <= operator_s2;
            clmul_s3      <= clmul_s2;
            clmulr_s3     <= clmulr_s2;
          end
        end
        assign mult_result_d = {hi_sum_q + hi_carry_q + HW'(lo_cout_q), lo_q};
        assign trans_id_sl   = trans_id_s3;
        assign mult_valid_sl = mult_valid_s3;
        assign operator_sl   = operator_s3;
        assign clmul_sl      = clmul_s3;
        assign clmulr_sl     = clmulr_s3;
      end else begin : gen_three_stage_out
        assign mult_result_d = prod_sum_q + prod_carry_q;
        assign trans_id_sl   = trans_id_s2;
        assign mult_valid_sl = mult_valid_s2;
        assign operator_sl   = operator_s2;
        assign clmul_sl      = clmul_s2;
        assign clmulr_sl     = clmulr_s2;
      end
    end else begin : gen_two_stage_out
      assign mult_result_d = prod_sum - corr_sh;
      assign trans_id_sl   = trans_id_s1;
      assign mult_valid_sl = mult_valid_s1;
      assign operator_sl   = operator_s1;
      assign clmul_sl      = clmul_s1;
      assign clmulr_sl     = clmulr_s1;
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        pp_q          <= '{default: '0};
        corr_q        <= '0;
        mult_valid_s1 <= 1'b0;
        trans_id_s1   <= '0;
        operator_s1   <= MUL;
      end else begin
        pp_q          <= pp_d;
        corr_q        <= corr_d;
        mult_valid_s1 <= mult_valid;
        trans_id_s1   <= trans_id_i;
        operator_s1   <= operation_i;
      end
    end

    // legacy path keeps the emit's wide product register + output select
    logic [G6LCCfg.XLEN*2-1:0] mult_result_qx;
    logic [G6LCCfg.XLEN-1:0]   result_o_sel;
    assign operator_d = operator_sl;
    always_comb begin : p_selmux
      unique case (operator_q)
        MULH, MULHU, MULHSU: result_o_sel = mult_result_qx[G6LCCfg.XLEN*2-1:G6LCCfg.XLEN];
        CLMUL:               result_o_sel = clmul_q;
        CLMULH:              result_o_sel = clmulr_q >> 1;
        CLMULR:              result_o_sel = clmulr_q;
        default: begin
          if (operator_q == MULW && G6LCCfg.IS_XLEN64) result_o_sel = sext32to64(mult_result_qx[31:0]);
          else result_o_sel = mult_result_qx[G6LCCfg.XLEN-1:0];
        end
      endcase
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        mult_valid_q  <= '0;
        trans_id_q    <= '0;
        operator_q    <= MUL;
        mult_result_qx <= '0;
      end else begin
        trans_id_q    <= trans_id_sl;
        mult_valid_q  <= mult_valid_sl;
        operator_q    <= operator_d;
        mult_result_qx <= mult_result_d;
      end
    end
    assign mult_result_q = result_o_sel;
    if (G6LCCfg.RVB) begin : gen_clmul_legacy
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          clmul_s1  <= '0;
          clmulr_s1 <= '0;
          clmul_q   <= '0;
          clmulr_q  <= '0;
        end else begin
          clmul_s1  <= clmul_d;
          clmulr_s1 <= clmulr_d;
          clmul_q   <= clmul_sl;
          clmulr_q  <= clmulr_sl;
        end
      end
    end else begin : gen_no_clmul_legacy
      assign clmul_s1  = '0;
      assign clmulr_s1 = '0;
      assign clmul_q   = '0;
      assign clmulr_q  = '0;
    end
  end else begin : gen_one_stage
    // single stage version (MultStages == 1): mult_result_q is a comb
    // alias of the selected product; result_o is a plain continuous assign.
    logic [G6LCCfg.XLEN*2-1:0] prod;
    assign prod = op_a_s * op_b_s;
    always_comb begin : p_selmux
      unique case (operation_i)
        MULH, MULHU, MULHSU: mult_result_q = prod[G6LCCfg.XLEN*2-1:G6LCCfg.XLEN];
        CLMUL:               mult_result_q = clmul_d;
        CLMULH:              mult_result_q = clmulr_d >> 1;
        CLMULR:              mult_result_q = clmulr_d;
        default: begin
          if (operation_i == MULW && G6LCCfg.IS_XLEN64) mult_result_q = sext32to64(prod[31:0]);
          else mult_result_q = prod[G6LCCfg.XLEN-1:0];
        end
      endcase
    end
    assign mult_valid_q  = mult_valid;
    assign trans_id_q    = trans_id_i;
    assign operator_q    = operation_i;
    assign clmul_q       = '0;
    assign clmulr_q      = '0;
  end

  // svt-stage: class S1 value
  // svt-stage: class S2 value
  // svt-stage: class S3 value
  // svt-stage: class S4 value
  // svt-stage: class S5 value
  // svt-stage: class S6 value
  // svt-stage: class S7 value
  // svt-stage: class S8 value
endmodule
