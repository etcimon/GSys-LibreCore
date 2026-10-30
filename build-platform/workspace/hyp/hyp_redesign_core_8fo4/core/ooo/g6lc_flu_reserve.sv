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
    // r97: per-lane static offset masks replace the serial greedy
    // admission loop - eligibility and earlier-offer conflicts are
    // parallel, and the final-accept reservation write is per-slot.
    localparam int unsigned WBC = int'(HypCfg.WbCaptureStages);
    localparam bit STAGGER = HypCfg.AluStages >= 2 && HypCfg.AluStaggered;
    localparam int unsigned LOW_CYC = (STAGGER ? 2 : 1) + WBC;
    localparam int unsigned FULL_CYC = (STAGGER ? int'(HypCfg.AluStages) : 1) + WBC;
    localparam int unsigned MUL_CYC = g6lc_hyp_pkg::hyp_mult_stages(HypCfg, int'(G6LCCfg.MultStages)) + WBC;
    localparam logic [RES_WIN-1:0] LOW_MASK = RES_WIN'(1) << (1 + LOW_CYC);
    localparam logic [RES_WIN-1:0] FULL_MASK = RES_WIN'(1) << (1 + FULL_CYC);
    localparam logic [RES_WIN-1:0] MUL_MASK = RES_WIN'(1) << (1 + MUL_CYC);
    localparam logic [RES_WIN-1:0] BR_MASK = RES_WIN'(1) << (3 + WBC);
    localparam logic [RES_WIN-1:0] ONE_MASK = RES_WIN'(1) << (2 + WBC);
    // Shifted occupancy window: bit k means "an accepted op's result is
    // due k cycles from now". One ownership bit for the divider.
    logic [RES_WIN-1:0]                      reserved_q;
    logic                                    div_live_q;
    logic [G6LCCfg.TRANS_ID_BITS-1:0]        div_tid_q;
    logic [NIP-1:0][RES_WIN-1:0] lane_mask;
    logic [NIP-1:0] lane_div, fixed_eligible, div_eligible, resource_eligible, div_winner;
    logic window_empty;
    assign window_empty = !(|reserved_q);
    for (genvar p = 0; p < NIP; p++) begin : gen_classify
      logic alu_low, mul_fixed;
      logic [RES_WIN-1:0] alu_mask;
      // Explicit membership exposes the opcode dependency. Case equality
      // retains the old decoder's default-false behavior for unknown op bits.
      assign alu_low = (op_i[p] inside {
          g6lc_core_pkg::ADD, g6lc_core_pkg::SUB,
          g6lc_core_pkg::ADDW, g6lc_core_pkg::SUBW,
          g6lc_core_pkg::XORL, g6lc_core_pkg::ORL,
          g6lc_core_pkg::ANDL, g6lc_core_pkg::ANDN,
          g6lc_core_pkg::ORN, g6lc_core_pkg::XNOR,
          g6lc_core_pkg::SH1ADD, g6lc_core_pkg::SH2ADD,
          g6lc_core_pkg::SH3ADD, g6lc_core_pkg::SH1ADDUW,
          g6lc_core_pkg::SH2ADDUW, g6lc_core_pkg::SH3ADDUW,
          g6lc_core_pkg::ADDUW}) === 1'b1;
      assign mul_fixed = (op_i[p] inside {
          g6lc_core_pkg::MUL, g6lc_core_pkg::MULH, g6lc_core_pkg::MULHU,
          g6lc_core_pkg::MULHSU, g6lc_core_pkg::MULW,
          g6lc_core_pkg::CLMUL, g6lc_core_pkg::CLMULH,
          g6lc_core_pkg::CLMULR}) === 1'b1;
      if (p == 0) begin : gen_primary
        assign alu_mask = alu_low ? LOW_MASK : FULL_MASK;
      end else begin : gen_secondary
        assign alu_mask = {RES_WIN{!alu_low}} & FULL_MASK;
      end
      assign lane_mask[p] =
          ({RES_WIN{fu_i[p] == g6lc_core_pkg::ALU}} & alu_mask) |
          ({RES_WIN{fu_i[p] == g6lc_core_pkg::CTRL_FLOW}} & BR_MASK) |
          ({RES_WIN{fu_i[p] == g6lc_core_pkg::CSR || fu_i[p] == g6lc_core_pkg::AES}} & ONE_MASK) |
          ({RES_WIN{fu_i[p] == g6lc_core_pkg::MULT && mul_fixed && MUL_CYC != 0}} & MUL_MASK);
      assign lane_div[p] = fu_i[p] == g6lc_core_pkg::MULT && (!mul_fixed || MUL_CYC == 0);
      assign fixed_eligible[p] = offer_i[p] && (|lane_mask[p]) && !div_live_q && !(|(lane_mask[p] & reserved_q));
      assign div_eligible[p] = offer_i[p] && lane_div[p] && !div_live_q && window_empty;
      assign resource_eligible[p] = fixed_eligible[p] || div_eligible[p];
    end

    // Parallel admission: a lane's fixed offer loses only to an earlier
    // *eligible* fixed offer hitting one of its slots or an earlier
    // divider winner; a divider wins only the empty window and no
    // earlier resource claim. No admit reads another admit.
    for (genvar p = 0; p < NIP; p++) begin : gen_admit
      logic [NIP-1:0] earlier_resource, earlier_same, earlier_div;
      for (genvar q = 0; q < NIP; q++) begin : gen_prior
        if (q < p) begin : gen_earlier
          assign earlier_resource[q] = resource_eligible[q];
          assign earlier_same[q] = fixed_eligible[q] && (|(lane_mask[q] & lane_mask[p]));
          assign earlier_div[q] = div_winner[q];
        end else begin : gen_not_earlier
          assign earlier_resource[q] = 1'b0;
          assign earlier_same[q] = 1'b0;
          assign earlier_div[q] = 1'b0;
        end
      end
      assign div_winner[p] = div_eligible[p] && !(|earlier_resource);
      assign admit_o[p] = !offer_i[p] || (!(|lane_mask[p]) && !lane_div[p]) ||
          (fixed_eligible[p] && !(|earlier_same) && !(|earlier_div)) || div_winner[p];
    end

    assign stall_o = |(offer_i & ~admit_o);

    // Sequential consumption on ACTUAL accepts only. The window shifts
    // once per edge after OR-ing this cycle's accepted offsets in.
    logic [RES_WIN-1:0] reserved_next;
    logic               div_accept, wb_div_match, div_release;

    for (genvar s = 0; s < RES_WIN; s++) begin : gen_accept_slot
      logic [NIP-1:0] accepted_here;
      for (genvar p = 0; p < NIP; p++) begin : gen_lane
        assign accepted_here[p] = accept_i[p] && lane_mask[p][s];
      end
      assign reserved_next[s] = reserved_q[s] || (|accepted_here);
    end
    assign div_accept = |(accept_i & lane_div);

    always_comb begin

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

    // Retained greedy oracle: replays the serial admission with the old
    // helper calls against the live registered state. Parallel admits
    // must agree bit-for-bit; synthesis excludes the whole block.
    always_ff @(posedge clk_i) begin : flu_oracle
      if (rst_ni) begin
        logic [RES_WIN-1:0] ref_used;
        logic               ref_claim;
        logic [NIP-1:0]     ref_admit, ref_div;
        int unsigned        ref_cyc [NIP];
        ref_used = reserved_q; ref_claim = div_live_q; ref_admit = '0;
        for (int unsigned p = 0; p < NIP; p++) begin
          ref_cyc[p] = (p != 0 && fu_i[p] == g6lc_core_pkg::ALU &&
              g6lc_ooo_pkg::ooo_lat_class(fu_i[p], op_i[p]) ==
              g6lc_hyp_pkg::LAT_ALU_LOW) ? 0 :
              g6lc_ooo_pkg::ooo_flu_cycles(G6LCCfg, HypCfg, fu_i[p], op_i[p]);
          ref_div[p] = fu_i[p] == g6lc_core_pkg::MULT && ref_cyc[p] == 0;
          a_off_in_win: assert (ref_cyc[p] == 0 || (1 + ref_cyc[p]) < RES_WIN)
            else $error("g6lc_flu_reserve: offset %0d outside RES_WIN=%0d",
                        1 + ref_cyc[p], RES_WIN);
          if (!offer_i[p]) ref_admit[p] = 1'b1;
          else if (ref_div[p]) begin
            ref_admit[p] = !ref_claim && ref_used == '0;
            if (ref_admit[p]) ref_claim = 1'b1;
          end else if (ref_cyc[p] != 0) begin
            ref_admit[p] = !ref_claim && !ref_used[1 + ref_cyc[p]];
            if (ref_admit[p]) ref_used[1 + ref_cyc[p]] = 1'b1;
          end else ref_admit[p] = 1'b1;
          assert (admit_o[p] === ref_admit[p])
            else $error("flu_reserve admit[%0d] parallel != greedy", p);
          assert (lane_mask[p] == ((ref_cyc[p] == 0) ? '0
                  : RES_WIN'(1) << (1 + ref_cyc[p])))
            else $error("flu_reserve mask[%0d] != offset", p);
          assert (lane_div[p] === ref_div[p])
            else $error("flu_reserve div[%0d] identity", p);
        end
      end
    end
//pragma translate_on

  end

endmodule
