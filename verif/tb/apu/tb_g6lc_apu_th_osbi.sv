// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Testharness +define+G6LC_APU OpenSBI-visible 14-rule addr_map locked to
// the compositor DRAM hole and hart-1 boot split. Not a CVA6 fetch, not
// UART/PLIC/DRAM/L2, not an OpenSBI firmware boot, not FPGA, not TEX.

`timescale 1ns/1ps

package g6lc_th_osbi_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  import axi_pkg::*;
  localparam int unsigned NRules = 14;
  localparam int unsigned DramIdx = 0;
  localparam int unsigned GpioIdx = 1;
  localparam int unsigned UartIdx = 5;
  localparam int unsigned PlicIdx = 6;
  localparam int unsigned ClintIdx = 7;
  localparam int unsigned RomIdx = 8;
  localparam int unsigned DebugIdx = 9;
  localparam int unsigned GuestIdx = 10;
  localparam int unsigned CtrlIdx = 11;
  localparam int unsigned RamIdx = 12;
  localparam logic [63:0] AppBoot = 64'h1_0000;
  localparam logic [63:0] DramBase = 64'h8000_0000;
  localparam logic [63:0] DramBytes = 64'h4000_0000;

  function automatic apu_cfg_t load_cfg(input bit enabled);
    apu_cfg_t cfg = ApuHarness;
    cfg.Enable = enabled;
    if (!enabled) cfg.FirmwareHart = APU_FW_HART_UNASSIGNED;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t dual();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t smt2();
    config_pkg::cva6_cfg_t cfg = dual();
    cfg.NrHarts = 2;
    return cfg;
  endfunction
  function automatic int last_match(input logic [63:0] a,
      input xbar_rule_64_t [NRules-1:0] rules);
    int idx;
    int i;
    idx = -1;
    for (i = 0; i < int'(NRules); i++)
      if (a >= rules[i].start_addr && a < rules[i].end_addr)
        idx = int'(rules[i].idx);
    return idx;
  endfunction
  function automatic int last_match2(input logic [63:0] a,
      input xbar_rule_64_t [1:0] pair);
    int idx;
    int i;
    idx = -1;
    for (i = 0; i < 2; i++)
      if (a >= pair[i].start_addr && a < pair[i].end_addr)
        idx = int'(pair[i].idx);
    return idx;
  endfunction
endpackage

module tb_g6lc_apu_th_osbi;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import axi_pkg::*;
  import g6lc_th_osbi_test_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t zreq;
  apu_dma_axi_resp_t guest_rsp, ctrl_rsp, ram_rsp;
  logic [31:0] aw_hart, ar_hart;
  logic [29:0] irq_in, irq_out, off_irq;
  logic plic, off_plic, fw_ready, off_ready;
  logic [1:0][38:0] boot, off_boot;
  xbar_rule_64_t guest_rule, ctrl_rule, ram_rule, dram_lo, dram_hi;
  xbar_rule_64_t off_guest, off_ctrl, off_ram, off_lo, off_hi;
  apu_dma_axi_req_t dma_req, off_dma;
  apu_dma_axi_resp_t dma_rsp;
  xbar_rule_64_t [NRules-1:0] rules;
  xbar_rule_64_t [1:0] aliased;
  int errors = 0, checks = 0, cycles = 0;

  assign zreq = '0;
  assign dma_rsp = '0;
  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  g6lc_apu_th_load #(
    .ApuCfg(load_cfg(1'b1)),
    .CoreCfg(dual()),
    .AppBoot(AppBoot),
    .DramBase(DramBase),
    .DramBytes(DramBytes),
    .GuestIdx(GuestIdx),
    .CtrlIdx(CtrlIdx),
    .RamIdx(RamIdx),
    .DramIdx(DramIdx),
    .NumCores(2),
    .Vlen(39),
    .HexFile("none")
  ) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(zreq), .control_req_i(zreq), .ram_req_i(zreq),
    .guest_rsp_o(guest_rsp), .control_rsp_o(ctrl_rsp), .ram_rsp_o(ram_rsp),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(irq_out),
    .plic_irq_o(plic), .fw_ready_o(fw_ready),
    .boot_addr_core_o(boot),
    .guest_rule_o(guest_rule), .control_rule_o(ctrl_rule),
    .ram_rule_o(ram_rule), .dram_lo_rule_o(dram_lo), .dram_hi_rule_o(dram_hi),
    .dma_req_o(dma_req), .dma_rsp_i(dma_rsp)
  );
  g6lc_apu_th_load #(
    .ApuCfg(load_cfg(1'b0)),
    .CoreCfg(dual()),
    .AppBoot(AppBoot),
    .DramBase(DramBase),
    .DramBytes(DramBytes),
    .NumCores(2),
    .Vlen(39),
    .HexFile("none")
  ) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(zreq), .control_req_i(zreq), .ram_req_i(zreq),
    .guest_rsp_o(), .control_rsp_o(), .ram_rsp_o(),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(off_irq),
    .plic_irq_o(off_plic), .fw_ready_o(off_ready),
    .boot_addr_core_o(off_boot),
    .guest_rule_o(off_guest), .control_rule_o(off_ctrl),
    .ram_rule_o(off_ram), .dram_lo_rule_o(off_lo), .dram_hi_rule_o(off_hi),
    .dma_req_o(off_dma), .dma_rsp_i(dma_rsp)
  );

  assign rules[0] = '{idx: DebugIdx, start_addr: 64'h0, end_addr: 64'h1000};
  assign rules[1] = '{idx: RomIdx, start_addr: AppBoot, end_addr: AppBoot + 64'h1_0000};
  assign rules[2] = '{idx: ClintIdx, start_addr: 64'h200_0000, end_addr: 64'h200_0000 + 64'hC_0000};
  assign rules[3] = '{idx: PlicIdx, start_addr: 64'hC00_0000, end_addr: 64'hC00_0000 + 64'h3FF_FFFF};
  assign rules[4] = '{idx: UartIdx, start_addr: 64'h1000_0000, end_addr: 64'h1000_1000};
  assign rules[5] = '{idx: 4, start_addr: 64'h1800_0000, end_addr: 64'h1800_1000};
  assign rules[6] = '{idx: 3, start_addr: 64'h2000_0000, end_addr: 64'h2800_0000};
  assign rules[7] = '{idx: 2, start_addr: 64'h3000_0000, end_addr: 64'h3001_0000};
  assign rules[8] = '{idx: GpioIdx, start_addr: 64'h4000_0000, end_addr: 64'h4000_1000};
  assign rules[9]  = dram_lo;
  assign rules[10] = guest_rule;
  assign rules[11] = ctrl_rule;
  assign rules[12] = ram_rule;
  assign rules[13] = dram_hi;
  assign aliased[0] = ram_rule;
  assign aliased[1] = '{idx: DramIdx, start_addr: DramBase,
                        end_addr: DramBase + DramBytes};

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s cycle=%0d", name, cycles);
    end
  endtask

  initial begin
    #200000;
    $fatal(1, "th osbi timeout checks=%0d", checks);
  end

  initial begin
    aw_hart = 1; ar_hart = 1; irq_in = '0;
    repeat (4) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("fw_ready", fw_ready === 1'b1);
    check("domain legal", apu_domain_legal(ApuHarness, dual()));
    check("SMT2 domain rejected", !apu_domain_legal(ApuHarness, smt2()));
    check("boot split legal",
          apu_boot_split_legal(ApuHarness, dual(), AppBoot));
    check("hart 0 ROM", boot[0] == 39'(AppBoot));
    check("hart 1 firmware RAM", boot[1] == 39'(ApuHarness.FirmwareRamBase));
    check("overlay next-addr is hart 1 boot",
          boot[1] == 39'h9000_0000);
    check("disabled hart 1 keeps ROM", off_boot[1] == 39'(AppBoot));
    check("compositor guest idx 10", guest_rule.idx == GuestIdx);
    check("compositor ctrl idx 11", ctrl_rule.idx == CtrlIdx);
    check("compositor ram idx 12", ram_rule.idx == RamIdx);
    check("compositor dram lo/hi idx 0",
          dram_lo.idx == DramIdx && dram_hi.idx == DramIdx);
    check("decode debug", last_match(64'h0, rules) == int'(DebugIdx));
    check("decode ROM", last_match(AppBoot, rules) == int'(RomIdx));
    check("decode CLINT", last_match(64'h200_0000, rules) == int'(ClintIdx));
    check("decode PLIC", last_match(64'hC00_0000, rules) == int'(PlicIdx));
    check("decode UART", last_match(64'h1000_0000, rules) == int'(UartIdx));
    check("decode GPIO", last_match(64'h4000_0000, rules) == int'(GpioIdx));
    check("decode guest virtio",
          last_match(ApuHarness.MmioBase, rules) == int'(GuestIdx));
    check("decode firmware control",
          last_match(ApuHarness.ControlBase, rules) == int'(CtrlIdx));
    check("decode DRAM lo", last_match(DramBase, rules) == int'(DramIdx));
    check("decode firmware RAM",
          last_match(ApuHarness.FirmwareRamBase, rules) == int'(RamIdx));
    check("decode DRAM hi",
          last_match(apu_dram_hi_start(ApuHarness.FirmwareRamBase,
                                       ApuHarness.FirmwareRamBytes),
                     rules) == int'(DramIdx));
    check("GPIO does not steal guest",
          last_match(64'h4000_0fff, rules) == int'(GpioIdx) &&
          last_match(64'h4000_1000, rules) == int'(GuestIdx));
    check("aliased last-match steals RAM",
          last_match2(ApuHarness.FirmwareRamBase, aliased) == int'(DramIdx));
    check("DMA initiator idle",
          !dma_req.ar_valid && !dma_req.aw_valid &&
          !off_dma.ar_valid && !off_dma.aw_valid);
    check("disabled IRQ passthrough", off_irq === irq_in && off_plic === 1'b0);

    if (errors != 0) $fatal(1, "APU th osbi errors=%0d", errors);
    $display("PASS tb_g6lc_apu_th_osbi checks=%0d cycles=%0d errors=0",
             checks, cycles);
    $finish;
  end
endmodule
