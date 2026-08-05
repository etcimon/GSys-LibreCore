// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal against live multi-port `g6lc_rename` (free/busy/map + bypass).
// Small PRF and 2 dispatch ports keep the BMC cone tractable.
//
// Run: sby -f core/ooo/formal/g6lc_ooo_rename.sby
//      cva6-build verify --formal

module g6lc_ooo_rename_props #(
    parameter int unsigned PRF_ENTRIES = 16,
    parameter int unsigned PRF_W       = $clog2(PRF_ENTRIES),
    parameter int unsigned NR_PORTS    = 2,
    parameter int unsigned NR_FREE     = 1,
    parameter int unsigned NR_WB       = 1,
    parameter int unsigned CKPT_DEPTH  = 2
) (
    input logic                             clk_i,
    input logic                             rst_ni,
    input logic                             flush_i,
    input logic                             mispredict_i,
    input logic [NR_PORTS-1:0]              valid_i,
    input logic [NR_PORTS-1:0][4:0]         rs1_i,
    input logic [NR_PORTS-1:0][4:0]         rs2_i,
    input logic [NR_PORTS-1:0][4:0]         rd_i,
    input logic [NR_PORTS-1:0]              need_rd_i,
    input logic [NR_PORTS-1:0]              is_branch_i,
    input logic [NR_WB-1:0]                 wb_valid_i,
    input logic [NR_WB-1:0][PRF_W-1:0]      wb_prd_i,
    input logic [NR_FREE-1:0]               free_i,
    input logic [NR_FREE-1:0][PRF_W-1:0]    free_prd_i,
    input logic                             enable_i
);

`ifdef FORMAL
  logic [NR_PORTS-1:0][PRF_W-1:0] prs1_o, prs2_o, prd_o, prd_old_o;
  logic [NR_PORTS-1:0]            rs1_ready_o, rs2_ready_o;
  logic                           stall_o;

  g6lc_rename #(
      .PRF_ENTRIES(PRF_ENTRIES),
      .PRF_W      (PRF_W),
      .NR_PORTS   (NR_PORTS),
      .NR_FREE    (NR_FREE),
      .NR_WB      (NR_WB),
      .CKPT_DEPTH (CKPT_DEPTH)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,
      .mispredict_i,
      .valid_i,
      .rs1_i,
      .rs2_i,
      .rd_i,
      .need_rd_i,
      .is_branch_i,
      .prs1_o,
      .prs2_o,
      .prd_o,
      .prd_old_o,
      .rs1_ready_o,
      .rs2_ready_o,
      .stall_o,
      .wb_valid_i,
      .wb_prd_i,
      .free_i,
      .free_prd_i,
      .enable_i
  );

  initial assume (!rst_ni);

  // Environment constraints for a legal rename stream.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        // x0 never needs a destination phys reg.
        assume (!(need_rd_i[p] && (rd_i[p] == 5'd0)));
        // Contiguous program-order valids: port 1 only if port 0 valid.
        if (p > 0) assume (!(valid_i[p] && !valid_i[0]));
      end
      for (int unsigned w = 0; w < NR_WB; w++)
        assume (wb_prd_i[w] < PRF_ENTRIES[PRF_W-1:0]);
      for (int unsigned f = 0; f < NR_FREE; f++)
        assume (free_prd_i[f] < PRF_ENTRIES[PRF_W-1:0]);
      // Free only non-zero phys (matches RTL guard free_prd != 0).
      for (int unsigned f = 0; f < NR_FREE; f++)
        assume (!(free_i[f] && free_prd_i[f] == '0));
      // Single-sided recovery: no simultaneous flush + mispredict.
      assume (!(flush_i && mispredict_i));
    end
  end

  // --- Live RTL invariants (hierarchical free/busy/map) ---
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Free and busy are exclusive for every phys reg.
      assert ((dut.free_q & dut.busy_q) == '0);
      // Checkpoint pointer stays in range [0, CKPT_DEPTH].
      assert (dut.ckpt_ptr_q <= CKPT_DEPTH[$clog2(CKPT_DEPTH+1)-1:0]);
      // x0 stays identity phys 0.
      assert (dut.map_q[0] == '0);
      // Successful dest alloc never returns phys 0.
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (enable_i && valid_i[p] && need_rd_i[p] && !stall_o)
          assert (prd_o[p] != '0);
      end
      // Same-cycle bypass: younger port sees older port's new mapping.
      if (NR_PORTS >= 2) begin
        if (enable_i && valid_i[0] && valid_i[1] && need_rd_i[0] && !stall_o &&
            (rd_i[0] != 5'd0) && (rs1_i[1] == rd_i[0]))
          assert (prs1_o[1] == prd_o[0]);
        if (enable_i && valid_i[0] && valid_i[1] && need_rd_i[0] && !stall_o &&
            (rd_i[0] != 5'd0) && (rs2_i[1] == rd_i[0]))
          assert (prs2_o[1] == prd_o[0]);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (enable_i && valid_i[0] && need_rd_i[0] && !stall_o);
      cover (NR_PORTS >= 2 && enable_i && valid_i[0] && valid_i[1] && need_rd_i[0] &&
             need_rd_i[1] && !stall_o);
      cover (stall_o);
      cover (mispredict_i && dut.ckpt_ptr_q != 0);
    end
  end
`endif

endmodule
