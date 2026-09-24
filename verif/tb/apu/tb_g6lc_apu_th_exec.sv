// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Testharness compositor mailbox exec: ExecEn=1 && !MemEn binds native exec
// under g6lc_apu_sys. Memory plus exec is legal in g6lc_apu_sched; this
// fixture stays exec-only. AXI4 control TID+IADD peek 10/11.
// ApuHarness.ExecEn stays 0. Not CVA6, not OpenSBI, not TEX.

`timescale 1ns/1ps

package g6lc_th_exec_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t exec_cfg(input bit enabled, input bit exec_en,
      input int unsigned bytes = 0);
    apu_cfg_t cfg = ApuHarness;
    cfg.Enable = enabled;
    cfg.ExecEn = enabled && exec_en;
    cfg.ExecQuadThreads = 4;
    cfg.ExecRegs = 8;
    cfg.ExecMemWords = 64;
    if (!enabled) cfg.FirmwareHart = APU_FW_HART_UNASSIGNED;
    if (bytes != 0) cfg.FirmwareRamBytes = 64'(bytes);
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t exec_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
endpackage

module g6lc_apu_th_exec_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1'b1, parameter bit ExecEn = 1'b1,
  parameter int unsigned RamBytes = 0, parameter HexFile = "none") (
  input  logic clk_i, rst_ni, testmode_i,
  input  apu_dma_axi_req_t guest_req_i, control_req_i, ram_req_i,
  output apu_dma_axi_resp_t guest_rsp_o, control_rsp_o, ram_rsp_o,
  input  logic [31:0] control_aw_hart_i, control_ar_hart_i,
  input  logic [31:0] ram_aw_hart_i, ram_ar_hart_i,
  input  logic [29:0] irq_sources_i,
  output logic [29:0] irq_sources_o,
  output logic plic_irq_o, fw_ready_o,
  output logic [1:0][38:0] boot_addr_core_o,
  output axi_pkg::xbar_rule_64_t guest_rule_o, control_rule_o, ram_rule_o,
         dram_lo_rule_o, dram_hi_rule_o,
  output apu_dma_axi_req_t dma_req_o,
  input  apu_dma_axi_resp_t dma_rsp_i,
  output logic ram_fault_o
);
  g6lc_apu_th_load #(
    .ApuCfg(g6lc_th_exec_test_pkg::exec_cfg(Enable, ExecEn, RamBytes)),
    .CoreCfg(g6lc_th_exec_test_pkg::exec_core()),
    .HexFile(HexFile)
  ) i_dut (.*);
endmodule

module tb_g6lc_apu_th_exec;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import axi_pkg::*;
  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t zreq, ctrl_req, guest_req;
  apu_dma_axi_resp_t ctrl_rsp, guest_rsp, ram_rsp;
  logic [31:0] aw_hart, ar_hart;
  logic [29:0] irq_in, irq_out, off_irq;
  logic plic, off_plic, fw_ready, off_ready;
  logic [1:0][38:0] boot, off_boot;
  axi_pkg::xbar_rule_64_t guest_rule, ctrl_rule, ram_rule, dram_lo, dram_hi;
  axi_pkg::xbar_rule_64_t off_guest, off_ctrl, off_ram, off_lo, off_hi;
  apu_dma_axi_req_t dma_req, off_dma;
  apu_dma_axi_resp_t dma_rsp;
  logic ram_fault, off_ram_fault;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  assign zreq = '0;
  assign dma_rsp = '0;
  g6lc_apu_th_exec_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(guest_req), .control_req_i(ctrl_req), .ram_req_i(zreq),
    .guest_rsp_o(guest_rsp), .control_rsp_o(ctrl_rsp), .ram_rsp_o(ram_rsp),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .ram_aw_hart_i(aw_hart), .ram_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(irq_out),
    .plic_irq_o(plic), .fw_ready_o(fw_ready),
    .boot_addr_core_o(boot),
    .guest_rule_o(guest_rule), .control_rule_o(ctrl_rule), .ram_rule_o(ram_rule),
    .dram_lo_rule_o(dram_lo), .dram_hi_rule_o(dram_hi),
    .dma_req_o(dma_req), .dma_rsp_i(dma_rsp),
    .ram_fault_o(ram_fault)
  );
  g6lc_apu_th_exec_fixture #(.Enable(0), .ExecEn(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(zreq), .control_req_i(zreq), .ram_req_i(zreq),
    .guest_rsp_o(), .control_rsp_o(), .ram_rsp_o(),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .ram_aw_hart_i(aw_hart), .ram_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(off_irq),
    .plic_irq_o(off_plic), .fw_ready_o(off_ready),
    .boot_addr_core_o(off_boot),
    .guest_rule_o(off_guest), .control_rule_o(off_ctrl), .ram_rule_o(off_ram),
    .dram_lo_rule_o(off_lo), .dram_hi_rule_o(off_hi),
    .dma_req_o(off_dma), .dma_rsp_i(dma_rsp),
    .ram_fault_o(off_ram_fault)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "th exec timeout case=%0d", cases); end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  task automatic pack32(input logic [63:0] a, input logic [31:0] d,
      output logic [63:0] data, output logic [7:0] strb);
    if (a[2]) begin data = {d, 32'h0}; strb = 8'hf0; end
    else begin data = {32'h0, d}; strb = 8'h0f; end
  endtask
  task automatic unpack32(input logic [63:0] a, input logic [63:0] data,
      output logic [31:0] d);
    d = a[2] ? data[63:32] : data[31:0];
  endtask
  task automatic ctrl_write(input logic [15:0] a, input logic [31:0] d,
      input logic [1:0] expected = 0);
    logic [63:0] addr, wdata;
    logic [7:0] strb;
    bit aw_done, w_done;
    addr = APU_CONTROL_BASE + 64'(a);
    pack32(addr, d, wdata, strb);
    aw_done = 0; w_done = 0;
    @(negedge clk);
    ctrl_req.aw.addr = addr; ctrl_req.aw.size = 3'd2; ctrl_req.aw.len = '0;
    ctrl_req.aw.burst = BURST_INCR; ctrl_req.aw.id = '0;
    ctrl_req.w.data = wdata; ctrl_req.w.strb = strb; ctrl_req.w.last = 1'b1;
    ctrl_req.aw_valid = 1; ctrl_req.w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (ctrl_req.aw_valid && ctrl_rsp.aw_ready) aw_done = 1;
      if (ctrl_req.w_valid && ctrl_rsp.w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) ctrl_req.aw_valid = 0;
      if (w_done) ctrl_req.w_valid = 0;
    end
    @(posedge clk);
    while (!ctrl_rsp.b_valid) @(posedge clk);
    check("AXI B", ctrl_rsp.b.resp == expected);
    @(negedge clk); ctrl_req.b_ready = 1;
    @(posedge clk); @(negedge clk); ctrl_req.b_ready = 0;
  endtask
  task automatic ctrl_read(input logic [15:0] a, output logic [31:0] data,
      input logic [1:0] expected = 0);
    logic [63:0] addr;
    addr = APU_CONTROL_BASE + 64'(a);
    @(negedge clk);
    ctrl_req.ar.addr = addr; ctrl_req.ar.size = 3'd2; ctrl_req.ar.len = '0;
    ctrl_req.ar.burst = BURST_INCR; ctrl_req.ar.id = '0;
    ctrl_req.ar_valid = 1;
    @(posedge clk);
    while (!ctrl_rsp.ar_ready) @(posedge clk);
    @(negedge clk); ctrl_req.ar_valid = 0;
    @(posedge clk);
    while (!ctrl_rsp.r_valid) @(posedge clk);
    unpack32(addr, ctrl_rsp.r.data, data);
    check("AXI R", ctrl_rsp.r.resp == expected && ctrl_rsp.r.last);
    @(negedge clk); ctrl_req.r_ready = 1;
    @(posedge clk); @(negedge clk); ctrl_req.r_ready = 0;
  endtask
  task automatic ctrl_write64(input logic [15:0] a, input logic [31:0] lo,
      input logic [31:0] hi, input logic [1:0] expected = 0);
    logic [63:0] addr;
    bit aw_done, w_done;
    addr = APU_CONTROL_BASE + 64'(a);
    aw_done = 0; w_done = 0;
    @(negedge clk);
    ctrl_req.aw.addr = addr; ctrl_req.aw.size = 3'd3; ctrl_req.aw.len = '0;
    ctrl_req.aw.burst = BURST_INCR; ctrl_req.aw.id = '0;
    ctrl_req.w.data = {hi, lo}; ctrl_req.w.strb = 8'hff; ctrl_req.w.last = 1'b1;
    ctrl_req.aw_valid = 1; ctrl_req.w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (ctrl_req.aw_valid && ctrl_rsp.aw_ready) aw_done = 1;
      if (ctrl_req.w_valid && ctrl_rsp.w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) ctrl_req.aw_valid = 0;
      if (w_done) ctrl_req.w_valid = 0;
    end
    @(posedge clk);
    while (!ctrl_rsp.b_valid) @(posedge clk);
    check("AXI B64", ctrl_rsp.b.resp == expected);
    @(negedge clk); ctrl_req.b_ready = 1;
    @(posedge clk); @(negedge clk); ctrl_req.b_ready = 0;
  endtask
  task automatic mail_word(input int unsigned idx, input logic [31:0] data);
    ctrl_write(ACTRL_MAIL_IDX, idx);
    ctrl_write(ACTRL_MAIL_DATA, data);
  endtask
  task automatic mail_word64(input logic [31:0] idx, input logic [31:0] data);
    ctrl_write64(ACTRL_MAIL_IDX, idx, data);
  endtask
  task automatic mail_go(input apu_mem_op_e op, input apu_dma_status_e st);
    logic [31:0] stat;
    int spins;
    cases++;
    ctrl_write(ACTRL_MAIL_GO, 32'(op));
    spins = 0;
    do begin
      ctrl_read(ACTRL_MAIL_STAT, stat);
      spins++;
      if (spins > 4000) $fatal(1, "mail busy timeout op=%0d", op);
    end while ((stat & ACTRL_MAIL_BUSY) != 0);
    check("mail status", stat[3:0] == 4'(st));
  endtask

  initial begin
    logic [31:0] r;
    integer i;
    apu_cfg_t harness;
    aw_hart = 1; ar_hart = 1; irq_in = '0;
    ctrl_req = '0; guest_req = '0;
    harness = ApuHarness;
    repeat (4) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);

    cases = 1;
    check("ApuHarness exec stays off", harness.ExecEn === 1'b0);
    begin
      apu_cfg_t mem;
      mem = g6lc_th_exec_test_pkg::exec_cfg(1'b1, 1'b0);
      mem.MaxResources = 8;
      mem.DmaWindowBase = 64'h8000_0000;
      mem.DmaWindowBytes = 64'h0001_0000;
      check("resource table without exec is legal", apu_cfg_legal(mem));
      mem.ExecEn = 1'b1;
      check("resource table plus exec is legal",
            apu_cfg_legal(mem) && apu_mem_exec_split(mem));
      mem.ExecEn = 1'b0;
      mem.MaxResources = 0;
      mem.DmaReadEn = 1'b1;
      check("dma read without exec is legal", apu_cfg_legal(mem));
      mem.ExecEn = 1'b1;
      check("dma read plus exec is legal",
            apu_cfg_legal(mem) && apu_mem_exec_split(mem));
      check("exec without a memory client is legal",
            apu_cfg_legal(g6lc_th_exec_test_pkg::exec_cfg(1'b1, 1'b1)));
    end
    check("ctrl idx 11", ctrl_rule.idx == 11);
    check("hart 1 boots firmware RAM", boot[1] == 39'h90000000);
    check("DMA initiator idle",
          !dma_req.ar_valid && !dma_req.aw_valid &&
          !off_dma.ar_valid && !off_dma.aw_valid);
    check("disabled hart 1 keeps ROM", off_boot[1] == 39'h10000);

    @(negedge clk);
    guest_req.ar.addr = APU_MMIO_BASE; guest_req.ar.size = 3'd2;
    guest_req.ar.len = '0; guest_req.ar.burst = BURST_INCR; guest_req.ar.id = '0;
    guest_req.ar_valid = 1;
    @(posedge clk);
    while (!guest_rsp.ar_ready) @(posedge clk);
    @(negedge clk); guest_req.ar_valid = 0;
    @(posedge clk);
    while (!guest_rsp.r_valid) @(posedge clk);
    unpack32(APU_MMIO_BASE, guest_rsp.r.data, r);
    check("guest virtio magic",
          guest_rsp.r.resp == 0 && guest_rsp.r.last && r == VIRTIO_MMIO_MAGIC);
    @(negedge clk); guest_req.r_ready = 1;
    @(posedge clk); @(negedge clk); guest_req.r_ready = 0;

    for (i = 0; i < APU_EXEC_IMEM; i++) begin
      mail_word(0, 32'(i));
      mail_word(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
      mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    end
    mail_word(0, 0);
    mail_word(1, apu_exec_enc(APU_EX_TID, 1, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 1);
    mail_word(1, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd10));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 2);
    mail_word(1, apu_exec_enc(APU_EX_IADD, 3, 1, 2, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 3);
    mail_word(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);

    mail_word(0, 0);
    mail_go(APU_MEM_EXEC_RUN, APU_DMA_OK);

    mail_word(0, 0);
    mail_word(1, 3);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("micro t0 r3", r == 32'd10);
    mail_word(0, 1);
    mail_word(1, 3);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("micro t1 r3", r == 32'd11);

    mail_word(0, 0);
    mail_word(1, apu_exec_enc(APU_EX_MOV, 4, 5, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 1);
    mail_word(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 0);
    mail_word(1, 5);
    mail_word(2, 32'h3f80_0000);
    mail_go(APU_MEM_EXEC_POKE, APU_DMA_OK);
    mail_word(0, 1);
    mail_word(1, 5);
    mail_word(2, 32'h3f80_0000);
    mail_go(APU_MEM_EXEC_POKE, APU_DMA_OK);
    mail_word(0, 1);
    mail_go(APU_MEM_EXEC_RUN, APU_DMA_OK);
    mail_word(0, 0);
    mail_word(1, 4);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("shader t0 r4", r == 32'h3f80_0000);
    mail_word(0, 1);
    mail_word(1, 4);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("shader t1 r4", r == 32'h3f80_0000);

    // Headless color: shader ST 1.0f to DMEM[0], mailbox DPEEK readback.
    mail_word(0, 0);
    mail_word(1, apu_exec_enc(APU_EX_LDI, 1, 0, 0, 0, 0, 0, 9'd0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 1);
    mail_word(1, apu_exec_enc(APU_EX_LDC, 2, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 2);
    mail_word(1, 32'h3f80_0000);
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 3);
    mail_word(1, apu_exec_enc(APU_EX_ST, 0, 1, 2, 0, 0, 0, 9'd0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 4);
    mail_word(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 1);
    mail_go(APU_MEM_EXEC_RUN, APU_DMA_OK);
    mail_word(2, 0);
    mail_go(APU_MEM_EXEC_DPEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("shader dmem[0] 1.0f", r == 32'h3f80_0000);

    // CVA6 WT may pack IDX+DATA (0x80/0x84) into one size=3 beat.
    ctrl_write64(ACTRL_MAIL_DATA, 32'hdead, 32'hbeef, 2);
    mail_word64(0, apu_exec_enc(APU_EX_MOV, 4, 5, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word64(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word64(0, 0);
    mail_word64(1, 5);
    mail_word64(2, 32'h3f80_0000);
    mail_go(APU_MEM_EXEC_POKE, APU_DMA_OK);
    mail_word64(0, 1);
    mail_word64(1, 5);
    mail_word64(2, 32'h3f80_0000);
    mail_go(APU_MEM_EXEC_POKE, APU_DMA_OK);
    mail_word64(0, 1);
    mail_go(APU_MEM_EXEC_RUN, APU_DMA_OK);
    mail_word64(0, 0);
    mail_word64(1, 4);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("size3 shader t0 r4", r == 32'h3f80_0000);
    mail_word64(0, 1);
    mail_word64(1, 4);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("size3 shader t1 r4", r == 32'h3f80_0000);

    // Scanline fill last so it cannot clobber earlier IMEM/RF cases.
    mail_word(0, 0);
    mail_word(1, apu_exec_enc(APU_EX_LDI, 1, 0, 0, 0, 0, 0, 9'd0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 1);
    mail_word(1, apu_exec_enc(APU_EX_LDI, 4, 0, 0, 0, 0, 0, 9'd4));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 2);
    mail_word(1, apu_exec_enc(APU_EX_LDC, 2, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 3);
    mail_word(1, 32'h3f80_0000);
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 4);
    mail_word(1, apu_exec_enc(APU_EX_MOV, 3, 1, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 5);
    mail_word(1, apu_exec_enc(APU_EX_IADD, 3, 3, 3, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 6);
    mail_word(1, apu_exec_enc(APU_EX_IADD, 3, 3, 3, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 7);
    mail_word(1, apu_exec_enc(APU_EX_ST, 0, 3, 2, 0, 0, 0, 9'd0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 8);
    mail_word(1, apu_exec_enc(APU_EX_LDI, 6, 0, 0, 0, 0, 0, 9'd1));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 9);
    mail_word(1, apu_exec_enc(APU_EX_IADD, 1, 1, 6, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 10);
    mail_word(1, apu_exec_enc(APU_EX_CMPLT, 0, 1, 4, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 11);
    mail_word(1, apu_exec_enc(APU_EX_BR, 0, 0, 0, 0, 0, 0, 9'h1F9));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 12);
    mail_word(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 0);
    mail_go(APU_MEM_EXEC_RUN, APU_DMA_OK);
    mail_word(2, 0);
    mail_go(APU_MEM_EXEC_DPEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("scanline dmem[0]", r == 32'h3f80_0000);
    mail_word(2, 1);
    mail_go(APU_MEM_EXEC_DPEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("scanline dmem[1]", r == 32'h3f80_0000);
    mail_word(2, 2);
    mail_go(APU_MEM_EXEC_DPEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("scanline dmem[2]", r == 32'h3f80_0000);
    mail_word(2, 3);
    mail_go(APU_MEM_EXEC_DPEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("scanline dmem[3]", r == 32'h3f80_0000);
    mail_word(2, 4);
    mail_go(APU_MEM_EXEC_DPEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("scanline dmem[4] empty", r == 32'h0);

    if (errors != 0) $fatal(1, "APU th exec errors=%0d", errors);
    $display("PASS tb_g6lc_apu_th_exec cases=%0d checks=%0d cycles=%0d errors=0",
             cases, checks, cycles);
    $finish;
  end
endmodule
