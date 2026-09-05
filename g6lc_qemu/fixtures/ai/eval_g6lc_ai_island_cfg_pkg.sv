// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

package g6q_eval_island_cfg_pkg;
  localparam int unsigned AiIslandDtypeMask = 32'hfb;
  typedef struct packed {
    int unsigned Clusters, MacsPerCycle, ClockKhz, SramBytes;
    int unsigned AccTileM, AccTileN, AccTileK;
    int unsigned NocWidth, DramChannels, DramGBps;
    int unsigned Queues, QueueDepth, QosClasses, WorkQuantumK;
  } ai_island_cfg_t;
  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
    Clusters: 1, MacsPerCycle: 16, ClockKhz: 100000,
    SramBytes: 65536, AccTileM: 256, AccTileN: 256, AccTileK: 256,
    NocWidth: 64, DramChannels: 1, DramGBps: 0,
    Queues: 1, QueueDepth: 4, QosClasses: 1, WorkQuantumK: 8
  };
endpackage
