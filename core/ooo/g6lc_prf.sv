// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.1 physical register file. Multi-port FF bank; phys 0 hardwired zero.
// Write-through bypass: same-cycle writes visible on reads (production opt).

module g6lc_prf #(
    parameter int unsigned DATA_WIDTH  = 64,
    parameter int unsigned PRF_ENTRIES = 48,
    parameter int unsigned NR_READ     = 4,
    parameter int unsigned NR_WRITE    = 2,
    parameter int unsigned PRF_W       = 6
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic [NR_READ-1:0][PRF_W-1:0]      raddr_i,
    output logic [NR_READ-1:0][DATA_WIDTH-1:0] rdata_o,
    input  logic [NR_WRITE-1:0][PRF_W-1:0]     waddr_i,
    input  logic [NR_WRITE-1:0][DATA_WIDTH-1:0] wdata_i,
    input  logic [NR_WRITE-1:0]                we_i
);

  logic [PRF_ENTRIES-1:0][DATA_WIDTH-1:0] mem_q;

  // Combinational read with write-through (highest write port wins on clash)
  always_comb begin
    for (int unsigned r = 0; r < NR_READ; r++) begin
      if (raddr_i[r] == '0) begin
        rdata_o[r] = '0;
      end else begin
        rdata_o[r] = mem_q[raddr_i[r]];
        for (int unsigned w = 0; w < NR_WRITE; w++) begin
          if (we_i[w] && waddr_i[w] == raddr_i[r] && waddr_i[w] != '0)
            rdata_o[r] = wdata_i[w];
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_q <= '0;
    end else begin
      for (int unsigned w = 0; w < NR_WRITE; w++) begin
        if (we_i[w] && waddr_i[w] != '0) mem_q[waddr_i[w]] <= wdata_i[w];
      end
    end
  end

endmodule
