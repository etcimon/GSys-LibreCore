// hyp8 provenance: REWRITTEN (rename stage R2 -- dependency resolve)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_rename_resolve -- R2 of the staged rename, the one kernel the
// unbanked design folded into its single-cycle map_d chain
// (analysis/g6lc_rename.md). An R1 map read cannot see:
//   * allocations by OLDER lanes of the same group (the unbanked design
//     saw them through its sequential map_d writes), or
//   * the writes of groups still ahead in the pipe -- a group in R3 has
//     not written map_q/busy_q yet, and the group just published may have
//     landed in the same edge the R1 read sampled.
// Both are covered by records: per lane, the newest matching destination
// wins in the order map-read < prev1 < prev0 < same-group-older-lane,
// which is exactly youngest-to-oldest program order for producers.
// A matched source is not ready: its physical tag is being written by an
// in-flight producer, so the IQ entry waits for its wakeup (the unbanked
// rs*_ready_o = 0 bypass, same meaning one stage later). A bypassed tag
// never changes correctness of the match itself -- it is the same phys tag
// the map would have returned once the producer's publish lands.
//
// prev records are written by the wrapper when a group leaves R1->R2;
// they are cleared on every recovery event (a dead group's registers are
// reclaimed and may be re-picked, so its tags must never satisfy a
// consumer). The hart compare on each record is a staged-form
// strengthening: under the drained handoff all lanes share a hart so it
// is inert, and under mixed residency it is the conservative direction.

module g6lc_rename_resolve
  import g6lc_ooo_pkg::*;
