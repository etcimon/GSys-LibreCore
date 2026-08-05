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
        // Release when no outstanding intent (simple: return to idle when no valids)
        if (!slv0_req_i.ar_valid && !slv0_req_i.aw_valid &&
            !slv0_req_i.w_valid && !mst_resp_i.r_valid && !mst_resp_i.b_valid)
          state_d = IDLE;
      end
      LOCK1: begin
        mst_req_o = slv1_req_i;
        slv1_resp_o = mst_resp_i;
        if (!slv1_req_i.ar_valid && !slv1_req_i.aw_valid &&
            !slv1_req_i.w_valid && !mst_resp_i.r_valid && !mst_resp_i.b_valid)
          state_d = IDLE;
      end
      default: state_d = IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= IDLE;
    else         state_q <= state_d;
  end

endmodule
