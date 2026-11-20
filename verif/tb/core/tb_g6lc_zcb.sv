// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zcb compressed expansions. Mutation +define+G6LC_MUT_ZCB_OFF must fail ZCB_ON.
module tb_g6lc_zcb;
  function automatic config_pkg::cva6_cfg_t cfg_of(input bit on);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.IS_XLEN64 = 1'b1;
    c.RVC = 1'b1;
    c.RVB = 1'b1;
`ifdef G6LC_MUT_ZCB_OFF
    c.RVZCB = 1'b0;
`else
    c.RVZCB = on;
`endif
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C_ON = cfg_of(1'b1);
  localparam config_pkg::cva6_cfg_t C_OFF = cfg_of(1'b0);

  logic [15:0] cin;
  logic [31:0] cout_on, cout_off;
  logic ill_on, ill_off, mac_on, mac_off, cmp_on, cmp_off, zc_on, zc_off;

  compressed_decoder #(.CVA6Cfg(C_ON)) dut_on (
    .instr_i(cin), .instr_o(cout_on), .illegal_instr_o(ill_on),
    .is_macro_instr_o(mac_on), .is_compressed_o(cmp_on), .is_zcmt_instr_o(zc_on));
  compressed_decoder #(.CVA6Cfg(C_OFF)) dut_off (
    .instr_i(cin), .instr_o(cout_off), .illegal_instr_o(ill_off),
    .is_macro_instr_o(mac_off), .is_compressed_o(cmp_off), .is_zcmt_instr_o(zc_off));

  // c.lbu x8, 0(x8); c.zext.b x8; c.not x8
  localparam logic [15:0] C_LBU    = 16'h8000;
  localparam logic [15:0] C_ZEXT_B = 16'h9C61;
  localparam logic [15:0] C_NOT    = 16'h9C75;
  localparam logic [31:0] LBU_X8   = 32'h00044403;
  localparam logic [31:0] ANDI_FF  = 32'h0FF47413;
  localparam logic [31:0] XORI_M1  = 32'hFFF44413;

  initial begin
    cin = C_LBU;
    #1;
    if (ill_on || cout_on != LBU_X8)
      $fatal(1, "ZCB_ON c.lbu ill=%0d out=%h", ill_on, cout_on);
    if (!ill_off)
      $fatal(1, "ZCB_OFF c.lbu not illegal");
    cin = C_ZEXT_B;
    #1;
    if (ill_on || cout_on != ANDI_FF)
      $fatal(1, "ZCB_ON c.zext.b out=%h", cout_on);
    if (!ill_off)
      $fatal(1, "ZCB_OFF c.zext.b not illegal");
    cin = C_NOT;
    #1;
    if (ill_on || cout_on != XORI_M1)
      $fatal(1, "ZCB_ON c.not out=%h", cout_on);
    $display("PASS tb_g6lc_zcb");
    $finish;
  end
endmodule
