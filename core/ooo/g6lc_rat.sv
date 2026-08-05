// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.1 Register Alias Table (architectural → physical).
// Checkpoint/restore on mispredict is the recovery path for full OoO.
// When DEPTH==32 and unused, this is a thin identity map (p = arch).

module g6lc_rat #(
    parameter int unsigned NR_ARCH = 32,
    parameter int unsigned PRF_W   = 6,   // $clog2(PrfEntries)
    parameter int unsigned CKPT_DEPTH = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // Lookup
    input  logic [4:0] rs1_i,
    input  logic [4:0] rs2_i,
    input  logic [4:0] rd_i,
    output logic [PRF_W-1:0] prs1_o,
    output logic [PRF_W-1:0] prs2_o,
    output logic [PRF_W-1:0] prd_old_o,  // previous mapping of rd (for freelist)
    // Allocate / commit rename
    input  logic             alloc_i,
    input  logic [PRF_W-1:0] alloc_prd_i,
    // Checkpoint
    input  logic             ckpt_push_i,
    input  logic             ckpt_restore_i,
    output logic             ckpt_empty_o
);

  logic [NR_ARCH-1:0][PRF_W-1:0] map_q, map_d;
  // Checkpoint stack of full maps (area: only when CKPT_DEPTH>0)
  logic [CKPT_DEPTH-1:0][NR_ARCH-1:0][PRF_W-1:0] ckpt_q;
  logic [$clog2(CKPT_DEPTH+1)-1:0] ckpt_ptr_q, ckpt_ptr_d;

  assign prs1_o    = map_q[rs1_i];
  assign prs2_o    = map_q[rs2_i];
  assign prd_old_o = map_q[rd_i];
  assign ckpt_empty_o = (ckpt_ptr_q == '0);

  always_comb begin
    map_d = map_q;
    ckpt_ptr_d = ckpt_ptr_q;
    if (alloc_i && rd_i != 5'd0) begin
      map_d[rd_i] = alloc_prd_i;
    end
    if (ckpt_push_i && ckpt_ptr_q < CKPT_DEPTH[$clog2(CKPT_DEPTH+1)-1:0]) begin
      ckpt_ptr_d = ckpt_ptr_q + 1'b1;
    end
    if (ckpt_restore_i && ckpt_ptr_q != 0) begin
      map_d = ckpt_q[ckpt_ptr_q-1'b1];
      ckpt_ptr_d = ckpt_ptr_q - 1'b1;
    end
    if (flush_i) begin
      for (int unsigned i = 0; i < NR_ARCH; i++) map_d[i] = PRF_W'(i);
      ckpt_ptr_d = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < NR_ARCH; i++) map_q[i] <= PRF_W'(i);
      ckpt_ptr_q <= '0;
      ckpt_q <= '0;
    end else begin
      map_q <= map_d;
      ckpt_ptr_q <= ckpt_ptr_d;
      if (ckpt_push_i && ckpt_ptr_q < CKPT_DEPTH[$clog2(CKPT_DEPTH+1)-1:0])
        ckpt_q[ckpt_ptr_q] <= map_q;
    end
  end

endmodule
