// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// A 64-byte descriptor fetch on N=2. An aligned pointer is read. A pointer
// 8 bytes off a 64-byte stripe is refused and issues no AR. The same rule
// holds at DataWidth 64 and 512. N=1 is not this test: every pointer fits.

`include "axi/typedef.svh"

module tb_g6lc_ai_desc_stripe;
  localparam logic [63:0] ALIGNED = 64'h8000_0000;
  localparam logic [63:0] CROSSES = 64'h8000_0008;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic        start64, start512;
  logic [63:0] addr64, addr512;
  logic        ready64, done64, err64, saw64;
  logic        ready512, done512, err512, saw512;
  logic [63:0] ar64, ar512;

  desc_fetch_chk #(.DW(64)) i64 (
    .clk, .rst_n, .start(start64), .addr(addr64),
    .ready(ready64), .done(done64), .err(err64), .saw_ar(saw64), .ar_addr(ar64)
  );
  desc_fetch_chk #(.DW(512)) i512 (
    .clk, .rst_n, .start(start512), .addr(addr512),
    .ready(ready512), .done(done512), .err(err512), .saw_ar(saw512), .ar_addr(ar512)
  );

  task automatic pulse(input int which, input logic [63:0] addr);
    int guard;
    logic done, err, saw, ready;
    logic [63:0] got;
    @(negedge clk);
    if (which == 0) begin
      addr64 = addr; start64 = 1;
    end else begin
      addr512 = addr; start512 = 1;
    end
    @(negedge clk);
    start64 = 0; start512 = 0;
    guard = 0;
    done = 0; err = 0; saw = 0; got = '0; ready = 0;
    while (!done && guard < 40) begin
      @(posedge clk);
      if (which == 0) begin
        done = done64; err = err64; saw = saw64; got = ar64; ready = ready64;
      end else begin
        done = done512; err = err512; saw = saw512; got = ar512; ready = ready512;
      end
      guard++;
    end
    if (!done) $fatal(1, "width %0d fetch timeout addr %h", which, addr);
    if (addr[5:0] == 6'h0) begin
      if (err || !saw || got != addr)
        $fatal(1, "aligned fetch width %0d err %b saw %b ar %h", which, err, saw, got);
    end else if (!err || saw) begin
      $fatal(1, "crossing fetch width %0d err %b saw %b", which, err, saw);
    end
  endtask

  initial begin
    start64 = 0; start512 = 0; addr64 = '0; addr512 = '0;
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    pulse(0, ALIGNED);
    pulse(0, CROSSES);
    pulse(1, ALIGNED);
    pulse(1, CROSSES);
    $display("PASS tb_g6lc_ai_desc_stripe");
    $finish;
  end

  initial begin
    repeat (500) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule

module desc_fetch_chk #(
  parameter int unsigned DW = 64
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [63:0] addr,
  output logic        ready,
  output logic        done,
  output logic        err,
  output logic        saw_ar,
  output logic [63:0] ar_addr
);
  typedef logic [63:0] addr_t;
  typedef logic [3:0]  id_t;
  typedef logic [DW-1:0] data_t;
  typedef logic [DW/8-1:0] strb_t;
  typedef logic user_t;
  `AXI_TYPEDEF_ALL(df, addr_t, id_t, data_t, strb_t, user_t)

  df_req_t  req;
  df_resp_t resp;

  g6lc_ai_desc_fetch #(
    .AddrWidth(64), .DataWidth(DW), .IdWidth(4),
    .NrChannels(2), .ChanShift(6),
    .axi_req_t(df_req_t), .axi_resp_t(df_resp_t)
  ) i_fetch (
    .clk_i(clk), .rst_ni(rst_n),
    .start_i(start), .addr_i(addr),
    .ready_o(ready), .done_o(done), .err_o(err), .desc_o(),
    .grant_i(1'b1),
    .axi_req_o(req), .axi_resp_i(resp)
  );

  typedef enum logic [1:0] { PH_IDLE, PH_R } ph_e;
  ph_e ph_q;
  logic [7:0] left_q;
  logic saw_q;
  logic [63:0] ar_q;

  assign saw_ar  = saw_q;
  assign ar_addr = ar_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph_q   <= PH_IDLE;
      left_q <= '0;
      saw_q  <= 1'b0;
      ar_q   <= '0;
      resp   <= '0;
    end else begin
      resp.ar_ready <= 1'b0;
      resp.r_valid  <= 1'b0;
      resp.r.last   <= 1'b0;
      resp.r.data   <= '0;
      resp.r.resp   <= axi_pkg::RESP_OKAY;
      resp.r.id     <= '0;
      resp.r.user   <= '0;
      if (start && ready)
        saw_q <= 1'b0;
      if (ph_q == PH_IDLE && req.ar_valid) begin
        resp.ar_ready <= 1'b1;
        saw_q  <= 1'b1;
        ar_q   <= req.ar.addr;
        left_q <= req.ar.len;
        ph_q   <= PH_R;
      end else if (ph_q == PH_R) begin
        resp.r_valid <= 1'b1;
        resp.r.last  <= (left_q == 8'd0);
        if (req.r_ready && left_q == 8'd0) begin
          resp.r_valid <= 1'b0;
          ph_q <= PH_IDLE;
        end else if (req.r_ready) begin
          left_q <= left_q - 8'd1;
        end
      end
    end
  end
endmodule
