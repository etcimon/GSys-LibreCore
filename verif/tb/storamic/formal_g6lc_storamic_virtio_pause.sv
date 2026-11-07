// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module formal_g6lc_storamic_virtio_pause #(
  parameter bit OracleNegative = 0
) (
  input logic clk_i, rst_ni, quiesce_i,
  input g6lc_storamic_pkg::axil_req_t req_i,
  output logic cover_aw_o, cover_w_o, cover_b_o, cover_r_o, cover_drained_o
);
  g6lc_storamic_pkg::axil_resp_t resp;
  logic inflight, reset_pending;
  logic aw_q, w_q, r_q, seen_q;
  g6lc_storamic_virtio_mmio #(.QueueNumMax(4)) dut (
    .clk_i, .rst_ni, .quiesce_i, .inflight_o(inflight),
    .ctrl_req_i(req_i), .ctrl_resp_o(resp),
    .device_usable_i(1'b1), .capacity_i(64'd8), .capacity_update_i(1'b0),
    .flush_cap_i(1'b1), .dma_idle_i(1'b1), .used_event_i(1'b0), .ring_fault_i(1'b0),
    .notify_o(), .irq_o(), .driver_ok_o(), .features_ok_o(), .driver_features_o(),
    .reset_epoch_o(), .queue_ready_o(), .queue_num_o(), .queue_desc_o(),
    .queue_driver_o(), .queue_device_o(), .reset_pending_o(reset_pending)
  );
  // Accepted interface debt, independent of the DUT's channel state.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin aw_q <= 0; w_q <= 0; r_q <= 0; seen_q <= 0; end
    else begin
      if (req_i.aw_valid && resp.aw_ready) aw_q <= 1;
      if (req_i.w_valid && resp.w_ready) w_q <= 1;
      if (resp.b_valid && req_i.b_ready) begin aw_q <= 0; w_q <= 0; end
      if (req_i.ar_valid && resp.ar_ready) r_q <= 1;
      if (resp.r_valid && req_i.r_ready) r_q <= 0;
      if (quiesce_i && inflight) seen_q <= 1;
    end
  end
  always_comb begin
    if (rst_ni) begin
      assert(inflight == (aw_q || w_q || r_q || reset_pending));
      if (quiesce_i) begin
        assert(!resp.ar_ready);
        if (!aw_q && !w_q) assert(!resp.aw_ready && !resp.w_ready);
        if (aw_q && !w_q) assert(resp.w_ready);
        if (w_q && !aw_q) assert(resp.aw_ready);
      end
      if (OracleNegative && quiesce_i) assert(!inflight);
    end
  end
  assign cover_aw_o = rst_ni && quiesce_i && aw_q && !w_q;
  assign cover_w_o = rst_ni && quiesce_i && w_q && !aw_q;
  assign cover_b_o = rst_ni && quiesce_i && resp.b_valid;
  assign cover_r_o = rst_ni && quiesce_i && resp.r_valid;
  assign cover_drained_o = rst_ni && quiesce_i && seen_q && !inflight;
endmodule
