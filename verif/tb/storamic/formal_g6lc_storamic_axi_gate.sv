// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Bounded formal for g6lc_storamic_axi_gate (C4 CPU pause/drain provider).
// Small concrete req/resp structs (the gate is type-parameterised, so the
// checker drives it with a minimal legal AXI4 shape). CntWidth=3 keeps the
// saturating counters reachable inside the BMC depth.
//
// Environment: upstream obeys AXI valid-hold + payload-stable; downstream
// ready/resp are arbitrary EXCEPT responses are only offered for transactions
// the checker mirror counts as outstanding, and R-last consistency is enforced
// by the same mirror (a read completes only on an R-last handshake).
package formal_axi_gate_types;
  typedef struct packed { logic [1:0] id; logic [7:0] addr; logic [7:0] data; } aw_t;
  typedef struct packed { logic [7:0] data; logic last; } w_t;
  typedef struct packed { logic [1:0] id; logic [7:0] addr; } ar_t;
  typedef struct packed { logic [1:0] id; logic [1:0] resp; } b_t;
  typedef struct packed { logic [1:0] id; logic [7:0] data; logic last; } r_t;
  typedef struct packed {
    aw_t aw; logic aw_valid;
    w_t  w;  logic w_valid; logic b_ready;
    ar_t ar; logic ar_valid; logic r_ready;
  } req_t;
  typedef struct packed {
    logic aw_ready; logic ar_ready; logic w_ready;
    logic b_valid; b_t b;
    logic r_valid; r_t r;
  } resp_t;
endpackage

