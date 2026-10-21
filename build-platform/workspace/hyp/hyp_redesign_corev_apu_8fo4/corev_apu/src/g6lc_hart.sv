// Copyright 2017-2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Modified by: Etienne Cimon
// Date: 19.03.2017
// Description: the core Top-level module
//
// U10ᵇ: When G6LCCfg.EnableAccelerator (RVV), the CVXIF path is replaced by
// typed accelerator interfaces + g6lc_ara_attach. Live Ara IP requires
// `define G6LC_ARA_ATTACH and vendor/ara on the flist; otherwise the attach
// stub elaborates and ties accelerator responses (lint-safe).

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: cluster/coherence attach, L2/L3 wiring and multi-hart SoC plumbing.
// The upstream notice above is prose and declares no SPDX identifier, so the
// outbound offer is stated here as the file's single SPDX tag. See REUSE.toml.
// Etienne Cimon offers this file AS A WHOLE under:
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

`include "rvfi_types.svh"
`include "cvxif_types.svh"
`include "g6lc_acc_intf.svh"
`include "axi/typedef.svh"

module g6lc_hart import g6lc_core_pkg::*; #(
  parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
  // hyp8: HypCfg threaded to g6lc_core (rank-2/4 cut parameters)
  parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_config_pkg::HypCfg,
  parameter type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(G6LCCfg),
  parameter type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(G6LCCfg),
  // rvfi_probes_csr_t, not logic: g6lc_rvfi_probes assigns the whole CSR probe
  // payload to this member, so a 1-bit default silently truncates it. The
  // production testharness already passes the wide type; the default must match.
  parameter type rvfi_probes_t = struct packed {
    rvfi_probes_csr_t csr;
    rvfi_probes_instr_t instr;
  },

  // CVXIF Types
  localparam type readregflags_t      = `READREGFLAGS_T(G6LCCfg),
  localparam type writeregflags_t     = `WRITEREGFLAGS_T(G6LCCfg),
  localparam type id_t                = `ID_T(G6LCCfg),
  localparam type hartid_t            = `HARTID_T(G6LCCfg),
  localparam type x_compressed_req_t  = `X_COMPRESSED_REQ_T(G6LCCfg, hartid_t),
  localparam type x_compressed_resp_t = `X_COMPRESSED_RESP_T(G6LCCfg),
  localparam type x_issue_req_t       = `X_ISSUE_REQ_T(G6LCCfg, hartid_t, id_t),
  localparam type x_issue_resp_t      = `X_ISSUE_RESP_T(G6LCCfg, writeregflags_t, readregflags_t),
  localparam type x_register_t        = `X_REGISTER_T(G6LCCfg, hartid_t, id_t, readregflags_t),
  localparam type x_commit_t          = `X_COMMIT_T(G6LCCfg, hartid_t, id_t),
  localparam type x_result_t          = `X_RESULT_T(G6LCCfg, hartid_t, id_t, writeregflags_t),
  localparam type cvxif_req_t         = `CVXIF_REQ_T(G6LCCfg, x_compressed_req_t, x_issue_req_t, x_register_t, x_commit_t),
  localparam type cvxif_resp_t        = `CVXIF_RESP_T(G6LCCfg, x_compressed_resp_t, x_issue_resp_t, x_result_t),
  // AXI Types
  parameter int unsigned AxiAddrWidth = g6lc_axi::AddrWidth,
  parameter int unsigned AxiDataWidth = g6lc_axi::DataWidth,
  parameter int unsigned AxiIdWidth   = g6lc_axi::IdWidth,
  parameter type axi_ar_chan_t = g6lc_axi::ar_chan_t,
  parameter type axi_aw_chan_t = g6lc_axi::aw_chan_t,
  parameter type axi_w_chan_t  = g6lc_axi::w_chan_t,
  parameter type noc_req_t = g6lc_axi::req_t,
  parameter type noc_resp_t = g6lc_axi::resp_t,
  // Ara geometry (U10ᵇ) — only used when EnableAccelerator
  parameter int unsigned AraNrLanes = 4,
  parameter int unsigned AraVLEN    = 4096
) (
  input  logic                         clk_i,
  // hyp8: uncore (SoC fabric) clock — noc_req_o/noc_resp_i are on this domain.
  // Draft SoC ties clk_uncore_i = clk_i (H13); the axi_cdc below is the real seam.
  input  logic                         clk_uncore_i,
  input  logic                         rst_ni,
  // Core ID, Cluster ID and boot address are considered more or less static
  input  logic [G6LCCfg.VLEN-1:0]       boot_addr_i,  // reset boot address
  input  logic [G6LCCfg.XLEN-1:0]       hart_id_i,    // hart id in a multicore environment (reflected in a CSR)

  // Interrupt inputs (per SMT hart; NrHarts==1 → scalar-equivalent widths)
  input  logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][1:0] irq_i,
  input  logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0]     ipi_i,
  // Timer facilities (per SMT hart / CLINT MSIP·MTIP slot)
  input  logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0]     time_irq_i,
  // Platform mtime counter value for Sstc (tie to '0 when G6LCCfg.SstcEn is 0)
  input  logic [63:0]                  rtc_time_i,
  input  logic                         debug_req_i,  // debug request (async)
  // G6LC core sleep request (every hart in WFI) for the cluster's per-core ICG
  output logic                         core_wfi_all_o,
  output logic                         core_wake_o,
  // RISC-V formal interface port (`rvfi`):
  // Can be left open when formal tracing is not needed.
  output rvfi_probes_t rvfi_probes_o,
  // memory side
  output noc_req_t                     noc_req_o,
  input  noc_resp_t                    noc_resp_i,
  // U6.2 external L1 invalidation from coherence hub (tie valid=0 if unused)
  input  logic [63:0]                  l1_inval_addr_i,
  input  logic                         l1_inval_valid_i,
  output logic                         l1_inval_ready_o,
  // T9a eWT CMO sideband (see g6lc_core.sv); idle when L2CmoEn=0 — tie ready/done 0
  output logic                         cmo_valid_o,
  output logic [1:0]                   cmo_op_o,
  output logic [G6LCCfg.PLEN-1:0]      cmo_addr_o,
  input  logic                         cmo_ready_i,
  input  logic                         cmo_done_i,
  // PMU group 2 hierarchy probes (tie 0 when unused)
  input  logic                         l2_miss_i,
  input  logic                         l3_hit_i,
  input  logic                         l3_miss_i,
  input  logic                         pf_issue_i,
  input  logic                         pf_train_i,
  // T9b: posted-write hold cycles at each cache level (indices 7/8)
  input  logic                         l2_pwhold_i,
  input  logic                         l3_pwhold_i,
  // T9h/M5: L2 prefetcher issue/usefulness pulses (indices 9/10)
  input  logic                         l2_pf_issue_i,
  input  logic                         l2_pf_useful_i,
  // Xg6lcai island sideband: ai.enq kick + ai.poll completion (tie 0 / open if no island)
  output logic                         ai_sb_enq_valid_o,
  input  logic                         ai_sb_enq_ready_i,
  input  logic [31:0]                  ai_sb_enq_ticket_i,
  output logic [7:0]                   ai_sb_qid_o,
  output logic [31:0]                  ai_sb_ticket_o,
  output logic [G6LCCfg.XLEN-1:0]      ai_sb_desc_ptr_o,
  input  logic                         ai_isl_attached_i,
  input  logic                         ai_isl_has_completion_i,
  input  logic                         ai_isl_retired_valid_i,
  input  logic [31:0]                  ai_isl_retired_ticket_i,
  input  logic [31:0]                  ai_isl_last_ticket_i,
  input  logic [15:0]                  ai_isl_last_status_i
);

  // hyp8: two-flop synchronizers on the interrupt/debug inputs (H13). In the
  // draft SoC these arrive on clk_uncore_i; when clk_uncore_i is a real async
  // clock the double-flop stages below are the required CDC cells.
  localparam int unsigned NH = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;

  logic [NH-1:0][1:0] irq_sync_q;
  logic [NH-1:0]      ipi_sync_q;
  logic [NH-1:0]      time_irq_sync_q;
  logic               debug_req_sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_irq_sync
    if (!rst_ni) begin
      irq_sync_q      <= '0;
      ipi_sync_q      <= '0;
      time_irq_sync_q <= '0;
      debug_req_sync_q <= 1'b0;
    end else begin
      irq_sync_q      <= irq_i;
      ipi_sync_q      <= ipi_i;
      time_irq_sync_q <= time_irq_i;
      debug_req_sync_q <= debug_req_i;
    end
  end

  // hyp8: core AXI master crosses clk_i -> clk_uncore_i through the vendor
  // gray-FIFO CDC. noc_req_o/noc_resp_i are uncore-domain; noc_req_pre is the
  // core-domain request assembled by g6lc_core (or the accelerator mux).
  noc_req_t  noc_req_pre;
  noc_resp_t noc_resp_pre;

  axi_cdc #(
    .aw_chan_t  ( axi_aw_chan_t ),
    .w_chan_t   ( axi_w_chan_t  ),
    .b_chan_t   ( g6lc_axi::b_chan_t ),
    .ar_chan_t  ( axi_ar_chan_t ),
    .r_chan_t   ( g6lc_axi::r_chan_t ),
    .axi_req_t  ( noc_req_t     ),
    .axi_resp_t ( noc_resp_t    ),
    .LogDepth   ( 2             )
  ) i_noc_cdc (
    .src_clk_i  ( clk_i        ),
    .src_rst_ni ( rst_ni       ),
    .src_req_i  ( noc_req_pre  ),
    .src_resp_o ( noc_resp_pre ),
    .dst_clk_i  ( clk_uncore_i ),
    .dst_rst_ni ( rst_ni       ),
    .dst_req_o  ( noc_req_o    ),
    .dst_resp_i ( noc_resp_i   )
  );

  //////////////////////////////////////////////////////////////////////////////
  // Standard path: CVXIF or bare core (no RVV accelerator)
  //////////////////////////////////////////////////////////////////////////////
  if (!G6LCCfg.EnableAccelerator) begin : gen_std

    cvxif_req_t  cvxif_req;
    cvxif_resp_t cvxif_resp;
    // Xg6lcai CSR sideband + PMU probes (csr_regfile / perf_counters ↔ AI copro)
    logic [G6LCCfg.XLEN-1:0] ai_aicfg;
    logic [1:0]              ai_ais;
    logic                    ai_issue_ok, ai_q_en;
    logic [7:0]              ai_qid;
    logic                    dirty_ai_state;
    logic                    ai_setcfg_we;
    logic [G6LCCfg.XLEN-1:0] ai_setcfg_wdata;
    logic                    ai_pmu_op, ai_pmu_mma, ai_pmu_post, ai_pmu_t0, ai_pmu_busy;
    logic                    ai_sb_enq;
    logic [7:0]              ai_sb_qid;
    logic [31:0]             ai_sb_ticket;
    logic [G6LCCfg.XLEN-1:0] ai_sb_desc_ptr;

    g6lc_core #(
      .G6LCCfg ( G6LCCfg ),
      .HypCfg ( HypCfg ),
      .rvfi_probes_instr_t ( rvfi_probes_instr_t ),
      .rvfi_probes_csr_t ( rvfi_probes_csr_t ),
      .rvfi_probes_t ( rvfi_probes_t ),
      .axi_ar_chan_t (axi_ar_chan_t),
      .axi_aw_chan_t (axi_aw_chan_t),
      .axi_w_chan_t (axi_w_chan_t),
      .noc_req_t (noc_req_t),
      .noc_resp_t (noc_resp_t),
      .readregflags_t (readregflags_t),
      .writeregflags_t (writeregflags_t),
      .id_t (id_t),
      .hartid_t (hartid_t),
      .x_compressed_req_t (x_compressed_req_t),
      .x_compressed_resp_t (x_compressed_resp_t),
      .x_issue_req_t (x_issue_req_t),
      .x_issue_resp_t (x_issue_resp_t),
      .x_register_t (x_register_t),
      .x_commit_t (x_commit_t),
      .x_result_t (x_result_t),
      .cvxif_req_t (cvxif_req_t),
      .cvxif_resp_t (cvxif_resp_t)
    ) i_g6lc (
      .clk_i                ( clk_i                     ),
      .rst_ni               ( rst_ni                    ),
      .boot_addr_i          ( boot_addr_i               ),
      .hart_id_i            ( hart_id_i                 ),
      .irq_i                ( irq_sync_q                ),
      .ipi_i                ( ipi_sync_q                ),
      .time_irq_i           ( time_irq_sync_q           ),
      .rtc_time_i           ( rtc_time_i                ),
      .debug_req_i          ( debug_req_sync_q          ),
      .core_wfi_all_o       ( core_wfi_all_o            ),
      .core_wake_o          ( core_wake_o               ),
      .rvfi_probes_o        ( rvfi_probes_o             ),
      .cvxif_req_o          ( cvxif_req                 ),
      .cvxif_resp_i         ( cvxif_resp                ),
      .ai_aicfg_o           ( ai_aicfg                  ),
      .ai_ais_o             ( ai_ais                    ),
      .ai_issue_ok_o        ( ai_issue_ok               ),
      .ai_q_en_o            ( ai_q_en                   ),
      .ai_qid_o             ( ai_qid                    ),
      .dirty_ai_state_i     ( dirty_ai_state            ),
      .ai_setcfg_we_i       ( ai_setcfg_we              ),
      .ai_setcfg_wdata_i    ( ai_setcfg_wdata           ),
      .ai_pmu_op_i          ( ai_pmu_op                 ),
      .ai_pmu_mma_i         ( ai_pmu_mma                ),
      .ai_pmu_post_i        ( ai_pmu_post               ),
      .ai_pmu_t0_i          ( ai_pmu_t0                 ),
      .ai_pmu_busy_i        ( ai_pmu_busy               ),
      .noc_req_o            ( noc_req_pre               ),
      .noc_resp_i           ( noc_resp_pre              ),
      .l1_inval_addr_i      ( l1_inval_addr_i           ),
      .l1_inval_valid_i     ( l1_inval_valid_i          ),
      .l1_inval_ready_o     ( l1_inval_ready_o          ),
      .cmo_valid_o          ( cmo_valid_o               ),
      .cmo_op_o             ( cmo_op_o                  ),
      .cmo_addr_o           ( cmo_addr_o                ),
      .cmo_ready_i          ( cmo_ready_i               ),
      .cmo_done_i           ( cmo_done_i                ),
      .l2_miss_i            ( l2_miss_i                 ),
      .l3_hit_i             ( l3_hit_i                  ),
      .l3_miss_i            ( l3_miss_i                 ),
      .pf_issue_i           ( pf_issue_i                ),
      .pf_train_i           ( pf_train_i                ),
      .l2_pwhold_i          ( l2_pwhold_i               ),
      .l3_pwhold_i          ( l3_pwhold_i               ),
      .l2_pf_issue_i        ( l2_pf_issue_i             ),
      .l2_pf_useful_i       ( l2_pf_useful_i            )
    );

    if (G6LCCfg.CvxifEn) begin: gen_cvxif
      if (G6LCCfg.CoproType == config_pkg::COPRO_EXAMPLE) begin: gen_COPRO_EXAMPLE
        assign dirty_ai_state  = 1'b0;
        assign ai_setcfg_we    = 1'b0;
        assign ai_setcfg_wdata = '0;
        assign ai_pmu_op       = 1'b0;
        assign ai_pmu_mma      = 1'b0;
        assign ai_pmu_post     = 1'b0;
        assign ai_pmu_t0       = 1'b0;
        assign ai_pmu_busy     = 1'b0;
        assign ai_sb_enq       = 1'b0;
        assign ai_sb_qid       = '0;
        assign ai_sb_ticket    = '0;
        assign ai_sb_desc_ptr  = '0;
        cvxif_example_coprocessor #(
          .NrRgprPorts (G6LCCfg.NrRgprPorts),
          .XLEN (G6LCCfg.XLEN),
          .readregflags_t (readregflags_t),
          .writeregflags_t (writeregflags_t),
          .id_t (id_t),
          .hartid_t (hartid_t),
          .x_compressed_req_t (x_compressed_req_t),
          .x_compressed_resp_t (x_compressed_resp_t),
          .x_issue_req_t (x_issue_req_t),
          .x_issue_resp_t (x_issue_resp_t),
          .x_register_t (x_register_t),
          .x_commit_t (x_commit_t),
          .x_result_t (x_result_t),
          .cvxif_req_t (cvxif_req_t),
          .cvxif_resp_t (cvxif_resp_t)
        ) i_cvxif_coprocessor (
          .clk_i                ( clk_i                          ),
          .rst_ni               ( rst_ni                         ),
          .cvxif_req_i          ( cvxif_req                      ),
          .cvxif_resp_o         ( cvxif_resp                     )
        );
      end else if (G6LCCfg.CoproType == config_pkg::COPRO_G6LC_AI) begin: gen_COPRO_G6LC_AI
        // Xg6lcai AI matrix plane, seam B (architecture/ai-matrix/README.md §2).
        g6lc_ai_coprocessor #(
          .NrRgprPorts (G6LCCfg.X_NUM_RS),  // per-instr RS count (CVXIF X_NUM_RS)
          .XLEN (G6LCCfg.XLEN),
          .AiCfg (G6LCCfg.AiCfg),
          .readregflags_t (readregflags_t),
          .writeregflags_t (writeregflags_t),
          .id_t (id_t),
          .hartid_t (hartid_t),
          .x_compressed_req_t (x_compressed_req_t),
          .x_compressed_resp_t (x_compressed_resp_t),
          .x_issue_req_t (x_issue_req_t),
          .x_issue_resp_t (x_issue_resp_t),
          .x_register_t (x_register_t),
          .x_commit_t (x_commit_t),
          .x_result_t (x_result_t),
          .cvxif_req_t (cvxif_req_t),
          .cvxif_resp_t (cvxif_resp_t)
        ) i_g6lc_ai_coprocessor (
          .clk_i                ( clk_i                          ),
          .rst_ni               ( rst_ni                         ),
          .cvxif_req_i          ( cvxif_req                      ),
          .cvxif_resp_o         ( cvxif_resp                     ),
          .aicfg_i              ( ai_aicfg                       ),
          .ais_i                ( ai_ais                         ),
          .ai_issue_ok_i        ( ai_issue_ok                    ),
          .ai_q_en_i            ( ai_q_en                        ),
          .ai_qid_i             ( ai_qid                         ),
          .isl_has_completion_i ( ai_isl_has_completion_i        ),
          .isl_retired_valid_i  ( ai_isl_retired_valid_i         ),
          .isl_retired_ticket_i ( ai_isl_retired_ticket_i        ),
          .isl_last_ticket_i    ( ai_isl_last_ticket_i           ),
          .isl_last_status_i    ( ai_isl_last_status_i           ),
          .isl_attached_i       ( ai_isl_attached_i              ),
          .dirty_ai_state_o     ( dirty_ai_state                 ),
          .ai_setcfg_we_o       ( ai_setcfg_we                   ),
          .ai_setcfg_wdata_o    ( ai_setcfg_wdata                ),
          .sb_enq_valid_o       ( ai_sb_enq                      ),
          .sb_enq_ready_i       ( ai_sb_enq_ready_i              ),
          .sb_enq_ticket_i      ( ai_sb_enq_ticket_i             ),
          .sb_qid_o             ( ai_sb_qid                      ),
          .sb_ticket_o          ( ai_sb_ticket                   ),
          .sb_desc_ptr_o        ( ai_sb_desc_ptr                 ),
          .testmode_i           ( 1'b0                           ),
          .ai_pmu_op_o          ( ai_pmu_op                      ),
          .ai_pmu_mma_o         ( ai_pmu_mma                     ),
          .ai_pmu_post_o        ( ai_pmu_post                    ),
          .ai_pmu_t0_o          ( ai_pmu_t0                      ),
          .ai_pmu_busy_o        ( ai_pmu_busy                    )
        );
      end else begin: gen_COPRO_NONE
        assign dirty_ai_state  = 1'b0;
        assign ai_setcfg_we    = 1'b0;
        assign ai_setcfg_wdata = '0;
        assign ai_pmu_op       = 1'b0;
        assign ai_pmu_mma      = 1'b0;
        assign ai_pmu_post     = 1'b0;
        assign ai_pmu_t0       = 1'b0;
        assign ai_pmu_busy     = 1'b0;
        assign ai_sb_enq       = 1'b0;
        assign ai_sb_qid       = '0;
        assign ai_sb_ticket    = '0;
        assign ai_sb_desc_ptr  = '0;
        assign cvxif_resp = '{compressed_ready: 1'b1, issue_ready: 1'b1, register_ready: 1'b1, default: '0};
      end
    end else begin: gen_no_cvxif
      assign dirty_ai_state  = 1'b0;
      assign ai_setcfg_we    = 1'b0;
      assign ai_setcfg_wdata = '0;
      assign ai_pmu_op       = 1'b0;
      assign ai_pmu_mma      = 1'b0;
      assign ai_pmu_post     = 1'b0;
      assign ai_pmu_t0       = 1'b0;
      assign ai_pmu_busy     = 1'b0;
      assign ai_sb_enq       = 1'b0;
      assign ai_sb_qid       = '0;
      assign ai_sb_ticket    = '0;
      assign ai_sb_desc_ptr  = '0;
      assign cvxif_resp = '0;
    end

    assign ai_sb_enq_valid_o = ai_sb_enq;
    assign ai_sb_qid_o       = ai_sb_qid;
    assign ai_sb_ticket_o    = ai_sb_ticket;
    assign ai_sb_desc_ptr_o  = ai_sb_desc_ptr;

  //////////////////////////////////////////////////////////////////////////////
  // U10ᵇ RVV / accelerator path (mutually exclusive with CvxifEn)
  //////////////////////////////////////////////////////////////////////////////
  end else begin : gen_acc

    // Typed accelerator interfaces (acc_dispatcher ↔ Ara)
    `G6LC_TYPEDEF_EXCEPTION(acc_exception_t, G6LCCfg);
    `G6LC_INTF_TYPEDEF_ACC_REQ(accelerator_req_t, G6LCCfg, fpnew_pkg::roundmode_e);
    `G6LC_INTF_TYPEDEF_ACC_RESP(accelerator_resp_t, G6LCCfg, acc_exception_t);
    `G6LC_INTF_TYPEDEF_MMU_REQ(acc_mmu_req_t, G6LCCfg);
    `G6LC_INTF_TYPEDEF_MMU_RESP(acc_mmu_resp_t, G6LCCfg, acc_exception_t);
    `G6LC_INTF_TYPEDEF_G6LC_TO_ACC(g6lc_to_acc_t, accelerator_req_t, acc_mmu_resp_t);
    `G6LC_INTF_TYPEDEF_ACC_TO_G6LC(acc_to_g6lc_t, accelerator_resp_t, acc_mmu_req_t);

    g6lc_to_acc_t acc_req;
    acc_to_g6lc_t acc_resp;

    // Wide Ara AXI (classic Ara: 64 * NrLanes / 2)
    localparam int unsigned AraWideDataWidth = 64 * AraNrLanes / 2;
    localparam int unsigned AraWideStrbWidth = AraWideDataWidth / 8;
    typedef logic [AxiIdWidth-1:0]     ara_id_t;
    typedef logic [AxiAddrWidth-1:0]   ara_addr_t;
    typedef logic [AraWideDataWidth-1:0] ara_data_t;
    typedef logic [AraWideStrbWidth-1:0] ara_strb_t;
    typedef logic                        ara_user_t;
    `AXI_TYPEDEF_ALL(ara_axi, ara_addr_t, ara_id_t, ara_data_t, ara_strb_t, ara_user_t)

    ara_axi_req_t  ara_axi_req;
    ara_axi_resp_t ara_axi_resp;

    noc_req_t  core_noc_req;
    noc_resp_t core_noc_resp;

    g6lc_core #(
      .G6LCCfg ( G6LCCfg ),
      .HypCfg ( HypCfg ),
      .rvfi_probes_instr_t ( rvfi_probes_instr_t ),
      .rvfi_probes_csr_t ( rvfi_probes_csr_t ),
      .rvfi_probes_t ( rvfi_probes_t ),
      .exception_t ( acc_exception_t ),
      .accelerator_req_t ( accelerator_req_t ),
      .accelerator_resp_t ( accelerator_resp_t ),
      .acc_mmu_req_t ( acc_mmu_req_t ),
      .acc_mmu_resp_t ( acc_mmu_resp_t ),
      .axi_ar_chan_t (axi_ar_chan_t),
      .axi_aw_chan_t (axi_aw_chan_t),
      .axi_w_chan_t (axi_w_chan_t),
      .noc_req_t (noc_req_t),
      .noc_resp_t (noc_resp_t),
      .readregflags_t (readregflags_t),
      .writeregflags_t (writeregflags_t),
      .id_t (id_t),
      .hartid_t (hartid_t),
      .x_compressed_req_t (x_compressed_req_t),
      .x_compressed_resp_t (x_compressed_resp_t),
      .x_issue_req_t (x_issue_req_t),
      .x_issue_resp_t (x_issue_resp_t),
      .x_register_t (x_register_t),
      .x_commit_t (x_commit_t),
      .x_result_t (x_result_t),
      .cvxif_req_t (g6lc_to_acc_t),
      .cvxif_resp_t (acc_to_g6lc_t)
    ) i_g6lc (
      .clk_i                ( clk_i                     ),
      .rst_ni               ( rst_ni                    ),
      .boot_addr_i          ( boot_addr_i               ),
      .hart_id_i            ( hart_id_i                 ),
      .irq_i                ( irq_sync_q                ),
      .ipi_i                ( ipi_sync_q                ),
      .time_irq_i           ( time_irq_sync_q           ),
      .rtc_time_i           ( rtc_time_i                ),
      .debug_req_i          ( debug_req_sync_q          ),
      .core_wfi_all_o       ( core_wfi_all_o            ),
      .core_wake_o          ( core_wake_o               ),
      .rvfi_probes_o        ( rvfi_probes_o             ),
      .cvxif_req_o          ( acc_req                   ),
      .cvxif_resp_i         ( acc_resp                  ),
      // AI plane is CVXIF-only (seam B); RVV/acc path leaves sideband idle
      .ai_aicfg_o           ( /* unused */              ),
      .ai_ais_o             ( /* unused */              ),
      .ai_issue_ok_o        ( /* unused */              ),
      .ai_q_en_o            ( /* unused */              ),
      .ai_qid_o             ( /* unused */              ),
      .dirty_ai_state_i     ( 1'b0                      ),
      .ai_setcfg_we_i       ( 1'b0                      ),
      .ai_setcfg_wdata_i    ( '0                        ),
      .ai_pmu_op_i          ( 1'b0                      ),
      .ai_pmu_mma_i         ( 1'b0                      ),
      .ai_pmu_post_i        ( 1'b0                      ),
      .ai_pmu_t0_i          ( 1'b0                      ),
      .ai_pmu_busy_i        ( 1'b0                      ),
      .noc_req_o            ( core_noc_req              ),
      .noc_resp_i           ( core_noc_resp             ),
      .l1_inval_addr_i      ( l1_inval_addr_i           ),
      .l1_inval_valid_i     ( l1_inval_valid_i          ),
      .l1_inval_ready_o     ( l1_inval_ready_o          ),
      .cmo_valid_o          ( cmo_valid_o               ),
      .cmo_op_o             ( cmo_op_o                  ),
      .cmo_addr_o           ( cmo_addr_o                ),
      .cmo_ready_i          ( cmo_ready_i               ),
      .cmo_done_i           ( cmo_done_i                ),
      .l2_miss_i            ( l2_miss_i                 ),
      .l3_hit_i             ( l3_hit_i                  ),
      .l3_miss_i            ( l3_miss_i                 ),
      .pf_issue_i           ( pf_issue_i                ),
      .pf_train_i           ( pf_train_i                ),
      .l2_pwhold_i          ( l2_pwhold_i               ),
      .l3_pwhold_i          ( l3_pwhold_i               ),
      .l2_pf_issue_i        ( l2_pf_issue_i             ),
      .l2_pf_useful_i       ( l2_pf_useful_i            )
    );

    g6lc_ara_attach #(
      .G6LCCfg            ( G6LCCfg ),
      .NrLanes            ( AraNrLanes ),
      .VLEN               ( AraVLEN ),
      .AxiAddrWidth       ( AxiAddrWidth ),
      .AxiIdWidth         ( AxiIdWidth ),
      .AxiNarrowDataWidth ( AxiDataWidth ),
      .AxiWideDataWidth   ( AraWideDataWidth ),
      .exception_t        ( acc_exception_t ),
      .accelerator_req_t  ( accelerator_req_t ),
      .accelerator_resp_t ( accelerator_resp_t ),
      .acc_mmu_req_t      ( acc_mmu_req_t ),
      .acc_mmu_resp_t     ( acc_mmu_resp_t ),
      .g6lc_to_acc_t      ( g6lc_to_acc_t ),
      .acc_to_g6lc_t      ( acc_to_g6lc_t ),
      .ara_axi_req_t      ( ara_axi_req_t ),
      .ara_axi_resp_t     ( ara_axi_resp_t ),
      .ara_axi_ar_t       ( ara_axi_ar_chan_t ),
      .ara_axi_r_t        ( ara_axi_r_chan_t ),
      .ara_axi_aw_t       ( ara_axi_aw_chan_t ),
      .ara_axi_w_t        ( ara_axi_w_chan_t ),
      .ara_axi_b_t        ( ara_axi_b_chan_t )
    ) i_ara_attach (
      .clk_i,
      .rst_ni,
      .scan_enable_i ( 1'b0 ),
      .scan_data_i   ( 1'b0 ),
      .scan_data_o   ( /* unused */ ),
      .acc_req_i     ( acc_req ),
      .acc_resp_o    ( acc_resp ),
      .ara_axi_req_o ( ara_axi_req ),
      .ara_axi_resp_i( ara_axi_resp )
    );

    // Memory merge: always expose narrow noc_req_t to the cluster.
    // - Without G6LC_ARA_ATTACH the attach stub zeros ara_axi → core-only path.
    // - With G6LC_ARA_ATTACH: downsize Ara wide AXI and mux with the core.
`ifdef G6LC_ARA_ATTACH
    // Downsize Ara wide AXI to core/SoC width, then same-ID 2:1 mux.
    noc_req_t  ara_narrow_req;
    noc_resp_t ara_narrow_resp;
    axi_dw_converter #(
      .AxiSlvPortDataWidth ( AraWideDataWidth ),
      .AxiMstPortDataWidth ( AxiDataWidth ),
      .AxiAddrWidth        ( AxiAddrWidth ),
      .AxiIdWidth          ( AxiIdWidth ),
      .AxiMaxReads         ( 4 ),
      .ar_chan_t           ( ara_axi_ar_chan_t ),
      .mst_r_chan_t        ( g6lc_axi::r_chan_t ),
      .slv_r_chan_t        ( ara_axi_r_chan_t ),
      .aw_chan_t           ( axi_aw_chan_t ),
      .b_chan_t            ( g6lc_axi::b_chan_t ),
      .mst_w_chan_t        ( axi_w_chan_t ),
      .slv_w_chan_t        ( ara_axi_w_chan_t ),
      .axi_mst_req_t       ( noc_req_t ),
      .axi_mst_resp_t      ( noc_resp_t ),
      .axi_slv_req_t       ( ara_axi_req_t ),
      .axi_slv_resp_t      ( ara_axi_resp_t )
    ) i_ara_dwc (
      .clk_i,
      .rst_ni,
      .slv_req_i  ( ara_axi_req ),
      .slv_resp_o ( ara_axi_resp ),
      .mst_req_o  ( ara_narrow_req ),
      .mst_resp_i ( ara_narrow_resp )
    );
    g6lc_axi_2to1_mux #(
      .axi_req_t  ( noc_req_t ),
      .axi_resp_t ( noc_resp_t )
    ) i_core_ara_mux (
      .clk_i,
      .rst_ni,
      .slv0_req_i  ( ara_narrow_req ),
      .slv0_resp_o ( ara_narrow_resp ),
      .slv1_req_i  ( core_noc_req ),
      .slv1_resp_o ( core_noc_resp ),
      .mst_req_o   ( noc_req_pre ),
      .mst_resp_i  ( noc_resp_pre )
    );
`else
    // Stub attach: Ara AXI idle; core owns the memory port.
    assign noc_req_pre    = core_noc_req;
    assign core_noc_resp  = noc_resp_pre;
    assign ara_axi_resp   = '0;
`endif

    assign ai_sb_enq_valid_o = 1'b0;
    assign ai_sb_qid_o       = '0;
    assign ai_sb_ticket_o    = '0;
    assign ai_sb_desc_ptr_o  = '0;

  end // gen_acc

endmodule // the core
