// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: the T21 prediction-time checkpoint buffer
// (`core/frontend/g6lc_bp_ckpt.sv`), checked as a unit. The fetch_B proofs
// elaborate the frontend with BPCkptDepth 0, so until now the buffer was
// covered only by the directed leaf (`tb_g6lc_review_ckpt`, 7 scenarios) and
// the randomized bench (REVIEW_RTL_CKPTRAND). This task makes the formal gate
// real for it (T23, plan item 5).
//
// Contract (the T21 own-entry identity, stated against an independent model):
//   C1  A tag handed out by an allocation names a live entry that returns
//       the ghist it was allocated with -- until its own resolve (pop), a
//       restore from it or from any OLDER live entry of the bank, or a bank
//       drop (flush / clear). Older = allocated earlier (the model keeps an
//       allocation sequence number per slot; the DUT does not export one).
//   C2  Once reclaimed by a restore or a drop, that tag is dead: a later pop
//       with the same {epoch, index} reads entry_valid_o = 0 (the epoch in the
//       tag advanced), so a late wrong-path resolve cannot touch the slot's
//       new owner. (A plain own pop is final by construction -- a CF resolves
//       once -- so the environment never re-pops an own-popped tag.)
//   C3  Occupancy: empty_o / full_o agree with the model's live count, and
//       the span never exceeds DEPTH. Allocation is all-or-nothing and only
//       when the slots fit.
//   C4  A restore from a live entry at ring distance d reclaims exactly the
//       entries at distance >= d: the model's live count equals d afterwards
//       (younger gone, older kept).
//
// Geometry: NrHarts 1 (one bank), DEPTH 4, NR_PUSH 2, GHIST_LEN 8, two epoch
// bits (TAG_W = IDX_W + 2), RAS fields present but unconstrained (the RAS
// snapshot is carried, not interpreted, by this module). Bounded PASS is not
// an unbounded proof; the cover task reports that the interesting paths
// (wrap, a restore that reclaims two younger entries, a stale-tag pop, full)
// are reachable within the depth.
//
// Run: sby -f core/frontend/formal/g6lc_bp_ckpt.sby
//      cva6-build verify --formal

module g6lc_bp_ckpt_props #(
    parameter int unsigned DEPTH = 4,
    parameter int unsigned NR_PUSH = 2,
    parameter int unsigned GHIST_LEN = 8,
    parameter int unsigned EPOCH_W = 2
) (
    input logic clk_i,
    input logic flush_i, clear_i,
    input logic [NR_PUSH-1:0] push_i,
    input logic [GHIST_LEN-1:0] push_ghist_i,
    input logic [1:0] push_ras_tos_i, push_ras_cnt_i,
    input logic [7:0] push_ras_top_i,
    input logic pop_i, pop_v_i, restore_i,
    input logic [$clog2(DEPTH)+EPOCH_W-1:0] pop_idx_i,
    // tracker arming: which of this cycle's allocated slots to follow
    input logic track_i,
    input logic [$clog2(NR_PUSH)-1:0] track_slot_i
);

