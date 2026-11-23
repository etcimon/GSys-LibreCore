// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.1 SMT thread select — contention-aware arbitration for shared pipeline.
// Supports 1..G6LC_MAX_SMT_HARTS harts (N-way, not SMT2-only).
//
// Policies (g6lc_cfg_t.SmtPolicy):
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
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    // SMT: resident-cycle bound on the RR/HYBRID quantum; 0 = fetch-count
    // quantum only (a low-fetch-rate resident yields after this many cycles).
    parameter int unsigned CycQuantum = 0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic fetch_fire_i,
    input  logic issue_fire_i,
    input  logic flush_i,
    // Hold switches (e.g. active hart still executing bootrom). Keeps active_hart
    // stable so PC-bank save/restore cannot corrupt a bootrom→DRAM jump.
    input  logic hold_i,
    input  logic drain_ready_i,
    // N1c bounded drain (drained handoff only; inert when
    // G6LCCfg.SmtDrainForceCycles == 0).
    input  logic commit_i,          // any commit-stage ack this cycle
    input  logic drain_killable_i,  // resident in-flight state is cancellable
    input  logic head_wfi_i,        // resident commit head is a WFI
    input  logic head_plain_i,      // resident commit head is a plain op
    input  logic [G6LCCfg.VLEN-1:0] head_pc_i,   // oldest uncommitted PC
    output logic drain_force_o,     // pulse: flush the resident hart now
    output logic drain_force_wfi_o, // drain_force_o && head was WFI
    output logic drain_force_abs_o, // drain_force_o from the absolute bound
    output logic drain_forced_o,    // a force is outstanding until switch_o
    output logic [G6LCCfg.VLEN-1:0] drain_force_pc_o,
    output logic quiesce_o,
    // I4ba: ID has a hart-tagged unissued instruction.
    // I4bc: IQ head valid while ID is empty.
    // I4bd tried I$ present ∪ IQ while ID empty; hold-FAIL (`51b1c001`).
    input  logic id_uniss_i,
    input  logic iq_valid_i,
    // I4bg: ALU rd==x5 use_imm just issued (lui/addi t0).
    input  logic t0_imm_i,
    // I4br: frontend I4z mtvec fetch/tail — no switch (narrower than flush).
    input  logic trap_hold_i,
    input  logic [G6LCCfg.NrHarts-1:0] hart_ready_i,
    input  logic [G6LCCfg.NrHarts-1:0] hart_dmiss_i,
    input  logic [G6LCCfg.NrHarts-1:0] hart_imiss_i,
    input  logic [G6LCCfg.NrHarts-1:0] hart_block_i,
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] active_hart_o,
    output logic switch_o,
    // I4bi: t0_extra was set on the do_switch cycle (valid with switch_o).
    output logic t0_extra_o,
    output logic switch_on_miss_o,
    // Zihintpause yield hint (one bit per hart). Advisory only: it can defer a
    // hart behind an unpaused peer, never gate readiness, and the anti-starvation
    // limit below still guarantees the hinting hart's forward service.
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] pause_hint_i,
    output logic switch_on_quantum_o,
    output logic switch_on_starve_o
);

  localparam int unsigned NH     = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
  localparam int unsigned HID_W  = (NH <= 1) ? 1 : $clog2(NH);
  localparam int unsigned Q_MAX  = (G6LCCfg.SmtFetchQuantum == 0) ? 1 : G6LCCfg.SmtFetchQuantum;
  localparam int unsigned Q_W    = (Q_MAX <= 1) ? 1 : $clog2(Q_MAX + 1);
  localparam int unsigned ST_MAX = G6LCCfg.SmtStarveLimit;
  localparam int unsigned ST_W   = (ST_MAX <= 1) ? 1 : $clog2(ST_MAX + 1);
  localparam int unsigned CQ_W   = (CycQuantum <= 1) ? 1 : $clog2(CycQuantum + 1);
  localparam smt_policy_t POLICY = G6LCCfg.SmtPolicy;

  if (NH <= 1) begin : gen_single_hart
    assign active_hart_o       = '0;
    assign switch_o            = 1'b0;
    assign quiesce_o           = 1'b0;
    assign t0_extra_o          = 1'b0;
    assign switch_on_miss_o    = 1'b0;
    assign switch_on_quantum_o = 1'b0;
    assign switch_on_starve_o  = 1'b0;
    assign drain_force_o       = 1'b0;
    assign drain_force_wfi_o   = 1'b0;
    assign drain_force_abs_o   = 1'b0;
    assign drain_forced_o      = 1'b0;
    assign drain_force_pc_o    = '0;
    logic _unused_boot;
    assign _unused_boot = fetch_fire_i | issue_fire_i | flush_i | hold_i |
                          id_uniss_i | iq_valid_i | t0_imm_i | trap_hold_i |
                          commit_i | drain_killable_i | head_wfi_i |
                          head_plain_i | (|head_pc_i) | drain_ready_i;
  end else begin : gen_smt

    logic [HID_W-1:0] active_q, active_d;
    logic [HID_W-1:0] rr_ptr_q, rr_ptr_d;  // next RR candidate after active
    logic [Q_W-1:0]   quantum_q, quantum_d;
    logic [CQ_W-1:0]  cyc_q, cyc_d;
    logic             cyc_hit;
    logic [ST_W-1:0]  starve_q[NH];
    logic [ST_W-1:0]  starve_d[NH];
    // After activate, suppress miss-switch briefly so an I$ fill can complete.
    // Also require *sustained* stall (stall_age) before miss-switch: counting
    // only activate_age caused dual-ready thrash every ~8 cycles on I$ misses
    // (OpenSBI FDT/strchr never progressed on RTL while Spike was fine).
    logic [4:0] activate_age_q, activate_age_d;
    logic [7:0] stall_age_q, stall_age_d;
    // Forward progress for the anti-starvation switch: a switch flushes the
    // resident hart's pre-dispatch stream. A completed I$ refill alone is not
    // enough: the peer can starve-switch immediately after the fill and kill it
    // before issue (g6lc64_hyp8_mc boot ROM: starve switches every ~41 cycles,
    // zero retirements). A starve switch therefore waits until the resident
    // hart has issued once since it was activated, bounded at 255 cycles so
    // the peer's service floor still holds.
    logic [7:0] unissued_age_q;
    logic [5:0] uniss_pend_q, uniss_pend_d;
    logic       t0_extra_q, t0_extra_d;
    logic       t0_defer_q, t0_defer_d;
    localparam logic [4:0] MISS_SWITCH_BLACKOUT = 5'd16;
    localparam logic [7:0] MISS_STALL_THRESH = 8'd32;
    localparam logic [5:0] SMT_UNISS_WAIT = 6'd47;

    logic [NH-1:0] miss_or_block;
    logic          active_stalled;
    logic [HID_W-1:0] peer_any, peer_clean, peer_starve, next_peer;
    logic          found_peer, found_clean, found_starve;
    logic          do_switch;
    logic          reason_miss, reason_quantum, reason_starve;
    // Sticky per-hart yield request: set when that hart retires a PAUSE, cleared
    // when it is next activated. No counter, so a hart can never be held off by
    // its own stale hint.
    localparam bit PAUSE_EN = (G6LCCfg.ZihintpauseEn && NH > 1);
    logic [NH-1:0] pause_req_q, pause_req_d;
    logic [HID_W-1:0] peer_unpaused;
    logic          found_unpaused, reason_yield;
    logic switch_q;
