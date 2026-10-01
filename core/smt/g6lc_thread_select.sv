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
    input  logic drain_ready_i,
    // N1c bounded drain (drained handoff only; inert when
    // CVA6Cfg.SmtDrainForceCycles == 0).
    input  logic commit_i,          // any commit-stage ack this cycle
    input  logic drain_killable_i,  // resident in-flight state is cancellable
    input  logic head_wfi_i,        // resident commit head is a WFI
    input  logic head_plain_i,      // resident commit head is a plain op
    input  logic [CVA6Cfg.VLEN-1:0] head_pc_i,   // oldest uncommitted PC
    output logic drain_force_o,     // pulse: flush the resident hart now
    output logic drain_force_wfi_o, // drain_force_o && head was WFI
    output logic drain_force_abs_o, // drain_force_o from the absolute bound
    output logic drain_forced_o,    // a force is outstanding until switch_o
    output logic [CVA6Cfg.VLEN-1:0] drain_force_pc_o,
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
    input  logic [CVA6Cfg.NrHarts-1:0] hart_ready_i,
    input  logic [CVA6Cfg.NrHarts-1:0] hart_dmiss_i,
    input  logic [CVA6Cfg.NrHarts-1:0] hart_imiss_i,
    input  logic [CVA6Cfg.NrHarts-1:0] hart_block_i,
    output logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] active_hart_o,
    output logic switch_o,
    // I4bi: t0_extra was set on the do_switch cycle (valid with switch_o).
    output logic t0_extra_o,
    output logic switch_on_miss_o,
    // Zihintpause yield hint (one bit per hart). Advisory only: it can defer a
    // hart behind an unpaused peer, never gate readiness, and the anti-starvation
    // limit below still guarantees the hinting hart's forward service.
    input logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] pause_hint_i,
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
    logic [ST_W-1:0]  starve_q[NH];
    logic [ST_W-1:0]  starve_d[NH];
    // After activate, suppress miss-switch briefly so an I$ fill can complete.
    // Also require *sustained* stall (stall_age) before miss-switch: counting
    // only activate_age caused dual-ready thrash every ~8 cycles on I$ misses
    // (OpenSBI FDT/strchr never progressed on RTL while Spike was fine).
    logic [4:0] activate_age_q, activate_age_d;
    logic [7:0] stall_age_q, stall_age_d;
    logic [5:0] uniss_pend_q, uniss_pend_d;
    logic       t0_extra_q, t0_extra_d;
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
    localparam bit PAUSE_EN = (CVA6Cfg.ZihintpauseEn && NH > 1);
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
    localparam int unsigned DF_MAX = CVA6Cfg.SmtDrainForceCycles;
    localparam int unsigned DF_W   = (DF_MAX <= 1) ? 1 : $clog2(DF_MAX + 1);
    // T10f: absolute bound derived from the relative one (16 no-commit
    // windows). DF_MAX == 0 disables both legs via DRAIN_FORCE_EN.
    localparam int unsigned DF_ABS_MAX = 16 * DF_MAX;
    localparam int unsigned DF_ABS_W   = (DF_ABS_MAX <= 1) ? 1 : $clog2(DF_ABS_MAX + 1);
    localparam bit DRAIN_FORCE_EN  =
        CVA6Cfg.SmtDrainedHandoff && (DF_MAX != 0);
    logic [DF_W-1:0]   drain_force_cnt_q, drain_force_cnt_d;
    logic [DF_ABS_W-1:0] drain_abs_cnt_q, drain_abs_cnt_d;
    logic              drain_forced_q, drain_forced_d;
    // At most one force pulse per pending drain: the pulse already starts
    // the resident flush, so a pulse-cycle resolution race that retires
    // drain_forced_q early must not let the force re-arm.
    logic              drain_issued_q, drain_issued_d;
    logic [CVA6Cfg.VLEN-1:0] drain_force_pc_q;
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
    always_comb begin
      peer_any     = active_q;
      peer_clean   = active_q;
      peer_starve  = active_q;
      peer_unpaused = active_q;
      found_peer   = 1'b0;
      found_clean  = 1'b0;
      found_starve = 1'b0;
      found_unpaused = 1'b0;
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
          // A peer that has itself yielded is not a better place to send work.
          if (PAUSE_EN && !pause_req_q[cand] && !found_unpaused) begin
            peer_unpaused  = cand;
            found_unpaused = 1'b1;
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
`ifdef G6LC_FETCH_B
      drain_pending_d = drain_pending_q;
      drain_peer_d = drain_peer_q;
      drain_reason_d = drain_reason_q;
`endif
      active_d       = active_q;
      rr_ptr_d       = rr_ptr_q;
      quantum_d      = quantum_q;
      activate_age_d = (activate_age_q == 5'h1F) ? 5'h1F : (activate_age_q + 5'd1);
      // Sustained-stall counter for miss-switch (resets when active fetches).
      if (active_stalled) begin
        if (stall_age_q != 8'hff)
          stall_age_d = stall_age_q + 8'd1;
        else
          stall_age_d = stall_age_q;
      end else begin
        stall_age_d = '0;
      end
      do_switch      = 1'b0;
      reason_miss    = 1'b0;
      reason_quantum = 1'b0;
      reason_starve  = 1'b0;
      reason_yield   = 1'b0;
      // Latch a fresh hint; clear the active hart's own request once it has been
      // given the core again, so a hart is never held off by a stale yield.
      pause_req_d    = PAUSE_EN ? (pause_req_q | pause_hint_i) : '0;
      t0_extra_d     = t0_extra_q;
      next_peer      = peer_any;
      for (int unsigned h = 0; h < NH; h++) starve_d[h] = starve_q[h];

      unique case (POLICY)
        SMT_SWITCH_ON_MISS: begin
          if (active_stalled && found_clean &&
              (activate_age_q >= MISS_SWITCH_BLACKOUT) &&
              (stall_age_q >= MISS_STALL_THRESH)) begin
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
          if (fetch_fire_i && (quantum_q >= Q_W'(Q_MAX - 1)) && found_peer) begin
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
              (activate_age_q >= MISS_SWITCH_BLACKOUT) &&
              (stall_age_q >= MISS_STALL_THRESH)) begin
            do_switch   = 1'b1;
            reason_miss = 1'b1;
            next_peer   = peer_clean;
          end else if (found_starve) begin
            do_switch     = 1'b1;
            reason_starve = 1'b1;
            next_peer     = peer_starve;
            // Ranked below anti-starvation so a yield can never deny the service
            // floor, and requiring an UNPAUSED peer so two yielding harts fall
            // through to the normal policy instead of ping-ponging.
          end else if (PAUSE_EN && pause_req_q[active_q] && found_unpaused) begin
            do_switch    = 1'b1;
            reason_yield = 1'b1;
            next_peer    = peer_unpaused;
          end else if (fetch_fire_i &&
                       (quantum_q >= Q_W'(Q_MAX - 1)) && found_peer) begin
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

      // I4bc: delay only when IQ has a head and ID is empty (tail sitting
      // in IQ). Do not wait on fetch_valid alone (I4bb) or I$ present (I4bd).
      uniss_pend_d = '0;
      if (do_switch && iq_valid_i && !id_uniss_i &&
          (uniss_pend_q < SMT_UNISS_WAIT) && !hold_i) begin
        do_switch      = 1'b0;
        reason_miss    = 1'b0;
        reason_quantum = 1'b0;
        reason_starve  = 1'b0;
        uniss_pend_d   = uniss_pend_q + 6'd1;
      end

      // I4bg: after lui/addi t0, suppress *quantum/starve* only so one more
      // fetch can take the cave tail. Miss-switch still fires (I4bh
      // also-miss lost the nat cookie).
      if (t0_extra_q && do_switch && (reason_quantum || reason_starve)) begin
        do_switch      = 1'b0;
        reason_quantum = 1'b0;
        reason_starve  = 1'b0;
      end
      if (t0_imm_i) t0_extra_d = 1'b1;
      else if (do_switch) t0_extra_d = 1'b0;
      else if (fetch_fire_i && t0_extra_q) t0_extra_d = 1'b0;

      // I4br: do not switch while I4z is pinning fetch at mtvec. A switch
      // flush_unissued after trap_fetch lifts still drops jal@3d8 (I4bq).
      // Not flush_i (I4y hold-FAIL). trap_hold is exception fetch+tail only.
      if (trap_hold_i) begin
        do_switch      = 1'b0;
        reason_miss    = 1'b0;
        reason_quantum = 1'b0;
        reason_starve  = 1'b0;
        reason_yield   = 1'b0;
      end

`ifdef G6LC_FETCH_B
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
`endif
      // Hold wins over policy: no switch. Also *freeze* quantum/starve aging —
      // otherwise the parked primary's starve hits ST_MAX during peer bootrom
      // and, the cycle peer exits bootrom (hold drops), starve immediately
      // steals the pipeline back before peer_pass can run (concurrent dual-active fail).
      if (hold_i) begin
        do_switch      = 1'b0;
        reason_miss    = 1'b0;
        reason_quantum = 1'b0;
        reason_starve  = 1'b0;
        reason_yield   = 1'b0;
        // Zero quantum under hold so when hold drops the active hart always
        // receives a full fetch quantum (freeze-high caused immediate RR steal).
        quantum_d      = '0;
        activate_age_d = activate_age_q;
        stall_age_d    = stall_age_q;
        for (int unsigned h = 0; h < NH; h++) starve_d[h] = starve_q[h];
      end else if (do_switch) begin
        active_d            = next_peer;
        quantum_d           = '0;
        activate_age_d      = '0;
        stall_age_d         = '0;
        starve_d[next_peer] = '0;
        // Zero all starve counters on switch so the outgoing hart does not
        // re-win on starve the next cycle after a bootrom hold window.
        for (int unsigned h = 0; h < NH; h++) begin
          if (h[HID_W-1:0] != next_peer) starve_d[h] = '0;
        end
        rr_ptr_d            = HID_W'((int'(next_peer) + 1) % NH);
      end else begin
        if (fetch_fire_i) begin
          if (quantum_q >= Q_W'(Q_MAX - 1))
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
    logic t0_bank_q;
    logic reason_miss_q, reason_quantum_q, reason_starve_q;

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
        activate_age_q   <= '0;
        stall_age_q      <= '0;
        uniss_pend_q     <= '0;
        t0_extra_q       <= 1'b0;
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
        activate_age_q   <= activate_age_d;
        stall_age_q      <= stall_age_d;
        uniss_pend_q     <= uniss_pend_d;
        t0_extra_q       <= t0_extra_d;
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

    // issue_fire reserved for future issue-quantum policy
    logic _unused_issue;
    assign _unused_issue = issue_fire_i;

    //pragma translate_off
`ifdef G6LC_FETCH_B
    // Read-only service/handoff observer. `state` is edge-compressed: it prints
    // only when a reported field changes, so the reader reconstructs intervals.
    // The cycle counter must match smt_flow_cycle in scoreboard.sv (increment
    // first, then print) or the reported cycles cannot be correlated.
    localparam int unsigned SMT_SCHED_W = HID_W + 4 * NH + 4;
    bit smt_sched_trace;
    int unsigned smt_sched_cycle;
    int unsigned smt_sched_decide;
    bit smt_sched_seen;
    logic [SMT_SCHED_W-1:0] smt_sched_shadow, smt_sched_now;
    initial smt_sched_trace = $test$plusargs("smt_sched_trace");
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
        if (!smt_sched_seen || (smt_sched_now !== smt_sched_shadow)) begin
          $display("[smt-sched] state cycle=%0d active=%0d ready=%b dmiss=%b imiss=%b block=%b quiesce=%b hold=%b trap=%b flush=%b",
                   smt_sched_cycle, active_q, hart_ready_i, hart_dmiss_i, hart_imiss_i,
                   hart_block_i, quiesce_o, hold_i, trap_hold_i, flush_i);
          smt_sched_seen   = 1'b1;
          smt_sched_shadow = smt_sched_now;
        end
        // A drain cannot be requested while one is pending, so decide and its
        // completion never coincide and the reader can pair them one to one.
        if (drain_pending_d && !drain_pending_q) begin
          smt_sched_decide = smt_sched_cycle;
          $display("[smt-sched] decide cycle=%0d from=%0d to=%0d reason=%b",
                   smt_sched_cycle, active_q, drain_peer_d, drain_reason_d);
        end else if (drain_pending_q && !drain_pending_d) begin
          // Cleared either by the real switch or because the target peer stopped
          // being ready; the second case is an abort, not a handoff.
          if (do_switch)
            $display("[smt-sched] switch cycle=%0d from=%0d to=%0d reason=%b waited=%0d",
                     smt_sched_cycle, active_q, drain_peer_q, drain_reason_q,
                     smt_sched_cycle - smt_sched_decide);
          else
            $display("[smt-sched] abort cycle=%0d from=%0d to=%0d reason=%b waited=%0d",
                     smt_sched_cycle, active_q, drain_peer_q, drain_reason_q,
                     smt_sched_cycle - smt_sched_decide);
        end
      end
    end
`endif
    //pragma translate_on

  end

endmodule
