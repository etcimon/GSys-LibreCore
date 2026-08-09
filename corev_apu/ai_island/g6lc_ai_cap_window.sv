// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island capability window (read-only MMIO).
// Authoritative discovery for the island plane — never expressed in aicfg CSRs
// (architecture/ai-matrix/scaling-100tops.md §8, isa-encoding.md §8).

module g6lc_ai_cap_window
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter ai_island_cfg_t IslandCfg = AiIslandLatencyDefault,
    parameter logic [15:0]    DtypeMask = 16'h0001  // bit0 = s8 dense
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    // Simple reg port (word-addressed, 32-bit). Writes ignored (RO).
    input  logic        req_i,
    input  logic        we_i,
    input  logic [15:0] addr_i,   // byte offset
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        rvalid_o
);

  // verilator lint_off UNUSEDSIGNAL
  logic _unused;
  assign _unused = ^{clk_i, rst_ni, we_i, wdata_i};
  // verilator lint_on UNUSEDSIGNAL

  logic [31:0] rdata_n;
  logic        rvalid_n, rvalid_q;
  logic [31:0] rdata_q;

  function automatic logic [3:0] lg2u(input int unsigned v);
    return 4'($clog2(v == 0 ? 1 : v));
  endfunction

  always_comb begin
    rdata_n  = '0;
    rvalid_n = 1'b0;
    if (req_i) begin
      rvalid_n = 1'b1;
      unique case (addr_i[15:2])  // word index
        // CAP_OFF_VERSION / 4
        14'h00: rdata_n = {16'h0, AiIslandCapVersion};
        14'h01: rdata_n = 32'(IslandCfg.Clusters);
        14'h02: rdata_n = 32'(IslandCfg.MacsPerCycle);
        14'h03: rdata_n = 32'(IslandCfg.ClockKhz);
        14'h04: rdata_n = 32'(IslandCfg.SramBytes);
        // packed log2(M)|log2(N)|log2(K)
        14'h05: rdata_n = {20'h0, lg2u(IslandCfg.AccTileK),
                                   lg2u(IslandCfg.AccTileN),
                                   lg2u(IslandCfg.AccTileM)};
        14'h06: rdata_n = 32'(IslandCfg.DramGBps);
        14'h07: rdata_n = {16'(IslandCfg.QueueDepth), 16'(IslandCfg.Queues)};
        14'h08: rdata_n = 32'(IslandCfg.QosClasses);
        14'h09: rdata_n = 32'(IslandCfg.WorkQuantumK);
        14'h0A: rdata_n = {16'h0, DtypeMask};
        default: rdata_n = 32'h0;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_q  <= '0;
      rvalid_q <= 1'b0;
    end else begin
      rdata_q  <= rdata_n;
      rvalid_q <= rvalid_n;
    end
  end

  assign rdata_o  = rdata_q;
  assign rvalid_o = rvalid_q;

endmodule
