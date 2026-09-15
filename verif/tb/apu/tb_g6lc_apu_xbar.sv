// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_xbar_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t xbar_cfg(input bit enabled);
    apu_cfg_t cfg = ApuHarness;
    cfg.Enable = enabled;
    if (!enabled) cfg.FirmwareHart = APU_FW_HART_UNASSIGNED;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t xbar_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
endpackage

module g6lc_apu_xbar_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1'b1, parameter int unsigned NumSources = 30) (
  input logic clk_i, rst_ni, testmode_i,
  input apu_dma_axi_req_t guest_req_i, control_req_i,
  output apu_dma_axi_resp_t guest_rsp_o, control_rsp_o,
  input logic [31:0] control_aw_hart_i, control_ar_hart_i,
  input logic [NumSources-1:0] irq_sources_i,
  output logic [NumSources-1:0] irq_sources_o,
  output logic plic_irq_o,
  output logic [31:0] plic_source_o,
  output axi_pkg::xbar_rule_64_t guest_rule_o, control_rule_o,
  output logic [63:0] guest_base_o, guest_end_o, control_base_o, control_end_o,
  output apu_dma_axi_req_t dma_req_o,
  input  apu_dma_axi_resp_t dma_rsp_i
);
  g6lc_apu_xbar #(
    .ApuCfg(g6lc_xbar_test_pkg::xbar_cfg(Enable)),
    .CoreCfg(g6lc_xbar_test_pkg::xbar_core()),
    .GuestIdx(10), .CtrlIdx(11), .NumSources(NumSources)
  ) i_dut (.*);
endmodule

module tb_g6lc_apu_xbar;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_xbar_test_pkg::*;
  import axi_pkg::*;
  localparam int unsigned NumSources = 30;
  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t [3:0] req;
  apu_dma_axi_resp_t [3:0] rsp;
  logic [31:0] aw_hart, ar_hart;
  logic [NumSources-1:0] irq_in, irq_out, off_irq_out;
  logic plic_irq, off_plic;
  logic [31:0] plic_source, off_src;
  axi_pkg::xbar_rule_64_t guest_rule, control_rule, off_guest_rule, off_ctrl_rule;
  logic [63:0] guest_base, guest_end, control_base, control_end;
  apu_dma_axi_req_t dma_req, off_dma;
  apu_dma_axi_resp_t dma_rsp;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_xbar_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(req[0]), .guest_rsp_o(rsp[0]),
    .control_req_i(req[1]), .control_rsp_o(rsp[1]),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(irq_out),
    .plic_irq_o(plic_irq), .plic_source_o(plic_source),
    .guest_rule_o(guest_rule), .control_rule_o(control_rule),
    .guest_base_o(guest_base), .guest_end_o(guest_end),
    .control_base_o(control_base), .control_end_o(control_end),
    .dma_req_o(dma_req), .dma_rsp_i(dma_rsp)
  );
  g6lc_apu_xbar_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(req[2]), .guest_rsp_o(rsp[2]),
    .control_req_i(req[3]), .control_rsp_o(rsp[3]),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(off_irq_out),
    .plic_irq_o(off_plic), .plic_source_o(off_src),
    .guest_rule_o(off_guest_rule), .control_rule_o(off_ctrl_rule),
    .guest_base_o(), .guest_end_o(), .control_base_o(), .control_end_o(),
    .dma_req_o(off_dma), .dma_rsp_i(dma_rsp)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "APU xbar timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_plic, off_src} !== '0) $fatal(1, "disabled APU xbar IRQ active");
    if (off_irq_out !== irq_in) $fatal(1, "disabled xbar must pass PLIC through");
    if (off_dma !== '0) $fatal(1, "disabled xbar DMA initiator active");
  end
  assign dma_rsp = '0;

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
  task automatic send_read(input int p, input logic [63:0] a,
      input logic [31:0] hart = 1);
    @(negedge clk);
    ar_hart = hart;
    req[p].ar.addr = a; req[p].ar.size = 3'd2; req[p].ar.len = '0;
    req[p].ar.burst = BURST_INCR; req[p].ar.id = '0;
    req[p].ar_valid = 1;
    @(posedge clk);
    while (!rsp[p].ar_ready) @(posedge clk);
    @(negedge clk); req[p].ar_valid = 0;
  endtask
  task automatic receive_read(input int p, input logic [63:0] a,
      output logic [31:0] data, input logic [1:0] expected = 0);
    @(posedge clk);
    while (!rsp[p].r_valid) @(posedge clk);
    unpack32(a, rsp[p].r.data, data);
    check("AXI R", rsp[p].r.resp == expected && rsp[p].r.last);
    @(negedge clk); req[p].r_ready = 1;
    @(posedge clk); @(negedge clk); req[p].r_ready = 0;
  endtask
  task automatic read_reg(input int p, input logic [63:0] a, output logic [31:0] data,
      input logic [1:0] expected = 0, input logic [31:0] hart = 1);
    send_read(p, a, hart);
    receive_read(p, a, data, expected);
  endtask

  initial begin
    logic [31:0] r;
    for (int p = 0; p < 4; p++) req[p] = '0;
    aw_hart = 0; ar_hart = 0; irq_in = '0;
    repeat (4) @(negedge clk);
    rst_ni = 1;

    cases = 1;
    check("guest idx follows testharness NB_PERIPHERALS", guest_rule.idx == 10);
    check("control idx is next", control_rule.idx == 11);
    check("guest rule window", guest_rule.start_addr == 64'h4000_1000 &&
          guest_rule.end_addr == 64'h4000_2000);
    check("control rule window", control_rule.start_addr == 64'h4000_2000 &&
          control_rule.end_addr == 64'h4000_3000);
    check("guest rule misses GPIO/AI",
          !(guest_rule.start_addr < 64'h4000_1000));
    check("idx unique", guest_rule.idx != control_rule.idx);
    check("disabled publishes the same rules",
          off_guest_rule.idx == guest_rule.idx &&
          off_ctrl_rule.start_addr == control_rule.start_addr);
    check("harness DMA initiator idle", !dma_req.ar_valid && !dma_req.aw_valid);

    cases = 2;
    read_reg(0, APU_MMIO_BASE, r);
    check("guest virtio magic", r == VIRTIO_MMIO_MAGIC);
    read_reg(1, APU_CONTROL_BASE, r, 2, 0);
    check("hart 0 cannot read control", r == 0);
    read_reg(1, APU_CONTROL_BASE, r, 0, 1);
    check("firmware hart reads control magic", r == APU_CONTROL_MAGIC);

    cases = 3;
    read_reg(2, APU_MMIO_BASE, r, 2);
    check("disabled guest SLVERR", 1'b1);
    irq_in[7] = 1'b1;
    @(negedge clk);
    check("AI source 8 passthrough", irq_out[7] == 1'b1 && irq_out[8] == 1'b0);

    if (errors != 0) $fatal(1, "APU xbar errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_xbar cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
