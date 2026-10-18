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
    parameter int unsigned PRF_W       = 6,
    parameter bit ZERO_REG_ZERO = 1'b1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic [NR_READ-1:0][PRF_W-1:0]      raddr_i,
    output logic [NR_READ-1:0][DATA_WIDTH-1:0] rdata_o,
    input  logic [NR_WRITE-1:0][PRF_W-1:0]     waddr_i,
    input  logic [NR_WRITE-1:0][DATA_WIDTH-1:0] wdata_i,
    input  logic [NR_WRITE-1:0]                we_i
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_prf status=proposal target=10-adjusted-FO4
  // svt-plan: cone combinational mem_q read plus CURRENT write-through;
  // highest write port wins. Reads are not registered in this module.
  // svt-plan: boundary accepted write packets -> bank-local write decode;
  // keep banked read selection and bypass in parallel.
  // svt-plan: bypass priority current writes > newest pending writes >
  // mem_q, highest port within each cycle; ZERO_REG_ZERO overrides all.
  // svt-plan: carry we/address/data and relative write age; capture the
  // entire NR_WRITE group each cycle or add upstream completion backpressure.
  // svt-plan: ownership physical-register recycling must not let a delayed
  // older write win over a new owner; preserve ordering at the write acceptance seam.
  // svt-plan: effect separates long write transport from array decode;
  // read banking reduces mux fan-in but extra bypass comparisons can dominate.
  // svt-plan: cost write packet registers and per-read comparisons; a
  // bounded one-cycle pending window avoids growing the bypass priority chain.
  // svt-plan: limit no local valid/ready or generation ports exist; adding
  // read latency needs coordinated IQ/operand scheduling, not only this file.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 65.2 adjusted FO4 on the
  // Nangate45 board): physical register file: write ports into mem_q; a stage is a bypass-network change.
  // svt-pipe: require-contract
  // svt-pipe: no-cut on=mem_q

  logic [PRF_ENTRIES-1:0][DATA_WIDTH-1:0] mem_q;

  // Combinational read with write-through (highest write port wins on clash)
  always_comb begin
    for (int unsigned r = 0; r < NR_READ; r++) begin
      if (ZERO_REG_ZERO && raddr_i[r] == '0) begin
        rdata_o[r] = '0;
      end else begin
        rdata_o[r] = mem_q[raddr_i[r]];
        for (int unsigned w = 0; w < NR_WRITE; w++) begin
          if (we_i[w] && waddr_i[w] == raddr_i[r] && (!ZERO_REG_ZERO || waddr_i[w] != '0))
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
        if (we_i[w] && (!ZERO_REG_ZERO || waddr_i[w] != '0)) mem_q[waddr_i[w]] <= wdata_i[w];
      end
    end
  end

endmodule
