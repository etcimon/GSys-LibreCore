// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Minimal 2→1 AXI4 mux for Ara attach: **same ID width** on all ports (no
// ID prepend). Port 0 has priority when both request. Used so live Ara can
// share the cluster's narrow AXI without axi_mux's ID-width expansion.
//
// Not a full ATOP/QoS-preserving interconnect — sufficient for single-hart
// bring-up and lint of CVA6_ARA_ATTACH.

module g6lc_axi_2to1_mux #(
    parameter type axi_req_t  = logic,
    parameter type axi_resp_t = logic
) (
    input  logic      clk_i,
    input  logic      rst_ni,
    // slv0 = Ara (or other), slv1 = core
    input  axi_req_t  slv0_req_i,
    output axi_resp_t slv0_resp_o,
    input  axi_req_t  slv1_req_i,
    output axi_resp_t slv1_resp_o,
    output axi_req_t  mst_req_o,
    input  axi_resp_t mst_resp_i
);

  typedef enum logic [1:0] { IDLE, LOCK0, LOCK1 } state_e;
  state_e state_q, state_d;

  // Outstanding-response accounting.
  //
  // There is no ID remapping here, so a response can only be routed by "who
  // holds the lock". That is sound only while the lock covers the WHOLE
  // transaction. Releasing it because nothing is momentarily valid loses the
  // association: any memory has latency, so a master that has had its AR
  // accepted and is waiting for data would see the lock handed to the other
  // master, and its R beats delivered there instead — the requester gets
  // another master's data and never receives its own.
  //
  // Reads and writes are counted separately because their completion events
  // differ (RLAST versus B). The lock is released only when both are zero.
  localparam int unsigned MAX_TXNS = 16;
  localparam int unsigned CNT_W    = $clog2(MAX_TXNS + 1);
  logic [CNT_W-1:0] rd_out_q, rd_out_d, wr_out_q, wr_out_d;
  logic rd_full, wr_full;
  assign rd_full = (rd_out_q == CNT_W'(MAX_TXNS));
  assign wr_full = (wr_out_q == CNT_W'(MAX_TXNS));

  // Master-side completion events, sampled from the ports actually handshaking.
  logic ar_fire, aw_fire, r_last_fire, b_fire;
  assign ar_fire     = mst_req_o.ar_valid && mst_resp_i.ar_ready;
  assign aw_fire     = mst_req_o.aw_valid && mst_resp_i.aw_ready;
  assign r_last_fire = mst_resp_i.r_valid && mst_req_o.r_ready && mst_resp_i.r.last;
  assign b_fire      = mst_resp_i.b_valid && mst_req_o.b_ready;

  logic ar_sel0, aw_sel0;
  assign ar_sel0 = slv0_req_i.ar_valid &&
                   (state_q == IDLE || state_q == LOCK0);
  assign aw_sel0 = slv0_req_i.aw_valid &&
                   (state_q == IDLE || state_q == LOCK0);

  // AR: prefer slv0 when both idle-valid
  always_comb begin
    mst_req_o = '0;
    slv0_resp_o = '0;
    slv1_resp_o = '0;
    state_d = state_q;

    // Default ready/valid fanout
    slv0_resp_o.aw_ready = 1'b0;
    slv0_resp_o.w_ready  = 1'b0;
    slv0_resp_o.ar_ready = 1'b0;
    slv0_resp_o.b_valid  = 1'b0;
    slv0_resp_o.r_valid  = 1'b0;
    slv1_resp_o.aw_ready = 1'b0;
    slv1_resp_o.w_ready  = 1'b0;
    slv1_resp_o.ar_ready = 1'b0;
    slv1_resp_o.b_valid  = 1'b0;
    slv1_resp_o.r_valid  = 1'b0;

    unique case (state_q)
      IDLE: begin
        if (slv0_req_i.ar_valid || slv0_req_i.aw_valid) begin
          state_d = LOCK0;
        end else if (slv1_req_i.ar_valid || slv1_req_i.aw_valid) begin
          state_d = LOCK1;
        end
      end
      LOCK0: begin
        // Pass-through slv0
        mst_req_o = slv0_req_i;
        slv0_resp_o = mst_resp_i;
        // Bound the counters: refuse further requests at the cap rather
        // than wrap and lose an outstanding response.
        if (rd_full) begin
          mst_req_o.ar_valid    = 1'b0;
          slv0_resp_o.ar_ready = 1'b0;
        end
        if (wr_full) begin
          mst_req_o.aw_valid    = 1'b0;
          slv0_resp_o.aw_ready = 1'b0;
        end
        // Release when no outstanding intent (simple: return to idle when no valids)
        if (!slv0_req_i.ar_valid && !slv0_req_i.aw_valid &&
            !slv0_req_i.w_valid && !rd_out_q && !wr_out_q)
          state_d = IDLE;
      end
      LOCK1: begin
        mst_req_o = slv1_req_i;
        slv1_resp_o = mst_resp_i;
        // Bound the counters: refuse further requests at the cap rather
        // than wrap and lose an outstanding response.
        if (rd_full) begin
          mst_req_o.ar_valid    = 1'b0;
          slv1_resp_o.ar_ready = 1'b0;
        end
        if (wr_full) begin
          mst_req_o.aw_valid    = 1'b0;
          slv1_resp_o.aw_ready = 1'b0;
        end
        if (!slv1_req_i.ar_valid && !slv1_req_i.aw_valid &&
            !slv1_req_i.w_valid && !rd_out_q && !wr_out_q)
          state_d = IDLE;
      end
      default: state_d = IDLE;
    endcase
  end

  always_comb begin
    rd_out_d = rd_out_q;
    wr_out_d = wr_out_q;
    // Both events can occur in one cycle; apply them together so the net change
    // is right rather than order-dependent.
    if (ar_fire && !r_last_fire) rd_out_d = rd_out_q + CNT_W'(1);
    if (!ar_fire && r_last_fire) rd_out_d = rd_out_q - CNT_W'(1);
    if (aw_fire && !b_fire)      wr_out_d = wr_out_q + CNT_W'(1);
    if (!aw_fire && b_fire)      wr_out_d = wr_out_q - CNT_W'(1);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q  <= IDLE;
      rd_out_q <= '0;
      wr_out_q <= '0;
    end else begin
      state_q  <= state_d;
      rd_out_q <= rd_out_d;
      wr_out_q <= wr_out_d;
    end
  end

endmodule
