// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// L3 cache — thin specialization of g6lc_l2_top with server-class geometry.
// Inserted between L2 master and DRAM when CVA6Cfg.L3En.

module g6lc_l3_top
  import g6lc_l3_pkg::*;
#(
    parameter bit          Enable      = 1'b1,
    parameter int unsigned BYTE_SIZE   = L3_DEFAULT_BYTE_SIZE,
    parameter int unsigned SET_ASSOC   = L3_DEFAULT_SET_ASSOC,
    parameter int unsigned LINE_WIDTH  = L3_DEFAULT_LINE_WIDTH,
    parameter int unsigned MSHR_DEPTH  = L3_DEFAULT_MSHR_DEPTH,
    parameter int unsigned DATA_BANKS  = L3_DEFAULT_DATA_BANKS,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter type axi_req_t  = logic,
    parameter type axi_resp_t = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    input  axi_req_t  slv_req_i,
    output axi_resp_t slv_resp_o,
    output axi_req_t  mst_req_o,
    input  axi_resp_t mst_resp_i,
    output logic      l3_hit_o,
    output logic      l3_miss_o,
    output logic      l3_bypass_o,
    // Victim replace — inclusive back-inval toward L1/L2
    output logic                       l3_evict_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0]  l3_evict_addr_o
);

  logic full, bank_cfl;

  g6lc_l2_top #(
      .Enable         (Enable),
      .BYTE_SIZE      (BYTE_SIZE),
      .SET_ASSOC      (SET_ASSOC),
      .LINE_WIDTH     (LINE_WIDTH),
      .MSHR_DEPTH     (MSHR_DEPTH),
      .DATA_BANKS     (DATA_BANKS),
      .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
      .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
      .AXI_ID_WIDTH   (AXI_ID_WIDTH),
      .AXI_USER_WIDTH (AXI_USER_WIDTH),
      .axi_req_t      (axi_req_t),
      .axi_resp_t     (axi_resp_t)
  ) i_l3_as_l2 (
      .clk_i,
      .rst_ni,
      .slv_req_i,
      .slv_resp_o,
      .mst_req_o,
      .mst_resp_i,
      .l2_hit_o           (l3_hit_o),
      .l2_miss_o          (l3_miss_o),
      .l2_bypass_o        (l3_bypass_o),
      .l2_mshr_full_o     (full),
      .l2_bank_conflict_o (bank_cfl),
      .l2_evict_valid_o   (l3_evict_valid_o),
      .l2_evict_addr_o    (l3_evict_addr_o),
      // L3 has no upper-level inclusive slave; back-inval is L2's job
      .l2_back_inval_valid_i (1'b0),
      .l2_back_inval_addr_i  ('0),
      .l2_back_inval_ready_o (/* unused */)
  );

endmodule