`ifdef G6LC_FETCH_B
    logic drain_pending_q, drain_pending_d;
    logic [HID_W-1:0] drain_peer_q, drain_peer_d;
    logic [3:0] drain_reason_q, drain_reason_d;
    assign quiesce_o = drain_pending_q | switch_q;

    // N1c bounded drain (T10f). A pending drain that makes no commit
    // progress for SmtDrainForceCycles cycles is forced: the top level
    // flushes the resident hart's uncommitted state like a commit flush,
    // the hart's bank entry is rewound to the oldest uncommitted PC
    // (head_pc_i, latched into drain_force_pc_q so the killed head —
    // a WFI included — re-executes on the next activation), and
    // drain_ready_i then rises so the handoff completes. A WFI at the
    // resident head forces immediately (the hart wants to sleep and the
    // peer must run). The counter only counts cycles with no resident
    // commit; any commit means drain progress and resets it. The force is
    // issued only while drain_killable_i guarantees no uncancellable side
    // effect (mid-atomic AMO/LR-SC, LSU commit handshake, pending store)
    // is in flight, and never while drain_ready_i.
    localparam int unsigned DF_MAX = G6LCCfg.SmtDrainForceCycles;
    localparam int unsigned DF_W   = (DF_MAX <= 1) ? 1 : $clog2(DF_MAX + 1);
    // T10f: absolute bound derived from the relative one (16 no-commit
    // windows). DF_MAX == 0 disables both legs via DRAIN_FORCE_EN.
    localparam int unsigned DF_ABS_MAX = 16 * DF_MAX;
    localparam int unsigned DF_ABS_W   = (DF_ABS_MAX <= 1) ? 1 : $clog2(DF_ABS_MAX + 1);
    localparam bit DRAIN_FORCE_EN  =
        G6LCCfg.SmtDrainedHandoff && (DF_MAX != 0);
    logic [DF_W-1:0]   drain_force_cnt_q, drain_force_cnt_d;
    logic [DF_ABS_W-1:0] drain_abs_cnt_q, drain_abs_cnt_d;
    logic              drain_forced_q, drain_forced_d;
    // At most one force pulse per pending drain: the pulse already starts
    // the resident flush, so a pulse-cycle resolution race that retires
    // drain_forced_q early must not let the force re-arm.
    logic              drain_issued_q, drain_issued_d;
    logic [G6LCCfg.VLEN-1:0] drain_force_pc_q;
    // The force pulse is registered: drain_force_o feeds the controller's
    // flush legs, and flush_id closes a path into drain_ready_i. Sampling
    // the decision keeps drain_ready_i out of the force cone — there is no
    // same-cycle path from the flush back into drain_force_d.
    logic              drain_force, drain_force_q, drain_force_wfi_q;
    logic              drain_force_abs_q;
`else
    assign quiesce_o = 1'b0;
    logic _unused_drain;
    assign _unused_drain = commit_i | drain_killable_i | head_wfi_i |
                           head_plain_i | (|head_pc_i) | drain_ready_i;
