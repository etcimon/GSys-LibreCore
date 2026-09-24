// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Rejected AXI4 bursts drain before the response. A split store keeps an
// earlier half's error when the later half succeeds.

`timescale 1ns/1ps

module g6lc_apu_axi4_lite_fixture
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1) (
  input logic clk_i, rst_ni, testmode_i,
  input apu_dma_axi_req_t slv_req_i,
  output apu_dma_axi_resp_t slv_rsp_o,
  output apu_axi_req_t lite_req_o,
  input apu_axi_resp_t lite_rsp_i,
  input logic [31:0] epoch_i,
  output logic hold_o,
  output logic [31:0] admitted_o
);
  g6lc_apu_axi4_lite #(.Enable(Enable)) i_dut (.*);
endmodule

module tb_g6lc_apu_axi4_lite;
  import g6lc_apu_bus_pkg::*;
  import axi_pkg::*;
  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t req, off_req;
  apu_dma_axi_resp_t rsp, off_rsp;
  apu_axi_req_t lreq, off_lreq;
  apu_axi_resp_t lrsp, off_lrsp;
  logic hold, admitted_bit;
  logic [31:0] admitted;
  logic b_pend, r_pend, arm_clear;
  logic [1:0] b_resp, prog_resp [0:3];
  int beat_n, lite_writes, lite_reads;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_axi4_lite #(.Enable(1)) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .slv_req_i(req), .slv_rsp_o(rsp),
    .lite_req_o(lreq), .lite_rsp_i(lrsp),
    .epoch_i(32'h1), .hold_o(hold), .admitted_o(admitted)
  );
  g6lc_apu_axi4_lite #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .slv_req_i(off_req), .slv_rsp_o(off_rsp),
    .lite_req_o(off_lreq), .lite_rsp_i(off_lrsp),
    .epoch_i(32'h1), .hold_o(), .admitted_o()
  );

  assign admitted_bit = |admitted;
  assign off_lrsp = '0;
  assign lrsp.aw_ready = lreq.aw_valid && !b_pend;
  assign lrsp.w_ready = lreq.w_valid && !b_pend;
  assign lrsp.ar_ready = lreq.ar_valid && !r_pend;
  assign lrsp.b_valid = b_pend;
  assign lrsp.b.resp = b_resp;
  assign lrsp.r_valid = r_pend;
  assign lrsp.r.resp = RESP_OKAY;
  assign lrsp.r.data = 32'h0;

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "axi4 lite timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if (off_lreq !== '0) $fatal(1, "disabled bridge drove lite");
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      b_pend <= 1'b0; r_pend <= 1'b0; b_resp <= '0;
      beat_n <= 0; lite_writes <= 0; lite_reads <= 0;
    end else if (arm_clear) begin
      beat_n <= 0;
    end else begin
      if (lreq.aw_valid && lrsp.aw_ready && lreq.w_valid && lrsp.w_ready) begin
        lite_writes <= lite_writes + 1;
        b_pend <= 1'b1;
        b_resp <= prog_resp[beat_n];
        beat_n <= beat_n + 1;
      end else if (b_pend && lreq.b_ready) begin
        b_pend <= 1'b0;
      end
      if (lreq.ar_valid && lrsp.ar_ready) begin
        lite_reads <= lite_reads + 1;
        r_pend <= 1'b1;
      end else if (r_pend && lreq.r_ready) begin
        r_pend <= 1'b0;
      end
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic bus_idle;
    req = '0; off_req = '0;
    req.b_ready = 1'b1; req.r_ready = 1'b1;
    off_req.b_ready = 1'b1; off_req.r_ready = 1'b1;
  endtask

  task automatic arm(input logic [1:0] a, input logic [1:0] b);
    prog_resp[0] = a; prog_resp[1] = b; prog_resp[2] = RESP_OKAY; prog_resp[3] = RESP_OKAY;
    @(negedge clk); arm_clear = 1'b1;
    @(posedge clk); @(negedge clk); arm_clear = 1'b0;
  endtask

  task automatic aw(input logic [63:0] addr, input logic [7:0] len,
                    input logic [2:0] size, input logic [3:0] id, input logic on);
    if (on) begin
      req.aw = '0; req.aw.addr = addr; req.aw.len = len; req.aw.size = size;
      req.aw.burst = BURST_INCR; req.aw.id = id; req.aw_valid = 1'b1;
    end else begin
      off_req.aw = '0; off_req.aw.addr = addr; off_req.aw.len = len; off_req.aw.size = size;
      off_req.aw.burst = BURST_INCR; off_req.aw.id = id; off_req.aw_valid = 1'b1;
    end
  endtask

  task automatic wbeat(input logic [63:0] data, input logic [7:0] strb,
                       input logic last, input logic on);
    if (on) begin
      req.w = '0; req.w.data = data; req.w.strb = strb; req.w.last = last;
      req.w_valid = 1'b1;
    end else begin
      off_req.w = '0; off_req.w.data = data; off_req.w.strb = strb; off_req.w.last = last;
      off_req.w_valid = 1'b1;
    end
  endtask

  task automatic drop_aw_w(input logic on);
    if (on) begin req.aw_valid = 1'b0; req.w_valid = 1'b0; end
    else begin off_req.aw_valid = 1'b0; off_req.w_valid = 1'b0; end
  endtask

  task automatic wait_b(input logic on, input logic [3:0] id, input logic [1:0] resp);
    int guard;
    guard = 0;
    if (on) begin
      while (!rsp.b_valid) begin
        @(negedge clk); guard++;
        if (guard > 80) $fatal(1, "B timeout case=%0d", cases);
      end
      check("write id", rsp.b.id == id);
      check("write resp", rsp.b.resp == resp);
    end else begin
      while (!off_rsp.b_valid) begin
        @(negedge clk); guard++;
        if (guard > 80) $fatal(1, "disabled B timeout case=%0d", cases);
      end
      check("disabled write id", off_rsp.b.id == id);
      check("disabled write resp", off_rsp.b.resp == resp);
    end
    @(posedge clk); @(negedge clk);
  endtask

  task automatic one_write(input logic [2:0] size, input logic [7:0] strb,
                           input logic [1:0] resp, input int writes);
    int base;
    bus_idle(); arm(resp, RESP_OKAY);
    base = lite_writes;
    @(negedge clk);
    aw(64'h4000_1000, 8'd0, size, 4'h3, 1);
    wbeat(64'h1122_3344_5566_7788, strb, 1'b1, 1);
    @(posedge clk); @(negedge clk);
    drop_aw_w(1);
    wait_b(1, 4'h3, resp);
    check("lite writes", lite_writes == base + writes);
  endtask

  initial begin
    int i, base;
    arm_clear = 1'b0;
    bus_idle();
    repeat (4) @(negedge clk);
    rst_ni = 1;
    @(negedge clk);

    cases = 1;
    one_write(3'd2, 8'h0f, RESP_OKAY, 1);

    cases = 2;
    bus_idle(); arm(RESP_SLVERR, RESP_OKAY);
    base = lite_writes;
    @(negedge clk);
    aw(64'h4000_2000, 8'd0, 3'd3, 4'h5, 1);
    wbeat(64'hffff_0000_aaaa_5555, 8'hff, 1'b1, 1);
    @(posedge clk); @(negedge clk);
    drop_aw_w(1);
    wait_b(1, 4'h5, RESP_SLVERR);
    check("both halves reached lite", lite_writes == base + 2);

    cases = 3;
    bus_idle(); arm(RESP_OKAY, RESP_SLVERR);
    base = lite_writes;
    @(negedge clk);
    aw(64'h4000_2000, 8'd0, 3'd3, 4'h6, 1);
    wbeat(64'h1, 8'hff, 1'b1, 1);
    @(posedge clk); @(negedge clk);
    drop_aw_w(1);
    wait_b(1, 4'h6, RESP_SLVERR);
    check("second half still issued", lite_writes == base + 2);

    cases = 4;
    bus_idle(); arm(RESP_OKAY, RESP_OKAY);
    @(negedge clk);
    aw(64'h4000_2000, 8'd0, 3'd3, 4'h7, 1);
    wbeat(64'h2, 8'hff, 1'b1, 1);
    @(posedge clk); @(negedge clk);
    drop_aw_w(1);
    wait_b(1, 4'h7, RESP_OKAY);

    cases = 5;
    one_write(3'd3, 8'hf0, RESP_OKAY, 1);

    cases = 6;
    bus_idle(); arm(RESP_OKAY, RESP_OKAY);
    base = lite_writes;
    @(negedge clk);
    aw(64'h10, 8'd3, 3'd1, 4'h9, 1);
    @(posedge clk); @(negedge clk);
    req.aw_valid = 1'b0;
    check("no B before the first write beat", !rsp.b_valid);
    repeat (3) begin @(negedge clk); check("B stays low while data is outstanding", !rsp.b_valid); end
    check("rejected burst does not reach lite", lite_writes == base && !lreq.aw_valid);
    for (i = 0; i < 4; i++) begin
      @(negedge clk);
      wbeat(64'(i), 8'hff, i == 3, 1);
      @(posedge clk); @(negedge clk);
      req.w_valid = 1'b0;
      if (i != 3) check("B waits for the remaining beats", !rsp.b_valid);
    end
    wait_b(1, 4'h9, RESP_SLVERR);
    check("drained burst issued no lite write", lite_writes == base);

    cases = 7;
    bus_idle();
    base = lite_reads;
    @(negedge clk);
    req.ar = '0; req.ar.addr = 64'h20; req.ar.len = 8'd2; req.ar.size = 3'd0;
    req.ar.burst = BURST_INCR; req.ar.id = 4'ha; req.ar_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    req.ar_valid = 1'b0;
    for (i = 0; i < 3; i++) begin
      if (!rsp.r_valid) @(negedge clk);
      check("read error beat", rsp.r_valid && rsp.r.id == 4'ha && rsp.r.resp == RESP_SLVERR);
      check("read last only on the final beat", rsp.r.last == (i == 2));
      @(posedge clk); @(negedge clk);
    end
    check("rejected read does not reach lite", lite_reads == base && !rsp.r_valid);

    cases = 8;
    bus_idle();
    @(negedge clk);
    aw(64'h30, 8'd2, 3'd1, 4'hb, 1);
    wbeat(64'h0, 8'hff, 1'b1, 1);
    @(posedge clk); @(negedge clk);
    drop_aw_w(1);
    repeat (4) begin
      @(negedge clk);
      check("early last does not complete", !rsp.b_valid && !rsp.aw_ready && !rsp.w_ready);
    end
    rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(negedge clk);
    one_write(3'd2, 8'h0f, RESP_OKAY, 1);

    cases = 9;
    bus_idle();
    @(negedge clk);
    aw(64'h40, 8'd1, 3'd0, 4'hc, 0);
    @(posedge clk); @(negedge clk);
    off_req.aw_valid = 1'b0;
    check("disabled bridge has no B before W", !off_rsp.b_valid);
    @(negedge clk);
    wbeat(64'h1, 8'h01, 1'b0, 0);
    @(posedge clk); @(negedge clk);
    off_req.w_valid = 1'b0;
    check("disabled bridge holds B for the last beat", !off_rsp.b_valid);
    @(negedge clk);
    wbeat(64'h2, 8'h01, 1'b1, 0);
    @(posedge clk); @(negedge clk);
    off_req.w_valid = 1'b0;
    wait_b(0, 4'hc, RESP_SLVERR);
    @(negedge clk);
    off_req.ar = '0; off_req.ar.addr = 64'h44; off_req.ar.len = 8'd1; off_req.ar.size = 3'd2;
    off_req.ar.id = 4'hd; off_req.ar_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    off_req.ar_valid = 1'b0;
    for (i = 0; i < 2; i++) begin
      if (!off_rsp.r_valid) @(negedge clk);
      check("disabled read error beat", off_rsp.r_valid && off_rsp.r.resp == RESP_SLVERR);
      check("disabled read last", off_rsp.r.last == (i == 1));
      @(posedge clk); @(negedge clk);
    end

    if (errors != 0) $fatal(1, "APU axi4 lite errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_axi4_lite cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
