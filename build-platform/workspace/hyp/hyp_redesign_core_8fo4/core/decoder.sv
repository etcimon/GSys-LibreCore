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
// File:   issue_read_operands.sv
// Author: Florian Zaruba <zarubaf@ethz.ch>
// Modified by: Etienne Cimon
// Date:   8.4.2017
//
// Copyright (C) 2017 ETH Zurich, University of Bologna
// All rights reserved.
//
// Description: Issues instruction from the scoreboard and fetches the operands
//              This also includes all the forwarding logic
//

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: OoO dispatch fields, hypervisor instruction decode, Zb* and CMO decode.
// The upstream notice above is prose and declares no SPDX identifier, so the
// outbound offer is stated here as the file's single SPDX tag. See REUSE.toml.
// Etienne Cimon offers this file AS A WHOLE under:
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module decoder
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type branchpredict_sbe_t = logic,
    parameter type exception_t = logic,
    parameter type irq_ctrl_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type interrupts_t = logic,
    parameter interrupts_t INTERRUPTS = '0
) (
    // Debug (async) request - SUBSYSTEM
    input logic debug_req_i,
    // PC from fetch stage - FRONTEND
    input logic [G6LCCfg.VLEN-1:0] pc_i,
    // Is a compressed instruction - compressed_decoder
    input logic is_compressed_i,
    // Compressed form of instruction - FRONTEND
    input logic [15:0] compressed_instr_i,
    // Illegal compressed instruction - compressed_decoder
    input logic is_illegal_i,
    // Instruction from fetch stage - FRONTEND
    input logic [31:0] instruction_i,
    // Is a macro instruction - macro_decoder
    input logic is_macro_instr_i,
    // Is a last macro instruction - macro_decoder
    input logic is_last_macro_instr_i,
    // Is mvsa01/mva01s macro instruction - macro_decoder
    input logic is_double_rd_macro_instr_i,
    // Zcmt instruction - FRONTEND
    input logic is_zcmt_i,
    // Jump address - zcmt_decoder
    input logic [G6LCCfg.XLEN-1:0] jump_address_i,
    // Is a branch predict instruction - FRONTEND
    input branchpredict_sbe_t branch_predict_i,
    // If an exception occurred in fetch stage - FRONTEND
    input exception_t ex_i,
    // Level sensitive (async) interrupts - SUBSYSTEM
    input logic [1:0] irq_i,
    // Interrupt control status - CSR_REGFILE
    input irq_ctrl_t irq_ctrl_i,
    // Current privilege level - CSR_REGFILE
    input riscv::priv_lvl_t priv_lvl_i,
    // Current virtualization mode - CSR_REGFILE
    input logic v_i,
    // Is debug mode - CSR_REGFILE
    input logic debug_mode_i,
    // Floating point extension status - CSR_REGFILE
    input riscv::xs_t fs_i,
    // Virtual floating point extension status - CSR_REGFILE
    input riscv::xs_t vfs_i,
    // Floating-point dynamic rounding mode - CSR_REGFILE
    input logic [2:0] frm_i,
    // Vector extension status - CSR_REGFILE
    input riscv::xs_t vs_i,
    // Trap virtual memory - CSR_REGFILE
    input logic tvm_i,
    // Timeout wait - CSR_REGFILE
    input logic tw_i,
    // Virtual timeout wait - CSR_REGFILE
    input logic vtw_i,
    // Trap sret - CSR_REGFILE
    input logic tsr_i,
    // Hypervisor user mode - CSR_REGFILE
    input logic hu_i,
    // machine-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t mcbie_i,
    // supervisor-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t scbie_i,
    // hypervisor-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t hcbie_i,
    // machine-mode clean/flush cache block enable - CSR_REGFILE
    input logic mcbcfe_i,
    // supervisor-mode clean/flush cache block enable - CSR_REGFILE
    input logic scbcfe_i,
    // hypervisor-mode clean/flush cache block enable - CSR_REGFILE
    input logic hcbcfe_i,
    // machine-mode cbo.zero enable (menvcfg.CBZE) - CSR_REGFILE
    input logic mcbze_i,
    // supervisor-mode cbo.zero enable (senvcfg.CBZE) - CSR_REGFILE
    input logic scbze_i,
    // hypervisor-mode cbo.zero enable (henvcfg.CBZE) - CSR_REGFILE
    input logic hcbze_i,
    // U6.1 SMT active thread tag (0 when NrHarts==1) - SMT
    input logic [((G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts))-1:0] smt_hart_id_i,
    // Instruction to be added to scoreboard entry - ISSUE_STAGE
    output scoreboard_entry_t instruction_o,
    // Instruction - ISSUE_STAGE
    output logic [31:0] orig_instr_o,
    // Is a control flow instruction - ISSUE_STAGE
    output logic is_control_flow_instr_o,
    input debug_from_trigger_i
);
  // hyp8: the single combinational decoder is now the composition
  // g6lc_decode_s1 -> g6lc_decode_s2 -> g6lc_decode_s3 (all combinational;
  // this module stays a pure comb wrapper with the original port list so
  // every instantiation site is unchanged). D1 packs the post-expansion /
  // post-sequencer context, D2 does the instruction-bit decode, D3 applies
  // privilege/CSR legality and assembles the scoreboard entry + exception.

  logic [31:0]   d1_instr;
  logic [15:0]   d1_cinstr;
  logic          d1_is_compressed;
  logic          d1_is_illegal;
  logic          d1_is_macro;
  logic          d1_is_last_macro;
  logic          d1_is_double_macro;
  logic          d1_is_zcmt;
  logic [G6LCCfg.XLEN-1:0] d1_jump_address;
  branchpredict_sbe_t      d1_bp;
  exception_t              d1_ex;
  logic [G6LCCfg.VLEN-1:0] d1_pc;
  logic [((G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts))-1:0] d1_hart;

  scoreboard_entry_t d2_sbe;
  logic [31:0]       d2_instr;
  logic [31:0]       d2_tinst;
  logic [15:0]       d2_cinstr;
  logic              d2_is_compressed;
  logic              d2_is_illegal;
  exception_t        d2_ex;
  logic              d2_ecall;
  logic              d2_ebreak;
  logic              d2_frm_req;
  logic              d2_check_fprm;
  logic              d2_fp_hit;
  logic              d2_illegal;
  logic              d2_cf;

  g6lc_decode_s1 #(
      .G6LCCfg            (G6LCCfg),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .exception_t        (exception_t)
  ) i_s1 (
      .instruction_i               (instruction_i),
      .compressed_instr_i          (compressed_instr_i),
      .is_compressed_i             (is_compressed_i),
      .is_illegal_i                (is_illegal_i),
      .is_macro_instr_i            (is_macro_instr_i),
      .is_last_macro_instr_i       (is_last_macro_instr_i),
      .is_double_rd_macro_instr_i  (is_double_rd_macro_instr_i),
      .is_zcmt_i                   (is_zcmt_i),
      .jump_address_i              (jump_address_i),
      .branch_predict_i            (branch_predict_i),
      .ex_i                        (ex_i),
      .pc_i                        (pc_i),
      .smt_hart_id_i               (smt_hart_id_i),
      .instruction_o               (d1_instr),
      .compressed_instr_o          (d1_cinstr),
      .is_compressed_o             (d1_is_compressed),
      .is_illegal_o                (d1_is_illegal),
      .is_macro_instr_o            (d1_is_macro),
      .is_last_macro_instr_o       (d1_is_last_macro),
      .is_double_rd_macro_instr_o  (d1_is_double_macro),
      .is_zcmt_o                   (d1_is_zcmt),
      .jump_address_o              (d1_jump_address),
      .branch_predict_o            (d1_bp),
      .ex_o                        (d1_ex),
      .pc_o                        (d1_pc),
      .smt_hart_id_o               (d1_hart)
  );

  g6lc_decode_s2 #(
      .G6LCCfg            (G6LCCfg),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .exception_t        (exception_t),
      .scoreboard_entry_t (scoreboard_entry_t)
  ) i_s2 (
      .instruction_i               (d1_instr),
      .compressed_instr_i          (d1_cinstr),
      .is_compressed_i             (d1_is_compressed),
      .is_illegal_i                (d1_is_illegal),
      .is_macro_instr_i            (d1_is_macro),
      .is_last_macro_instr_i       (d1_is_last_macro),
      .is_double_rd_macro_instr_i  (d1_is_double_macro),
      .is_zcmt_i                   (d1_is_zcmt),
      .jump_address_i              (d1_jump_address),
      .branch_predict_i            (d1_bp),
      .ex_i                        (d1_ex),
      .pc_i                        (d1_pc),
      .smt_hart_id_i               (d1_hart),
      .sbe_o                       (d2_sbe),
      .instr_o                     (d2_instr),
      .tinst_o                     (d2_tinst),
      .compressed_instr_o          (d2_cinstr),
      .is_compressed_o             (d2_is_compressed),
      .is_illegal_o                (d2_is_illegal),
      .ex_o                        (d2_ex),
      .ecall_o                     (d2_ecall),
      .ebreak_o                    (d2_ebreak),
      .frm_req_o                   (d2_frm_req),
      .check_fprm_o                (d2_check_fprm),
      .fp_hit_o                    (d2_fp_hit),
      .illegal_o                   (d2_illegal),
      .cf_o                        (d2_cf)
  );

  g6lc_decode_s3 #(
      .G6LCCfg            (G6LCCfg),
      .exception_t        (exception_t),
      .irq_ctrl_t         (irq_ctrl_t),
      .scoreboard_entry_t (scoreboard_entry_t),
      .interrupts_t       (interrupts_t),
      .INTERRUPTS         (INTERRUPTS)
  ) i_s3 (
      .dec_i                  (d2_sbe),
      .instr_i                (d2_instr),
      .tinst_i                (d2_tinst),
      .compressed_instr_i     (d2_cinstr),
      .is_compressed_i        (d2_is_compressed),
      .is_illegal_i           (d2_is_illegal),
      .ex_i                   (d2_ex),
      .pc_i                   (pc_i),
      .ecall_i                (d2_ecall),
      .ebreak_i               (d2_ebreak),
      .frm_req_i              (d2_frm_req),
      .check_fprm_i           (d2_check_fprm),
      .fp_hit_i               (d2_fp_hit),
      .illegal_i              (d2_illegal),
      .cf_i                   (d2_cf),
      .debug_req_i            (debug_req_i),
      .priv_lvl_i             (priv_lvl_i),
      .v_i                    (v_i),
      .debug_mode_i           (debug_mode_i),
      .fs_i                   (fs_i),
      .vfs_i                  (vfs_i),
      .frm_i                  (frm_i),
      .vs_i                   (vs_i),
      .tvm_i                  (tvm_i),
      .tw_i                   (tw_i),
      .vtw_i                  (vtw_i),
      .tsr_i                  (tsr_i),
      .hu_i                   (hu_i),
      .mcbie_i                (mcbie_i),
      .scbie_i                (scbie_i),
      .hcbie_i                (hcbie_i),
      .mcbcfe_i               (mcbcfe_i),
      .scbcfe_i               (scbcfe_i),
      .hcbcfe_i               (hcbcfe_i),
      .mcbze_i                (mcbze_i),
      .scbze_i                (scbze_i),
      .hcbze_i                (hcbze_i),
      .irq_i                  (irq_i),
      .irq_ctrl_i             (irq_ctrl_i),
      .debug_from_trigger_i   (debug_from_trigger_i),
      .instruction_o          (instruction_o),
      .orig_instr_o           (orig_instr_o),
      .is_control_flow_instr_o(is_control_flow_instr_o)
  );
endmodule
