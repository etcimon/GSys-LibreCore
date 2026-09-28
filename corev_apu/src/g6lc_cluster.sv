// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.2 SoC N-core cluster wrapper (1…CVA6_MAX_CORES).
//
// Instantiates NR_CORES × ariane, g6lc_coherence_hub, optional L2/L3/PF,
// inclusive-L3 back-inval (parameter), and wires L1 inv adapters.
// PMU group-2 probes fan into each core's perf_counters.
// DRAM channels sit **below** this wrapper (`mem_req_o` → xbar → DRAM slave).
// Raising NR_CORES does not instantiate PHYs; see architecture/uncore/dram-channel-scaling.md.

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
    // When set, boot_addr_core_i[c] is the reset PC for physical core c.
    // Default off: every core uses boot_addr_i (ROM). FPGA/Altera unused.
    parameter bit          PerCoreBoot = 1'b0,
    // Per-core window guard, before the hub merges the cores. Default off.
    // A core whose hart is not FwHart cannot send the RAM or control window
    // into the hub. The firmware hart is a wire-through. FPGA/Altera unused.
    parameter bit          SrcGuard = 1'b0,
    parameter logic [31:0] FwHart = 32'hffff_ffff,
    parameter logic [63:0] GuardRamBase = 64'h0,
    parameter logic [63:0] GuardRamBytes = 64'h0,
    parameter logic [63:0] GuardCtrlBase = 64'h0,
    parameter logic [63:0] GuardCtrlBytes = 64'h0,
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
    input  logic [NR_CORES-1:0][CVA6Cfg.VLEN-1:0] boot_addr_core_i,
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
    output logic pf_train_o,
    // Xg6lcai island sideband from core 0 (tie open/0 when no island)
    output logic        ai_sb_enq_valid_o,
    output logic [7:0]  ai_sb_qid_o,
    output logic [31:0] ai_sb_ticket_o,
    output logic [CVA6Cfg.XLEN-1:0] ai_sb_desc_ptr_o,
    input  logic        ai_isl_has_completion_i,
    input  logic [31:0] ai_isl_last_ticket_i,
    input  logic [15:0] ai_isl_last_status_i
);

  localparam int unsigned NC = (NR_CORES < 1) ? 1 : NR_CORES;
  // Effective inclusion policy: TB override parameter OR package bit. The
  // testbench keeps INCLUSIVE_L3=0 so production packages own the policy.
  localparam bit INCL = INCLUSIVE_L3 || CVA6Cfg.L3InclusiveEn;
  localparam int unsigned LINE_B =
      (CVA6Cfg.DCACHE_LINE_WIDTH != 0) ? CVA6Cfg.DCACHE_LINE_WIDTH / 8
                                       : COH_DEFAULT_LINE_BYTES;

  if (CVA6Cfg.CohPolicy == COH_OOO &&
      (!CVA6Cfg.OoOEn || CVA6Cfg.FpPresent || !CVA6Cfg.L2En || NC <= 1 || CVA6Cfg.DCacheType != WT ||
       CVA6Cfg.ICACHE_LINE_WIDTH != CVA6Cfg.DCACHE_LINE_WIDTH)) begin : gen_bad_ooo_coherence
    $error("OoO coherence requires multiple integer OoO WT cores with equal L1 lines and L2");
    //pragma translate_off
