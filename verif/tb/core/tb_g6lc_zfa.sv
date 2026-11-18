// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zfa decode: fminm/fleq/fli/fround/fcvtmod legal with RVZfa; off-knob illegal.
// Mutation +define+G6LC_MUT_ZFA_OFF must fail ZFA_ON.
`include "g6lc_core_types.svh"
module tb_g6lc_zfa
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
`ifdef G6LC_MUT_ZFA_OFF
    c.RVZfa = 1'b0;
`else
    c.RVZfa = on;
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

  localparam logic [31:0] I_FMINM_S    = 32'h28002053;
  localparam logic [31:0] I_FMAXM_S    = 32'h28003053;
  localparam logic [31:0] I_FLEQ_S     = 32'hA0004053;
  localparam logic [31:0] I_FLTQ_S     = 32'hA0005053;
  localparam logic [31:0] I_FLI_S      = 32'hF0100053;
  localparam logic [31:0] I_FROUND_S   = 32'h40400053;
  localparam logic [31:0] I_FROUNDNX_S = 32'h40500053;
  localparam logic [31:0] I_FCVTMOD    = 32'hC2801053;
  localparam logic [31:0] I_FMIN_S     = 32'h28000053;
  localparam logic [31:0] I_FADD_S     = 32'h00100053;
  localparam logic [31:0] I_FMV_W_X    = 32'hF0000053;
  localparam logic [31:0] I_FMINM_H    = 32'h2C002053;

  initial begin
    inst = I_FMINM_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.fu != FPU || sbe_on.op != FMIN_MAX)
      $fatal(1, "ZFA_ON fminm.s fu=%0d op=%0d ex=%0d", sbe_on.fu, sbe_on.op, sbe_on.ex.valid);
    if (!sbe_off.ex.valid)
      $fatal(1, "ZFA_ON fminm.s must be illegal with knob off");
    inst = I_FMAXM_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FMIN_MAX)
      $fatal(1, "ZFA_ON fmaxm.s");
    inst = I_FLEQ_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FCMP)
      $fatal(1, "ZFA_ON fleq.s");
    if (!sbe_off.ex.valid)
      $fatal(1, "ZFA_ON fleq.s must be illegal with knob off");
    inst = I_FLTQ_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FCMP)
      $fatal(1, "ZFA_ON fltq.s");
    inst = I_FLI_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FLI || !sbe_on.use_zimm)
      $fatal(1, "ZFA_ON fli.s op=%0d zimm=%0d ex=%0d", sbe_on.op, sbe_on.use_zimm, sbe_on.ex.valid);
    if (!sbe_off.ex.valid)
      $fatal(1, "ZFA_ON fli.s must be illegal with knob off");
    inst = I_FROUND_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FROUND)
      $fatal(1, "ZFA_ON fround.s op=%0d ex=%0d", sbe_on.op, sbe_on.ex.valid);
    if (!sbe_off.ex.valid)
      $fatal(1, "ZFA_ON fround.s must be illegal with knob off");
    inst = I_FROUNDNX_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FROUNDNX)
      $fatal(1, "ZFA_ON froundnx.s");
    inst = I_FCVTMOD;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FCVTMOD)
      $fatal(1, "ZFA_ON fcvtmod.w.d op=%0d ex=%0d", sbe_on.op, sbe_on.ex.valid);
    if (!sbe_off.ex.valid)
      $fatal(1, "ZFA_ON fcvtmod.w.d must be illegal with knob off");
    inst = I_FMIN_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FMIN_MAX)
      $fatal(1, "ZFA_ON live fmin.s broken");
    inst = I_FADD_S;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FADD)
      $fatal(1, "ZFA_ON live fadd.s broken");
    inst = I_FMV_W_X;
    #1;
    if (sbe_on.ex.valid || sbe_on.op != FMV_X2F)
      $fatal(1, "ZFA_ON live fmv.w.x broken");
    inst = I_FMINM_H;
    #1;
    if (!sbe_on.ex.valid)
      $fatal(1, "ZFA_ON fminm.h must stay illegal without XF16");
    $display("PASS tb_g6lc_zfa");
    $finish;
  end
endmodule
