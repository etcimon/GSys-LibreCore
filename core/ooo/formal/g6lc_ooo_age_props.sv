// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: the OoO age key and the LSQ alias-validation scan, against
// the live g6lc_lsq. A scoreboard-shaped window model supplies the live set:
// tids are allocated at alloc_ptr and retired at commit_ptr, so the live set is
// the circular window [commit_ptr, alloc_ptr). The age key is sound exactly
// under that invariant, which is what the first property states; the second
// and third state that the violation scan is complete, sound and reports the
// oldest offending load.
//
// Run: sby -f core/ooo/formal/g6lc_ooo_age.sby

module g6lc_ooo_age_props #(
    parameter int unsigned NR_SB      = 8,
    parameter int unsigned TID_W      = 3,
    parameter int unsigned LD_ENTRIES = 2,
    parameter int unsigned ST_ENTRIES = 2,
    parameter int unsigned SEQ_W      = 6
) (
    input logic             clk_i,
    input logic             rst_ni,
    input logic             flush_i,
    input logic             alloc_i,
    input logic             alloc_is_st_i,
    input logic             retire_i,
    input logic             addr_valid_i,
    input logic [TID_W-1:0] addr_id_i,
    input logic [11:0]      addr_i,
    input logic [1:0]       addr_size_i
);

