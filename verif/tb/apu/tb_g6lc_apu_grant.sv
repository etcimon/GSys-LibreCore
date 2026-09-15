// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_grant_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t grant_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
endpackage

module g6lc_apu_grant_fixture
  import g6lc_apu_cfg_pkg::*;
#(parameter bit Enable = 1'b1) (
  input logic clk_i, rst_ni, testmode_i,
  input logic [31:0] aw_hart_i, ar_hart_i,
  input logic [63:0] aw_addr_i, ar_addr_i,
  input logic guest_irq_i, control_irq_i,
  output logic control_aw_authorized_o, control_ar_authorized_o,
  output logic plic_irq_o, fw_irq_o,
  output logic [31:0] plic_source_o
);
  g6lc_apu_grant #(.ApuCfg(g6lc_grant_test_pkg::grant_cfg(Enable))) i_dut (.*);
endmodule

module tb_g6lc_apu_grant;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_grant_test_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic [31:0] aw_hart, ar_hart;
  logic [63:0] aw_addr, ar_addr;
  logic guest_irq, control_irq;
  logic aw_auth, ar_auth, plic_irq, fw_irq;
  logic [31:0] plic_source;
  logic off_aw, off_ar, off_plic, off_fw;
  logic [31:0] off_src;
  int errors = 0, checks = 0, cycles = 0;

  g6lc_apu_grant_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .aw_hart_i(aw_hart), .ar_hart_i(ar_hart),
    .aw_addr_i(aw_addr), .ar_addr_i(ar_addr),
    .guest_irq_i(guest_irq), .control_irq_i(control_irq),
    .control_aw_authorized_o(aw_auth), .control_ar_authorized_o(ar_auth),
    .plic_irq_o(plic_irq), .fw_irq_o(fw_irq), .plic_source_o(plic_source)
  );
  g6lc_apu_grant_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .aw_hart_i(aw_hart), .ar_hart_i(ar_hart),
    .aw_addr_i(aw_addr), .ar_addr_i(ar_addr),
    .guest_irq_i(guest_irq), .control_irq_i(control_irq),
    .control_aw_authorized_o(off_aw), .control_ar_authorized_o(off_ar),
    .plic_irq_o(off_plic), .fw_irq_o(off_fw), .plic_source_o(off_src)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #100000; $fatal(1, "grant timeout"); end
  always @(negedge clk) begin
    #1;
    if ({off_aw, off_ar, off_plic, off_fw, off_src} !== '0)
      $fatal(1, "disabled grant active");
  end
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s cycle=%0d", name, cycles);
    end
  endtask

  initial begin
    aw_hart = 0; ar_hart = 0;
    aw_addr = 0; ar_addr = 0;
    guest_irq = 0; control_irq = 0;
    repeat (4) @(negedge clk);
    rst_ni = 1;

    check("irq source is not the AI line", APU_IRQ_SOURCE != 8);
    check("irq source matches package", plic_source == 32'(APU_IRQ_SOURCE));
    check("mmio sits after GPIO/AI", APU_MMIO_BASE == 64'h4000_1000);
    check("control is private", APU_CONTROL_BASE == 64'h4000_2000);
    check("mmio does not overlap GPIO",
          !apu_ranges_overlap(APU_MMIO_BASE, APU_MMIO_LEN, 64'h4000_0000, 64'h1000));
    check("control does not overlap mmio",
          !apu_ranges_overlap(APU_CONTROL_BASE, APU_CONTROL_LEN,
                              APU_MMIO_BASE, APU_MMIO_LEN));

    aw_hart = 1; aw_addr = APU_CONTROL_BASE;
    ar_hart = 1; ar_addr = APU_CONTROL_BASE + 4;
    @(negedge clk);
    check("firmware hart write grant", aw_auth);
    check("firmware hart read grant", ar_auth);

    aw_hart = 0;
    @(negedge clk);
    check("application hart cannot write control", !aw_auth);
    check("firmware read grant independent", ar_auth);

    ar_hart = 0; aw_hart = 1;
    @(negedge clk);
    check("application hart cannot read control", !ar_auth);

    aw_addr = APU_MMIO_BASE;
    ar_hart = 1; ar_addr = APU_MMIO_BASE;
    @(negedge clk);
    check("firmware hart is not granted on guest mmio", !aw_auth && !ar_auth);

    aw_hart = 1; aw_addr = APU_CONTROL_BASE + APU_CONTROL_LEN - 4;
    @(negedge clk);
    check("last control word granted", aw_auth);
    aw_addr = APU_CONTROL_BASE + APU_CONTROL_LEN;
    @(negedge clk);
    check("control length is exclusive", !aw_auth);

    guest_irq = 1; control_irq = 1;
    @(negedge clk);
    check("guest irq becomes PLIC", plic_irq);
    check("firmware irq is not the guest line", fw_irq);
    guest_irq = 0;
    @(negedge clk);
    check("PLIC follows guest irq", !plic_irq);
    check("firmware irq independent", fw_irq);

    if (errors != 0) $fatal(1, "APU grant errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_grant checks=%0d cycles=%0d errors=0", checks, cycles);
      $finish;
    end
  end
endmodule
