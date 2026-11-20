// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// hyp8 port of verif/tb/core/tb_g6lc_za64rs.sv (89d3dadd0). Config type
// adapted cva6_cfg_t/cva6_cfg_empty/CVA6Cfg -> g6lc_cfg_t/g6lc_cfg_empty/G6LCCfg.
// Za64rs membership: exact-address set is a subset of a 64 B window.
// Mutation +define+G6LC_MUT_ZA64RS_OFF must fail ZA64RS_ON.
`timescale 1ns / 1ps
module tb_g6lc_za64rs;
  function automatic config_pkg::g6lc_cfg_t cfg_of(input bit on);
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.XLEN = 64;
    c.IS_XLEN64 = 1'b1;
    c.RVA = 1'b1;
    c.DCACHE_LINE_WIDTH = 128;
`ifdef G6LC_MUT_ZA64RS_OFF
    c.RVZa64rs = 1'b0;
`else
    c.RVZa64rs = on;
`endif
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C_ON = cfg_of(1'b1);
  localparam config_pkg::g6lc_cfg_t C_OFF = cfg_of(1'b0);

  logic [63:0] lr, other;
  logic same_on, max_on, ok_on;
  logic same_off, max_off, ok_off;

  g6lc_za64rs #(
      .G6LCCfg(C_ON), .ADDR_WIDTH(64)
  ) dut_on (
      .lr_addr_i(lr), .other_addr_i(other),
      .same_set_o(same_on), .within_max_o(max_on), .za64rs_ok_o(ok_on)
  );
  g6lc_za64rs #(
      .G6LCCfg(C_OFF), .ADDR_WIDTH(64)
  ) dut_off (
      .lr_addr_i(lr), .other_addr_i(other),
      .same_set_o(same_off), .within_max_o(max_off), .za64rs_ok_o(ok_off)
  );

  initial begin
    if (!ok_on) $fatal(1, "ZA64RS_ON advertise predicate low");
    if (ok_off) $fatal(1, "ZA64RS_OFF advertise predicate high");

    lr = 64'h1000;
    other = 64'h1000;
    #1;
    if (!same_on || !max_on) $fatal(1, "ZA64RS_ON exact addr not in set");
    if (!same_off) $fatal(1, "off exact addr not in set");

    other = 64'h1008;
    #1;
    if (same_on) $fatal(1, "ZA64RS_ON +8 must be a different set");
    if (!max_on) $fatal(1, "ZA64RS_ON +8 still inside 64 B window");
    if (same_on && !max_on) $fatal(1, "ZA64RS_ON set exceeds 64 B");

    other = 64'h1040;
    #1;
    if (same_on) $fatal(1, "ZA64RS_ON +64 must be a different set");
    if (max_on) $fatal(1, "ZA64RS_ON +64 must leave the 64 B window");

    $display("PASS tb_g6lc_za64rs");
    $finish;
  end
endmodule
