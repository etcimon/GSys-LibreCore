// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_ai_desc_formats
  import g6lc_ai_desc_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,
    input logic submit_i,
    input logic [2:0] fmt_i,
    input logic [1:0] dtype_i,
    input logic [1:0] accmode_i,
    input logic [1:0] ew_i,
    input logic sparse_i,
    input logic [15:0] mask_i,
    output logic [31:0] flags_o,
    output logic [2:0] raw_fmt_o,
    output logic granted_o,
    output logic enums_ok_o,
    output logic ready_o,
    output logic done_o,
    output logic [15:0] status_o,
    output logic check_o,
    output logic gemm_start_o,
    output logic [2:0] gemm_fmt_o
);
  localparam config_pkg::cva6_cfg_t CoreCfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  // Materialize the large packed argument: Verilator 5.008 mis-emits the wide
  // constant when passing CoreCfg directly to check_cfg (C++ array-bounds error).
  config_pkg::cva6_cfg_t checked_cfg /* verilator public_flat_rw */;
  initial begin
    checked_cfg = CoreCfg;
    config_pkg::check_cfg(checked_cfg);
    assert (CoreCfg.AiCfg.MatrixEn &&
            CoreCfg.AiCfg.FormatMask == cva6_config_pkg::ai_cfg.FormatMask)
      else $fatal(1, "core normalization changed the configured MatrixEn/format gate");
    $display("CORE_CONFIG PASS MatrixEn=%0d FormatMask=%0h", CoreCfg.AiCfg.MatrixEn,
             CoreCfg.AiCfg.FormatMask);
  end

  desc_t desc;
  always_comb begin
    desc = '0;
    desc.version = DESC_VERSION;
    desc.op = OP_GEMM;
    desc.m = 1;
    desc.n = 1;
    desc.k = 1;
    desc.ld_ab = 32'h0001_0001;
    desc.ptr_a = 64'h100;
    desc.ptr_b = 64'h200;
    desc.ptr_c = 64'h300;
    desc.flags[FLAG_NUMFMT_SHIFT +: FLAG_NUMFMT_WIDTH] = fmt_i;
    desc.flags[FLAG_DTYPE_SHIFT +: FLAG_DTYPE_WIDTH] = dtype_i;
    desc.flags[FLAG_ACCMODE_SHIFT +: FLAG_ACCMODE_WIDTH] = accmode_i;
    desc.flags[FLAG_EW_SHIFT +: FLAG_EW_WIDTH] = ew_i;
    desc.flags[FLAG_SP24_SHIFT] = sparse_i;
  end
  assign flags_o = desc.flags;
  assign raw_fmt_o = desc_numfmt(desc);
  assign granted_o = desc_numfmt_granted(desc, mask_i);
  assign enums_ok_o = config_pkg::AI_FMT_INT == 0 && config_pkg::AI_FMT_INT4 == 1 &&
      config_pkg::AI_FMT_SP24 == 2 && config_pkg::AI_FMT_FP8_E4M3 == 3 &&
      config_pkg::AI_FMT_FP8_E5M2 == 4 && config_pkg::AI_FMT_FP16 == 5 &&
      config_pkg::AI_FMT_BF16 == 6 && config_pkg::AI_FMT_FP32 == 7 &&
      config_pkg::AiFmtMaskInt8Int4 == 3;

  // Real descriptor engine at the production mask, not a copied acceptance FSM.
  g6lc_ai_desc_engine #(.DtypeMask(16'h0003), .ExecuteGemm(1'b1)) dut (
      .clk_i, .rst_ni, .testmode_i(1'b0), .enable_i(1'b1), .wr_cpl_en_i(1'b0),
      .submit_valid_i(submit_i), .submit_ready_o(ready_o), .submit_qid_i(1'b0),
      .submit_ticket_i(32'd7), .submit_desc_i(desc_to_bits(desc)),
      .done_valid_o(done_o), .done_ticket_o(), .done_status_o(status_o), .done_irq_o(),
      .prog_we_o(), .prog_qid_o(), .prog_base_o(), .prog_limit_o(), .prog_perm_o(),
      .prog_ext_we_i(1'b0), .prog_ext_qid_i(1'b0), .prog_ext_base_i(64'b0),
      .prog_ext_limit_i(64'b0), .prog_ext_perm_i(2'b0),
      .check_req_o(check_o), .check_qid_o(), .check_addr_o(), .check_len_o(),
      .check_need_r_o(), .check_need_w_o(), .check_ok_i(1'b1),
      .busy_o(), .last_status_o(), .wr_start_o(), .wr_addr_o(), .wr_data_o(),
      .wr_ready_i(1'b1), .wr_done_i(1'b1), .wr_err_i(1'b0),
      .gemm_start_o, .gemm_m_o(), .gemm_n_o(), .gemm_k_o(), .gemm_lda_o(), .gemm_ldb_o(),
      .gemm_numfmt_o(gemm_fmt_o), .gemm_ptr_a_o(), .gemm_ptr_b_o(), .gemm_ptr_c_o(),
      .gemm_ready_i(1'b1), .gemm_done_i(1'b1), .gemm_err_i(1'b0)
  );
endmodule