`ifndef SYNTHESIS
    initial $fatal(1, "invalid OoO coherence configuration");
`endif
    //pragma translate_on
  end

  axi_req_t  [NC-1:0] core_req;
  axi_resp_t [NC-1:0] core_resp;
  axi_req_t  [NC-1:0] guarded_req;
  axi_resp_t [NC-1:0] guarded_resp;
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
  // T9b posted-write hold-cycle probes → PMU group 2, indices 7 (L2) / 8 (L3).
  logic l2_pwhold_w, l3_pwhold_w;
  logic [AXI_ADDR_WIDTH-1:0] l3_evict_a;
  logic pf_issue_w, pf_train_w;
  logic evict_v, incl_evict_ready;
  logic [AXI_ADDR_WIDTH-1:0] evict_a;

  assign l2_miss_o  = l2_miss_w;
  assign l3_hit_o   = l3_hit_w;
  assign l3_miss_o  = l3_miss_w;
  assign pf_issue_o = pf_issue_w;
  assign pf_train_o = pf_train_w;

  if (!PerCoreBoot) begin : gen_boot_default
    logic unused_core_boot;
    assign unused_core_boot = |boot_addr_core_i;
  end

  // Prefer L3 victim when L3En; else L2 victim (feeds L1 inclusive inv)
  assign evict_v = CVA6Cfg.L3En ? l3_evict_v : l2_evict_v;
  assign evict_a = CVA6Cfg.L3En ? l3_evict_a : l2_evict_a;

  // L3→L2 tag back-inval (inclusive hierarchy). Active when the effective
  // inclusion policy and L3 are both on. The invalidate is qualified by the
  // victim ACCEPT edge, not the held offer: the L3 keeps l3_evict_v asserted
  // while it waits for l3_evict_rdy, so sampling the offer alone would fire
  // the L2 tag invalidate once per wait cycle instead of once per victim.
  // l3_evict_rdy ANDs the inclusive-inv accept with the L2's back-inval slot
  // so the victim commit lands on both consumers atomically.
  logic l2_back_inval_v;
  logic [AXI_ADDR_WIDTH-1:0] l2_back_inval_a;
  logic l2_back_inval_ready;
  logic l3_evict_rdy;
  // T9a: CMO engine wiring (valid only under CVA6Cfg.L2CmoEn)
  logic       [NC-1:0] cmo_req_v, cmo_req_rdy, cmo_done;
  logic [1:0]          cmo_req_op  [NC];
  logic [CVA6Cfg.PLEN-1:0]     cmo_req_paddr [NC];
  logic [AXI_ADDR_WIDTH-1:0]   cmo_req_addr  [NC];
  coh_inval_t [NC-1:0] inv_cmo;
  logic       [NC-1:0] inv_cmo_ready;
  logic                cmo_bcast_v, cmo_bcast_rdy, cmo_bcast_done;
  logic [AXI_ADDR_WIDTH-1:0] cmo_bcast_a;
  logic                cmo_l2_v, cmo_l2_rdy;
  logic [AXI_ADDR_WIDTH-1:0] cmo_l2_a;
  logic                cmo_l3_v, cmo_l3_rdy;
  logic [AXI_ADDR_WIDTH-1:0] cmo_l3_a;
  logic                l2_idle_w, l3_idle_w;
  // The L3 victim accept is the only competing user of the L2 back-inval
  // port; it wins the slot and the CMO simply keeps l2_inval_valid raised.
  logic vict_l2_take;
  assign vict_l2_take = INCL && CVA6Cfg.L3En && l3_evict_v && l3_evict_rdy;
  assign l3_evict_rdy = incl_evict_ready && (INCL ? l2_back_inval_ready : 1'b1);
  assign l2_back_inval_v = vict_l2_take ? 1'b1 : cmo_l2_v;
  assign l2_back_inval_a = vict_l2_take ? l3_evict_a : cmo_l2_a;
  assign cmo_l2_rdy = !vict_l2_take && l2_back_inval_ready;

  logic [NC-1:0] inv_incl_ready;
  // Merge hub + inclusive victim + CMO broadcast inv (priority order)
  always_comb begin
    for (int unsigned c = 0; c < NC; c++) begin
      inv_incl_ready[c] = inv_core_ready[c] && !inv_hub[c].valid;
      inv_cmo_ready[c]  = inv_core_ready[c] && !inv_hub[c].valid &&
                          !inv_incl[c].valid;
      if (inv_hub[c].valid) inv_to_core[c] = inv_hub[c];
      else if (inv_incl[c].valid) inv_to_core[c] = inv_incl[c];
      else inv_to_core[c] = inv_cmo[c];
    end
  end

  // --------------------
  // Cores
  // --------------------
  rvfi_probes_t [NC-1:0] core_rvfi;

  logic        [NC-1:0]        core_sb_enq;
  logic        [NC-1:0][7:0]   core_sb_qid;
  logic        [NC-1:0][31:0]  core_sb_ticket;
  logic        [NC-1:0][CVA6Cfg.XLEN-1:0] core_sb_desc_ptr;

  // S4: multi-core SMT (N>1,T>1) secondary cores race OpenSBI's shared
  // lottery/stack (G1dg class *across cores*, not SMT). Hold c>0 clock-gated
  // until IPI (HSM) or BOOT_HOLD_CYC (same 200000 as SMT_COLD_EXCL).
  // stream8 is T=1 so this localparam is 0. Core 0 always runs.
  // ICG IS_FUNCTIONAL: correctness, not power. test_en tied 0 until
  // testmode_i is threaded (DFT). Same clk; en_i is registered.
  localparam bit BOOT_HOLD = (NC > 1) && (CVA6Cfg.NrHarts > 1);
  localparam logic [17:0] BOOT_HOLD_CYC = 18'd200000;
  logic [17:0] boot_hold_q;
  logic [NC-1:0] ipi_seen_q;
  logic [NC-1:0] core_clk;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      boot_hold_q <= '0;
      ipi_seen_q  <= '0;
    end else begin
      if (BOOT_HOLD && (boot_hold_q != 18'h3ffff))
        boot_hold_q <= boot_hold_q + 18'd1;
      for (int unsigned c = 0; c < NC; c++) begin
        if (|ipi_i[c]) ipi_seen_q[c] <= 1'b1;
      end
    end
  end

  for (genvar c = 0; c < NC; c++) begin : gen_core
    if (BOOT_HOLD && (c != 0)) begin : gen_boot_icg
      logic rel;
      assign rel = (boot_hold_q >= BOOT_HOLD_CYC) || ipi_seen_q[c];
      tc_clk_gating #(
          .IS_FUNCTIONAL(1'b1)
      ) i_boot_icg (
          .clk_i,
          .en_i     (rel),
          .test_en_i(1'b0),
          .clk_o    (core_clk[c])
      );
    end else begin : gen_boot_feed
      assign core_clk[c] = clk_i;
    end
    ariane #(
        .CVA6Cfg       (CVA6Cfg),
        .rvfi_probes_t (rvfi_probes_t),
        .noc_req_t     (axi_req_t),
        .noc_resp_t    (axi_resp_t)
    ) i_ariane (
        .clk_i            (core_clk[c]),
        .rst_ni,
        .boot_addr_i      (PerCoreBoot ? boot_addr_core_i[c] : boot_addr_i),
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
        // T9a CMO sideband → g6lc_cmo_engine (idle ties when L2CmoEn=0)
        .cmo_valid_o      (cmo_req_v[c]),
        .cmo_op_o         (cmo_req_op[c]),
        .cmo_addr_o       (cmo_req_paddr[c]),
        .cmo_ready_i      (cmo_req_rdy[c]),
        .cmo_done_i       (cmo_done[c]),
        // Fan hierarchy probes to every core's PMU group 2
        .l2_miss_i        (l2_miss_w),
        .l3_hit_i         (l3_hit_w),
        .l3_miss_i        (l3_miss_w),
        .pf_issue_i       (pf_issue_w),
        .pf_train_i       (pf_train_w),
        .l2_pwhold_i      (l2_pwhold_w),
        .l3_pwhold_i      (l3_pwhold_w),
        .ai_sb_enq_valid_o(core_sb_enq[c]),
        .ai_sb_qid_o      (core_sb_qid[c]),
        .ai_sb_ticket_o   (core_sb_ticket[c]),
        .ai_sb_desc_ptr_o (core_sb_desc_ptr[c]),
        // Broadcast island completion to every core for ai.poll
        .ai_isl_has_completion_i(ai_isl_has_completion_i),
        .ai_isl_last_ticket_i   (ai_isl_last_ticket_i),
        .ai_isl_last_status_i   (ai_isl_last_status_i)
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

    // PLEN (core side) → AXI_ADDR_WIDTH (hierarchy side)
    assign cmo_req_addr[c] = AXI_ADDR_WIDTH'(cmo_req_paddr[c]);
  end

  assign rvfi_probes_o = core_rvfi[0];

  // Single island: accept enq from core 0 (first hart wins multi-core for now)
  assign ai_sb_enq_valid_o = core_sb_enq[0];
  assign ai_sb_qid_o       = core_sb_qid[0];
  assign ai_sb_ticket_o    = core_sb_ticket[0];
  assign ai_sb_desc_ptr_o  = core_sb_desc_ptr[0];

  // Per-core guard in front of the hub. SrcGuard=0 is a wire.
  localparam int unsigned HART_STRIDE =
      (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  for (genvar c = 0; c < NC; c++) begin : gen_src
    if (SrcGuard) begin : gen_guard
      g6lc_apu_src_guard #(
          .Hart      (32'(c * HART_STRIDE)),
          .FwHart    (FwHart),
          .RamBase   (GuardRamBase),
          .RamBytes  (GuardRamBytes),
          .CtrlBase  (GuardCtrlBase),
          .CtrlBytes (GuardCtrlBytes),
          .axi_req_t (axi_req_t),
          .axi_resp_t(axi_resp_t)
      ) i_guard (
          .clk_i,
          .rst_ni,
          .up_req_i (core_req[c]),
          .up_resp_o(core_resp[c]),
          .dn_req_o (guarded_req[c]),
          .dn_resp_i(guarded_resp[c])
      );
    end else begin : gen_wire
      assign guarded_req[c]  = core_req[c];
      assign core_resp[c]    = guarded_resp[c];
    end
  end

  // --------------------
  // Coherence hub
  // --------------------
  // S4: SKIP_HUB identity (s4-v-skiphub-minis) same stock HANG @40000 —
  // not the hub. Keep NC>1 hub on _v.
  if (NC <= 1 && IDENTITY_FAST) begin : gen_single
    assign hub_mem_req      = guarded_req[0];
    assign guarded_resp[0]  = hub_mem_resp;
    assign inv_hub       = '{default: '0};
  end else begin : gen_hub
    g6lc_coherence_hub #(
        .NR_CORES             (NC),
        // T9a: package-configured outstanding-transaction credit limit
        // (0 → default 4; legality range enforced by check_cfg)
        .MAX_OUTSTANDING      (CVA6Cfg.CohMaxOutstanding != 0 ? CVA6Cfg.CohMaxOutstanding : 4),
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
        .core_req_i       (guarded_req),
        .core_resp_o      (guarded_resp),
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
        .coh_sc_noresv_o  (),
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
        .RR_EN          (CVA6Cfg.L2RoundRobinEn),
        .FAIR_WRITES    (CVA6Cfg.OoOEn),
        .TAG_SRAM       (CVA6Cfg.L2TagSramEn),
        .WRITE_UPDATE   (CVA6Cfg.L2WriteUpdateEn),
        .POSTED_WRITES  (CVA6Cfg.L2PostedWriteEn),
        .WTRK_DEPTH     (CVA6Cfg.L2WriteTrackDepth != 0 ? CVA6Cfg.L2WriteTrackDepth : 32'd4),
        .RDTRK_DEPTH    (CVA6Cfg.L2ReadTrackDepth != 0 ? CVA6Cfg.L2ReadTrackDepth : 32'd4),
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
        // TB reads the pulses hierarchically; no cluster ports.
        .l2_selfinv_hit_o   (),
        .l2_wupdate_o       (),
        .l2_wtrk_full_o     (),
        .l2_wtrk_line_hold_o(),
        .l2_posted_o        (),
        .l2_rdtrk_o         (),
        .l2_posted_hold_o   (l2_pwhold_w),
        .l2_evict_valid_o   (l2_evict_v),
        .l2_evict_addr_o    (l2_evict_a),
        // Under L3En the L2's evict output is not the inclusive broadcast
        // source (l3_evict_v is), so it always sees ready; without L3 the L2
        // is the producer and must hold its victim until the inv engine takes
        // it.
        .l2_evict_ready_i   (CVA6Cfg.L3En ? 1'b1 : incl_evict_ready),
        .l2_back_inval_valid_i (l2_back_inval_v),
        .l2_back_inval_addr_i  (l2_back_inval_a),
        .l2_back_inval_ready_o (l2_back_inval_ready),
        .l2_write_idle_o       (l2_idle_w)
    );
  end else begin : gen_no_l2
    assign l2_mst_req   = hub_mem_req;
    assign hub_mem_resp = l2_mst_resp;
    assign l2_miss_w    = 1'b0;
    assign l2_evict_v   = 1'b0;
    assign l2_evict_a   = '0;
    assign l2_back_inval_ready = 1'b1;
    assign l2_idle_w    = 1'b1;
    assign l2_pwhold_w  = 1'b0;
  end

  if (CVA6Cfg.L3En) begin : gen_l3
    g6lc_l3_top #(
        .Enable         (1'b1),
        .FAIR_WRITES    (CVA6Cfg.OoOEn),
        .BYTE_SIZE      (CVA6Cfg.L3ByteSize != 0 ? CVA6Cfg.L3ByteSize : 32'd2097152),
        .SET_ASSOC      (CVA6Cfg.L3SetAssoc != 0 ? CVA6Cfg.L3SetAssoc : 32'd16),
        .LINE_WIDTH     (CVA6Cfg.L3LineWidth != 0 ? CVA6Cfg.L3LineWidth :
                         (CVA6Cfg.L2LineWidth != 0 ? CVA6Cfg.L2LineWidth : 32'd512)),
        .MSHR_DEPTH     (CVA6Cfg.L3MshrDepth != 0 ? CVA6Cfg.L3MshrDepth : 32'd16),
        .DATA_BANKS     (CVA6Cfg.L3DataBanks != 0 ? CVA6Cfg.L3DataBanks : 32'd8),
        .TAG_SRAM       (CVA6Cfg.L2TagSramEn),
        .WRITE_UPDATE   (CVA6Cfg.L2WriteUpdateEn),
        .POSTED_WRITES  (CVA6Cfg.L2PostedWriteEn),
        .WTRK_DEPTH     (CVA6Cfg.L2WriteTrackDepth != 0 ? CVA6Cfg.L2WriteTrackDepth : 32'd4),
        .RDTRK_DEPTH    (CVA6Cfg.L2ReadTrackDepth != 0 ? CVA6Cfg.L2ReadTrackDepth : 32'd4),
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
        // TB reads the pulses hierarchically; no cluster ports.
        .l3_selfinv_hit_o (),
        .l3_wupdate_o       (),
        .l3_wtrk_full_o     (),
        .l3_wtrk_line_hold_o(),
        .l3_posted_o        (),
        .l3_rdtrk_o         (),
        .l3_posted_hold_o   (l3_pwhold_w),
        .l3_evict_valid_o (l3_evict_v),
        .l3_evict_addr_o  (l3_evict_a),
        .l3_evict_ready_i (l3_evict_rdy),
        // T9a CMO: L3 match-inval + write-idle for clean/flush ordering
        .l3_write_idle_o       (l3_idle_w),
        .l3_back_inval_valid_i (cmo_l3_v),
        .l3_back_inval_addr_i  (cmo_l3_a),
        .l3_back_inval_ready_o (cmo_l3_rdy)
    );
  end else begin : gen_no_l3
    assign l3_mst_req  = l2_mst_req;
    assign l2_mst_resp = l3_mst_resp;
    assign l3_hit_w    = 1'b0;
    assign l3_miss_w   = 1'b0;
    assign l3_bypass_w = 1'b1;
    assign l3_evict_v  = 1'b0;
    assign l3_evict_a  = '0;
    assign l3_idle_w   = 1'b1;
    assign l3_pwhold_w = 1'b0;
    assign cmo_l3_rdy  = 1'b1;
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
  logic incl_inv_busy;
  g6lc_l3_inclusive_inv #(
      .InclusiveEn   (INCL),
      .NR_CORES      (NC),
      .LINE_BYTES    (LINE_B),
      .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
  ) i_incl_inv (
      .clk_i,
      .rst_ni,
      .evict_valid_i(evict_v),
      .evict_addr_i (evict_a),
      .inv_ready_i  (inv_incl_ready),
      .inv_o        (inv_incl),
      .inv_busy_o   (incl_inv_busy),
      .evict_ready_o(incl_evict_ready),
      .drain_done_o ()
  );

  // --------------------
  // T9a eWT CMO engine + L1 broadcaster
  // --------------------
  // One CMO in flight, round-robin over the cores' cmo sidebands. The
  // broadcaster is a second inclusive-inv instance so the CMO broadcast
  // inherits the same all-cores-ack drain contract; it merges into
  // inv_to_core at lowest priority (hub > inclusive victim > cmo).
  if (CVA6Cfg.L2CmoEn) begin : gen_cmo
    g6lc_l3_inclusive_inv #(
        .InclusiveEn   (1'b1),
        .NR_CORES      (NC),
        .LINE_BYTES    (LINE_B),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ) i_cmo_bcast (
        .clk_i,
        .rst_ni,
        .evict_valid_i(cmo_bcast_v),
        .evict_addr_i (cmo_bcast_a),
        .inv_ready_i  (inv_cmo_ready),
        .inv_o        (inv_cmo),
        .inv_busy_o   (),
        .evict_ready_o(cmo_bcast_rdy),
        .drain_done_o (cmo_bcast_done)
    );

    g6lc_cmo_engine #(
        .NR_CORES       (NC),
        .L2_EN          (CVA6Cfg.L2En),
        .L3_EN          (CVA6Cfg.L3En),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH)
    ) i_cmo_engine (
        .clk_i,
        .rst_ni,
        .cmo_valid_i      (cmo_req_v),
        .cmo_op_i         (cmo_req_op),
        .cmo_addr_i       (cmo_req_addr),
        .cmo_ready_o      (cmo_req_rdy),
        .cmo_done_o       (cmo_done),
        .l1_bcast_valid_o (cmo_bcast_v),
        .l1_bcast_addr_o  (cmo_bcast_a),
        .l1_bcast_ready_i (cmo_bcast_rdy),
        .l1_bcast_done_i  (cmo_bcast_done),
        .l2_inval_valid_o (cmo_l2_v),
        .l2_inval_addr_o  (cmo_l2_a),
        .l2_inval_ready_i (cmo_l2_rdy),
        .l3_inval_valid_o (cmo_l3_v),
        .l3_inval_addr_o  (cmo_l3_a),
        .l3_inval_ready_i (cmo_l3_rdy),
        .l2_write_idle_i  (l2_idle_w),
        .l3_write_idle_i  (l3_idle_w)
    );
  end else begin : gen_no_cmo
    // The cores complete CBOs locally (L2CmoEn=0) — sideband stays idle.
    for (genvar c = 0; c < NC; c++) begin : gen_cmo_idle
      assign inv_cmo[c]    = '0;
      assign cmo_req_rdy[c] = 1'b0;
      assign cmo_done[c]    = 1'b0;
    end
    assign cmo_l2_v        = 1'b0;
    assign cmo_l2_a        = '0;
    assign cmo_l3_v        = 1'b0;
    assign cmo_l3_a        = '0;
    assign cmo_bcast_v     = 1'b0;
    assign cmo_bcast_a     = '0;
    assign cmo_bcast_rdy   = 1'b0;
    assign cmo_bcast_done  = 1'b0;
    logic unused_cmo_w;
    assign unused_cmo_w = |cmo_req_v;
  end

  // Silence unused
  // NOTE: incl_evict_ready is now honoured end-to-end on the selected producer
  // (i_l3 under L3En, i_l2 otherwise): both engines hold their victim offer in
  // S_TAG until the inclusive-inv leaf accepts it, so a victim arriving while
  // a previous back-invalidation drains is no longer dropped. Under INCL the
  // L3 victim accept additionally waits on the L2 back-inval slot and the L2
  // invalidate fires only on that accept edge.
  // Remaining gap (documented in architecture/multi-core/README.md): under
  // L3En the shared L2's OWN evictions are not an inv source at all — evict_v
  // selects only l3_evict_v — so an L2 victim displacing an L1-held line does
  // not broadcast an invalidation.
  logic _unused_bypass, _unused_incl_busy;
  assign _unused_bypass = l3_bypass_w;
  assign _unused_incl_busy = incl_inv_busy;

endmodule

`include "g6lc_apu_src_guard.sv"
