// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zfhmin: flh / fcvt.s.h / fmv.x.h legal with XF16=0; fadd.h stays illegal.
// Mutation +define+G6LC_MUT_ZFHMIN_OFF must fail ZFHMIN_ON.
`include "g6lc_core_types.svh"
module tb_g6lc_zfhmin
  import ariane_pkg::*;
;
  function automatic config_pkg::cva6_cfg_t cfg_of(input bit on);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.GPLEN = 41;
    c.PLEN = 56;
    c.IS_XLEN64 = 1'b1;
    c.TRANS_ID_BITS = 4;
    c.NrHarts = 1;
    c.RVF = 1'b1;
    c.RVD = 1'b1;
    c.FpPresent = 1'b1;
    c.FLen = 64;
    c.XF16 = 1'b0;
`ifdef G6LC_MUT_ZFHMIN_OFF
    c.RVZfhmin = 1'b0;
`else
    c.RVZfhmin = on;
`endif
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C_ON = cfg_of(1'b1);
  localparam config_pkg::cva6_cfg_t C_OFF = cfg_of(1'b0);

  typedef `G6LC_EXCEPTION_T(C_ON) exception_t;
  typedef struct packed {
    logic [1:0] cf;
    logic [C_ON.VLEN-1:0] predict_address;
    logic ckpt_v;
    logic [7:0] ckpt_idx;
    logic is_call;
    logic is_ret;
  } branchpredict_sbe_t;
  typedef `G6LC_IRQ_CTRL_T(C_ON) irq_ctrl_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C_ON) scoreboard_entry_t;
  typedef `G6LC_INTERRUPTS_T(C_ON) interrupts_t;

  logic [31:0] inst;
  scoreboard_entry_t sbe_on, sbe_off;
  logic [31:0] orig_on, orig_off;
  logic cf_on, cf_off;
  irq_ctrl_t irq0;
  assign irq0 = '0;

  decoder #(
    .CVA6Cfg(C_ON),
    .branchpredict_sbe_t(branchpredict_sbe_t),
    .exception_t(exception_t),
    .irq_ctrl_t(irq_ctrl_t),
    .scoreboard_entry_t(scoreboard_entry_t),
    .interrupts_t(interrupts_t)
  ) dut_on (
    .debug_req_i(1'b0), .pc_i('0), .is_compressed_i(1'b0),
    .compressed_instr_i('0), .is_illegal_i(1'b0), .instruction_i(inst),
    .is_macro_instr_i(1'b0), .is_last_macro_instr_i(1'b0),
    .is_double_rd_macro_instr_i(1'b0), .is_zcmt_i(1'b0), .jump_address_i('0),
    .branch_predict_i('0), .ex_i('0), .irq_i('0), .irq_ctrl_i(irq0),
    .priv_lvl_i(riscv::PRIV_LVL_M), .v_i(1'b0), .debug_mode_i(1'b0),
    .fs_i(riscv::Initial), .vfs_i(riscv::Off), .frm_i(3'b000), .vs_i(riscv::Off),
    .tvm_i(1'b0), .tw_i(1'b0), .vtw_i(1'b0), .tsr_i(1'b0), .hu_i(1'b0),
    .mcbie_i(riscv::CBIE_FLUSH), .scbie_i(riscv::CBIE_FLUSH), .hcbie_i(riscv::CBIE_FLUSH),
    .mcbcfe_i(1'b1), .scbcfe_i(1'b1), .hcbcfe_i(1'b1),
    .mcbze_i(1'b1), .scbze_i(1'b1), .hcbze_i(1'b1), .smt_hart_id_i('0),
    .instruction_o(sbe_on), .orig_instr_o(orig_on), .is_control_flow_instr_o(cf_on),
    .debug_from_trigger_i(1'b0)
  );

  decoder #(
    .CVA6Cfg(C_OFF),
    .branchpredict_sbe_t(branchpredict_sbe_t),
    .exception_t(exception_t),
    .irq_ctrl_t(irq_ctrl_t),
    .scoreboard_entry_t(scoreboard_entry_t),
    .interrupts_t(interrupts_t)
  ) dut_off (
    .debug_req_i(1'b0), .pc_i('0), .is_compressed_i(1'b0),
    .compressed_instr_i('0), .is_illegal_i(1'b0), .instruction_i(inst),
    .is_macro_instr_i(1'b0), .is_last_macro_instr_i(1'b0),
    .is_double_rd_macro_instr_i(1'b0), .is_zcmt_i(1'b0), .jump_address_i('0),
    .branch_predict_i('0), .ex_i('0), .irq_i('0), .irq_ctrl_i(irq0),
    .priv_lvl_i(riscv::PRIV_LVL_M), .v_i(1'b0), .debug_mode_i(1'b0),
    .fs_i(riscv::Initial), .vfs_i(riscv::Off), .frm_i(3'b000), .vs_i(riscv::Off),
    .tvm_i(1'b0), .tw_i(1'b0), .vtw_i(1'b0), .tsr_i(1'b0), .hu_i(1'b0),
    .mcbie_i(riscv::CBIE_FLUSH), .scbie_i(riscv::CBIE_FLUSH), .hcbie_i(riscv::CBIE_FLUSH),
    .mcbcfe_i(1'b1), .scbcfe_i(1'b1), .hcbcfe_i(1'b1),
    .mcbze_i(1'b1), .scbze_i(1'b1), .hcbze_i(1'b1), .smt_hart_id_i('0),
    .instruction_o(sbe_off), .orig_instr_o(orig_off), .is_control_flow_instr_o(cf_off),
    .debug_from_trigger_i(1'b0)
  );

  localparam logic [31:0] I_FLH      = 32'h00051507;
  localparam logic [31:0] I_FCVT_S_H = 32'h40258553;
  localparam logic [31:0] I_FMV_X_H  = 32'hE4058553;
  localparam logic [31:0] I_FADD_H   = 32'h04C58553;
  localparam logic [31:0] I_FLW      = 32'h00052507;

  initial begin
    inst = I_FLH;
    #1;
    if (sbe_on.ex.valid || sbe_on.fu != LOAD || sbe_on.op != FLH)
      $fatal(1, "ZFHMIN_ON flh fu=%0d op=%0d ex=%0d", sbe_on.fu, sbe_on.op, sbe_on.ex.valid);
    if (!sbe_off.ex.valid)
      $fatal(1, "ZFHMIN_OFF flh not illegal");
    inst = I_FCVT_S_H;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FCVT_F2F)
      $fatal(1, "ZFHMIN_ON fcvt.s.h");
    inst = I_FMV_X_H;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FMV_F2X)
      $fatal(1, "ZFHMIN_ON fmv.x.h");
    inst = I_FADD_H;
    #1;
    if (!sbe_on.ex.valid)
      $fatal(1, "ZFHMIN_ON fadd.h must stay illegal (not full Zfh)");
    inst = I_FLW;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FLW)
      $fatal(1, "live flw broken");
    $display("PASS tb_g6lc_zfhmin");
    $finish;
  end
endmodule
