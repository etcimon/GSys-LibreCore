// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.2 SoC N-core cluster wrapper (1…CVA6_MAX_CORES).
//
// Instantiates NR_CORES × ariane, g6lc_coherence_hub, optional L2/L3/PF,
// inclusive-L3 back-inval (parameter), and wires L1 inv adapters.
// PMU group-2 probes fan into each core's perf_counters.

module g6lc_cluster
  import g6lc_coherence_pkg::*;
  import config_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned NR_CORES = 1,
    parameter bit          L2_ENABLE = 1'b0,
    parameter bit          IDENTITY_FAST = 1'b1,  // N=1 skip hub instance
    // Inclusive LLC: on L3 (or L2 if L3 off) victim replace, inv all L1s and
    // (when L3En) invalidate the matching L2 tag. Default on when L3En so the
    // stream-plane × multicore hierarchy stays coherent without TB knobs.
    parameter bit          INCLUSIVE_L3 = 1'b0,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter type axi_req_t  = logic,
    parameter type axi_resp_t = logic,
    parameter type rvfi_probes_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Per physical core × SMT hart: PLIC {MEIP,SEIP}, CLINT IPI, CLINT timer
    input  logic [NR_CORES-1:0][(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][1:0] irq_i,
    input  logic [NR_CORES-1:0][(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0]     ipi_i,
    input  logic [NR_CORES-1:0][(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0]     time_irq_i,
    input  logic [63:0]              rtc_time_i,
    input  logic [NR_CORES-1:0]      debug_req_i,
    output axi_req_t  mem_req_o,
    input  axi_resp_t mem_resp_i,
    output rvfi_probes_t rvfi_probes_o,
    // Optional hierarchy observability (SoC TB / external PMU)
    output logic l2_miss_o,
    output logic l3_hit_o,
    output logic l3_miss_o,
    output logic pf_issue_o,
    output logic pf_train_o
);

  localparam int unsigned NC = (NR_CORES < 1) ? 1 : NR_CORES;
  localparam int unsigned LINE_B =
      (CVA6Cfg.DCACHE_LINE_WIDTH != 0) ? CVA6Cfg.DCACHE_LINE_WIDTH / 8
                                       : COH_DEFAULT_LINE_BYTES;

  axi_req_t  [NC-1:0] core_req;
  axi_resp_t [NC-1:0] core_resp;
  coh_inval_t [NC-1:0] inv_hub, inv_incl, inv_to_core;
  logic       [NC-1:0] inv_core_ready;
  logic [63:0]         l1_inv_addr [NC];
  logic                l1_inv_valid[NC];
  logic                l1_inv_ready[NC];

  axi_req_t  hub_mem_req;
  axi_resp_t hub_mem_resp;

  logic l2_miss_w, l2_evict_v;
  logic [AXI_ADDR_WIDTH-1:0] l2_evict_a;
  logic l3_hit_w, l3_miss_w, l3_bypass_w, l3_evict_v;
  logic [AXI_ADDR_WIDTH-1:0] l3_evict_a;
  logic pf_issue_w, pf_train_w;
  logic evict_v;
  logic [AXI_ADDR_WIDTH-1:0] evict_a;

  assign l2_miss_o  = l2_miss_w;
  assign l3_hit_o   = l3_hit_w;
  assign l3_miss_o  = l3_miss_w;
  assign pf_issue_o = pf_issue_w;
  assign pf_train_o = pf_train_w;

  // Prefer L3 victim when L3En; else L2 victim (feeds L1 inclusive inv)
  assign evict_v = CVA6Cfg.L3En ? l3_evict_v : l2_evict_v;
  assign evict_a = CVA6Cfg.L3En ? l3_evict_a : l2_evict_a;

  // L3→L2 tag back-inval (inclusive hierarchy). Active when InclusiveEn and L3.
  logic l2_back_inval_v;
  logic [AXI_ADDR_WIDTH-1:0] l2_back_inval_a;
  logic l2_back_inval_ready;
  assign l2_back_inval_v = INCLUSIVE_L3 && CVA6Cfg.L3En && l3_evict_v;
  assign l2_back_inval_a = l3_evict_a;

  // Merge hub + inclusive inv (hub wins if both valid same cycle)
  always_comb begin
    for (int unsigned c = 0; c < NC; c++) begin
      if (inv_hub[c].valid) inv_to_core[c] = inv_hub[c];
      else inv_to_core[c] = inv_incl[c];
    end
  end

  // --------------------
  // Cores
  // --------------------
  rvfi_probes_t [NC-1:0] core_rvfi;

  for (genvar c = 0; c < NC; c++) begin : gen_core
    ariane #(
        .CVA6Cfg       (CVA6Cfg),
        .rvfi_probes_t (rvfi_probes_t),
        .noc_req_t     (axi_req_t),
        .noc_resp_t    (axi_resp_t)
    ) i_ariane (
        .clk_i,
        .rst_ni,
        .boot_addr_i      (boot_addr_i),
        // mhartid base: core_index × NrHarts (SMT banks add +h in csr bank)
        .hart_id_i        (CVA6Cfg.XLEN'(c * ((CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts))),
        .irq_i            (irq_i[c]),      // [NrHarts-1:0][1:0]
        .ipi_i            (ipi_i[c]),      // [NrHarts-1:0]
        .time_irq_i       (time_irq_i[c]), // [NrHarts-1:0]

        .rtc_time_i       (rtc_time_i),
        .debug_req_i      (debug_req_i[c]),
        .rvfi_probes_o    (core_rvfi[c]),
        .noc_req_o        (core_req[c]),
        .noc_resp_i       (core_resp[c]),
        .l1_inval_addr_i  (l1_inv_addr[c]),
        .l1_inval_valid_i (l1_inv_valid[c]),
        .l1_inval_ready_o (l1_inv_ready[c]),
        // Fan hierarchy probes to every core's PMU group 2
        .l2_miss_i        (l2_miss_w),
        .l3_hit_i         (l3_hit_w),
        .l3_miss_i        (l3_miss_w),
        .pf_issue_i       (pf_issue_w),
        .pf_train_i       (pf_train_w)
    );

    g6lc_l1_inv_adapter #(
        .LINE_BYTES(LINE_B)
    ) i_inv_ad (
        .clk_i,
        .rst_ni,
        .inv_i           (inv_to_core[c]),
        .inv_ready_o     (inv_core_ready[c]),
        .l1_inval_addr_o (l1_inv_addr[c]),
        .l1_inval_valid_o(l1_inv_valid[c]),
        .l1_inval_ready_i(l1_inv_ready[c])
    );
  end

  assign rvfi_probes_o = core_rvfi[0];

  // --------------------
  // Coherence hub
  // --------------------
  if (NC <= 1 && IDENTITY_FAST) begin : gen_single
    assign hub_mem_req   = core_req[0];
    assign core_resp[0]  = hub_mem_resp;
    assign inv_hub       = '{default: '0};
  end else begin : gen_hub
    g6lc_coherence_hub #(
        .NR_CORES             (NC),
        .SNOOP_FILTER_EN      (CVA6Cfg.SnoopFilterEn),
        .SNOOP_FILTER_ENTRIES (CVA6Cfg.SnoopFilterEntries != 0 ? CVA6Cfg.SnoopFilterEntries
                                                               : COH_DEFAULT_SF_ENTRIES),
        .INVAL_DEPTH          (CVA6Cfg.CohInvalDepth != 0 ? CVA6Cfg.CohInvalDepth
                                                          : COH_DEFAULT_INVAL_DEPTH),
        .LINE_BYTES           (LINE_B),
        .AXI_STARVE_LIMIT     (CVA6Cfg.CohAxiStarveLimit != 0 ? CVA6Cfg.CohAxiStarveLimit : 16),
        .POLICY               (CVA6Cfg.CohPolicy),
        .AXI_ADDR_WIDTH       (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH       (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH         (AXI_ID_WIDTH),
        .AXI_USER_WIDTH       (AXI_USER_WIDTH),
        .axi_req_t            (axi_req_t),
        .axi_resp_t           (axi_resp_t)
    ) i_hub (
        .clk_i,
        .rst_ni,
        .core_req_i       (core_req),
        .core_resp_o      (core_resp),
        .mem_req_o        (hub_mem_req),
        .mem_resp_i       (hub_mem_resp),
        .inv_core_o       (inv_hub),
        .inv_core_ready_i (inv_core_ready),
        .lr_valid_i       (1'b0),
        .lr_addr_i        ('0),
        .lr_core_i        ('0),
        .coh_inv_fire_o   (),
        .coh_sf_hit_o     (),
        .coh_sf_overapprox_o(),
        .coh_arb_starve_o (),
        .coh_split_conflict_o(),
        .coh_sc_fail_o    (),
        .coh_lr_kill_o    ()
    );
  end

  // --------------------
  // L2 → L3 → PF → DRAM
  // --------------------
  axi_req_t  l2_mst_req, l3_mst_req;
  axi_resp_t l2_mst_resp, l3_mst_resp;

  if (L2_ENABLE || CVA6Cfg.L2En) begin : gen_l2
    g6lc_l2_top #(
        .Enable         (1'b1),
        .BYTE_SIZE      (CVA6Cfg.L2ByteSize != 0 ? CVA6Cfg.L2ByteSize : 32'd262144),
        .SET_ASSOC      (CVA6Cfg.L2SetAssoc != 0 ? CVA6Cfg.L2SetAssoc : 32'd8),
        .LINE_WIDTH     (CVA6Cfg.L2LineWidth != 0 ? CVA6Cfg.L2LineWidth :
                         (CVA6Cfg.DCACHE_LINE_WIDTH != 0 ? CVA6Cfg.DCACHE_LINE_WIDTH : 32'd512)),
        .MSHR_DEPTH     (CVA6Cfg.L2MshrDepth != 0 ? CVA6Cfg.L2MshrDepth : 32'd8),
        .DATA_BANKS     (CVA6Cfg.L2DataBanks != 0 ? CVA6Cfg.L2DataBanks : 32'd4),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .AXI_USER_WIDTH (AXI_USER_WIDTH),
        .axi_req_t      (axi_req_t),
        .axi_resp_t     (axi_resp_t)
    ) i_l2 (
        .clk_i,
        .rst_ni,
        .slv_req_i          (hub_mem_req),
        .slv_resp_o         (hub_mem_resp),
        .mst_req_o          (l2_mst_req),
        .mst_resp_i         (l2_mst_resp),
        .l2_hit_o           (),
        .l2_miss_o          (l2_miss_w),
        .l2_bypass_o        (),
        .l2_mshr_full_o     (),
        .l2_bank_conflict_o (),
        .l2_evict_valid_o   (l2_evict_v),
        .l2_evict_addr_o    (l2_evict_a),
        .l2_back_inval_valid_i (l2_back_inval_v),
        .l2_back_inval_addr_i  (l2_back_inval_a),
        .l2_back_inval_ready_o (l2_back_inval_ready)
    );
  end else begin : gen_no_l2
    assign l2_mst_req   = hub_mem_req;
    assign hub_mem_resp = l2_mst_resp;
    assign l2_miss_w    = 1'b0;
    assign l2_evict_v   = 1'b0;
    assign l2_evict_a   = '0;
    assign l2_back_inval_ready = 1'b1;
  end

  if (CVA6Cfg.L3En) begin : gen_l3
    g6lc_l3_top #(
        .Enable         (1'b1),
        .BYTE_SIZE      (CVA6Cfg.L3ByteSize != 0 ? CVA6Cfg.L3ByteSize : 32'd2097152),
        .SET_ASSOC      (CVA6Cfg.L3SetAssoc != 0 ? CVA6Cfg.L3SetAssoc : 32'd16),
        .LINE_WIDTH     (CVA6Cfg.L3LineWidth != 0 ? CVA6Cfg.L3LineWidth :
                         (CVA6Cfg.L2LineWidth != 0 ? CVA6Cfg.L2LineWidth : 32'd512)),
        .MSHR_DEPTH     (CVA6Cfg.L3MshrDepth != 0 ? CVA6Cfg.L3MshrDepth : 32'd16),
        .DATA_BANKS     (CVA6Cfg.L3DataBanks != 0 ? CVA6Cfg.L3DataBanks : 32'd8),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .AXI_USER_WIDTH (AXI_USER_WIDTH),
        .axi_req_t      (axi_req_t),
        .axi_resp_t     (axi_resp_t)
    ) i_l3 (
        .clk_i,
        .rst_ni,
        .slv_req_i        (l2_mst_req),
        .slv_resp_o       (l2_mst_resp),
        .mst_req_o        (l3_mst_req),
        .mst_resp_i       (l3_mst_resp),
        .l3_hit_o         (l3_hit_w),
        .l3_miss_o        (l3_miss_w),
        .l3_bypass_o      (l3_bypass_w),
        .l3_evict_valid_o (l3_evict_v),
        .l3_evict_addr_o  (l3_evict_a)
    );
  end else begin : gen_no_l3
    assign l3_mst_req  = l2_mst_req;
    assign l2_mst_resp = l3_mst_resp;
    assign l3_hit_w    = 1'b0;
    assign l3_miss_w   = 1'b0;
    assign l3_bypass_w = 1'b1;
    assign l3_evict_v  = 1'b0;
    assign l3_evict_a  = '0;
  end

  g6lc_server_prefetcher #(
      .Enable         (CVA6Cfg.ServerPrefetchEn),
      .NR_STREAMS     (CVA6Cfg.ServerPfStreams != 0 ? CVA6Cfg.ServerPfStreams : 4),
      .PF_DISTANCE    (CVA6Cfg.ServerPfDistance != 0 ? CVA6Cfg.ServerPfDistance : 2),
      .LINE_BYTES     ((CVA6Cfg.L2LineWidth != 0 ? CVA6Cfg.L2LineWidth : 512) / 8),
      .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
      .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
      .AXI_ID_WIDTH   (AXI_ID_WIDTH),
      .AXI_USER_WIDTH (AXI_USER_WIDTH),
      .axi_req_t      (axi_req_t),
      .axi_resp_t     (axi_resp_t)
  ) i_server_pf (
      .clk_i,
      .rst_ni,
      .up_req_i   (l3_mst_req),
      .up_resp_o  (l3_mst_resp),
      .dn_req_o   (mem_req_o),
      .dn_resp_i  (mem_resp_i),
      .pf_issue_o (pf_issue_w),
      .pf_train_o (pf_train_w)
  );

  // Inclusive back-inval (parameter; default off)
  g6lc_l3_inclusive_inv #(
      .InclusiveEn   (INCLUSIVE_L3),
      .NR_CORES      (NC),
      .LINE_BYTES    (LINE_B),
      .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
  ) i_incl_inv (
      .clk_i,
      .rst_ni,
      .evict_valid_i(evict_v),
      .evict_addr_i (evict_a),
      .inv_ready_i  (inv_core_ready),
      .inv_o        (inv_incl),
      .inv_busy_o   ()
  );

  // Silence unused
  logic _unused_bypass, _unused_l2_bi_rdy;
  assign _unused_bypass = l3_bypass_w;
  assign _unused_l2_bi_rdy = l2_back_inval_ready;

endmodule
