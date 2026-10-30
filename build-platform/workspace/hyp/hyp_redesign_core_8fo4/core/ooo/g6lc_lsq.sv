// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq — hyp8 load/store queue (U5.4 production LSQ), rewritten for
// the 8-FO4 budget per analysis/g6lc_lsq.md and the cut_minimization
// g6lc_lsq rows.
//
// Emit interface preserved; additions (L1):
//   ld_checked_o[NR_SB_ENTRIES] — per-scoreboard-slot "load verdict is
//     final and no older store can still resolve or deliver data".  A
//     load may publish its result only when checked (contract §3 bound:
//     a violating load cannot commit before its verdict — the window is
//     covered by the existing cancel+refetch replay).
//   replay_valid_o/replay_tid_o — the IQ re-arm / scoreboard replay
//     pulse, firing on a reported memory-order violation only (recorded
//     simplification: a `wait` verdict holds publication via
//     ld_checked_o instead of replaying).
//   HypCfg parameter — HypCfg.LsqCamBanks banks the CAM/age work.
//
// Pipeline shape (event E -> CAM/age C -> reduce R -> verdict V):
//   E   g6lc_lsq_event     one registered record per update port — the
//                          retimed AGU output register (rank-2 cut); the
//                          live addr_valid_i update path is removed.
//   C   g6lc_lsq_cam_bank  HypCfg.LsqCamBanks banks x <=4 entries:
//                          same-word & lane-overlap & hart match bits.
//        + g6lc_lsq_age    per-bank ooo_age_older/dist vs commit_ptr_i.
//   R   g6lc_lsq_reduce    match&&older -> youngest-store tournament
//                          (STL) / oldest-violation tournament, plus the
//                          unresolved/data-wait terms.
//   V   g6lc_lsq_verdict   stl_*/mem_violation_* registered; the final
//                          per-tid verdict bits.
//   S   g6lc_lsq_slot      entry arrays: alloc (live, as today), event
//                          apply, complete, commit release, cancel,
//                          flush.
//   rel g6lc_lsq_release   registered per-load older-unresolved-store
//                          and data-wait tid masks (replaces the live
//                          st_d scan).
//
// Same-cycle-address race (emit parity): the emit's violation scan let a
// store address see loads whose address arrived "this cycle on another
// update port".  hyp8 replicates this with VIRTUAL LEAVES — a store
// event compares against the OTHER staged load-address/query records of
// the same cycle (vio_virt_*), registered alongside the bank outputs.
//
// Kill identities (contract §3): every staged record carries its tid;
// cancelled_mask_i kills in place (event capture, slot apply, CAM gating,
// verdict); flush_i clears all pipeline records and the speculative
// entries.  LSU tombstones, the committed store queue and the write-
// buffer pending record are owned elsewhere and survive (H7).
// PHYS_VALIDATE/COH_OOO paths are kept syntactically on staged phys/mod
// records (+1 vs the emit; the WT config folds the path entirely).

module g6lc_lsq #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter int unsigned LD_ENTRIES = 8,
    parameter int unsigned ST_ENTRIES = 8,
    parameter int unsigned NR_ALLOC   = 2,
    parameter int unsigned NR_UPDATE  = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // U5 production: drop entries whose SB tid was cancelled
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]            cancelled_mask_i,
    // Scoreboard issued mask (assertions only)
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]            sb_live_i,
    // Multi-port allocate at dispatch
    input  logic [NR_ALLOC-1:0]                         ld_alloc_i,
    input  logic [NR_ALLOC-1:0]                         st_alloc_i,
    input  logic [NR_ALLOC-1:0][G6LCCfg.TRANS_ID_BITS-1:0] alloc_id_i,
    // T6b: allocating op's SMT hart. Entries order, forward and replay only
    // within their own hart (mixed residency); constant-0 when NrHarts==1.
    input  logic [NR_ALLOC-1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] alloc_hart_i,
    // Allocating op's PC (loads only need it: reported on a memory-order
    // violation so the memdep predictor can train on the violating load).
    input  logic [NR_ALLOC-1:0][G6LCCfg.VLEN-1:0]       alloc_pc_i,
    output logic                                        ld_full_o,
    output logic                                        st_full_o,
    // Free entries. "Any entry free" is not an admission credit: a dispatch
    // group with more memory ops than free entries has its surplus
    // allocations silently discarded, leaving ops live in the ROB/IQ with
    // no queue entry to order or forward them. The caller must compare its
    // group size against these counts.
    output logic [$clog2(LD_ENTRIES+1)-1:0]             ld_free_o,
    output logic [$clog2(ST_ENTRIES+1)-1:0]             st_free_o,
    // Live AGU / store-data updates (issue cycle) — staged into records.
    input  logic [NR_UPDATE-1:0]                         addr_valid_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.TRANS_ID_BITS-1:0] addr_id_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.PLEN-1:0]         addr_i,
    input  logic [NR_UPDATE-1:0]                         addr_is_st_i,
    input  logic [NR_UPDATE-1:0][1:0]                     addr_size_i,
    input  logic [NR_UPDATE-1:0]                         st_data_valid_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.TRANS_ID_BITS-1:0] st_data_id_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.XLEN-1:0]        st_data_i,
    // Multi-WB complete
    input  logic [G6LCCfg.NrWbPorts-1:0]                            complete_valid_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] complete_id_i,
    input  logic [G6LCCfg.NrWbPorts-1:0]                            complete_is_st_i,
    // Store commit, one bit plus the committing store's trans_id per commit
    // port. Release is by id, never "the oldest valid entry": stores are
    // held until commit, so an index-based release could free a different
    // store.
    input  logic [G6LCCfg.NrCommitPorts-1:0]                            commit_st_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_id_i,
    // Age anchor: the scoreboard commit pointer = oldest live slot.
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]                         commit_ptr_i,
    // Load query for CAM / STL (issue of load) — staged as an event.
    input  logic        ld_query_i,
    input  logic [G6LCCfg.PLEN-1:0] ld_query_addr_i,
    input  logic [1:0]  ld_query_size_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] ld_query_id_i,
    // T6b: querying load's SMT hart — the query sees only the load's own
    // hart's stores. Constant-0 when NrHarts==1.
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ld_query_hart_i,
    // Live store tids (one bit per scoreboard slot) for the issue queue's
    // per-entry age gate.
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0] st_live_mask_o,
    // Same keying restricted to stores whose address is still unresolved.
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0] st_unresolved_mask_o,
    // T6b: st_live_mask_o partitioned by owning hart.
    output logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] st_hart_mask_o,
    output logic        store_pending_o,
    output logic        stl_forward_o,
    output logic [G6LCCfg.XLEN-1:0] stl_data_o,
    output logic        stl_stall_o,
    output logic        lsq_busy_o,
    output logic        mem_violation_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] mem_violation_id_o,
    // PC of the reported violating load (memdep train input).
    output logic [G6LCCfg.VLEN-1:0]          mem_violation_pc_o,
    input logic [1:0] phys_valid_i,
    input logic [1:0][G6LCCfg.PLEN-1:0] phys_addr_i,
    input logic [1:0][G6LCCfg.TRANS_ID_BITS-1:0] phys_id_i,
    input logic [1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] phys_hart_i,
    input logic [1:0][1:0] phys_size_i,
    input logic [G6LCCfg.NrCommitPorts-1:0] commit_ld_i,
    input logic [1:0] mod_valid_i,
    input logic [1:0][G6LCCfg.PLEN-1:0] mod_addr_i,
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0] phys_pending_o,
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0] phys_replay_o,
    // hyp8 additions (L1):
    // Load verdict final + drains: a load may publish only when checked.
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0] ld_checked_o,
    // IQ re-arm / scoreboard replay — fires on a violation only.
    output logic                               replay_valid_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]   replay_tid_o
);

  localparam int unsigned HID_W =
      $clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2);
  localparam bit PHYS_VALIDATE = G6LCCfg.CohPolicy == config_pkg::COH_OOO;
  localparam int LINE_OFF = G6LCCfg.DCACHE_LINE_WIDTH >= 8 ?
                            $clog2(G6LCCfg.DCACHE_LINE_WIDTH/8) : 4;
  localparam int unsigned LANES = (G6LCCfg.XLEN + 7) / 8;
  localparam int unsigned IDW = G6LCCfg.TRANS_ID_BITS;

  // hyp8: banking — HypCfg.LsqCamBanks banks of at most 4 entries.
  localparam int unsigned NB_S = (ST_ENTRIES + HypCfg.LsqCamBanks - 1) /
                                 HypCfg.LsqCamBanks;
  localparam int unsigned NB_L = (LD_ENTRIES + HypCfg.LsqCamBanks - 1) /
                                 HypCfg.LsqCamBanks;
  localparam int unsigned BSZ_S = (ST_ENTRIES + NB_S - 1) / NB_S;
  localparam int unsigned BSZ_L = (LD_ENTRIES + NB_L - 1) / NB_L;

`ifdef G6LC_MUT_LSQ_NO_HART
  localparam bit LSQ_HART_OWN = 1'b0;
`else
  localparam bit LSQ_HART_OWN = 1'b1;
