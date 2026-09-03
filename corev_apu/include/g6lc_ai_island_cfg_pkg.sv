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
// gemm_seq MaxDim/PeLanes bind from AccTileM / MacsPerCycle (AiIslandLatencyDefault).

package g6lc_ai_island_cfg_pkg;

  // Capability-window contract version (MMIO BAR0 + DTS g6lc,ai-matrix).
  localparam logic [15:0] AiIslandCapVersion = 16'd1;

  // Named DRAM classes (DramClass field / CAP_OFF_DRAM_CLASS).
  localparam int unsigned AI_DRAM_SIM_AXI = 0;  // testharness AXI SRAM; I3-lite
  localparam int unsigned AI_DRAM_DDR4    = 1;  // LiteDRAM at xbar; I3
  localparam int unsigned AI_DRAM_LPDDR5  = 2;  // SKU target only
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

  // I1 live RTL: AccTile*=256 / PeLanes=256 (1 MAC cycle per C at full tile).
  // Multi-bank C (j%PeLanes) → each bank MaxDim*1 words (256xi32 @256/256).
  // gemm_seq binds MaxDim/PeLanes from AccTileM / MacsPerCycle.
  // I3-lite: multi-beat AR/AW + B oct-drain + trail C-store + multi-out AR + PMU→CAP; NoC 64.
  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(256),           // PeLanes = AccTileK (full-width MAC)
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(2 * 1024 * 1024), // A/B + multi-bank C (MaxDim=256)
      AccTileM:     unsigned'(256),           // SKU AccTile* live freeze
      AccTileN:     unsigned'(256),
      AccTileK:     unsigned'(256),
      NocWidth:     unsigned'(64),
      DramChannels: unsigned'(1),
      DramChanShift: unsigned'(AI_DRAM_CHAN_SHIFT_DEFAULT),
      DramGBps:     unsigned'(8),             // I3-lite: 64-bit NoC @ 1 GHz peak GB/s
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
      MacsPerCycle: unsigned'(256),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(2 * 1024 * 1024),
      AccTileM:     unsigned'(256),
      AccTileN:     unsigned'(256),
      AccTileK:     unsigned'(256),
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
      MacsPerCycle: unsigned'(256),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(2 * 1024 * 1024),
      AccTileM:     unsigned'(256),
      AccTileN:     unsigned'(256),
      AccTileK:     unsigned'(256),
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
      MacsPerCycle: unsigned'(256),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(2 * 1024 * 1024),
      AccTileM:     unsigned'(256),
      AccTileN:     unsigned'(256),
      AccTileK:     unsigned'(256),
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

  // Latency-SKU target: AccTile* = 256 frozen; full Macs/NoC/DRAM still open.
  localparam ai_island_cfg_t AiIslandLatencySkuTarget = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(8192),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(2 * 1024 * 1024),
      AccTileM:     unsigned'(256),           // AccTile* freeze (matches live)
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

  // I3 PMU (sticky last GEMM). Units: beats, cycles, milli-GB/s.
  localparam logic [15:0] PMU_OFF_R_BEATS     = 16'h0180;
  localparam logic [15:0] PMU_OFF_W_BEATS     = 16'h0184;
  localparam logic [15:0] PMU_OFF_CYCLES      = 16'h0188;
  localparam logic [15:0] PMU_OFF_GBPS_X1000  = 16'h018C;

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
  // Live value is INT8-only because the PE datapath is s8×s8→s32. This is a
  // GRANT, so widening it without the matching datapath would advertise a format
  // the engine cannot execute; the engine then returns ST_BAD_FMT and software
  // has been lied to. Widen the datapath first, then this mask.
  localparam logic [15:0] AiIslandDtypeMask   = 16'h0001;

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
  // capability, and it is a property of `g6lc_ai_pe`/`g6lc_ai_mac`: today
  // strictly `s8×s8→s32`, hence bit 0 alone.
  //
  // `g6lc_ai_island_top` asserts grant ⊆ implemented, so raising the grant
  // without the datapath is caught at elaboration instead of becoming a
  // guest-visible lie. Update this ONLY together with the PE.
  localparam logic [15:0] AiIslandPeImplMask  = 16'h0001;

  // I3 legality: sim-AXI nameplate is the NoC peak; never advertise 400 GB/s
  // on class 0; enabled clusters cannot exceed present.
  function automatic bit island_cfg_legal(input ai_island_cfg_t c);
    bit ok;
    int unsigned noc;
    ok  = 1'b1;
    noc = noc_peak_gbps(c.NocWidth, c.ClockKhz);
    if (c.Clusters == 0 || c.ClustersEnabled > c.Clusters) ok = 1'b0;
    if (c.MaxAROut < 1 || c.MaxAROut > AI_MAX_AR_OUT_DRAM) ok = 1'b0;
    if ((c.DramCas == 0) != (c.DramTrcd == 0) || (c.DramCas == 0) != (c.DramTrp == 0))
      ok = 1'b0;
    if (c.DramCas > 255 || c.DramTrcd > 255 || c.DramTrp > 255)
      ok = 1'b0;
    if (c.DramCas != 0 && c.MaxAROut < AI_MAX_AR_OUT_LIVE)
      ok = 1'b0;  // DRAM-class command delay needs outstanding ARs
    if (c.DramClass > AI_DRAM_LPDDR5) ok = 1'b0;
    if (c.DramClass == AI_DRAM_SIM_AXI) begin
      if (c.DramGBps != noc) ok = 1'b0;
    end
    if (!dram_channels_ok(c.DramChannels)) ok = 1'b0;
    if (c.DramChanShift < 3 || c.DramChanShift > 16) ok = 1'b0;
    if (c.DramClass == AI_DRAM_DDR4) begin
      // Nameplate is N × DDR4-2400×64; never the I3-lite NoC number or 400.
      if (c.DramGBps != ddr4_nameplate_gbps(c.DramChannels)) ok = 1'b0;
    end
    if (c.DramClass == AI_DRAM_LPDDR5 && c.DramGBps == noc)
      ok = 1'b0;  // SKU must not reuse the I3-lite NoC number
    return ok;
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

  // Class-0 SRAM, two 64 B stripes. Nameplate stays the NoC 8 GB/s.
  // Testharness +define+G6LC_AI_DRAM_SIM_CHANS_2. Not LiteDRAM, not I2.
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
