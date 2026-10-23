// hyp8 provenance: NEW (actual-acceptance FLU writeback reservation)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_flu_reserve -- IRO-acceptance FLU completion reservation
// (analysis/continuation-design.md). The shared FLU writeback port in
// ex_stage can publish one record per cycle; every accepted fixed-latency
// FLU op therefore claims the window slot at offset 1+ooo_flu_cycles(fu,op)
// so no two admitted ops complete on the same edge. This is NOT an output
// FIFO: the window only declines the acknowledgement of a lane whose
// arrival would collide or land while the variable-latency divider owns
// the port -- the held lane is re-offered next cycle.
//
// Authority boundary: offers are the IRO scoreboard's pre-ack result with
// exceptions and flush already excluded by the caller; reservations are
// consumed only by the FINAL accept vector (post casq/CVXIF/lr_sc/prefix
// post-processing), never by the tentative offer. The divider claim is
// released only by its matching writeback, by scoreboard reclamation of
// its trans_id, or by reset -- never by a pre-acceptance mult_ready and
// never by the partial unissued flush (admission is already prevented by
// the zeroed offer/accept under flush; older bits expire with time).
//
// With HypCfg.WbReserve==0 the module admits every lane and tracks
// nothing.

module g6lc_flu_reserve #(
    parameter config_pkg::g6lc_cfg_t        G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t  HypCfg  = g6lc_hyp_pkg::HypDefault
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Offered lanes (IRO pre-ack, valid, non-exception, non-flush).
    input  logic [G6LCCfg.NrIssuePorts-1:0]                     offer_i,
    // Actually accepted lanes (final issue_ack_o, same qualifications).
    input  logic [G6LCCfg.NrIssuePorts-1:0]                     accept_i,
    input  g6lc_core_pkg::fu_t  [G6LCCfg.NrIssuePorts-1:0]      fu_i,
    input  g6lc_core_pkg::fu_op [G6LCCfg.NrIssuePorts-1:0]      op_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]
           [G6LCCfg.TRANS_ID_BITS-1:0]                          tid_i,
    // Scoreboard liveness (fwd_i.still_issued) for divider reclamation.
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                    sb_live_i,
    // Actual writeback observations for divider release.
    input  logic [G6LCCfg.NrWbPorts-1:0]                        wb_valid_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] wb_tid_i,
    // Admission of each offered lane (1 for non-FLU / non-offered lanes).
    output logic [G6LCCfg.NrIssuePorts-1:0]                     admit_o,
    // An offered lane was declined this cycle (PMU seam).
    output logic                                                stall_o
);

  if (!HypCfg.WbReserve) begin : gen_passthrough
    assign admit_o = '1;
    assign stall_o = 1'b0;
    // No state is tracked: the reservation model only exists for the
    // repaired stalled-IRO profile.
  end else begin : gen_reserve

    localparam int unsigned NIP = G6LCCfg.NrIssuePorts;
    localparam int unsigned RES_WIN =
        g6lc_ooo_pkg::ooo_flu_res_win(G6LCCfg, HypCfg);
    localparam int unsigned OFF_W = (RES_WIN > 1) ? $clog2(RES_WIN) : 1;

    // Shifted occupancy window: bit k means "an accepted op's result is
    // due k cycles from now". One ownership bit for the divider.
    logic [RES_WIN-1:0]                      reserved_q;
    logic                                    div_live_q;
    logic [G6LCCfg.TRANS_ID_BITS-1:0]        div_tid_q;

    // Per-lane classification (combinational copies for the admits).
    int unsigned           lane_cyc  [NIP];
    logic [NIP-1:0]        lane_flu;    // rides the shared FLU WB port
    logic [NIP-1:0]        lane_div;    // variable-latency divider
    logic [NIP-1:0][OFF_W-1:0] lane_off;
    // ALU2: a non-zero port's LAT_ALU_LOW completes on FPU_WB, not on the
    // shared FLU port. Port 0's ALU-low still reserves FLU. Classified
    // beside the loop so the opcode case is not another serial statement
    // inside the admit chain.
    logic [NIP-1:0] lane_alu2;
    for (genvar p = 0; p < NIP; p++) begin : gen_alu2
      if (p == 0) begin : gen_p0
        assign lane_alu2[p] = 1'b0;
      end else begin : gen_pn
        assign lane_alu2[p] = (fu_i[p] == g6lc_core_pkg::ALU) &&
            (g6lc_ooo_pkg::ooo_lat_class(fu_i[p], op_i[p]) ==
             g6lc_hyp_pkg::LAT_ALU_LOW);
      end
    end

    always_comb begin
      for (int unsigned p = 0; p < NIP; p++) begin
        lane_cyc[p]  = lane_alu2[p] ? 0 :
            g6lc_ooo_pkg::ooo_flu_cycles(G6LCCfg, HypCfg, fu_i[p], op_i[p]);
        lane_div[p]  = (fu_i[p] == g6lc_core_pkg::MULT) && (lane_cyc[p] == 0);
        lane_flu[p]  = (lane_cyc[p] != 0) || lane_div[p];
        lane_off[p]  = OFF_W'(1 + lane_cyc[p]);
      end
    end

    // Combinational admission over a working copy of the window; each
    // lane's decision sees the reservations of the lanes already admitted
    // this same cycle (lane order = port order).
    logic [RES_WIN-1:0] used;
    logic               div_claim;
    always_comb begin
      used      = reserved_q;
      div_claim = div_live_q;
      admit_o   = '0;
      for (int unsigned p = 0; p < NIP; p++) begin
        if (!offer_i[p]) begin
          admit_o[p] = 1'b1;  // no offer -> nothing to reserve
        end else if (lane_div[p]) begin
          // Divider: needs an empty window and no outstanding claim.
          admit_o[p] = !div_claim && (used == '0);
          if (admit_o[p]) div_claim = 1'b1;
        end else if (lane_cyc[p] != 0) begin
          admit_o[p] = !div_claim && !used[lane_off[p]];
          if (admit_o[p]) used[lane_off[p]] = 1'b1;
        end else begin
          admit_o[p] = 1'b1;  // non-FLU: no shared-port resource
        end
      end
    end

    assign stall_o = |(offer_i & ~admit_o);

    // Sequential consumption on ACTUAL accepts only. The window shifts
    // once per edge after OR-ing this cycle's accepted offsets in.
    logic [RES_WIN-1:0] reserved_next;
    logic               div_accept, wb_div_match, div_release;

    always_comb begin
      reserved_next = reserved_q;
      div_accept    = 1'b0;
      for (int unsigned p = 0; p < NIP; p++) begin
        if (accept_i[p] && (lane_cyc[p] != 0))
          reserved_next[lane_off[p]] = 1'b1;
        if (accept_i[p] && lane_div[p])
          div_accept = 1'b1;
      end

      // Divider release: its matching writeback, or the scoreboard slot
      // dying underneath it (cancel/reclaim). No mult_ready term -- a
      // pre-acceptance ready flag never ends ownership.
      wb_div_match = 1'b0;
      for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
        if (wb_valid_i[w] && (wb_tid_i[w] == div_tid_q))
          wb_div_match = 1'b1;
      div_release = wb_div_match || !sb_live_i[div_tid_q];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        reserved_q <= '0;
        div_live_q <= 1'b0;
        div_tid_q  <= '0;
      end else begin
        reserved_q <= RES_WIN'(reserved_next >> 1);
        if (div_accept) begin
          // Admission already excluded a live claim, so this can only
          // fire when div_live_q is clear or releasing this edge.
          div_live_q <= 1'b1;
          div_tid_q  <= '0;
          for (int unsigned p = 0; p < NIP; p++)
            if (accept_i[p] && lane_div[p]) div_tid_q <= tid_i[p];
        end else if (div_live_q && div_release) begin
          div_live_q <= 1'b0;
        end
      end
    end

//pragma translate_off
    // Window reachability: every supported fixed offset fits.
    initial begin
      assert (RES_WIN > 1 + g6lc_hyp_pkg::hyp_mult_stages(
                  HypCfg, int'(G6LCCfg.MultStages)) &&
              RES_WIN > 1 + int'(HypCfg.AluStages) && RES_WIN > 3)
        else $fatal(1, "g6lc_flu_reserve: RES_WIN=%0d cannot cover offsets",
                    RES_WIN);
    end

    for (genvar p = 0; p < NIP; p++) begin : gen_res_chk
      // An accepted offer implies it was admitted -- the final ack must
      // never resurrect a lane this unit declined.
      property p_accept_implies_admit;
        @(posedge clk_i) disable iff (!rst_ni)
          (accept_i[p] && offer_i[p]) |-> admit_o[p];
      endproperty
      a_accept_implies_admit: assert property (p_accept_implies_admit)
        else $error("g6lc_flu_reserve: accept on port %0d without admit", p);
      // Accepted fixed-FLU offsets are always inside the window.
      property p_off_in_win;
        @(posedge clk_i) disable iff (!rst_ni)
          (accept_i[p] && (lane_cyc[p] != 0)) |-> (int'(lane_off[p]) < RES_WIN);
      endproperty
      a_off_in_win: assert property (p_off_in_win)
        else $error("g6lc_flu_reserve: offset %0d outside RES_WIN=%0d",
                    lane_off[p], RES_WIN);
    end

    // At most one divider owner: a divider accept can only happen against
    // a clear (or this-edge-releasing) claim.
    property p_div_single;
      @(posedge clk_i) disable iff (!rst_ni)
        div_accept |-> (!div_live_q || div_release);
    endproperty
    a_div_single: assert property (p_div_single)
      else $error("g6lc_flu_reserve: second divider admitted while owned");

    // Ownership persists until the release condition -- in particular a
    // high mult_ready before acceptance cannot release it (there is no
    // ready term in div_release).
    property p_div_hold;
      @(posedge clk_i) disable iff (!rst_ni)
        (div_live_q && !div_release && !div_accept) |=> div_live_q;
    endproperty
    a_div_hold: assert property (p_div_hold)
      else $error("g6lc_flu_reserve: divider ownership dropped without release");
//pragma translate_on

  end

endmodule
