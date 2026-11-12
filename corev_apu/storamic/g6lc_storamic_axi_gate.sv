// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// C4 CPU producer pause/drain provider, part 1: the AXI4 boundary gate.
//
// Sits on the CPU's single AXI request/response boundary (up_* toward the
// core, dn_* toward the interconnect/memory). When close_i is asserted the
// gate stops accepting NEW AW/AR requests, lets every already-forwarded or
// in-flight transaction run to completion, and then reports closed_o. While
// closed_o is high no downstream AW/AR/W valid may be present and no new
// upstream request can be accepted, so the CPU is physically cut off from the
// bus until close_i falls. B/R responses are owed data and always pass.
//
// Contract (qualified by the axi-gate-formal stage):
//   * AW/AR use a registered commit (aw_commit_q/ar_commit_q + captured
//     header). A downstream valid that has been forwarded is held, payload
//     stable, until the downstream ready handshake — it is never withdrawn,
//     even if close_i asserts mid-handshake. A NEW upstream AW/AR handshake is
//     accepted only while !close_i && !commit_q && !overflow_q.
//   * W beats pass only while w_cnt_q (w_owed = accepted AW - accepted
//     W-last) is nonzero, so W-before-AW is back-pressured. W is owed data for
//     an already-accepted AW and is NOT gated by close_i.
//   * B/R are a pure combinational pass-through in both directions.
//   * wr_cnt/rd_cnt/w_cnt are CntWidth saturating counters (outstanding
//     writes = AW-B, reads = AR-Rlast, w_owed = AW-Wlast). A counter that
//     would exceed its maximum sets sticky overflow_q, which makes closed_o
//     permanently unreachable (fail-closed) and blocks further new AW/AR.
//   * closed_o = close_i && !aw_commit_q && !ar_commit_q && all counters==0
//     && !overflow_q   (combinational; the boundary invariant holds at the
//     same cycle). inflight_o = any counter!=0 || commit_q.
//
// Timing impact: AW/AR gain one capture pipeline stage (registered commit).
// W valid/ready and the B/R pass-through add a single AND (counter-nonzero /
// overflow term) on the ordinary valid/ready path; there is no combinational
// path from a downstream ready to any upstream/downstream valid beyond that
// pass-through AND. No new clock, no latch, async-active-low reset only.
module g6lc_storamic_axi_gate #(
  parameter type req_t = logic,
  parameter type resp_t = logic,
  parameter int unsigned CntWidth = 8
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic close_i,
  output logic closed_o,
  output logic inflight_o,
  input  req_t up_req_i,     // request bundle from the core (AW/W/AR + B/R ready)
  output resp_t up_resp_o,   // response bundle to the core (ready + B/R)
  output req_t dn_req_o,     // request bundle to memory (AW/W/AR + B/R ready)
  input  resp_t dn_resp_i    // response bundle from memory (ready + B/R)
);
  localparam logic [CntWidth-1:0] CNT_MAX = {CntWidth{1'b1}};

  // Registered commit: an accepted upstream AW/AR is captured here and must be
  // presented downstream until the downstream ready accepts it.
  logic aw_commit_q, ar_commit_q;
  req_t aw_hold_q, ar_hold_q;   // captured headers; only .aw / .ar are consumed
  logic [CntWidth-1:0] wr_cnt_q, rd_cnt_q, w_cnt_q;
  logic overflow_q;

  // ---- channel handshake fires, all referenced to the dn (gate<->memory)
  // boundary so the counters describe transactions on the wire. ----
  logic dn_aw_fire, dn_ar_fire, dn_b_fire, dn_rlast_fire, dn_wlast_fire;
  logic up_aw_accept, up_ar_accept;

  assign dn_aw_fire    = aw_commit_q && dn_resp_i.aw_ready;
  assign dn_ar_fire    = ar_commit_q && dn_resp_i.ar_ready;
  assign dn_b_fire     = dn_resp_i.b_valid && up_req_i.b_ready;
  assign dn_rlast_fire = dn_resp_i.r_valid && up_req_i.r_ready && dn_resp_i.r.last;
  assign dn_wlast_fire = dn_req_o.w_valid && dn_resp_i.w_ready && up_req_i.w.last;
  assign up_aw_accept  = up_req_i.aw_valid && up_resp_o.aw_ready;
  assign up_ar_accept  = up_req_i.ar_valid && up_resp_o.ar_ready;

  // ---- next-state counters (inc-then-dec so a same-cycle AW+B or AR+Rlast
  // pair nets correctly); saturating, overflow on exceeding the maximum. ----
  logic [CntWidth-1:0] wr_cnt_d, rd_cnt_d, w_cnt_d;
  logic wr_ovf, rd_ovf, w_ovf;
  always_comb begin
    wr_cnt_d = wr_cnt_q; wr_ovf = 1'b0;
    if (dn_aw_fire) begin
      if (wr_cnt_q == CNT_MAX) begin wr_cnt_d = CNT_MAX; wr_ovf = 1'b1; end
      else wr_cnt_d = wr_cnt_q + 1'b1;
    end
    if (dn_b_fire && wr_cnt_d != '0) wr_cnt_d = wr_cnt_d - 1'b1;

    rd_cnt_d = rd_cnt_q; rd_ovf = 1'b0;
    if (dn_ar_fire) begin
      if (rd_cnt_q == CNT_MAX) begin rd_cnt_d = CNT_MAX; rd_ovf = 1'b1; end
      else rd_cnt_d = rd_cnt_q + 1'b1;
    end
    if (dn_rlast_fire && rd_cnt_d != '0) rd_cnt_d = rd_cnt_d - 1'b1;

    w_cnt_d = w_cnt_q; w_ovf = 1'b0;
    if (dn_aw_fire) begin
      if (w_cnt_q == CNT_MAX) begin w_cnt_d = CNT_MAX; w_ovf = 1'b1; end
      else w_cnt_d = w_cnt_q + 1'b1;
    end
    if (dn_wlast_fire && w_cnt_d != '0) w_cnt_d = w_cnt_d - 1'b1;
  end

  // ---- pass-through with close gating ----
  always_comb begin
    dn_req_o = '0;
    dn_req_o.aw       = aw_hold_q.aw;
    dn_req_o.aw_valid = aw_commit_q;
    dn_req_o.w        = up_req_i.w;
    dn_req_o.w_valid  = up_req_i.w_valid && (w_cnt_q != '0);
    dn_req_o.b_ready  = up_req_i.b_ready;
    dn_req_o.ar       = ar_hold_q.ar;
    dn_req_o.ar_valid = ar_commit_q;
    dn_req_o.r_ready  = up_req_i.r_ready;

    up_resp_o = '0;
    up_resp_o.aw_ready = !close_i && !aw_commit_q && !overflow_q;
    up_resp_o.ar_ready = !close_i && !ar_commit_q && !overflow_q;
    up_resp_o.w_ready  = dn_resp_i.w_ready && (w_cnt_q != '0);
    up_resp_o.b_valid  = dn_resp_i.b_valid;
    up_resp_o.b        = dn_resp_i.b;
    up_resp_o.r_valid  = dn_resp_i.r_valid;
    up_resp_o.r        = dn_resp_i.r;
  end

  assign closed_o   = close_i && !aw_commit_q && !ar_commit_q && !overflow_q &&
                      (wr_cnt_q == '0) && (rd_cnt_q == '0) && (w_cnt_q == '0);
  assign inflight_o = aw_commit_q || ar_commit_q ||
                      (wr_cnt_q != '0) || (rd_cnt_q != '0) || (w_cnt_q != '0);

  // pragma translate_off
  initial begin
    if (CntWidth < 2) $fatal(1, "STORAMIC_AXI_GATE_CONFIG CntWidth");
  end
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_commit_q <= 1'b0; ar_commit_q <= 1'b0;
      aw_hold_q   <= '0;   ar_hold_q   <= '0;
      wr_cnt_q    <= '0;   rd_cnt_q    <= '0;   w_cnt_q <= '0;
      overflow_q  <= 1'b0;
    end else begin
      // AW/AR capture-then-forward; up and dn accepts are mutually exclusive
      // per channel because up_*_ready requires !commit_q while dn_*_fire
      // requires commit_q.
      if (up_aw_accept) begin
        aw_commit_q <= 1'b1;
        aw_hold_q   <= up_req_i;
      end
      if (dn_aw_fire) aw_commit_q <= 1'b0;
      if (up_ar_accept) begin
        ar_commit_q <= 1'b1;
        ar_hold_q   <= up_req_i;
      end
      if (dn_ar_fire) ar_commit_q <= 1'b0;

      wr_cnt_q <= wr_cnt_d;
      rd_cnt_q <= rd_cnt_d;
      w_cnt_q  <= w_cnt_d;
      if (wr_ovf || rd_ovf || w_ovf) overflow_q <= 1'b1;
    end
  end
endmodule
