// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.1 SMT thread select — contention-aware arbitration for shared pipeline.
// Supports 1..CVA6_MAX_SMT_HARTS harts (N-way, not SMT2-only).
//
// Policies (cva6_cfg_t.SmtPolicy):
//   SMT_RR             — round-robin after SmtFetchQuantum consecutive grants
//   SMT_SWITCH_ON_MISS — switch when active hart D$/I$ miss if a peer is ready
//   SMT_HYBRID         — miss-prefer + quantum RR + anti-starve
//
// Peer selection (NrHarts>2): prefer lowest ready non-active index, then wrap
// RR from last_peer. Never uses ~active (that only works for NH==2).
//
// When NrHarts==1: constant-0 identity.
//
// switch_o is a 1-cycle *delayed* pulse relative to the do_switch decision so
// it asserts in the same cycle active_hart_o already holds the *incoming*
// hart. PC-bank restore indexes npc_bank[active_hart]; a same-cycle comb
// switch with registered active restored the *outgoing* bank (peer never ran).

module g6lc_thread_select
  import config_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic fetch_fire_i,
    input  logic issue_fire_i,
    input  logic flush_i,
    // Hold switches (e.g. active hart still executing bootrom). Keeps active_hart
    // stable so PC-bank save/restore cannot corrupt a bootrom→DRAM jump.
    input  logic hold_i,
    input  logic [CVA6Cfg.NrHarts-1:0] hart_ready_i,
    input  logic [CVA6Cfg.NrHarts-1:0] hart_dmiss_i,
    input  logic [CVA6Cfg.NrHarts-1:0] hart_imiss_i,
    input  logic [CVA6Cfg.NrHarts-1:0] hart_block_i,
    output logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] active_hart_o,
    output logic switch_o,
    output logic switch_on_miss_o,
    output logic switch_on_quantum_o,
    output logic switch_on_starve_o
);

  localparam int unsigned NH     = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W  = (NH <= 1) ? 1 : $clog2(NH);
  localparam int unsigned Q_MAX  = (CVA6Cfg.SmtFetchQuantum == 0) ? 1 : CVA6Cfg.SmtFetchQuantum;
  localparam int unsigned Q_W    = (Q_MAX <= 1) ? 1 : $clog2(Q_MAX + 1);
  localparam int unsigned ST_MAX = CVA6Cfg.SmtStarveLimit;
  localparam int unsigned ST_W   = (ST_MAX <= 1) ? 1 : $clog2(ST_MAX + 1);
  localparam smt_policy_t POLICY = CVA6Cfg.SmtPolicy;

  if (NH <= 1) begin : gen_single_hart
    assign active_hart_o       = '0;
    assign switch_o            = 1'b0;
    assign switch_on_miss_o    = 1'b0;
    assign switch_on_quantum_o = 1'b0;
    assign switch_on_starve_o  = 1'b0;
    logic _unused_boot;
    assign _unused_boot = fetch_fire_i | issue_fire_i | flush_i | hold_i;
  end else begin : gen_smt

    logic [HID_W-1:0] active_q, active_d;
    logic [HID_W-1:0] rr_ptr_q, rr_ptr_d;  // next RR candidate after active
    logic [Q_W-1:0]   quantum_q, quantum_d;
    logic [ST_W-1:0]  starve_q[NH];
    logic [ST_W-1:0]  starve_d[NH];
    // After activate, suppress miss-switch briefly so an I$ fill can complete
    // (otherwise HYBRID ejects the peer every miss before bootrom progresses).
    logic [3:0] activate_age_q, activate_age_d;
    localparam logic [3:0] MISS_SWITCH_BLACKOUT = 4'd8;

    logic [NH-1:0] miss_or_block;
    logic          active_stalled;
    logic [HID_W-1:0] peer_any, peer_clean, peer_starve, next_peer;
    logic          found_peer, found_clean, found_starve;
    logic          do_switch;
    logic          reason_miss, reason_quantum, reason_starve;

    always_comb begin
      for (int unsigned h = 0; h < NH; h++) begin
        miss_or_block[h] = hart_dmiss_i[h] | hart_imiss_i[h] | hart_block_i[h];
      end
    end

    assign active_stalled = miss_or_block[active_q] | ~hart_ready_i[active_q];

    // RR scan: any ready peer, clean peer, starved peer
    always_comb begin
      peer_any     = active_q;
      peer_clean   = active_q;
      peer_starve  = active_q;
      found_peer   = 1'b0;
      found_clean  = 1'b0;
      found_starve = 1'b0;
      for (int unsigned k = 0; k < NH; k++) begin
        automatic logic [HID_W-1:0] cand;
        cand = HID_W'((int'(rr_ptr_q) + k) % NH);
        if (cand != active_q && hart_ready_i[cand]) begin
          if (!found_peer) begin
            peer_any   = cand;
            found_peer = 1'b1;
          end
          if (!miss_or_block[cand] && !found_clean) begin
            peer_clean  = cand;
            found_clean = 1'b1;
          end
        end
      end
      for (int unsigned h = 0; h < NH; h++) begin
        if (h[HID_W-1:0] != active_q && hart_ready_i[h] && ST_MAX != 0 &&
            starve_q[h] >= ST_MAX[ST_W-1:0]) begin
          if (!found_starve || starve_q[h] > starve_q[peer_starve]) begin
            peer_starve  = h[HID_W-1:0];
            found_starve = 1'b1;
          end
        end
      end
    end

    always_comb begin
      active_d       = active_q;
      rr_ptr_d       = rr_ptr_q;
      quantum_d      = quantum_q;
      activate_age_d = (activate_age_q == 4'hF) ? 4'hF : (activate_age_q + 4'd1);
      do_switch      = 1'b0;
      reason_miss    = 1'b0;
      reason_quantum = 1'b0;
      reason_starve  = 1'b0;
      next_peer      = peer_any;
      for (int unsigned h = 0; h < NH; h++) starve_d[h] = starve_q[h];

      unique case (POLICY)
        SMT_SWITCH_ON_MISS: begin
          if (active_stalled && found_clean &&
              (activate_age_q >= MISS_SWITCH_BLACKOUT)) begin
            do_switch   = 1'b1;
            reason_miss = 1'b1;
            next_peer   = peer_clean;
          end else if (!hart_ready_i[active_q] && found_peer) begin
            do_switch   = 1'b1;
            reason_miss = 1'b1;
            next_peer   = peer_any;
          end
        end
        SMT_RR: begin
          if (fetch_fire_i && (quantum_q + 1'b1 >= Q_MAX[Q_W-1:0]) && found_peer) begin
            do_switch      = 1'b1;
            reason_quantum = 1'b1;
            next_peer      = peer_any;
          end else if (!hart_ready_i[active_q] && found_peer) begin
            do_switch      = 1'b1;
            reason_quantum = 1'b1;
            next_peer      = peer_any;
          end
        end
        default: begin  // SMT_HYBRID
          if (active_stalled && found_clean &&
              (activate_age_q >= MISS_SWITCH_BLACKOUT)) begin
            do_switch   = 1'b1;
            reason_miss = 1'b1;
            next_peer   = peer_clean;
          end else if (found_starve) begin
            do_switch     = 1'b1;
            reason_starve = 1'b1;
            next_peer     = peer_starve;
          end else if (fetch_fire_i &&
                       (quantum_q + 1'b1 >= Q_MAX[Q_W-1:0]) && found_peer) begin
            do_switch      = 1'b1;
            reason_quantum = 1'b1;
            next_peer      = peer_any;
          end else if (!hart_ready_i[active_q] && found_peer) begin
            do_switch   = 1'b1;
            reason_miss = 1'b1;
            next_peer   = peer_any;
          end
        end
      endcase

      // Hold wins over policy: no switch. Also *freeze* quantum/starve aging —
      // otherwise the parked primary's starve hits ST_MAX during peer bootrom
      // and, the cycle peer exits bootrom (hold drops), starve immediately
      // steals the pipeline back before peer_pass can run (concurrent dual-active fail).
      if (hold_i) begin
        do_switch      = 1'b0;
        reason_miss    = 1'b0;
        reason_quantum = 1'b0;
        reason_starve  = 1'b0;
        // Zero quantum under hold so when hold drops the active hart always
        // receives a full fetch quantum (freeze-high caused immediate RR steal).
        quantum_d      = '0;
        activate_age_d = activate_age_q;
        for (int unsigned h = 0; h < NH; h++) starve_d[h] = starve_q[h];
      end else if (do_switch) begin
        active_d            = next_peer;
        quantum_d           = '0;
        activate_age_d      = '0;
        starve_d[next_peer] = '0;
        // Zero all starve counters on switch so the outgoing hart does not
        // re-win on starve the next cycle after a bootrom hold window.
        for (int unsigned h = 0; h < NH; h++) begin
          if (h[HID_W-1:0] != next_peer) starve_d[h] = '0;
        end
        rr_ptr_d            = HID_W'((int'(next_peer) + 1) % NH);
      end else begin
        if (fetch_fire_i) begin
          if (quantum_q + 1'b1 >= Q_MAX[Q_W-1:0])
            quantum_d = Q_MAX[Q_W-1:0];
          else
            quantum_d = quantum_q + 1'b1;
        end
        for (int unsigned h = 0; h < NH; h++) begin
          if (h[HID_W-1:0] == active_q)
            starve_d[h] = '0;
          else if (hart_ready_i[h] && ST_MAX != 0) begin
            if (starve_q[h] < ST_MAX[ST_W-1:0])
              starve_d[h] = starve_q[h] + 1'b1;
          end
        end
      end

      if (flush_i) quantum_d = '0;

    end

    // Delayed switch pulse: fires when active_q already equals the incoming hart.
    logic switch_q;
    logic reason_miss_q, reason_quantum_q, reason_starve_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        active_q         <= '0;
        rr_ptr_q         <= HID_W'(1 % NH);  // prefer hart 1 as first alternate
        quantum_q        <= '0;
        activate_age_q   <= '0;
        switch_q         <= 1'b0;
        reason_miss_q    <= 1'b0;
        reason_quantum_q <= 1'b0;
        reason_starve_q  <= 1'b0;
        for (int unsigned h = 0; h < NH; h++) starve_q[h] <= '0;
      end else begin
        active_q         <= active_d;
        rr_ptr_q         <= rr_ptr_d;
        quantum_q        <= quantum_d;
        activate_age_q   <= activate_age_d;
        switch_q         <= do_switch;
        reason_miss_q    <= do_switch & reason_miss;
        reason_quantum_q <= do_switch & reason_quantum;
        reason_starve_q  <= do_switch & reason_starve;
        for (int unsigned h = 0; h < NH; h++) starve_q[h] <= starve_d[h];
      end
    end

    assign active_hart_o       = active_q;
    assign switch_o            = switch_q;
    assign switch_on_miss_o    = reason_miss_q;
    assign switch_on_quantum_o = reason_quantum_q;
    assign switch_on_starve_o  = reason_starve_q;

    // issue_fire reserved for future issue-quantum policy
    logic _unused_issue;
    assign _unused_issue = issue_fire_i;

  end

endmodule
