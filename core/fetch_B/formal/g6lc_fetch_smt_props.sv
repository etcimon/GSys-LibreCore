// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: the SMT-facing fetch contracts (I4/R1 packet provenance,
// I8 commit-hart filtering, I10 switch progress) over the pure functions of
// `g6lc_fetch_pkg`. Self-contained: no frontend elaboration.
//
// These three are the fetch-side of multi-threading, and each already has a
// recorded failure behind it (core-fetch/SPEC.md s4 and s5):
//   - packet_hart : a switch must not retag an in-flight packet as the incoming
//                   hart. R1 lets a parked hart legitimately run with sp == 0,
//                   so mislabelled provenance is indistinguishable from a hart
//                   that is simply not ready yet.
//   - commit_for_hart : TRACE t=200082 showed `src=4` (PC_COMMIT) reseeding
//                   fetch with hart0's target while h=1, stealing hart1's
//                   bootrom `jr s0`. An outgoing hart may still retire CSR/fence
//                   because a switch does not flush EX.
//   - snap_pc     : on a switch, bank the address the I$ actually accepted, not
//                   the fetch-ahead npc, or the restore loses a window.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_smt.sby
//      cva6-build verify --formal

module g6lc_fetch_smt_props (
    input logic        clk_i,
    input logic        rst_ni,
    // en.restore is the SMT const-fold: free here, so every property below is
    // proven for BOTH the T=1 and the T>1 envelope in one run rather than
    // needing a second package (I26 -- every envelope correct on its own).
    input logic        en_restore,
    input logic [7:0]  hart,
    input logic        en_smt,
    input logic        commit,
    input logic [7:0]  commit_hart,
    input logic [7:0]  active_hart,
    input logic        snap_en,
    input logic        inflight,
    input logic [63:0] inflight_addr,
    input logic [63:0] npc,
    input logic [3:0] port_count,
    input logic [7:0] decode_valid, queue_valid,
    input logic [7:0][7:0] decode_hart, queue_hart,
    input logic [7:0][63:0] decode_pc, queue_pc,
    input logic transport_valid, redirect_valid,
    input logic [7:0] redirect_hart,
    input logic [63:0] redirect_pc,
    input logic accept_take, accept_flush,
    input logic [63:0] accept_window
);