`endif

  // Entry layouts — identical to the emit base; injected into the
  // submodules via the parameter-type seam.
  typedef struct packed {
    logic                             valid;
    logic                             addr_v;
    logic                             data_v;
    logic [IDW-1:0]                   id;
    logic [HID_W-1:0]                 hart;
    logic [G6LCCfg.PLEN-1:0]          addr;
    logic [G6LCCfg.XLEN-1:0]          data;
    logic [1:0]                       size;
    // hyp8 T1 item 2: byte-lane footprint, written with the address.
    logic [LANES-1:0]                 be;
  } st_ent_t;

  typedef struct packed {
    logic                             valid;
    logic                             addr_v;
    logic                             done;
    logic [IDW-1:0]                   id;
    logic [HID_W-1:0]                 hart;
    logic [G6LCCfg.PLEN-1:0]          addr;
    logic [1:0]                       size;
    // hyp8 T1 item 2: byte-lane footprint, written with the address.
    logic [LANES-1:0]                 be;
    logic [G6LCCfg.VLEN-1:0]          pc;
  } ld_ent_t;

  // Canonical bank-visible projection of either entry kind.
  typedef struct packed {
    logic                             valid;
    logic                             addr_v;
    logic                             data_v;
    logic [HID_W-1:0]                 hart;
    logic [G6LCCfg.PLEN-1:0]          addr;
    logic [1:0]                       size;
    // hyp8 T1 item 2: stored byte-lane footprint.
    logic [LANES-1:0]                 be;
  } cam_ent_t;

  st_ent_t [ST_ENTRIES-1:0] st_q;
  ld_ent_t [LD_ENTRIES-1:0] ld_q;

  // ---------------- Stage E: staged event records ----------------
  logic [NR_UPDATE-1:0]                ev_addr_valid, ev_addr_is_st;
  logic [NR_UPDATE-1:0][IDW-1:0]       ev_addr_id;
  logic [NR_UPDATE-1:0][G6LCCfg.PLEN-1:0] ev_addr;
  logic [NR_UPDATE-1:0][1:0]           ev_addr_size;
  logic [NR_UPDATE-1:0][LANES-1:0]     ev_addr_be;
  logic [NR_UPDATE-1:0]                ev_data_valid;
  logic [NR_UPDATE-1:0][IDW-1:0]       ev_data_id;
  logic [NR_UPDATE-1:0][G6LCCfg.XLEN-1:0] ev_data;
  logic [G6LCCfg.NrWbPorts-1:0]        ev_complete_valid, ev_complete_is_st;
  logic [G6LCCfg.NrWbPorts-1:0][IDW-1:0] ev_complete_id;
  logic [G6LCCfg.NrCommitPorts-1:0]    ev_commit_st, ev_commit_ld;
  logic [G6LCCfg.NrCommitPorts-1:0][IDW-1:0] ev_commit_id;
  logic                               ev_query_valid;
  logic [IDW-1:0]                     ev_query_id;
  logic [G6LCCfg.PLEN-1:0]            ev_query_addr;
  logic [1:0]                         ev_query_size;
  logic [LANES-1:0]                   ev_query_be;
  logic [HID_W-1:0]                   ev_query_hart;
  logic [1:0]                         ev_phys_valid;
  logic [1:0][G6LCCfg.PLEN-1:0]       ev_phys_addr;
  logic [1:0][IDW-1:0]                ev_phys_id;
  logic [1:0][HID_W-1:0]              ev_phys_hart;
  logic [1:0][1:0]                    ev_phys_size;
  logic [1:0]                         ev_mod_valid;
  logic [1:0][G6LCCfg.PLEN-1:0]       ev_mod_addr;
  logic [$clog2(2*NR_UPDATE+G6LCCfg.NrWbPorts+G6LCCfg.NrCommitPorts+7+1)-1:0] ev_count;

  g6lc_lsq_event #(
      .G6LCCfg   (G6LCCfg),
      .NR_UPDATE (NR_UPDATE)
  ) i_event (
      .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
      .addr_valid_i, .addr_id_i, .addr_i, .addr_is_st_i, .addr_size_i,
      .st_data_valid_i, .st_data_id_i, .st_data_i,
      .complete_valid_i, .complete_id_i, .complete_is_st_i,
      .commit_st_i, .commit_ld_i, .commit_id_i,
      .ld_query_i, .ld_query_addr_i, .ld_query_size_i, .ld_query_id_i,
      .ld_query_hart_i,
      .phys_valid_i, .phys_addr_i, .phys_id_i, .phys_hart_i, .phys_size_i,
      .mod_valid_i, .mod_addr_i,
      .ev_addr_valid_o    (ev_addr_valid),
      .ev_addr_is_st_o    (ev_addr_is_st),
      .ev_addr_id_o       (ev_addr_id),
      .ev_addr_o          (ev_addr),
      .ev_addr_size_o     (ev_addr_size),
      .ev_addr_be_o       (ev_addr_be),
      .ev_data_valid_o    (ev_data_valid),
      .ev_data_id_o       (ev_data_id),
      .ev_data_o          (ev_data),
      .ev_complete_valid_o(ev_complete_valid),
      .ev_complete_id_o   (ev_complete_id),
      .ev_complete_is_st_o(ev_complete_is_st),
      .ev_commit_st_o     (ev_commit_st),
      .ev_commit_ld_o     (ev_commit_ld),
      .ev_commit_id_o     (ev_commit_id),
      .ev_query_valid_o   (ev_query_valid),
      .ev_query_id_o      (ev_query_id),
      .ev_query_addr_o    (ev_query_addr),
      .ev_query_size_o    (ev_query_size),
      .ev_query_be_o      (ev_query_be),
      .ev_query_hart_o    (ev_query_hart),
      .ev_phys_valid_o    (ev_phys_valid),
      .ev_phys_addr_o     (ev_phys_addr),
      .ev_phys_id_o       (ev_phys_id),
      .ev_phys_hart_o     (ev_phys_hart),
      .ev_phys_size_o     (ev_phys_size),
      .ev_mod_valid_o     (ev_mod_valid),
      .ev_mod_addr_o      (ev_mod_addr),
      .ev_count_o         (ev_count)
  );

  // ---------------- Entry arrays ----------------
  logic [NR_UPDATE-1:0][HID_W-1:0]      ev_st_hart, ev_ld_hart;
  logic [NR_UPDATE-1:0][G6LCCfg.VLEN-1:0] ev_ld_pc;
  logic [NR_ALLOC-1:0]                  ld_alloc_v;
  logic [NR_ALLOC-1:0][$clog2(LD_ENTRIES)-1:0] ld_alloc_idx;
  logic [NR_ALLOC-1:0][LD_ENTRIES-1:0]  ld_alloc_oh;
  logic [LD_ENTRIES-1:0]                ld_release;

  g6lc_lsq_slot #(
      .G6LCCfg   (G6LCCfg),
      .LD_ENTRIES(LD_ENTRIES),
      .ST_ENTRIES(ST_ENTRIES),
      .NR_ALLOC  (NR_ALLOC),
      .NR_UPDATE (NR_UPDATE),
      .st_ent_t  (st_ent_t),
      .ld_ent_t  (ld_ent_t)
  ) i_slot (
      .clk_i, .rst_ni, .flush_i, .cancelled_mask_i, .sb_live_i,
      .ld_alloc_i, .st_alloc_i, .alloc_id_i, .alloc_hart_i, .alloc_pc_i,
      .ev_addr_valid_i (ev_addr_valid),
      .ev_addr_is_st_i (ev_addr_is_st),
      .ev_addr_id_i    (ev_addr_id),
      .ev_addr_i       (ev_addr),
      .ev_addr_size_i  (ev_addr_size),
      .ev_addr_be_i    (ev_addr_be),
      .ev_data_valid_i (ev_data_valid),
      .ev_data_id_i    (ev_data_id),
      .ev_data_i       (ev_data),
      .ev_complete_valid_i(ev_complete_valid),
      .ev_complete_id_i   (ev_complete_id),
      .ev_complete_is_st_i(ev_complete_is_st),
      .ev_commit_st_i  (ev_commit_st),
      .ev_commit_ld_i  (ev_commit_ld),
      .ev_commit_id_i  (ev_commit_id),
      .ev_phys_valid_i (ev_phys_valid),
      .ev_phys_addr_i  (ev_phys_addr),
      .ev_phys_id_i    (ev_phys_id),
      .ev_phys_hart_i  (ev_phys_hart),
      .ev_phys_size_i  (ev_phys_size),
      .ld_release_i    (ld_release),
      .st_o            (st_q),
      .ld_o            (ld_q),
      .ev_st_hart_o    (ev_st_hart),
      .ev_ld_hart_o    (ev_ld_hart),
      .ev_ld_pc_o      (ev_ld_pc),
      .ld_alloc_v_o    (ld_alloc_v),
      .ld_alloc_idx_o  (ld_alloc_idx),
      .ld_alloc_oh_o   (ld_alloc_oh)
  );

  // Credits are a pure projection of registered slots, never pending events.
  // Case equality preserves the old if (!valid) treatment of X/Z as occupied.
  localparam int unsigned LD_FREE_W = $clog2(LD_ENTRIES + 1);
  localparam int unsigned ST_FREE_W = $clog2(ST_ENTRIES + 1);
  logic [LD_ENTRIES-1:0] ld_free_mask;
  logic [ST_ENTRIES-1:0] st_free_mask;
  for (genvar i = 0; i < LD_ENTRIES; i++) begin : gen_ld_credit
    assign ld_free_mask[i] = (ld_q[i].valid === 1'b0);
  end
  for (genvar i = 0; i < ST_ENTRIES; i++) begin : gen_st_credit
    assign st_free_mask[i] = (st_q[i].valid === 1'b0);
  end
  assign ld_free_o = LD_FREE_W'($countones(ld_free_mask));
  assign st_free_o = ST_FREE_W'($countones(st_free_mask));
  assign ld_full_o = !(|ld_free_mask);
  assign st_full_o = !(|st_free_mask);

  // Occupancy status, from registered state only (emit block kept).
  // hyp8: lsq_busy_o also covers the staged records — an in-flight
  // update is conservatively busy until it applies.
  always_comb begin
    store_pending_o       = 1'b0;
    lsq_busy_o            = (ev_count != '0);
    st_live_mask_o        = '0;
    st_unresolved_mask_o  = '0;
    st_hart_mask_o        = '0;
    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      if (st_q[i].valid) begin
        store_pending_o = 1'b1;
        lsq_busy_o      = 1'b1;
        st_live_mask_o[st_q[i].id] = 1'b1;
        st_hart_mask_o[st_q[i].hart][st_q[i].id] = 1'b1;
        if (!LSQ_HART_OWN)
          for (int unsigned h = 0; h < G6LCCfg.NrHarts; h++)
            st_hart_mask_o[h][st_q[i].id] = 1'b1;
        if (!st_q[i].addr_v) st_unresolved_mask_o[st_q[i].id] = 1'b1;
      end
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_q[i].valid) lsq_busy_o = 1'b1;
  end

  // Bank-visible projections (packed so a bank slice connects directly
  // to the cam_bank ent_i port).
  cam_ent_t [NB_S-1:0][BSZ_S-1:0] st_cam;
  cam_ent_t [NB_L-1:0][BSZ_L-1:0] ld_cam;
  always_comb begin
    for (int unsigned b = 0; b < NB_S; b++)
      for (int unsigned e = 0; e < BSZ_S; e++) begin
        st_cam[b][e] = '0;
        if (b*BSZ_S+e < ST_ENTRIES) begin
          st_cam[b][e].valid  = st_q[b*BSZ_S+e].valid;
          st_cam[b][e].addr_v = st_q[b*BSZ_S+e].addr_v;
          st_cam[b][e].data_v = st_q[b*BSZ_S+e].data_v;
          st_cam[b][e].hart   = st_q[b*BSZ_S+e].hart;
          st_cam[b][e].addr   = st_q[b*BSZ_S+e].addr;
          st_cam[b][e].size   = st_q[b*BSZ_S+e].size;
          st_cam[b][e].be     = st_q[b*BSZ_S+e].be;
        end
      end
    for (int unsigned b = 0; b < NB_L; b++)
      for (int unsigned e = 0; e < BSZ_L; e++) begin
        ld_cam[b][e] = '0;
        if (b*BSZ_L+e < LD_ENTRIES) begin
          ld_cam[b][e].valid  = ld_q[b*BSZ_L+e].valid;
          ld_cam[b][e].addr_v = ld_q[b*BSZ_L+e].addr_v;
          ld_cam[b][e].data_v = 1'b1;  // loads never gate on store data
          ld_cam[b][e].hart   = ld_q[b*BSZ_L+e].hart;
          ld_cam[b][e].addr   = ld_q[b*BSZ_L+e].addr;
          ld_cam[b][e].size   = ld_q[b*BSZ_L+e].size;
          ld_cam[b][e].be     = ld_q[b*BSZ_L+e].be;
        end
      end
  end

  // The deduplicated query event: the rewritten load unit issues a load
  // by presenting an address record (addr_valid_i, is_st=0) — that
  // record IS the query.  The explicit ld_query_* port is honoured only
  // when no load-address event for the same id is staged this cycle.
  logic q_ev_valid;
  always_comb begin
    q_ev_valid = ev_query_valid;
    for (int unsigned u = 0; u < NR_UPDATE; u++)
      if (ev_addr_valid[u] && !ev_addr_is_st[u] &&
          ev_addr_id[u] == ev_query_id)
        q_ev_valid = 1'b0;
  end

  // Query record's entry-resolved PC (for the virtual violation leaf).
  logic [G6LCCfg.VLEN-1:0] q_ld_pc;
  always_comb begin
    q_ld_pc = '0;
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_q[i].valid && ld_q[i].id == ev_query_id)
        q_ld_pc = ld_q[i].pc;
  end

  // ---------------- Stage C: banked CAM + age ----------------
  // Per update port u: STL direction (load event vs store entries,
  // DIR=0 age) and violation direction (store event vs load entries,
  // DIR=1 age).  The query event gets its own STL path.
  // Leaf counts for reduce: STL = NB_S*BSZ_S; VIO = NB_L*BSZ_L bank
  // leaves + NR_UPDATE virtual leaves (other same-cycle load events +
  // the deduplicated query record — see below).
  localparam int unsigned STL_BANK = NB_S * BSZ_S;
  localparam int unsigned STL_LEAF = STL_BANK;
  localparam int unsigned VIO_BANK = NB_L * BSZ_L;
  localparam int unsigned VIO_LEAF = VIO_BANK + NR_UPDATE;

  logic [NR_UPDATE-1:0][STL_BANK-1:0] stl_match_q, stl_unres_q, stl_nodata_q;
  logic [NR_UPDATE-1:0][STL_BANK-1:0] stl_older_q;
  logic [NR_UPDATE-1:0][STL_BANK-1:0][IDW-1:0] stl_dist_q;
  logic [STL_BANK-1:0]                 q_match_q, q_unres_q, q_nodata_q;
  logic [STL_BANK-1:0]                 q_older_q;
  logic [STL_BANK-1:0][IDW-1:0]        q_dist_q;
  logic [NR_UPDATE-1:0][VIO_BANK-1:0]  vio_match_q, vio_unres_q, vio_nodata_q;
  logic [NR_UPDATE-1:0][VIO_BANK-1:0]  vio_older_q;
  logic [NR_UPDATE-1:0][VIO_BANK-1:0][IDW-1:0] vio_dist_q;
  // Virtual violation leaves: store event u vs same-cycle load event v
  // (v != u) and vs the deduplicated query record.  match/older/dist
  // are computed at the C stage and registered beside the bank outputs;
  // the leaf index packs the other load events then the query record.
  logic [NR_UPDATE-1:0][NR_UPDATE-1:0] vv_match_d, vv_older_d;
  logic [NR_UPDATE-1:0][NR_UPDATE-1:0][IDW-1:0] vv_dist_d, vv_id_d;
  logic [NR_UPDATE-1:0][NR_UPDATE-1:0][G6LCCfg.VLEN-1:0] vv_pay_d;
  logic [NR_UPDATE-1:0][NR_UPDATE-1:0] vv_match_q, vv_older_q;
  logic [NR_UPDATE-1:0][NR_UPDATE-1:0][IDW-1:0] vv_dist_q, vv_id_q;
  logic [NR_UPDATE-1:0][NR_UPDATE-1:0][G6LCCfg.VLEN-1:0] vv_pay_q;

  // Byte-enable as a constant table over {size, a[2:0]}: 32 slots of
  // LANES bits — a 32:1 mux (~5.5 FO4) instead of the variable-shift
  // barrel billed ~26 under the vv_* guards.
  function automatic logic [31:0][LANES-1:0] lane_be_table();
    logic [LANES-1:0] m;
    for (int unsigned s = 0; s < 4; s++) begin
      for (int unsigned off = 0; off < 8; off++) begin
        m = '0;
        for (int unsigned b = 0; b < LANES; b++)
          if (b < (1 << s)) m[b] = 1'b1;
        lane_be_table[{s[1:0], off[2:0]}] =
            (G6LCCfg.XLEN == 64) ? (m << off[2:0]) : (m << off[1:0]);
      end
    end
  endfunction
  localparam logic [31:0][LANES-1:0] LANE_BE_TAB = lane_be_table();

  function automatic logic [LANES-1:0] lane_be(
      input logic [G6LCCfg.PLEN-1:0] a,
      input logic [1:0]              size
  );
    return LANE_BE_TAB[{size, a[2:0]}];
  endfunction

//pragma translate_off
  // Reference loop form for the table check (time-0 exhausts all 32
  // {size, off} slots).
  function automatic logic [LANES-1:0] lane_be_ref(
      input logic [G6LCCfg.PLEN-1:0] a,
      input logic [1:0]              size
  );
    automatic logic [LANES-1:0] m;
    m = '0;
    for (int unsigned b = 0; b < LANES; b++)
      if (b < (1 << size)) m[b] = 1'b1;
    if (G6LCCfg.XLEN == 64)
      lane_be_ref = m << a[2:0];
    else
      lane_be_ref = m << a[1:0];
  endfunction
  initial begin : lane_be_tab_chk
    logic [G6LCCfg.PLEN-1:0] ta;
    for (int unsigned s = 0; s < 4; s++) begin
      for (int unsigned o = 0; o < 8; o++) begin
        ta = '0;
        ta[2:0] = o[2:0];
        if (lane_be(ta, 2'(s)) !== lane_be_ref(ta, 2'(s))) begin
          $error("lane_be table != ref size=%0d off=%0d", s, o);
        end
      end
    end
  end
//pragma translate_on

  function automatic logic same_word(
      input logic [G6LCCfg.PLEN-1:0] a,
      input logic [G6LCCfg.PLEN-1:0] b
  );
    if (G6LCCfg.PLEN > 6)
      same_word = (a[G6LCCfg.PLEN-1:3] == b[G6LCCfg.PLEN-1:3]);
    else
      same_word = (a == b);
  endfunction

  // Same hoist the file already uses for s_be[s]/ev0_be: the event
  // byte enables are invariant in the (u,v) pair scan — compute them
  // once per event instead of inside the guarded block.
  logic [LANES-1:0] ev_be [NR_UPDATE];
  logic [LANES-1:0] q_be;
  for (genvar u = 0; u < NR_UPDATE; u++) begin : gen_ev_be
    assign ev_be[u] = lane_be(ev_addr[u], ev_addr_size[u]);
  end
  assign q_be = lane_be(ev_query_addr, ev_query_size);

  always_comb begin
    vv_match_d = '0;
    vv_older_d = '0;
    vv_dist_d  = '0;
    vv_id_d    = '0;
    vv_pay_d   = '0;
    for (int unsigned u = 0; u < NR_UPDATE; u++) begin
      if (ev_addr_valid[u] && ev_addr_is_st[u] &&
          !cancelled_mask_i[ev_addr_id[u]]) begin
        // Other same-cycle load events: virtual leaf slots 0..NR-2.
        for (int unsigned v = 0; v < NR_UPDATE; v++) begin
          if (v != u) begin
            vv_id_d[u][(v < u) ? v : v-1]  = ev_addr_id[v];
            vv_pay_d[u][(v < u) ? v : v-1] = ev_ld_pc[v];
            if (ev_addr_valid[v] && !ev_addr_is_st[v] &&
                !cancelled_mask_i[ev_addr_id[v]] &&
                (!LSQ_HART_OWN || ev_ld_hart[v] == ev_st_hart[u])) begin
              if (same_word(ev_addr[v], ev_addr[u]) && (ev_be[u] & ev_be[v]) != '0)
                vv_match_d[u][(v < u) ? v : v-1] = 1'b1;
              vv_older_d[u][(v < u) ? v : v-1] = g6lc_ooo_pkg::ooo_age_older(
                  IDW, 32'(ev_addr_id[u]), 32'(ev_addr_id[v]),
                  32'(commit_ptr_i));
              vv_dist_d[u][(v < u) ? v : v-1] = IDW'(g6lc_ooo_pkg::ooo_age_dist(
                  IDW, 32'(ev_addr_id[v]), 32'(commit_ptr_i)));
            end
          end
        end
        // Deduplicated query record: virtual leaf slot NR_UPDATE-1.
        vv_id_d[u][NR_UPDATE-1]  = ev_query_id;
        vv_pay_d[u][NR_UPDATE-1] = q_ld_pc;
        if (q_ev_valid && !cancelled_mask_i[ev_query_id] &&
            (!LSQ_HART_OWN || ev_query_hart == ev_st_hart[u])) begin
          if (same_word(ev_query_addr, ev_addr[u]) && (ev_be[u] & q_be) != '0)
            vv_match_d[u][NR_UPDATE-1] = 1'b1;
          vv_older_d[u][NR_UPDATE-1] = g6lc_ooo_pkg::ooo_age_older(
              IDW, 32'(ev_addr_id[u]), 32'(ev_query_id),
              32'(commit_ptr_i));
          vv_dist_d[u][NR_UPDATE-1] = IDW'(g6lc_ooo_pkg::ooo_age_dist(
              IDW, 32'(ev_query_id), 32'(commit_ptr_i)));
        end
      end
    end
  end

  // Stage-C registers: the virtual leaves and the leaf metadata
  // snapshots (entry id / payload captured with the match bits so a
  // freed entry cannot change a candidate's identity before the reduce
  // stage reads it).
  logic [NR_UPDATE-1:0][VIO_BANK-1:0][IDW-1:0]      vio_eid_q;
  logic [NR_UPDATE-1:0][VIO_BANK-1:0][G6LCCfg.VLEN-1:0] vio_epay_q;
  logic [STL_BANK-1:0][IDW-1:0]                     stl_eid_q;
  logic [NR_UPDATE-1:0][STL_BANK-1:0][G6LCCfg.XLEN-1:0] stl_epay_q;
  logic [STL_BANK-1:0][IDW-1:0]                     q_eid_q;
  logic [STL_BANK-1:0][G6LCCfg.XLEN-1:0]            q_epay_q;
  // r53-B6: pairwise leaf age matrices for the reducers, compare-form
  // (ooo_age_older over the same leaf ids this edge snapshots).
  // age[r][c] = "r older than c"; relative order of two live ids is
  // pivot-invariant under commit_ptr_i movement (it can only retire
  // entries, and a retired leaf is dead in cand). The store matrix
  // serves both the per-update stl reducer and the q reducer (same
  // st entry ids); the vio matrix covers {vv_id_d, ld ids}.
  logic [STL_BANK-1:0][STL_BANK-1:0]                st_age_d, st_age_q;
  logic [NR_UPDATE-1:0][VIO_LEAF-1:0][VIO_LEAF-1:0] vio_age_d, vio_age_q;
  for (genvar r = 0; r < STL_BANK; r++) begin : gen_st_age_r
    for (genvar c = 0; c < STL_BANK; c++) begin : gen_st_age_c
      assign st_age_d[r][c] = g6lc_ooo_pkg::ooo_age_older(
          IDW, 32'(st_q[r].id), 32'(st_q[c].id), 32'(commit_ptr_i));
    end
  end
  for (genvar u = 0; u < NR_UPDATE; u++) begin : gen_vio_age_u
    for (genvar r = 0; r < VIO_LEAF; r++) begin : gen_vio_age_r
      for (genvar c = 0; c < VIO_LEAF; c++) begin : gen_vio_age_c
        logic [31:0] rid, cid;
        assign rid = (r < VIO_BANK)
            ? ((r < LD_ENTRIES) ? 32'(ld_q[r].id) : 32'b0)
            : 32'(vv_id_d[u][r-VIO_BANK]);
        assign cid = (c < VIO_BANK)
            ? ((c < LD_ENTRIES) ? 32'(ld_q[c].id) : 32'b0)
            : 32'(vv_id_d[u][c-VIO_BANK]);
        assign vio_age_d[u][r][c] = g6lc_ooo_pkg::ooo_age_older(
            IDW, rid, cid, 32'(commit_ptr_i));
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vv_match_q <= '0;
      vv_older_q <= '0;
      vv_dist_q  <= '0;
      vv_id_q    <= '0;
      vv_pay_q   <= '0;
      vio_eid_q  <= '0;
      vio_epay_q <= '0;
      stl_eid_q  <= '0;
      stl_epay_q <= '0;
      q_eid_q    <= '0;
      q_epay_q   <= '0;
      st_age_q   <= '0;
      vio_age_q  <= '0;
    end else if (flush_i) begin
      vv_match_q <= '0;
      vv_older_q <= '0;
      vv_dist_q  <= '0;
      vv_id_q    <= '0;
      vv_pay_q   <= '0;
      vio_eid_q  <= '0;
      vio_epay_q <= '0;
      stl_eid_q  <= '0;
      stl_epay_q <= '0;
      q_eid_q    <= '0;
      q_epay_q   <= '0;
      st_age_q   <= '0;
      vio_age_q  <= '0;
    end else begin
      vv_match_q <= vv_match_d;
      vv_older_q <= vv_older_d;
      vv_dist_q  <= vv_dist_d;
      vv_id_q    <= vv_id_d;
      vv_pay_q   <= vv_pay_d;
      st_age_q   <= st_age_d;
      vio_age_q  <= vio_age_d;
      for (int unsigned u = 0; u < NR_UPDATE; u++) begin
        for (int unsigned i = 0; i < VIO_BANK; i++) begin
          if (i < LD_ENTRIES) begin
            vio_eid_q[u][i]    <= ld_q[i].id;
            vio_epay_q[u][i]   <= ld_q[i].pc;
          end else begin
            vio_eid_q[u][i]    <= '0;
            vio_epay_q[u][i]   <= '0;
          end
        end
        for (int unsigned i = 0; i < STL_BANK; i++) begin
          if (i < ST_ENTRIES) begin
            stl_epay_q[u][i] <= st_q[i].data;
          end else begin
            stl_epay_q[u][i] <= '0;
          end
        end
      end
      for (int unsigned i = 0; i < STL_BANK; i++) begin
        if (i < ST_ENTRIES) begin
          stl_eid_q[i] <= st_q[i].id;
          q_eid_q[i]   <= st_q[i].id;
          q_epay_q[i]  <= st_q[i].data;
        end else begin
          stl_eid_q[i] <= '0;
          q_eid_q[i]   <= '0;
          q_epay_q[i]  <= '0;
        end
      end
    end
  end

  // Event context pipeline: ctx1 registers beside the CAM stage,
  // ctx2 beside reduce — the verdict names its tid from ctx2.
  // r43-T T3: HypCfg.LsqReduceStages==2 adds ctx3 beside R2 so the
  // event/verdict pairing keeps the same distance as the reduce.
  localparam bit LRED2 = (HypCfg.LsqReduceStages >= 2);
  logic [NR_UPDATE-1:0]        uctx1_v, uctx1_is_st;
  logic [NR_UPDATE-1:0][IDW-1:0] uctx1_id;
  logic [NR_UPDATE-1:0]        uctx2_v, uctx2_is_st;
  logic [NR_UPDATE-1:0][IDW-1:0] uctx2_id;
  logic                        qctx1_v, qctx2_v;
  logic [IDW-1:0]              qctx1_id, qctx2_id;
  logic [NR_UPDATE-1:0]        uctx3_v, uctx3_is_st;
  logic [NR_UPDATE-1:0][IDW-1:0] uctx3_id;
  logic                        qctx3_v;
  logic [IDW-1:0]              qctx3_id;
  // The verdict-side context is ctx2 (1-stage reduce) or ctx3 (2-stage).
  logic [NR_UPDATE-1:0]        uctxV_v, uctxV_is_st;
  logic [NR_UPDATE-1:0][IDW-1:0] uctxV_id;
  logic                        qctxV_v;
  logic [IDW-1:0]              qctxV_id;
  assign uctxV_v     = LRED2 ? uctx3_v     : uctx2_v;
  assign uctxV_is_st = LRED2 ? uctx3_is_st : uctx2_is_st;
  assign uctxV_id    = LRED2 ? uctx3_id    : uctx2_id;
  assign qctxV_v     = LRED2 ? qctx3_v     : qctx2_v;
  assign qctxV_id    = LRED2 ? qctx3_id    : qctx2_id;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      uctx1_v <= '0;
      uctx2_v <= '0;
      qctx1_v <= 1'b0;
      qctx2_v <= 1'b0;
      uctx3_v <= '0;
      qctx3_v <= 1'b0;
    end else if (flush_i) begin
      uctx1_v <= '0;
      uctx2_v <= '0;
      qctx1_v <= 1'b0;
      qctx2_v <= 1'b0;
      uctx3_v <= '0;
      qctx3_v <= 1'b0;
    end else begin
      for (int unsigned u = 0; u < NR_UPDATE; u++) begin
        uctx1_v[u]     <= ev_addr_valid[u] && !cancelled_mask_i[ev_addr_id[u]];
        uctx1_is_st[u] <= ev_addr_is_st[u];
        uctx1_id[u]    <= ev_addr_id[u];
        uctx2_v[u]     <= uctx1_v[u] && !cancelled_mask_i[uctx1_id[u]];
        uctx2_is_st[u] <= uctx1_is_st[u];
        uctx2_id[u]    <= uctx1_id[u];
      end
      qctx1_v  <= q_ev_valid && !cancelled_mask_i[ev_query_id];
      qctx1_id <= ev_query_id;
      qctx2_v  <= qctx1_v && !cancelled_mask_i[qctx1_id];
      qctx2_id <= qctx1_id;
      // r43-T T3: third context stage beside R2 (kill-gated the same
      // way as ctx1->ctx2) when the reduce runs in two stages.
      if (LRED2) begin
        for (int unsigned u = 0; u < NR_UPDATE; u++) begin
          uctx3_v[u]     <= uctx2_v[u] && !cancelled_mask_i[uctx2_id[u]];
          uctx3_is_st[u] <= uctx2_is_st[u];
          uctx3_id[u]    <= uctx2_id[u];
        end
        qctx3_v  <= qctx2_v && !cancelled_mask_i[qctx2_id];
        qctx3_id <= qctx2_id;
      end
    end
  end

  // Banked CAM + age instances.  Bank leaf vectors from the instances
  // are packed into the [0 +: NB*BSZ] region of the *_q buses.
  for (genvar u = 0; u < NR_UPDATE; u++) begin : gen_upd_pipe
    // STL direction: the event CAMs only when it is a load address.
    logic ev_is_ld;
    assign ev_is_ld = ev_addr_valid[u] && !ev_addr_is_st[u];
    for (genvar b = 0; b < NB_S; b++) begin : gen_stl_bank
      logic [BSZ_S-1:0] ent_v;
      logic [BSZ_S-1:0][IDW-1:0] ent_id;
      always_comb begin
        for (int unsigned e = 0; e < BSZ_S; e++) begin
          ent_v[e]    = (b*BSZ_S+e < ST_ENTRIES) ? st_q[b*BSZ_S+e].valid : 1'b0;
          ent_id[e]   = (b*BSZ_S+e < ST_ENTRIES) ? st_q[b*BSZ_S+e].id : '0;
        end
      end
      g6lc_lsq_cam_bank #(
          .G6LCCfg   (G6LCCfg),
          .ENTRIES   (BSZ_S),
          .cam_ent_t (cam_ent_t)
      ) i_cam (
          .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
          .ev_valid_i (ev_is_ld),
          .ev_id_i    (ev_addr_id[u]),
          .ev_addr_i  (ev_addr[u]),
          .ev_size_i  (ev_addr_size[u]),
          .ev_be_i    (ev_addr_be[u]),
          .ev_hart_i  (ev_ld_hart[u]),
          .ent_i      (st_cam[b]),
          .match_o    (stl_match_q[u][b*BSZ_S +: BSZ_S]),
          .unres_o    (stl_unres_q[u][b*BSZ_S +: BSZ_S]),
          .nodata_o   (stl_nodata_q[u][b*BSZ_S +: BSZ_S])
      );
      g6lc_lsq_age #(
          .G6LCCfg (G6LCCfg),
          .ENTRIES (BSZ_S),
          .DIR     (1'b0)
      ) i_age (
          .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
          .ev_valid_i (ev_is_ld),
          .ev_id_i    (ev_addr_id[u]),
          .ent_valid_i(ent_v),
          .ent_id_i   (ent_id),
          .commit_ptr_i,
          .older_o    (stl_older_q[u][b*BSZ_S +: BSZ_S]),
          .dist_o     (stl_dist_q[u][b*BSZ_S +: BSZ_S])
      );
    end
    // Violation direction: the event CAMs only when it is a store
    // address; leaves [NB_L*BSZ_L +: ...] are the virtual candidates
    // owned by the wrapper's stage-C register above.
    logic ev_is_st;
    assign ev_is_st = ev_addr_valid[u] && ev_addr_is_st[u];
    for (genvar b = 0; b < NB_L; b++) begin : gen_vio_bank
      logic [BSZ_L-1:0] ent_v;
      logic [BSZ_L-1:0][IDW-1:0] ent_id;
      always_comb begin
        for (int unsigned e = 0; e < BSZ_L; e++) begin
          ent_v[e]    = (b*BSZ_L+e < LD_ENTRIES) ? ld_q[b*BSZ_L+e].valid : 1'b0;
          ent_id[e]   = (b*BSZ_L+e < LD_ENTRIES) ? ld_q[b*BSZ_L+e].id : '0;
        end
      end
      g6lc_lsq_cam_bank #(
          .G6LCCfg   (G6LCCfg),
          .ENTRIES   (BSZ_L),
          .cam_ent_t (cam_ent_t)
      ) i_cam (
          .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
          .ev_valid_i (ev_is_st),
          .ev_id_i    (ev_addr_id[u]),
          .ev_addr_i  (ev_addr[u]),
          .ev_size_i  (ev_addr_size[u]),
          .ev_be_i    (ev_addr_be[u]),
          .ev_hart_i  (ev_st_hart[u]),
          .ent_i      (ld_cam[b]),
          .match_o    (vio_match_q[u][b*BSZ_L +: BSZ_L]),
          .unres_o    (vio_unres_q[u][b*BSZ_L +: BSZ_L]),
          .nodata_o   (vio_nodata_q[u][b*BSZ_L +: BSZ_L])
      );
      g6lc_lsq_age #(
          .G6LCCfg (G6LCCfg),
          .ENTRIES (BSZ_L),
          .DIR     (1'b1)
      ) i_age (
          .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
          .ev_valid_i (ev_is_st),
          .ev_id_i    (ev_addr_id[u]),
          .ent_valid_i(ent_v),
          .ent_id_i   (ent_id),
          .commit_ptr_i,
          .older_o    (vio_older_q[u][b*BSZ_L +: BSZ_L]),
          .dist_o     (vio_dist_q[u][b*BSZ_L +: BSZ_L])
      );
    end
  end

  // The query event's own STL path.
  for (genvar b = 0; b < NB_S; b++) begin : gen_q_stl_bank
    logic [BSZ_S-1:0] ent_v;
    logic [BSZ_S-1:0][IDW-1:0] ent_id;
    always_comb begin
      for (int unsigned e = 0; e < BSZ_S; e++) begin
        ent_v[e]    = (b*BSZ_S+e < ST_ENTRIES) ? st_q[b*BSZ_S+e].valid : 1'b0;
        ent_id[e]   = (b*BSZ_S+e < ST_ENTRIES) ? st_q[b*BSZ_S+e].id : '0;
      end
    end
    g6lc_lsq_cam_bank #(
        .G6LCCfg   (G6LCCfg),
        .ENTRIES   (BSZ_S),
        .cam_ent_t (cam_ent_t)
    ) i_cam (
        .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
        .ev_valid_i (q_ev_valid),
        .ev_id_i    (ev_query_id),
        .ev_addr_i  (ev_query_addr),
        .ev_size_i  (ev_query_size),
        .ev_be_i    (ev_query_be),
        .ev_hart_i  (ev_query_hart),
        .ent_i      (st_cam[b]),
        .match_o    (q_match_q[b*BSZ_S +: BSZ_S]),
        .unres_o    (q_unres_q[b*BSZ_S +: BSZ_S]),
        .nodata_o   (q_nodata_q[b*BSZ_S +: BSZ_S])
    );
    g6lc_lsq_age #(
        .G6LCCfg (G6LCCfg),
        .ENTRIES (BSZ_S),
        .DIR     (1'b0)
    ) i_age (
        .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
        .ev_valid_i (q_ev_valid),
        .ev_id_i    (ev_query_id),
        .ent_valid_i(ent_v),
        .ent_id_i   (ent_id),
        .commit_ptr_i,
        .older_o    (q_older_q[b*BSZ_S +: BSZ_S]),
        .dist_o     (q_dist_q[b*BSZ_S +: BSZ_S])
    );
  end

  // ---------------- Stage R: reduce ----------------
  // Reduce leaf vectors = bank region (cam/age registered outputs) then
  // the virtual leaf region (violation only).  Entry metadata uses the
  // C-stage snapshots, so a freed entry cannot alias a live candidate.
  logic [NR_UPDATE-1:0]        stl_r_v, stl_r_wait;
  logic [NR_UPDATE-1:0][IDW-1:0] stl_r_id;
  logic [NR_UPDATE-1:0][G6LCCfg.XLEN-1:0] stl_r_pay;
  logic [NR_UPDATE-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] stl_r_dwait;
  logic                        q_r_v, q_r_wait;
  logic [IDW-1:0]              q_r_id;
  logic [G6LCCfg.XLEN-1:0]     q_r_pay;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] q_r_dwait;
  logic [NR_UPDATE-1:0]        vio_r_v;
  logic [NR_UPDATE-1:0][IDW-1:0] vio_r_id, vio_r_dist;
  logic [NR_UPDATE-1:0][G6LCCfg.VLEN-1:0] vio_r_pay;

  for (genvar u = 0; u < NR_UPDATE; u++) begin : gen_reduce
    g6lc_lsq_reduce #(
        .G6LCCfg (G6LCCfg),
        .HypCfg  (HypCfg),
        .NLEAF   (STL_LEAF),
        .PAYW    (G6LCCfg.XLEN),
        .DIR     (1'b0)
    ) i_stl_red (
        .clk_i, .rst_ni, .flush_i,
        .match_i  (stl_match_q[u]),
        .unres_i  (stl_unres_q[u]),
        .nodata_i (stl_nodata_q[u]),
        .older_i  (stl_older_q[u]),
        .age_i    (st_age_q),
        .dist_i   (stl_dist_q[u]),
        .ent_id_i (stl_eid_q),
        .ent_pay_i(stl_epay_q[u]),
        .win_valid_o(stl_r_v[u]),
        .win_leaf_o (),
        .win_id_o   (stl_r_id[u]),
        .win_dist_o (),
        .win_pay_o  (stl_r_pay[u]),
        .wait_o     (stl_r_wait[u]),
        .dwait_ids_o(stl_r_dwait[u])
    );
    g6lc_lsq_reduce #(
        .G6LCCfg (G6LCCfg),
        .HypCfg  (HypCfg),
        .NLEAF   (VIO_LEAF),
        .PAYW    (G6LCCfg.VLEN),
        .DIR     (1'b1),
        // The violation direction publishes id/dist/PC only — the
        // data-wait decode is dead work here.
        .TRACK_WAIT(1'b0)
    ) i_vio_red (
        .clk_i, .rst_ni, .flush_i,
        // Every resident younger load matching the eventing store is a
        // violation candidate: the LSU's forward probe may have raced
        // the store's resolution and the published data may be stale.
        // The replay is the recovery — suppressing it committed stale
        // data twice (h33: dwait-tracked lbu byte 0x88 vs stored 0xef;
        // r5: unres-tracked ld published 0).
        .match_i  ({vv_match_q[u], vio_match_q[u]}),
        .unres_i  ({NR_UPDATE'(1'b0), vio_unres_q[u]}),
        .nodata_i ({NR_UPDATE'(1'b0), vio_nodata_q[u]}),
        .older_i  ({vv_older_q[u], vio_older_q[u]}),
        .age_i    (vio_age_q[u]),
        .dist_i   ({vv_dist_q[u], vio_dist_q[u]}),
        .ent_id_i ({vv_id_q[u], vio_eid_q[u]}),
        .ent_pay_i({vv_pay_q[u], vio_epay_q[u]}),
        .win_valid_o(vio_r_v[u]),
        .win_leaf_o (),
        .win_id_o   (vio_r_id[u]),
        .win_dist_o (vio_r_dist[u]),
        .win_pay_o  (vio_r_pay[u]),
        .wait_o     (),
        .dwait_ids_o()
    );
  end

  g6lc_lsq_reduce #(
      .G6LCCfg (G6LCCfg),
      .HypCfg  (HypCfg),
      .NLEAF   (STL_LEAF),
      .PAYW    (G6LCCfg.XLEN),
      .DIR     (1'b0)
  ) i_q_red (
      .clk_i, .rst_ni, .flush_i,
      .match_i  (q_match_q),
      .unres_i  (q_unres_q),
      .nodata_i (q_nodata_q),
      .older_i  (q_older_q),
      .age_i    (st_age_q),
      .dist_i   (q_dist_q),
      .ent_id_i (q_eid_q),
      .ent_pay_i(q_epay_q),
      .win_valid_o(q_r_v),
      .win_leaf_o (),
      .win_id_o   (q_r_id),
      .win_dist_o (),
      .win_pay_o  (q_r_pay),
      .wait_o     (q_r_wait),
      .dwait_ids_o(q_r_dwait)
  );

  // ---------------- Stage V: verdict ----------------
  localparam int unsigned NLD = NR_UPDATE + 1;

  logic [NLD-1:0]                               ld_ev_v;
  logic [NLD-1:0][IDW-1:0]                      ld_ev_id;
  logic [NLD-1:0]                               ld_win_v;
  logic [NLD-1:0][G6LCCfg.XLEN-1:0]             ld_win_pay;
  logic [NLD-1:0]                               ld_wait;
  logic [NLD-1:0][G6LCCfg.NR_SB_ENTRIES-1:0]    ld_dwait;

  always_comb begin
    for (int unsigned u = 0; u < NR_UPDATE; u++) begin
      ld_ev_v[u]   = uctxV_v[u] && !uctxV_is_st[u];
      ld_ev_id[u]  = uctxV_id[u];
      ld_win_v[u]  = stl_r_v[u];
      ld_win_pay[u]= stl_r_pay[u];
      ld_wait[u]   = stl_r_wait[u];
      ld_dwait[u]  = stl_r_dwait[u];
    end
    ld_ev_v[NR_UPDATE]   = qctxV_v;
    ld_ev_id[NR_UPDATE]  = qctxV_id;
    ld_win_v[NR_UPDATE]  = q_r_v;
    ld_win_pay[NR_UPDATE]= q_r_pay;
    ld_wait[NR_UPDATE]   = q_r_wait;
    ld_dwait[NR_UPDATE]  = q_r_dwait;
  end

  logic [NLD-1:0]                               vld_v, vld_wait;
  logic [NLD-1:0][IDW-1:0]                      vld_id;
  logic [NLD-1:0][G6LCCfg.XLEN-1:0]             vld_data;
  logic [NLD-1:0][G6LCCfg.NR_SB_ENTRIES-1:0]    vld_dwait;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0]             final_mask;
  logic                                        v_viol;
  logic [IDW-1:0]                              v_viol_id;
  logic [G6LCCfg.VLEN-1:0]                     v_viol_pc;

  g6lc_lsq_verdict #(
      .G6LCCfg (G6LCCfg),
      .NLD     (NLD),
      .NSV     (NR_UPDATE),
      .NR_ALLOC(NR_ALLOC)
  ) i_verdict (
      .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
      .ld_ev_valid_i (ld_ev_v),
      .ld_ev_id_i    (ld_ev_id),
      .ld_win_valid_i(ld_win_v),
      .ld_win_pay_i  (ld_win_pay),
      .ld_wait_i     (ld_wait),
      .ld_dwait_i    (ld_dwait),
      .st_ev_valid_i (uctxV_v & uctxV_is_st),
      .st_win_valid_i(vio_r_v),
      .st_win_id_i   (vio_r_id),
      .st_win_dist_i (vio_r_dist),
      .st_win_pay_i  (vio_r_pay),
      .ld_alloc_i    (ld_alloc_i),
      .alloc_id_i    (alloc_id_i),
      .ld_verdict_valid_o(vld_v),
      .ld_verdict_id_o   (vld_id),
      .ld_verdict_wait_o (vld_wait),
      .ld_verdict_data_o (vld_data),
      .ld_verdict_dwait_o(vld_dwait),
      .stl_stall_o   (stl_stall_o),
      .stl_forward_o (stl_forward_o),
      .stl_data_o    (stl_data_o),
      .mem_violation_o   (v_viol),
      .mem_violation_id_o(v_viol_id),
      .mem_violation_pc_o(v_viol_pc),
      .replay_valid_o(replay_valid_o),
      .replay_tid_o  (replay_tid_o),
      .final_o       (final_mask)
  );

  // ---------------- Release / checked ----------------
  // Store resolution events, per store tid: address resolves (staged
  // addr/phys event), commit frees it, or the tid is cancelled.
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] st_resolved, st_data_res;
  // hyp8: per-tid compare/OR gathers — the emit's dynamic-index OR-sets
  // serialize into one chain; each mask bit is an independent cone here.
  for (genvar t = 0; t < G6LCCfg.NR_SB_ENTRIES; t++) begin : gen_stres
    logic [NR_UPDATE-1:0]          ra, rd;
    logic [G6LCCfg.NrCommitPorts-1:0] rc;
    for (genvar u = 0; u < NR_UPDATE; u++) begin
      assign ra[u] = ev_addr_valid[u] && ev_addr_is_st[u] &&
                     (ev_addr_id[u] == IDW'(t));
      assign rd[u] = ev_data_valid[u] && (ev_data_id[u] == IDW'(t));
    end
    for (genvar c = 0; c < G6LCCfg.NrCommitPorts; c++)
      assign rc[c] = ev_commit_st[c] && (ev_commit_id[c] == IDW'(t));
    assign st_resolved[t] = cancelled_mask_i[t] || (|ra) ||
                            (ev_phys_valid[1] && ev_phys_id[1] == IDW'(t)) ||
                            (|rc);
    assign st_data_res[t] = cancelled_mask_i[t] || (|rd) || (|rc);
  end

  // Older same-hart unresolved stores per alloc port: the registered
  // unresolved mask hart-filtered, plus same-cycle older store
  // allocations (alloc ports carry program order p0 -> pN).
  logic [NR_ALLOC-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] alloc_older;
  for (genvar p = 0; p < NR_ALLOC; p++) begin : gen_alloc_older
    for (genvar t = 0; t < G6LCCfg.NR_SB_ENTRIES; t++) begin : gen_ao_t
      logic [NR_ALLOC-1:0] older_q;
      always_comb begin
        for (int unsigned q = 0; q < NR_ALLOC; q++)
          older_q[q] = (q < p) && st_alloc_i[q] &&
                       (alloc_id_i[q] == IDW'(t));
      end
      assign alloc_older[p][t] =
          (st_unresolved_mask_o[t] &&
           (LSQ_HART_OWN ? st_hart_mask_o[alloc_hart_i[p]][t] : 1'b1)) ||
          (|older_q);
    end
  end

  logic [LD_ENTRIES-1:0] unres_empty, dwait_empty;

  // Packed projections of the load entries for the release module.
  logic [LD_ENTRIES-1:0]              ld_valid_pack, ld_done_pack;
  logic [LD_ENTRIES-1:0][IDW-1:0]     ld_id_pack;

  // hyp8 T1 item 7: verdict→entry hit decoded once here (the wrapper
  // owns the entry→id table) so the release module sees one-hot rows.
  // Declared before i_release — slang requires declaration before use.
  logic [NLD-1:0][LD_ENTRIES-1:0] vld_ld_hit;
  always_comb begin
    for (int unsigned v = 0; v < NLD; v++)
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        vld_ld_hit[v][i] = vld_v[v] && (ld_q[i].id == vld_id[v]);
  end

  g6lc_lsq_release #(
      .G6LCCfg   (G6LCCfg),
      .LD_ENTRIES(LD_ENTRIES),
      .NR_ALLOC  (NR_ALLOC),
      .NLD       (NLD)
  ) i_release (
      .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,
      .ld_valid_i   (ld_valid_pack),
      .ld_done_i    (ld_done_pack),
      .ld_id_i      (ld_id_pack),
      .ld_alloc_v_i (ld_alloc_v),
      .ld_alloc_idx_i(ld_alloc_idx),
      .ld_alloc_oh_i (ld_alloc_oh),
      .alloc_older_i(alloc_older),
      .st_resolved_i(st_resolved),
      .st_data_res_i(st_data_res),
      .vld_dwait_v_i (vld_v),
      .vld_dwait_id_i(vld_id),
      .vld_ld_hit_i  (vld_ld_hit),
      .vld_dwait_i   (vld_dwait),
      .unres_empty_o (unres_empty),
      .dwait_empty_o (dwait_empty),
      .ld_release_o  (ld_release)
  );

  always_comb begin
    for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
      ld_valid_pack[i] = ld_q[i].valid;
      ld_done_pack[i]  = ld_q[i].done;
      ld_id_pack[i]    = ld_q[i].id;
    end
  end

  // ld_checked_o[tid]: the load's verdict is final AND no older store can
  // still resolve or deliver data — the publish gate (checked bit).
  // Sticky until the tid is re-allocated, cancelled, or flushed so a
  // freed entry cannot retract it.
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] checked_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      checked_q <= '0;
    end else if (flush_i) begin
      checked_q <= '0;
    end else begin
      for (int unsigned t = 0; t < G6LCCfg.NR_SB_ENTRIES; t++)
        if (cancelled_mask_i[t]) checked_q[t] <= 1'b0;
      for (int unsigned p = 0; p < NR_ALLOC; p++)
        if (ld_alloc_i[p]) checked_q[alloc_id_i[p]] <= 1'b0;
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ld_q[i].valid && final_mask[ld_q[i].id] &&
            unres_empty[i] && dwait_empty[i])
          checked_q[ld_q[i].id] <= 1'b1;
    end
  end
  assign ld_checked_o = checked_q;

  // ---------------- PHYS_VALIDATE paths (folded in WT) ----------------
  logic [LD_ENTRIES-1:0] phys_alias_cand;
  logic                          phys_viol;
  logic [IDW-1:0]                phys_viol_id;
  logic [G6LCCfg.VLEN-1:0]       phys_viol_pc;

  // hyp8: per-tid compare/OR gather (same independent-LHS form as
  // phys_replay_o below) instead of dynamic-index patch writes.
  for (genvar t = 0; t < G6LCCfg.NR_SB_ENTRIES; t++) begin : gen_pp_tid
    logic [LD_ENTRIES-1:0] peq;
    for (genvar l = 0; l < LD_ENTRIES; l++)
      assign peq[l] = ld_q[l].valid && !ld_q[l].addr_v &&
                      (ld_q[l].id == IDW'(t));
    assign phys_pending_o[t] = PHYS_VALIDATE && (|peq);
  end

  // PHYS_VALIDATE replay/alias scan — the emit's block, reading the
  // staged phys/mod records (+1 cycle vs the live inputs; folded off in
  // the WT configuration).
  // hyp8: fully unrolled compare vectors + per-tid OR-reduce — the emit's
  // nested dynamic-index writes (phys_replay_o[ld_q[l].id]) serialized the
  // whole scan into one dependency chain; a per-l candidate vector with a
  // per-tid compare/OR gather is bit-identical and log-depth.
  logic                  pv_live;
  logic [LD_ENTRIES-1:0] ulv;
  logic [LD_ENTRIES-1:0] pv_replay_c;

  for (genvar r = 0; r < LD_ENTRIES; r++) begin : gen_ulv
    assign ulv[r] = ev_phys_valid[0] && ld_q[r].valid &&
        sb_live_i[ld_q[r].id] && !cancelled_mask_i[ld_q[r].id] &&
        ev_phys_id[0] == ld_q[r].id && ev_phys_hart[0] == ld_q[r].hart;
  end
  assign pv_live = |ulv;

  // hyp8: the store-side event select / byte-enable is invariant in l —
  // compute it once per store entry instead of inside the l×s pair scan
  // (bit-identical, removes the replicated mux→lane_be chain from the
  // per-pair compare cone).
  logic [ST_ENTRIES-1:0]           s_sev, s_skn;
  logic [ST_ENTRIES-1:0][G6LCCfg.PLEN-1:0] s_addr;
  logic [ST_ENTRIES-1:0][1:0]      s_size;
  logic [ST_ENTRIES-1:0][LANES-1:0] s_be;
  logic [LANES-1:0]                ev0_be;
  for (genvar s = 0; s < ST_ENTRIES; s++) begin : gen_sattr
    assign s_sev[s]  = ev_phys_valid[1] && ev_phys_id[1] == st_q[s].id &&
                       ev_phys_hart[1] == st_q[s].hart;
    assign s_skn[s]  = st_q[s].addr_v || s_sev[s];
    assign s_addr[s] = s_sev[s] ? ev_phys_addr[1] : st_q[s].addr;
    assign s_size[s] = s_sev[s] ? ev_phys_size[1] : st_q[s].size;
    assign s_be[s]   = lane_be(s_addr[s], s_size[s]);
  end
  assign ev0_be = lane_be(ev_phys_addr[0], ev_phys_size[0]);

  for (genvar l = 0; l < LD_ENTRIES; l++) begin : gen_phys_l
    logic                        levt, lkn, outer_l, condA;
    logic [G6LCCfg.PLEN-1:0]     laddr;
    logic [1:0]                  lsize;
    logic [LANES-1:0]            lbe;
    logic [1:0]                  mm;
    logic [ST_ENTRIES-1:0]       pm;
    assign levt  = ev_phys_valid[0] && ev_phys_id[0] == ld_q[l].id &&
                   ev_phys_hart[0] == ld_q[l].hart;
    assign lkn   = ld_q[l].addr_v || levt;
    assign laddr = levt ? ev_phys_addr[0] : ld_q[l].addr;
    assign lsize = levt ? ev_phys_size[0] : ld_q[l].size;
    assign lbe   = lane_be(laddr, lsize);
    assign outer_l = ld_q[l].valid && sb_live_i[ld_q[l].id] &&
        !cancelled_mask_i[ld_q[l].id] && lkn &&
        !config_pkg::is_inside_nonidempotent_regions(G6LCCfg, 64'(laddr));
    assign condA = pv_live && ev_phys_hart[0] == ld_q[l].hart &&
        g6lc_ooo_pkg::ooo_age_older(IDW, 32'(ev_phys_id[0]),
                                    32'(ld_q[l].id), 32'(commit_ptr_i)) &&
        same_word(ev_phys_addr[0], laddr) &&
        ((ev0_be & lbe) != '0);
    for (genvar m = 0; m < 2; m++)
      assign mm[m] = ev_mod_valid[m] &&
                     ((laddr >> LINE_OFF) == (ev_mod_addr[m] >> LINE_OFF));
    for (genvar s = 0; s < ST_ENTRIES; s++) begin : gen_phys_s
      assign pm[s] = st_q[s].valid && sb_live_i[st_q[s].id] &&
              !cancelled_mask_i[st_q[s].id] &&
              st_q[s].hart == ld_q[l].hart && s_skn[s] &&
              (levt || s_sev[s]) &&
              g6lc_ooo_pkg::ooo_age_older(IDW, 32'(st_q[s].id),
                                          32'(ld_q[l].id), 32'(commit_ptr_i)) &&
              same_word(s_addr[s], laddr) &&
              ((s_be[s] & lbe) != '0);
    end
    assign pv_replay_c[l] = outer_l && (condA || (|mm) || (|pm));
    assign phys_alias_cand[l] = (PHYS_VALIDATE && !flush_i) && (outer_l && |pm);
  end

  for (genvar t = 0; t < G6LCCfg.NR_SB_ENTRIES; t++) begin : gen_pv_tid
    logic [LD_ENTRIES-1:0] eq;
    for (genvar l = 0; l < LD_ENTRIES; l++)
      assign eq[l] = pv_replay_c[l] && (ld_q[l].id == IDW'(t));
    assign phys_replay_o[t] = PHYS_VALIDATE && !flush_i && (|eq);
  end

  // PHYS_VALIDATE violation report — oldest alias candidate, registered
  // (+3 to sit with the verdict; folded off in the WT config).
  localparam int unsigned LdSelLeaves = 1 << $clog2(LD_ENTRIES);
  localparam int unsigned LdSelW = (LD_ENTRIES > 1) ? $clog2(LD_ENTRIES) : 1;
  logic [2*LdSelLeaves-1:1]           pv_pick_valid;
`ifdef G6LC_MUT_T2_LSQ_PICKDIST
  // Review mutant: 32-bit distances, the pre-r42 form.
  logic [2*LdSelLeaves-1:1][31:0]     pv_pick_dist;
  logic [LD_ENTRIES-1:0][31:0]        ld_dist;
