// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Completion store. An 8-byte-aligned word is written, including one that
// sits at the top of a 512-bit beat. A 4-byte-aligned pointer completes
// with err and issues no AW. Same rule at DataWidth 64 and 512.

`include "axi/typedef.svh"

module tb_g6lc_ai_store_align;
  localparam logic [63:0] WORD = 64'h0123_4567_89AB_CDEF;
  localparam logic [63:0] BASE = 64'h8000_0000;
  localparam logic [63:0] TOP  = 64'h8000_0038;
  localparam logic [63:0] BAD  = 64'h8000_0004;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic start64, start512, ready64, ready512, done64, done512, err64, err512;
  logic saw64, saw512;
  logic [63:0] addr64, addr512, aw64, aw512;
  logic [63:0] data64;
  logic [511:0] data512;
  logic [7:0] strb64;
  logic [63:0] strb512;

  store_chk #(.DW(64)) i64 (
    .clk, .rst_n, .start(start64), .addr(addr64), .data(WORD),
    .ready(ready64), .done(done64), .err(err64), .saw_aw(saw64),
    .aw_addr(aw64), .w_data(data64), .w_strb(strb64)
  );
  store_chk #(.DW(512)) i512 (
    .clk, .rst_n, .start(start512), .addr(addr512), .data(WORD),
    .ready(ready512), .done(done512), .err(err512), .saw_aw(saw512),
    .aw_addr(aw512), .w_data(data512), .w_strb(strb512)
  );

  task automatic wait_done(input int which);
    int guard;
    guard = 0;
    while (guard < 40) begin
      @(posedge clk);
      if (which == 0 && done64) return;
      if (which == 1 && done512) return;
      guard++;
    end
    $fatal(1, "store timeout width %0d", which);
  endtask

  initial begin
    start64 = 0; start512 = 0; addr64 = '0; addr512 = '0;
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    @(negedge clk); addr64 = BASE; start64 = 1;
    @(negedge clk); start64 = 0;
    wait_done(0);
    if (err64 || !saw64 || aw64 != BASE || data64 != WORD || strb64 != 8'hFF)
      $fatal(1, "64-bit aligned store err %b saw %b aw %h data %h strb %h",
             err64, saw64, aw64, data64, strb64);

    @(negedge clk); addr64 = BAD; start64 = 1;
    @(negedge clk); start64 = 0;
    wait_done(0);
    if (!err64 || saw64)
      $fatal(1, "64-bit misaligned store err %b saw %b", err64, saw64);

    @(negedge clk); addr512 = TOP; start512 = 1;
    @(negedge clk); start512 = 0;
    wait_done(1);
    if (err512 || !saw512 || aw512 != TOP || data512[511:448] != WORD
        || strb512 != 64'hFF00_0000_0000_0000)
      $fatal(1, "512-bit top-lane store err %b saw %b aw %h hi %h strb %h",
             err512, saw512, aw512, data512[511:448], strb512);
    if (data512[447:0] != '0)
      $fatal(1, "512-bit top-lane store wrote below the word");

    @(negedge clk); addr512 = BAD; start512 = 1;
    @(negedge clk); start512 = 0;
    wait_done(1);
    if (!err512 || saw512)
      $fatal(1, "512-bit misaligned store err %b saw %b", err512, saw512);

    $display("PASS tb_g6lc_ai_store_align");
    $finish;
  end

  initial begin
    repeat (500) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule

module store_chk #(
  parameter int unsigned DW = 64
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             start,
  input  logic [63:0]      addr,
  input  logic [63:0]      data,
  output logic             ready,
  output logic             done,
  output logic             err,
  output logic             saw_aw,
  output logic [63:0]      aw_addr,
  output logic [DW-1:0]    w_data,
  output logic [DW/8-1:0]  w_strb
);
  typedef logic [63:0] addr_t;
  typedef logic [3:0]  id_t;
  typedef logic [DW-1:0] data_t;
  typedef logic [DW/8-1:0] strb_t;
  typedef logic user_t;
  `AXI_TYPEDEF_ALL(st, addr_t, id_t, data_t, strb_t, user_t)

  st_req_t  req;
  st_resp_t resp;

  g6lc_ai_mem_store #(
    .AddrWidth(64), .DataWidth(DW), .IdWidth(4),
    .axi_req_t(st_req_t), .axi_resp_t(st_resp_t)
  ) i_store (
    .clk_i(clk), .rst_ni(rst_n),
    .start_i(start), .addr_i(addr), .data_i(DW'(data)),
    .ready_o(ready), .done_o(done), .err_o(err),
    .axi_req_o(req), .axi_resp_i(resp)
  );

  typedef enum logic [1:0] { PH_IDLE, PH_W, PH_B } ph_e;
  ph_e ph_q;
  logic saw_q;
  logic [63:0] aw_q;
  logic [DW-1:0] data_q;
  logic [DW/8-1:0] strb_q;

  assign saw_aw  = saw_q;
  assign aw_addr = aw_q;
  assign w_data  = data_q;
  assign w_strb  = strb_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph_q   <= PH_IDLE;
      saw_q  <= 1'b0;
      aw_q   <= '0;
      data_q <= '0;
      strb_q <= '0;
      resp   <= '0;
    end else begin
      resp.aw_ready <= 1'b0;
      resp.w_ready  <= 1'b0;
      resp.b_valid  <= 1'b0;
      resp.b.resp   <= axi_pkg::RESP_OKAY;
      resp.b.id     <= '0;
      resp.b.user   <= '0;
      if (start && ready)
        saw_q <= 1'b0;
      if (ph_q == PH_IDLE && req.aw_valid) begin
        resp.aw_ready <= 1'b1;
        saw_q <= 1'b1;
        aw_q  <= req.aw.addr;
        ph_q  <= PH_W;
      end else if (ph_q == PH_W && req.w_valid) begin
        resp.w_ready <= 1'b1;
        data_q <= req.w.data;
        strb_q <= req.w.strb;
        ph_q   <= PH_B;
      end else if (ph_q == PH_B) begin
        resp.b_valid <= 1'b1;
        if (req.b_ready)
          ph_q <= PH_IDLE;
      end
    end
  end
endmodule
