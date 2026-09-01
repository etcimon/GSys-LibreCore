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
    int unsigned DramChannels;
    int unsigned DramGBps;       // nameplate aggregate
    int unsigned Queues;         // T2 rings visible to the island
    int unsigned QueueDepth;
    int unsigned QosClasses;
    int unsigned WorkQuantumK;   // preemption boundary in k-steps
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
      DramGBps:     unsigned'(8),             // I3-lite: 64-bit NoC @ 1 GHz peak GB/s
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64),
      ClustersEnabled: unsigned'(1)
  };

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
      DramGBps:     unsigned'(400),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64),
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

endpackage
