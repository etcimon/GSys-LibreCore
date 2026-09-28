// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// T9b/M1b posted-write and bypass-read trackers for g6lc_l2_top.
//
// g6lc_l2_wtrk — write tracker. Every accepted write (posted and blocking
// alike) allocates one entry in slave-AW accept order, so memory B responses
// route uniformly: a B for downstream id X is absorbed by the oldest live
// entry with downstream id X that has not yet received its B (per-id B
// ordering is an AXI guarantee). Entries whose B has arrived are presented
// on the slave B channel oldest-first — carrying the recorded *slave* id —
// and popped on the slave handshake. Each entry therefore carries two ids:
// the slave-side id (`push_id_i`, returned on slave B and probed by the
// ATOP-load guard) and the downstream id (`push_dsid_i`, the id the write
// was forwarded on — the parent's reserved WR_ID for a posted write, the
// original id for a blocking one).
//
//   Ordering enforced by the parent FSM, not here:
//     R1  a cacheable read miss to a line with any live entry holds.
//     R2  AW acceptance requires a free slot and — when an entry for the
//         same line exists — the same *downstream* id, so same-id B order
//         alone routes same-line write completions. Posted writes all share
//         WR_ID, so posted-vs-posted never holds; only a posted write
//         meeting a blocking entry (or vice versa) still waits.
//
// g6lc_l2_rdtrk — bypass-read tracker. A forwarded non-FILL_ID bypass AR
// leaves an {id} entry; memory R beats are routed to the oldest entry with
// the matching id and the entry pops on the burst's last beat (AXI delivers
// bursts contiguously and per-id in order). R5: slave-side responses with a
// live entry's id hold until that entry pops.
//
// Ordering inside each tracker is an age matrix: older_q[i][j] means entry i
// was allocated before entry j — exact under out-of-order pops, which a
// plain position FIFO cannot express. DEPTH ≤ 8 keeps the matrix ≤ 64 bits.
//
// Timing note (contract): the hazard CAMs are DEPTH-entry (≤8) compares on
// registered request fields; the oldest-select adds one AND-reduce level.
// Neither the trackers nor the R arbiter sit on the S_TAG hit compare path.

