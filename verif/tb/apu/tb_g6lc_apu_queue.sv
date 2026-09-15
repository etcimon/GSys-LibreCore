// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_queue_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  localparam logic [63:0] WindowBase = 64'h8000_0000;
  function automatic apu_cfg_t q_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.DmaWriteEn = enabled;
    cfg.DmaWindowBase = WindowBase;
    cfg.DmaWindowBytes = 64'h1000_0000;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = WindowBase + 64'h1000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
endpackage

module g6lc_apu_queue_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1) (
  input logic clk_i, rst_ni, testmode_i, enable_i, cancel_i,
  input logic used_valid_i,
  output logic used_ready_o,
  input apu_used_req_t used_i,
  output logic used_cpl_valid_o,
  input logic used_cpl_ready_i,
  output apu_map_cpl_t used_cpl_o,
  output logic idle_o, bus_fault_o,
  output apu_dma_axi_req_t axi_req_o,
  input apu_dma_axi_resp_t axi_rsp_i
);
  g6lc_apu_queue #(.ApuCfg(g6lc_queue_test_pkg::q_cfg(Enable))) i_dut (.*);
endmodule

module tb_g6lc_apu_queue;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_queue_test_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic enable, cancel, uv, ur, ucv, ucr, idle, fault;
  apu_used_req_t ureq;
  apu_map_cpl_t ucpl;
  apu_dma_axi_req_t axi_req;
  apu_dma_axi_resp_t axi_rsp;
  logic off_ur, off_ucv, off_idle, off_fault;
  apu_dma_axi_req_t off_axi;
  logic allow_aw, allow_w, allow_b, aw_seen, w_seen, executed, bvalid, inject_err;
  apu_dma_axi_aw_chan_t model_aw;
  apu_dma_axi_w_chan_t model_w;
  int errors = 0, checks = 0, cycles = 0, cases = 0, aw_count, w_count;
  logic [7:0] memory [0:4095];

  g6lc_apu_queue_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .used_valid_i(uv), .used_ready_o(ur), .used_i(ureq),
    .used_cpl_valid_o(ucv), .used_cpl_ready_i(ucr), .used_cpl_o(ucpl),
    .idle_o(idle), .bus_fault_o(fault), .axi_req_o(axi_req), .axi_rsp_i(axi_rsp)
  );
  g6lc_apu_queue_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .used_valid_i(uv), .used_ready_o(off_ur), .used_i(ureq),
    .used_cpl_valid_o(off_ucv), .used_cpl_ready_i(ucr), .used_cpl_o(),
    .idle_o(off_idle), .bus_fault_o(off_fault), .axi_req_o(off_axi), .axi_rsp_i(axi_rsp)
  );
  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #10000000; $fatal(1, "queue timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_ur, off_ucv, off_fault, off_axi} !== '0 || off_idle !== 1'b1)
      $fatal(1, "disabled queue active");
  end
  always_comb begin
    axi_rsp = '0;
    axi_rsp.aw_ready = allow_aw && !aw_seen && !bvalid;
    axi_rsp.w_ready = allow_w && !w_seen && !bvalid && cycles % 3 != 0;
    axi_rsp.b_valid = bvalid;
    axi_rsp.b.id = 1;
    axi_rsp.b.resp = inject_err ? 2'b10 : 2'b00;
  end
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_seen <= 0; w_seen <= 0; executed <= 0; bvalid <= 0;
      model_aw <= '0; model_w <= '0; aw_count <= 0; w_count <= 0;
    end else begin
      if (axi_req.aw_valid && axi_rsp.aw_ready) begin
        aw_seen <= 1; model_aw <= axi_req.aw; aw_count <= aw_count + 1;
      end
      if (axi_req.w_valid && axi_rsp.w_ready) begin
        w_seen <= 1; model_w <= axi_req.w; w_count <= w_count + 1;
      end
      if (aw_seen && w_seen && !executed) begin
        executed <= 1;
        for (int b = 0; b < 8; b++) if (model_w.strb[b])
          memory[int'((model_aw.addr & ~64'd7) + 64'(b) - WindowBase)] <= model_w.data[8*b +: 8];
      end
      if (executed && !bvalid && allow_b && cycles % 4 != 0) bvalid <= 1;
      if (bvalid && axi_req.b_ready) begin
        bvalid <= 0; aw_seen <= 0; w_seen <= 0; executed <= 0;
      end
    end
  end
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin errors++; $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles); end
  endtask
  task automatic reset_all;
    @(negedge clk); rst_ni = 0; uv = 0; ucr = 0; cancel = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1; enable = 1; allow_aw = 1; allow_w = 1; allow_b = 1; inject_err = 0;
    for (int i = 0; i < 4096; i++) memory[i] = 8'ha5;
  endtask
  function automatic apu_used_req_t mkused(input logic [15:0] num, idx, input logic [31:0] id, len);
    mkused = '{
      mapping: '{valid: 1, permissions: 2'b10, resource_id: 7, context_id: 3, epoch: 5,
                 base: WindowBase, bytes: 64'h1000},
      offset: 64'h40, queue_num: num, idx: idx, desc_id: id, len: len, qid: 0,
      context_id: 9, fence: 64'h1111_2222_3333_4444, tag: 64'(cases + 1)
    };
  endfunction
  task automatic publish(input apu_used_req_t req, input apu_dma_status_e st,
                         input bit do_cancel = 0);
    logic [15:0] saved_idx;
    int elem;
    saved_idx = {memory[67], memory[66]};
    aw_count = 0;
    @(negedge clk); while (!ur) @(negedge clk);
    cases++; ureq = req; uv = 1; @(posedge clk); @(negedge clk); uv = 0; ureq = '0;
    if (do_cancel) begin
      while (aw_count == 0 && !ucv) @(negedge clk);
      cancel = 1;
      repeat (6) begin @(negedge clk); check("used cancel waits for AXI", !ucv && !ur); end
      allow_b = 1;
    end
    while (!ucv) @(negedge clk);
    check("used status", ucpl.status == st);
    check("used tag", ucpl.tag == 64'(cases));
    if (st == APU_DMA_OK) begin
      elem = 64 + 4 + 8 * int'(req.idx % req.queue_num);
      check("used id", {memory[elem+3], memory[elem+2], memory[elem+1], memory[elem]} == req.desc_id);
      check("used len", {memory[elem+7], memory[elem+6], memory[elem+5], memory[elem+4]} == req.len);
      check("used idx published", {memory[67], memory[66]} == (req.idx + 16'd1));
    end
    if (do_cancel) check("cancelled idx not published", {memory[67], memory[66]} == saved_idx);
    ucr = 1; @(posedge clk); @(negedge clk); ucr = 0; cancel = 0;
  endtask

  initial begin
    ureq = '0;
    reset_all();
    check("used ring bytes", apu_used_ring_bytes(16'd64) == 64'd516);
    check("elem 0", apu_used_elem_off(16'd64, 0) == 64'd4);
    check("elem wrap", apu_used_elem_off(16'd8, 16'd9) == 64'd12);
    memory[66] = 0; memory[67] = 0;
    publish(mkused(64, 0, 32'h11, 32'h22), APU_DMA_OK);
    publish(mkused(64, 1, 32'haa, 32'hbb), APU_DMA_OK);
    publish(mkused(8, 9, 32'h2, 32'h4), APU_DMA_OK);
    begin
      apu_used_req_t bad;
      bad = mkused(7, 0, 1, 1);
      publish(bad, APU_DMA_LIMIT);
      bad = mkused(64, 0, 1, 1);
      bad.offset = 64'h0f00;
      publish(bad, APU_DMA_BOUNDS);
      bad = mkused(64, 0, 1, 1);
      bad.mapping.permissions = 2'b01;
      publish(bad, APU_DMA_PERMISSION);
    end
    memory[66] = 8'hfe; memory[67] = 8'hff;
    publish(mkused(64, 16'hffff, 32'h3, 32'h5), APU_DMA_OK);
    check("idx wrap", {memory[67], memory[66]} == 16'h0);
    inject_err = 1;
    publish(mkused(64, 3, 32'h8, 32'h9), APU_DMA_BUS_ERROR);
    inject_err = 0;
    reset_all();
    memory[66] = 8'h10; memory[67] = 8'h00;
    allow_b = 0;
    publish(mkused(64, 4, 32'h77, 32'h88), APU_DMA_CANCELLED, 1);
    allow_b = 1;
    if (errors != 0) $fatal(1, "APU queue errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_queue cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
