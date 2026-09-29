// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// L3 cache — thin specialization of g6lc_l2_top with server-class geometry.
// Inserted between L2 master and DRAM when CVA6Cfg.L3En.

module g6lc_l3_top
  import g6lc_l3_pkg::*;
#(
    parameter bit          Enable      = 1'b1,
    parameter bit          FAIR_WRITES = 1'b0,
    parameter bit          TAG_SRAM    = 1'b0,
    // Write-update: forwarded cacheable writes merge into resident lines
    // instead of purging them (see g6lc_l2_top WRITE_UPDATE / l2 README).
    parameter bit          WRITE_UPDATE = 1'b0,
    // T9b posted writes / bypass-read tracking at the L3 level (see
    // g6lc_l2_top POSTED_WRITES); pass-through of the cluster config.
    parameter bit          POSTED_WRITES = 1'b0,
    parameter int unsigned WTRK_DEPTH    = 4,
    parameter int unsigned RDTRK_DEPTH   = 4,
    // T9h/M5: same stream/stride prefetcher as the L2 (pass-through of
    // g6lc_l2_top PF_*); default off at L3 in this milestone.
    parameter bit          PF_EN          = 1'b0,
    parameter int unsigned PF_STREAMS     = 4,
    parameter int unsigned PF_DISTANCE    = 2,
    parameter bit          PF_STRIDE      = 1'b1,
    parameter int unsigned PF_MSHR_RESERVE= 1,
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
    // Observability pulse: an inval-match actually cleared a live L3 line
    // this cycle (write self-inval propagation). TB counts it as l3_selfinv.
    output logic      l3_selfinv_hit_o,
    // Observability pulse (WRITE_UPDATE): a forwarded write merged into a
    // resident L3 line. TB counts it as l3_wupd.
    output logic      l3_wupdate_o,
    // T9b observability at L3 (see g6lc_l2_top l2_*_o outputs).
    output logic      l3_wtrk_full_o,
    output logic      l3_wtrk_line_hold_o,
    // T9h/M5 prefetcher observability (see g6lc_l2_top l2_pf_*_o).
    output logic      l3_pf_issue_o,
    output logic      l3_pf_useful_o,
    output logic      l3_pf_drop_o,
    // T9c/M1c hold-cycle split (see g6lc_l2_top l2_hold_*_o).
    output logic      l3_hold_r1_o,
    output logic      l3_hold_r1_wu_o,
    output logic      l3_hold_r2_o,
    output logic      l3_posted_o,
    output logic      l3_rdtrk_o,
    output logic      l3_posted_hold_o,
    // Victim replace — inclusive back-inval toward L1/L2. Valid/ready offer:
    // the victim commit inside holds until l3_evict_ready_i accepts the
    // notification. Tie high when no inclusive engine is connected.
    output logic                       l3_evict_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0]  l3_evict_addr_o,
    input  logic                       l3_evict_ready_i,
    // T9a eWT CMO ordering (see g6lc_l2_top l2_write_idle_o)
    output logic                       l3_write_idle_o,
    // T9a CMO match-inval into the L3 tag (cluster CMO engine). Always ready
    // (single-cycle tag match on the inner engine's back-inval port).
    input  logic                       l3_back_inval_valid_i,
    input  logic [AXI_ADDR_WIDTH-1:0]  l3_back_inval_addr_i,
    output logic                       l3_back_inval_ready_o
);

  logic full, bank_cfl;

  g6lc_l2_top #(
      .Enable         (Enable),
      .FAIR_WRITES    (FAIR_WRITES),
      .TAG_SRAM       (TAG_SRAM),
      .WRITE_UPDATE   (WRITE_UPDATE),
      .POSTED_WRITES  (POSTED_WRITES),
      .WTRK_DEPTH     (WTRK_DEPTH),
      .RDTRK_DEPTH    (RDTRK_DEPTH),
      .PF_EN          (PF_EN),
      .PF_STREAMS     (PF_STREAMS),
      .PF_DISTANCE    (PF_DISTANCE),
      .PF_STRIDE      (PF_STRIDE),
      .PF_MSHR_RESERVE(PF_MSHR_RESERVE),
      // This engine sits below an L2 that re-tags its posted writes onto
      // the reserved WR_ID — id-14 arrivals are the designed flow here, so
      // the slave-side WR_ID integration assert stays off (T9d/M1d).
      .SLV_WRID_OK    (1'b1),
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
      .l2_selfinv_hit_o   (l3_selfinv_hit_o),
      .l2_wupdate_o       (l3_wupdate_o),
      .l2_wtrk_full_o     (l3_wtrk_full_o),
      .l2_wtrk_line_hold_o(l3_wtrk_line_hold_o),
      .l2_hold_r1_o       (l3_hold_r1_o),
      .l2_hold_r1_wu_o    (l3_hold_r1_wu_o),
      .l2_hold_r2_o       (l3_hold_r2_o),
      .l2_posted_o        (l3_posted_o),
      .l2_rdtrk_o         (l3_rdtrk_o),
      .l2_posted_hold_o   (l3_posted_hold_o),
      .l2_pf_issue_o      (l3_pf_issue_o),
      .l2_pf_useful_o     (l3_pf_useful_o),
      .l2_pf_drop_o       (l3_pf_drop_o),
      .l2_mshr_full_o     (full),
      .l2_bank_conflict_o (bank_cfl),
      .l2_evict_valid_o   (l3_evict_valid_o),
      .l2_evict_addr_o    (l3_evict_addr_o),
      .l2_evict_ready_i   (l3_evict_ready_i),
      // T9a: CMO match-inval drives the inner engine's back-inval port; the
      // inclusive L3 victim has no up-level back-inval of its own here.
      .l2_back_inval_valid_i (l3_back_inval_valid_i),
      .l2_back_inval_addr_i  (l3_back_inval_addr_i),
      .l2_back_inval_ready_o (l3_back_inval_ready_o),
      .l2_write_idle_o       (l3_write_idle_o)
  );

endmodule
