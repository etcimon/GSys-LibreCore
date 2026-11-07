// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Single-beat upstream protocol environment; arbitrary AW/W ordering,
// backpressure, DMA request withdrawal and multiple accepted transactions.
module formal_g6lc_storamic_dma_ownership #(
  parameter bit OracleNegative = 0
) (
  input logic clk_i, rst_ni, dma_req_i,
  input g6lc_storamic_pkg::axi_req_t up_i,
  input g6lc_storamic_pkg::axi_resp_t back_i,
  output logic cover_offered_w_o, cover_held_aw_o,
  output logic cover_held_r_o, cover_drain_o
);
  import g6lc_storamic_pkg::*;
  axi_req_t mst, previous_up, previous_mst;
  axi_resp_t rsp, previous_rsp, previous_back;
  logic grant, done, inflight, history;
  logic [7:0] writes, reads, slave_aw, slave_w, slave_ar;
  logic signed [8:0] data_credit;
  logic aw, ar, wl, b, rl;
  logic initialized = 0;
  always_ff @(posedge clk_i) begin
    initialized <= 1;
    if (!initialized) assume (!rst_ni);
  end
  g6lc_storamic_dma_axi #(
    .IdWidth(8), .DmaId(8'hFE), .axi_req_t(axi_req_t), .axi_resp_t(axi_resp_t)
  ) dut (
    .clk_i, .rst_ni, .inflight_o(inflight),
    .dma_req_i, .dma_gnt_o(grant), .dma_we_i(1'b1),
    .dma_addr_i(64'h8000), .dma_wdata_i(64'h1234), .dma_be_i(8'hFF),
    .dma_rvalid_o(done), .dma_rdata_o(), .dma_err_o(),
    .up_req_i(up_i), .up_resp_o(rsp), .mst_req_o(mst), .mst_resp_i(back_i),
    .inval_valid_o(), .inval_addr_o(), .inval_ready_i(1'b0), .inval_done_i(1'b0)
  );
  assign aw = up_i.aw_valid && rsp.aw_ready;
  assign ar = up_i.ar_valid && rsp.ar_ready;
  assign wl = up_i.w_valid && rsp.w_ready && up_i.w.last;
  assign b = rsp.b_valid && up_i.b_ready;
  assign rl = rsp.r_valid && up_i.r_ready && rsp.r.last;
  always_comb begin
    assume (up_i.aw.len == 0 && up_i.ar.len == 0 && up_i.w.last);
    assume (up_i.aw.id == 1 && up_i.ar.id == 1 && back_i.r.last);
    assume (!back_i.b_valid || (slave_aw != 0 && slave_w != 0));
    assume (!back_i.r_valid || slave_ar != 0);
    if (!rst_ni) begin
      assume (!dma_req_i && !up_i.aw_valid && !up_i.w_valid && !up_i.ar_valid);
      assume (!back_i.b_valid && !back_i.r_valid);
    end
    if (rst_ni && history) begin
      if (previous_up.aw_valid && !previous_rsp.aw_ready)
        assume (up_i.aw_valid && up_i.aw == previous_up.aw);
      if (previous_up.w_valid && !previous_rsp.w_ready)
        assume (up_i.w_valid && up_i.w == previous_up.w);
      if (previous_up.ar_valid && !previous_rsp.ar_ready)
        assume (up_i.ar_valid && up_i.ar == previous_up.ar);
      if (previous_back.b_valid && !previous_mst.b_ready)
        assume (back_i.b_valid && back_i.b == previous_back.b);
      if (previous_back.r_valid && !previous_mst.r_ready)
        assume (back_i.r_valid && back_i.r == previous_back.r);
      if (previous_mst.aw_valid && !previous_back.aw_ready)
        assert (mst.aw_valid && mst.aw == previous_mst.aw);
      if (previous_mst.w_valid && !previous_back.w_ready)
        assert (mst.w_valid && mst.w == previous_mst.w);
      if (previous_mst.ar_valid && !previous_back.ar_ready)
        assert (mst.ar_valid && mst.ar == previous_mst.ar);
      if ((previous_mst.aw_valid && previous_mst.aw.id == 1 && !previous_back.aw_ready) ||
          (previous_mst.ar_valid && !previous_back.ar_ready))
        assert (inflight && !grant);
    end
    if (rst_ni) begin
      if (wl) assert (data_credit > 0 || (data_credit == 0 && mst.aw_valid));
      if (grant) assert (writes == 0 && reads == 0 && data_credit == 0);
      if (writes != 0 || reads != 0 || data_credit != 0) assert (inflight);
      assert (data_credit >= -1 && data_credit <= 255);
      if (aw) assert (mst.aw_valid && back_i.aw_ready && mst.aw == up_i.aw);
      if (ar) assert (mst.ar_valid && back_i.ar_ready && mst.ar == up_i.ar);
      if (wl) assert (mst.w_valid && back_i.w_ready && mst.w == up_i.w);
      if (OracleNegative) assert (!grant);
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      history <= 0; writes <= 0; reads <= 0; data_credit <= 0;
      slave_aw <= 0; slave_w <= 0; slave_ar <= 0;
      previous_up <= '0; previous_rsp <= '0; previous_mst <= '0; previous_back <= '0;
      cover_offered_w_o <= 0; cover_held_aw_o <= 0;
      cover_held_r_o <= 0; cover_drain_o <= 0;
    end else begin
      history <= 1;
      previous_up <= up_i; previous_rsp <= rsp;
      previous_mst <= mst; previous_back <= back_i;
      writes <= writes + 8'(aw) - 8'(b);
      reads <= reads + 8'(ar) - 8'(rl);
      data_credit <= data_credit + 9'(aw) - 9'(wl);
      slave_aw <= slave_aw + 8'(mst.aw_valid && back_i.aw_ready) -
                             8'(back_i.b_valid && mst.b_ready);
      slave_w <= slave_w + 8'(mst.w_valid && back_i.w_ready && mst.w.last) -
                           8'(back_i.b_valid && mst.b_ready);
      slave_ar <= slave_ar + 8'(mst.ar_valid && back_i.ar_ready) -
                             8'(back_i.r_valid && mst.r_ready && back_i.r.last);
      if (wl && data_credit == 0 && !aw) cover_offered_w_o <= 1;
      if (history && previous_mst.aw_valid && previous_mst.aw.id == 1 &&
          !previous_back.aw_ready && dma_req_i && mst.aw_valid) cover_held_aw_o <= 1;
      if (rsp.r_valid && !up_i.r_ready && dma_req_i && !grant) cover_held_r_o <= 1;
      if (cover_offered_w_o && grant) cover_drain_o <= 1;
    end
  end
endmodule
