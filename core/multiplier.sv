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
// Modified by: Etienne Cimon (configurable multiply pipeline and lifetime contract).
//
// Description: Multiplication Unit with one pipeline register
//              This unit relies on retiming features of the synthesizer
//


module multiplier
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    // Subsystem Clock - SUBSYSTEM
    input  logic                             clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                             rst_ni,
    // Multiplier transaction ID - Mult
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_i,
    // Multiplier instruction is valid - Mult
    input  logic                             mult_valid_i,
    // Multiplier operation - Mult
    input  fu_op                             operation_i,
    // A operand - Mult
    input  logic [         CVA6Cfg.XLEN-1:0] operand_a_i,
    // B operand - Mult
    input  logic [         CVA6Cfg.XLEN-1:0] operand_b_i,
    // Multiplier result - Mult
    output logic [         CVA6Cfg.XLEN-1:0] result_o,
    // Mutliplier result is valid - Mult
    output logic                             mult_valid_o,
    // Multiplier transaction ID - Mult
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0] mult_trans_id_o
);
  // Carry-less multiplication
  logic [CVA6Cfg.XLEN-1:0]
      clmul_q, clmul_d, clmulr_q, clmulr_d, operand_a, operand_b, operand_a_rev, operand_b_rev;
  logic clmul_rmode, clmul_hmode;

  if (CVA6Cfg.RVB) begin : gen_bitmanip
    // checking for clmul_rmode and clmul_hmode
    assign clmul_rmode = (operation_i == CLMULR);
    assign clmul_hmode = (operation_i == CLMULH);

    // operand_a and b reverse generator
    for (genvar i = 0; i < CVA6Cfg.XLEN; i++) begin
      assign operand_a_rev[i] = operand_a_i[(CVA6Cfg.XLEN-1)-i];
      assign operand_b_rev[i] = operand_b_i[(CVA6Cfg.XLEN-1)-i];
    end

    // operand_a and operand_b selection
    assign operand_a = (clmul_rmode | clmul_hmode) ? operand_a_rev : operand_a_i;
    assign operand_b = (clmul_rmode | clmul_hmode) ? operand_b_rev : operand_b_i;

    // implementation
    always_comb begin
      clmul_d = '0;
      for (int i = 0; i <= CVA6Cfg.XLEN; i++) begin
        clmul_d = (|((operand_b >> i) & 1)) ? clmul_d ^ (operand_a << i) : clmul_d;
      end
    end

    // clmulr + clmulh result generator
    for (genvar i = 0; i < CVA6Cfg.XLEN; i++) begin
      assign clmulr_d[i] = clmul_d[(CVA6Cfg.XLEN-1)-i];
    end
  end

  // Pipeline register
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_q;
  logic                             mult_valid_q;
  fu_op operator_d, operator_q;
  logic [CVA6Cfg.XLEN*2-1:0] mult_result_d, mult_result_q;

  // control registers
  logic sign_a, sign_b;
  logic mult_valid;

  // control signals
  assign mult_valid_o = mult_valid_q;
  assign mult_trans_id_o = trans_id_q;

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
  logic signed [CVA6Cfg.XLEN:0] op_a_s, op_b_s;
  assign op_a_s = $signed({operand_a_i[CVA6Cfg.XLEN-1] & sign_a, operand_a_i});
  assign op_b_s = $signed({operand_b_i[CVA6Cfg.XLEN-1] & sign_b, operand_b_i});

  // Stage 1 → stage 2 pipeline of the control (two-stage only): the product's
  // valid, trans_id and operator ride one register further.
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_s1;
  logic                             mult_valid_s1;
  fu_op                             operator_s1;

  if (CVA6Cfg.MultStages > 1) begin : gen_two_stage
    // Two-stage multiplier (sv-timing A115). The (XLEN+1)×(XLEN+1) product
    // is the deepest single path of the core (5.3 ns on the Nangate45 study
    // against 3.8 ns for the next cone).
    //
    // Unsigned partial products with a sign correction, not signed ones:
    // synthesis implements a signed `*` by sign-extending both operands to
    // the result width (an 82×82 array for a 65×17 product), which is why
    // the first signed-slice form of this stage measured *deeper* than the
    // one-stage multiplier. With A = A_u − a_top·2^(XLEN+1) and
    // B = B_u − b_top·2^(XLEN+1) (A_u, B_u the unsigned (XLEN+1)-bit
    // patterns, a_top/b_top their top bits):
    //
    //   A·B ≡ A_u·B_u − 2^(XLEN+1)·(a_top·B_u + b_top·A_u)   (mod 2^(2·XLEN))
    //
    // Stage 1 registers the NS = XLEN/16 unsigned products A_u × B_u[slice]
    // (16 bits each, the top slice 17) and the correction a_top·B_u +
    // b_top·A_u (one add, off the product's depth); stage 2 sums the shifted
    // products and subtracts the shifted correction once. Exact modulo
    // 2^(2·XLEN) — all the operations read. One more cycle of MUL latency;
    // the result travels with its trans_id. mult.sv carries cancellation
    // liveness with the pipeline and suppresses killed results before
    // arbitration, including after scoreboard TID reuse.
    //
    // Re-pipelining contract (sv-timing A123/A124). The product's control
    // rides as {mult_valid_s1, trans_id_s1, operator_s1}; cancellation is
    // applied outside this module (mult.sv), so the domain has no kill and
    // no flush of its own. A further stage may be cut at the shifted-product
    // sum; the correction and the operator must travel with it (corr_sh is
    // the shifted correction, re-derived from the carried copy), and the
    // output register's valid / trans_id / operator read the last stage.
    // svt-pipe: protocol mul valid=mult_valid_s1 id=trans_id_s1
    // svt-pipe: carry mul operator_s1,corr_q
    // svt-pipe: result mul valid=mult_valid_q id=trans_id_q operator_d corr_sh
    localparam int unsigned NS = CVA6Cfg.XLEN / 16;
    localparam int unsigned AW = CVA6Cfg.XLEN + 1;   // unsigned pattern of the signed operand
    localparam int unsigned PW = AW + 17;            // (XLEN+1) × 17 unsigned
    localparam int unsigned RW = CVA6Cfg.XLEN * 2;
    logic [AW-1:0] a_u, b_u;
    assign a_u = op_a_s;  // the (XLEN+1)-bit two's-complement pattern, read unsigned
    assign b_u = op_b_s;
    logic [PW-1:0] pp_d[NS], pp_q[NS];
    logic [AW:0]   corr_d, corr_q;                   // a_top·B_u + b_top·A_u
    for (genvar k = 0; k < NS; k++) begin : gen_pp
      if (k == NS - 1) begin : gen_top
        assign pp_d[k] = a_u * b_u[AW-1:16*k];       // 17-bit top slice (sign bit included)
      end else begin : gen_mid
        assign pp_d[k] = a_u * b_u[16*k+:16];
      end
    end
    assign corr_d = (a_u[AW-1] ? {1'b0, b_u} : '0) + (b_u[AW-1] ? {1'b0, a_u} : '0);
    // Stage 2: the shifted products summed as a balanced tree (so the
    // structural model and synthesis both see log depth), minus the
    // correction at bit XLEN+1.
    logic [RW-1:0] term[NS];
    for (genvar k = 0; k < NS; k++) begin : gen_term
      assign term[k] = RW'(pp_q[k]) << (16 * k);
    end
    logic [RW-1:0] corr_sh, prod_sum;
    assign corr_sh = RW'(corr_q) << AW;
    if (NS == 4) begin : gen_sum4
      // svt-pipe: cut-ok mul
      assign prod_sum = (term[0] + term[1]) + (term[2] + term[3]);
    end else if (NS == 2) begin : gen_sum2
      // svt-pipe: cut-ok mul
      assign prod_sum = term[0] + term[1];
    end else begin : gen_sum_n
      always_comb begin
        automatic logic [RW-1:0] acc;
        acc = '0;
        for (int unsigned k = 0; k < NS; k++) acc = acc + term[k];
        prod_sum = acc;
      end
    end
    assign mult_result_d = prod_sum - corr_sh;
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
  end else begin : gen_one_stage
    // single stage version
    assign mult_result_d = op_a_s * op_b_s;
    assign mult_valid_s1 = mult_valid;
    assign trans_id_s1   = trans_id_i;
    assign operator_s1   = operation_i;
  end

  assign operator_d = operator_s1;

  always_comb begin : p_selmux
    unique case (operator_q)
      MULH, MULHU, MULHSU: result_o = mult_result_q[CVA6Cfg.XLEN*2-1:CVA6Cfg.XLEN];
      CLMUL:               result_o = clmul_q;
      CLMULH:              result_o = clmulr_q >> 1;
      CLMULR:              result_o = clmulr_q;
      // MUL performs an CVA6Cfg.XLEN-bit×CVA6Cfg.XLEN-bit multiplication and places the lower CVA6Cfg.XLEN bits in the destination register
      default: begin
        if (operator_q == MULW && CVA6Cfg.IS_XLEN64) result_o = sext32to64(mult_result_q[31:0]);
        else result_o = mult_result_q[CVA6Cfg.XLEN-1:0];  // including MUL
      end
    endcase
  end
  if (CVA6Cfg.RVB) begin
    // The carry-less results take the same number of stages as the product
    // so the operator select at the output sees them together (A115).
    logic [CVA6Cfg.XLEN-1:0] clmul_s1, clmulr_s1;
    if (CVA6Cfg.MultStages > 1) begin : gen_clmul_two_stage
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          clmul_s1  <= '0;
          clmulr_s1 <= '0;
        end else begin
          clmul_s1  <= clmul_d;
          clmulr_s1 <= clmulr_d;
        end
      end
    end else begin : gen_clmul_one_stage
      assign clmul_s1  = clmul_d;
      assign clmulr_s1 = clmulr_d;
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        clmul_q  <= '0;
        clmulr_q <= '0;
      end else begin
        clmul_q  <= clmul_s1;
        clmulr_q <= clmulr_s1;
      end
    end
  end else begin
    assign clmul_q  = '0;
    assign clmulr_q = '0;
  end
  // -----------------------
  // Output pipeline register
  // -----------------------
  // svt-pipe: no-cut
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mult_valid_q  <= '0;
      trans_id_q    <= '0;
      operator_q    <= MUL;
      mult_result_q <= '0;
    end else begin
      // Input silencing
      trans_id_q    <= trans_id_s1;
      // Output Register
      mult_valid_q  <= mult_valid_s1;
      operator_q    <= operator_d;
      mult_result_q <= mult_result_d;
    end
  end
endmodule
