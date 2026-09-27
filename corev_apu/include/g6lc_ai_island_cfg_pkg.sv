// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island (T2) configuration package — uncore plane.
//
// Island knobs do NOT live in cva6_cfg_t (architecture/ai-matrix/scaling-100tops.md
// §8). This package is the single home for cluster count, MACs/cycle, SRAM
// budgets, NoC width and DRAM class. The core-attached plane stays on
// config_pkg::ai_cfg_t.
//
// Status: P3 + I1-lite live (island on flist when MatrixEn).
// gemm_seq PeLanes binds from MacsPerCycle. MaxM/N/K bind from AccTileM/N/K.

package g6lc_ai_island_cfg_pkg;

  // Capability-window contract version (MMIO BAR0 + DTS g6lc,ai-matrix).
  localparam logic [15:0] AiIslandCapVersion = 16'd1;

  // Named DRAM classes (DramClass field / CAP_OFF_DRAM_CLASS).
  localparam int unsigned AI_DRAM_SIM_AXI = 0;  // testharness AXI SRAM; I3-lite
  localparam int unsigned AI_DRAM_DDR4    = 1;  // LiteDRAM at xbar; I3
  localparam int unsigned AI_DRAM_LPDDR5  = 2;  // SKU target only
  // Class-2 nameplate. A rate socket may advertise it. It is not a measured PHY.
  localparam int unsigned AI_DRAM_LPDDR5_GBPS = 400;
  // DDR4-2400 ×64 peak = 2400e6 × 8 B/s = 19.2 GB/s → integer nameplate 19.
  // Board DIMM class only — not a measurement, not the 400 GB/s LPDDR5 SKU.
  localparam int unsigned AI_DRAM_DDR4_2400_X64_GBPS = 19;
  // Independent DRAM controllers (not island I2 clusters). Power of two.
  localparam int unsigned AI_DRAM_MAX_CHANNELS = 8;
  // 64-byte stripe LSB (64-bit beat → bits [2:0] byte; [5:3] in-line).
  localparam int unsigned AI_DRAM_CHAN_SHIFT_DEFAULT = 6;
  localparam int unsigned AI_MAX_AR_OUT_LIVE = 2;
  localparam int unsigned AI_MAX_AR_OUT_DRAM = 8;
  // DDR4-2400 CL16 ≈ 13.3 ns → 14 cycles on the 1 GHz island clock.
  localparam int unsigned AI_DRAM_DDR4_CAS_CY  = 14;
  localparam int unsigned AI_DRAM_DDR4_TRCD_CY = 14;
  localparam int unsigned AI_DRAM_DDR4_TRP_CY  = 14;

  // Elaborated INT8 MAC/cycle of the live island. gemm_seq PeLanes takes
  // this value. The accumulator box is AI_PANEL_* below, so the next MAC
  // width is still this localparam and does not by itself resize M or N.
  // VaTurboEn does not multiply it: that flag only enables operand reuse,
  // which adds no lanes.
  localparam int unsigned AI_LIVE_MACS = 512;
  // Bounding box of the live panels. MAC issue width stays AI_LIVE_MACS.
  // VA residency keys are (m,k) for A and (n,k) for B, so these three
  // output shapes do not alias each other:
  //   512×512, 512×256, 1024×128. K of each panel is still <= 512.
  localparam int unsigned AI_PANEL_M = 1024;
  localparam int unsigned AI_PANEL_N = 512;
  localparam int unsigned AI_PANEL_K = 512;

  // NoC peak GB/s = (width_bytes) × (clock GHz). Live 64-bit @ 1 GHz → 8.
  function automatic int unsigned noc_peak_gbps(
      input int unsigned noc_bits, input int unsigned clock_khz
  );
    return (noc_bits / 8) * (clock_khz / 1_000_000);
  endfunction

  // DDR4-2400×64 nameplate scales linearly with independent channels.
  function automatic int unsigned ddr4_nameplate_gbps(input int unsigned nch);
    return nch * AI_DRAM_DDR4_2400_X64_GBPS;
  endfunction

  // Published DRAM nameplate in GB/s. Not a measured PHY rate.
  // Class 0 is the NoC peak (width_bytes × clock_GHz). Extra class-0 stripes
  // do not multiply it. Class 1 is N × 19. Class 2 is the 400 GB/s constant.
  function automatic int unsigned dram_nameplate_gbps(
      input int unsigned noc_bits,
      input int unsigned clock_khz,
      input int unsigned nch,
      input int unsigned dram_class
  );
    if (dram_class == AI_DRAM_SIM_AXI)
      return noc_peak_gbps(noc_bits, clock_khz);
    if (dram_class == AI_DRAM_DDR4)
      return ddr4_nameplate_gbps(nch);
    if (dram_class == AI_DRAM_LPDDR5)
      return AI_DRAM_LPDDR5_GBPS;
    return 0;
  endfunction

  // Project a class-0 nameplate by integer width and clock multipliers.
  // Class 1 and class 2 ignore those multipliers, so 19 stays N×19 and 400
  // stays 400. A zero multiplier is not a nameplate.
  function automatic int unsigned bumped_dram_gbps(
      input int unsigned noc_bits,
      input int unsigned clock_khz,
      input int unsigned nch,
      input int unsigned dram_class,
      input int unsigned width_mul,
      input int unsigned clock_mul
  );
    if (width_mul == 0 || clock_mul == 0)
      return 0;
    if (dram_class != AI_DRAM_SIM_AXI)
      return dram_nameplate_gbps(noc_bits, clock_khz, nch, dram_class);
    return dram_nameplate_gbps(
        noc_bits * width_mul, clock_khz * clock_mul, nch, dram_class);
  endfunction

  function automatic bit dram_channels_ok(input int unsigned nch);
    return (nch >= 1) && (nch <= AI_DRAM_MAX_CHANNELS)
        && ((nch & (nch - 1)) == 0);
  endfunction

  // True iff an INCR burst of nbytes starting at addr stays in one stripe.
  // N=1 is a single slave: every burst fits (core I$/D$/L2 and GEMM identity).
  function automatic bit dram_burst_fits_stripe(
      input int unsigned nch,
      input int unsigned shift,
      input logic [63:0] addr,
      input int unsigned nbytes
  );
    int unsigned stripe, off;
    if (nch <= 1) return 1'b1;
    if (shift < 3 || shift > 16) return 1'b0;
    stripe = unsigned'(1) << shift;
    off    = unsigned'(addr[31:0]) & (stripe - unsigned'(1));
    return (off + nbytes) <= stripe;
  endfunction

  // Max AXI beats that fit in the current stripe. N=1 → 255 (AXI4 cap),
  // so GEMM MaxBurstBeats is unchanged on the live fixture.
  function automatic int unsigned dram_beats_in_stripe(
      input int unsigned nch,
      input int unsigned shift,
      input int unsigned beat_bytes,
      input logic [63:0] addr
  );
    int unsigned stripe, off, rem, maxb;
    if (nch <= 1) return unsigned'(255);
    if (beat_bytes == 0) return unsigned'(1);
    stripe = unsigned'(1) << shift;
    off    = unsigned'(addr[31:0]) & (stripe - unsigned'(1));
    rem    = stripe - off;
    maxb   = rem / beat_bytes;
    if (maxb == 0) maxb = unsigned'(1);
    if (maxb > unsigned'(255)) maxb = unsigned'(255);
    return maxb;
  endfunction

  // Element width in bytes. INT4 is packed two-per-byte, so a row uses
  // ai_row_bytes. Must stay in step with g6lc_ai_gemm_seq's loader.
  function automatic logic [31:0] ai_elem_bytes(input logic [2:0] fmt);
    if (fmt inside {3'd5, 3'd6}) return 32'd2;
    else if (fmt == 3'd7) return 32'd4;
    else return 32'd1;
  endfunction

  function automatic logic [31:0] ai_row_bytes(input logic [2:0] fmt,
                                               input logic [31:0] elems);
    if (fmt == 3'd1) return (elems + 32'd1) >> 1;
    else return elems * ai_elem_bytes(fmt);
  endfunction

  // Bytes touched by `rows` rows. The last row is `tail_elems` long; earlier
  // rows use `stride_elems`. A product that does not fit saturates so the
  // region check fails closed.
  function automatic logic [63:0] ai_operand_span(
      input logic [31:0] rows, stride_elems, tail_elems,
      input logic [2:0] fmt);
    logic [63:0] stride_b, tail_b, n, prod;
    if (rows == 0) return 64'd1;
    stride_b = 64'(ai_row_bytes(fmt, stride_elems));
    tail_b   = 64'(ai_row_bytes(fmt, tail_elems));
    n        = 64'(rows) - 64'd1;
    if (stride_b != 0 && n > ({64{1'b1}} / stride_b))
      return {64{1'b1}};
    prod = n * stride_b;
    if (tail_b > ({64{1'b1}} - prod))
      return {64{1'b1}};
    prod = prod + tail_b;
    if (prod == 0) return 64'd1;
    return prod;
  endfunction

  // C is packed i32, ldc = n.
  function automatic logic [63:0] ai_result_span(
      input logic [31:0] rows, cols);
    logic [63:0] bytes;
    if (rows == 0 || cols == 0) return 64'd1;
    if (64'(rows) > ({64{1'b1}} / 64'(cols)))
      return {64{1'b1}};
    bytes = 64'(rows) * 64'(cols);
    if (bytes > ({64{1'b1}} >> 2))
      return {64{1'b1}};
    return bytes << 2;
  endfunction

  function automatic bit ai_elem_aligned(input logic [63:0] addr,
                                         input logic [2:0] fmt);
    if (fmt inside {3'd5, 3'd6}) return addr[0] == 1'b0;
    else if (fmt == 3'd7) return addr[1:0] == 2'b0;
    else return 1'b1;
  endfunction

  // Even n stores 8-byte pairs. Odd n stores 4-byte words.
  function automatic bit ai_c_aligned(input logic [63:0] addr,
                                      input logic n_odd);
    if (n_odd) return addr[1:0] == 2'b0;
    else return addr[2:0] == 3'b0;
  endfunction

  function automatic bit ai_completion_aligned(input logic [63:0] addr);
    return addr[2:0] == 3'b0;
  endfunction

  // A/B loads use one full-bus beat. The region check has to cover that beat,
  // including bytes before a misaligned pointer and after the last element.
  function automatic logic [63:0] ai_beat_lo(input logic [63:0] addr,
                                             input int unsigned beat);
    if (beat <= 1) return addr;
    if ((beat & (beat - 1)) != 0) return 64'd0;
    return addr & ~(64'(beat) - 64'd1);
  endfunction

  function automatic logic [63:0] ai_bus_len(
      input logic [63:0] addr,
      input logic [63:0] nbytes,
      input int unsigned beat);
    logic [63:0] lo, last, mask, hi;
    if (nbytes == 0 || nbytes == {64{1'b1}}) return {64{1'b1}};
    if (beat <= 1) return nbytes;
    if ((beat & (beat - 1)) != 0) return {64{1'b1}};
    if ((nbytes - 64'd1) > ({64{1'b1}} - addr)) return {64{1'b1}};
    lo   = ai_beat_lo(addr, beat);
    last = addr + nbytes - 64'd1;
    mask = 64'(beat) - 64'd1;
    if ((last | mask) == {64{1'b1}}) return {64{1'b1}};
    hi = (last | mask) + 64'd1;
    return hi - lo;
  endfunction

  // Frozen at I1 for both latency and throughput SKUs (scaling-100tops.md §5.1).
  typedef struct packed {
    int unsigned Clusters;       // replication unit (1 for latency SKU)
    int unsigned MacsPerCycle;   // per-cluster dense INT8 MAC/cycle
    int unsigned ClockKhz;       // island clock
    int unsigned SramBytes;      // per-cluster staging + weight SRAM
    int unsigned AccTileM;       // island blocking T row (not core tile)
    int unsigned AccTileN;
    int unsigned AccTileK;
    int unsigned NocWidth;       // bits
    int unsigned DramChannels;   // independent DRAM controllers (1,2,4,8)
    int unsigned DramChanShift;  // addr LSB of channel select (stripe)
    int unsigned DramGBps;       // nameplate aggregate (= chans × per-channel)
    int unsigned DramClass;      // 0=sim AXI (I3-lite), 1=DDR4, 2=LPDDR5 SKU
    int unsigned Queues;         // T2 rings visible to the island
    int unsigned QueueDepth;
    int unsigned QosClasses;
    int unsigned WorkQuantumK;   // preemption boundary in k-steps
    int unsigned MaxAROut;       // I3: GEMM multi-outstanding AR/AW (live=2; DDR4≤8)
    int unsigned DramCas;        // I3: island-DMA CL (0 = bypass; DDR4-2400 ≈ 14 @ 1 GHz)
    int unsigned DramTrcd;       // I3: tRCD cycles (0 = bypass)
    int unsigned DramTrp;        // I3: tRP cycles (0 = bypass)
    int unsigned ClustersEnabled; // F8: enabled count; == Clusters until I2 gating
  } ai_island_cfg_t;

  // I1 live RTL: PeLanes = AI_LIVE_MACS. The accumulator box is
  // AI_PANEL_M × AI_PANEL_N × AI_PANEL_K, which holds the VA panels
  // 512×512, 512×256 and 1024×128. Multi-bank C is j%PeLanes.
  // gemm_seq binds MaxM/N/K and PeLanes from those fields.
  // I3-lite: multi-beat AR/AW + B oct-drain + trail C-store + multi-out AR + PMU→CAP; NoC 64.
  // ClockKhz 2_000_000 is the published nameplate. The port is still 8 bytes/cycle.
  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(AI_LIVE_MACS),  // PeLanes = AccTileK
      ClockKhz:     unsigned'(2_000_000),     // nameplate; noc peak = 16 GB/s
      SramBytes:    unsigned'(4 * 1024 * 1024),
      AccTileM:     unsigned'(AI_PANEL_M),
      AccTileN:     unsigned'(AI_PANEL_N),
      AccTileK:     unsigned'(AI_PANEL_K),
      NocWidth:     unsigned'(64),
      DramChannels: unsigned'(1),
      DramChanShift: unsigned'(AI_DRAM_CHAN_SHIFT_DEFAULT),
      DramGBps:     unsigned'(16),            // dram_nameplate_gbps(64, 2 GHz, class 0)
      DramClass:    unsigned'(AI_DRAM_SIM_AXI),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64),
      MaxAROut:     unsigned'(AI_MAX_AR_OUT_LIVE),
      DramCas:      unsigned'(0),
      DramTrcd:     unsigned'(0),
      DramTrp:      unsigned'(0),
      ClustersEnabled: unsigned'(1)
  };

  // I3-lite + DDR4 page-command latency on island DMA only. Still DramClass=0
  // (testharness SRAM backing, nameplate = NoC 8 GB/s). Not LiteDRAM. Selected
  // in the testharness with +define+G6LC_AI_DRAM_TIMING (default off).
  localparam ai_island_cfg_t AiIslandDdr4TimingSim = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(AI_LIVE_MACS),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(4 * 1024 * 1024),
      AccTileM:     unsigned'(AI_PANEL_M),
      AccTileN:     unsigned'(AI_PANEL_N),
      AccTileK:     unsigned'(AI_PANEL_K),
      NocWidth:     unsigned'(64),
      DramChannels: unsigned'(1),
      DramChanShift: unsigned'(AI_DRAM_CHAN_SHIFT_DEFAULT),
      DramGBps:     unsigned'(8),
      DramClass:    unsigned'(AI_DRAM_SIM_AXI),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64),
      MaxAROut:     unsigned'(AI_MAX_AR_OUT_DRAM),
      DramCas:      unsigned'(AI_DRAM_DDR4_CAS_CY),
      DramTrcd:     unsigned'(AI_DRAM_DDR4_TRCD_CY),
      DramTrp:      unsigned'(AI_DRAM_DDR4_TRP_CY),
      ClustersEnabled: unsigned'(1)
  };

  // I3 DRAM bringup target (not live). Flip testharness DramClass to this
  // only after `vendor sync litedram` fills g6lc_ai_dram_backend class 1.
  // Nameplate is DDR4-2400 x64 peak, not the 8 GB/s NoC number and not 400.
  localparam ai_island_cfg_t AiIslandDdr4Bringup = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(AI_LIVE_MACS),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(4 * 1024 * 1024),
      AccTileM:     unsigned'(AI_PANEL_M),
      AccTileN:     unsigned'(AI_PANEL_N),
      AccTileK:     unsigned'(AI_PANEL_K),
      NocWidth:     unsigned'(64),            // live xbar still 64-bit
      DramChannels: unsigned'(1),
      DramChanShift: unsigned'(AI_DRAM_CHAN_SHIFT_DEFAULT),
      DramGBps:     unsigned'(AI_DRAM_DDR4_2400_X64_GBPS),
      DramClass:    unsigned'(AI_DRAM_DDR4),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64),
      MaxAROut:     unsigned'(AI_MAX_AR_OUT_DRAM),
      DramCas:      unsigned'(AI_DRAM_DDR4_CAS_CY),
      DramTrcd:     unsigned'(AI_DRAM_DDR4_TRCD_CY),
      DramTrp:      unsigned'(AI_DRAM_DDR4_TRP_CY),
      ClustersEnabled: unsigned'(1)
  };

  // Two independent DDR4-2400×64 controllers (38 GB/s nameplate). Not live.
  // Same AccTile/NoC as 1-channel bringup; bandwidth scales with DramChannels.
  localparam ai_island_cfg_t AiIslandDdr4x2Bringup = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(AI_LIVE_MACS),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(4 * 1024 * 1024),
      AccTileM:     unsigned'(AI_PANEL_M),
      AccTileN:     unsigned'(AI_PANEL_N),
      AccTileK:     unsigned'(AI_PANEL_K),
      NocWidth:     unsigned'(64),
      DramChannels: unsigned'(2),
      DramChanShift: unsigned'(AI_DRAM_CHAN_SHIFT_DEFAULT),
      DramGBps:     unsigned'(2 * AI_DRAM_DDR4_2400_X64_GBPS),
      DramClass:    unsigned'(AI_DRAM_DDR4),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64),
      MaxAROut:     unsigned'(AI_MAX_AR_OUT_DRAM),
      DramCas:      unsigned'(AI_DRAM_DDR4_CAS_CY),
      DramTrcd:     unsigned'(AI_DRAM_DDR4_TRCD_CY),
      DramTrp:      unsigned'(AI_DRAM_DDR4_TRP_CY),
      ClustersEnabled: unsigned'(1)
  };

  // Four/eight independent DDR4-2400×64 controllers (76 / 152 GB/s). Not live.
  localparam ai_island_cfg_t AiIslandDdr4x4Bringup =
      island_cfg_with_channels(AiIslandDdr4Bringup, unsigned'(4));
  localparam ai_island_cfg_t AiIslandDdr4x8Bringup =
      island_cfg_with_channels(AiIslandDdr4Bringup, unsigned'(8));

  // Non-default throughput cluster. Not the live package.
  // 8 × 4096 MAC/cycle at 1.5 GHz is the 98.3 TOPS sketch. AccTileK matches
  // MacsPerCycle so the island_top bound holds. DramClass 2 names the rate
  // socket. The live default stays class 0, one AI_LIVE_MACS cluster, a
  // 64-bit port, and a 2 GHz nameplate (16 GB/s, still 8 bytes/cycle).
  localparam ai_island_cfg_t AiIslandThroughputSku = '{
      Clusters:     unsigned'(8),
      MacsPerCycle: unsigned'(4096),
      ClockKhz:     unsigned'(1_500_000),
      SramBytes:    unsigned'(2 * 1024 * 1024),
      AccTileM:     unsigned'(4096),
      AccTileN:     unsigned'(4096),
      AccTileK:     unsigned'(4096),
      NocWidth:     unsigned'(512),
      DramChannels: unsigned'(1),
      DramChanShift: unsigned'(AI_DRAM_CHAN_SHIFT_DEFAULT),
      DramGBps:     unsigned'(AI_DRAM_LPDDR5_GBPS),
      DramClass:    unsigned'(AI_DRAM_LPDDR5),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64),
      MaxAROut:     unsigned'(AI_MAX_AR_OUT_DRAM),
      DramCas:      unsigned'(0),
      DramTrcd:     unsigned'(0),
      DramTrp:      unsigned'(0),
      ClustersEnabled: unsigned'(8)
  };

  // Fast-cluster format grant: every ISA code except structured 2:4.
  // The live PE mask stays INT8|INT4. This mask is for g6lc_ai_cluster_set.
  localparam logic [15:0] AiIslandFastDtypeMask = 16'h00fb;
  // Elaborated multiplier count of g6lc_ai_cluster_tile. The 4096 sketch
  // above is not this many physical MACs; K is walked in strips of LANES.
  localparam int unsigned AI_THROUGHPUT_LANES = 8;

  // Latency-SKU target. AccTile stays 256 so 8192 MAC/cycle stays illegal.
  // It does not follow AI_LIVE_MACS.
  localparam ai_island_cfg_t AiIslandLatencySkuTarget = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(8192),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(2 * 1024 * 1024),
      AccTileM:     unsigned'(256),
      AccTileN:     unsigned'(256),
      AccTileK:     unsigned'(256),
      NocWidth:     unsigned'(512),
      DramChannels: unsigned'(2),
      DramChanShift: unsigned'(AI_DRAM_CHAN_SHIFT_DEFAULT),
      DramGBps:     unsigned'(400),
      DramClass:    unsigned'(AI_DRAM_LPDDR5),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64),
      MaxAROut:     unsigned'(AI_MAX_AR_OUT_DRAM),
      DramCas:      unsigned'(0),
      DramTrcd:     unsigned'(0),
      DramTrp:      unsigned'(0),
      ClustersEnabled: unsigned'(1)
  };

  // Guest-absolute island placement (F1). SoC alias of GPIOBase; 4 KiB window.
  // Emulator ingest: AI_CAP_BASE/AI_DESC_BASE → island-relative cap_base/desc_base.
  localparam logic [63:0] AI_CAP_BASE  = 64'h4000_0000;
  localparam logic [63:0] AI_DESC_BASE = 64'h4000_0140;

  // Island-relative register map (F1). Capability window occupies [CAP_BASE, 0x00FF].
  localparam logic [15:0] CAP_BASE          = 16'h0000;
  localparam logic [15:0] DESC_BASE         = 16'h0140;
  localparam logic [15:0] REG_OFF_CAP       = 16'h0000;
  localparam logic [15:0] REG_OFF_DESC      = 16'h0140;
  localparam logic [15:0] REG_OFF_CTL       = 16'h0100;
  localparam logic [15:0] REG_OFF_STATUS    = 16'h0104;
  localparam logic [15:0] REG_OFF_DOORBELL  = 16'h0108;
  localparam logic [15:0] REG_OFF_CPL       = 16'h010C;
  localparam logic [15:0] REG_OFF_QUEUE     = 16'h0120;
  // q0 only. A stride of 0x20 from here is the descriptor latch, and 0x0180
  // is the PMU, so later queues start at REG_OFF_QUEUE_TAIL.
  localparam logic [15:0] REG_OFF_QUEUE_TAIL = 16'h01A0;

  // I3 PMU (sticky last GEMM). Units: beats, cycles, milli-GB/s.
  localparam logic [15:0] PMU_OFF_R_BEATS     = 16'h0180;
  localparam logic [15:0] PMU_OFF_W_BEATS     = 16'h0184;
  localparam logic [15:0] PMU_OFF_CYCLES      = 16'h0188;
  localparam logic [15:0] PMU_OFF_GBPS_X1000  = 16'h018C;
  // F15: policy codec/steering sticky snapshot (last GEMM job). RO.
  localparam logic [15:0] PMU_OFF_POLICY_CODE  = 16'h0190;
  localparam logic [15:0] PMU_OFF_POLICY_WORD  = 16'h0194;
  localparam logic [15:0] PMU_OFF_POLICY_TOPO  = 16'h0198;
  localparam logic [15:0] PMU_OFF_POLICY_EVENT = 16'h019C;

  // {hit, q[7:0], word[2:0]}. `word` is the 32-bit slot in the 0x20 window.
  // Queue 0 is 0x0120. Queues after that are 0x01A0 + (q-1)*0x20.
  function automatic logic [11:0] ai_queue_decode(
      input logic [15:0] addr,
      input int unsigned nqueues
  );
    logic [11:0] dec;
    int unsigned q;
    int unsigned idx;
    logic [2:0] word;
    dec  = '0;
    q    = 0;
    idx  = 0;
    word = addr[4:2];
    if (nqueues != 0 && addr >= REG_OFF_QUEUE && addr < REG_OFF_QUEUE + 16'h20) begin
      dec = {1'b1, 8'd0, word};
    end else if (nqueues > 1 && 32'(addr) >= 32'(REG_OFF_QUEUE_TAIL)
        && 32'(addr) < 32'(REG_OFF_QUEUE_TAIL) + 32'(nqueues - 1) * 32'd32) begin
      idx = (32'(addr) - 32'(REG_OFF_QUEUE_TAIL)) >> 5;
      q   = idx + 1;
      if (q < nqueues && q < 256)
        dec = {1'b1, 8'(q), word};
    end
    return dec;
  endfunction

  // Live SKU: both queues on cluster 0. I2 grows this with ClustersEnabled.
  localparam int unsigned QueueClusterMap [0:1] = '{0, 0};

  // Capability window MMIO layout (offsets, 32-bit LE) — **RTL is normative**
  // (scaling-100tops.md §8 tracks these CAP_OFF_* names; do not rediscover from
  // an older 0x14=DRAM table).
  localparam logic [15:0] CAP_OFF_VERSION     = 16'h00;
  localparam logic [15:0] CAP_OFF_CLUSTERS    = 16'h04;
  localparam logic [15:0] CAP_OFF_MACS_CYCLE  = 16'h08;
  localparam logic [15:0] CAP_OFF_CLOCK_KHZ   = 16'h0C;
  localparam logic [15:0] CAP_OFF_SRAM_BYTES  = 16'h10;
  localparam logic [15:0] CAP_OFF_BLOCK_MNK   = 16'h14;  // packed M|N|K log2
  // [15:0]=nameplate GB/s; [31:16]=measured milli-GB/s after first GEMM (I3)
  localparam logic [15:0] CAP_OFF_DRAM_GBPS   = 16'h18;
  localparam logic [15:0] CAP_OFF_QUEUES      = 16'h1C;
  localparam logic [15:0] CAP_OFF_QOS         = 16'h20;
  localparam logic [15:0] CAP_OFF_QUANTUM     = 16'h24;
  localparam logic [15:0] CAP_OFF_DTYPE_MASK  = 16'h28;  // ew/sp24 grant bits
  // F14: full 32-bit measured milli-GB/s. Packed [31:16] of DRAM_GBPS saturates
  // at 16'hFFFF (>= 65.535 GB/s); software must read this word for I3 ≥ 66 GB/s.
  localparam logic [15:0] CAP_OFF_DRAM_MEAS_X1000 = 16'h2C;
  // F8: enabled-cluster bitmap (bit i = cluster i powered/enabled).
  localparam logic [15:0] CAP_OFF_CLUSTER_EN  = 16'h30;
  // I3 DRAM class discovery (not a 400 GB/s measurement).
  localparam logic [15:0] CAP_OFF_DRAM_CLASS  = 16'h34;  // 0=sim AXI, 1=DDR4, 2=LPDDR5
  // [15:0] DramChannels; [23:16] DramChanShift; [31:24] reserved
  localparam logic [15:0] CAP_OFF_DRAM_CHANS  = 16'h38;
  localparam int unsigned CAP_CHANS_COUNT_SHIFT = 0;
  localparam int unsigned CAP_CHANS_SHIFT_SHIFT = 16;
  localparam logic [15:0] CAP_OFF_NOC_WIDTH   = 16'h3C;  // bits
  // I3: GEMM multi-outstanding AR depth (hides DRAM tRCD/CL when class 1).
  localparam logic [15:0] CAP_OFF_MAX_AR_OUT  = 16'h40;
  // Packed DDR4 page-command timing (island DMA only; 0 = SRAM bypass).
  // [7:0] Cas, [15:8] tRCD, [23:16] tRP, [31:24] reserved.
  localparam logic [15:0] CAP_OFF_DRAM_TIMING = 16'h44;
  localparam int unsigned CAP_TIMING_CAS_SHIFT  = 0;
  localparam int unsigned CAP_TIMING_TRCD_SHIFT = 8;
  localparam int unsigned CAP_TIMING_TRP_SHIFT  = 16;
  localparam int unsigned CAP_TIMING_FIELD_W    = 8;
  // I3 DRAM status (not a GB/s). [0]=init_done (class 0 sticky 1; class 1 0 until
  // LiteDRAM calib); [1]=timing_en (DramCas!=0); [31:2] reserved.
  localparam logic [15:0] CAP_OFF_DRAM_STATUS = 16'h48;
  localparam int unsigned CAP_STATUS_INIT_BIT   = 0;
  localparam int unsigned CAP_STATUS_TIMING_BIT = 1;
  // S5 SoC occupancy (not GEMM PMU). ch i read beats at 0x50+4*i,
  // write beats at 0x70+4*i. Island CAP 0x18/0x2C/0x180 stay aggregate.
  localparam logic [15:0] CAP_OFF_DRAM_CH_R   = 16'h50;
  localparam logic [15:0] CAP_OFF_DRAM_CH_W   = 16'h70;
  // AI-X9 operand layout. Published so software DISCOVERS the layout instead of
  // inferring it from a contract version it may not check.
  //   [0] a_k_major : A rows contiguous along k (1 = row-major A[m][k])
  //   [1] b_k_major : B rows contiguous along k (1 = k-major B[n][k])
  //   [31:2] reserved
  // Live SKU publishes both set. b_k_major was 0 in ContractVersion 1.
  localparam logic [15:0] CAP_OFF_LAYOUT      = 16'h4C;
  localparam int unsigned CAP_LAYOUT_A_KMAJOR_BIT = 0;
  localparam int unsigned CAP_LAYOUT_B_KMAJOR_BIT = 1;
  localparam logic [31:0] AiIslandLayoutWord =
      (32'd1 << CAP_LAYOUT_A_KMAJOR_BIT) | (32'd1 << CAP_LAYOUT_B_KMAJOR_BIT);

  // F3: packed CAP_OFF_BLOCK_MNK subfields (log2 tile dims).
  localparam int unsigned CAP_BLOCK_M_SHIFT   = 0;
  localparam int unsigned CAP_BLOCK_N_SHIFT   = 4;
  localparam int unsigned CAP_BLOCK_K_SHIFT   = 8;
  localparam int unsigned CAP_BLOCK_FIELD_W   = 4;

  // Granted numeric formats, published at CAP_OFF_DTYPE_MASK and enforced by
  // g6lc_ai_desc_engine against a descriptor's flags.numfmt.
  //
  // Bit positions are `config_pkg::AI_FMT_*` -- the SAME enumeration the
  // core-attached plane uses in `ai_cfg_t.FormatMask`. One numbering for both
  // planes is deliberate: software discovers the island through this window and
  // the core through `ai.setcfg`, and two numberings would eventually disagree.
  //
  //   bit 0 AI_FMT_INT (dense INT8)   <- live engine
  //   bit 1 AI_FMT_INT4
  //   bit 2 AI_FMT_SP24
  //   bit 3 AI_FMT_FP8_E4M3
  //   bit 4 AI_FMT_FP8_E5M2
  //   bit 5 AI_FMT_FP16
  //   bit 6 AI_FMT_BF16
  //   bit 7 AI_FMT_FP32
  //
  // Live value is INT8 + INT4 (F1). This is a GRANT, so it moves only AFTER the
  // datapath can execute the format -- widening it early advertises arithmetic
  // the engine then refuses with ST_BAD_FMT, i.e. software has been lied to.
  //
  // INT4 qualified when all three pieces were in place and measured:
  //   * g6lc_ai_pe_dot reduces 2*Lanes products and unpacks two sign-extended
  //     nibbles per byte through the existing signed 8x8 cell (F1-PE);
  //   * g6lc_ai_gemm_seq advances t by 2*PeLanes, reads byte (t/2)+p, and masks
  //     the invalid nibble on an odd-k tail (F1-sequencer);
  //   * both loaders count t in BYTES against k_bytes = fmt_row_bytes(k), so a
  //     packed row is fetched at its real length instead of 2x over-fetched
  //     (F1-load).
  // FP8 needs no further load work -- it is already one byte per element -- but
  // it is NOT granted here because its multiplier/accumulator path is F2.
  //
  // Literal, not `config_pkg::AiFmtMaskInt8Int4`: the ai_island unit-TB runners
  // (verif/tb/ai_island/run-gemm-*.sh) compile THIS package before core's
  // config_pkg, so a cross-package reference here breaks them. The value must
  // equal AiFmtMaskInt8Int4; g6lc_ai_island_top's grant ⊆ implemented assertion
  // and config_pkg's own check_cfg mask↔Int4En rule are what keep it honest.
  localparam logic [15:0] AiIslandDtypeMask   = 16'h0003;  // AiFmtMaskInt8Int4

  // Illegal grant used ONLY as a negative control: INT8 + BF16, where the PE
  // implements INT8 alone, so the grant ⊆ implemented guard in
  // g6lc_ai_island_top must fire. A guard that has never fired is
  // indistinguishable from a dead one, and a silent build proves only that
  // nothing complained.
  //
  // It is a named constant here rather than an `ifdef` around
  // AiIslandDtypeMask itself: two conditional declarations of one localparam
  // make the value unparseable to anything that reads this package without
  // evaluating macros, and the emulator's capability-window ingest is exactly
  // such a reader (it reported "unresolved" instead of 0x0001). The testbench
  // selects it by parameter, so the package keeps stating one design.
  localparam logic [15:0] AiIslandDtypeMaskOvergrant = 16'h0041;

  // What the PE array can actually COMPUTE, as opposed to what the capability
  // window is willing to advertise.
  //
  // These are two different facts and keeping them as one number is how a part
  // ends up advertising BF16 it cannot do. `AiIslandDtypeMask` is policy -- a
  // SKU may legitimately grant less than the hardware supports. This is
  // capability, and it is a property of the PE datapath: `s8×s8→s32`, plus (F1)
  // the same signed 8x8 cell fed two sign-extended 4-bit nibbles per byte, which
  // is a genuine second format rather than a relabelling.
  //
  // Still bit 0 and 1 only. FP8 would need the float accumulator (F2), BF16 the
  // exponent path (F3), FP16 an 11x11 significand (F4), FP32 a decomposition
  // (F5) -- none of which exist yet, so none may appear here.
  //
  // `g6lc_ai_island_top` asserts grant ⊆ implemented, so raising the grant
  // without the datapath is caught at elaboration instead of becoming a
  // guest-visible lie. Update this ONLY together with the PE.
  localparam logic [15:0] AiIslandPeImplMask  = 16'h0003;  // AiFmtMaskInt8Int4

  // I3 legality: sim-AXI nameplate is the NoC peak; never advertise 400 GB/s
  // on class 0; enabled clusters cannot exceed present.
  function automatic bit island_cfg_legal(input ai_island_cfg_t c);
    bit ok;
    int unsigned noc;
    ok  = 1'b1;
    noc = noc_peak_gbps(c.NocWidth, c.ClockKhz);
    if (c.Clusters == 0 || c.Clusters > 8 || c.ClustersEnabled > c.Clusters) ok = 1'b0;
    // g6lc_ai_island_top is one engine and rejects Clusters != 1.
    // g6lc_ai_cluster_set is the N-copy elaboration. MacsPerCycle must fit
    // the K tile so a 8192-MAC struct with AccTileK 256 stays illegal.
    if (c.MacsPerCycle == 0 || c.MacsPerCycle > c.AccTileK) ok = 1'b0;
    if (c.MaxAROut < 1 || c.MaxAROut > AI_MAX_AR_OUT_DRAM) ok = 1'b0;
    if ((c.DramCas == 0) != (c.DramTrcd == 0) || (c.DramCas == 0) != (c.DramTrp == 0))
      ok = 1'b0;
    if (c.DramCas > 255 || c.DramTrcd > 255 || c.DramTrp > 255)
      ok = 1'b0;
    if (c.DramCas != 0 && c.MaxAROut < AI_MAX_AR_OUT_LIVE)
      ok = 1'b0;  // DRAM-class command delay needs outstanding ARs
    if (c.DramClass > AI_DRAM_LPDDR5) ok = 1'b0;
    if (c.DramClass == AI_DRAM_SIM_AXI) begin
      if (c.DramGBps != dram_nameplate_gbps(
              c.NocWidth, c.ClockKhz, c.DramChannels, c.DramClass))
        ok = 1'b0;
    end
    if (!dram_channels_ok(c.DramChannels)) ok = 1'b0;
    if (c.DramChanShift < 3 || c.DramChanShift > 16) ok = 1'b0;
    if (c.DramClass == AI_DRAM_DDR4) begin
      // Nameplate is N × DDR4-2400×64; never the class-0 NoC number or 400.
      if (c.DramGBps != dram_nameplate_gbps(
              c.NocWidth, c.ClockKhz, c.DramChannels, c.DramClass))
        ok = 1'b0;
    end
    if (c.DramClass == AI_DRAM_LPDDR5 && c.DramGBps == noc)
      ok = 1'b0;  // SKU must not reuse the class-0 NoC number
    if (c.DramClass == AI_DRAM_LPDDR5 && c.DramGBps != dram_nameplate_gbps(
            c.NocWidth, c.ClockKhz, c.DramChannels, c.DramClass))
      ok = 1'b0;
    return ok;
  endfunction

  // Parameter sketch in milli-TOPS (98.304 TOPS → 98304). Not a measurement.
  // INT8 is 2 × clusters × macs × clock. Other formats scale by element bytes.
  function automatic int unsigned sketch_milli_tops(
      input ai_island_cfg_t c, input int unsigned fmt
  );
    int unsigned base;
    base = (2 * c.Clusters * c.MacsPerCycle * (c.ClockKhz / 1000)) / 1000;
    case (fmt)
      0: return base;           // INT8
      1: return base * 2;       // INT4, two per byte
      3, 4: return base;       // FP8, one byte
      5, 6: return base / 2;   // FP16, BF16
      7: return base / 4;       // FP32
      default: return 0;       // SP24 and anything reserved
    endcase
  endfunction

  // Same sketch, times mac_mul/mac_div. mac_mul is a projection of issue
  // groups. It does not elaborate gemm_seq: PeLanes stays MacsPerCycle.
  // va_level is the VA-turbo error-budget index (0..15). It does not scale
  // the dense peak. Lane groups inside one engine do not add MAC/cycle, and
  // level 0 is the exact path. A level above 15 is not a peak.
  function automatic int unsigned sketch_milli_tops_scaled(
      input ai_island_cfg_t c,
      input int unsigned fmt,
      input int unsigned mac_mul,
      input int unsigned mac_div,
      input int unsigned va_level
  );
    int unsigned milli;
    if (mac_mul == 0 || mac_div == 0 || va_level > 15)
      return 0;
    milli = sketch_milli_tops(c, fmt);
    if (milli != 0 && mac_mul > ({32{1'b1}} / milli))
      return 0;
    return (milli * mac_mul) / mac_div;
  endfunction

  // Issues of AI_LIVE_MACS products along K for one output. A K that fits
  // the tile is one issue: extra lanes stay idle, so a short K does not
  // finish in fewer issues. k==AI_LIVE_MACS is the full-lane panel.
  // k above the tile does not fit one descriptor.
  // The three output shapes VA residency can keep distinct.
  function automatic bit va_panel_ok(input int unsigned m, input int unsigned n);
    if (m == AI_LIVE_MACS && n == AI_LIVE_MACS)
      return 1'b1;
    if (m == AI_LIVE_MACS && n == (AI_LIVE_MACS / 2))
      return 1'b1;
    if (m == (AI_LIVE_MACS * 2) && n == (AI_LIVE_MACS / 4))
      return 1'b1;
    return 1'b0;
  endfunction

  function automatic int unsigned panel_k_issues(input int unsigned k);
    if (k == 0 || k > AI_PANEL_K)
      return 0;
    return (k + AI_LIVE_MACS - 1) / AI_LIVE_MACS;
  endfunction

  // MAC issues for an m×n×k panel inside the live box. VA residency does
  // not change this count. 512×256 and 1024×128 are half the outputs of
  // 512×512, and any k that fits is still one issue per output.
  function automatic int unsigned panel_mac_issues(
      input int unsigned m,
      input int unsigned n,
      input int unsigned k
  );
    int unsigned issues;
    int unsigned outs;
    if (m == 0 || n == 0 || m > AI_PANEL_M || n > AI_PANEL_N)
      return 0;
    issues = panel_k_issues(k);
    if (issues == 0)
      return 0;
    if (m > ({32{1'b1}} / n))
      return 0;
    outs = m * n;
    if (outs > ({32{1'b1}} / issues))
      return 0;
    return outs * issues;
  endfunction

  // INT8 bytes of one operand (rows × k). A VA hit skips this many bytes
  // and does not change panel_mac_issues. rows or k above the tile is 0.
  function automatic int unsigned panel_operand_bytes(
      input int unsigned rows,
      input int unsigned k
  );
    if (rows == 0 || k == 0 || rows > AI_PANEL_M || k > AI_PANEL_K)
      return 0;
    if (rows > ({32{1'b1}} / k))
      return 0;
    return rows * k;
  endfunction

  // Testharness axi_riscv_atomics_wrap write MLP. Live MaxAROut keeps 1
  // (cookie). S4/CLASS1 MaxAROut=8 opens 8 AW so wrap NrAwSlots is reachable.
  function automatic int unsigned dram_aw_out(input ai_island_cfg_t c);
    return (c.MaxAROut > AI_MAX_AR_OUT_LIVE) ? c.MaxAROut : unsigned'(1);
  endfunction

  // Scale a DDR4 bringup SKU to N independent channels (nameplate = N×19 GB/s).
  function automatic ai_island_cfg_t island_cfg_with_channels(
      input ai_island_cfg_t base,
      input int unsigned nch
  );
    ai_island_cfg_t c;
    c = base;
    c.DramChannels = nch;
    if (c.DramClass == AI_DRAM_DDR4)
      c.DramGBps = ddr4_nameplate_gbps(nch);
    return c;
  endfunction

  // Class-0 SRAM, two 64 B stripes. Nameplate stays the live NoC peak
  // (channels do not multiply class 0). Testharness
  // +define+G6LC_AI_DRAM_SIM_CHANS_2. Not LiteDRAM, not I2.
  localparam ai_island_cfg_t AiIslandSimChans2 =
      island_cfg_with_channels(AiIslandLatencyDefault, unsigned'(2));
  // Class-0 SRAM, four/eight 64 B stripes. Testharness SIM_CHANS_4 / _8.
  localparam ai_island_cfg_t AiIslandSimChans4 =
      island_cfg_with_channels(AiIslandLatencyDefault, unsigned'(4));
  localparam ai_island_cfg_t AiIslandSimChans8 =
      island_cfg_with_channels(AiIslandLatencyDefault, unsigned'(8));

  // Overlay Cas/tRCD/tRP on a base SKU (all-zero or all-nonzero).
  function automatic ai_island_cfg_t island_cfg_with_timing(
      input ai_island_cfg_t base,
      input int unsigned cas_c,
      input int unsigned trcd_c,
      input int unsigned trp_c
  );
    ai_island_cfg_t c;
    c = base;
    c.DramCas  = cas_c;
    c.DramTrcd = trcd_c;
    c.DramTrp  = trp_c;
    return c;
  endfunction

endpackage
