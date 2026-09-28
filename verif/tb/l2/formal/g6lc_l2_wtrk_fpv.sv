// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Bounded formal harness for g6lc_l2_wtrk (T9b posted-write tracker).
//
//   P1  no two live entries share a line with different ids (under the
//       parent's R2 admission contract; FORMAL_MUT_P1 drops the contract
//       as the negative control).
//   P2  B conservation — every memory B is absorbed by exactly one entry,
//       b_pend rises only on an absorb and falls only on the slave-B pop;
//       bounded liveness: no entry outlives the fairness bound, with a
//       cover witness of a posted entry's full lifecycle.
//
// Unconstrained inputs are free variables; the assumptions below are the
// caller-side legality contract from g6lc_l2_top (AW admission + AXI B
// ordering per id).

module g6lc_l2_wtrk_fpv #(
    parameter int unsigned DEPTH = 4,
    parameter int unsigned IDW   = 4,
    parameter int unsigned AW_   = 16
) (
    input logic               clk_i,
    input logic               rst_ni,
    input logic               push_i,
    input logic [IDW-1:0]     push_id_i,
    input logic [AW_-1:0]     push_line_i,
    input logic               push_blocking_i,
    input logic               push_need_r_i,
    input logic               m_b_valid_i,
    input logic [IDW-1:0]     m_b_id_i,
    input logic [1:0]         m_b_resp_i,
    input logic               s_b_ready_i
);
  localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  logic                    full_o, empty_o, m_b_match_o;
  logic [IDX_W-1:0]        alloc_idx_o, pop_idx_o;
  logic                    s_b_valid_o, pop_o;
  logic [IDW-1:0]          s_b_id_o;
  logic [1:0]              s_b_resp_o;
  logic                    s_b_blocking_o;

  g6lc_l2_wtrk #(
      .DEPTH          (DEPTH),
      .ID_WIDTH       (IDW),
      .ADDR_WIDTH     (AW_),
      .AXI_USER_WIDTH (1)
  ) dut (
      .clk_i,
      .rst_ni,
      .push_i            (push_i),
      .push_id_i         (push_id_i),
      .push_line_i       (push_line_i),
      .push_blocking_i   (push_blocking_i),
      .push_need_r_i     (push_need_r_i),
      .full_o            (full_o),
      .alloc_idx_o       (alloc_idx_o),
      .m_b_valid_i       (m_b_valid_i),
      .m_b_id_i          (m_b_id_i),
      .m_b_resp_i        (m_b_resp_i),
      .m_b_user_i        ('0),
      .m_b_match_o       (m_b_match_o),
      .s_b_valid_o       (s_b_valid_o),
      .s_b_id_o          (s_b_id_o),
      .s_b_resp_o        (s_b_resp_o),
      .s_b_user_o        (),
      .s_b_blocking_o    (s_b_blocking_o),
      .s_b_ready_i       (s_b_ready_i),
      .pop_o             (pop_o),
      .pop_idx_o         (pop_idx_o),
      .line0_i           ('0),
      .line0_match_o     (),
      .line1_i           ('0),
      .line1_match_o     (),
      .line1_match_id_o  (),
      .need_r_id_i       ('0),
      .need_r_id_match_o (),
      .empty_o           (empty_o)
  );

  // --------------------
  // Caller-side legality assumptions
  // --------------------
  // Start in reset so the unconstrained register initial state is forced
  // to the reset state (otherwise step-0 states are unreachable junk).
  logic f_past_valid = 1'b0;
  always @(posedge clk_i) f_past_valid <= 1'b1;
  always @(posedge clk_i) assume (f_past_valid || !rst_ni);

  // R2 admission: a push whose line matches a live entry carries that
  // entry's id (the parent's AW gate holds different-id same-line writes).
  // FORMAL_MUT_P1 drops this assumption — the solver must then produce a
  // P1 counterexample, proving the property is load-bearing.
  logic           line_seen;
  logic [IDW-1:0] line_seen_id;
  always_comb begin
    line_seen    = 1'b0;
    line_seen_id = '0;
    for (int unsigned e = 0; e < DEPTH; e++)
      if (dut.valid_q[e] && dut.ent_line_q[e] == push_line_i) begin
        line_seen    = 1'b1;
        line_seen_id = dut.ent_id_q[e];
      end
  end

  always @(posedge clk_i) begin
    if (rst_ni) begin
      // AW admission never pushes into a full tracker.
      assume (!push_i || !full_o);
`ifndef FORMAL_MUT_P1
      assume (!push_i || !line_seen || push_id_i == line_seen_id);
`endif
    end
  end

  // Bounded-liveness fairness: while any entry still waits for its B the
  // memory delivers one within FB cycles, and the slave accepts a pending
  // B within FS cycles.
  localparam int unsigned FB = 8;
  localparam int unsigned FS = 4;
  int unsigned wait_cnt, stall_cnt;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wait_cnt  <= 0;
      stall_cnt <= 0;
    end else begin
      wait_cnt  <= (|(dut.valid_q & ~dut.b_pend_q)) ? wait_cnt + 1 : 0;
      stall_cnt <= (s_b_valid_o && !s_b_ready_i) ? stall_cnt + 1 : 0;
    end
  end
  always @(posedge clk_i) begin
    if (rst_ni) begin
      assume (wait_cnt <= FB);
      assume (stall_cnt <= FS);
    end
  end

  // --------------------
  // P1 — same-line entries always carry the same id
  // --------------------
  always @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned i = 0; i < DEPTH; i++)
        for (int unsigned j = i + 1; j < DEPTH; j++)
          assert (!(dut.valid_q[i] && dut.valid_q[j] &&
                    dut.ent_line_q[i] == dut.ent_line_q[j] &&
                    dut.ent_id_q[i]  != dut.ent_id_q[j]));
    end
  end

  // --------------------
  // P2 — B conservation
  // --------------------
  always @(posedge clk_i) begin
    if (rst_ni) begin
      // Every memory B is absorbed by exactly one live entry.
      if (m_b_valid_i && m_b_match_o)
        assert (dut.m_sel != '0 && (dut.m_sel & (dut.m_sel - 1'b1)) == '0);
      // At most one entry presents on the slave B channel.
      if (s_b_valid_o)
        assert (dut.p_sel != '0 && (dut.p_sel & (dut.p_sel - 1'b1)) == '0);
      for (int unsigned e = 0; e < DEPTH; e++) begin
        // b_pend rises only on a memory-B absorb of this entry ...
        if (dut.b_pend_q[e] && !$past(dut.b_pend_q[e]) && $past(rst_ni))
          assert ($past(m_b_valid_i && dut.m_sel[e]));
        // ... and falls only on this entry's slave-B pop.
        if (!dut.b_pend_q[e] && $past(dut.b_pend_q[e]) && $past(rst_ni))
          assert ($past(pop_o && dut.p_sel[e]));
      end
    end
  end

`ifdef FORMAL_LIVENESS
  // Bounded liveness: per-entry age never exceeds the worst-case drain
  // bound (each of the DEPTH entries can wait FB for its B and FS to
  // present it; same-id ordering serialises the pops).
  localparam int unsigned MAXAGE = DEPTH*FB + DEPTH*FS + 8;
  int unsigned age_q [DEPTH];
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned e = 0; e < DEPTH; e++) age_q[e] <= 0;
    end else begin
      for (int unsigned e = 0; e < DEPTH; e++) begin
        if (push_i && alloc_idx_o == IDX_W'(e)) age_q[e] <= 0;
        else if (dut.valid_q[e] && age_q[e] <= MAXAGE)
          age_q[e] <= age_q[e] + 1;
      end
    end
  end
  always @(posedge clk_i) begin
    if (rst_ni)
      for (int unsigned e = 0; e < DEPTH; e++)
        assert (!dut.valid_q[e] || age_q[e] <= MAXAGE);
  end
`endif

  // Liveness witness: a posted (non-blocking) entry gets its B, presents
  // on the slave channel and pops.
  always @(posedge clk_i) begin
    if (rst_ni) cover (pop_o && !dut.ent_block_q[dut.pop_idx_o]);
  end

endmodule