`else
  // r42-T R5: the circular distance is < 2**IDW; carry IDW+1 bits with
  // bit IDW as the invalid sentinel instead of a 32-bit magnitude.
  logic [2*LdSelLeaves-1:1][IDW:0]    pv_pick_dist;
  logic [LD_ENTRIES-1:0][IDW:0]       ld_dist;
`endif
  logic [2*LdSelLeaves-1:1][LdSelW-1:0] pv_pick_slot;
  for (genvar j = 0; j < LD_ENTRIES; j++) begin : gen_ld_dist
    assign ld_dist[j] = $bits(ld_dist[j])'(g6lc_ooo_pkg::ooo_age_dist(
        IDW, 32'(ld_q[j].id), 32'(commit_ptr_i)));
  end
  for (genvar j = 0; j < LdSelLeaves; j++) begin : gen_pv_leaf
    if (j < LD_ENTRIES) begin : gen_entry
      assign pv_pick_valid[LdSelLeaves+j] =
`ifdef G6LC_MUT_T2_LSQ_PICKDIST
          phys_alias_cand[j] && ld_dist[j] != 32'hFFFF_FFFF;
`else
          // ooo_age_dist returns < 2**IDW (top bit 0); the old 32'hFF..
          // compare was tautological, so the valid arm reduces to the
          // candidate bit. Pad leaves carry the '1 sentinel.
          phys_alias_cand[j];
