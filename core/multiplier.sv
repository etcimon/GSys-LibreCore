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
    // Two-stage multiplier (sv-timing A115): the (XLEN+1)×(XLEN+1) product
    // is the deepest single path of the core (5.3 ns on the Nangate45 study
    // against 3.8 ns for the next cone). B is cut into NS = XLEN/16 slices
    // — 16 unsigned bits each, the top one 17 bits carrying the sign — and
    // the NS partial products A × B_k are registered; the second stage sums
    // the shifted products once. Exact: Σ_k (A × B_k) << 16k == A × B for
    // every signedness the sign bits above encode. Area: NS × (XLEN+18)
    // flops and NS−1 extra adders; the partial-product trees are the same
    // work the one-stage multiplier did. One more cycle of MUL latency; the
    // result still travels with its trans_id, so no other contract changes
    // (mult.sv arbitrates on `mult_valid`, the scoreboard drops a late
    // result after a flush by its `issued` guard).
    localparam int unsigned NS = CVA6Cfg.XLEN / 16;
    localparam int unsigned PW = CVA6Cfg.XLEN + 18;  // (XLEN+1) × 17 signed
    // unpacked so an element keeps its signedness (a packed-array element
    // select is unsigned by the LRM)
    logic signed [PW-1:0] pp_d[NS], pp_q[NS];
    for (genvar k = 0; k < NS; k++) begin : gen_pp
      if (k == NS - 1) begin : gen_top
        // the top slice: 16 magnitude bits plus the operand's sign bit
        logic signed [16:0] b_k;
        assign b_k = $signed(op_b_s[CVA6Cfg.XLEN:16*k]);
        assign pp_d[k] = op_a_s * b_k;
      end else begin : gen_mid
        logic signed [16:0] b_k;
        assign b_k = $signed({1'b0, op_b_s[16*k+:16]});
        assign pp_d[k] = op_a_s * b_k;
      end
    end
    // Stage 2: one sum of the sign-extended, shifted partial products. The
    // reduction is written as a balanced tree so the structural model and
    // synthesis both see log depth (a serial sum would read NS adders deep).
    logic signed [CVA6Cfg.XLEN*2+1:0] term[NS];
    for (genvar k = 0; k < NS; k++) begin : gen_term
      assign term[k] = (CVA6Cfg.XLEN*2+2)'(pp_q[k]) <<< (16 * k);
    end
    if (NS == 4) begin : gen_sum4
      assign mult_result_d = (CVA6Cfg.XLEN*2)'((term[0] + term[1]) + (term[2] + term[3]));
    end else if (NS == 2) begin : gen_sum2
      assign mult_result_d = (CVA6Cfg.XLEN*2)'(term[0] + term[1]);
    end else begin : gen_sum_n
      always_comb begin
        automatic logic signed [CVA6Cfg.XLEN*2+1:0] acc;
        acc = '0;
        for (int unsigned k = 0; k < NS; k++) acc = acc + term[k];
        mult_result_d = (CVA6Cfg.XLEN*2)'(acc);
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        pp_q          <= '{default: '0};
        mult_valid_s1 <= 1'b0;
        trans_id_s1   <= '0;
        operator_s1   <= MUL;
      end else begin
        pp_q          <= pp_d;
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