`endif

    always_comb begin
      for (int unsigned h = 0; h < NH; h++) begin
        miss_or_block[h] = hart_dmiss_i[h] | hart_imiss_i[h] | hart_block_i[h];
      end
    end

    assign active_stalled = miss_or_block[active_q] | ~hart_ready_i[active_q];

    // RR scan: any ready peer, clean peer, starved peer
    // hyp8 r3: serial RR scan -> per-candidate compare vectors +
    // first-set one-hot + masked-OR gather; starve pick is a pairwise
    // strict-'>' tournament (earlier scan index wins ties, as the
    // sequential argmax did). `rr_ptr_q + k` wraps with one conditional
    // subtract (k < NH, rr_ptr_q < NH) instead of a billed `% NH`.
    logic [NH-1:0]    ts_elig, ts_clean, ts_unpa, ts_stve;
    logic [HID_W-1:0] ts_cand[NH];
    logic [NH-1:0]    fs_peer, fs_clean, fs_unpa;
    for (genvar gk = 0; gk < NH; gk++) begin : gen_ts_scan
      assign ts_cand[gk] = (int'(rr_ptr_q) + gk >= NH)
                             ? HID_W'(int'(rr_ptr_q) + gk - NH)
                             : HID_W'(int'(rr_ptr_q) + gk);
      assign ts_elig[gk]  = (ts_cand[gk] != active_q) && hart_ready_i[ts_cand[gk]];
      assign ts_clean[gk] = ts_elig[gk] && !miss_or_block[ts_cand[gk]];
      assign ts_unpa[gk]  = ts_elig[gk] && PAUSE_EN && !pause_req_q[ts_cand[gk]];
      assign ts_stve[gk]  = (HID_W'(gk) != active_q) && hart_ready_i[gk] &&
                            (ST_MAX != 0) &&
                            (starve_q[gk] >= ST_MAX[ST_W-1:0]);
      if (gk == 0) begin : gen_fs0
        assign fs_peer[gk]  = ts_elig[gk];
        assign fs_clean[gk] = ts_clean[gk];
        assign fs_unpa[gk]  = ts_unpa[gk];
      end else begin : gen_fsn
        assign fs_peer[gk]  = ts_elig[gk]  && !(|ts_elig[gk-1:0]);
        assign fs_clean[gk] = ts_clean[gk] && !(|ts_clean[gk-1:0]);
        assign fs_unpa[gk]  = ts_unpa[gk]  && !(|ts_unpa[gk-1:0]);
      end
    end
    assign found_peer     = |ts_elig;
    assign found_clean    = |ts_clean;
    assign found_unpaused = |ts_unpa;
    assign found_starve   = |ts_stve;

    always_comb begin : p_peer_gather
      peer_any      = '0;
      peer_clean    = '0;
      peer_unpaused = '0;
      for (int unsigned k = 0; k < NH; k++) begin
        peer_any      |= ts_cand[k] & {HID_W{fs_peer[k]}};
        peer_clean    |= ts_cand[k] & {HID_W{fs_clean[k]}};
        peer_unpaused |= ts_cand[k] & {HID_W{fs_unpa[k]}};
      end
      if (!found_peer)     peer_any      = active_q;
      if (!found_clean)    peer_clean    = active_q;
      if (!found_unpaused) peer_unpaused = active_q;
    end

    // pairwise strict-'>' argmax over the eligible starve counters
    localparam int unsigned TSL = (NH <= 1) ? 1 : $clog2(NH);
    logic [HID_W-1:0] am_idx [TSL+1][NH];
    logic [ST_W-1:0]  am_val [TSL+1][NH];
    logic             am_vld [TSL+1][NH];
    for (genvar l = 0; l <= TSL; l++) begin : gen_am
      for (genvar t = 0; t < NH; t++) begin : gen_amt
        if (l == 0) begin : gen_leaf
          assign am_idx[l][t] = HID_W'(t);
          assign am_val[l][t] = starve_q[t];
          assign am_vld[l][t] = ts_stve[t];
        end else if (t < ((NH + (1 << l) - 1) >> l)) begin : gen_node
          if (2 * t + 1 < ((NH + (1 << (l - 1)) - 1) >> (l - 1))) begin : gen_pair
            assign am_vld[l][t] = am_vld[l-1][2*t] || am_vld[l-1][2*t+1];
            assign am_idx[l][t] = (am_vld[l-1][2*t+1] &&
                    (!am_vld[l-1][2*t] || (am_val[l-1][2*t+1] > am_val[l-1][2*t])))
                                  ? am_idx[l-1][2*t+1] : am_idx[l-1][2*t];
            assign am_val[l][t] = (am_vld[l-1][2*t+1] &&
                    (!am_vld[l-1][2*t] || (am_val[l-1][2*t+1] > am_val[l-1][2*t])))
                                  ? am_val[l-1][2*t+1] : am_val[l-1][2*t];
          end else begin : gen_odd
            assign am_vld[l][t] = am_vld[l-1][2*t];
            assign am_idx[l][t] = am_idx[l-1][2*t];
            assign am_val[l][t] = am_val[l-1][2*t];
          end
        end else begin : gen_pad
          assign am_vld[l][t] = 1'b0;
          assign am_idx[l][t] = '0;
          assign am_val[l][t] = '0;
        end
      end
    end
    assign peer_starve = am_vld[TSL][0] ? am_idx[TSL][0] : active_q;

    // Cycle-bound quantum: a resident hart whose fetch rate is too low to
    // reach SmtFetchQuantum (spin loops) still yields once it has stayed
    // resident for CycQuantum cycles. Constant-0 when CycQuantum == 0.
    assign cyc_hit = (CycQuantum != 0) &&
                     (cyc_q >= CQ_W'(CycQuantum - 1));

    // hyp8 r3: the single composed next-state writer billed as one dense
    // cone. Split into the raw policy select, the ordered gate chain
    // (uniss -> t0 -> trap_hold -> drain -> hold), and independent
    // per-field next-state assigns. Decision order and all side effects
    // are source-order identical.
    logic          do_pol, rm_pol, rq_pol, rs_pol, ry_pol;
    logic          do_g1,  rm_g1,  rq_g1,  rs_g1,  ry_g1;
    logic [HID_W-1:0] nxt_pol;

    always_comb begin : p_policy
      do_pol  = 1'b0;
      rm_pol  = 1'b0;
      rq_pol  = 1'b0;
      rs_pol  = 1'b0;
      ry_pol  = 1'b0;
      nxt_pol = peer_any;
      unique case (POLICY)
        SMT_SWITCH_ON_MISS: begin
          if (active_stalled && found_clean &&
              (activate_age_q >= MISS_SWITCH_BLACKOUT) &&
              (stall_age_q >= MISS_STALL_THRESH)) begin
            do_pol   = 1'b1;
            rm_pol = 1'b1;
            nxt_pol   = peer_clean;
          end else if (!hart_ready_i[active_q] && found_peer) begin
            do_pol   = 1'b1;
            rm_pol = 1'b1;
            nxt_pol   = peer_any;
          end
        end
        SMT_RR: begin
          if (((fetch_fire_i && (quantum_q >= Q_W'(Q_MAX - 1))) || cyc_hit) &&
              found_peer) begin
            do_pol      = 1'b1;
            rq_pol = 1'b1;
            nxt_pol      = peer_any;
          end else if (!hart_ready_i[active_q] && found_peer) begin
            do_pol      = 1'b1;
            rq_pol = 1'b1;
            nxt_pol      = peer_any;
          end
        end
        default: begin  // SMT_HYBRID
          if (active_stalled && found_clean &&
              (activate_age_q >= MISS_SWITCH_BLACKOUT) &&
              (stall_age_q >= MISS_STALL_THRESH)) begin
            do_pol   = 1'b1;
            rm_pol = 1'b1;
            nxt_pol   = peer_clean;
          end else if (found_starve &&
                       (unissued_age_q == 8'd0 || unissued_age_q == 8'hff)) begin
            do_pol     = 1'b1;
            rs_pol = 1'b1;
            nxt_pol     = peer_starve;
            // Ranked below anti-starvation so a yield can never deny the service
            // floor, and requiring an UNPAUSED peer so two yielding harts fall
            // through to the normal policy instead of ping-ponging.
          end else if (PAUSE_EN && pause_req_q[active_q] && found_unpaused) begin
            do_pol    = 1'b1;
            ry_pol = 1'b1;
            nxt_pol    = peer_unpaused;
          end else if (((fetch_fire_i &&
                         (quantum_q >= Q_W'(Q_MAX - 1))) || cyc_hit) &&
                       found_peer) begin
            do_pol      = 1'b1;
            rq_pol = 1'b1;
            nxt_pol      = peer_any;
          end else if (!hart_ready_i[active_q] && found_peer) begin
            do_pol   = 1'b1;
            rm_pol = 1'b1;
            nxt_pol   = peer_any;
          end
        end
      endcase
    end

    always_comb begin : p_gate
      // I4bc: delay only when IQ has a head and ID is empty (tail sitting
      // in IQ). Do not wait on fetch_valid alone (I4bb) or I$ present (I4bd).
      // uniss_pend bounds the wait at SMT_UNISS_WAIT. It must accumulate across
      // the sparse do_pol (fetch_fire) re-assertions and brief iqv/idu flicker:
      // the old form reset the counter every !do_pol cycle so the bound never
      // fired and the quantum switch starved the peer (mc_smt_sibling_both_present,
      // hart1 resident=0). Once a do_pol-blocked episode starts the count is held
      // until the switch resolves, flush, or hold -- the head-state term only
      // gates whether a *new* delay is granted, never whether the bound is kept.
      uniss_pend_d = '0;
      do_g1 = do_pol; rm_g1 = rm_pol; rq_g1 = rq_pol; rs_g1 = rs_pol;
      ry_g1 = ry_pol;
      if (do_pol && iq_valid_i && !id_uniss_i && !hold_i) begin
        if (uniss_pend_q < SMT_UNISS_WAIT) begin
          do_g1        = 1'b0;
          rm_g1        = 1'b0;
          rq_g1        = 1'b0;
          rs_g1        = 1'b0;
          uniss_pend_d = uniss_pend_q + 6'd1;
        end else begin
          uniss_pend_d = SMT_UNISS_WAIT;
        end
      end else if (!flush_i && !hold_i && (uniss_pend_q != '0)) begin
        uniss_pend_d = uniss_pend_q;
      end

      // I4bg: after lui/addi t0, suppress *quantum/starve* only so one more
      // fetch can take the cave tail. Miss-switch still fires (I4bh
      // also-miss lost the nat cookie).
      // The deferral is one fetch, once: t0_imm_i re-arms t0_extra_q on every
      // `li t0` issue, and a resident loop that opens with one (OpenSBI
      // _wait_for_boot_hart: li t0,2 ... div x3 ... bne) has it set at every
      // fetch_fire, the only cycle the quantum predicate is evaluated. Unbounded,
      // the quantum switch was suppressed forever and the boot hart never ran
      // again (fw_payload: hart 0 frozen at 6333 retired from cycle ~32k).
      // t0_defer_q records the deferral already granted to this resident; a
      // switch taken with t0_extra_q set banks smt_t0_next (I4bi), as the
      // miss-switch always has.
      t0_defer_d = t0_defer_q;
`ifdef G6LC_MUT_SMT_T0_DEFER_UNBOUNDED
      // Leaf-bench mutation (tb_g6lc_thread_select_t0): the pre-fix gate.
      if (t0_extra_q && do_g1 && (rq_g1 || rs_g1)) begin
