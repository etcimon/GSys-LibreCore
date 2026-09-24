// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// g6lc_apu_sched runs a mapping op and a local exec op on one device.
// The two clients are not presented an op in the same cycle. Exec does
// not read the mapping. Enable=0 stays quiet. ApuHarness keeps both off.

`timescale 1ns/1ps

module g6lc_apu_sched_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  apu_reg_req_t req_i,
  output apu_reg_rsp_t rsp_o,
  input  logic cancel_i,
  output logic idle_o,
  output logic bus_fault_o,
  output apu_dma_axi_req_t dma_req_o,
  input  apu_dma_axi_resp_t dma_rsp_i
);
  if (!Enable) begin : gen_off
    g6lc_apu_sched #(.ApuCfg(ApuOff), .Enable(1'b0)) i_dut (
      .clk_i, .rst_ni, .testmode_i, .req_i, .rsp_o, .cancel_i,
      .idle_o, .bus_fault_o, .dma_req_o, .dma_rsp_i
    );
  end else begin : gen_on
    g6lc_apu_sched #(.ApuCfg(ApuSchedBoth), .Enable(1'b1)) i_dut (
      .clk_i, .rst_ni, .testmode_i, .req_i, .rsp_o, .cancel_i,
      .idle_o, .bus_fault_o, .dma_req_o, .dma_rsp_i
    );
  end
endmodule

module tb_g6lc_apu_sched;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  logic clk = 0, rst_ni = 0;
  apu_reg_req_t req, req_off = '0;
  apu_reg_rsp_t rsp, rsp_off;
  apu_dma_axi_req_t dma_req, dma_off;
  apu_dma_axi_resp_t dma_rsp;
  logic idle, bus_fault, idle_off, fault_off;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  bit saw_dma = 0, saw_off_busy = 0;

  assign dma_rsp = '0;
  g6lc_apu_sched_fixture #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b0),
    .req_i(req), .rsp_o(rsp), .cancel_i(1'b0),
    .idle_o(idle), .bus_fault_o(bus_fault),
    .dma_req_o(dma_req), .dma_rsp_i(dma_rsp)
  );
  g6lc_apu_sched_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b0),
    .req_i(req_off), .rsp_o(rsp_off), .cancel_i(1'b0),
    .idle_o(idle_off), .bus_fault_o(fault_off),
    .dma_req_o(dma_off), .dma_rsp_i(dma_rsp)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && (dma_req.aw_valid || dma_req.ar_valid || dma_req.w_valid))
      saw_dma = 1;
    if (rst_ni && !idle_off) saw_off_busy = 1;
  end
  initial begin #200000; $fatal(1, "sched timeout case=%0d", cases); end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic reg_write(input logic [15:0] addr, input logic [31:0] data);
    @(negedge clk);
    req = '0;
    req.addr = 64'(addr);
    req.write = 1'b1;
    req.wdata = data;
    req.wstrb = 4'hf;
    req.valid = 1'b1;
    @(posedge clk);
    check("mailbox write", rsp.ready && !rsp.error);
    @(negedge clk);
    req.valid = 1'b0;
  endtask

  task automatic reg_read(input logic [15:0] addr, output logic [31:0] data);
    @(negedge clk);
    req = '0;
    req.addr = 64'(addr);
    req.valid = 1'b1;
    @(posedge clk);
    data = rsp.rdata;
    check("mailbox read", rsp.ready && !rsp.error);
    @(negedge clk);
    req.valid = 1'b0;
  endtask

  task automatic mail(input int unsigned idx, input logic [31:0] data);
    reg_write(ACTRL_MAIL_IDX, 32'(idx));
    reg_write(ACTRL_MAIL_DATA, data);
  endtask

  task automatic mail_go(input apu_mem_op_e op, input apu_dma_status_e st);
    logic [31:0] stat;
    int spins;
    reg_write(ACTRL_MAIL_GO, 32'(op));
    spins = 0;
    do begin
      reg_read(ACTRL_MAIL_STAT, stat);
      spins++;
      if (spins > 200) $fatal(1, "mail busy op=%0d", op);
    end while ((stat & ACTRL_MAIL_BUSY) != 0);
    check("mail status", stat[3:0] == 4'(st));
    check("scheduler is idle", idle && !bus_fault);
  endtask

  initial begin
    logic [31:0] got;
    apu_cfg_t mem;
    req = '0;
    cases = 1;
    check("harness keeps memory and exec off",
          ApuHarness.ExecEn === 1'b0 && ApuHarness.MaxResources === 0);
    check("sched profile is legal", apu_cfg_legal(ApuSchedBoth) &&
          apu_mem_exec_split(ApuSchedBoth));
    mem = ApuHarness;
    mem.MaxResources = 8;
    mem.DmaWindowBase = 64'h8000_0000;
    mem.DmaWindowBytes = 64'h0001_0000;
    check("resource table without exec is legal", apu_cfg_legal(mem));
    mem.ExecEn = 1'b1;
    check("resource table plus exec is legal",
          apu_cfg_legal(mem) && apu_mem_exec_split(mem));
    mem.MaxResources = 0;
    mem.ExecEn = 1'b1;
    mem.DmaReadEn = 1'b1;
    check("dma read plus exec is legal", apu_cfg_legal(mem));
    mem = ApuHarness;
    mem.ExecEn = 1'b1;
    check("exec without a memory client is legal",
          apu_cfg_legal(mem) && apu_mem_exec_split(mem));

    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);

    cases = 2;
    mail(0, 32'd0);
    mail(1, 32'd1);
    // bit 0 valid, bit 1 read permission. Lookup rejects a slot with neither.
    mail(4, 32'd3);
    mail(5, 32'h8000_1000);
    mail(6, 32'd0);
    mail(7, 32'h1000);
    mail(8, 32'd0);
    mail_go(APU_MEM_MAP_INSERT, APU_DMA_OK);
    reg_read(ACTRL_MAIL_CPL0, got);
    check("insert returns the resource", got == 32'd1);
    mail_go(APU_MEM_MAP_LOOKUP, APU_DMA_OK);
    reg_write(ACTRL_MAIL_IDX, 32'd5);
    reg_read(ACTRL_MAIL_DATA, got);
    check("lookup returns the mapping base", got == 32'h8000_1000);

    cases = 3;
    mail(0, 32'd0);
    mail(1, apu_exec_enc(APU_EX_LDI, 4'd1, 4'd0, 4'd0, 4'd0, 1'b0, 1'b0, 9'd10));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail(0, 32'd1);
    mail(1, apu_exec_enc(APU_EX_HALT, 4'd0, 4'd0, 4'd0, 4'd0, 1'b0, 1'b0, 9'd0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail(0, 32'd0);
    mail_go(APU_MEM_EXEC_RUN, APU_DMA_OK);
    mail(0, 32'd0);
    mail(1, 32'd1);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    reg_read(ACTRL_MAIL_CPL0, got);
    check("exec peek is 10", got == 32'd10);

    cases = 4;
    mail(1, 32'd1);
    mail_go(APU_MEM_MAP_LOOKUP, APU_DMA_OK);
    reg_write(ACTRL_MAIL_IDX, 32'd5);
    reg_read(ACTRL_MAIL_DATA, got);
    check("mapping survives the exec op", got == 32'h8000_1000);
    check("no DMA during memory and exec", !saw_dma);
    check("disabled scheduler stays idle", idle_off && !fault_off && !saw_off_busy);
    check("disabled scheduler issues no DMA",
          !dma_off.aw_valid && !dma_off.ar_valid && !dma_off.w_valid);
    @(negedge clk);
    req_off.addr = 64'(ACTRL_MAIL_GO);
    req_off.write = 1'b1;
    req_off.wdata = 32'(APU_MEM_EXEC_RUN);
    req_off.wstrb = 4'hf;
    req_off.valid = 1'b1;
    @(posedge clk);
    check("disabled mailbox write errors", rsp_off.ready && rsp_off.error);
    @(negedge clk);
    req_off.valid = 1'b0;
    check("disabled scheduler is still idle", idle_off && !saw_off_busy);

    if (errors != 0) $fatal(1, "APU sched errors=%0d", errors);
    $display("PASS tb_g6lc_apu_sched cases=%0d checks=%0d cycles=%0d errors=0",
             cases, checks, cycles);
    $finish;
  end
endmodule