module g6lc_l2_wtrk #(
    parameter int unsigned DEPTH          = 4,
    parameter int unsigned ID_WIDTH       = 4,
    parameter int unsigned ADDR_WIDTH     = 64,
    parameter int unsigned AXI_USER_WIDTH = 1
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    // Allocation on slave AW accept. push_id_i is the slave id (returned on
    // the slave B channel); push_dsid_i is the downstream id the write is
    // forwarded on (reserved WR_ID for posted writes, original id for
    // blocking ones) — memory B routing and the R2 admission compare use it.
    input  logic                        push_i,
    input  logic [ID_WIDTH-1:0]         push_id_i,
    input  logic [ID_WIDTH-1:0]         push_dsid_i,
    input  logic [ADDR_WIDTH-1:0]       push_line_i,
    input  logic                        push_blocking_i,
    // Entry's write carries an ATOP R response (atop[5]); the read tracker
    // must not take a same-id entry while such a write is live.
    input  logic                        push_need_r_i,
    // Write-update attribution (T9c/M1c): the parent pulses this once the
    // write-update decision of the entry at mark_idx_i resolves as a hit, so
    // an R1 hold against a live entry can be split write-around vs
    // write-update-hit (line0_wu_o).
    input  logic                        mark_i,
    input  logic [$clog2(DEPTH)-1:0]    mark_idx_i,
    output logic                        full_o,
    output logic [$clog2(DEPTH)-1:0]    alloc_idx_o,
    // Memory B channel: absorb a B into the oldest matching unserved entry
    // (matched on the downstream id).
    input  logic                        m_b_valid_i,
    input  logic [ID_WIDTH-1:0]         m_b_id_i,
    input  logic [1:0]                  m_b_resp_i,
    input  logic [AXI_USER_WIDTH-1:0]   m_b_user_i,
    output logic                        m_b_match_o,
    // Slave B channel: oldest entry with a pending B; pop on handshake.
    output logic                        s_b_valid_o,
    output logic [ID_WIDTH-1:0]         s_b_id_o,
    output logic [1:0]                  s_b_resp_o,
    output logic [AXI_USER_WIDTH-1:0]   s_b_user_o,
    output logic                        s_b_blocking_o,
    input  logic                        s_b_ready_i,
    output logic                        pop_o,
    output logic [$clog2(DEPTH)-1:0]    pop_idx_o,
    // Line hazard probes (registered request fields compared in the
    // parent): probe 0 is the R1 in-flight-request line, probe 1 the R2
    // AW-admission line (whose matching entry's downstream id is also
    // reported for the same-downstream-id admission rule).
    input  logic [ADDR_WIDTH-1:0]       line0_i,
    output logic                        line0_match_o,
    // Any line0-matching entry was marked write-update-hit (vs write-around).
    output logic                        line0_wu_o,
    input  logic [ADDR_WIDTH-1:0]       line1_i,
    output logic                        line1_match_o,
    output logic [ID_WIDTH-1:0]         line1_match_id_o,
    // ATOP-load guard: a live entry carrying an ATOP R with this id.
    input  logic [ID_WIDTH-1:0]         need_r_id_i,
    output logic                        need_r_id_match_o,
    output logic                        empty_o
);

  localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  logic [DEPTH-1:0]        valid_q, valid_d;
  logic [ID_WIDTH-1:0]     ent_id_q    [DEPTH];
  logic [ID_WIDTH-1:0]     ent_dsid_q  [DEPTH];
  logic [ADDR_WIDTH-1:0]   ent_line_q  [DEPTH];
  logic [DEPTH-1:0]        ent_block_q, ent_block_d;
  logic [DEPTH-1:0]        ent_needs_q, ent_needs_d;
  logic [DEPTH-1:0]        ent_wu_q,    ent_wu_d;
  logic [DEPTH-1:0]        b_pend_q,    b_pend_d;
  logic [1:0]              b_resp_q    [DEPTH];
  logic [AXI_USER_WIDTH-1:0] b_user_q  [DEPTH];
  // older_q[i][j] == 1: entry i was allocated before entry j.
  logic [DEPTH-1:0]        older_q [DEPTH], older_d [DEPTH];

  // --------------------
  // Allocation: first invalid slot keeps indices stable across out-of-order
  // pops; the age matrix records issue order.
  // --------------------
  logic [DEPTH-1:0] free_v;
  logic [IDX_W-1:0] free_idx;
  always_comb begin
    for (int unsigned e = 0; e < DEPTH; e++) free_v[e] = ~valid_q[e];
    free_idx = '0;
    for (int unsigned e = DEPTH; e > 0; e--)
      if (free_v[e-1]) free_idx = IDX_W'(e-1);
  end
  assign full_o      = ~(|free_v);
  assign empty_o     = ~(|valid_q);
  assign alloc_idx_o = free_idx;

  // Oldest select: pick the set-bit with no set-bit older than it.
  function automatic logic [DEPTH-1:0] oldest(
      input logic [DEPTH-1:0] match,
      input logic [DEPTH-1:0] older_col [DEPTH]  // read as matrix (row per j)
  );
    logic [DEPTH-1:0] res;
    for (int unsigned e = 0; e < DEPTH; e++) begin
      logic any_older;
      any_older = 1'b0;
      for (int unsigned j = 0; j < DEPTH; j++)
        any_older |= match[j] & older_col[j][e];
      res[e] = match[e] & ~any_older;
    end
    return res;
  endfunction

  // --------------------
  // Memory B: oldest entry with matching downstream id that still waits
  // for its B.
  // --------------------
  logic [DEPTH-1:0] m_match, m_sel;
  logic [IDX_W-1:0] m_sel_idx;
  always_comb begin
    for (int unsigned e = 0; e < DEPTH; e++)
      m_match[e] = valid_q[e] && !b_pend_q[e] && (ent_dsid_q[e] == m_b_id_i);
    m_sel = oldest(m_match, older_q);
    m_sel_idx = '0;
    for (int unsigned e = 0; e < DEPTH; e++)
      if (m_sel[e]) m_sel_idx = IDX_W'(e);
  end
  assign m_b_match_o = |m_match;

  // --------------------
  // Slave B: oldest entry whose B has arrived.
  // --------------------
  logic [DEPTH-1:0] p_match, p_sel;
  logic [IDX_W-1:0] p_sel_idx;
  always_comb begin
    for (int unsigned e = 0; e < DEPTH; e++)
      p_match[e] = valid_q[e] && b_pend_q[e];
    p_sel = oldest(p_match, older_q);
    p_sel_idx = '0;
    for (int unsigned e = 0; e < DEPTH; e++)
      if (p_sel[e]) p_sel_idx = IDX_W'(e);
  end
  assign s_b_valid_o = |p_match;
  assign s_b_id_o    = ent_id_q[p_sel_idx];
  assign s_b_resp_o  = b_resp_q[p_sel_idx];
  assign s_b_user_o  = b_user_q[p_sel_idx];
  assign s_b_blocking_o = ent_block_q[p_sel_idx];
  assign pop_o       = s_b_valid_o && s_b_ready_i;
  assign pop_idx_o   = p_sel_idx;

  // --------------------
  // Hazard probes
  // --------------------
  logic [DEPTH-1:0] l0_match, l1_match;
  logic [IDX_W-1:0] l1_match_idx;
  always_comb begin
    for (int unsigned e = 0; e < DEPTH; e++) begin
      l0_match[e] = valid_q[e] && (ent_line_q[e] == line0_i);
      l1_match[e] = valid_q[e] && (ent_line_q[e] == line1_i);
    end
    l1_match_idx = '0;
    for (int unsigned e = 0; e < DEPTH; e++)
      if (l1_match[e]) l1_match_idx = IDX_W'(e);
  end
  function automatic logic [DEPTH-1:0] match_by_id(
      input logic [ID_WIDTH-1:0] ids [DEPTH],
      input logic [ID_WIDTH-1:0]     id
  );
    logic [DEPTH-1:0] m;
    for (int unsigned e = 0; e < DEPTH; e++) m[e] = (ids[e] == id);
    return m;
  endfunction

  assign line0_match_o     = |l0_match;
  assign line0_wu_o        = |(l0_match & ent_wu_q);
  assign line1_match_o     = |l1_match;
  assign line1_match_id_o  = ent_dsid_q[l1_match_idx];
  assign need_r_id_match_o = |(valid_q & ent_needs_q &
                               match_by_id(ent_id_q, need_r_id_i));

  // --------------------
  // State
  // --------------------
  always_comb begin
    valid_d     = valid_q;
    ent_block_d = ent_block_q;
    ent_needs_d = ent_needs_q;
    ent_wu_d    = ent_wu_q;
    b_pend_d    = b_pend_q;
    for (int unsigned e = 0; e < DEPTH; e++) begin
      older_d[e] = older_q[e];
    end

    // Absorb a memory B into the oldest matching unserved entry.
    if (m_b_valid_i && m_b_match_o) begin
      b_pend_d[m_sel_idx] = 1'b1;
    end

    if (mark_i) begin
      ent_wu_d[mark_idx_i] = 1'b1;
    end

    if (push_i) begin
      valid_d[free_idx]     = 1'b1;
      ent_block_d[free_idx] = push_blocking_i;
      ent_needs_d[free_idx] = push_need_r_i;
      ent_wu_d[free_idx]    = 1'b0;
      for (int unsigned e = 0; e < DEPTH; e++) begin
        older_d[e][free_idx] = valid_q[e];   // every live entry is older
        older_d[free_idx][e] = 1'b0;          // new entry is newest
      end
    end

    if (pop_o) begin
      valid_d[p_sel_idx]  = 1'b0;
      b_pend_d[p_sel_idx] = 1'b0;
      for (int unsigned e = 0; e < DEPTH; e++) begin
        older_d[p_sel_idx][e] = 1'b0;
        older_d[e][p_sel_idx] = 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q     <= '0;
      ent_block_q <= '0;
      ent_needs_q <= '0;
      ent_wu_q    <= '0;
      b_pend_q    <= '0;
      for (int unsigned e = 0; e < DEPTH; e++) begin
        ent_id_q[e]   <= '0;
        ent_dsid_q[e] <= '0;
        ent_line_q[e] <= '0;
        b_resp_q[e]   <= '0;
        b_user_q[e]   <= '0;
        older_q[e]    <= '0;
      end
    end else begin
      valid_q     <= valid_d;
      ent_block_q <= ent_block_d;
      ent_needs_q <= ent_needs_d;
      ent_wu_q    <= ent_wu_d;
      b_pend_q    <= b_pend_d;
      if (push_i) begin
        ent_id_q[free_idx]   <= push_id_i;
        ent_dsid_q[free_idx] <= push_dsid_i;
        ent_line_q[free_idx] <= push_line_i;
      end
      if (m_b_valid_i && m_b_match_o) begin
        b_resp_q[m_sel_idx] <= m_b_resp_i;
        b_user_q[m_sel_idx] <= m_b_user_i;
      end
      for (int unsigned e = 0; e < DEPTH; e++) begin
        older_q[e] <= older_d[e];
      end
    end
  end

  // A B with no tracker entry is a protocol violation: every write allocates
  // and Bs are only ever routed here. Fail fast in simulation.
  //pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni && m_b_valid_i && !m_b_match_o)
      $error("%m: memory B id=%0h with no live write-tracker entry", m_b_id_i);
  end
  //pragma translate_on

