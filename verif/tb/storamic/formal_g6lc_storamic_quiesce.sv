// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Feature-focused safety and non-vacuous drain reachability. No bounded
// liveness: a master may withhold W beats or backpressure B/R indefinitely.
module formal_g6lc_storamic_quiesce (
  input logic clk_i,
  input logic rst_ni,
  input logic quiesce_i,
  input g6lc_storamic_pkg::axi_req_t req_i,
  input logic mem_ready_i,
  input logic mem_gnt_i,
  input logic mem_rvalid_i,
  input logic [63:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic cover_write_drain_o,
  output logic cover_read_drain_o
);
  import g6lc_storamic_pkg::*;
  axi_resp_t resp;
  logic mem_req, mem_we, quiesced;
  logic w_owned, r_owned, mem_owned;
  txn_id_t mem_tag, owned_tag;
  logic paused_w, paused_r, granted_w, granted_r, retired_w, retired_r;

  g6lc_storamic_axi_memory #(.RegionBytes(256), .SeqWidth(4)) dut (
    .clk_i, .rst_ni, .testmode_i(1'b0), .quiesce_i, .quiesced_o(quiesced),
    .req_i, .resp_o(resp), .source_i(8'h3a), .reset_generation_i(32'd0),
    .service_ready_o(), .sequence_exhausted_o(), .faults_o(), .events_o(),
    .inflight_o(), .mem_ready_i, .mem_req_o(mem_req), .mem_gnt_i,
    .mem_we_o(mem_we), .mem_addr_o(), .mem_wdata_o(), .mem_be_o(),
    .mem_tag_o(mem_tag), .mem_slot_o(), .mem_rvalid_i, .mem_rdata_i,
    .mem_error_i, .mem_tag_i,
    .map_valid_i(1'b0), .slot_map_i('0), .region_map_i('0)
  );

  assign cover_write_drain_o = quiesced && paused_w && granted_w && retired_w;
  assign cover_read_drain_o = quiesced && paused_r && granted_r && retired_r;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_owned <= 0; r_owned <= 0; mem_owned <= 0; owned_tag <= '0;
      paused_w <= 0; paused_r <= 0;
      granted_w <= 0; granted_r <= 0; retired_w <= 0; retired_r <= 0;
    end else begin
      if (req_i.aw_valid && resp.aw_ready) w_owned <= 1;
      if (resp.b_valid && req_i.b_ready) w_owned <= 0;
      if (req_i.ar_valid && resp.ar_ready) r_owned <= 1;
      if (resp.r_valid && req_i.r_ready && resp.r.last) r_owned <= 0;
      if (mem_req && mem_gnt_i) begin
        mem_owned <= 1;
        owned_tag <= mem_tag;
      end else if (mem_owned && mem_rvalid_i && mem_tag_i == owned_tag) begin
        mem_owned <= 0;
      end

      if (quiesce_i) assert (!resp.aw_ready && !resp.ar_ready);
      if (quiesced) begin
        assert (!w_owned && !r_owned && !mem_owned);
        assert (!mem_req && !resp.b_valid && !resp.r_valid);
      end

      // A cover requires an actual memory grant and successful retirement
      // during one continuous pause, not just an idle/error-only trace.
      if (!quiesce_i) begin
        paused_w <= 0; paused_r <= 0;
        granted_w <= 0; granted_r <= 0; retired_w <= 0; retired_r <= 0;
      end else begin
        if (w_owned) paused_w <= 1;
        if (r_owned) paused_r <= 1;
        if (mem_req && mem_gnt_i && mem_we) granted_w <= 1;
        if (mem_req && mem_gnt_i && !mem_we) granted_r <= 1;
        if (resp.b_valid && req_i.b_ready && resp.b.resp == 0) retired_w <= 1;
        if (resp.r_valid && req_i.r_ready && resp.r.last && resp.r.resp == 0)
          retired_r <= 1;
      end
    end
  end
endmodule
