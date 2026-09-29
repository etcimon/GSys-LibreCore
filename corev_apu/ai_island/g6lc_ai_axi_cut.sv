// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Full register slice on the island's DMA master (all five AXI channels), typed
// only by the aggregate request/response structs so it drops in wherever the
// island top does. Each channel is a two-entry spill register, so throughput is
// unchanged and every VALID/READY path is cut by flops. This is the registered
// boundary the island presents to the fabric: no request VALID or master READY
// leaves this module as a combinational function of a fabric signal.
module g6lc_ai_axi_cut #(
    parameter type axi_req_t  = logic,
    parameter type axi_resp_t = logic,
    parameter bit  Bypass     = 1'b0
) (
    input  logic      clk_i,
    input  logic      rst_ni,
    input  axi_req_t  slv_req_i,
    output axi_resp_t slv_resp_o,
    output axi_req_t  mst_req_o,
    input  axi_resp_t mst_resp_i
);
  axi_req_t  slv_req  /*verilator split_var*/, mst_req  /*verilator split_var*/;
  axi_resp_t slv_resp /*verilator split_var*/, mst_resp /*verilator split_var*/;
  assign slv_req    = slv_req_i;
  assign mst_resp   = mst_resp_i;
  assign mst_req_o  = mst_req;
  assign slv_resp_o = slv_resp;

  localparam int AwW = $bits(slv_req.aw);
  localparam int WW  = $bits(slv_req.w);
  localparam int ArW = $bits(slv_req.ar);
  localparam int BW  = $bits(mst_resp.b);
  localparam int RW  = $bits(mst_resp.r);
  logic [AwW-1:0] aw_q;
  logic [WW-1:0]  w_q;
  logic [ArW-1:0] ar_q;
  logic [BW-1:0]  b_q;
  logic [RW-1:0]  r_q;

  spill_register #(.T(logic [AwW-1:0]), .Bypass(Bypass)) i_aw (
      .clk_i, .rst_ni, .valid_i(slv_req.aw_valid), .ready_o(slv_resp.aw_ready),
      .data_i(slv_req.aw), .valid_o(mst_req.aw_valid), .ready_i(mst_resp.aw_ready), .data_o(aw_q));
  spill_register #(.T(logic [WW-1:0]), .Bypass(Bypass)) i_w (
      .clk_i, .rst_ni, .valid_i(slv_req.w_valid), .ready_o(slv_resp.w_ready),
      .data_i(slv_req.w), .valid_o(mst_req.w_valid), .ready_i(mst_resp.w_ready), .data_o(w_q));
  spill_register #(.T(logic [ArW-1:0]), .Bypass(Bypass)) i_ar (
      .clk_i, .rst_ni, .valid_i(slv_req.ar_valid), .ready_o(slv_resp.ar_ready),
      .data_i(slv_req.ar), .valid_o(mst_req.ar_valid), .ready_i(mst_resp.ar_ready), .data_o(ar_q));
  spill_register #(.T(logic [BW-1:0]), .Bypass(Bypass)) i_b (
      .clk_i, .rst_ni, .valid_i(mst_resp.b_valid), .ready_o(mst_req.b_ready),
      .data_i(mst_resp.b), .valid_o(slv_resp.b_valid), .ready_i(slv_req.b_ready), .data_o(b_q));
  spill_register #(.T(logic [RW-1:0]), .Bypass(Bypass)) i_r (
      .clk_i, .rst_ni, .valid_i(mst_resp.r_valid), .ready_o(mst_req.r_ready),
      .data_i(mst_resp.r), .valid_o(slv_resp.r_valid), .ready_i(slv_req.r_ready), .data_o(r_q));

  assign mst_req.aw  = aw_q;
  assign mst_req.w   = w_q;
  assign mst_req.ar  = ar_q;
  assign slv_resp.b  = b_q;
  assign slv_resp.r  = r_q;
endmodule
