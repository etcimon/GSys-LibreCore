// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// decoder Zimop + Zihintntl. Mutation +define+G6LC_MUT_ZIMOP_OFF must fail ZIMOP_ON.
`include "g6lc_core_types.svh"
module tb_g6lc_zimop
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
    c.RVC = 1'b1;
`ifdef G6LC_MUT_ZIMOP_OFF
    c.RVZimop = 1'b0;
    c.RVZihintntl = 1'b0;
`else
    c.RVZimop = on;
    c.RVZihintntl = on;
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

  localparam logic [31:0] MOP_R0_A0 = 32'h89004573;
  localparam logic [31:0] NTL_P = 32'h00200033;
  localparam logic [31:0] ADD_A0 = 32'h00c58533;

  initial begin
    inst = MOP_R0_A0;
    #1;
    if (sbe_on.ex.valid)
      $fatal(1, "ZIMOP_ON mop.r.0 trapped");
    if (sbe_on.fu != ALU || sbe_on.op != ADD || sbe_on.rd != 5'd10 ||
        sbe_on.rs1 != 5'd0 || sbe_on.rs2 != 5'd0)
      $fatal(1, "ZIMOP_ON mop.r.0 fu=%0d op=%0d rd=%0d rs1=%0d rs2=%0d",
             sbe_on.fu, sbe_on.op, sbe_on.rd, sbe_on.rs1, sbe_on.rs2);
    if (!sbe_off.ex.valid)
      $fatal(1, "ZIMOP_OFF mop.r.0 not illegal");
    inst = NTL_P;
    #1;
    if (sbe_on.rs2 != 5'd0)
      $fatal(1, "NTL_ON still waits on rs2=%0d", sbe_on.rs2);
    if (sbe_off.rs2 != 5'd2)
      $fatal(1, "NTL_OFF should keep rs2=x2, got %0d", sbe_off.rs2);
    inst = ADD_A0;
    #1;
    if (sbe_on.rd != 5'd10 || sbe_on.rs1 != 5'd11 || sbe_on.rs2 != 5'd12)
      $fatal(1, "live ADD a0,a1,a2 broken");
    $display("PASS tb_g6lc_zimop");
    $finish;
  end
endmodule
