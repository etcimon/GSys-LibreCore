// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Lint/elaboration wrapper: g6lc_ai_island_top with Clusters = CLUSTERS at a reduced
// geometry (16x16x16 tiles, 8 MAC/cycle per engine). CLUSTERS = 1 is the single-engine
// arm; 2 and 4 elaborate g6lc_ai_cluster_dispatch inside the island.
module lint_g6lc_ai_island_clusters #(
    parameter int unsigned CLUSTERS = 2
) (
    input logic clk_i,
    input logic rst_ni
);
  import g6lc_ai_island_cfg_pkg::*;
  function automatic ai_island_cfg_t cfg();
    ai_island_cfg_t c = AiIslandLatencyDefault;
    c.Clusters = CLUSTERS;
    c.ClustersEnabled = CLUSTERS;
    c.MacsPerCycle = 8;
    c.AccTileM = 16; c.AccTileN = 16; c.AccTileK = 16;
    c.SramBytes = 64 * 1024;
    return c;
  endfunction
  localparam ai_island_cfg_t Cfg = cfg();
  typedef logic [63:0] addr_t; typedef logic [5:0] id_t; typedef logic [63:0] data_t;
  typedef logic [7:0] strb_t; typedef logic [0:0] user_t;
  `AXI_TYPEDEF_ALL(bus, addr_t, id_t, data_t, strb_t, user_t)
  bus_req_t  dma_req;
  bus_resp_t dma_resp;
  assign dma_resp = '0;
  g6lc_ai_island_top #(
      .IslandCfg(Cfg), .EnableDmaFetch(1), .AxiDataWidth(64), .AxiIdWidth(6),
      .axi_req_t(bus_req_t), .axi_resp_t(bus_resp_t)
  ) dut (
      .clk_i, .rst_ni, .testmode_i(1'b0),
      .req_i(1'b0), .we_i(1'b0), .addr_i('0), .wdata_i('0),
      .rdata_o(), .rvalid_o(), .rerror_o(), .irq_o(),
      .sb_enq_valid_i(1'b0), .sb_enq_ready_o(), .sb_qid_i('0), .sb_ticket_i('0), .sb_desc_ptr_i('0),
      .sb_last_ticket_o(), .sb_last_status_o(), .sb_has_completion_o(),
      .sb_retired_valid_o(), .sb_retired_ticket_o(),
      .axi_dma_req_o(dma_req), .axi_dma_resp_i(dma_resp),
      .dram_init_done_i(1'b1), .ch_r_beats_i('0), .ch_w_beats_i('0)
  );
endmodule
