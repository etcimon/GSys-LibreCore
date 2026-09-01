// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island capability window (read-only MMIO).
// Authoritative discovery for the island plane — never expressed in aicfg CSRs
// (architecture/ai-matrix/scaling-100tops.md §8, isa-encoding.md §8).
//
// CAP_OFF_DRAM_GBPS packing (I3):
//   [15:0]  nameplate GB/s from IslandCfg.DramGBps (0 = not measured)
//   [31:16] measured milli-GB/s, saturates at 16'hFFFF (>= 65.535 GB/s)
// CAP_OFF_DRAM_MEAS_X1000 (0x2C): full 32-bit milli-GB/s (F14).
// CAP_OFF_CLUSTERS (0x04): [15:0] present, [31:16] enabled (F8).

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
    // I3: last-job measured bandwidth (milli-GB/s); 0 = not yet measured
    input  logic [31:0] dram_gbps_meas_x1000_i,
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
  logic [15:0] meas_milli;

  // Saturate measured milli-GB/s into high half of CAP_DRAM
  assign meas_milli = (dram_gbps_meas_x1000_i > 32'h0000_FFFF)
                    ? 16'hFFFF
                    : dram_gbps_meas_x1000_i[15:0];

  function automatic logic [3:0] lg2u(input int unsigned v);
    return 4'($clog2(v == 0 ? 1 : v));
  endfunction

  always_comb begin
    rdata_n  = '0;
    rvalid_n = 1'b0;
    if (req_i) begin
      rvalid_n = 1'b1;
      unique case (addr_i[15:2])  // word index of CAP_OFF_*
        CAP_OFF_VERSION[15:2]:
          rdata_n = {16'h0, AiIslandCapVersion};
        CAP_OFF_CLUSTERS[15:2]:
          rdata_n = {16'(IslandCfg.ClustersEnabled), 16'(IslandCfg.Clusters)};
        CAP_OFF_MACS_CYCLE[15:2]:
          rdata_n = 32'(IslandCfg.MacsPerCycle);
        CAP_OFF_CLOCK_KHZ[15:2]:
          rdata_n = 32'(IslandCfg.ClockKhz);
        CAP_OFF_SRAM_BYTES[15:2]:
          rdata_n = 32'(IslandCfg.SramBytes);
        // packed log2(M)|log2(N)|log2(K)
        CAP_OFF_BLOCK_MNK[15:2]:
          rdata_n = {20'h0, lg2u(IslandCfg.AccTileK),
                             lg2u(IslandCfg.AccTileN),
                             lg2u(IslandCfg.AccTileM)};
        // nameplate [15:0] | measured milli-GB/s [31:16] (saturates)
        CAP_OFF_DRAM_GBPS[15:2]:
          rdata_n = {meas_milli, 16'(IslandCfg.DramGBps)};
        CAP_OFF_QUEUES[15:2]:
          rdata_n = {16'(IslandCfg.QueueDepth), 16'(IslandCfg.Queues)};
        CAP_OFF_QOS[15:2]:
          rdata_n = 32'(IslandCfg.QosClasses);
        CAP_OFF_QUANTUM[15:2]:
          rdata_n = 32'(IslandCfg.WorkQuantumK);
        CAP_OFF_DTYPE_MASK[15:2]:
          rdata_n = {16'h0, DtypeMask};
        CAP_OFF_DRAM_MEAS_X1000[15:2]:
          rdata_n = dram_gbps_meas_x1000_i;
        CAP_OFF_CLUSTER_EN[15:2]:
          rdata_n = (IslandCfg.ClustersEnabled >= 32) ? 32'hFFFF_FFFF
                    : (32'h1 << IslandCfg.ClustersEnabled) - 32'h1;
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
