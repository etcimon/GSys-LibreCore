// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Typed lint/synthesis tops for individual uncore modules.
//
// Why these are needed. `run_cluster_synth_review.py` synthesises uncore modules
// as top, in parallel, because the whole-cluster target is too slow to finish.
// But several of those modules type their ports through
// `parameter type axi_req_t = logic`, and as top they take that default — so
// member access on a `logic` becomes illegal and the module cannot be synthesised
// at all ("invalid member access for type 'axi_resp_t' (aka 'logic')").
//
// Worse, the ones whose width/count parameters also default can still exit 0
// while emitting ZERO cells: with `NR_CORES = 1` the coherence hub, the
// invalidation bus and the snoop filter all collapse to their degenerate path, so
// a run "passed" having synthesised nothing. That is a vacuous pass, and it is why
// the runner now requires `cells > 0`.
//
// Each top below therefore does two things and nothing else: bind CONCRETE AXI
// struct types, and pick parameters that keep the interesting logic alive
// (NR_CORES = 2, snoop filter enabled). Same device as `g6lc_cluster_lint_top`,
// applied per module so a failure names one module instead of the whole cluster.
//
// Ports are PASSED THROUGH, not tied off. The first version of this file tied every
// input to a constant and left the outputs dangling, on the theory that a synthesis
// smoke only needs the module elaborated. That was wrong in a way worth recording:
// `opt` then deletes the entire design as unreachable, and `stat` reported wires and
// ports with NO CELLS. The run looked successful (rc 0, no latches) while
// synthesising nothing at all — a vacuous pass manufactured by the harness rather
// than found in the RTL.
//
// So each top re-exports the DUT's interface with concrete types. That keeps every
// cell reachable, which is the entire point of the exercise.
//
// This remains a smoke: elaboration, synthesizability and latch-freedom only. Every
// module here already has its own functional suite (review-hub-*, review-sf-*,
// review-mux-*, review-retain-*); this adds the synthesis evidence those suites do
// not provide, and claims nothing about behaviour.
//
// Requires TARGET_CFG's config package plus corev_apu/Flist.cluster.

//  NOTE on imports: `coh_inval_t` and the COH_DEFAULT_* sizes come from
//  g6lc_coherence_pkg, but `coh_policy_t` and `COH_FILTERED` come from config_pkg.
//  Importing only the former fails with "use of undeclared identifier
//  'COH_FILTERED'" -- the hub itself imports both, which is the clue.

//  Coherence hub: NR_CORES = 2 and the snoop filter enabled, because at NR_CORES = 1
//  the target-set generation, the arbiter and the whole filtered path fold away —
//  which is exactly how this module previously "synthesised" to nothing.
module g6lc_coherence_hub_lint_top
  import g6lc_coherence_pkg::*;
  import config_pkg::*;
#(
    parameter int unsigned NR_CORES = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  ariane_axi::req_t  [NR_CORES-1:0] core_req,
    output ariane_axi::resp_t [NR_CORES-1:0] core_resp,
    output ariane_axi::req_t                 mem_req,
    input  ariane_axi::resp_t                mem_resp,
    output coh_inval_t        [NR_CORES-1:0] inv_core,
    input  logic              [NR_CORES-1:0] inv_core_ready,
    input  logic                             lr_valid,
    input  logic [63:0]                      lr_addr,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] lr_core,
    output logic coh_inv_fire,
    output logic coh_sf_hit,
    output logic coh_sf_overapprox,
    output logic coh_arb_starve,
    output logic coh_split_conflict,
    output logic coh_sc_noresv,
    output logic coh_lr_kill
);

  g6lc_coherence_hub #(
      .NR_CORES       (NR_CORES),
      .SNOOP_FILTER_EN(1'b1),
      .POLICY         (COH_FILTERED),
      .axi_req_t      (ariane_axi::req_t),
      .axi_resp_t     (ariane_axi::resp_t)
  ) i_hub (
      .clk_i,
      .rst_ni,
      .core_req_i          (core_req),
      .core_resp_o         (core_resp),
      .mem_req_o           (mem_req),
      .mem_resp_i          (mem_resp),
      .inv_core_o          (inv_core),
      .inv_core_ready_i    (inv_core_ready),
      .lr_valid_i          (lr_valid),
      .lr_addr_i           (lr_addr),
      .lr_core_i           (lr_core),
      .coh_inv_fire_o      (coh_inv_fire),
      .coh_sf_hit_o        (coh_sf_hit),
      .coh_sf_overapprox_o (coh_sf_overapprox),
      .coh_arb_starve_o    (coh_arb_starve),
      .coh_split_conflict_o(coh_split_conflict),
      .coh_sc_noresv_o     (coh_sc_noresv),
      .coh_lr_kill_o       (coh_lr_kill),
      .hub_aw_sc_collide_o (),
      .hub_ar_wr_hold_o    (),
      .hub_aw_hold_slot_o  (),
      .hub_aw_hold_other_o ()
  );