`ifdef FORMAL
  import g6lc_fetch_pkg::*;

  fetch_en_t   e;
  logic [7:0]  stamped;
  logic        cfh;
  logic [63:0] snapped;
  restart_t frontier, transport;
  logic decode_match, queue_match;
  logic active_redirect, bank_redirect;
  logic target_accepted;

  assign target_accepted = accepted_target(32'(port_count), accept_take, accept_flush,
      queue_valid, queue_pc, redirect_pc);

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      logic seen;
      seen = 1'b0;
      for (int p = 0; p < 8; p++) begin
        if (p < port_count && queue_valid[p] && queue_pc[p] == redirect_pc) seen = 1'b1;
      end
      assert (target_accepted == (accept_take && !accept_flush && seen));
      if (!accept_take || accept_flush) assert (!target_accepted);
      cover (target_accepted && queue_valid[0] && queue_pc[0] == redirect_pc &&
          redirect_pc[2:0] == 3'd6 && accept_window == ((redirect_pc & ~64'd7) + 64'd8));
      cover (target_accepted && !queue_valid[0] && port_count > 1);
      cover (seen && accept_flush && !target_accepted);
      cover (accept_take && !accept_flush && |queue_valid && !seen && !target_accepted);
    end
  end

  assign active_redirect = redirect_for_hart(en_smt, redirect_valid, redirect_hart, active_hart);
  assign bank_redirect = en_smt && redirect_valid && redirect_hart != active_hart;

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(active_redirect && bank_redirect));
      assert ((active_redirect || bank_redirect) == redirect_valid);
      if (en_smt && active_redirect) assert (redirect_hart == active_hart);
      if (!en_smt) assert (active_redirect == redirect_valid);
      cover (bank_redirect && !active_redirect);
      cover (en_smt && active_redirect);
    end
  end

  always_comb begin
    transport = '{valid: transport_valid, pc: npc};
    frontier = restart_frontier(32'(port_count), active_hart,
        decode_valid, decode_hart, decode_pc, queue_valid, queue_hart, queue_pc,
        transport, redirect_valid, redirect_hart, redirect_pc);
    decode_match = 1'b0;
    queue_match = 1'b0;
    for (int p = 0; p < 8; p++) begin
      if (p < port_count) begin
        decode_match |= decode_valid[p] && decode_hart[p] == active_hart;
        queue_match |= queue_valid[p] && queue_hart[p] == active_hart;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (port_count >= 1 && port_count <= 8);
      if (redirect_valid && redirect_hart == active_hart) begin
        assert (frontier.valid && frontier.pc == redirect_pc);
      end else begin
        logic found;
        found = 1'b0;
        for (int p = 0; p < 8; p++) begin
          if (!found && p < port_count && decode_valid[p] && decode_hart[p] == active_hart) begin
            assert (frontier.valid && frontier.pc == decode_pc[p]);
            found = 1'b1;
          end
        end
        for (int p = 0; p < 8; p++) begin
          if (!found && p < port_count && queue_valid[p] && queue_hart[p] == active_hart) begin
            assert (frontier.valid && frontier.pc == queue_pc[p]);
            found = 1'b1;
          end
        end
        if (!found) assert (frontier == transport);
      end
      cover (decode_match && queue_match && !redirect_valid);
      cover (!decode_match && queue_match && !redirect_valid);
      cover (redirect_valid && redirect_hart == active_hart && decode_match);
      cover (redirect_valid && redirect_hart != active_hart && queue_match);
      cover (decode_match && frontier.valid && frontier.pc == 0 && !redirect_valid);
      cover (!decode_match && !queue_match && !redirect_valid && !frontier.valid);
    end
  end

  always_comb begin
    e           = '0;
    e.restore   = en_restore;
    stamped     = packet_hart(e, hart);
    cfh         = commit_for_hart(en_smt, commit, commit_hart, active_hart);
    snapped     = snap_pc(snap_en, inflight, inflight_addr, npc);
  end

  // No reset assumption: this module is stateless. Every property below is a
  // combinational implication over free inputs, so there is no initial state
  // for a free-running reset to corrupt. (`initial assume` is also rejected by
  // the slang frontend -- reading a net during design initialization.)

  // --- I4 / R1: packet provenance ------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // T=1 stamps a constant 0: there is no second hart to attribute to, and
      // the field must not carry stale bits into decode.
      if (!en_restore) assert (stamped == 8'b0);
      // T>1 carries the FETCHING hart verbatim. Any transform here is a retag.
      if (en_restore) assert (stamped == hart);
      // Provenance is a pure function of the fold and the fetching hart: it can
      // never depend on which hart happens to be active at decode.
      assert (stamped == (en_restore ? hart : 8'b0));
    end
  end

  // --- I8: PC_COMMIT reseeds fetch only for the active hart ----------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Single-thread: the filter is inert, never suppressing a real commit.
      if (!en_smt) assert (cfh == commit);
      // Under SMT a reseed requires BOTH a commit and a hart match.
      if (cfh) assert (commit);
      if (en_smt && cfh) assert (commit_hart == active_hart);
      // The recorded failure, stated directly: an outgoing hart retiring while
      // a different hart is active must NOT steal the fetch redirect.
      if (en_smt && commit && commit_hart != active_hart) assert (!cfh);
      // No commit, no reseed -- in either envelope.
      if (!commit) assert (!cfh);
    end
  end

  // --- I10: a thread switch loses no progress ------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // With a request in flight, bank the address the I$ accepted. npc has
      // already stepped a window ahead, so banking it drops that window.
      if (snap_en && inflight) assert (snapped == inflight_addr);
      // Nothing in flight (or the fold is off): the running npc is correct.
      if (!snap_en || !inflight) assert (snapped == npc);
      // The snapshot is always one of the two candidates; it never invents.
      assert (snapped == inflight_addr || snapped == npc);
    end
  end

  // --- reachability --------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (en_restore && stamped != 8'b0);
      cover (en_smt && commit && !cfh);
      cover (snap_en && inflight && inflight_addr != npc);
    end
  end
`endif

endmodule
