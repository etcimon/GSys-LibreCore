// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.1 free list of physical registers (excludes x0 → phys 0 hardwired).

module g6lc_freelist #(
    parameter int unsigned PRF_ENTRIES = 48,
    parameter int unsigned PRF_W       = 6
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic alloc_i,
    output logic [PRF_W-1:0] alloc_prd_o,
    output logic             empty_o,
    input  logic free_i,
    input  logic [PRF_W-1:0] free_prd_i
);

  // Bit-vector free list: bit i set ⇒ phys reg i free. phys 0 always free/hardwired.
  logic [PRF_ENTRIES-1:0] free_q, free_d;
  logic [PRF_W-1:0] pick;

  // Priority encode lowest free phys reg ≥ 1
  always_comb begin
    pick = '0;
    empty_o = 1'b1;
    for (int unsigned i = 1; i < PRF_ENTRIES; i++) begin
      if (free_q[i] && empty_o) begin
        pick = PRF_W'(i);
        empty_o = 1'b0;
      end
    end
  end

  assign alloc_prd_o = pick;

  always_comb begin
    free_d = free_q;
    if (alloc_i && !empty_o) free_d[pick] = 1'b0;
    if (free_i && free_prd_i != '0) free_d[free_prd_i] = 1'b1;
    if (flush_i) begin
      free_d = '1;
      free_d[0] = 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      free_q <= '1;
    end else begin
      free_q <= free_d;
    end
  end

endmodule
