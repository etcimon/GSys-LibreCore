// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Testharness load compositor: DRAM-hole rules + hart-1 boot PC.
// Not a CVA6 fetch.

`timescale 1ns/1ps

package g6lc_th_load_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t load_cfg(input bit enabled, input int unsigned bytes);
    apu_cfg_t cfg = ApuHarness;
    cfg.Enable = enabled;
    if (!enabled) cfg.FirmwareHart = APU_FW_HART_UNASSIGNED;
    if (bytes != 0) cfg.FirmwareRamBytes = 64'(bytes);
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t load_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
endpackage

module g6lc_apu_th_load_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1'b1, parameter int unsigned NumCores = 2,
  parameter int unsigned Vlen = 39, parameter int unsigned RamBytes = 0,
  parameter HexFile = "none") (
  input  logic clk_i, rst_ni, testmode_i,
  input  apu_dma_axi_req_t guest_req_i, control_req_i, ram_req_i,
  output apu_dma_axi_resp_t guest_rsp_o, control_rsp_o, ram_rsp_o,
  input  logic [31:0] control_aw_hart_i, control_ar_hart_i,
  input  logic [29:0] irq_sources_i,
  output logic [29:0] irq_sources_o,
  output logic plic_irq_o, fw_ready_o,
  output logic [NumCores-1:0][Vlen-1:0] boot_addr_core_o,
  output axi_pkg::xbar_rule_64_t guest_rule_o, control_rule_o, ram_rule_o,
         dram_lo_rule_o, dram_hi_rule_o,
  output apu_dma_axi_req_t dma_req_o,
  input  apu_dma_axi_resp_t dma_rsp_i
);
  g6lc_apu_th_load #(
    .ApuCfg(g6lc_th_load_test_pkg::load_cfg(Enable, RamBytes)),
    .CoreCfg(g6lc_th_load_test_pkg::load_core()),
    .AppBoot(64'h0001_0000),
    .DramBase(64'h8000_0000),
    .DramBytes(64'h4000_0000),
    .NumCores(NumCores),
    .Vlen(Vlen),
    .HexFile(HexFile)
  ) i_dut (.*);
endmodule

module tb_g6lc_apu_th_load;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import axi_pkg::*;
  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t zreq, ram_req;
  apu_dma_axi_resp_t guest_rsp, ctrl_rsp, ram_rsp;
  logic [31:0] aw_hart, ar_hart;
  logic [29:0] irq_in, irq_out, off_irq;
  logic plic, off_plic, fw_ready, off_ready;
  logic [1:0][38:0] boot, off_boot;
  axi_pkg::xbar_rule_64_t guest_rule, ctrl_rule, ram_rule, dram_lo, dram_hi;
  axi_pkg::xbar_rule_64_t off_guest, off_ctrl, off_ram, off_lo, off_hi;
  apu_dma_axi_req_t dma_req, off_dma;
  apu_dma_axi_resp_t dma_rsp;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  assign zreq = '0;
  assign dma_rsp = '0;
  g6lc_apu_th_load_fixture #(.HexFile("apu_fw.hex")) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(zreq), .control_req_i(zreq), .ram_req_i(ram_req),
    .guest_rsp_o(guest_rsp), .control_rsp_o(ctrl_rsp), .ram_rsp_o(ram_rsp),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(irq_out),
    .plic_irq_o(plic), .fw_ready_o(fw_ready),
    .boot_addr_core_o(boot),
    .guest_rule_o(guest_rule), .control_rule_o(ctrl_rule), .ram_rule_o(ram_rule),
    .dram_lo_rule_o(dram_lo), .dram_hi_rule_o(dram_hi),
    .dma_req_o(dma_req), .dma_rsp_i(dma_rsp)
  );
  g6lc_apu_th_load_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(zreq), .control_req_i(zreq), .ram_req_i(zreq),
    .guest_rsp_o(), .control_rsp_o(), .ram_rsp_o(),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(off_irq),
    .plic_irq_o(off_plic), .fw_ready_o(off_ready),
    .boot_addr_core_o(off_boot),
    .guest_rule_o(off_guest), .control_rule_o(off_ctrl), .ram_rule_o(off_ram),
    .dram_lo_rule_o(off_lo), .dram_hi_rule_o(off_hi),
    .dma_req_o(off_dma), .dma_rsp_i(dma_rsp)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "th_load timeout case=%0d", cases); end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  task automatic unpack32(input logic [63:0] a, input logic [63:0] data,
      output logic [31:0] d);
    d = a[2] ? data[63:32] : data[31:0];
  endtask
  task automatic ram_read(input logic [63:0] a, output logic [31:0] data);
    @(negedge clk);
    ram_req.ar.addr = a; ram_req.ar.size = 3'd2; ram_req.ar.len = '0;
    ram_req.ar.burst = BURST_INCR; ram_req.ar.id = '0;
    ram_req.ar_valid = 1;
    @(posedge clk);
    while (!ram_rsp.ar_ready) @(posedge clk);
    @(negedge clk); ram_req.ar_valid = 0;
    @(posedge clk);
    while (!ram_rsp.r_valid) @(posedge clk);
    unpack32(a, ram_rsp.r.data, data);
    check("RAM R", ram_rsp.r.resp == 0 && ram_rsp.r.last);
    @(negedge clk); ram_req.r_ready = 1;
    @(posedge clk); @(negedge clk); ram_req.r_ready = 0;
  endtask

  initial begin
    logic [31:0] r;
    aw_hart = 1; ar_hart = 1; irq_in = '0;
    ram_req = '0;
    repeat (4) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);

    cases = 1;
    check("guest idx 10", guest_rule.idx == 10);
    check("ctrl idx 11", ctrl_rule.idx == 11);
    check("ram idx 12", ram_rule.idx == 12);
    check("dram lo idx 0", dram_lo.idx == 0);
    check("dram hi idx 0", dram_hi.idx == 0);
    check("dram lo ends at RAM", dram_lo.start_addr == 64'h8000_0000 &&
          dram_lo.end_addr == 64'h9000_0000);
    check("ram window", ram_rule.start_addr == 64'h9000_0000 &&
          ram_rule.end_addr == 64'h9004_0000);
    check("dram hi starts after RAM", dram_hi.start_addr == 64'h9004_0000 &&
          dram_hi.end_addr == 64'hC000_0000);
    check("guest misses GPIO/AI", guest_rule.start_addr == 64'h4000_1000);
    check("disabled publishes the same rules",
          off_ram.idx == ram_rule.idx && off_lo.end_addr == dram_lo.end_addr);
    check("harness DMA initiator idle",
          !dma_req.ar_valid && !dma_req.aw_valid &&
          !off_dma.ar_valid && !off_dma.aw_valid);

    cases = 2;
    check("hart 0 boots ROM", boot[0] == 39'h10000);
    check("hart 1 boots firmware RAM", boot[1] == 39'h90000000);
    check("disabled hart 1 keeps ROM", off_boot[1] == 39'h10000);
    check("fw_ready after preload hold", fw_ready === 1'b1);
    check("disabled fw_ready", off_ready === 1'b1);
    check("disabled IRQ passthrough", off_irq === irq_in && off_plic === 1'b0);

    cases = 3;
    ram_read(64'h9000_0000, r);
    check("boot PC word is auipc", r == 32'h0003_f117);
    ram_read(64'h9000_000c, r);
    check("crt0 spin at +12", r == 32'h0000_006f);

    if (errors != 0) $fatal(1, "APU th_load errors=%0d", errors);
    $display("PASS tb_g6lc_apu_th_load cases=%0d checks=%0d cycles=%0d errors=0",
             cases, checks, cycles);
    $finish;
  end
endmodule
