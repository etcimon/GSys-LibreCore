// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Standalone smoke for g6lc_ai_dram_timing page-command delay.
// Not LiteDRAM. Not a Variane cookie. Cas=14 empty-bank = tRCD+Cas cycles.

`timescale 1ns/1ps

module tb_g6lc_ai_dram_timing;
  typedef struct packed { logic [63:0] addr; } ax_chan_t;
  typedef struct packed {
    ax_chan_t aw;
    logic     aw_valid;
    logic     w_valid;
    logic     b_ready;
    ax_chan_t ar;
    logic     ar_valid;
    logic     r_ready;
  } axi_req_t;
  typedef struct packed {
    logic aw_ready;
    logic w_ready;
    logic b_valid;
    logic ar_ready;
    logic r_valid;
  } axi_resp_t;

  localparam int unsigned CAS  = 14;
  localparam int unsigned TRCD = 14;
  localparam int unsigned TRP  = 14;

  logic clk, rst_ni;
  axi_req_t  slv_req, mst_req;
  axi_resp_t slv_resp, mst_resp;

  int unsigned errors;
  int unsigned cycles;

  g6lc_ai_dram_timing #(
      .CasCycles  (CAS),
      .TrcdCycles (TRCD),
      .TrpCycles  (TRP),
      .AddrWidth  (64),
      .axi_req_t  (axi_req_t),
      .axi_resp_t (axi_resp_t)
  ) i_dut (
      .clk_i      (clk),
      .rst_ni     (rst_ni),
      .slv_req_i  (slv_req),
      .slv_resp_o (slv_resp),
      .mst_req_o  (mst_req),
      .mst_resp_i (mst_resp)
  );

  axi_req_t  byp_slv, byp_mst;
  axi_resp_t byp_slv_resp, byp_mst_resp;
  g6lc_ai_dram_timing #(
      .CasCycles  (0),
      .TrcdCycles (0),
      .TrpCycles  (0),
      .AddrWidth  (64),
      .axi_req_t  (axi_req_t),
      .axi_resp_t (axi_resp_t)
  ) i_bypass (
      .clk_i      (clk),
      .rst_ni     (rst_ni),
      .slv_req_i  (byp_slv),
      .slv_resp_o (byp_slv_resp),
      .mst_req_o  (byp_mst),
      .mst_resp_i (byp_mst_resp)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  task automatic wait_ar_ready(output int unsigned n);
    n = 0;
    slv_req.ar_valid = 1'b1;
    while (!slv_resp.ar_ready) begin
      @(posedge clk);
      n++;
      if (n > 200) begin
        $error("AR ready timeout");
        errors++;
        break;
      end
    end
    @(posedge clk);
    slv_req.ar_valid = 1'b0;
  endtask

  initial begin
    errors = 0;
    cycles = 0;
    slv_req  = '0;
    mst_resp = '0;
    mst_resp.ar_ready = 1'b1;
    mst_resp.aw_ready = 1'b1;
    byp_slv = '0;
    byp_mst_resp = '0;
    byp_mst_resp.ar_ready = 1'b1;
    byp_mst_resp.aw_ready = 1'b1;
    rst_ni = 1'b0;
    repeat (4) @(posedge clk);
    rst_ni = 1'b1;
    @(posedge clk);

    // Empty bank: tRCD+Cas = 28 cycles of command delay.
    slv_req.ar.addr = 64'h0000_1000;
    wait_ar_ready(cycles);
    if (cycles < 27 || cycles > 29) begin
      $error("empty-bank delay %0d, expected ~28", cycles);
      errors++;
    end else
      $display("PASS empty-bank delay=%0d", cycles);

    // Same 4 KiB page: Cas only.
    slv_req.ar.addr = 64'h0000_1080;
    wait_ar_ready(cycles);
    if (cycles < 13 || cycles > 15) begin
      $error("page-hit delay %0d, expected ~14", cycles);
      errors++;
    end else
      $display("PASS page-hit delay=%0d", cycles);

    // Different row, same bank (addr[14:12] bank, row above bit 15): miss.
    slv_req.ar.addr = 64'h0001_1000;
    wait_ar_ready(cycles);
    if (cycles < 41 || cycles > 43) begin
      $error("page-miss delay %0d, expected ~42", cycles);
      errors++;
    end else
      $display("PASS page-miss delay=%0d", cycles);

    byp_slv.ar_valid = 1'b1;
    byp_slv.ar.addr  = 64'h0;
    #1;
    if (!byp_slv_resp.ar_ready || !byp_mst.ar_valid) begin
      $error("Cas=0 bypass did not pass AR combinationally");
      errors++;
    end else
      $display("PASS Cas=0 combinational bypass");

    if (errors != 0) begin
      $display("FAIL errors=%0d", errors);
      $fatal(1);
    end
    $display("PASS g6lc_ai_dram_timing");
    $finish;
  end
endmodule