endmodule

//  Invalidation bus: NR_CORES = 2 so there are per-core FIFOs to synthesise and a
//  target bitset wide enough to matter.
module g6lc_inval_bus_lint_top
  import g6lc_coherence_pkg::*;
  import config_pkg::*;
#(
    parameter int unsigned NR_CORES = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  coh_inval_t                inv_req,
    input  logic [NR_CORES-1:0]       inv_target,
    output logic                      inv_ready,
    output coh_inval_t [NR_CORES-1:0] inv_core,
    input  logic       [NR_CORES-1:0] inv_core_ready,
    output logic                      inv_stall,
    output logic                      inv_coalesce,
    output logic [NR_CORES-1:0][COH_INV_SEQ_W-1:0] inv_enq_seq,
    output logic [NR_CORES-1:0][COH_INV_SEQ_W-1:0] inv_deq_seq
);

  g6lc_inval_bus #(
      .NR_CORES(NR_CORES)
  ) i_bus (
      .clk_i,
      .rst_ni,
      .inv_req_i       (inv_req),
      .inv_target_i    (inv_target),
      .inv_ready_o     (inv_ready),
      .inv_core_o      (inv_core),
      .inv_core_ready_i(inv_core_ready),
      .inv_stall_o     (inv_stall),
      .inv_coalesce_o  (inv_coalesce),
      .inv_enq_seq_o   (inv_enq_seq),
      .inv_deq_seq_o   (inv_deq_seq)
  );
endmodule

//  Snoop filter: Enable=1 and NR_CORES=2. With Enable=0 or one core the sharer
//  bitset degenerates and the tag array disappears, which is the vacuous case.
module g6lc_snoop_filter_lint_top
  import g6lc_coherence_pkg::*;
  import config_pkg::*;
#(
    parameter int unsigned NR_CORES = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic        alloc_valid,
    input  logic [63:0] alloc_addr,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] alloc_core,
    input  logic        clear_valid,
    input  logic [63:0] clear_addr,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] clear_core,
    input  logic        clear_all,
    input  logic        lookup_valid,
    input  logic [63:0] lookup_addr,
    output logic [NR_CORES-1:0] present,
    output logic        lookup_hit,
    output logic        overapprox
);

  g6lc_snoop_filter #(
      .Enable  (1'b1),
      .NR_CORES(NR_CORES)
  ) i_sf (
      .clk_i,
      .rst_ni,
      .alloc_valid_i (alloc_valid),
      .alloc_addr_i  (alloc_addr),
      .alloc_core_i  (alloc_core),
      .clear_valid_i (clear_valid),
      .clear_addr_i  (clear_addr),
      .clear_core_i  (clear_core),
      .clear_all_i   (clear_all),
      .lookup_valid_i(lookup_valid),
      .lookup_addr_i (lookup_addr),
      .present_o     (present),
      .lookup_hit_o  (lookup_hit),
      .overapprox_o  (overapprox)
  );
endmodule

