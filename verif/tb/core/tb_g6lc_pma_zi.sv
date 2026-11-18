// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Ziccif/Ziccrse/Ziccamoa PMA leaf. Mutation +define+G6LC_MUT_PMA_ZI_OFF
// must fail PMA_ZI_ON.
`timescale 1ns / 1ps
module tb_g6lc_pma_zi;
  function automatic config_pkg::cva6_cfg_t cfg_of(input bit on);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.IS_XLEN64 = 1'b1;
    c.RVA = 1'b1;
    c.ICACHE_LINE_WIDTH = 128;
`ifdef G6LC_MUT_PMA_ZI_OFF
    c.RVZiccif = 1'b0;
    c.RVZiccrse = 1'b0;
    c.RVZiccamoa = 1'b0;
`else
    c.RVZiccif = on;
    c.RVZiccrse = on;
    c.RVZiccamoa = on;
`endif
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C_ON = cfg_of(1'b1);
  localparam config_pkg::cva6_cfg_t C_OFF = cfg_of(1'b0);

  logic [127:0] line;
  logic [31:0] off, instr_on, instr_off;
  logic aln_on, aln_off, cif_on, cif_off;
  logic [63:0] addr;
  logic [3:0] sz;
  logic rsrv_on, rsrv_off, crse_on, crse_off;
  logic amo_on, amo_off, camoa_on, camoa_off;

  g6lc_pma_zi #(.CVA6Cfg(C_ON), .LINE_W(128)) dut_on (
      .line_i(line), .fetch_off_i(off),
      .fetch_instr_o(instr_on), .fetch_aligned_o(aln_on), .ziccif_ok_o(cif_on),
      .rsrv_addr_i(addr), .rsrv_size_i(sz),
      .reservable_o(rsrv_on), .ziccrse_ok_o(crse_on),
      .amo_addr_i(addr), .amo_size_i(sz),
      .amo_aligned_o(amo_on), .ziccamoa_ok_o(camoa_on)
  );
  g6lc_pma_zi #(.CVA6Cfg(C_OFF), .LINE_W(128)) dut_off (
      .line_i(line), .fetch_off_i(off),
      .fetch_instr_o(instr_off), .fetch_aligned_o(aln_off), .ziccif_ok_o(cif_off),
      .rsrv_addr_i(addr), .rsrv_size_i(sz),
      .reservable_o(rsrv_off), .ziccrse_ok_o(crse_off),
      .amo_addr_i(addr), .amo_size_i(sz),
      .amo_aligned_o(amo_off), .ziccamoa_ok_o(camoa_off)
  );

  initial begin
    if (!cif_on || !crse_on || !camoa_on)
      $fatal(1, "PMA_ZI_ON advertise predicate low cif=%0d crse=%0d camoa=%0d",
             cif_on, crse_on, camoa_on);
    if (cif_off || crse_off || camoa_off)
      $fatal(1, "PMA_ZI_OFF advertise predicate high");

    // One I$ line: four little-endian 32-bit words A,B,C,D.
    line = {32'hDDDDDDDD, 32'hCCCCCCCC, 32'hBBBBBBBB, 32'hAAAAAAAA};
    off = 32'd0;
    addr = 64'h1000;
    sz = 4'd8;
    #1;
    if (!aln_on || instr_on != 32'hAAAAAAAA)
      $fatal(1, "PMA_ZI_ON fetch@0 got %h aligned=%0d", instr_on, aln_on);
    if (instr_off != 32'hAAAAAAAA)
      $fatal(1, "off-knob fetch extract broken");
    if (!rsrv_on || rsrv_off)
      $fatal(1, "PMA_ZI_ON aligned LD not reservable / off still reservable");
    if (!amo_on)
      $fatal(1, "PMA_ZI_ON aligned AMO.D not aligned");

    off = 32'd4;
    #1;
    if (!aln_on || instr_on != 32'hBBBBBBBB)
      $fatal(1, "PMA_ZI_ON fetch@4 got %h", instr_on);

    off = 32'd12;
    #1;
    if (!aln_on || instr_on != 32'hDDDDDDDD)
      $fatal(1, "PMA_ZI_ON fetch@12 got %h", instr_on);

    off = 32'd1;
    #1;
    if (aln_on)
      $fatal(1, "PMA_ZI_ON unaligned fetch claimed aligned");

    addr = 64'h1001;
    sz = 4'd4;
    #1;
    if (rsrv_on)
      $fatal(1, "PMA_ZI_ON unaligned word LR claimed reservable");
    if (amo_on)
      $fatal(1, "PMA_ZI_ON unaligned AMO.W claimed aligned");

    $display("PASS tb_g6lc_pma_zi");
    $finish;
  end
endmodule
