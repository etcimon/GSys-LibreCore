// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Lint/elab top for the UNCORE cluster.
//
// core/Flist.cva6 elaborates top `cva6`, which contains none of g6lc_cluster,
// g6lc_l2_top, g6lc_l3_top or g6lc_server_prefetcher — so the whole cache
// hierarchy sat outside the gate's lint and synthesis coverage. This top puts
// it under the gate, including the direct L2-to-L3 abutment the cluster wires.
//
// g6lc_cluster cannot itself be the lint top: as top, its parameters take their
// defaults (`cva6_cfg_empty`, `axi_req_t = logic`), which elaborates a nonsense
// configuration — MEM_TID_WIDTH 0, degenerate CBOZ beat counts. Same reason
// g6lc_ara_lint_top exists for the vector path: bind the real config package and
// concrete AXI structs, then instantiate.
//
// Requires TARGET_CFG=<the target whose package is on the flist> and
// corev_apu/Flist.cluster via verify.extraFlistsByTarget.

// The only L3En=1 targets that refuse elaboration are the ones whose OoO+FP
// combination is still illegal: multi-hart FP with MIXED residency (the
// T9g/M4 guard keeps `OoOEn && FpPresent && NrHarts > 1 && !SmtDrainedHandoff`
// refused). Single-hart and drained-handoff FP are production legs and keep
// OoOEn here, so g6lc64_ooo_int2_l3 elaborates the real COH_OOO hub with the
// FP class enabled — the hierarchy coverage this top exists for. One field,
// chosen because the OoO backend has its own leaf suites and its own refusal
// checks (review-ooo-illegal-*), whereas the cache hierarchy had no gate
// coverage at all. Integer packages keep OoOEn unconditionally: the COH_OOO
// hub is only legal with the OoO backend present, and g6lc64_ooo_int2 exists
// precisely to put that hub under the gate.
function automatic config_pkg::cva6_cfg_t uncore_lint_cfg();
  config_pkg::cva6_cfg_t c;
  c = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  if (c.FpPresent && c.OoOEn && c.NrHarts > 1 && !c.SmtDrainedHandoff)
    c.OoOEn = 1'b0;
`ifdef SYNTHESIS
  // Synthesis smoke only: the generic BEHAVIOURAL tc_sram model cannot be
  // elaborated by the synthesis frontend at the production cache geometry (its
  // reset construct is rejected as an asynchronous load pattern once the array
  // is large). A real flow binds a compiled macro at that seam, which is the
  // documented PDK-swap boundary — so a smaller geometry here checks the
  // hierarchy's synthesizability and latch-freedom, and says nothing about area
  // or about production-geometry closure. Lint keeps the production geometry.
  c.L2ByteSize = 32'd16384;
  c.L3ByteSize = 32'd32768;
`endif
  return c;
endfunction

module g6lc_cluster_lint_top
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = uncore_lint_cfg(),
    // Two cores for lint so the coherence hub, its arbitration and the L1
    // invalidation adapters are elaborated rather than folded away by the N=1
    // fast path. For synthesis one core: two cores took the smoke past twenty
    // minutes, which is too slow for a per-change gate, and the cache hierarchy
    // under test is identical either way. What shrinks is the hub's N-core
    // arbitration, which has its own leaf suites (review-incl-evict, the hub
    // records) rather than no coverage. COH_OOO refuses a single core, so that
    // policy synthesizes its package's core count (the opt-in int2 gate).
`ifdef SYNTHESIS
    parameter int unsigned NR_CORES =
        (CVA6Cfg.CohPolicy == config_pkg::COH_OOO) ? CVA6Cfg.NrCores : 1
`else
    parameter int unsigned NR_CORES =
        (CVA6Cfg.CohPolicy == config_pkg::COH_OOO) ? CVA6Cfg.NrCores : 2
`endif
);
  logic clk_i, rst_ni;
  ariane_axi::req_t  mem_req;
  ariane_axi::resp_t mem_resp;
  assign mem_resp = '0;

  // The real probe struct, built exactly as ariane defaults it. A `logic` stub
  // is not usable: cva6_rvfi_probes writes members of this type.
  typedef `RVFI_PROBES_INSTR_T(CVA6Cfg) rvfi_probes_instr_t;
  typedef `RVFI_PROBES_CSR_T(CVA6Cfg) rvfi_probes_csr_t;
  typedef struct packed {
    rvfi_probes_csr_t csr;
    rvfi_probes_instr_t instr;
  } rvfi_probes_lint_t;

  g6lc_cluster #(
      .CVA6Cfg        (CVA6Cfg),
      .NR_CORES       (NR_CORES),
      .L2_ENABLE      (1'b1),
      .IDENTITY_FAST  (1'b0),
      // policy comes from CVA6Cfg.L3InclusiveEn
      .INCLUSIVE_L3   (1'b0),
      .AXI_ADDR_WIDTH (CVA6Cfg.AxiAddrWidth),
      .AXI_DATA_WIDTH (CVA6Cfg.AxiDataWidth),
      .AXI_ID_WIDTH   (CVA6Cfg.AxiIdWidth),
      .AXI_USER_WIDTH (CVA6Cfg.AxiUserWidth),
      .axi_req_t      (ariane_axi::req_t),
      .axi_resp_t     (ariane_axi::resp_t),
      .rvfi_probes_t  (rvfi_probes_lint_t)
  ) i_cluster (
      .clk_i,
      .rst_ni,
      .boot_addr_i       ('0),
      .boot_addr_core_i  ('0),
      .irq_i             ('0),
      .ipi_i             ('0),
      .time_irq_i        ('0),
      .rtc_time_i        ('0),
      .debug_req_i       ('0),
      .mem_req_o         (mem_req),
      .mem_resp_i        (mem_resp),
      .rvfi_probes_o     (),
      .l2_miss_o         (),
      .l3_hit_o          (),
      .l3_miss_o         (),
      .pf_issue_o        (),
      .pf_train_o        (),
      .ai_sb_enq_valid_o (),
      .ai_sb_enq_ready_i(1'b1),
      .ai_sb_qid_o       (),
      .ai_sb_ticket_o    (),
      .ai_sb_desc_ptr_o  (),
      .ai_isl_has_completion_i (1'b0),
      .ai_isl_retired_valid_i(1'b0),
      .ai_isl_retired_ticket_i('0),
      .ai_isl_attached_i(1'b0),
      .ai_isl_last_ticket_i    ('0),
      .ai_isl_last_status_i    ('0)
  );

endmodule