//  AXI 2:1 mux: needs nothing but concrete struct types. This is the module whose
//  response misrouting was repaired earlier in this review, so having synthesis
//  evidence for it is not academic.
module g6lc_axi_2to1_mux_lint_top (
    input  logic clk_i,
    input  logic rst_ni,
    input  ariane_axi::req_t  slv0_req,
    output ariane_axi::resp_t slv0_resp,
    input  ariane_axi::req_t  slv1_req,
    output ariane_axi::resp_t slv1_resp,
    output ariane_axi::req_t  mst_req,
    input  ariane_axi::resp_t mst_resp
);

  g6lc_axi_2to1_mux #(
      .axi_req_t (ariane_axi::req_t),
      .axi_resp_t(ariane_axi::resp_t)
  ) i_mux (
      .clk_i,
      .rst_ni,
      .slv0_req_i (slv0_req),
      .slv0_resp_o(slv0_resp),
      .slv1_req_i (slv1_req),
      .slv1_resp_o(slv1_resp),
      .mst_req_o  (mst_req),
      .mst_resp_i (mst_resp)
  );
endmodule

//  ---------------------------------------------------------------------------
//  L2, L3 and the prefetcher.
//
//  These three need the same geometry treatment as g6lc_cluster_lint_top: under
//  `SYNTHESIS` the behavioural `tc_sram` model cannot be elaborated by the synthesis
//  frontend at production cache size (its reset construct is rejected as an
//  asynchronous load pattern once the array is large), so the arrays are shrunk here.
//  That is a real limitation of the generic model, not of the design — a production
//  flow binds a compiled macro at that seam, which is the documented PDK-swap
//  boundary. Consequently these runs check synthesizability and latch-freedom ONLY;
//  they say nothing about area or about closure at production geometry, and any cell
//  count from them must not be quoted as an area figure.
//
//  Lint keeps the production geometry, as it does for the cluster top.
//  ---------------------------------------------------------------------------

module g6lc_l2_top_lint_top
  import g6lc_l2_pkg::*;
#(
`ifdef SYNTHESIS
    parameter int unsigned BYTE_SIZE = 32'd16384
`else
    parameter int unsigned BYTE_SIZE = L2_DEFAULT_BYTE_SIZE
`endif
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  ariane_axi::req_t  slv_req,
    output ariane_axi::resp_t slv_resp,
    output ariane_axi::req_t  mst_req,
    input  ariane_axi::resp_t mst_resp,
    output logic        l2_hit,
    output logic        l2_miss,
    output logic        l2_bypass,
    output logic        l2_mshr_full,
    output logic        l2_bank_conflict,
    output logic        l2_evict_valid,
    output logic [63:0] l2_evict_addr,
    input  logic        l2_evict_ready,
    input  logic        l2_back_inval_valid,
    input  logic [63:0] l2_back_inval_addr,
    output logic        l2_back_inval_ready
);
  g6lc_l2_top #(
      .Enable    (1'b1),
      .BYTE_SIZE (BYTE_SIZE),
      .axi_req_t (ariane_axi::req_t),
      .axi_resp_t(ariane_axi::resp_t)
  ) i_l2 (
      .clk_i,
      .rst_ni,
      .slv_req_i            (slv_req),
      .slv_resp_o           (slv_resp),
      .mst_req_o            (mst_req),
      .mst_resp_i           (mst_resp),
      .l2_hit_o             (l2_hit),
      .l2_miss_o            (l2_miss),
      .l2_bypass_o          (l2_bypass),
      .l2_mshr_full_o       (l2_mshr_full),
      .l2_bank_conflict_o   (l2_bank_conflict),
      .l2_selfinv_hit_o     (),
      .l2_wupdate_o         (),
      .l2_wtrk_full_o       (),
      .l2_wtrk_line_hold_o  (),
      .l2_hold_r1_o         (),
      .l2_hold_r1_wu_o      (),
      .l2_hold_r2_o         (),
      .l2_posted_o          (),
      .l2_rdtrk_o           (),
      .l2_posted_hold_o     (),
      .l2_pf_issue_o        (),
      .l2_pf_useful_o       (),
      .l2_pf_drop_o         (),
      .l2_evict_valid_o     (l2_evict_valid),
      .l2_evict_addr_o      (l2_evict_addr),
      .l2_evict_ready_i     (l2_evict_ready),
      .l2_back_inval_valid_i(l2_back_inval_valid),
      .l2_back_inval_addr_i (l2_back_inval_addr),
      .l2_back_inval_ready_o(l2_back_inval_ready),
      .l2_write_idle_o      ()
  );
endmodule

module g6lc_l3_top_lint_top
  import g6lc_l3_pkg::*;
#(
`ifdef SYNTHESIS
    parameter int unsigned BYTE_SIZE = 32'd32768
