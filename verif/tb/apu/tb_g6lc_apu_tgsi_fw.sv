// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Separate TGSI firmware image: compile MOV, shader RUN, peek TEMP[0].
// Does not replace the TID+IADD bring-up image.

`timescale 1ns/1ps

module tb_g6lc_apu_tgsi_fw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import axi_pkg::*;
  logic clk = 0, rst_ni = 0, hart_en = 0;
  apu_axi_req_t tb_req;
  apu_axi_resp_t ctrl_rsp;
  apu_dma_axi_req_t tb_ram;
  apu_dma_axi_resp_t fwram_rsp;
  apu_dma_axi_req_t dma_req;
  logic [31:0] cookie, image [2048];
  logic halt;
  logic [63:0] pc;
  axi_pkg::xbar_rule_64_t ram_rule;
  int errors = 0, checks = 0, cycles = 0, nwords = 0;

  g6lc_apu_minihart_sys i_sys (
    .clk_i(clk), .rst_ni, .hart_en_i(hart_en),
    .tb_ctrl_req_i(tb_req), .tb_ctrl_rsp_o(ctrl_rsp),
    .tb_ram_req_i(tb_ram), .tb_ram_rsp_o(fwram_rsp),
    .halt_o(halt), .cookie_o(cookie), .pc_o(pc),
    .dma_req_o(dma_req), .ram_rule_o(ram_rule)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin
    #20000000;
    $fatal(1, "tgsi fw timeout pc=%h cookie=%h cycles=%0d", pc, cookie, cycles);
  end

  initial begin
    string hexfile;
    hexfile = "apu_tgsi.hex";
    void'($value$plusargs("HEX=%s", hexfile));
    $readmemh(hexfile, image);
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s cycle=%0d pc=%h", name, cycles, pc);
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
  task automatic ram_write(input logic [63:0] a, input logic [31:0] d);
    logic [63:0] wdata;
    logic [7:0] strb;
    bit aw_done, w_done;
    pack32(a, d, wdata, strb);
    aw_done = 0; w_done = 0;
    @(negedge clk);
    tb_ram.aw.addr = a; tb_ram.aw.size = 3'd2; tb_ram.aw.len = '0;
    tb_ram.aw.burst = BURST_INCR; tb_ram.aw.id = '0;
    tb_ram.w.data = wdata; tb_ram.w.strb = strb; tb_ram.w.last = 1'b1;
    tb_ram.aw_valid = 1; tb_ram.w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (tb_ram.aw_valid && fwram_rsp.aw_ready) aw_done = 1;
      if (tb_ram.w_valid && fwram_rsp.w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) tb_ram.aw_valid = 0;
      if (w_done) tb_ram.w_valid = 0;
    end
    @(posedge clk);
    while (!fwram_rsp.b_valid) @(posedge clk);
    check("RAM B", fwram_rsp.b.resp == 0);
    @(negedge clk); tb_ram.b_ready = 1;
    @(posedge clk); @(negedge clk); tb_ram.b_ready = 0;
  endtask
  task automatic ram_read(input logic [63:0] a, output logic [31:0] data);
    @(negedge clk);
    tb_ram.ar.addr = a; tb_ram.ar.size = 3'd2; tb_ram.ar.len = '0;
    tb_ram.ar.burst = BURST_INCR; tb_ram.ar.id = '0;
    tb_ram.ar_valid = 1;
    @(posedge clk);
    while (!fwram_rsp.ar_ready) @(posedge clk);
    @(negedge clk); tb_ram.ar_valid = 0;
    @(posedge clk);
    while (!fwram_rsp.r_valid) @(posedge clk);
    unpack32(a, fwram_rsp.r.data, data);
    check("RAM R", fwram_rsp.r.resp == 0 && fwram_rsp.r.last);
    @(negedge clk); tb_ram.r_ready = 1;
    @(posedge clk); @(negedge clk); tb_ram.r_ready = 0;
  endtask
  task automatic send_write(input logic [63:0] a, input logic [31:0] d);
    bit aw_done, w_done;
    aw_done = 0; w_done = 0;
    @(negedge clk);
    tb_req.aw.addr = a; tb_req.aw.prot = 3'b000;
    tb_req.w.data = d; tb_req.w.strb = 4'hf;
    tb_req.aw_valid = 1; tb_req.w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (tb_req.aw_valid && ctrl_rsp.aw_ready) aw_done = 1;
      if (tb_req.w_valid && ctrl_rsp.w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) tb_req.aw_valid = 0;
      if (w_done) tb_req.w_valid = 0;
    end
    @(posedge clk);
    while (!ctrl_rsp.b_valid) @(posedge clk);
    check("AXI B", ctrl_rsp.b.resp == 0);
    @(negedge clk); tb_req.b_ready = 1;
    @(posedge clk); @(negedge clk); tb_req.b_ready = 0;
  endtask
  task automatic send_read(input logic [63:0] a, output logic [31:0] data);
    @(negedge clk);
    tb_req.ar.addr = a; tb_req.ar.prot = 3'b000; tb_req.ar_valid = 1;
    @(posedge clk);
    while (!ctrl_rsp.ar_ready) @(posedge clk);
    @(negedge clk); tb_req.ar_valid = 0;
    @(posedge clk);
    while (!ctrl_rsp.r_valid) @(posedge clk);
    data = ctrl_rsp.r.data;
    check("AXI R", ctrl_rsp.r.resp == 0);
    @(negedge clk); tb_req.r_ready = 1;
    @(posedge clk); @(negedge clk); tb_req.r_ready = 0;
  endtask
  task automatic ctrl_read(input logic [15:0] a, output logic [31:0] data);
    send_read(APU_CONTROL_BASE + 64'(a), data);
  endtask
  task automatic ctrl_write(input logic [15:0] a, input logic [31:0] d);
    send_write(APU_CONTROL_BASE + 64'(a), d);
  endtask
  task automatic mail_word(input int unsigned idx, input logic [31:0] data);
    ctrl_write(ACTRL_MAIL_IDX, idx);
    ctrl_write(ACTRL_MAIL_DATA, data);
  endtask
  task automatic mail_go(input apu_mem_op_e op, input apu_dma_status_e st);
    logic [31:0] stat;
    int spins;
    ctrl_write(ACTRL_MAIL_GO, 32'(op));
    spins = 0;
    do begin
      ctrl_read(ACTRL_MAIL_STAT, stat);
      spins++;
      if (spins > 4000) $fatal(1, "mail busy timeout");
    end while ((stat & ACTRL_MAIL_BUSY) != 0);
    check("mail status", stat[3:0] == 4'(st));
  endtask

  initial begin
    logic [31:0] r;
    integer i;
    tb_req = '0; tb_ram = '0;
    hart_en = 0;
    repeat (4) @(negedge clk);
    rst_ni = 1;
    repeat (2) @(negedge clk);

    nwords = 0;
    for (i = 0; i < 2048; i++)
      if (image[i] !== 32'hx && image[i] !== 32'h0)
        nwords = i + 1;
    check("tgsi image loaded", nwords > 4);
    for (i = 0; i < nwords; i++)
      ram_write(64'h9000_0000 + 64'(i * 4), image[i]);

    hart_en = 1;
    while (!halt) @(posedge clk);
    check("spin pc", pc == 64'h9000_000c);
    check("tgsi cookie", cookie == 32'h600D_000B);

    @(negedge clk);
    hart_en = 0;
    repeat (4) @(negedge clk);

    ram_read(64'h9003_FF00, r);
    check("ram tgsi cookie", r == 32'h600D_000B);
    mail_word(0, 0); mail_word(1, 4);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("shader t0 r4", r == 32'h3f800000);
    mail_word(0, 1); mail_word(1, 4);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("shader t1 r4", r == 32'h3f800000);
    check("dma idle", dma_req == '0);

    if (errors != 0) $fatal(1, "APU tgsi fw errors=%0d", errors);
    $display("PASS tb_g6lc_apu_tgsi_fw checks=%0d cycles=%0d errors=0 cookie=%h nwords=%0d",
             checks, cycles, cookie, nwords);
    $finish;
  end
endmodule
