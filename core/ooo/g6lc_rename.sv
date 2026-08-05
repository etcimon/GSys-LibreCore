// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.1 multi-port rename (up to NrIssuePorts in one cycle).
// Sequential combinational rename within the cycle so later ports see earlier
// allocations (WAW/WAR correct). Freelist pops N free phys regs from free_d
// (earlier ports already cleared). Precise free+busy+map ckpt on branch.
//
// Package-free ports (NR_WB instead of CVA6Cfg.NrWbPorts) so formal can
// instantiate this module without config_pkg / ariane_pkg elaboration.

module g6lc_rename #(
    parameter int unsigned PRF_ENTRIES = 72,
    parameter int unsigned PRF_W       = 7,
    parameter int unsigned NR_PORTS    = 2,
    parameter int unsigned NR_FREE     = 2,
    parameter int unsigned NR_WB       = 1,
    parameter int unsigned CKPT_DEPTH  = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic mispredict_i,
    // Dispatch ports (program order p=0 oldest)
    input  logic [NR_PORTS-1:0]       valid_i,
    input  logic [NR_PORTS-1:0][4:0]  rs1_i,
    input  logic [NR_PORTS-1:0][4:0]  rs2_i,
    input  logic [NR_PORTS-1:0][4:0]  rd_i,
    input  logic [NR_PORTS-1:0]       need_rd_i,
    input  logic [NR_PORTS-1:0]       is_branch_i,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prs1_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prs2_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prd_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prd_old_o,
    output logic [NR_PORTS-1:0]       rs1_ready_o,
    output logic [NR_PORTS-1:0]       rs2_ready_o,
    output logic                      stall_o,
    // Busy table / freelist
    input  logic [NR_WB-1:0]            wb_valid_i,
    input  logic [NR_WB-1:0][PRF_W-1:0] wb_prd_i,
    // Multi-port free at commit (up to NR_FREE = NrCommitPorts)
    input  logic [NR_FREE-1:0]            free_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] free_prd_i,
    input  logic                      enable_i
);

  logic [31:0][PRF_W-1:0] map_q, map_d;
  logic [PRF_ENTRIES-1:0] free_q, free_d;
  logic [PRF_ENTRIES-1:0] busy_q, busy_d;

  logic [CKPT_DEPTH-1:0][31:0][PRF_W-1:0] ckpt_map_q;
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0]  ckpt_free_q;
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0]  ckpt_busy_q;
  logic [$clog2(CKPT_DEPTH+1)-1:0] ckpt_ptr_q, ckpt_ptr_d;

  // Lowest free phys ≥1 in current free vector
  function automatic logic [PRF_W-1:0] pick_free(input logic [PRF_ENTRIES-1:0] fr);
    pick_free = '0;
    for (int unsigned i = 1; i < PRF_ENTRIES; i++) begin
      if (fr[i] && pick_free == '0) pick_free = PRF_W'(i);
    end
  endfunction

  logic [NR_PORTS-1:0][PRF_W-1:0] alloc_prd_c;
  logic [NR_PORTS-1:0] do_alloc;
  logic stall_c;
  logic do_ckpt;

  // Checkpoint on first branch in this dispatch group (any port, not only 0)
  always_comb begin
    do_ckpt = 1'b0;
    if (enable_i && (ckpt_ptr_q < CKPT_DEPTH[$clog2(CKPT_DEPTH+1)-1:0])) begin
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (valid_i[p] && is_branch_i[p]) do_ckpt = 1'b1;
      end
    end
  end

  always_comb begin
    map_d = map_q;
    free_d = free_q;
    busy_d = busy_q;
    ckpt_ptr_d = ckpt_ptr_q;
    prs1_o = '0;
    prs2_o = '0;
    prd_o = '0;
    prd_old_o = '0;
    rs1_ready_o = '1;
    rs2_ready_o = '1;
    alloc_prd_c = '0;
    do_alloc = '0;
    stall_c = 1'b0;

    for (int unsigned p = 0; p < NR_PORTS; p++) begin
      automatic logic [PRF_W-1:0] p1, p2, old, picked;
      p1  = (rs1_i[p] == 5'd0) ? '0 : map_d[rs1_i[p]];
      p2  = (rs2_i[p] == 5'd0) ? '0 : map_d[rs2_i[p]];
      old = (rd_i[p] == 5'd0) ? '0 : map_d[rd_i[p]];
      prs1_o[p] = p1;
      prs2_o[p] = p2;
      prd_old_o[p] = old;
      rs1_ready_o[p] = (rs1_i[p] == 5'd0) || !busy_d[p1];
      rs2_ready_o[p] = (rs2_i[p] == 5'd0) || !busy_d[p2];

      if (valid_i[p] && enable_i && need_rd_i[p]) begin
        // free_d already has earlier ports' allocs removed
        picked = pick_free(free_d);
        if (picked == '0) begin
          stall_c = 1'b1;
        end else begin
          do_alloc[p] = 1'b1;
          alloc_prd_c[p] = picked;
          free_d[picked] = 1'b0;
          map_d[rd_i[p]] = picked;
          busy_d[picked] = 1'b1;
          prd_o[p] = picked;
        end
      end else if (valid_i[p] && enable_i) begin
        prd_o[p] = old;
      end
    end

    for (int unsigned p = 1; p < NR_PORTS; p++) begin
      for (int unsigned e = 0; e < p; e++) begin
        if (valid_i[e] && do_alloc[e] && rs1_i[p] == rd_i[e] && rd_i[e] != 5'd0) begin
          prs1_o[p] = alloc_prd_c[e];
          rs1_ready_o[p] = 1'b0;
        end
        if (valid_i[e] && do_alloc[e] && rs2_i[p] == rd_i[e] && rd_i[e] != 5'd0) begin
          prs2_o[p] = alloc_prd_c[e];
          rs2_ready_o[p] = 1'b0;
        end
      end
    end

    for (int unsigned w = 0; w < NR_WB; w++) begin
      if (wb_valid_i[w] && wb_prd_i[w] != '0) busy_d[wb_prd_i[w]] = 1'b0;
    end
    for (int unsigned f = 0; f < NR_FREE; f++) begin
      if (free_i[f] && free_prd_i[f] != '0) free_d[free_prd_i[f]] = 1'b1;
    end

    if (do_ckpt) ckpt_ptr_d = ckpt_ptr_q + 1'b1;

    if (mispredict_i && ckpt_ptr_q != 0) begin
      map_d  = ckpt_map_q[ckpt_ptr_q-1'b1];
      free_d = ckpt_free_q[ckpt_ptr_q-1'b1];
      busy_d = ckpt_busy_q[ckpt_ptr_q-1'b1];
      ckpt_ptr_d = ckpt_ptr_q - 1'b1;
    end

    if (flush_i) begin
      for (int unsigned i = 0; i < 32; i++) map_d[i] = PRF_W'(i);
      free_d = '0;
      for (int unsigned i = 32; i < PRF_ENTRIES; i++) free_d[i] = 1'b1;
      busy_d = '0;
      ckpt_ptr_d = '0;
    end

    stall_o = stall_c;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < 32; i++) map_q[i] <= PRF_W'(i);
      free_q <= '0;
      for (int unsigned i = 32; i < PRF_ENTRIES; i++) free_q[i] <= 1'b1;
      busy_q <= '0;
      ckpt_ptr_q <= '0;
      ckpt_map_q <= '0;
      ckpt_free_q <= '0;
      ckpt_busy_q <= '0;
    end else begin
      map_q <= map_d;
      free_q <= free_d;
      busy_q <= busy_d;
      ckpt_ptr_q <= ckpt_ptr_d;
      if (do_ckpt) begin
        ckpt_map_q[ckpt_ptr_q]  <= map_q;
        ckpt_free_q[ckpt_ptr_q] <= free_q;
        ckpt_busy_q[ckpt_ptr_q] <= busy_q;
      end
    end
  end

endmodule