`else
    parameter int unsigned BYTE_SIZE = L3_DEFAULT_BYTE_SIZE
`endif
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  ariane_axi::req_t  slv_req,
    output ariane_axi::resp_t slv_resp,
    output ariane_axi::req_t  mst_req,
    input  ariane_axi::resp_t mst_resp,
    output logic        l3_hit,
    output logic        l3_miss,
    output logic        l3_bypass,
    output logic        l3_evict_valid,
    output logic [63:0] l3_evict_addr,
    input  logic        l3_evict_ready,
    input  logic        l3_back_inval_valid,
    input  logic [63:0] l3_back_inval_addr,
    output logic        l3_back_inval_ready
);
  g6lc_l3_top #(
      .Enable    (1'b1),
      .BYTE_SIZE (BYTE_SIZE),
      .axi_req_t (ariane_axi::req_t),
      .axi_resp_t(ariane_axi::resp_t)
  ) i_l3 (
      .clk_i,
      .rst_ni,
      .slv_req_i       (slv_req),
      .slv_resp_o      (slv_resp),
      .mst_req_o       (mst_req),
      .mst_resp_i      (mst_resp),
      .l3_hit_o        (l3_hit),
      .l3_miss_o       (l3_miss),
      .l3_bypass_o     (l3_bypass),
      .l3_selfinv_hit_o(),
      .l3_wupdate_o    (),
      .l3_wtrk_full_o  (),
      .l3_wtrk_line_hold_o(),
      .l3_hold_r1_o    (),
      .l3_hold_r1_wu_o (),
      .l3_hold_r2_o    (),
      .l3_posted_o     (),
      .l3_rdtrk_o      (),
      .l3_posted_hold_o(),
      .l3_pf_issue_o   (),
      .l3_pf_useful_o  (),
      .l3_pf_drop_o    (),
      .l3_evict_valid_o(l3_evict_valid),
      .l3_evict_addr_o (l3_evict_addr),
      .l3_evict_ready_i(l3_evict_ready),
      .l3_write_idle_o (),
      .l3_back_inval_valid_i(l3_back_inval_valid),
      .l3_back_inval_addr_i (l3_back_inval_addr),
      .l3_back_inval_ready_o(l3_back_inval_ready)
  );
endmodule

//  The prefetcher holds no cache array, so it needs no geometry shrink — only
//  concrete AXI types.
module g6lc_server_prefetcher_lint_top (
    input  logic clk_i,
    input  logic rst_ni,
    input  ariane_axi::req_t  up_req,
    output ariane_axi::resp_t up_resp,
    output ariane_axi::req_t  dn_req,
    input  ariane_axi::resp_t dn_resp,
    output logic pf_issue,
    output logic pf_train
);
  g6lc_server_prefetcher #(
      .Enable    (1'b1),
      .axi_req_t (ariane_axi::req_t),
      .axi_resp_t(ariane_axi::resp_t)
  ) i_pf (
      .clk_i,
      .rst_ni,
      .up_req_i  (up_req),
      .up_resp_o (up_resp),
      .dn_req_o  (dn_req),
      .dn_resp_i (dn_resp),
      .pf_issue_o(pf_issue),
      .pf_train_o(pf_train)
  );
endmodule
