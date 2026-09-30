// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: N1c bounded drain for g6lc_thread_select (drained handoff).
//
// Contract under proof, against a small model of the drain interface:
//   P1  the force is never requested while the drain is already ready
//       (drain_force_o |-> !$past(drain_ready_i)); the pulse is registered
//       one cycle after the decision, so the sampled-ready form is the
//       provable contract.
//   P1b a force that lands while the drain has just resolved (drain_ready_i
//       rose or a commit arrived in the pulse cycle) drops the forced state
//       before the bank can sample a stale head-PC snapshot.
//   P2  a pending drain hands off within SmtDrainForceCycles + K cycles,
//       where K is the modelled flush latency: the environment never commits
//       the resident hart, keeps the head killable and plain-or-WFI, keeps
//       the peer ready, and raises drain_ready_i at most K cycles after a
//       force.
//   Cover witnesses: a timer force, a WFI force, and a full drain->switch.
//   Negative control: +define+G6LC_MUT_DRAIN_NOFORCE drops the force in the
//   DUT, so the bounded property must FAIL (P2 is load-bearing).
//
// The caller-side legality contract (head killable, commit tracked) is
// assumed exactly as cva6.sv drives drain_killable_i/head_plain_i; the
// wait-for-killable behaviour is exercised by the review leaf instead.
//
// Run: sby -f core/smt/formal/g6lc_thread_select.sby

