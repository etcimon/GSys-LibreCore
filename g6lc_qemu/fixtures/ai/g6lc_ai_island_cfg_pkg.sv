// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

package g6lc_ai_island_cfg_pkg;
  typedef struct packed {
    int unsigned Clusters;
    int unsigned MacsPerCycle;
    int unsigned ClockKhz;
    int unsigned SramBytes;
    int unsigned AccTileM;
    int unsigned AccTileN;
    int unsigned AccTileK;
    int unsigned NocWidth;
    int unsigned DramChannels;
    int unsigned DramGBps;
    int unsigned Queues;
    int unsigned QueueDepth;
    int unsigned QosClasses;
    int unsigned WorkQuantumK;
  } ai_island_cfg_t;

  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(256),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(2 * 1024 * 1024),
      AccTileM:     unsigned'(256),
      AccTileN:     unsigned'(256),
      AccTileK:     unsigned'(256),
      NocWidth:     unsigned'(64),
      DramChannels: unsigned'(1),
      DramGBps:     unsigned'(0),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64)
  };

  localparam logic [15:0] CAP_OFF_VERSION     = 16'h00;
  localparam logic [15:0] CAP_OFF_CLUSTERS    = 16'h04;
  localparam logic [15:0] CAP_OFF_MACS_CYCLE  = 16'h08;

  // Placement of the island MMIO window. These are test-only values; a real
  // design publishes them as localparams beside the capability offsets.
  localparam logic [63:0] AI_CAP_BASE         = 64'h3000_0000;
  localparam logic [63:0] AI_DESC_BASE        = 64'h3000_0140;

  localparam int unsigned QueueClusterMap [0:1] = '{0, 1};
endpackage