`ifdef FORMAL
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.PLEN = 12;
    c.NR_SB_ENTRIES = NR_SB;
    c.TRANS_ID_BITS = TID_W;
    c.NrWbPorts = 1;
    c.NrCommitPorts = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C = cfg();

  // ---------------------------------------------------------------------
  // Window model (the scoreboard's allocation/commit contract)
  // ---------------------------------------------------------------------
  logic [TID_W-1:0]            alloc_ptr_q, commit_ptr_q;
  logic [TID_W:0]              count_q;
  logic [NR_SB-1:0]            live_q, is_st_q, ld_addr_v_q;
  logic [NR_SB-1:0][11:0]      ld_addr_q;
  logic [NR_SB-1:0][1:0]       ld_size_q;
  logic [NR_SB-1:0][SEQ_W-1:0] seq_q;
  logic [SEQ_W-1:0]            seq_ctr_q;

  logic ld_full, st_full, pend, fwd, stall, busy, viol;
  logic [$clog2(LD_ENTRIES+1)-1:0] ld_free;
  logic [$clog2(ST_ENTRIES+1)-1:0] st_free;
  logic [NR_SB-1:0] st_live_mask;
  logic [63:0] fwd_data;
  logic [TID_W-1:0] viol_id;

  wire head_is_st = is_st_q[commit_ptr_q];
  wire do_alloc   = alloc_i && !flush_i && (count_q != NR_SB[TID_W:0]) &&
                    (alloc_is_st_i ? !st_full : !ld_full);
  wire do_retire  = retire_i && !flush_i && (count_q != '0);

  // Loads leave the LSQ on writeback completion, stores on commit release.
  wire       cmpl_v  = do_retire && !head_is_st;
  wire       cmst_v  = do_retire && head_is_st;

  g6lc_lsq #(
      .CVA6Cfg   (C),
      .LD_ENTRIES(LD_ENTRIES),
      .ST_ENTRIES(ST_ENTRIES),
      .NR_ALLOC  (1),
      .NR_UPDATE (1)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i  ('0),
      .sb_live_i         ('1),
      .ld_alloc_i        (do_alloc && !alloc_is_st_i),
      .st_alloc_i        (do_alloc && alloc_is_st_i),
      .alloc_id_i        (alloc_ptr_q),
      .ld_full_o         (ld_full),
      .st_full_o         (st_full),
      .ld_free_o         (ld_free),
      .st_free_o         (st_free),
      .addr_valid_i      (addr_valid_i),
      .addr_id_i         (addr_id_i),
      .addr_i            (addr_i),
      .addr_is_st_i      (is_st_q[addr_id_i]),
      .addr_size_i       (addr_size_i),
      .st_data_valid_i   (1'b0),
      .st_data_id_i      ('0),
      .st_data_i         ('0),
      .complete_valid_i  (cmpl_v),
      .complete_id_i     (commit_ptr_q),
      .complete_is_st_i  (1'b0),
      .commit_st_i       (cmst_v),
      .commit_id_i       (commit_ptr_q),
      .commit_ptr_i      (commit_ptr_q),
      .ld_query_i        (1'b0),
      .ld_query_addr_i   ('0),
      .ld_query_size_i   (2'b11),
      .ld_query_id_i     ('0),
      .st_live_mask_o    (st_live_mask),
      .store_pending_o   (pend),
      .stl_forward_o     (fwd),
      .stl_data_o        (fwd_data),
      .stl_stall_o       (stall),
      .lsq_busy_o        (busy),
      .mem_violation_o   (viol),
      .mem_violation_id_o(viol_id)
  );

  // Force a reset in the first cycle. `initial assume (!rst_ni)` is rejected by
  // the slang frontend, so drive it from an initialised register.
  logic rst_init_q = 1'b1;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  always_ff @(posedge clk_i) begin
    if (rst_init_q) assume (!rst_ni);
  end

  // Address updates name a live, unresolved entry and are naturally aligned.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (!addr_valid_i || live_q[addr_id_i]);
      assume (!addr_valid_i || is_st_q[addr_id_i] || !ld_addr_v_q[addr_id_i]);
      assume (!addr_valid_i || ((addr_i & 12'((1 << addr_size_i) - 1)) == '0));
      assume (seq_ctr_q < SEQ_W'(48));
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      alloc_ptr_q  <= '0;
      commit_ptr_q <= '0;
      count_q      <= '0;
      live_q       <= '0;
      is_st_q      <= '0;
      ld_addr_v_q  <= '0;
      ld_addr_q    <= '0;
      ld_size_q    <= '0;
      seq_q        <= '0;
      seq_ctr_q    <= '0;
    end else if (flush_i) begin
      alloc_ptr_q  <= '0;
      commit_ptr_q <= '0;
      count_q      <= '0;
      live_q       <= '0;
      ld_addr_v_q  <= '0;
    end else begin
      if (do_alloc) begin
        live_q[alloc_ptr_q]      <= 1'b1;
        is_st_q[alloc_ptr_q]     <= alloc_is_st_i;
        ld_addr_v_q[alloc_ptr_q] <= 1'b0;
        seq_q[alloc_ptr_q]       <= seq_ctr_q;
        seq_ctr_q                <= seq_ctr_q + 1'b1;
        alloc_ptr_q              <= alloc_ptr_q + 1'b1;
      end
      if (do_retire) begin
        live_q[commit_ptr_q]      <= 1'b0;
        ld_addr_v_q[commit_ptr_q] <= 1'b0;
        commit_ptr_q              <= commit_ptr_q + 1'b1;
      end
      count_q <= count_q + (TID_W+1)'(do_alloc) - (TID_W+1)'(do_retire);
      if (addr_valid_i && live_q[addr_id_i] && !is_st_q[addr_id_i]) begin
        ld_addr_v_q[addr_id_i] <= 1'b1;
        ld_addr_q[addr_id_i]   <= addr_i;
        ld_size_q[addr_id_i]   <= addr_size_i;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Specification helpers
  // ---------------------------------------------------------------------
  function automatic logic [7:0] lanes(input logic [11:0] a, input logic [1:0] size);
    logic [7:0] m;
    m = '0;
    for (int unsigned b = 0; b < 8; b++) if (b < (1 << size)) m[b] = 1'b1;
    return m << a[2:0];
  endfunction

  function automatic logic older(input logic [TID_W-1:0] a, input logic [TID_W-1:0] b);
    return g6lc_ooo_pkg::ooo_age_older(TID_W, 32'(a), 32'(b), 32'(commit_ptr_q));
  endfunction

  // Candidate loads for the store address arriving this cycle.
  logic st_resolving;
  logic [NR_SB-1:0] cand;
  always_comb begin
    st_resolving = addr_valid_i && live_q[addr_id_i] && is_st_q[addr_id_i];
    cand = '0;
    for (int unsigned t = 0; t < NR_SB; t++)
      cand[t] = st_resolving && live_q[t] && !is_st_q[t] && ld_addr_v_q[t] &&
                older(addr_id_i, TID_W'(t)) &&
                (ld_addr_q[t][11:3] == addr_i[11:3]) &&
                ((lanes(ld_addr_q[t], ld_size_q[t]) & lanes(addr_i, addr_size_i)) != '0);
  end

  // ---------------------------------------------------------------------
  // Properties
  // ---------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // P1: under the live-window invariant the age key is allocation order.
      for (int unsigned a = 0; a < NR_SB; a++)
        for (int unsigned b = 0; b < NR_SB; b++)
          if (live_q[a] && live_q[b] && a != b)
            assert (older(TID_W'(a), TID_W'(b)) == (seq_q[a] < seq_q[b]));
      // P2: the scan is complete and sound.
      assert (viol == |cand);
      // P3: the reported load is a candidate and no candidate is older.
      if (viol) begin
        assert (cand[viol_id]);
        for (int unsigned t = 0; t < NR_SB; t++)
          if (cand[t]) assert (!older(TID_W'(t), viol_id));
      end
      // Live-entry witness: every LSQ store the DUT reports live is live here.
      for (int unsigned t = 0; t < NR_SB; t++)
        if (st_live_mask[t]) assert (live_q[t] && is_st_q[t]);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (viol);
      cover (viol && (commit_ptr_q > alloc_ptr_q));
      cover (count_q == NR_SB[TID_W:0]);
    end
  end
`endif

endmodule
