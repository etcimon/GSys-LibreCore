// hyp8 provenance: REWRITTEN (sv-timing emit at the 8-FO4 budget)
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright 2026 GSys — LibreCore hypothesis core (8-FO4 redesign).
// Description: store buffer commit kernel. Program-order head select of
//   the speculative queue (the live entry no live entry is older than),
//   the commit-transaction head-match gate, and the one-cycle pend record
//   that carries the popped head into the commit queue (+1 on commit_i —
//   the committed store is architectural and survives flush).

module stb_commit
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned           DEPTH_SPEC = 4,
    parameter type                   entry_t    = logic,
    // T6b-4b mixed-resident OoO commit head-match gate
    parameter bit                    MIX_COMMIT = 1'b0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,  // does NOT clear the pend: the popped store committed
    // speculative queue view
    input  logic [DEPTH_SPEC-1:0]            spec_valid_i,
    input  logic [DEPTH_SPEC-1:0][DEPTH_SPEC-1:0] spec_older_i,
    input  entry_t [DEPTH_SPEC-1:0]          spec_entries_i,
    // commit event (COMMIT_STAGE) and its tid for the head-match gate
    input  logic                             commit_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_trans_id_i,
    input  logic                             drain_ready_i,
    // head select (the live entry no live entry is older than)
    output logic [DEPTH_SPEC-1:0]            head_oh_o,
    output entry_t                           head_entry_o,
    output logic                             head_valid_o,
    // T6b-4b: a younger committing tid must not evict the uncommitted head
    output logic                             head_mismatch_o,
    // spec pop — the head (plus same-TID Zicclsm beat1) leaves this cycle
    output logic [DEPTH_SPEC-1:0]            pop_oh_o,
    // staged commit push: valid one cycle after commit_i; entry snapshot
    // taken at the pop edge so a same-cycle cancel cannot corrupt it.
    output logic                             push_valid_o,
    output entry_t                           push_entry_o,
    output logic                             pend_v_o,
    output logic                             pend2_v_o,
    output entry_t                           pend2_entry_o
);

  // head: live, and no live entry is older (emit spec_head_oh verbatim)
  always_comb begin
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      automatic logic any_older;
      any_older = 1'b0;
      for (int unsigned j = 0; j < DEPTH_SPEC; j++)
        any_older |= spec_valid_i[j] && spec_older_i[j][i];
      head_oh_o[i] = spec_valid_i[i] && !any_older;
    end
  end

  always_comb begin
    head_entry_o = '0;
    for (int unsigned i = 0; i < DEPTH_SPEC; i++)
      if (head_oh_o[i]) head_entry_o = head_entry_o | spec_entries_i[i];
  end

  // Zicclsm two-beat store: both beats share head_entry_o.trans_id. Pop beat1
  // atomically with beat0 into architectural pend2_q so both survive flush_i
  // and beat1 drains into commit_queue immediately after beat0.
  logic [DEPTH_SPEC-1:0] beat1_oh;
  entry_t                beat1_entry;
  logic                  beat1_valid;
  always_comb begin
    beat1_oh    = '0;
    beat1_entry = '0;
`ifndef G6LC_MUT_STQ_ZICCLSM_SINGLE_BEAT
    if (G6LCCfg.RVZicclsm && head_valid_o) begin
      for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
        if (spec_valid_i[i] && !head_oh_o[i] &&
            (spec_entries_i[i].trans_id == head_entry_o.trans_id)) begin
          beat1_oh[i] = 1'b1;
          beat1_entry = beat1_entry | spec_entries_i[i];
        end
      end
    end
`endif
  end
  assign beat1_valid = |beat1_oh;

  assign head_valid_o   = |head_oh_o;
  assign head_mismatch_o = MIX_COMMIT && head_valid_o &&
                           (head_entry_o.trans_id != commit_trans_id_i);

  // The pop itself is same-cycle (the entry's slot frees as today); the
  // payload is captured into the pend record and pushed to the commit
  // queue one cycle later. A committing store is architectural — its tid
  // is never in the cancel mask and may already be recycled — so the pend
  // is not gated by cancelled_mask_i (emit parity: no cancel check on the
  // spec->commit handoff).
  assign pop_oh_o = commit_i ? (head_oh_o | beat1_oh) : '0;

  logic   pend_v_q, pend2_v_q;
  entry_t pend_entry_q, pend2_entry_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_pend
    if (!rst_ni) begin
      pend_v_q      <= 1'b0;
      pend_entry_q  <= '0;
      pend2_v_q     <= 1'b0;
      pend2_entry_q <= '0;
    end else begin
      // pend drains every cycle into the commit queue (the drain accepts
      // unconditionally — capacity is charged through commit_ready_o).
      // When a two-beat Zicclsm store commits, beat1 stages in pend2_q and
      // shifts into pend_q once beat0 has pushed (!pend_v_q) and the commit
      // queue has a free slot (drain_ready_i).
      if (commit_i && head_valid_o) begin
        pend_v_q      <= 1'b1;
        pend_entry_q  <= head_entry_o;
        pend2_v_q     <= beat1_valid;
        pend2_entry_q <= beat1_entry;
      end else if (!pend_v_q && pend2_v_q && drain_ready_i) begin
        pend_v_q      <= 1'b1;
        pend_entry_q  <= pend2_entry_q;
        pend2_v_q     <= 1'b0;
      end else begin
        pend_v_q      <= 1'b0;
      end
    end
  end

  assign push_valid_o  = pend_v_q;
  assign push_entry_o  = pend_entry_q;
  assign pend_v_o      = pend_v_q || pend2_v_q;
  assign pend2_v_o     = pend2_v_q;
  assign pend2_entry_o = pend2_entry_q;

endmodule