`endif
      assign pv_pick_dist[LdSelLeaves+j] = ld_dist[j];
      assign pv_pick_slot[LdSelLeaves+j] = LdSelW'(j);
    end else begin : gen_pad
      assign pv_pick_valid[LdSelLeaves+j] = 1'b0;
      assign pv_pick_dist[LdSelLeaves+j]  = '1;
      assign pv_pick_slot[LdSelLeaves+j]  = '0;
    end
  end
  for (genvar n = 1; n < LdSelLeaves; n++) begin : gen_pv_pick
    logic take_right;
    assign take_right = pv_pick_valid[2*n+1] &&
                        (!pv_pick_valid[2*n] || pv_pick_dist[2*n+1] < pv_pick_dist[2*n]);
    assign pv_pick_valid[n] = pv_pick_valid[2*n] | pv_pick_valid[2*n+1];
    assign pv_pick_dist[n]  = take_right ? pv_pick_dist[2*n+1] : pv_pick_dist[2*n];
    assign pv_pick_slot[n]  = take_right ? pv_pick_slot[2*n+1] : pv_pick_slot[2*n];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phys_viol    <= 1'b0;
      phys_viol_id <= '0;
      phys_viol_pc <= '0;
    end else if (flush_i) begin
      phys_viol    <= 1'b0;
      phys_viol_id <= '0;
      phys_viol_pc <= '0;
    end else begin
      phys_viol    <= PHYS_VALIDATE && pv_pick_valid[1];
      phys_viol_id <= (PHYS_VALIDATE && pv_pick_valid[1]) ? ld_q[pv_pick_slot[1]].id : '0;
      phys_viol_pc <= (PHYS_VALIDATE && pv_pick_valid[1]) ? ld_q[pv_pick_slot[1]].pc : '0;
    end
  end

  assign mem_violation_o    = v_viol || phys_viol;
  assign mem_violation_id_o = v_viol ? v_viol_id : phys_viol_id;
  assign mem_violation_pc_o = v_viol ? v_viol_pc : phys_viol_pc;

//pragma translate_off
  // r42-T R5 equivalence: recompute the pre-r42 32-bit pv tournament.
  int unsigned t2_pvpick_n = 0;
  logic [2*LdSelLeaves-1:1][31:0]       pvref_dist;
  logic [2*LdSelLeaves-1:1]             pvref_valid;
  logic [2*LdSelLeaves-1:1][LdSelW-1:0] pvref_slot;
  logic [LD_ENTRIES-1:0][31:0]          pvref_ldist;
  for (genvar j = 0; j < LD_ENTRIES; j++) begin : gen_pvref_d
    assign pvref_ldist[j] = g6lc_ooo_pkg::ooo_age_dist(
        IDW, 32'(ld_q[j].id), 32'(commit_ptr_i));
  end
  for (genvar j = 0; j < LdSelLeaves; j++) begin : gen_pvref_leaf
    if (j < LD_ENTRIES) begin : ge
      assign pvref_valid[LdSelLeaves+j] =
          phys_alias_cand[j] && pvref_ldist[j] != 32'hFFFF_FFFF;
      assign pvref_dist[LdSelLeaves+j] = pvref_ldist[j];
      assign pvref_slot[LdSelLeaves+j] = LdSelW'(j);
    end else begin : gp
      assign pvref_valid[LdSelLeaves+j] = 1'b0;
      assign pvref_dist[LdSelLeaves+j]  = '1;
      assign pvref_slot[LdSelLeaves+j]  = '0;
    end
  end
  for (genvar n = 1; n < LdSelLeaves; n++) begin : gen_pvref_pick
    logic tr;
    assign tr = pvref_valid[2*n+1] &&
                (!pvref_valid[2*n] || pvref_dist[2*n+1] < pvref_dist[2*n]);
    assign pvref_valid[n] = pvref_valid[2*n] | pvref_valid[2*n+1];
    assign pvref_dist[n]  = tr ? pvref_dist[2*n+1] : pvref_dist[2*n];
    assign pvref_slot[n]  = tr ? pvref_slot[2*n+1] : pvref_slot[2*n];
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i) begin
      t2_pvpick_n <= t2_pvpick_n + 1;
      g6lc_t2_pvpick_eq: assert (
          pv_pick_valid[1] === pvref_valid[1] &&
          (!pv_pick_valid[1] || pv_pick_slot[1] === pvref_slot[1]))
        else $error("g6lc_lsq: equiv pv_pick");
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_lsq pvpick: checked=%0d", t2_pvpick_n);
  end
//pragma translate_on

//pragma translate_off
  // +lsq_trace: load-entry release lifetime probe (diagnostic only).
  bit lsq_trace;
  int unsigned lsq_cyc = 0;
  int unsigned lsq_lo, lsq_hi;
  logic [LD_ENTRIES-1:0]                            lp_seen;
  logic [LD_ENTRIES-1:0]                            lp_done, lp_rel;
  logic [LD_ENTRIES-1:0][IDW-1:0]                   lp_id;
  logic [LD_ENTRIES-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] lp_unres, lp_dwait;
  initial begin
    lsq_trace = $test$plusargs("lsq_trace");
    lsq_lo = 0;
    lsq_hi = 3000;
    void'($value$plusargs("trace_from=%d", lsq_lo));
    void'($value$plusargs("trace_to=%d", lsq_hi));
  end

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      lsq_cyc = 0;
      lp_seen = '0;
    end else if (lsq_trace) begin
      lsq_cyc++;
      if (lsq_cyc >= lsq_lo && lsq_cyc <= lsq_hi) begin
        for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
          if (ld_q[i].valid) begin
            if (!lp_seen[i] || lp_done[i] != ld_q[i].done ||
                lp_id[i] != ld_q[i].id ||
                lp_unres[i] != i_release.unres_q[i] ||
                lp_dwait[i] != i_release.dwait_q[i] ||
                lp_rel[i]  != ld_release[i]) begin
              $display("[lsq] c=%0d ld i=%0d id=%0d done=%b unres=%h dwait=%h rel=%b",
                       lsq_cyc, i, ld_q[i].id, ld_q[i].done,
                       i_release.unres_q[i], i_release.dwait_q[i],
                       ld_release[i]);
              lp_seen[i]  = 1'b1;
              lp_done[i]  = ld_q[i].done;
              lp_id[i]    = ld_q[i].id;
              lp_unres[i] = i_release.unres_q[i];
              lp_dwait[i] = i_release.dwait_q[i];
              lp_rel[i]   = ld_release[i];
            end
          end else lp_seen[i] = 1'b0;
        end
        for (int unsigned v = 0; v < NLD; v++)
          if (vld_v[v])
            $display("[lsq] c=%0d dwait_set v=%0d id=%0d mask=%h",
                     lsq_cyc, v, vld_id[v], vld_dwait[v]);
        if (|st_resolved)
          $display("[lsq] c=%0d st_resolved=%h", lsq_cyc, st_resolved);
        if (|st_data_res)
          $display("[lsq] c=%0d st_data_res=%h", lsq_cyc, st_data_res);
        for (int unsigned p = 0; p < NR_ALLOC; p++)
          if (ld_alloc_v[p])
            $display("[lsq] c=%0d ld_alloc p=%0d idx=%0d id=%0d older=%h",
                     lsq_cyc, p, ld_alloc_idx[p], alloc_id_i[p],
                     alloc_older[p]);
        for (int unsigned p = 0; p < G6LCCfg.NrWbPorts; p++) begin
          if (complete_valid_i[p])
            $display("[lsq] c=%0d complete_in p=%0d id=%0d is_st=%b canc=%b",
                     lsq_cyc, p, complete_id_i[p], complete_is_st_i[p],
                     cancelled_mask_i[complete_id_i[p]]);
          if (ev_complete_valid[p])
            $display("[lsq] c=%0d ev_complete p=%0d id=%0d is_st=%b",
                     lsq_cyc, p, ev_complete_id[p], ev_complete_is_st[p]);
        end
      end
    end
  end
//pragma translate_on

endmodule
