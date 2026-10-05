// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// 2:1 AXI DMA join. APU (A) wins over secondary (B). Enable=0 is idle.

`timescale 1ns/1ps

module tb_g6lc_apu_tdma;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t a_req, b_req, mst_req, off_mst;
  apu_dma_axi_resp_t a_rsp, b_rsp, mst_rsp, off_a, off_b;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  logic r_active, r_valid_q;
  logic [7:0] r_left;
  int unsigned ar_count;

  g6lc_apu_tdma #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .a_req_i(a_req), .a_rsp_o(a_rsp),
    .b_req_i(b_req), .b_rsp_o(b_rsp), .mst_req_o(mst_req), .mst_rsp_i(mst_rsp)
  );
  g6lc_apu_tdma_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .a_req_i(a_req), .a_rsp_o(off_a),
    .b_req_i(b_req), .b_rsp_o(off_b), .mst_req_o(off_mst), .mst_rsp_i(mst_rsp)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "tdma timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_mst !== '0 || off_a !== '0 || off_b !== '0)
      $fatal(1, "disabled tdma active");
  end

  always_comb begin
    mst_rsp = '0;
    mst_rsp.ar_ready = rst_ni && !r_active && !r_valid_q;
    mst_rsp.r_valid = r_valid_q;
    mst_rsp.r.last = r_valid_q && (r_left == 8'd1);
    mst_rsp.r.resp = axi_pkg::RESP_OKAY;
    mst_rsp.r.data = 64'hA5A5_0000_0000_0001;
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_active <= 1'b0;
      r_valid_q <= 1'b0;
      r_left <= '0;
      ar_count <= 0;
    end else begin
      if (mst_req.ar_valid && mst_rsp.ar_ready) begin
        r_active <= 1'b1;
        r_left <= mst_req.ar.len + 8'd1;
        ar_count <= ar_count + 1;
      end
      if (r_active && !r_valid_q) r_valid_q <= 1'b1;
      if (r_valid_q && mst_req.r_ready) begin
        r_valid_q <= 1'b0;
        r_left <= r_left - 8'd1;
        if (r_left == 8'd1) r_active <= 1'b0;
      end
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d ar_count=%0d", name, cases, cycles,
               ar_count);
    end
  endtask

  task automatic idle_bus;
    a_req = '0;
    b_req = '0;
    a_req.r_ready = 1'b1;
    b_req.r_ready = 1'b1;
  endtask

  task automatic do_reset;
    idle_bus();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic wait_idle;
    while (r_active || r_valid_q) @(posedge clk);
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    idle_bus();
    do_reset;
    cases++;
    check("off stays quiet", off_mst === '0);
    check("profiles keep tdma off",
          !ApuOff.TdmaEn && !ApuP1Transport.TdmaEn && !ApuHarness.TdmaEn);
    cfg = ApuP1Transport;
    cfg.TdmaEn = 1'b1;
    check("tdma does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TdmaEn = 1'b1;
    check("tdma does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    a_req.ar_valid = 1'b1;
    a_req.ar.addr = 64'h8000_1000;
    a_req.ar.len = 8'd1;
    a_req.ar.size = 3'd3;
    a_req.ar.burst = axi_pkg::BURST_INCR;
    do @(posedge clk); while (!(mst_req.ar_valid && mst_rsp.ar_ready));
    check("apu ar wins", mst_req.ar.addr == 64'h8000_1000 && a_rsp.ar_ready &&
          !b_rsp.ar_ready);
    a_req.ar_valid = 1'b0;
    wait_idle();
    check("apu one ar", ar_count == 1);

    cases++;
    idle_bus();
    b_req.ar_valid = 1'b1;
    b_req.ar.addr = 64'h8000_2000;
    b_req.ar.len = 8'd0;
    b_req.ar.size = 3'd3;
    do @(posedge clk); while (!(mst_req.ar_valid && mst_rsp.ar_ready));
    check("b forwarded", mst_req.ar.addr == 64'h8000_2000 && b_rsp.ar_ready &&
          !a_rsp.ar_ready);
    b_req.ar_valid = 1'b0;
    wait_idle();
    check("b one ar", ar_count == 2);

    cases++;
    idle_bus();
    a_req.ar_valid = 1'b1;
    a_req.ar.addr = 64'h8000_3000;
    a_req.ar.len = 8'd0;
    a_req.ar.size = 3'd3;
    b_req.ar_valid = 1'b1;
    b_req.ar.addr = 64'h8000_4000;
    b_req.ar.len = 8'd0;
    b_req.ar.size = 3'd3;
    do @(posedge clk); while (!(mst_req.ar_valid && mst_rsp.ar_ready));
    check("a beats b", mst_req.ar.addr == 64'h8000_3000 && a_rsp.ar_ready);
    a_req.ar_valid = 1'b0;
    b_req.ar_valid = 1'b0;
    wait_idle();
    check("a still ahead", ar_count == 3);

    if (errors != 0) $fatal(1, "APU tdma errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_tdma cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
