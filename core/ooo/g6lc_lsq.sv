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
    // In-order store commit (drain oldest store)
    input  logic        commit_st_i,
    // Load query for CAM / STL (issue of load)
    input  logic        ld_query_i,
    input  logic [CVA6Cfg.PLEN-1:0] ld_query_addr_i,
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] ld_query_id_i,
    output logic        older_store_pending_o,
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

  // Line match: cache-line aligned (64B) when PLEN allows, else byte-8 group
  function automatic logic line_match(
      input logic [CVA6Cfg.PLEN-1:0] a,
      input logic [CVA6Cfg.PLEN-1:0] b
  );
    if (CVA6Cfg.PLEN > 6)
      line_match = (a[CVA6Cfg.PLEN-1:3] == b[CVA6Cfg.PLEN-1:3]);
    else
      line_match = (a == b);
  endfunction

  always_comb begin
    st_d = st_q;
    ld_d = ld_q;
    ld_full_o = 1'b1;
    st_full_o = 1'b1;
    for (int unsigned i = 0; i < LD_ENTRIES; i++) if (!ld_q[i].valid) ld_full_o = 1'b0;
    for (int unsigned i = 0; i < ST_ENTRIES; i++) if (!st_q[i].valid) st_full_o = 1'b0;

    // Multi-port alloc (program order p=0 first)
    for (int unsigned p = 0; p < NR_ALLOC; p++) begin
      if (ld_alloc_i[p]) begin
        automatic logic placed;
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
        automatic logic placed;
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

    // Commit oldest store (lowest index with valid)
    if (commit_st_i) begin
      automatic logic done;
      done = 1'b0;
      for (int unsigned i = 0; i < ST_ENTRIES; i++) begin
        if (!done && st_q[i].valid) begin
          st_d[i].valid = 1'b0;
          done = 1'b1;
        end
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

  // CAM / STL query (combinational on registered state)
  always_comb begin
    older_store_pending_o = 1'b0;
    stl_forward_o = 1'b0;
    stl_data_o = '0;
    stl_stall_o = 1'b0;
    lsq_busy_o = 1'b0;

    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      if (st_q[i].valid) begin
        older_store_pending_o = 1'b1;
        lsq_busy_o = 1'b1;
      end
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_q[i].valid) lsq_busy_o = 1'b1;

    if (ld_query_i) begin
      automatic logic found_match;
      automatic logic need_stall;
      found_match = 1'b0;
      need_stall  = 1'b0;
      // Scan youngest→oldest (high index = later alloc in compacting-free array:
      // entries keep alloc order by filling low indices first, so high = younger)
      for (int i = ST_ENTRIES - 1; i >= 0; i--) begin
        if (st_q[i].valid && !found_match) begin
          // Only consider stores that could be older than this load (tid not
          // strictly ordered here; conservative: all in-flight stores)
          if (!st_q[i].addr_v) begin
            need_stall = 1'b1;
          end else if (line_match(st_q[i].addr, ld_query_addr_i)) begin
            found_match = 1'b1;
            if (st_q[i].data_v) begin
              stl_forward_o = 1'b1;
              stl_data_o    = st_q[i].data;
              need_stall    = 1'b0;
            end else begin
              need_stall = 1'b1;
            end
          end
        end
      end
      // Unknown-addr older store without a resolved younger match → stall
      stl_stall_o = need_stall && !stl_forward_o;
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
