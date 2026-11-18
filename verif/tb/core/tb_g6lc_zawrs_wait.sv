// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zawrs wait policy: NOP if no reservation; STO timeout; irq wake.
// Mutation +define+G6LC_MUT_ZAWRS_WAIT_OFF must fail ZAWRS_WAIT_ON.
`timescale 1ns / 1ps
module tb_g6lc_zawrs_wait;
  function automatic config_pkg::cva6_cfg_t cfg_of(input bit on);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
`ifdef G6LC_MUT_ZAWRS_WAIT_OFF
    c.ZawrsEn = 1'b0;
`else
    c.ZawrsEn = on;
`endif
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C_ON = cfg_of(1'b1);
  localparam config_pkg::cva6_cfg_t C_OFF = cfg_of(1'b0);

  logic wrs, nto, res, irq, timeout;
  logic enter_on, wake_on, enter_off, wake_off;

  g6lc_zawrs #(.CVA6Cfg(C_ON)) dut_on (
      .wrs_i(wrs), .nto_i(nto), .res_valid_i(res),
      .irq_i(irq), .timeout_i(timeout),
      .enter_wait_o(enter_on), .wake_o(wake_on)
  );
  g6lc_zawrs #(.CVA6Cfg(C_OFF)) dut_off (
      .wrs_i(wrs), .nto_i(nto), .res_valid_i(res),
      .irq_i(irq), .timeout_i(timeout),
      .enter_wait_o(enter_off), .wake_o(wake_off)
  );

  initial begin
    wrs = 1'b1;
    nto = 1'b1;
    res = 1'b0;
    irq = 1'b0;
    timeout = 1'b0;
    #1;
    if (enter_on)
      $fatal(1, "ZAWRS_WAIT_ON no-reservation entered wait");
    if (enter_off || wake_off)
      $fatal(1, "off-knob wait outputs live");

    res = 1'b1;
    #1;
    if (!enter_on)
      $fatal(1, "ZAWRS_WAIT_ON reservation did not enter wait");
    if (enter_off)
      $fatal(1, "off-knob entered wait");

    irq = 1'b1;
    #1;
    if (enter_on)
      $fatal(1, "ZAWRS_WAIT_ON irq still entering wait");
    if (!wake_on)
      $fatal(1, "ZAWRS_WAIT_ON irq did not wake");

    irq = 1'b0;
    nto = 1'b0;
    timeout = 1'b1;
    #1;
    if (enter_on)
      $fatal(1, "ZAWRS_WAIT_ON STO timeout still entering");
    if (!wake_on)
      $fatal(1, "ZAWRS_WAIT_ON STO timeout did not wake");

    $display("PASS tb_g6lc_zawrs_wait");
    $finish;
  end
endmodule