module formal_g6lc_storamic_axi_gate (
  clk_i, rst_ni, close_i, closed_o, inflight_o, up_req_i, up_resp_o,
  dn_req_o, dn_resp_i
);
  import formal_axi_gate_types::*;
  parameter int unsigned CntWidth = 3;
  input  logic  clk_i, rst_ni, close_i;
  output logic  closed_o, inflight_o;
  input  req_t  up_req_i;
  output resp_t up_resp_o;
  output req_t  dn_req_o;
  input  resp_t dn_resp_i;

  g6lc_storamic_axi_gate #(
    .req_t(req_t), .resp_t(resp_t), .CntWidth(CntWidth)
  ) dut (
    .clk_i, .rst_ni, .close_i, .closed_o, .inflight_o,
    .up_req_i, .up_resp_o, .dn_req_o, .dn_resp_i
  );

  // ---- observable channel fires (referenced to the dn boundary) ----
  logic f_aw, f_ar, f_w, f_wl, f_b, f_rl;
  logic up_aw_acc, up_ar_acc, up_w_hs;
  assign f_aw  = dn_req_o.aw_valid && dn_resp_i.aw_ready;
  assign f_ar  = dn_req_o.ar_valid && dn_resp_i.ar_ready;
  assign f_w   = dn_req_o.w_valid && dn_resp_i.w_ready;
  assign f_wl  = f_w && dn_req_o.w.last;
  assign f_b   = dn_resp_i.b_valid && dn_req_o.b_ready;
  assign f_rl  = dn_resp_i.r_valid && dn_req_o.r_ready && dn_resp_i.r.last;
  assign up_aw_acc = up_req_i.aw_valid && up_resp_o.aw_ready;
  assign up_ar_acc = up_req_i.ar_valid && up_resp_o.ar_ready;
  assign up_w_hs   = up_req_i.w_valid && up_resp_o.w_ready;

  localparam logic [3:0] CNT_MAX = 4'd7;   // 2^CntWidth-1 for CntWidth=3

  // ---- independent mirror of outstanding transactions (dn handshakes only) ----
  logic [3:0] c_wr_q, c_rd_q, c_w_q;
  logic       ovf_q, closed_armed_q, close_seen_q, closed_reached_q;
  // accepted-payload trackers for the no-close pass-through check (AW/AR are
  // serialised through the single commit register, so one pending slot each).
  aw_t chk_aw_q; ar_t chk_ar_q;
  logic    chk_aw_v_q, chk_ar_v_q;
  // registered previous-cycle observers for the hold/stability checks; using
  // flops rather than $past keeps the properties inside the same always block
  // the mirror counters live in.
  logic aw_stall_q, ar_stall_q, w_stall_dn_q;
  logic up_aw_stall_q, up_ar_stall_q, up_w_stall_q;
  aw_t prev_dn_aw_q, prev_up_aw_q;
  ar_t prev_dn_ar_q, prev_up_ar_q;
  w_t  prev_dn_w_q,  prev_up_w_q;
  logic b_stall_q, r_stall_q;
  b_t prev_dn_b_q; r_t prev_dn_r_q;
  // cover history
  logic w_stall_q, r_multi_q;

  wire [3:0] wr_out = c_wr_q;
  wire [3:0] rd_out = c_rd_q;
  wire [3:0] w_out  = c_w_q;

  // Mirror next-state: the DUT's inc-then-dec + saturating-overflow semantics,
  // computed combinationally so a same-cycle AW-fire + W-last (or B/R-last)
  // nets exactly like the DUT rather than last-nonblocking-wins.
  logic [3:0] cwr_d, crd_d, cw_d;
  logic       mir_ovf;
  always_comb begin
    cwr_d = c_wr_q; crd_d = c_rd_q; cw_d = c_w_q; mir_ovf = 1'b0;
    // outstanding writes = AW accepted - B accepted; w_owed = AW - W-last
    if (f_aw) begin
      if (cwr_d == CNT_MAX) begin cwr_d = CNT_MAX; mir_ovf = 1'b1; end
      else cwr_d = cwr_d + 1'b1;
      if (cw_d  == CNT_MAX) begin cw_d  = CNT_MAX; mir_ovf = 1'b1; end
      else cw_d  = cw_d  + 1'b1;
    end
    if (f_b  && cwr_d != '0) cwr_d = cwr_d - 1'b1;
    // outstanding reads = AR accepted - R-last accepted
    if (f_ar) begin
      if (crd_d == CNT_MAX) begin crd_d = CNT_MAX; mir_ovf = 1'b1; end
      else crd_d = crd_d + 1'b1;
    end
    if (f_rl && crd_d != '0) crd_d = crd_d - 1'b1;
    if (f_wl && cw_d != '0)  cw_d  = cw_d  - 1'b1;
  end

  logic past_valid = 1'b0;
  always @(posedge clk_i) begin
    past_valid <= 1'b1;
    if (!past_valid) assume(!rst_ni);
    if (!rst_ni || !past_valid || !$past(rst_ni)) begin
      c_wr_q <= '0; c_rd_q <= '0; c_w_q <= '0;
      ovf_q <= 1'b0; closed_armed_q <= 1'b0; close_seen_q <= 1'b0;
      closed_reached_q <= 1'b0;
      chk_aw_q <= '0; chk_ar_q <= '0; chk_aw_v_q <= 1'b0; chk_ar_v_q <= 1'b0;
      w_stall_q <= 1'b0; r_multi_q <= 1'b0;
      aw_stall_q <= 1'b0; ar_stall_q <= 1'b0; w_stall_dn_q <= 1'b0;
      up_aw_stall_q <= 1'b0; up_ar_stall_q <= 1'b0; up_w_stall_q <= 1'b0;
      prev_dn_aw_q <= '0; prev_up_aw_q <= '0;
      prev_dn_ar_q <= '0; prev_up_ar_q <= '0;
      prev_dn_w_q  <= '0; prev_up_w_q  <= '0;
      b_stall_q <= 1'b0; r_stall_q <= 1'b0;
      prev_dn_b_q <= '0; prev_dn_r_q <= '0;
    end else begin
      // ---- environment: upstream AXI valid-hold + payload-stable ----
      // (registered one-cycle observers; identical strict-hold semantics to a
      // $past formulation but kept inside this clocked block)
      assume(!(up_aw_stall_q) ||
             (up_req_i.aw_valid && up_req_i.aw == prev_up_aw_q));
      assume(!(up_ar_stall_q) ||
             (up_req_i.ar_valid && up_req_i.ar == prev_up_ar_q));
      assume(!(up_w_stall_q) ||
             (up_req_i.w_valid && up_req_i.w == prev_up_w_q));
      // downstream B/R valid-hold (legal AXI slave)
      assume(!(b_stall_q) ||
             (dn_resp_i.b_valid && dn_resp_i.b == prev_dn_b_q));
      assume(!(r_stall_q) ||
             (dn_resp_i.r_valid && dn_resp_i.r == prev_dn_r_q));
      // responses only for transactions the mirror counts as outstanding
      assume(!(dn_resp_i.b_valid) || (wr_out != '0));
      assume(!(dn_resp_i.r_valid) || (rd_out != '0));

      // ---- mirror counters: register the inc-then-dec next state ----
      c_wr_q <= cwr_d; c_rd_q <= crd_d; c_w_q <= cw_d;
      if (mir_ovf) ovf_q <= 1'b1;

      // ---- sequential close bookkeeping ----
      if (!close_i) closed_armed_q <= 1'b0;
      else if (closed_o) closed_armed_q <= 1'b1;
      if (close_i) close_seen_q <= 1'b1;
      if (closed_o) closed_reached_q <= 1'b1;

      // ---- accepted-payload trackers (up side, for pass-through check) ----
      if (up_aw_acc) begin chk_aw_q <= up_req_i.aw; chk_aw_v_q <= 1'b1; end
      if (up_ar_acc) begin chk_ar_q <= up_req_i.ar; chk_ar_v_q <= 1'b1; end

      // ---- registered hold/stability observers (feed the assumes above and
      // the P3 asserts below on the next cycle) ----
      aw_stall_q    <= dn_req_o.aw_valid && !dn_resp_i.aw_ready;
      ar_stall_q    <= dn_req_o.ar_valid && !dn_resp_i.ar_ready;
      w_stall_dn_q  <= dn_req_o.w_valid  && !dn_resp_i.w_ready;
      up_aw_stall_q <= up_req_i.aw_valid && !up_resp_o.aw_ready;
      up_ar_stall_q <= up_req_i.ar_valid && !up_resp_o.ar_ready;
      up_w_stall_q  <= up_req_i.w_valid  && !up_resp_o.w_ready;
      prev_dn_aw_q  <= dn_req_o.aw;  prev_up_aw_q  <= up_req_i.aw;
      prev_dn_ar_q  <= dn_req_o.ar;  prev_up_ar_q  <= up_req_i.ar;
      prev_dn_w_q   <= dn_req_o.w;   prev_up_w_q   <= up_req_i.w;
      b_stall_q <= dn_resp_i.b_valid && !dn_req_o.b_ready;
      r_stall_q <= dn_resp_i.r_valid && !dn_req_o.r_ready;
      prev_dn_b_q <= dn_resp_i.b;  prev_dn_r_q <= dn_resp_i.r;

      // ---- cover history ----
      if (dn_req_o.w_valid && !dn_resp_i.w_ready && wr_out != '0)
        w_stall_q <= 1'b1;
      if (dn_resp_i.r_valid && !dn_resp_i.r.last && rd_out != '0)
        r_multi_q <= 1'b1;
    end

    // ================= assertions (P1..P6) =================
    if (past_valid && rst_ni && $past(rst_ni)) begin
      // P1: closed_o => no downstream AW/AR/W valid
      assert(!(closed_o) ||
             (!dn_req_o.aw_valid && !dn_req_o.ar_valid && !dn_req_o.w_valid));
      // P2: closed_o => independent mirror outstanding all zero
      assert(!(closed_o) || (wr_out == '0 && rd_out == '0 && w_out == '0));
      // P3: dn AW/AR/W valid holds with stable payload until ready
      assert(!(aw_stall_q)   ||
             (dn_req_o.aw_valid && dn_req_o.aw == prev_dn_aw_q));
      assert(!(ar_stall_q)   ||
             (dn_req_o.ar_valid && dn_req_o.ar == prev_dn_ar_q));
      assert(!(w_stall_dn_q) ||
             (dn_req_o.w_valid && dn_req_o.w == prev_dn_w_q));
      // P4: once closed_o reached, while close_i stays high no dn AW/AR
      //     handshake may start (physical cutoff), even if closed_o later drops.
      assert(!(closed_armed_q && close_i && (f_aw || f_ar)));
      // P5: when close was never asserted, faithful pass-through.
      //     B/R are always an unmodified combinational pass-through.
      assert(up_resp_o.b_valid == dn_resp_i.b_valid);
      assert(up_resp_o.b       == dn_resp_i.b);
      assert(dn_req_o.b_ready  == up_req_i.b_ready);
      assert(up_resp_o.r_valid == dn_resp_i.r_valid);
      assert(up_resp_o.r       == dn_resp_i.r);
      assert(dn_req_o.r_ready  == up_req_i.r_ready);
      //     W payload is forwarded same-cycle unmodified.
      assert(dn_req_o.w == up_req_i.w);
      //     AW/AR accepted payloads reach dn unchanged, in order.
      if (!close_seen_q) begin
        if (f_aw && chk_aw_v_q) assert(dn_req_o.aw == chk_aw_q);
        if (f_ar && chk_ar_v_q) assert(dn_req_o.ar == chk_ar_q);
      end
      // P6: sticky overflow => closed_o never, and no new upstream AW/AR admit.
      assert(!(ovf_q) || !closed_o);
      assert(!(ovf_q) || !(up_aw_acc || up_ar_acc));
      // W legality oracle (kills the w_owed==0 mutant): a dn W handshake is
      // only legal while a write's W channel is open downstream.
      assert(!(f_w) || (w_out != '0));

      // ================= covers =================
      // close during an in-flight write whose W is stalled -> later closed_o
      cover(closed_o && w_stall_q);
      // close with a multi-beat R pending -> later closed_o
      cover(closed_o && r_multi_q);
      // closed -> reopen -> a new AW is admitted upstream after the gate opens
      cover(closed_reached_q && !close_i && up_aw_acc);
      // overflow reached
      cover(ovf_q);
    end
  end
endmodule
