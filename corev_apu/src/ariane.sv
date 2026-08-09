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
// Description: Ariane Top-level module
//
// U10ᵇ: When CVA6Cfg.EnableAccelerator (RVV), the CVXIF path is replaced by
// typed accelerator interfaces + g6lc_ara_attach. Live Ara IP requires
// `define CVA6_ARA_ATTACH and vendor/ara on the flist; otherwise the attach
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
`include "cva6_acc_intf.svh"
`include "axi/typedef.svh"

module ariane import ariane_pkg::*; #(
  parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
  parameter type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg),
  parameter type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(CVA6Cfg),
  parameter type rvfi_probes_t = struct packed {
    logic csr;
    rvfi_probes_instr_t instr;
  },

  // CVXIF Types
  localparam type readregflags_t      = `READREGFLAGS_T(CVA6Cfg),
  localparam type writeregflags_t     = `WRITEREGFLAGS_T(CVA6Cfg),
  localparam type id_t                = `ID_T(CVA6Cfg),
  localparam type hartid_t            = `HARTID_T(CVA6Cfg),
  localparam type x_compressed_req_t  = `X_COMPRESSED_REQ_T(CVA6Cfg, hartid_t),
  localparam type x_compressed_resp_t = `X_COMPRESSED_RESP_T(CVA6Cfg),
  localparam type x_issue_req_t       = `X_ISSUE_REQ_T(CVA6Cfg, hartid_t, id_t),
  localparam type x_issue_resp_t      = `X_ISSUE_RESP_T(CVA6Cfg, writeregflags_t, readregflags_t),
  localparam type x_register_t        = `X_REGISTER_T(CVA6Cfg, hartid_t, id_t, readregflags_t),
  localparam type x_commit_t          = `X_COMMIT_T(CVA6Cfg, hartid_t, id_t),
  localparam type x_result_t          = `X_RESULT_T(CVA6Cfg, hartid_t, id_t, writeregflags_t),
  localparam type cvxif_req_t         = `CVXIF_REQ_T(CVA6Cfg, x_compressed_req_t, x_issue_req_t, x_register_t, x_commit_t),
  localparam type cvxif_resp_t        = `CVXIF_RESP_T(CVA6Cfg, x_compressed_resp_t, x_issue_resp_t, x_result_t),
  // AXI Types
  parameter int unsigned AxiAddrWidth = ariane_axi::AddrWidth,
  parameter int unsigned AxiDataWidth = ariane_axi::DataWidth,
  parameter int unsigned AxiIdWidth   = ariane_axi::IdWidth,
  parameter type axi_ar_chan_t = ariane_axi::ar_chan_t,
  parameter type axi_aw_chan_t = ariane_axi::aw_chan_t,
  parameter type axi_w_chan_t  = ariane_axi::w_chan_t,
  parameter type noc_req_t = ariane_axi::req_t,
  parameter type noc_resp_t = ariane_axi::resp_t,
  // Ara geometry (U10ᵇ) — only used when EnableAccelerator
  parameter int unsigned AraNrLanes = 4,
  parameter int unsigned AraVLEN    = 4096
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  // Core ID, Cluster ID and boot address are considered more or less static
  input  logic [CVA6Cfg.VLEN-1:0]       boot_addr_i,  // reset boot address
  input  logic [CVA6Cfg.XLEN-1:0]       hart_id_i,    // hart id in a multicore environment (reflected in a CSR)

  // Interrupt inputs (per SMT hart; NrHarts==1 → scalar-equivalent widths)
  input  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][1:0] irq_i,
  input  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0]     ipi_i,
  // Timer facilities (per SMT hart / CLINT MSIP·MTIP slot)
  input  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0]     time_irq_i,
  // Platform mtime counter value for Sstc (tie to '0 when CVA6Cfg.SstcEn is 0)
  input  logic [63:0]                  rtc_time_i,
  input  logic                         debug_req_i,  // debug request (async)
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
  // PMU group 2 hierarchy probes (tie 0 when unused)
  input  logic                         l2_miss_i,
  input  logic                         l3_hit_i,
  input  logic                         l3_miss_i,
  input  logic                         pf_issue_i,
  input  logic                         pf_train_i
);

  //////////////////////////////////////////////////////////////////////////////
  // Standard path: CVXIF or bare core (no RVV accelerator)
  //////////////////////////////////////////////////////////////////////////////
  if (!CVA6Cfg.EnableAccelerator) begin : gen_std

    cvxif_req_t  cvxif_req;
    cvxif_resp_t cvxif_resp;

    cva6 #(
      .CVA6Cfg ( CVA6Cfg ),
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
    ) i_cva6 (
      .clk_i                ( clk_i                     ),
      .rst_ni               ( rst_ni                    ),
      .boot_addr_i          ( boot_addr_i               ),
      .hart_id_i            ( hart_id_i                 ),
      .irq_i                ( irq_i                     ),
      .ipi_i                ( ipi_i                     ),
      .time_irq_i           ( time_irq_i                ),
      .rtc_time_i           ( rtc_time_i                ),
      .debug_req_i          ( debug_req_i               ),
      .rvfi_probes_o        ( rvfi_probes_o             ),
      .cvxif_req_o          ( cvxif_req                 ),
      .cvxif_resp_i         ( cvxif_resp                ),
      .noc_req_o            ( noc_req_o                 ),
      .noc_resp_i           ( noc_resp_i                ),
      .l1_inval_addr_i      ( l1_inval_addr_i           ),
      .l1_inval_valid_i     ( l1_inval_valid_i          ),
      .l1_inval_ready_o     ( l1_inval_ready_o          ),
      .l2_miss_i            ( l2_miss_i                 ),
      .l3_hit_i             ( l3_hit_i                  ),
      .l3_miss_i            ( l3_miss_i                 ),
      .pf_issue_i           ( pf_issue_i                ),
      .pf_train_i           ( pf_train_i                )
    );

    if (CVA6Cfg.CvxifEn) begin: gen_cvxif
      if (CVA6Cfg.CoproType == config_pkg::COPRO_EXAMPLE) begin: gen_COPRO_EXAMPLE
        cvxif_example_coprocessor #(
          .NrRgprPorts (CVA6Cfg.NrRgprPorts),
          .XLEN (CVA6Cfg.XLEN),
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
      end else if (CVA6Cfg.CoproType == config_pkg::COPRO_G6LC_AI) begin: gen_COPRO_G6LC_AI
        // Xg6lcai AI matrix plane, seam B (architecture/ai-matrix/README.md §2).
        // P1: real CVXIF coprocessor (core/cvxif_g6lc_ai/). Mask/match + T0
        // execute; T1/T2 groups accept and stub-complete until tile SRAM / DMA.
        g6lc_ai_coprocessor #(
          .NrRgprPorts (CVA6Cfg.X_NUM_RS),  // per-instr RS count (CVXIF X_NUM_RS)
          .XLEN (CVA6Cfg.XLEN),
          .AiCfg (CVA6Cfg.AiCfg),
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
          .cvxif_resp_o         ( cvxif_resp                     )
        );
      end else begin: gen_COPRO_NONE
        assign cvxif_resp = '{compressed_ready: 1'b1, issue_ready: 1'b1, register_ready: 1'b1, default: '0};
      end
    end else begin: gen_no_cvxif
      assign cvxif_resp = '0;
    end

  //////////////////////////////////////////////////////////////////////////////
  // U10ᵇ RVV / accelerator path (mutually exclusive with CvxifEn)
  //////////////////////////////////////////////////////////////////////////////
  end else begin : gen_acc

    // Typed accelerator interfaces (acc_dispatcher ↔ Ara)
    `CVA6_TYPEDEF_EXCEPTION(acc_exception_t, CVA6Cfg);
    `CVA6_INTF_TYPEDEF_ACC_REQ(accelerator_req_t, CVA6Cfg, fpnew_pkg::roundmode_e);
    `CVA6_INTF_TYPEDEF_ACC_RESP(accelerator_resp_t, CVA6Cfg, acc_exception_t);
    `CVA6_INTF_TYPEDEF_MMU_REQ(acc_mmu_req_t, CVA6Cfg);
    `CVA6_INTF_TYPEDEF_MMU_RESP(acc_mmu_resp_t, CVA6Cfg, acc_exception_t);
    `CVA6_INTF_TYPEDEF_CVA6_TO_ACC(cva6_to_acc_t, accelerator_req_t, acc_mmu_resp_t);
    `CVA6_INTF_TYPEDEF_ACC_TO_CVA6(acc_to_cva6_t, accelerator_resp_t, acc_mmu_req_t);

    cva6_to_acc_t acc_req;
    acc_to_cva6_t acc_resp;

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

    cva6 #(
      .CVA6Cfg ( CVA6Cfg ),
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
      .cvxif_req_t (cva6_to_acc_t),
      .cvxif_resp_t (acc_to_cva6_t)
    ) i_cva6 (
      .clk_i                ( clk_i                     ),
      .rst_ni               ( rst_ni                    ),
      .boot_addr_i          ( boot_addr_i               ),
      .hart_id_i            ( hart_id_i                 ),
      .irq_i                ( irq_i                     ),
      .ipi_i                ( ipi_i                     ),
      .time_irq_i           ( time_irq_i                ),
      .rtc_time_i           ( rtc_time_i                ),
      .debug_req_i          ( debug_req_i               ),
      .rvfi_probes_o        ( rvfi_probes_o             ),
      .cvxif_req_o          ( acc_req                   ),
      .cvxif_resp_i         ( acc_resp                  ),
      .noc_req_o            ( core_noc_req              ),
      .noc_resp_i           ( core_noc_resp             ),
      .l1_inval_addr_i      ( l1_inval_addr_i           ),
      .l1_inval_valid_i     ( l1_inval_valid_i          ),
      .l1_inval_ready_o     ( l1_inval_ready_o          ),
      .l2_miss_i            ( l2_miss_i                 ),
      .l3_hit_i             ( l3_hit_i                  ),
      .l3_miss_i            ( l3_miss_i                 ),
      .pf_issue_i           ( pf_issue_i                ),
      .pf_train_i           ( pf_train_i                )
    );

    g6lc_ara_attach #(
      .CVA6Cfg            ( CVA6Cfg ),
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
      .cva6_to_acc_t      ( cva6_to_acc_t ),
      .acc_to_cva6_t      ( acc_to_cva6_t ),
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
    // - Without CVA6_ARA_ATTACH the attach stub zeros ara_axi → core-only path.
    // - With CVA6_ARA_ATTACH: downsize Ara wide AXI and mux with the core.
`ifdef CVA6_ARA_ATTACH
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
      .mst_r_chan_t        ( ariane_axi::r_chan_t ),
      .slv_r_chan_t        ( ara_axi_r_chan_t ),
      .aw_chan_t           ( axi_aw_chan_t ),
      .b_chan_t            ( ariane_axi::b_chan_t ),
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
      .mst_req_o   ( noc_req_o ),
      .mst_resp_i  ( noc_resp_i )
    );
`else
    // Stub attach: Ara AXI idle; core owns the memory port.
    assign noc_req_o      = core_noc_req;
    assign core_noc_resp  = noc_resp_i;
    assign ara_axi_resp   = '0;
`endif

  end // gen_acc

endmodule // ariane
