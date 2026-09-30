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
    parameter logic [15:0]    DtypeMask = AiIslandDtypeMask,  // F3: package default
    // CAP_OFF_ACCMODE bit 0 (published and enforced from one top-level value).
    parameter bit             AccumulateEn = AiIslandAccmodeGrant[0],
    // Operand bank bytes (CAP_OFF_BANK_{A,B}_BYTES); 0 = legacy k <= AccTileK box.
    parameter logic [31:0]    BankABytes = 32'd0,
    parameter logic [31:0]    BankBBytes = 32'd0,
    // CAP_OFF_COH bit 0: island DMA writes are invalidated through the cache
    // hierarchy before completion (AiCfg.DmaInvalEn); 0 = software cbo.inval.
    parameter bit             DmaInvalEn = 1'b0
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
    // I3: DRAM backend init/calib (class 0 = 1; class 1 = 0 until LiteDRAM)
    input  logic        dram_init_done_i,
    // S5: SoC DRAM-slave occupancy (cores + L2 + island). Not GEMM PMU.
    input  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats_i,
    input  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_w_beats_i,
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
  // Saturate rather than truncate: a wrapped value would read as a plausible
  // low bandwidth. Software that needs >= 66 GB/s reads CAP_OFF_DRAM_MEAS_X1000.
  assign meas_milli = (dram_gbps_meas_x1000_i > 32'h0000_FFFF)
                    ? 16'hFFFF
                    : dram_gbps_meas_x1000_i[15:0];

  function automatic logic [3:0] lg2u(input int unsigned v);
    return 4'($clog2(v == 0 ? 1 : v));
  endfunction

  always_comb begin
    automatic int unsigned ch_r_idx, ch_w_idx;
    automatic logic        occ_hit;
    rdata_n   = '0;
    rvalid_n  = 1'b0;
    ch_r_idx  = 32'(addr_i[15:2]) - 32'(CAP_OFF_DRAM_CH_R[15:2]);
    ch_w_idx  = 32'(addr_i[15:2]) - 32'(CAP_OFF_DRAM_CH_W[15:2]);
    occ_hit   = 1'b0;
    if (req_i) begin
      rvalid_n = 1'b1;
      if (ch_r_idx < AI_DRAM_MAX_CHANNELS) begin
        rdata_n = ch_r_beats_i[ch_r_idx];
        occ_hit = 1'b1;
      end else if (ch_w_idx < AI_DRAM_MAX_CHANNELS) begin
        rdata_n = ch_w_beats_i[ch_w_idx];
        occ_hit = 1'b1;
      end
      // Occupancy windows are checked first and short-circuit the case: they are
      // two 8-entry ranges, which a flat CAP_OFF_* case would have to spell out
      // as 16 separate arms.
      if (!occ_hit) unique case (addr_i[15:2])  // word index of CAP_OFF_*
        CAP_OFF_COMMAND_QUEUE[15:2]:
          rdata_n = IslandCfg.CommandDepth == 0 ? 32'd0 :
              {16'(IslandCfg.CommandDepth), COMMAND_QUEUE_VERSION, COMMAND_QUEUE_FLAGS};
        CAP_OFF_ACCMODE[15:2]: rdata_n = {31'h0, AccumulateEn};
        CAP_OFF_BANK_A_BYTES[15:2]: rdata_n = BankABytes;
        CAP_OFF_BANK_B_BYTES[15:2]: rdata_n = BankBBytes;
        CAP_OFF_COH[15:2]:          rdata_n = {31'h0, DmaInvalEn};
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
        // packed log2(M)|log2(N)|log2(K) — CAP_BLOCK_*_SHIFT
        CAP_OFF_BLOCK_MNK[15:2]:
          rdata_n = 32'(lg2u(IslandCfg.AccTileK)) << CAP_BLOCK_K_SHIFT
                  | 32'(lg2u(IslandCfg.AccTileN)) << CAP_BLOCK_N_SHIFT
                  | 32'(lg2u(IslandCfg.AccTileM)) << CAP_BLOCK_M_SHIFT;
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
        CAP_OFF_DRAM_CLASS[15:2]:
          rdata_n = 32'(IslandCfg.DramClass);
        CAP_OFF_DRAM_CHANS[15:2]:
          rdata_n = 32'(IslandCfg.DramChanShift) << CAP_CHANS_SHIFT_SHIFT
                  | 32'(IslandCfg.DramChannels)  << CAP_CHANS_COUNT_SHIFT;
        CAP_OFF_NOC_WIDTH[15:2]:
          rdata_n = 32'(IslandCfg.NocWidth);
        CAP_OFF_MAX_AR_OUT[15:2]:
          rdata_n = 32'(IslandCfg.MaxAROut);
        CAP_OFF_DRAM_TIMING[15:2]:
          rdata_n = 32'(IslandCfg.DramTrp)  << CAP_TIMING_TRP_SHIFT
                  | 32'(IslandCfg.DramTrcd) << CAP_TIMING_TRCD_SHIFT
                  | 32'(IslandCfg.DramCas)  << CAP_TIMING_CAS_SHIFT;
        CAP_OFF_DRAM_STATUS[15:2]:
          rdata_n = {30'h0,
                     (IslandCfg.DramCas != 0),
                     dram_init_done_i};
        // AI-X9: operand layout, so software discovers that B is k-major rather
        // than inferring it from a contract version it may never read.
        CAP_OFF_LAYOUT[15:2]:
          rdata_n = AiIslandLayoutWord;
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
