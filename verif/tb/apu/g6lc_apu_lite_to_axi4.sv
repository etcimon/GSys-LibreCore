// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AXI-Lite 32-bit master to testharness AXI4-64 size=2. Verif-only.

`timescale 1ns/1ps

module g6lc_apu_lite_to_axi4
  import g6lc_apu_bus_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_axi_req_t   lite_req_i,
  output apu_axi_resp_t  lite_rsp_o,
  output apu_dma_axi_req_t  axi4_req_o,
  input  apu_dma_axi_resp_t axi4_rsp_i
);
  logic [63:0] aw_addr_q, ar_addr_q;
  logic [63:0] waddr;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_addr_q <= '0;
      ar_addr_q <= '0;
    end else begin
      if (lite_req_i.aw_valid && lite_rsp_o.aw_ready) aw_addr_q <= lite_req_i.aw.addr;
      if (lite_req_i.ar_valid && lite_rsp_o.ar_ready) ar_addr_q <= lite_req_i.ar.addr;
    end
  end

  assign waddr = lite_req_i.aw_valid ? lite_req_i.aw.addr : aw_addr_q;

  always_comb begin
    axi4_req_o = '0;
    axi4_req_o.aw.addr = lite_req_i.aw.addr;
    axi4_req_o.aw.size = 3'd2;
    axi4_req_o.aw.len = '0;
    axi4_req_o.aw.burst = axi_pkg::BURST_INCR;
    axi4_req_o.aw.prot = lite_req_i.aw.prot;
    axi4_req_o.aw_valid = lite_req_i.aw_valid;
    axi4_req_o.w.last = 1'b1;
    if (waddr[2]) begin
      axi4_req_o.w.data = {lite_req_i.w.data, 32'h0};
      axi4_req_o.w.strb = 8'hf0;
    end else begin
      axi4_req_o.w.data = {32'h0, lite_req_i.w.data};
      axi4_req_o.w.strb = 8'h0f;
    end
    axi4_req_o.w_valid = lite_req_i.w_valid;
    axi4_req_o.b_ready = lite_req_i.b_ready;
    axi4_req_o.ar.addr = lite_req_i.ar.addr;
    axi4_req_o.ar.size = 3'd2;
    axi4_req_o.ar.len = '0;
    axi4_req_o.ar.burst = axi_pkg::BURST_INCR;
    axi4_req_o.ar.prot = lite_req_i.ar.prot;
    axi4_req_o.ar_valid = lite_req_i.ar_valid;
    axi4_req_o.r_ready = lite_req_i.r_ready;

    lite_rsp_o = '0;
    lite_rsp_o.aw_ready = axi4_rsp_i.aw_ready;
    lite_rsp_o.w_ready = axi4_rsp_i.w_ready;
    lite_rsp_o.b_valid = axi4_rsp_i.b_valid;
    lite_rsp_o.b.resp = axi4_rsp_i.b.resp;
    lite_rsp_o.ar_ready = axi4_rsp_i.ar_ready;
    lite_rsp_o.r_valid = axi4_rsp_i.r_valid;
    lite_rsp_o.r.resp = axi4_rsp_i.r.resp;
    lite_rsp_o.r.data = ar_addr_q[2] ? axi4_rsp_i.r.data[63:32]
                                     : axi4_rsp_i.r.data[31:0];
  end
endmodule