#(
    parameter int unsigned NR_PORTS = 2
) (
    input  ooo_ren_lane_t [NR_PORTS-1:0] lane_i,
    // Previous two groups' lane records (prev0 = just ahead).
    input  ooo_ren_lane_t [NR_PORTS-1:0] prev0_i,
    input  ooo_ren_lane_t [NR_PORTS-1:0] prev1_i,
    output ooo_ren_lane_t [NR_PORTS-1:0] lane_o
);
  // svt-stage: begin RR

  // Apply one producer record to a resolved lane: integer dests feed
  // integer sources (and the integer predecessor tag), FP dests feed FP
  // sources. The class split mirrors the unbanked !is_fpr_rsN guards --
  // x5 and f5 share an architectural number but are different registers.
  // prd_old follows the same youngest-wins rule: it is the mapping this
  // lane's own destination overwrite replaces.
  function automatic ooo_ren_lane_t bypass_lane(
      input ooo_ren_lane_t l_in, input ooo_ren_lane_t prod);
    ooo_ren_lane_t l;
    l = l_in;
    if (prod.v && prod.do_alloc && (prod.hart == l.hart)) begin
      if (!l.f_rs1 && (prod.rd == l.rs1) && (prod.rd != 5'd0)) begin
        l.prs1 = prod.prd;
        l.rs1_rdy = 1'b0;
      end
      if (!l.f_rs2 && (prod.rd == l.rs2) && (prod.rd != 5'd0)) begin
        l.prs2 = prod.prd;
        l.rs2_rdy = 1'b0;
      end
      if ((prod.rd == l.rd) && (prod.rd != 5'd0))
        l.old = prod.prd;
    end
    if (prod.v && prod.do_falloc && (prod.hart == l.hart)) begin
      // No rd!=0 filter on the FP class: f0 is a real register.
      if (l.f_rs1 && (prod.rd == l.rs1)) begin
        l.fprs1 = prod.fprd;
        l.rs1_rdy = 1'b0;
      end
      if (l.f_rs2 && (prod.rd == l.rs2)) begin
        l.fprs2 = prod.fprd;
        l.rs2_rdy = 1'b0;
      end
      if (l.f_rs3 && (prod.rd == l.rs3)) begin
        l.fprs3 = prod.fprd;
        l.rs3_rdy = 1'b0;
      end
      if (l.f_rd && (prod.rd == l.rd))
        l.fold = prod.fprd;
    end
    return l;
  endfunction

  // hyp8: the serial fold over 3*NR_PORTS producers is replaced by
  // per-field compare vectors, a highest-set one-hot (the youngest
  // producer wins, matching the emit's apply-order prev1 -> prev0 ->
  // same-group lanes), and balanced masked-OR gathers. Every lane field
  // is an independent LHS cone.
  function automatic logic [3*NR_PORTS-1:0] hi_last(
      input logic [3*NR_PORTS-1:0] x);
    logic [3*NR_PORTS-1:0] a;
    a = x << 1;
    for (int unsigned l = 1; l < 3 * NR_PORTS; l = l << 1) a = a | (a << l);
    return x & ~a;
  endfunction

  localparam int unsigned RL = (3 * NR_PORTS > 1) ? $clog2(3 * NR_PORTS) : 1;

  for (genvar p = 0; p < NR_PORTS; p++) begin : gen_lane
    // Ordered producers: prev1 (oldest) | prev0 | same-group lanes < p
    // | padding. Highest index = youngest = last applied.
    ooo_ren_lane_t prod_g [3 * NR_PORTS];
    for (genvar e = 0; e < 3 * NR_PORTS; e++) begin : gen_pg
      if (e < NR_PORTS)
        assign prod_g[e] = prev1_i[e];
      else if (e < 2 * NR_PORTS)
        assign prod_g[e] = prev0_i[e - NR_PORTS];
      else if (e - 2 * NR_PORTS < p)
        assign prod_g[e] = lane_i[e - 2 * NR_PORTS];
      else
        assign prod_g[e] = '0;
    end
    logic [3*NR_PORTS-1:0] ia, fa;
    logic [3*NR_PORTS-1:0] h_s1, h_s2, h_old, h_f1, h_f2, h_f3, h_fold;
    for (genvar e = 0; e < 3 * NR_PORTS; e++) begin : gen_hv
      assign ia[e] = prod_g[e].v && prod_g[e].do_alloc &&
                     (prod_g[e].hart == lane_i[p].hart);
      assign fa[e] = prod_g[e].v && prod_g[e].do_falloc &&
                     (prod_g[e].hart == lane_i[p].hart);
      assign h_s1[e] = ia[e] && !lane_i[p].f_rs1 &&
                       (prod_g[e].rd == lane_i[p].rs1) &&
                       (prod_g[e].rd != 5'd0);
      assign h_s2[e] = ia[e] && !lane_i[p].f_rs2 &&
                       (prod_g[e].rd == lane_i[p].rs2) &&
                       (prod_g[e].rd != 5'd0);
      assign h_old[e] = ia[e] && (prod_g[e].rd == lane_i[p].rd) &&
                        (prod_g[e].rd != 5'd0);
      assign h_f1[e] = fa[e] && lane_i[p].f_rs1 &&
                       (prod_g[e].rd == lane_i[p].rs1);
      assign h_f2[e] = fa[e] && lane_i[p].f_rs2 &&
                       (prod_g[e].rd == lane_i[p].rs2);
      assign h_f3[e] = fa[e] && lane_i[p].f_rs3 &&
                       (prod_g[e].rd == lane_i[p].rs3);
      assign h_fold[e] = fa[e] && lane_i[p].f_rd &&
                         (prod_g[e].rd == lane_i[p].rd);
    end
    logic [3*NR_PORTS-1:0] o_s1, o_s2, o_old, o_f1, o_f2, o_f3, o_fold;
    assign o_s1   = hi_last(h_s1);
    assign o_s2   = hi_last(h_s2);
    assign o_old  = hi_last(h_old);
    assign o_f1   = hi_last(h_f1);
    assign o_f2   = hi_last(h_f2);
    assign o_f3   = hi_last(h_f3);
    assign o_fold = hi_last(h_fold);
    // Masked-OR pairwise gathers: the one-hot producer's tag per field.
    logic [6:0][7:0] pick;
    logic [3*NR_PORTS-1:0][7:0] leaf [7];
    logic [6:0][3*NR_PORTS-1:0]  oh;
    assign oh = {o_fold, o_f3, o_f2, o_f1, o_old, o_s2, o_s1};
    for (genvar f = 0; f < 7; f++) begin : gen_f
      for (genvar e = 0; e < 3 * NR_PORTS; e++) begin : gen_leaf
        if (f < 3)
          assign leaf[f][e] = {8{oh[f][e]}} & prod_g[e].prd;
        else
          assign leaf[f][e] = {8{oh[f][e]}} & prod_g[e].fprd;
      end
      logic [RL:0][3*NR_PORTS-1:0][7:0] rt;
      for (genvar e = 0; e < 3 * NR_PORTS; e++)
        assign rt[0][e] = leaf[f][e];
      for (genvar l = 0; l < RL; l++) begin : gen_lvl
        localparam int unsigned NW = (3*NR_PORTS + (1 << l) - 1) >> l;
        localparam int unsigned NX = (3*NR_PORTS + (1 << (l+1)) - 1) >> (l+1);
        for (genvar t = 0; t < 3 * NR_PORTS; t++) begin : gen_t
          if (t < NX) begin : gen_in
            if (2 * t + 1 < NW) begin : gen_pair
              assign rt[l+1][t] = rt[l][2*t] | rt[l][2*t+1];
            end else begin : gen_odd
              assign rt[l+1][t] = rt[l][2*t];
            end
          end else begin : gen_pad
            assign rt[l+1][t] = '0;
          end
        end
      end
      assign pick[f] = rt[RL][0];
    end
    always_comb begin : p_out
      lane_o[p]         = lane_i[p];
      lane_o[p].prs1    = (|h_s1)   ? pick[0] : lane_i[p].prs1;
      lane_o[p].prs2    = (|h_s2)   ? pick[1] : lane_i[p].prs2;
      lane_o[p].old     = (|h_old)  ? pick[2] : lane_i[p].old;
      lane_o[p].fprs1   = (|h_f1)   ? pick[3] : lane_i[p].fprs1;
      lane_o[p].fprs2   = (|h_f2)   ? pick[4] : lane_i[p].fprs2;
      lane_o[p].fprs3   = (|h_f3)   ? pick[5] : lane_i[p].fprs3;
      lane_o[p].fold    = (|h_fold) ? pick[6] : lane_i[p].fold;
      lane_o[p].rs1_rdy = lane_i[p].rs1_rdy && ~(|h_s1) && ~(|h_f1);
      lane_o[p].rs2_rdy = lane_i[p].rs2_rdy && ~(|h_s2) && ~(|h_f2);
      lane_o[p].rs3_rdy = lane_i[p].rs3_rdy && ~(|h_f3);
    end
  end

  // svt-stage: end RR
  // svt-stage: class RR decision
endmodule
