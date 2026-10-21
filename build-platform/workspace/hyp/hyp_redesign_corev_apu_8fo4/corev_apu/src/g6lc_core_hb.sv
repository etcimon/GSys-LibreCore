// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_core_hb -- the per-core unit of hierarchical Verilation.
//
// A pure pass-through around `the core` whose parameterisation is closed over
// the target package: no `parameter type`, no struct parameter at the
// boundary (Verilator's hier_block accepts only integer/real/string
// parameters, and a 19 k-bit G6LCCfg on the child command line is not a
// boundary anyone wants). With `--hierarchical` and the `hier_block` entry in
// `verilator_config.vlt`, Verilator builds this module once as a library and
// the cluster's NrCores instances share it: the core's generated code exists
// once (verilation and C++ compile time scale with one core plus the uncore),
// each instance is evaluated by its own scheduler -- a core whose clock is held
// by the sleep gate costs its input-change check and nothing else -- and the
// gated clock stays a primary input of the child instead of a derived domain
// in the cluster's partition (the T22 CoreSleepGate measurement charged 17 %
// for exactly that merge). Without `--hierarchical` the pragma is ignored and
// this is an ordinary wrapper the inliner removes: no physical change either
// way; the synthesis hierarchy is unchanged (the cluster still instantiates
// one `the core` per core).
//
// Selected by `+define+G6LC_CORE_HB` in g6lc_cluster.sv. The cluster's own
// G6LCCfg must be the target package's configuration (it is, in every
// testharness); a mismatch is an elaboration error, never a silent divergence.

`include "rvfi_types.svh"

module g6lc_core_hb
  import g6lc_core_pkg::*;
(
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic [g6lc_core_hb_pkg::VLEN-1:0]  boot_addr_i,
  input  logic [g6lc_core_hb_pkg::XLEN-1:0]  hart_id_i,
  input  logic [g6lc_core_hb_pkg::NH-1:0][1:0] irq_i,
  input  logic [g6lc_core_hb_pkg::NH-1:0]      ipi_i,
  input  logic [g6lc_core_hb_pkg::NH-1:0]      time_irq_i,
  input  logic [63:0]                  rtc_time_i,
  input  logic                         debug_req_i,
  output logic                         core_wfi_all_o,
  output logic                         core_wake_o,
  output g6lc_core_hb_pkg::rvfi_probes_t rvfi_probes_o,
  output g6lc_axi::req_t             noc_req_o,
  input  g6lc_axi::resp_t            noc_resp_i,
  input  logic [63:0]                  l1_inval_addr_i,
  input  logic                         l1_inval_valid_i,
  output logic                         l1_inval_ready_o,
  output logic                         cmo_valid_o,
  output logic [1:0]                   cmo_op_o,
  output logic [g6lc_core_hb_pkg::PLEN-1:0] cmo_addr_o,
  input  logic                         cmo_ready_i,
  input  logic                         cmo_done_i,
  input  logic                         l2_miss_i,
  input  logic                         l3_hit_i,
  input  logic                         l3_miss_i,
  input  logic                         pf_issue_i,
  input  logic                         pf_train_i,
  input  logic                         l2_pwhold_i,
  input  logic                         l3_pwhold_i,
  input  logic                         l2_pf_issue_i,
  input  logic                         l2_pf_useful_i,
  output logic                         ai_sb_enq_valid_o,
  input  logic                         ai_sb_enq_ready_i,
  input  logic [31:0]                  ai_sb_enq_ticket_i,
  output logic [7:0]                   ai_sb_qid_o,
  output logic [31:0]                  ai_sb_ticket_o,
  output logic [g6lc_core_hb_pkg::XLEN-1:0] ai_sb_desc_ptr_o,
  input  logic                         ai_isl_attached_i,
  input  logic                         ai_isl_has_completion_i,
  input  logic                         ai_isl_retired_valid_i,
  input  logic [31:0]                  ai_isl_retired_ticket_i,
  input  logic [31:0]                  ai_isl_last_ticket_i,
  input  logic [15:0]                  ai_isl_last_status_i
);
  // The metacomment binds only under --hierarchical (see the header).
  /*verilator hier_block*/

  g6lc_hart #(
      .G6LCCfg       (g6lc_core_hb_pkg::Cfg),
      .rvfi_probes_t (g6lc_core_hb_pkg::rvfi_probes_t),
      .noc_req_t     (g6lc_axi::req_t),
      .noc_resp_t    (g6lc_axi::resp_t)
  ) i_g6lc (
      .clk_i,
      // The hart's axi_cdc dst side is the cluster/uncore clock — the closed
      // wrapper is only instantiated in the clk_i-fabric cluster (H13), so
      // tie it here. Left unconnected the CDC dst never clocks.
      .clk_uncore_i     (clk_i),
      .rst_ni,
      .boot_addr_i,
      .hart_id_i,
      .irq_i,
      .ipi_i,
      .time_irq_i,
      .rtc_time_i,
      .debug_req_i,
      .core_wfi_all_o,
      .core_wake_o,
      .rvfi_probes_o,
      .noc_req_o,
      .noc_resp_i,
      .l1_inval_addr_i,
      .l1_inval_valid_i,
      .l1_inval_ready_o,
      .cmo_valid_o,
      .cmo_op_o,
      .cmo_addr_o,
      .cmo_ready_i,
      .cmo_done_i,
      .l2_miss_i,
      .l3_hit_i,
      .l3_miss_i,
      .pf_issue_i,
      .pf_train_i,
      .l2_pwhold_i,
      .l3_pwhold_i,
      .l2_pf_issue_i,
      .l2_pf_useful_i,
      .ai_sb_enq_valid_o,
      .ai_sb_enq_ready_i,
      .ai_sb_enq_ticket_i,
      .ai_sb_qid_o,
      .ai_sb_ticket_o,
      .ai_sb_desc_ptr_o,
      .ai_isl_attached_i,
      .ai_isl_has_completion_i,
      .ai_isl_retired_valid_i,
      .ai_isl_retired_ticket_i,
      .ai_isl_last_ticket_i,
      .ai_isl_last_status_i
  );

endmodule
