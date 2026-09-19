// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.4 production LSQ: multi-alloc, live address CAM, store-to-load forward.
// Bottleneck opts:
//   * Dual-port alloc / addr / data update (NrIssuePorts)
//   * Youngest-matching-store forward (scan high→low, first hit wins)
//   * Stall only unknown older addr or match-without-data
//   * Complete by trans_id (multi-WB)

module g6lc_lsq #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned LD_ENTRIES = 8,
    parameter int unsigned ST_ENTRIES = 8,
    parameter int unsigned NR_ALLOC   = 2,
    parameter int unsigned NR_UPDATE  = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // U5 production: drop entries whose SB tid was cancelled
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]            cancelled_mask_i,
    // Multi-port allocate at dispatch
    input  logic [NR_ALLOC-1:0]                         ld_alloc_i,
    input  logic [NR_ALLOC-1:0]                         st_alloc_i,
    input  logic [NR_ALLOC-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] alloc_id_i,
    output logic                                        ld_full_o,
    output logic                                        st_full_o,
    // Free entries. "Any entry free" is not an admission credit: a dispatch
    // group with more memory ops than free entries has its surplus allocations
    // silently discarded below, leaving ops live in the ROB/IQ with no queue
    // entry to order or forward them. The caller must compare its group size
    // against these counts.
    output logic [$clog2(LD_ENTRIES+1)-1:0]             ld_free_o,
    output logic [$clog2(ST_ENTRIES+1)-1:0]             st_free_o,
    // Live AGU / store-data updates (issue cycle)
    input  logic [NR_UPDATE-1:0]                         addr_valid_i,
    input  logic [NR_UPDATE-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] addr_id_i,
    input  logic [NR_UPDATE-1:0][CVA6Cfg.PLEN-1:0]         addr_i,
    input  logic [NR_UPDATE-1:0]                         addr_is_st_i,
    input  logic [NR_UPDATE-1:0][1:0]                     addr_size_i,
    input  logic [NR_UPDATE-1:0]                         st_data_valid_i,
    input  logic [NR_UPDATE-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] st_data_id_i,
    input  logic [NR_UPDATE-1:0][CVA6Cfg.XLEN-1:0]        st_data_i,
    // Multi-WB complete
    input  logic [CVA6Cfg.NrWbPorts-1:0]                            complete_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] complete_id_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0]                            complete_is_st_i,
    // Store commit, one bit plus the committing store's trans_id per commit
    // port. Release is by id, never "the oldest valid entry": writeback already
    // releases by id, so an index-based release here frees a different store.
    input  logic [CVA6Cfg.NrCommitPorts-1:0]                            commit_st_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] commit_id_i,
    // Age anchor: the scoreboard commit pointer = oldest live slot. Program
    // order is circular distance from this pointer; trans_id wraps, so it is
    // the only sound "older than" key once slots are reused.
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0]                         commit_ptr_i,
    // Load query for CAM / STL (issue of load)
    input  logic        ld_query_i,
    input  logic [CVA6Cfg.PLEN-1:0] ld_query_addr_i,
    input  logic [1:0]  ld_query_size_i,
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] ld_query_id_i,
    // Live store tids (one bit per scoreboard slot) for the issue queue's
    // per-entry age gate.
    output logic [CVA6Cfg.NR_SB_ENTRIES-1:0] st_live_mask_o,
    output logic        store_pending_o,
    output logic        stl_forward_o,
    output logic [CVA6Cfg.XLEN-1:0] stl_data_o,
    output logic        stl_stall_o,
    output logic        lsq_busy_o
);

  typedef struct packed {
    logic                             valid;
    logic                             addr_v;
    logic                             data_v;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] id;
    logic [CVA6Cfg.PLEN-1:0]          addr;
    logic [CVA6Cfg.XLEN-1:0]          data;
    logic [1:0]                       size;
  } st_ent_t;

  typedef struct packed {
    logic                             valid;
    logic                             addr_v;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] id;
    logic [CVA6Cfg.PLEN-1:0]          addr;
  } ld_ent_t;

  st_ent_t [ST_ENTRIES-1:0] st_q, st_d;
  ld_ent_t [LD_ENTRIES-1:0] ld_q, ld_d;

  // Byte-lane footprint of an access inside its aligned XLEN word, matching the
  // store_buffer/be_gen lane convention (size is the extract_transfer_size
  // encoding: 00=byte .. 11=XLEN). Naturally-aligned accesses never straddle
  // the word boundary; a misaligned access traps in the LSU, so bytes landing
  // beyond lane XLEN/8 are moot here.
  localparam int unsigned LANES = (CVA6Cfg.XLEN + 7) / 8;
  function automatic logic [LANES-1:0] lane_be(
      input logic [CVA6Cfg.PLEN-1:0] a,
      input logic [1:0]              size
  );
    automatic logic [LANES-1:0] m;
    m = '0;
    for (int unsigned b = 0; b < LANES; b++)
      if (b < (1 << size)) m[b] = 1'b1;
    if (CVA6Cfg.XLEN == 64)
      lane_be = m << a[2:0];
    else
      lane_be = m << a[1:0];
  endfunction
  // Same aligned word? PLEN < 4 degenerates to the full address.
  function automatic logic same_word(
      input logic [CVA6Cfg.PLEN-1:0] a,
      input logic [CVA6Cfg.PLEN-1:0] b
  );
    if (CVA6Cfg.PLEN > 6)
      same_word = (a[CVA6Cfg.PLEN-1:3] == b[CVA6Cfg.PLEN-1:3]);
    else
      same_word = (a == b);
  endfunction

  // Occupancy flags depend only on registered state. They are kept out of the
  // update block below because that block reads ld_alloc_i/st_alloc_i, which the
  // caller derives from dispatch acknowledge; since the caller's admission term
  // consumes these flags, sharing a block closes a combinational loop
  // (can_go -> dispatch ack -> st_alloc_i -> st_full_o -> can_go). Dependency
  // analysis is per always_comb block, not per signal.
  always_comb begin
    ld_full_o = 1'b1;
    st_full_o = 1'b1;
    ld_free_o = '0;
    st_free_o = '0;
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (!ld_q[i].valid) begin
        ld_full_o = 1'b0;
        ld_free_o = ld_free_o + 1'b1;
      end
    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      if (!st_q[i].valid) begin
        st_full_o = 1'b0;
        st_free_o = st_free_o + 1'b1;
      end
  end

  always_comb begin
    // Declared and defaulted at block scope: a local declared inside a
    // conditional scope reads as a latch to the elaborator.
    automatic logic placed;
    placed = 1'b0;
    st_d = st_q;
    ld_d = ld_q;

    // Multi-port alloc (program order p=0 first)
    for (int unsigned p = 0; p < NR_ALLOC; p++) begin
      if (ld_alloc_i[p]) begin
        placed = 1'b0;
        for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
          if (!placed && !ld_d[i].valid) begin
            ld_d[i].valid = 1'b1;
            ld_d[i].addr_v = 1'b0;
            ld_d[i].id = alloc_id_i[p];
            ld_d[i].addr = '0;
            placed = 1'b1;
          end
        end
      end
      if (st_alloc_i[p]) begin
        placed = 1'b0;
        for (int unsigned i = 0; i < ST_ENTRIES; i++) begin
          if (!placed && !st_d[i].valid) begin
            st_d[i].valid = 1'b1;
            st_d[i].addr_v = 1'b0;
            st_d[i].data_v = 1'b0;
            st_d[i].id = alloc_id_i[p];
            st_d[i].addr = '0;
            st_d[i].data = '0;
            st_d[i].size = 2'b10;
            placed = 1'b1;
          end
        end
      end
    end

    // Live AGU address / size
    for (int unsigned u = 0; u < NR_UPDATE; u++) begin
      if (addr_valid_i[u]) begin
        if (addr_is_st_i[u]) begin
          for (int unsigned i = 0; i < ST_ENTRIES; i++)
            if (st_q[i].valid && st_q[i].id == addr_id_i[u]) begin
              st_d[i].addr_v = 1'b1;
              st_d[i].addr   = addr_i[u];
              st_d[i].size   = addr_size_i[u];
            end
        end else begin
          for (int unsigned i = 0; i < LD_ENTRIES; i++)
            if (ld_q[i].valid && ld_q[i].id == addr_id_i[u]) begin
              ld_d[i].addr_v = 1'b1;
              ld_d[i].addr   = addr_i[u];
            end
        end
      end
      if (st_data_valid_i[u]) begin
        for (int unsigned i = 0; i < ST_ENTRIES; i++)
          if (st_q[i].valid && st_q[i].id == st_data_id_i[u]) begin
            st_d[i].data_v = 1'b1;
            st_d[i].data   = st_data_i[u];
          end
      end
    end

    // Multi-WB complete
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
      if (complete_valid_i[w]) begin
        if (complete_is_st_i[w]) begin
          for (int unsigned i = 0; i < ST_ENTRIES; i++)
            if (st_q[i].valid && st_q[i].id == complete_id_i[w]) st_d[i].valid = 1'b0;
        end else begin
          for (int unsigned i = 0; i < LD_ENTRIES; i++)
            if (ld_q[i].valid && ld_q[i].id == complete_id_i[w]) ld_d[i].valid = 1'b0;
        end
      end
    end

    // Release committed stores by trans_id, on every commit port. Freeing the
    // lowest valid index instead would release whichever store happened to be
    // oldest -- typically a younger, still-unresolved store, because writeback
    // has already released the one now committing. It is idempotent: if the
    // entry is gone, nothing matches.
    for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
      if (commit_st_i[c]) begin
        for (int unsigned i = 0; i < ST_ENTRIES; i++)
          if (st_q[i].valid && st_q[i].id == commit_id_i[c]) st_d[i].valid = 1'b0;
      end
    end

    // Drop cancelled younger memory ops (tid == SB slot)
    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      if (st_d[i].valid && cancelled_mask_i[st_d[i].id]) st_d[i].valid = 1'b0;
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_d[i].valid && cancelled_mask_i[ld_d[i].id]) ld_d[i].valid = 1'b0;

    if (flush_i) begin
      st_d = '0;
      ld_d = '0;
    end
  end

  // Occupancy status, from registered state only. This is deliberately a
  // separate always_comb from the STL query below: sharing one block made these
  // outputs appear to depend on ld_query_*, and since the store-pending signal
  // gates issue that closed a combinational loop through the issue queue
  // (ld_qaddr -> LSQ -> store_pending -> mem_stall -> issue_valid).
  always_comb begin
    store_pending_o = 1'b0;
    lsq_busy_o = 1'b0;
    st_live_mask_o = '0;
    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      if (st_q[i].valid) begin
        store_pending_o = 1'b1;
        lsq_busy_o = 1'b1;
        st_live_mask_o[st_q[i].id] = 1'b1;
      end
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_q[i].valid) lsq_busy_o = 1'b1;
  end

  // CAM / STL query (combinational on registered state). Age is the circular
  // trans_id distance from commit_ptr_i: a store is older than the load iff
  // (store.id - cp) < (load.id - cp). Index order is NOT age -- freed slots are
  // reused out of order.
  //
  // Ordering vs data path split: this query is the *hazard* decision only --
  // the LSU store_buffer owns the byte-exact data forward (full PA + be, both
  // queues, commit handoff). stl_stall_o gates issue until no older store can
  // still alias unseen; the single serial LSU pipe then lands any older store
  // in the buffer strictly before the younger load's own PA compare.
  // stl_forward_o/stl_data_o are observability of "this load's bytes are fully
  // covered by one older store with data present" -- the same predicate the
  // store_buffer checks as st_fwd_covers downstream.
  always_comb begin
    automatic logic [LANES-1:0] ld_be, sbe;
    automatic logic need_stall, found_match;
    automatic int unsigned best;
    automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] ld_dist, sdist, best_dist;
    sbe         = '0;
    need_stall  = 1'b0;
    found_match = 1'b0;
    best        = 0;
    best_dist   = '0;
    ld_dist     = '0;
    sdist       = '0;
    stl_forward_o = 1'b0;
    stl_data_o = '0;
    stl_stall_o = 1'b0;
    ld_be = lane_be(ld_query_addr_i, ld_query_size_i);

    if (ld_query_i) begin
      need_stall  = 1'b0;
      found_match = 1'b0;
      best        = 0;
      best_dist   = '0;
      ld_dist     = ld_query_id_i - commit_ptr_i;
      for (int unsigned i = 0; i < ST_ENTRIES; i++) begin
        sdist = st_q[i].id - commit_ptr_i;
        if (st_q[i].valid && sdist < ld_dist) begin
          if (!st_q[i].addr_v) begin
            // Unresolved OLDER store may yet alias: stall regardless of any
            // resolved match (the unresolved one could be the true producer).
            need_stall = 1'b1;
          end else begin
            sbe = lane_be(st_q[i].addr, st_q[i].size);
            if (same_word(st_q[i].addr, ld_query_addr_i) &&
                (sbe & ld_be) != '0) begin
              // Byte overlap with an older store. Data still in flight means
              // the load must wait for the store to land in the LSU buffer.
              if (!st_q[i].data_v) need_stall = 1'b1;
              // Youngest older store whose lanes fully cover the load's bytes
              // is the one the store_buffer will forward from.
              if ((sbe & ld_be) == ld_be && (!found_match || sdist > best_dist)) begin
                found_match = 1'b1;
                best        = i;
                best_dist   = sdist;
              end
            end
          end
        end
      end
      if (!need_stall && found_match) begin
        stl_forward_o = 1'b1;
        stl_data_o    = st_q[best].data;
      end
      stl_stall_o = need_stall;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q <= '0;
      ld_q <= '0;
    end else begin
      st_q <= st_d;
      ld_q <= ld_d;
    end
  end

endmodule