endmodule


// ==========================================================================
// Bypass-read tracker — {valid, id} entries in forward order. The parent FSM
// returns to S_IDLE after the memory AR handshake; R beats are routed here
// by the parent's slave-R arbiter and the entry pops on the last beat.
// ==========================================================================
module g6lc_l2_rdtrk #(
    parameter int unsigned DEPTH    = 4,
    parameter int unsigned ID_WIDTH = 4,
    parameter int unsigned NPROBE   = 4
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    input  logic                      push_i,
    input  logic [ID_WIDTH-1:0]       push_id_i,
    output logic                      full_o,
    // Head-beat routing: oldest live entry matching the memory R beat id.
    input  logic [ID_WIDTH-1:0]       r_id_i,
    output logic                      head_match_o,
    // Pop on the forwarded last beat.
    input  logic                      pop_i,
    // R5 hold probes: each probe id reports whether a live entry carries
    // it (hit-serve, fill-serve, waiter and AW-guard checks in the parent).
    input  logic [NPROBE-1:0][ID_WIDTH-1:0] probe_id_i,
    output logic [NPROBE-1:0]               probe_match_o,
    output logic                          empty_o
);

  localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  logic [DEPTH-1:0]      valid_q, valid_d;
  logic [ID_WIDTH-1:0]   ent_id_q [DEPTH];
  logic [DEPTH-1:0]      older_q [DEPTH], older_d [DEPTH];

  logic [DEPTH-1:0] free_v;
  logic [IDX_W-1:0] free_idx;
  always_comb begin
    for (int unsigned e = 0; e < DEPTH; e++) free_v[e] = ~valid_q[e];
    free_idx = '0;
    for (int unsigned e = DEPTH; e > 0; e--)
      if (free_v[e-1]) free_idx = IDX_W'(e-1);
  end
  assign full_o  = ~(|free_v);
  assign empty_o = ~(|valid_q);

  // Oldest matching entry wins the head beat (per-id order delivers the
  // oldest burst's beats first; bursts never interleave on one channel).
  logic [DEPTH-1:0] h_match, h_sel;
  logic [IDX_W-1:0] h_idx;
  always_comb begin
    for (int unsigned e = 0; e < DEPTH; e++)
      h_match[e] = valid_q[e] && (ent_id_q[e] == r_id_i);
    for (int unsigned e = 0; e < DEPTH; e++) begin
      logic any_older;
      any_older = 1'b0;
      for (int unsigned j = 0; j < DEPTH; j++)
        any_older |= h_match[j] & older_q[j][e];
      h_sel[e] = h_match[e] & ~any_older;
    end
    h_idx = '0;
    for (int unsigned e = 0; e < DEPTH; e++)
      if (h_sel[e]) h_idx = IDX_W'(e);
  end
  assign head_match_o = |h_match;

  // R5 hold probes: each bit of probe_match_o reports a live entry
  // carrying the corresponding probe id.
  logic [NPROBE-1:0] p_match;
  always_comb begin
    for (int unsigned p = 0; p < NPROBE; p++) begin
      p_match[p] = 1'b0;
      for (int unsigned e = 0; e < DEPTH; e++)
        p_match[p] |= valid_q[e] && (ent_id_q[e] == probe_id_i[p]);
    end
  end
  assign probe_match_o = p_match;

  always_comb begin
    valid_d = valid_q;
    for (int unsigned e = 0; e < DEPTH; e++) older_d[e] = older_q[e];
    if (push_i) begin
      valid_d[free_idx] = 1'b1;
      for (int unsigned e = 0; e < DEPTH; e++) begin
        older_d[e][free_idx] = valid_q[e];
        older_d[free_idx][e] = 1'b0;
      end
    end
    if (pop_i) begin
      valid_d[h_idx] = 1'b0;
      for (int unsigned e = 0; e < DEPTH; e++) begin
        older_d[h_idx][e] = 1'b0;
        older_d[e][h_idx] = 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= '0;
      for (int unsigned e = 0; e < DEPTH; e++) begin
        ent_id_q[e] <= '0;
        older_q[e]  <= '0;
      end
    end else begin
      valid_q <= valid_d;
      if (push_i) ent_id_q[free_idx] <= push_id_i;
      for (int unsigned e = 0; e < DEPTH; e++) begin
        older_q[e] <= older_d[e];
      end
    end
  end

endmodule
