// hyp8 provenance: REWRITTEN (split of <src>/core/decoder.sv at the 8-FO4
// budget; all decode arms carried over verbatim)
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
// Modifications (c) 2026 Etienne Cimon: split into three combinational decode
// stages for the hyp8 8-FO4 pipeline (decoder T1 D=63.2, rank 4 front-end
// depth). Behaviour is identical to the original single-comb decoder.
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// g6lc_decode_s1 (D1): fetch/decode context assembly. The upstream decoder's
// inputs are already the post-expansion, post-sequencer word; this stage just
// packs that context so the identical record can be registered in the
// pipelined id_stage (HypCfg.DecodeStages == 3) or wired straight through in
// the combinational decoder composition. Pure wiring, no decode logic.

module g6lc_decode_s1 #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type branchpredict_sbe_t = logic,
    parameter type exception_t = logic
) (
    input  logic [31:0]                     instruction_i,
    input  logic [15:0]                     compressed_instr_i,
    input  logic                            is_compressed_i,
    input  logic                            is_illegal_i,
    input  logic                            is_macro_instr_i,
    input  logic                            is_last_macro_instr_i,
    input  logic                            is_double_rd_macro_instr_i,
    input  logic                            is_zcmt_i,
    input  logic [G6LCCfg.XLEN-1:0]         jump_address_i,
    input  branchpredict_sbe_t              branch_predict_i,
    input  exception_t                      ex_i,
    input  logic [G6LCCfg.VLEN-1:0]         pc_i,
    input  logic [((G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts))-1:0]                smt_hart_id_i,
    output logic [31:0]                     instruction_o,
    output logic [15:0]                     compressed_instr_o,
    output logic                            is_compressed_o,
    output logic                            is_illegal_o,
    output logic                            is_macro_instr_o,
    output logic                            is_last_macro_instr_o,
    output logic                            is_double_rd_macro_instr_o,
    output logic                            is_zcmt_o,
    output logic [G6LCCfg.XLEN-1:0]         jump_address_o,
    output branchpredict_sbe_t              branch_predict_o,
    output exception_t                      ex_o,
    output logic [G6LCCfg.VLEN-1:0]         pc_o,
    output logic [((G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts))-1:0]                smt_hart_id_o
);
  assign instruction_o                = instruction_i;
  assign compressed_instr_o           = compressed_instr_i;
  assign is_compressed_o              = is_compressed_i;
  assign is_illegal_o                 = is_illegal_i;
  assign is_macro_instr_o             = is_macro_instr_i;
  assign is_last_macro_instr_o        = is_last_macro_instr_i;
  assign is_double_rd_macro_instr_o   = is_double_rd_macro_instr_i;
  assign is_zcmt_o                    = is_zcmt_i;
  assign jump_address_o               = jump_address_i;
  assign branch_predict_o             = branch_predict_i;
  assign ex_o                         = ex_i;
  assign pc_o                         = pc_i;
  assign smt_hart_id_o                = smt_hart_id_i;
endmodule