`else
      if (t0_extra_q && do_g1 && (rq_g1 || rs_g1) && !t0_defer_q) begin
`endif
        do_g1 = 1'b0;
        rq_g1 = 1'b0;
        rs_g1 = 1'b0;
        t0_defer_d = 1'b1;
      end
      if (t0_imm_i) t0_extra_d = 1'b1;
      else if (do_g1) t0_extra_d = 1'b0;
      else if (fetch_fire_i && t0_extra_q) t0_extra_d = 1'b0;
      else t0_extra_d = t0_extra_q;

      // I4br: do not switch while I4z is pinning fetch at mtvec. A switch
      // flush_unissued after trap_fetch lifts still drops jal@3d8 (I4bq).
      // Not flush_i (I4y hold-FAIL). trap_hold is exception fetch+tail only.
      if (trap_hold_i) begin
        do_g1 = 1'b0;
        rm_g1 = 1'b0;
        rq_g1 = 1'b0;
        rs_g1 = 1'b0;
        ry_g1 = 1'b0;
      end
    end

`ifdef G6LC_FETCH_B
    always_comb begin : p_drain
      drain_pending_d = drain_pending_q;
      drain_peer_d    = drain_peer_q;
      drain_reason_d  = drain_reason_q;
      next_peer       = nxt_pol;
      do_switch       = do_g1;
      reason_miss     = rm_g1;
      reason_quantum  = rq_g1;
      reason_starve   = rs_g1;
      reason_yield    = ry_g1;
      if (drain_pending_q) begin
        next_peer = drain_peer_q;
        do_switch = drain_ready_i && hart_ready_i[drain_peer_q] &&
                    !hold_i && !trap_hold_i && !flush_i;
        reason_miss = do_switch && drain_reason_q[2];
        reason_quantum = do_switch && drain_reason_q[1];
        reason_starve = do_switch && drain_reason_q[0];
        reason_yield = do_switch && drain_reason_q[3];
        if (do_switch || !hart_ready_i[drain_peer_q]) drain_pending_d = 1'b0;
      end else begin
        if (do_switch && !hold_i && !flush_i) begin
          drain_pending_d = 1'b1;
          drain_peer_d = next_peer;
          drain_reason_d = {reason_yield, reason_miss, reason_quantum, reason_starve};
        end
        do_switch = 1'b0;
        reason_miss = 1'b0;
        reason_quantum = 1'b0;
        reason_starve = 1'b0;
        reason_yield = 1'b0;
      end

      // N1c bounded drain force. WFI is an immediate request once no commit
      // is in flight (a committing WFI retires and the drain resolves on its
      // own); otherwise the no-commit counter must reach DF_MAX, and the
      // absolute bound backstops a sustained masked-commit stream. One force
      // per drain: while
      // drain_forced_q is armed no further request is issued — a re-fired
      // force would keep flush_ctrl_id high and drain_ready_i could never
      // rise (the formal boundedness proof catches that livelock otherwise).
`ifdef G6LC_MUT_DRAIN_NOFORCE
      // Review/formal mutation: the bounded-drain force is dropped so the
      // drain regresses to the unbounded pre-N1c behaviour. The review leaf
      // times out waiting for drain_force_o and the SymbiYosys boundedness
      // property must fail.
      drain_force = 1'b0;
