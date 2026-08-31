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
    input logic [63:0] npc
);

`ifdef FORMAL
  import g6lc_fetch_pkg::*;

  fetch_en_t   e;
  logic [7:0]  stamped;
  logic        cfh;
  logic [63:0] snapped;

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
