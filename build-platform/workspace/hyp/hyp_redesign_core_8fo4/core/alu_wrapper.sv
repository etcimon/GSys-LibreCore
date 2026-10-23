// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// - propagate HypCfg into the staggered ALU instances;
// - new sideband: fwd_a_i/fwd_b_i (A1-capture operand select) and
//   alu_fwd_low_o/alu_fwd_tid_o taps on the primary ALU.
// Copyright 2025 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Original authors: Gianmarco Ottavi,  University of Bologna
//                   Riccardo Tedeschi, University of Bologna
// Description: ALU(s) wrapper — NrALUs instances (1 scalar, 2..4 multi-issue)

module alu_wrapper
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter type fu_data_t = logic
) (
    input  logic                                               clk_i,
    input  logic                                               rst_ni,
    input  alu_bypass_t                                        alu_bypass_i,
    input  fu_data_t    [G6LCCfg.NrALUs-1:0]                   fu_data_i,
    // hyp8: A1-capture operand selects for the primary ALU (driven by
    // the IRO spec-arm forward; alu2/extra ALUs take no forward).
    input  logic        [3:0]                                  fwd_a_i,
    input  logic        [3:0]                                  fwd_b_i,
    // hyp8: per-ALU result ownership of the op in fu_data_i -- an issued
    // ALU result, not merely a decoded packet on the port. Branch-compare
    // / CSR / AES-class ops keep their A1 registers and branch path but
    // must not claim an A3 result slot.
    input  logic        [G6LCCfg.NrALUs-1:0]                   result_valid_i,
    output logic        [G6LCCfg.NrALUs-1:0][G6LCCfg.XLEN-1:0] result_o,
    output logic                                               alu_branch_res_o,
    // hyp8: primary-ALU A1 taps (low-32 forward value + its tid).
    output logic        [31:0]                                 alu_fwd_low_o,
    output logic        [G6LCCfg.TRANS_ID_BITS-1:0]            alu_fwd_tid_o,
    // hyp8: tid of the op in the registered A2 result slot (the result_q
    // forward source identity).
    output logic        [G6LCCfg.TRANS_ID_BITS-1:0]            alu_fwd_qtid_o,
    // hyp8: tid of the op in the registered A3 result slot (result3_q,
    // the sel_r forward source; equals qtid when AluStages==2).
    output logic        [G6LCCfg.TRANS_ID_BITS-1:0]            alu_fwd_rtid_o,
    output logic        [G6LCCfg.TRANS_ID_BITS-1:0]            alu_fwd_htid_o,
    // hyp8: slot-class taps -- the op in the result_q / result3_q slot
    // is A3-class (LAT_ALU_FULL); the FLU lane picks +2 vs +3.
    output logic                                               alu_s2_a3_o,
    output logic                                               alu_s3_a3_o
);

  // hyp8: the pre-register A2 result is the closest analogue of the
  // original same-cycle result_o for the alu2 cross-bypass.
  logic [G6LCCfg.XLEN-1:0] alu0_result_d;

  // Primary ALU always present (handles branch compare on port 0)
  alu #(
      .G6LCCfg  (G6LCCfg),
      .HypCfg   (HypCfg),
      .HasBranch(1'b1),
      .fu_data_t(fu_data_t)
  ) alu_i (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .fu_data_i       (fu_data_i[0]),
      .result_valid_i  (result_valid_i[0]),
      .fu_data_cpop_i  (fu_data_i[0]),
      .result_o        (result_o[0]),
      .alu_branch_res_o(alu_branch_res_o),
      .alu_fwd_low_o   (alu_fwd_low_o),
      .alu_fwd_tid_o   (alu_fwd_tid_o),
      .alu_fwd_qtid_o  (alu_fwd_qtid_o),
      .alu_fwd_rtid_o  (alu_fwd_rtid_o),
      .alu_fwd_htid_o  (alu_fwd_htid_o),
      .alu_s2_a3_o     (alu_s2_a3_o),
      .alu_s3_a3_o     (alu_s3_a3_o),
      .alu_result_d_o  (alu0_result_d),
      .fwd_a_i         (fwd_a_i),
      .fwd_b_i         (fwd_b_i)
  );

  // Secondary ALU with optional rs1/rs2 bypass from primary (dual-issue path)
  if (G6LCCfg.NrALUs >= 2) begin : gen_alu2
    fu_data_t fu_data_bypass;

    always_comb begin
      fu_data_bypass = fu_data_i[1];
      // hyp8: result_o[0] is the registered A2 result under the staggered
      // ALU; the original bypass wanted the same-cycle analogue -> use
      // the pre-register A2-comb tap (one cycle after alu0's input).
      if (alu_bypass_i.rs1_from_rd) begin
        fu_data_bypass.operand_a = alu0_result_d;
      end
      if (alu_bypass_i.rs2_from_rd) begin
        fu_data_bypass.operand_b = alu0_result_d;
      end
    end

    alu #(
        .G6LCCfg  (G6LCCfg),
        .HypCfg   (HypCfg),
        .HasBranch(1'b0),
        .fu_data_t(fu_data_t)
    ) alu2_i (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),
        .fu_data_i       (fu_data_bypass),
        .result_valid_i  (result_valid_i[1]),
        .fu_data_cpop_i  (fu_data_i[1]),
        .result_o        (result_o[1]),
        .alu_branch_res_o(  /* Unconnected */),
        .alu_fwd_low_o   (  /* Unconnected */),
        .alu_fwd_tid_o   (  /* Unconnected */),
        .alu_fwd_qtid_o  (  /* Unconnected */),
        .alu_fwd_rtid_o  (  /* Unconnected */),
        .alu_fwd_htid_o  (  /* Unconnected */),
        .alu_s2_a3_o     (  /* Unconnected */),
        .alu_s3_a3_o     (  /* Unconnected */),
        .alu_result_d_o  (  /* Unconnected */),
        .fwd_a_i         ('0),
        .fwd_b_i         ('0)
    );
  end

  // Extra ALUs for wider multi-issue (no cross-bypass; area-cheap precursor)
  for (genvar a = 2; a < G6LCCfg.NrALUs; a++) begin : gen_extra_alu
    alu #(
        .G6LCCfg  (G6LCCfg),
        .HypCfg   (HypCfg),
        .HasBranch(1'b0),
        .fu_data_t(fu_data_t)
    ) alu_extra_i (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),
        .fu_data_i       (fu_data_i[a]),
        .result_valid_i  (result_valid_i[a]),
        .fu_data_cpop_i  (fu_data_i[a]),
        .result_o        (result_o[a]),
        .alu_branch_res_o(  /* Unconnected */),
        .alu_fwd_low_o   (  /* Unconnected */),
        .alu_fwd_tid_o   (  /* Unconnected */),
        .alu_fwd_qtid_o  (  /* Unconnected */),
        .alu_fwd_rtid_o  (  /* Unconnected */),
        .alu_fwd_htid_o  (  /* Unconnected */),
        .alu_s2_a3_o     (  /* Unconnected */),
        .alu_s3_a3_o     (  /* Unconnected */),
        .alu_result_d_o  (  /* Unconnected */),
        .fwd_a_i         ('0),
        .fwd_b_i         ('0)
    );
  end

endmodule