`else
      drain_force = DRAIN_FORCE_EN && drain_pending_q && !drain_ready_i &&
          drain_killable_i && !drain_forced_q && !drain_issued_q &&
          ((!commit_i && head_wfi_i) ||
           (!commit_i && (drain_force_cnt_q == DF_W'(DF_MAX)) &&
            head_plain_i) ||
           ((drain_abs_cnt_q == DF_ABS_W'(DF_ABS_MAX)) && head_plain_i));
`endif
      drain_force_cnt_d = drain_force_cnt_q;
      if (!drain_pending_q || drain_ready_i || commit_i || drain_force)
        drain_force_cnt_d = '0;
      else if (drain_force_cnt_q != DF_W'(DF_MAX))
        drain_force_cnt_d = drain_force_cnt_q + 1'b1;
      // T10f: absolute bound. Counts every pending && !ready cycle — a commit
      // does NOT reset it, so an unbounded stream of masked-commit cycles
      // (phys_pending/phys_mod/cancelled heads) can no longer starve the
      // relative leg forever.
      drain_abs_cnt_d = drain_abs_cnt_q;
      if (!drain_pending_q || drain_ready_i || drain_force)
        drain_abs_cnt_d = '0;
      else if (drain_abs_cnt_q != DF_ABS_W'(DF_ABS_MAX))
        drain_abs_cnt_d = drain_abs_cnt_q + 1'b1;
      // Forced state must survive the do_switch cycle into the switch_q pulse
      // (the outgoing bank reads npc_alt at switch_i) and die with the switch
      // or with the drain itself. drain_force_q is the registered pulse; the
      // npc_alt window is anchored on the decision so a flush that resolves
      // the drain in one cycle cannot outrun it. If the drain resolves
      // naturally in the pulse cycle itself (drain_ready_i rises or a commit
      // lands while the force is in flight), the head-PC snapshot is stale —
      // drop the forced state so the bank takes the normal retire/NPC path
      // instead of rewinding to a PC that has since committed or drained.
      drain_forced_d = (drain_forced_q || drain_force) && drain_pending_q &&
                       !switch_q &&
                       !(drain_force_q && (drain_ready_i || commit_i));
      // Once a pulse has been issued it is spent for this drain — the flush
      // it starts still completes even when the forced bookkeeping above was
      // dropped by the commit/ready race, and re-firing under a sustained
      // commit stream would re-pulse flush_ctrl_id forever without ever
      // letting drain_ready_i rise.
      drain_issued_d = (drain_issued_q || drain_force) && drain_pending_q &&
                       !switch_q;

      // Hold wins over policy: no switch.
      if (hold_i) begin
        do_switch      = 1'b0;
        reason_miss    = 1'b0;
        reason_quantum = 1'b0;
        reason_starve  = 1'b0;
        reason_yield   = 1'b0;
      end
    end
`else
    always_comb begin : p_sel
      next_peer      = nxt_pol;
      do_switch      = do_g1;
      reason_miss    = rm_g1;
      reason_quantum = rq_g1;
      reason_starve  = rs_g1;
      reason_yield   = ry_g1;
      if (hold_i) begin
        do_switch      = 1'b0;
        reason_miss    = 1'b0;
        reason_quantum = 1'b0;
        reason_starve  = 1'b0;
        reason_yield   = 1'b0;
      end
    end
`endif

    // per-field next-state — independent cones; hold > do_switch > free-run,
    // quantum additionally cleared by flush (all map to '0, so one select).
    assign pause_req_d = PAUSE_EN ? (pause_req_q | pause_hint_i) : '0;
    assign active_d    = do_switch ? next_peer : active_q;
    assign rr_ptr_d    = do_switch
                           ? ((int'(next_peer) + 1 >= NH)
                                ? HID_W'(int'(next_peer) + 1 - NH)
                                : HID_W'(int'(next_peer) + 1))
                           : rr_ptr_q;
    // quantum additionally cleared by hold/do_switch. flush_i is deliberately
    // NOT a reset: the frontend flushes on routine self-inflicted events
    // (FENCE/FENCE.I/SFENCE/HFENCE/CBO and branch mispredicts) that have nothing
    // to do with SMT fairness. Counting them as quantum resets made Q_MAX
    // unreachable in fence/mispredict-dense code -- the resident hart never
    // yielded and the ready SMT sibling starved (mc_all_harts_present: hart0's
    // per-pass `fence` held quantum_q<=~29 << 4096 -> do_pol never fired ->
    // hart1 resident=0). During the flush fetch_fire_i is low so the count
    // simply holds; it resumes on the next fetch grant. Only a genuine
    // handoff/hold boundary (do_switch, hold_i) earns a fresh quantum.
    assign quantum_d   = (hold_i || do_switch) ? '0
                       : !fetch_fire_i ? quantum_q
                       : (quantum_q >= Q_W'(Q_MAX - 1)) ? Q_W'(Q_MAX)
                                                        : quantum_q + 1'b1;
    // Resident-cycle counter for the cycle-bounded quantum: counts every
    // cycle the current hart stays resident (fetch or not) and saturates at
    // CycQuantum. Cleared only on a real handoff/hold boundary; flush_i does
    // not reset it, the same rule quantum_q follows (see the comment above).
    assign cyc_d       = (hold_i || do_switch) ? '0
                       : (cyc_q >= CQ_W'(CycQuantum)) ? CQ_W'(CycQuantum)
                                                    : cyc_q + 1'b1;
    assign activate_age_d = hold_i    ? activate_age_q
                          : do_switch ? '0
                          : (activate_age_q == 5'h1F) ? 5'h1F
                                                      : activate_age_q + 5'd1;
    assign stall_age_d = hold_i        ? stall_age_q
                       : do_switch     ? '0
                       : !active_stalled ? '0
                       : (stall_age_q == 8'hff) ? stall_age_q
                                                : stall_age_q + 8'd1;
    for (genvar gh = 0; gh < NH; gh++) begin : gen_starve_ns
      assign starve_d[gh] = hold_i    ? starve_q[gh]
                          : do_switch ? '0
                          : (HID_W'(gh) == active_q) ? '0
                          : (hart_ready_i[gh] && (ST_MAX != 0) &&
                             (starve_q[gh] < ST_MAX[ST_W-1:0]))
                              ? starve_q[gh] + 1'b1
                          : starve_q[gh];
    end

    // Delayed switch pulse: fires when active_q already equals the incoming hart.
    logic t0_bank_q;
    logic reason_miss_q, reason_quantum_q, reason_starve_q;

    // unissued_age_q: cycles since activation without an issue (0 = issued).
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) unissued_age_q <= 8'd1;
      else if (do_switch) unissued_age_q <= 8'd1;
      else if (issue_fire_i) unissued_age_q <= 8'd0;
      else if (hold_i) unissued_age_q <= unissued_age_q;
      else if (unissued_age_q != 8'd0 && unissued_age_q != 8'hff) unissued_age_q <= unissued_age_q + 8'd1;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
`ifdef G6LC_FETCH_B
        drain_pending_q <= 1'b0;
        drain_peer_q <= '0;
        drain_reason_q <= '0;
        drain_force_cnt_q <= '0;
        drain_abs_cnt_q <= '0;
        drain_forced_q <= 1'b0;
        drain_issued_q <= 1'b0;
        drain_force_pc_q <= '0;
        drain_force_q <= 1'b0;
        drain_force_wfi_q <= 1'b0;
        drain_force_abs_q <= 1'b0;
`endif
        active_q         <= '0;
        pause_req_q      <= '0;
        rr_ptr_q         <= HID_W'(1 % NH);  // prefer hart 1 as first alternate
        quantum_q        <= '0;
        cyc_q            <= '0;
        activate_age_q   <= '0;
        stall_age_q      <= '0;
        uniss_pend_q     <= '0;
        t0_extra_q       <= 1'b0;
        t0_defer_q       <= 1'b0;
        t0_bank_q        <= 1'b0;
        switch_q         <= 1'b0;
        reason_miss_q    <= 1'b0;
        reason_quantum_q <= 1'b0;
        reason_starve_q  <= 1'b0;
        for (int unsigned h = 0; h < NH; h++) starve_q[h] <= '0;
      end else begin
`ifdef G6LC_FETCH_B
        drain_pending_q <= drain_pending_d;
        drain_peer_q <= drain_peer_d;
        drain_reason_q <= drain_reason_d;
        drain_force_cnt_q <= drain_force_cnt_d;
        drain_abs_cnt_q <= drain_abs_cnt_d;
        drain_forced_q <= drain_forced_d;
        drain_issued_q <= drain_issued_d;
        drain_force_q <= drain_force;
        drain_force_wfi_q <= drain_force && head_wfi_i;
        // abs attribution is exclusive: a force whose WFI or relative leg
        // was also armed counts as that leg, not the absolute bound.
        drain_force_abs_q <= drain_force && head_plain_i && !head_wfi_i &&
                             (drain_abs_cnt_q == DF_ABS_W'(DF_ABS_MAX)) &&
                             (commit_i ||
                              (drain_force_cnt_q != DF_W'(DF_MAX)));
        if (drain_force) drain_force_pc_q <= head_pc_i;
`endif
        active_q         <= active_d;
        // Clear only on an activation TRANSITION: the hint is raised while the
        // hart is still active, so clearing every active cycle would erase it in
        // the same cycle it was set and the yield would never happen.
        pause_req_q <= !PAUSE_EN ? '0 :
            (active_d != active_q) ? (pause_req_d & ~(NH'(1) << active_d)) : pause_req_d;
        rr_ptr_q         <= rr_ptr_d;
        quantum_q        <= quantum_d;
        cyc_q            <= cyc_d;
        activate_age_q   <= activate_age_d;
        stall_age_q      <= stall_age_d;
        // Reset the unissued-head wait on an actual switch so the next resident
        // hart gets a fresh SMT_UNISS_WAIT grace instead of inheriting a
        // saturated count that would disable the I4bc delay entirely.
        uniss_pend_q     <= do_switch ? '0 : uniss_pend_d;
        t0_extra_q       <= t0_extra_d;
        t0_defer_q       <= (do_switch || hold_i) ? 1'b0 : t0_defer_d;
        t0_bank_q        <= do_switch & t0_extra_q;
        switch_q         <= do_switch;
        reason_miss_q    <= do_switch & reason_miss;
        reason_quantum_q <= do_switch & reason_quantum;
        reason_starve_q  <= do_switch & reason_starve;
        for (int unsigned h = 0; h < NH; h++) starve_q[h] <= starve_d[h];
      end
    end

    assign active_hart_o       = active_q;
    assign switch_o            = switch_q;
    assign t0_extra_o          = t0_bank_q;
    assign switch_on_miss_o    = reason_miss_q;
    assign switch_on_quantum_o = reason_quantum_q;
    assign switch_on_starve_o  = reason_starve_q;
`ifdef G6LC_FETCH_B
    assign drain_force_o       = drain_force_q;
    assign drain_force_wfi_o   = drain_force_wfi_q;
    assign drain_force_abs_o   = drain_force_abs_q;
    assign drain_forced_o      = drain_forced_q;
    assign drain_force_pc_o    = drain_force_pc_q;
`else
    assign drain_force_o       = 1'b0;
    assign drain_force_wfi_o   = 1'b0;
    assign drain_force_abs_o   = 1'b0;
    assign drain_forced_o      = 1'b0;
    assign drain_force_pc_o    = '0;
`endif

    //pragma translate_off
`ifdef G6LC_FETCH_B
    // Quantum/switch decision probe (+smt_quant_probe, windowed by
    // +smt_quant_lo/hi). Captures the decision chain smt_sched does NOT expose
    // -- do_pol/do_g1/do_switch, rq_* reason bits, quantum_q, fetch_fire_i,
    // found_peer, uniss_pend_q -- to isolate why an SMT_RR quantum switch never
    // requests a drain while a ready peer waits. `do_switch` is consumed into
    // drain_pending_d inside p_drain (cleared to 0 in the FETCH_B else leg), so
    // the intermediate do_pol/do_g1/rq_* nets carry the pre-consumption truth.
    bit smt_quant_probe;
    int unsigned smt_quant_cycle;
    int unsigned smt_quant_ff, smt_quant_dp;
    int unsigned smt_quant_lo, smt_quant_hi;
    initial begin
      smt_quant_probe = $test$plusargs("smt_quant_probe");
      smt_quant_lo = 0;
      smt_quant_hi = 32'hFFFF_FFFF;
      void'($value$plusargs("smt_quant_lo=%0d", smt_quant_lo));
      void'($value$plusargs("smt_quant_hi=%0d", smt_quant_hi));
      smt_quant_cycle = 0; smt_quant_ff = 0; smt_quant_dp = 0;
    end
    always @(posedge clk_i) begin
      if (!rst_ni) begin
        smt_quant_cycle <= 0; smt_quant_ff <= 0; smt_quant_dp <= 0;
      end else if (smt_quant_probe) begin
        smt_quant_cycle <= smt_quant_cycle + 1;
        if (smt_quant_cycle >= smt_quant_lo && smt_quant_cycle <= smt_quant_hi) begin
          if (fetch_fire_i) smt_quant_ff <= smt_quant_ff + 1;
          // Event A: raw SMT_RR quantum predicate asserted (do_pol+r_q) but the
          // gated decision did not reach a drain request -> a suppressor ate it.
          if (do_pol && rq_pol) begin
            $display("[smt-quant] POL cyc=%0d act=%0d q=%0d ff=%b fp=%b cmt=%b iss=%b g1=%b rq1=%b ready=%b iqv=%b idu=%b uniss=%0d t0x=%b trap=%b fl=%b hold=%b dp=%0d",
                     smt_quant_cycle, active_q, quantum_q, fetch_fire_i, found_peer,
                     commit_i, issue_fire_i, do_g1, rq_g1, hart_ready_i, iq_valid_i,
                     id_uniss_i, uniss_pend_q, t0_extra_q, trap_hold_i, flush_i,
                     hold_i, drain_pending_q);
          end
          // Event B: gated decision survived to a drain request.
          if (drain_pending_d && !drain_pending_q) begin
            smt_quant_dp <= smt_quant_dp + 1;
            $display("[smt-quant] DP cyc=%0d act=%0d peer=%0d reason=%b q=%0d",
                     smt_quant_cycle, active_q, drain_peer_d, drain_reason_d, quantum_q);
          end
          // Periodic snapshot (every 1024 cyc): quantum trajectory + fire rates.
          if ((smt_quant_cycle & 12'h3FF) == 12'h000)
            $display("[smt-quant] SM cyc=%0d act=%0d q=%0d pol=%b/%b g1=%b/%b sw=%b rq=%b ff=%b fp=%b cmt=%b iss=%b ready=%b iqv=%b idu=%b uniss=%0d dp=%0d swq=%0d ffN=%0d dpN=%0d",
                     smt_quant_cycle, active_q, quantum_q, do_pol, rq_pol, do_g1, rq_g1,
                     do_switch, reason_quantum, fetch_fire_i, found_peer, commit_i,
                     issue_fire_i, hart_ready_i, iq_valid_i, id_uniss_i, uniss_pend_q,
                     drain_pending_q, switch_q, smt_quant_ff, smt_quant_dp);
        end
      end
    end
`endif
    //pragma translate_on

    //pragma translate_off
`ifdef G6LC_FETCH_B
    // Read-only service/handoff observer. `state` is edge-compressed: it prints
    // only when a reported field changes, so the reader reconstructs intervals.
    // The cycle counter must match smt_flow_cycle in scoreboard.sv (increment
    // first, then print) or the reported cycles cannot be correlated.
    // T20b: `+smt_sched_lo=N +smt_sched_hi=M` window the observer (default:
    // the whole run, as before) and every line carries `inst=%m` so the
    // per-core selectors of a multi-core harness can be told apart.
    localparam int unsigned SMT_SCHED_W = HID_W + 4 * NH + 4;
    bit smt_sched_trace;
    int unsigned smt_sched_cycle;
    int unsigned smt_sched_decide;
    int unsigned smt_sched_lo, smt_sched_hi;
    bit smt_sched_seen;
    logic smt_sched_on;
    logic [SMT_SCHED_W-1:0] smt_sched_shadow, smt_sched_now;
    initial begin
      smt_sched_trace = $test$plusargs("smt_sched_trace");
      smt_sched_lo = 0;
      smt_sched_hi = 32'hFFFF_FFFF;
      void'($value$plusargs("smt_sched_lo=%0d", smt_sched_lo));
      void'($value$plusargs("smt_sched_hi=%0d", smt_sched_hi));
    end
    assign smt_sched_on = smt_sched_trace && smt_sched_cycle >= smt_sched_lo &&
                          smt_sched_cycle <= smt_sched_hi;
    always @(posedge clk_i) begin
      if (!rst_ni) begin
        smt_sched_cycle  = 0;
        smt_sched_decide = 0;
        smt_sched_seen   = 1'b0;
        smt_sched_shadow = '0;
      end else if (smt_sched_trace) begin
        smt_sched_cycle = smt_sched_cycle + 1;
        smt_sched_now = {active_q, hart_ready_i, hart_dmiss_i, hart_imiss_i, hart_block_i,
                         quiesce_o, hold_i, trap_hold_i, flush_i};
        if (smt_sched_on && (!smt_sched_seen || (smt_sched_now !== smt_sched_shadow))) begin
          $display("[smt-sched] state cycle=%0d active=%0d ready=%b dmiss=%b imiss=%b block=%b quiesce=%b hold=%b trap=%b flush=%b drain_pend=%0d forced=%0d inst=%m",
                   smt_sched_cycle, active_q, hart_ready_i, hart_dmiss_i, hart_imiss_i,
                   hart_block_i, quiesce_o, hold_i, trap_hold_i, flush_i, drain_pending_q,
                   drain_forced_o);
          smt_sched_seen   = 1'b1;
          smt_sched_shadow = smt_sched_now;
        end
        if (!smt_sched_on) smt_sched_seen = 1'b0;
        // A drain cannot be requested while one is pending, so decide and its
        // completion never coincide and the reader can pair them one to one.
        if (drain_pending_d && !drain_pending_q) begin
          smt_sched_decide = smt_sched_cycle;
          if (smt_sched_on)
            $display("[smt-sched] decide cycle=%0d from=%0d to=%0d reason=%b inst=%m",
                     smt_sched_cycle, active_q, drain_peer_d, drain_reason_d);
        end else if (drain_pending_q && !drain_pending_d) begin
          // Cleared either by the real switch or because the target peer stopped
          // being ready; the second case is an abort, not a handoff.
          if (smt_sched_on) begin
            if (do_switch)
              $display("[smt-sched] switch cycle=%0d from=%0d to=%0d reason=%b waited=%0d forced=%0d head_pc=%h inst=%m",
                       smt_sched_cycle, active_q, drain_peer_q, drain_reason_q,
                       smt_sched_cycle - smt_sched_decide, drain_forced_o, head_pc_i);
            else
              $display("[smt-sched] abort cycle=%0d from=%0d to=%0d reason=%b waited=%0d inst=%m",
                       smt_sched_cycle, active_q, drain_peer_q, drain_reason_q,
                       smt_sched_cycle - smt_sched_decide);
          end
        end
        if (smt_sched_on && drain_force_o)
          $display("[smt-sched] force cycle=%0d active=%0d wfi=%0d abs=%0d head_pc=%h inst=%m",
                   smt_sched_cycle, active_q, drain_force_wfi_o, drain_force_abs_o, head_pc_i);
      end
    end
`endif
    //pragma translate_on

  end

endmodule
