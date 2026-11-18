// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zawrs decode: WRS.NTO/STO when ZawrsEn=1; illegal when off.
// Mutation +define+G6LC_MUT_ZAWRS_OFF must fail ZAWRS_ON.
`include "g6lc_core_types.svh"
module tb_g6lc_zawrs
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
`ifdef G6LC_MUT_ZAWRS_OFF
    c.ZawrsEn = 1'b0;
`else
    c.ZawrsEn = on;
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
    .fs_i(riscv::Off), .vfs_i(riscv::Off), .frm_i('0), .vs_i(riscv::Off),
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
    .fs_i(riscv::Off), .vfs_i(riscv::Off), .frm_i('0), .vs_i(riscv::Off),
    .tvm_i(1'b0), .tw_i(1'b0), .vtw_i(1'b0), .tsr_i(1'b0), .hu_i(1'b0),
    .mcbie_i(riscv::CBIE_FLUSH), .scbie_i(riscv::CBIE_FLUSH), .hcbie_i(riscv::CBIE_FLUSH),
    .mcbcfe_i(1'b1), .scbcfe_i(1'b1), .hcbcfe_i(1'b1),
    .mcbze_i(1'b1), .scbze_i(1'b1), .hcbze_i(1'b1), .smt_hart_id_i('0),
    .instruction_o(sbe_off), .orig_instr_o(orig_off), .is_control_flow_instr_o(cf_off),
    .debug_from_trigger_i(1'b0)
  );

  localparam logic [31:0] I_WRS_NTO = 32'h00d00073;
  localparam logic [31:0] I_WRS_STO = 32'h01d00073;
  localparam logic [31:0] WFI_I     = 32'h10500073;

  initial begin
    inst = I_WRS_NTO;
    #1;
    if (sbe_on.ex.valid)
      $fatal(1, "ZAWRS_ON wrs.nto trapped");
    if (sbe_on.fu != CSR || sbe_on.op != WRS_NTO)
      $fatal(1, "ZAWRS_ON wrs.nto fu=%0d op=%0d", sbe_on.fu, sbe_on.op);
    if (!sbe_off.ex.valid)
      $fatal(1, "ZAWRS_OFF wrs.nto not illegal");
    inst = I_WRS_STO;
    #1;
    if (sbe_on.ex.valid)
      $fatal(1, "ZAWRS_ON wrs.sto trapped");
    if (sbe_on.fu != CSR || sbe_on.op != WRS_STO)
      $fatal(1, "ZAWRS_ON wrs.sto fu=%0d op=%0d", sbe_on.fu, sbe_on.op);
    if (!sbe_off.ex.valid)
      $fatal(1, "ZAWRS_OFF wrs.sto not illegal");
    inst = WFI_I;
    #1;
    if (sbe_on.ex.valid || sbe_off.ex.valid)
      $fatal(1, "WFI trapped under ZawrsEn on/off");
    if (sbe_on.op != WFI || sbe_off.op != WFI)
      $fatal(1, "WFI decode broken");
    $display("PASS tb_g6lc_zawrs");
    $finish;
  end
endmodule