`ifdef FORMAL
  localparam int unsigned IDX_W = $clog2(DEPTH);
  localparam int unsigned TAG_W = IDX_W + EPOCH_W;
  localparam int unsigned SEQ_W = 6;  // positions < 2*depth+DEPTH; bounded by the assume below
  localparam int unsigned CNT_W = $clog2(DEPTH + 1);

  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c;
    c = config_pkg::cva6_cfg_empty;
    c.NrHarts = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = mk_cfg();

  logic rst_init_q = 1'b1;
  logic rst_ni;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  assign rst_ni = ~rst_init_q;

  // --- DUT ------------------------------------------------------------------
  logic alloc_v_o, entry_valid_o, restore_valid_o, empty_o, full_o, clear_restore_o;
  logic [NR_PUSH-1:0][TAG_W-1:0] alloc_idx_o;
  logic [GHIST_LEN-1:0] entry_ghist_o;
  logic [1:0] entry_ras_tos_o, entry_ras_cnt_o, clear_ras_tos_o, clear_ras_cnt_o;
  logic [7:0] entry_ras_top_o, clear_ras_top_o;

  g6lc_bp_ckpt #(
      .CVA6Cfg(Cfg), .GHIST_LEN(GHIST_LEN), .DEPTH(DEPTH),
      .RAS_DEPTH(4), .RAS_PTR_W(2), .RAS_CNT_W(2), .RAS_VLEN(8),
      .NR_PUSH(NR_PUSH), .TAG_W(TAG_W)
  ) dut (
      .clk_i, .rst_ni, .flush_i, .clear_i,
      .clear_restore_o, .clear_ras_tos_o, .clear_ras_cnt_o, .clear_ras_top_o,
      .push_hart_i('0), .pop_hart_i('0),
      .push_i, .push_ghist_i, .push_ras_tos_i, .push_ras_cnt_i, .push_ras_top_i,
      .alloc_v_o, .alloc_idx_o,
      .pop_i, .pop_v_i, .pop_idx_i, .restore_i,
      .entry_valid_o, .entry_ghist_o, .entry_ras_tos_o, .entry_ras_cnt_o, .entry_ras_top_o,
      .restore_valid_o, .empty_o, .full_o
  );

  // --- independent model ------------------------------------------------------
  // Per slot: live bit, the tag it was handed out under, the ghist stored, and
  // its ring position (a free-running allocation pointer in the model's own
  // wide arithmetic: allocation order is the "younger" relation, and the
  // DUT's span -- alloc minus the oldest live position, holes included -- is
  // reproduced from it; a restore pulls the pointer back to the restored
  // entry's position, a drop to 0, exactly the capacity rule the module
  // documents).
  logic [DEPTH-1:0] m_live_q;
  logic [DEPTH-1:0][TAG_W-1:0] m_tag_q;
  logic [DEPTH-1:0][GHIST_LEN-1:0] m_ghist_q;
  logic [DEPTH-1:0][SEQ_W-1:0] m_seq_q;
  logic [SEQ_W-1:0] m_next_seq_q;
  // span from the model: pointer minus the oldest live position (0 when none)
  logic [SEQ_W-1:0] m_oldest_pos;
  logic m_any_live;
  logic [SEQ_W-1:0] m_span;
  always_comb begin
    m_any_live = 1'b0;
    m_oldest_pos = '0;
    for (int unsigned k = 0; k < DEPTH; k++) begin
      if (m_live_q[k] && (!m_any_live || m_seq_q[k] < m_oldest_pos)) begin
        m_any_live = 1'b1;
        m_oldest_pos = m_seq_q[k];
      end
    end
    m_span = m_any_live ? (m_next_seq_q - m_oldest_pos) : '0;
  end
  // A dead-tag set: tags reclaimed by a restore or a drop, which must read
  // dead until the slot is reallocated under a new tag (the epoch moved).
  logic [DEPTH-1:0] m_dead_q;
  logic [DEPTH-1:0][TAG_W-1:0] m_dead_tag_q;

  logic [IDX_W-1:0] pop_slot;
  assign pop_slot = pop_idx_i[IDX_W-1:0];

  // the pop tag names a live model entry
  logic pop_hits_live;
  assign pop_hits_live = pop_v_i && m_live_q[pop_slot] && (m_tag_q[pop_slot] == pop_idx_i);

  // allocations this cycle (the model takes the DUT's indices: the identity
  // being checked is "what you allocated is what you read back", not the
  // allocation order itself, which C3/C4 pin through the span)
  logic [CNT_W-1:0] push_cnt;
  logic [NR_PUSH-1:0][CNT_W-1:0] push_rank;
  always_comb begin
    push_cnt = '0;
    for (int unsigned k = 0; k < NR_PUSH; k++) begin
      push_rank[k] = push_cnt;
      push_cnt += CNT_W'(push_i[k]);
    end
  end

  // entries the restore reclaims: the restored entry and every younger one
  logic [DEPTH-1:0] m_victims;
  always_comb begin
    m_victims = '0;
    if (restore_i && pop_hits_live) begin
      for (int unsigned k = 0; k < DEPTH; k++) begin
        if (m_live_q[k] && (m_seq_q[k] >= m_seq_q[pop_slot])) m_victims[k] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m_live_q <= '0;
      m_tag_q <= '0;
      m_ghist_q <= '0;
      m_seq_q <= '0;
      m_next_seq_q <= '0;
      m_dead_q <= '0;
      m_dead_tag_q <= '0;
    end else begin
      // reclaim (a restore also pulls the allocation pointer back onto the
      // restored entry's position: its slot is the next one handed out)
      if (restore_i && pop_hits_live) begin
        for (int unsigned k = 0; k < DEPTH; k++) begin
          if (m_victims[k]) begin
            m_live_q[k] <= 1'b0;
            m_dead_q[k] <= 1'b1;
            m_dead_tag_q[k] <= m_tag_q[k];
          end
        end
        m_next_seq_q <= m_seq_q[pop_slot];
      end else if (pop_i && pop_hits_live) begin
        m_live_q[pop_slot] <= 1'b0;
      end
      // allocation (the DUT reports it; C3 checks it was legal)
      if (alloc_v_o) begin
        for (int unsigned k = 0; k < NR_PUSH; k++) begin
          if (push_i[k]) begin
            m_live_q[alloc_idx_o[k][IDX_W-1:0]] <= 1'b1;
            m_tag_q[alloc_idx_o[k][IDX_W-1:0]] <= alloc_idx_o[k];
            m_ghist_q[alloc_idx_o[k][IDX_W-1:0]] <= push_ghist_i;
            m_seq_q[alloc_idx_o[k][IDX_W-1:0]] <= m_next_seq_q + SEQ_W'(push_rank[k]);
            m_dead_q[alloc_idx_o[k][IDX_W-1:0]] <= 1'b0;
          end
        end
        m_next_seq_q <= m_next_seq_q + SEQ_W'(push_cnt);
      end
      // bank drop: everything dead, the pointer back to 0 (as the DUT's)
      if (flush_i || clear_i) begin
        for (int unsigned k = 0; k < DEPTH; k++) begin
          if (m_live_q[k]) begin
            m_dead_q[k] <= 1'b1;
            m_dead_tag_q[k] <= m_tag_q[k];
          end
        end
        m_live_q <= '0;
        m_next_seq_q <= '0;
      end
    end
  end

  // --- environment ------------------------------------------------------------
  // A pop names a tag that was handed out: live, or dead by a reclaim (the
  // late wrong-path resolve C2 is about). It never re-pops an own-popped tag
  // (a CF resolves once) and never invents a tag.
  always_comb begin
    if (pop_v_i) begin
      assume (pop_hits_live || (m_dead_q[pop_slot] && m_dead_tag_q[pop_slot] == pop_idx_i));
    end
    // restore / pop are resolve-side events and carry a tag
    if (restore_i || pop_i) assume (pop_v_i);
    // a restore is a mispredict resolve: no plain pop in the same cycle
    if (restore_i) assume (!pop_i);
    // the frontend never allocates and drops in one cycle (alloc_en excludes
    // it anyway); keep the model and the DUT on the same simple step
    if (flush_i || clear_i) assume (push_i == '0);
    // the position counter is a model artefact: stop before it wraps
    assume (m_next_seq_q < SEQ_W'(48));
  end

  // --- tracked entry (C1 / C2) --------------------------------------------------
  logic t_armed_q, t_dead_q;
  logic [TAG_W-1:0] t_tag_q;
  logic [GHIST_LEN-1:0] t_ghist_q;
  logic [IDX_W-1:0] t_slot;
  assign t_slot = t_tag_q[IDX_W-1:0];
  logic t_hit;  // this cycle's pop names the tracked tag
  assign t_hit = pop_v_i && (pop_idx_i == t_tag_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      t_armed_q <= 1'b0;
      t_dead_q <= 1'b0;
      t_tag_q <= '0;
      t_ghist_q <= '0;
    end else begin
      if (!t_armed_q && !t_dead_q && track_i && alloc_v_o && push_i[track_slot_i]) begin
        t_armed_q <= 1'b1;
        t_tag_q <= alloc_idx_o[track_slot_i];
        t_ghist_q <= push_ghist_i;
      end else if (t_armed_q) begin
        // own pop: final, stop tracking
        if (pop_i && !restore_i && t_hit) t_armed_q <= 1'b0;
        // reclaimed by a restore from itself or an older live entry, or a drop
        if ((restore_i && pop_hits_live && m_victims[t_slot]) || flush_i || clear_i) begin
          t_armed_q <= 1'b0;
          t_dead_q <= 1'b1;
        end
      end else if (t_dead_q) begin
        // the slot is reallocated under a new tag: the dead tag is retired
        if (alloc_v_o) begin
          for (int unsigned k = 0; k < NR_PUSH; k++) begin
            if (push_i[k] && alloc_idx_o[k][IDX_W-1:0] == t_slot) t_dead_q <= 1'b0;
          end
        end
      end
    end
  end

  always_comb begin
    if (rst_ni) begin
      // C1: the tracked tag reads its own snapshot while live
      if (t_armed_q && t_hit) begin
        a_c1_live:  assert (entry_valid_o);
        a_c1_ghist: assert (entry_ghist_o == t_ghist_q);
      end
      // C2: once reclaimed by a restore or a drop it is dead (until the slot
      // is reallocated, under a different epoch)
      if (t_dead_q && t_hit) begin
        a_c2_dead: assert (!entry_valid_o);
        a_c2_norestore: assert (!restore_valid_o);
      end
      // C3: occupancy is span-based (holes included), as the module documents
      a_c3_span:  assert (SEQ_W'(dut.span[0]) == m_span);
      a_c3_bound: assert (m_span <= SEQ_W'(DEPTH));
      a_c3_empty: assert (empty_o == (m_span == '0));
      a_c3_full:  assert (full_o == (m_span == SEQ_W'(DEPTH)));
      a_c3_fit:   assert (!alloc_v_o || (m_span + SEQ_W'(push_cnt) <= SEQ_W'(DEPTH)));
      a_c3_nodrop: assert (!alloc_v_o || (!flush_i && !clear_i));
      a_c3_norestore: assert (!alloc_v_o || !restore_i);
      a_c3_some:  assert (!alloc_v_o || (push_cnt != '0));
      // ... and all-or-nothing: whenever the slots fit and nothing forbids it,
      // the window IS checkpointed (no silent refusal)
      a_c3_when_fits: assert (alloc_v_o || (push_cnt == '0) || restore_i || flush_i || clear_i
                              || (m_span + SEQ_W'(push_cnt) > SEQ_W'(DEPTH)));
      // the DUT's restore qualification agrees with the model's liveness
      a_c3_rv: assert (restore_valid_o == (restore_i && pop_hits_live));
      // a pop that names a live model entry is live in the DUT too
      if (pop_hits_live) a_c3_live: assert (entry_valid_o);
    end
  end

  // C4: after a restore from a live entry at ring distance d, the span is d
  // (younger gone, older kept, the pointer on the restored slot)
  logic c4_q;
  logic [SEQ_W-1:0] c4_expect_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      c4_q <= 1'b0;
      c4_expect_q <= '0;
    end else begin
      c4_q <= restore_i && pop_hits_live && !flush_i && !clear_i;
      c4_expect_q <= m_seq_q[pop_slot] - m_oldest_pos;
    end
  end
  always_comb begin
    if (rst_ni && c4_q) a_c4_span: assert (m_span == c4_expect_q);
  end

  // --- reachability -------------------------------------------------------------
  logic [SEQ_W-1:0] cov_allocs_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cov_allocs_q <= '0;
    else if (alloc_v_o) cov_allocs_q <= cov_allocs_q + SEQ_W'(push_cnt);
  end
  always_comb begin
    if (rst_ni) begin
      c_full: cover (full_o);
      c_wrap: cover (alloc_v_o && cov_allocs_q >= SEQ_W'(DEPTH));
      c_restore_two: cover (restore_i && pop_hits_live && $countones(m_victims) == 3);
      c_stale_pop: cover (t_dead_q && t_hit);
      c_tracked_pop: cover (t_armed_q && t_hit && pop_i && !restore_i);
      c_clear_restore: cover (clear_restore_o);
    end
  end
`endif

endmodule