module g6lc_thread_select_props #(
    parameter int unsigned NH    = 2,
    parameter int unsigned FORCE = 8,
    parameter int unsigned K     = 2
) (
    input logic clk_i,
    input logic rst_ni,
    // free environment variables
    input logic fetch_fire_i,
    input logic natural_ready_i,
    input logic head_wfi_i
);
`ifdef FORMAL
  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.NrHarts = NH;
    c.SmtPolicy = config_pkg::SMT_RR;
    c.SmtFetchQuantum = 2;
    c.SmtStarveLimit = 0;
    c.SmtDrainedHandoff = 1'b1;
    c.SmtDrainForceCycles = FORCE;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C = mk_cfg();
  localparam int unsigned HW = (NH > 1) ? $clog2(NH) : 1;
  localparam int unsigned BOUND = FORCE + K + 4;

  // Start in reset so the unconstrained register initial state is forced
  // to the reset state (same pattern as the other formal models).
  logic f_past_valid = 1'b0;
  always @(posedge clk_i) f_past_valid <= 1'b1;
  always @(posedge clk_i) assume (f_past_valid || !rst_ni);

  // ---- drain interface model ------------------------------------------
  // Worst case for the bound: the resident hart never commits (the ring-32
  // wedge), the head is always plain-or-WFI and the in-flight state is
  // always killable. The peer is always ready, no hold/trap/flush. The
  // natural drain readiness is free; the forced path models the
  // force->flush->sb_empty latency: drain_ready_i rises K cycles after a
  // force at the latest (and may rise earlier via natural_ready_i).
  logic commit_i;
  logic drain_killable_i;
  logic head_plain_i;
  logic drain_ready_i;
  logic force_seen_q;
  logic [$clog2(K+2)-1:0] force_age_q;

  assign commit_i         = 1'b0;
  assign drain_killable_i = 1'b1;
  assign head_plain_i     = 1'b1;

  logic drain_force_o, drain_force_wfi_o, drain_forced_o, switch_o, quiesce_o;
  logic [63:0] drain_force_pc_o;
  logic [HW-1:0] active_hart_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      force_seen_q <= 1'b0;
      force_age_q  <= '0;
    end else if (drain_force_o) begin
      force_seen_q <= 1'b1;
      force_age_q  <= '0;
    end else if (force_seen_q) begin
      if (force_age_q == K[$clog2(K+2)-1:0]) force_seen_q <= 1'b0;
      else force_age_q <= force_age_q + 1'b1;
    end
  end
  assign drain_ready_i = natural_ready_i |
                         (force_seen_q && (force_age_q == K[$clog2(K+2)-1:0]));

  g6lc_thread_select #(.CVA6Cfg(C)) dut (
      .clk_i,
      .rst_ni,
      .fetch_fire_i,
      .issue_fire_i        (1'b0),
      .flush_i             (1'b0),
      .hold_i              (1'b0),
      .drain_ready_i       (drain_ready_i),
      .commit_i            (commit_i),
      .drain_killable_i    (drain_killable_i),
      .head_wfi_i          (head_wfi_i),
      .head_plain_i        (head_plain_i),
      .head_pc_i           (64'h8000_0100),
      .drain_force_o       (drain_force_o),
      .drain_force_wfi_o   (drain_force_wfi_o),
      .drain_forced_o      (drain_forced_o),
      .drain_force_pc_o    (drain_force_pc_o),
      .quiesce_o           (quiesce_o),
      .id_uniss_i          (1'b0),
      .iq_valid_i          (1'b0),
      .t0_imm_i            (1'b0),
      .trap_hold_i         (1'b0),
      .hart_ready_i        ({NH{1'b1}}),
      .hart_dmiss_i        ('0),
      .hart_imiss_i        ('0),
      .hart_block_i        ('0),
      .active_hart_o       (active_hart_o),
      .switch_o            (switch_o),
      .t0_extra_o          (),
      .switch_on_miss_o    (),
      .switch_on_quantum_o (),
      .switch_on_starve_o  (),
      .pause_hint_i        ('0)
  );

  // ---- properties ------------------------------------------------------
  // P1: the force is never requested while the drain is already ready — the
  // decision samples !drain_ready_i and the pulse follows one cycle later.
  // P1b: the natural-resolution race (ready rose, or a commit landed, in the
  // pulse cycle) drops drain_forced_o so the bank never sees a stale
  // head-PC snapshot. P2 bookkeeping uses pending/forced age counters:
  // "hands off within the bound" <=> the age never overflows.
  localparam int unsigned AW = $clog2(BOUND + 2);
  localparam int unsigned FW = $clog2(K + 6);
  logic [AW-1:0] pend_age_q;
  logic [FW-1:0] forced_age_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_age_q        <= '0;
      forced_age_q      <= '0;
    end else begin
      if (!dut.gen_smt.drain_pending_q || switch_o)
        pend_age_q <= '0;
      else if (pend_age_q != AW'(BOUND + 1))
        pend_age_q <= pend_age_q + 1'b1;

      if (!drain_forced_o || switch_o)
        forced_age_q <= '0;
      else if (forced_age_q != FW'(K + 5))
        forced_age_q <= forced_age_q + 1'b1;

    end
  end

  always @(posedge clk_i) begin
    if (f_past_valid && rst_ni) begin
      // P1: the force pulse never follows a ready decision cycle.
      assert (!(drain_force_o && $past(drain_ready_i)));

      // P1b: pulse-cycle resolution drops forced before the bank samples.
      if ($past(drain_force_o && (drain_ready_i || commit_i)))
        assert (!drain_forced_o);

      // P2: a pending drain hands off within FORCE + K (+ pipeline slack).
      assert (pend_age_q <= AW'(BOUND));

      // Forced bookkeeping: forced never outlives the K-bounded flush plus
      // the do_switch/switch_q pipeline.
      assert (forced_age_q <= FW'(K + 4));

      // WFI flag consistency: asserted only alongside a force, and equal to
      // the head_wfi_i sampled at the decision cycle.
      assert (!(drain_force_wfi_o && !drain_force_o));
      if (drain_force_o)
        assert (drain_force_wfi_o == $past(head_wfi_i));
    end
  end

  // ---- witnesses -------------------------------------------------------
`ifdef FORMAL_COVER
  always @(posedge clk_i) begin
    if (f_past_valid && rst_ni) begin
      cover (drain_force_o && !drain_force_wfi_o);   // timer force
      cover (drain_force_wfi_o);                     // WFI force
      cover (switch_o);                              // full drain -> switch
      cover (drain_forced_o && switch_o);            // forced handoff
    end
  end
`endif
`endif
endmodule
