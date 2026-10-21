// hyp8 provenance: REWRITTEN (banked pick + reservation mask, group 4/5)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Free list of physical registers, banked pick form (analysis/g6lc_rename.md
// A136, analysis/cut_minimization.md row "g6lc_rename").
//
// Hyp8 structure:
//   - One shared bitmap free_q (bit i set => phys reg i free) plus a
//     reservation mask rsv_q: a bit picked by an in-flight rename group (R1)
//     stays free in free_q but is excluded from later picks until the group
//     publishes (commit consumes it) or is killed (release drops only the
//     reservation). This is the "reserved by in-flight group" mask so R1
//     never picks a register a killed group may return -- a killed pick
//     returns exactly once, through the release port.
//   - BANKS pick banks: lane p picks from bank (p mod BANKS) = the lowest
//     set index i of (free & ~rsv) with i % BANKS == p % BANKS. The pick is
//     combinational off registered state and is captured by the caller's
//     stage register; the reservation is set in the same edge.
//   - Lowest-set is computed as the prefix-OR isolate (av & (~av + 1)), the
//     log-depth A136 form; the one-hot is then OR-encoded per output bit.
//   - Free writes and recovery writes index the shared bitmap directly.
//   - Registered available count drives empty_o/stall usage by the caller.
//
// Hyp8 departures from the unbanked cell:
//   - Index 0 is never picked (x0's phys tag stays permanently free);
//     the upstream rename bit-vector could hand out phys 0.
//   - empty_o/cnt are registered one cycle after the last bitmap change
//     (conservative stall source: count only moves with registered state).

module g6lc_freelist #(
    parameter int unsigned PRF_ENTRIES = 48,
    parameter int unsigned PRF_W       = 6,
    parameter int unsigned NR_LANES    = 1,   // pick lanes; lane p -> bank p%BANKS
    parameter int unsigned NR_FREE     = 1,   // commit free ports
    parameter int unsigned BANKS       = 1    // HypCfg.FreelistBanks
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // R1 pick request; pick_o is comb off registered state, captured by the
    // caller's register; pick_avail_o says bank(lane) had a candidate.
    input  logic [NR_LANES-1:0]            pick_req_i,
    output logic [NR_LANES-1:0][PRF_W-1:0] pick_o,
    output logic [NR_LANES-1:0]            pick_avail_o,
    // Publish commit: the lane's picked register becomes allocated.
    input  logic [NR_LANES-1:0]            commit_i,
    input  logic [NR_LANES-1:0][PRF_W-1:0] commit_prd_i,
    // Killed in-flight group: drop only the reservation (exactly once --
    // callers pulse release_i once per killed pick).
    input  logic [NR_LANES-1:0]            release_i,
    input  logic [NR_LANES-1:0][PRF_W-1:0] release_prd_i,
    // Commit free writes (by index).
    input  logic [NR_FREE-1:0]             free_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0]  free_prd_i,
    // Mispredict repair: OR squashed registers back into the bitmap.
    input  logic                           repair_i,
    input  logic [PRF_ENTRIES-1:0]         repair_mask_i,
    // Flush / amap rebuild: overwrite the whole bitmap and drop every
    // reservation (all in-flight groups are dead by definition).
    input  logic                           restore_i,
    input  logic [PRF_ENTRIES-1:0]         restore_mask_i,
    // Registered available count (free & ~rsv) for capacity checks.
    output logic [31:0]                    avail_cnt_o,
    output logic                           empty_o
);

  logic [PRF_ENTRIES-1:0] free_q, free_d;
  logic [PRF_ENTRIES-1:0] rsv_q, rsv_d;
  logic [PRF_ENTRIES-1:0] avail;

  // Bit 0 is never pickable (kept "free" for the x0-by-convention tag but
  // masked out of every bank's candidate set).
  assign avail = free_q & ~rsv_q & {{PRF_ENTRIES-1{1'b1}}, 1'b0};

  // ----------------------------------------------------------------------
  // Picks: lane p's bank is p % BANKS; lanes sharing a bank take successive
  // lowest-set bits (with NP=2, BANKS=2 each bank serves one lane).
  // ----------------------------------------------------------------------
  logic [PRF_ENTRIES-1:0] bank_taken;
  // Each lane's candidate mask is a bank filter of `avail`, with earlier
  // lanes of the same bank removed. Lowest-set is av & (~av+1), the same
  // pick the procedural scan produced (first free, program order of lanes).
  // The rename valid bit is |one-hot: a lane with no free register does
  // not hand out an index.
  logic [NR_LANES-1:0][PRF_ENTRIES-1:0] lane_av, lane_oh;
  for (genvar p = 0; p < NR_LANES; p++) begin : gen_lane_av
    for (genvar i = 0; i < PRF_ENTRIES; i++) begin : gen_bit
      if ((i % BANKS) == (p % BANKS))
        assign lane_av[p][i] = avail[i];
      else
        assign lane_av[p][i] = 1'b0;
    end
  end
  for (genvar p = 0; p < NR_LANES; p++) begin : gen_lane_oh
    logic [PRF_ENTRIES-1:0] excl, pool;
    always_comb begin
      excl = '0;
      for (int unsigned q = 0; q < NR_LANES; q++)
        if ((q < p) && ((q % BANKS) == (p % BANKS))) excl |= lane_oh[q];
    end
    assign pool = lane_av[p] & ~excl;
    assign lane_oh[p] = pool & (~pool + {{PRF_ENTRIES-1{1'b0}}, 1'b1});
  end
  always_comb begin : pick_lanes
    pick_o = '0;
    pick_avail_o = '0;
    bank_taken = '0;
    for (int unsigned p = 0; p < NR_LANES; p++) begin
      pick_avail_o[p] = |lane_oh[p];
      for (int unsigned i = 0; i < PRF_ENTRIES; i++)
        if (lane_oh[p][i]) pick_o[p] = PRF_W'(i);
      bank_taken |= lane_oh[p];
    end
  end

  // ----------------------------------------------------------------------
  // Bitmap / reservation next state.
  // ----------------------------------------------------------------------
  always_comb begin : upd
    free_d = free_q;
    rsv_d = rsv_q;
    // commit frees
    for (int unsigned f = 0; f < NR_FREE; f++) begin
      if (free_i[f] && free_prd_i[f] != '0) free_d[free_prd_i[f]] = 1'b1;
    end
    // mispredict repair (squashed speculative allocations return)
    if (repair_i) free_d |= repair_mask_i;
    // picked registers become reserved this edge
    for (int unsigned p = 0; p < NR_LANES; p++) begin
      if (pick_req_i[p] && pick_avail_o[p]) rsv_d[pick_o[p]] = 1'b1;
    end
    // publish consumes the reservation and allocates the register
    for (int unsigned p = 0; p < NR_LANES; p++) begin
      if (commit_i[p]) begin
        free_d[commit_prd_i[p]] = 1'b0;
        rsv_d[commit_prd_i[p]] = 1'b0;
      end
    end
    // killed groups release their reservations only
    for (int unsigned p = 0; p < NR_LANES; p++) begin
      if (release_i[p]) rsv_d[release_prd_i[p]] = 1'b0;
    end
    // flush / amap rebuild overwrites everything and drops reservations
    if (restore_i) begin
      free_d = restore_mask_i;
      rsv_d = '0;
    end
    if (flush_i) begin
      // only the architectural registers stay allocated; phys 0 excluded
      free_d = '1;
      free_d[0] = 1'b0;
      rsv_d = '0;
    end
  end

  // Registered available count (popcount of free & ~rsv) drives empty/stall.
  logic [31:0] avail_cnt_d;
  g6lc_hyp_popcount #(
      .INPUT_WIDTH (PRF_ENTRIES)
  ) i_avail_cnt (
      .data_i    (avail),
      .popcount_o(avail_cnt_d[$clog2(PRF_ENTRIES):0])
  );

  logic [31:0] avail_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      free_q <= '1;
      free_q[0] <= 1'b0;
      rsv_q <= '0;
      avail_cnt_q <= '0;
    end else begin
      free_q <= free_d;
      rsv_q <= rsv_d;
      avail_cnt_q <= avail_cnt_d;
    end
  end

  assign avail_cnt_o = avail_cnt_q;
  assign empty_o = (avail_cnt_q == 32'd0);

  //pragma translate_off
  initial begin
    assert (NR_LANES > 0 && BANKS > 0 && BANKS <= PRF_ENTRIES);
  end
  //pragma translate_on

endmodule
