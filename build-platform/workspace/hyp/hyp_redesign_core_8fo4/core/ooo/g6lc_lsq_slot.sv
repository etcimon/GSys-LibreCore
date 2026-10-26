// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq_slot — hyp8 LSQ entry arrays.
//
// Owns the per-entry store/load records of the emit base (valid, addr_v,
// data_v, done, id, hart, addr, data, size, pc) and every writer of them:
//
//   * allocation — lowest-free per alloc port in program order (port 0
//     first), exactly the emit's admission behaviour;
//   * staged-event application — one cycle after the update port asserted,
//     the event record selects its entry by a per-entry transaction-id
//     compare (5–6-bit compare per port per entry) and writes the field;
//   * multi-WB complete (loads' `done`), store release by commit id, and
//     completed-load release (`ld_release_i`, from g6lc_lsq_release);
//   * cancellation — `cancelled_mask_i[id]` drops the entry in place, and
//     also gates each staged event's application so a record killed in
//     flight never reaches the entry (contract §3);
//   * flush — clears the speculative arrays (LSU tombstones, the committed
//     store queue and the write-buffer pending record are owned elsewhere
//     and survive — H7).
//
// The emit's many-writer `st_d`/`ld_d` comb block read live update ports;
// hyp8 replaces those inputs with the registered event records from
// g6lc_lsq_event, so the cone into the arrays starts at a register.
// PHYS_VALIDATE updates apply from the staged `phys` records one cycle
// late; the WT configuration folds that path exactly as the emit did.
//
// `ev_ld_hart_o`/`ev_st_hart_o` resolve a staged address event's hart tag
// from the entry it names (allocation carried the hart — the AGU path
// does not) so the CAM banks can keep the per-hart ordering rules (T6b).

module g6lc_lsq_slot #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned LD_ENTRIES = 8,
    parameter int unsigned ST_ENTRIES = 8,
    parameter int unsigned NR_ALLOC   = 2,
    parameter int unsigned NR_UPDATE  = 2,
    // Entry layouts — identical packed-struct typedefs are declared in the
    // g6lc_lsq wrapper and injected here (the parameter-type seam).
    parameter type st_ent_t = logic,
    parameter type ld_ent_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Scoreboard issued mask (PHYS_VALIDATE path, as the emit base).
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_live_i,

    // Multi-port allocate at dispatch — live inputs, as today.
    input  logic [NR_ALLOC-1:0]                              ld_alloc_i,
    input  logic [NR_ALLOC-1:0]                              st_alloc_i,
    input  logic [NR_ALLOC-1:0][G6LCCfg.TRANS_ID_BITS-1:0]   alloc_id_i,
    input  logic [NR_ALLOC-1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] alloc_hart_i,
    input  logic [NR_ALLOC-1:0][G6LCCfg.VLEN-1:0]            alloc_pc_i,

    // Staged event records (registered in g6lc_lsq_event).
    input  logic [NR_UPDATE-1:0]                             ev_addr_valid_i,
    input  logic [NR_UPDATE-1:0]                             ev_addr_is_st_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.TRANS_ID_BITS-1:0]  ev_addr_id_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.PLEN-1:0]           ev_addr_i,
    input  logic [NR_UPDATE-1:0][1:0]                        ev_addr_size_i,
    // hyp8 T1 item 2: the staged byte-lane footprint, registered beside
    // the event address in g6lc_lsq_event.
    input  logic [NR_UPDATE-1:0][(G6LCCfg.XLEN+7)/8-1:0]         ev_addr_be_i,
    input  logic [NR_UPDATE-1:0]                             ev_data_valid_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.TRANS_ID_BITS-1:0]  ev_data_id_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.XLEN-1:0]           ev_data_i,
    input  logic [G6LCCfg.NrWbPorts-1:0]                     ev_complete_valid_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] ev_complete_id_i,
    input  logic [G6LCCfg.NrWbPorts-1:0]                     ev_complete_is_st_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0]                 ev_commit_st_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0]                 ev_commit_ld_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] ev_commit_id_i,
    input  logic [1:0]                                       ev_phys_valid_i,
    input  logic [1:0][G6LCCfg.PLEN-1:0]                     ev_phys_addr_i,
    input  logic [1:0][G6LCCfg.TRANS_ID_BITS-1:0]            ev_phys_id_i,
    input  logic [1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ev_phys_hart_i,
    input  logic [1:0][1:0]                                  ev_phys_size_i,

    // Completed-load release (registered older-unresolved mask empty).
    input  logic [LD_ENTRIES-1:0]                            ld_release_i,

    // Entry arrays, registered.
    output st_ent_t [ST_ENTRIES-1:0] st_o,
    output ld_ent_t [LD_ENTRIES-1:0] ld_o,

    // Staged address events' resolved hart tags (for the CAM banks).
    output logic [NR_UPDATE-1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ev_st_hart_o,
    output logic [NR_UPDATE-1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ev_ld_hart_o,
    // Staged address events' resolved load-entry PC (the same-cycle
    // virtual-candidate violation leaf needs the querying load's PC).
    output logic [NR_UPDATE-1:0][G6LCCfg.VLEN-1:0]        ev_ld_pc_o,

    // Allocation index per port (release snapshots its older-store mask
    // into the entry being written).
    output logic [NR_ALLOC-1:0]                           ld_alloc_v_o,
    output logic [NR_ALLOC-1:0][$clog2(LD_ENTRIES)-1:0]   ld_alloc_idx_o,
    // hyp8 T1 item 7: the same pick as a one-hot (release's per-entry
    // alloc_hit without a per-entry index compare).
    output logic [NR_ALLOC-1:0][LD_ENTRIES-1:0]           ld_alloc_oh_o
);

  localparam int unsigned HID_W =
      $clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2);
  localparam int unsigned LANES = (G6LCCfg.XLEN + 7) / 8;
  localparam bit PHYS_VALIDATE = G6LCCfg.CohPolicy == config_pkg::COH_OOO;

  // Byte-lane footprint of an access inside its aligned XLEN word — the
  // emit base's lane_be, verbatim (used on the PHYS_VALIDATE write path;
  // the AGU path carries the staged ev_addr_be_i).
  function automatic logic [LANES-1:0] lane_be(
      input logic [G6LCCfg.PLEN-1:0] a,
      input logic [1:0]              size
  );
    automatic logic [LANES-1:0] m;
    m = '0;
    for (int unsigned b = 0; b < LANES; b++)
      if (b < (1 << size)) m[b] = 1'b1;
    if (G6LCCfg.XLEN == 64)
      lane_be = m << a[2:0];
    else
      lane_be = m << a[1:0];
  endfunction

  st_ent_t [ST_ENTRIES-1:0] st_q, st_d;
  ld_ent_t [LD_ENTRIES-1:0] ld_q, ld_d;

  assign st_o = st_q;
  assign ld_o = ld_q;

  // Event hart resolution: the allocating dispatch carried the hart into
  // the entry; an update names only its id.  Compares are per-entry,
  // per-port (NR_UPDATE x ST_ENTRIES / LD_ENTRIES, 6-bit each).
  always_comb begin
    for (int unsigned u = 0; u < NR_UPDATE; u++) begin
      ev_st_hart_o[u] = '0;
      for (int unsigned i = 0; i < ST_ENTRIES; i++)
        if (st_q[i].valid && st_q[i].id == ev_addr_id_i[u])
          ev_st_hart_o[u] = st_q[i].hart;
      ev_ld_hart_o[u] = '0;
      ev_ld_pc_o[u]   = '0;
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ld_q[i].valid && ld_q[i].id == ev_addr_id_i[u]) begin
          ev_ld_hart_o[u] = ld_q[i].hart;
          ev_ld_pc_o[u]   = ld_q[i].pc;
        end
    end
  end

  // First-free one-hot per alloc port. Port 0 takes the lowest invalid
  // entry; port 1 takes the next. Same admission as the reference scan:
  // ld_alloc_v_o is set only when a slot was actually claimed.
  logic [NR_ALLOC-1:0][LD_ENTRIES-1:0] ld_oh;
  logic [NR_ALLOC-1:0][ST_ENTRIES-1:0] st_oh;
  logic [LD_ENTRIES-1:0] ld_inv;
  logic [ST_ENTRIES-1:0] st_inv;
  for (genvar i = 0; i < LD_ENTRIES; i++) assign ld_inv[i] = !ld_q[i].valid;
  for (genvar i = 0; i < ST_ENTRIES; i++) assign st_inv[i] = !st_q[i].valid;
  for (genvar p = 0; p < NR_ALLOC; p++) begin : gen_alloc_oh
    logic [LD_ENTRIES-1:0] ld_pool;
    logic [ST_ENTRIES-1:0] st_pool;
    always_comb begin
      ld_pool = ld_inv;
      st_pool = st_inv;
      for (int unsigned q = 0; q < NR_ALLOC; q++)
        if (q < p) begin
          // Reserve an earlier port's pick only while that port actually
          // allocates. Unmasked, a non-allocating port still consumes the
          // lowest free slot in this pool, so a later allocating port can
          // find its pool empty while the dispatch-side free count passed
          // the group check: the alloc then drops silently and the op has
          // no LSQ record for the rest of its lifetime (hyp8-osbi-ld-diag-r2:
          // lane-1 load lost at ld_free==1, tid 21 never checked).
          ld_pool &= ~(ld_oh[q] & {LD_ENTRIES{ld_alloc_i[q]}});
          st_pool &= ~(st_oh[q] & {ST_ENTRIES{st_alloc_i[q]}});
        end
    end
    assign ld_oh[p] = ld_pool & (~ld_pool + {{LD_ENTRIES-1{1'b0}}, 1'b1});
    assign st_oh[p] = st_pool & (~st_pool + {{ST_ENTRIES-1{1'b0}}, 1'b1});
    // hyp8 T1 item 7: the allocated slot decoded at the source.
    assign ld_alloc_oh_o[p] = ld_oh[p] & {LD_ENTRIES{ld_alloc_i[p]}};
  end

  // hyp8 T1 item 14: row-local hit decodes for every write source into
  // the store/load records. Each source's per-entry hit is a one-hot
  // column gather computed in parallel; the per-entry arm then selects
  // the winning source's value instead of the serial override chain
  // (the arm VALUES chained through 21 deps in the source-order form).
  logic [NR_UPDATE-1:0][ST_ENTRIES-1:0] st_ahit_m;
  logic [NR_UPDATE-1:0][LD_ENTRIES-1:0] ld_ahit_m;
  logic [NR_UPDATE-1:0][ST_ENTRIES-1:0] st_dhit_m;
  logic [ST_ENTRIES-1:0]                st_phit, st_cmt;
  logic [LD_ENTRIES-1:0]                ld_phit, ld_cmt, ld_cpl;
  logic [NR_ALLOC-1:0][ST_ENTRIES-1:0]  st_alloc_hit_m;
  logic [NR_ALLOC-1:0][LD_ENTRIES-1:0]  ld_alloc_hit_m;
  for (genvar u = 0; u < NR_UPDATE; u++) begin : gen_slot_hit_u
    logic ev_st_ok, ev_ld_ok, ev_d_ok;
    assign ev_st_ok = !PHYS_VALIDATE && ev_addr_valid_i[u] &&
                      ev_addr_is_st_i[u] &&
                      !cancelled_mask_i[ev_addr_id_i[u]];
    assign ev_ld_ok = !PHYS_VALIDATE && ev_addr_valid_i[u] &&
                      !ev_addr_is_st_i[u] &&
                      !cancelled_mask_i[ev_addr_id_i[u]];
    assign ev_d_ok  = ev_data_valid_i[u] &&
                      !cancelled_mask_i[ev_data_id_i[u]];
    for (genvar i = 0; i < ST_ENTRIES; i++) begin : gen_st_hit
      assign st_ahit_m[u][i] = ev_st_ok && st_q[i].valid &&
                               st_q[i].id == ev_addr_id_i[u];
      assign st_dhit_m[u][i] = ev_d_ok && st_q[i].valid &&
                               st_q[i].id == ev_data_id_i[u];
    end
    for (genvar i = 0; i < LD_ENTRIES; i++) begin : gen_ld_hit
      assign ld_ahit_m[u][i] = ev_ld_ok && ld_q[i].valid &&
                               ld_q[i].id == ev_addr_id_i[u];
    end
  end
  for (genvar i = 0; i < ST_ENTRIES; i++) begin : gen_st_hit2
    assign st_phit[i] = PHYS_VALIDATE && ev_phys_valid_i[1] &&
                        st_q[i].valid && sb_live_i[st_q[i].id] &&
                        !cancelled_mask_i[ev_phys_id_i[1]] &&
                        st_q[i].id == ev_phys_id_i[1] &&
                        st_q[i].hart == ev_phys_hart_i[1];
    logic [G6LCCfg.NrCommitPorts-1:0] ccol;
    for (genvar c = 0; c < G6LCCfg.NrCommitPorts; c++)
      assign ccol[c] = ev_commit_st_i[c] && st_q[i].valid &&
                       st_q[i].id == ev_commit_id_i[c];
    assign st_cmt[i] = |ccol;
    for (genvar p = 0; p < NR_ALLOC; p++)
      assign st_alloc_hit_m[p][i] = st_alloc_i[p] && st_oh[p][i];
  end
  for (genvar i = 0; i < LD_ENTRIES; i++) begin : gen_ld_hit2
    assign ld_phit[i] = PHYS_VALIDATE && ev_phys_valid_i[0] &&
                        ld_q[i].valid && sb_live_i[ld_q[i].id] &&
                        !cancelled_mask_i[ev_phys_id_i[0]] &&
                        ld_q[i].id == ev_phys_id_i[0] &&
                        ld_q[i].hart == ev_phys_hart_i[0];
    logic [G6LCCfg.NrCommitPorts-1:0] ccol;
    for (genvar c = 0; c < G6LCCfg.NrCommitPorts; c++)
      assign ccol[c] = ev_commit_ld_i[c] && ld_q[i].valid &&
                       ld_q[i].id == ev_commit_id_i[c];
    assign ld_cmt[i] = |ccol;
    logic [G6LCCfg.NrWbPorts-1:0] wcol;
    for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++)
      assign wcol[w] = ev_complete_valid_i[w] && !ev_complete_is_st_i[w] &&
                       !cancelled_mask_i[ev_complete_id_i[w]] &&
                       ld_q[i].valid && ld_q[i].id == ev_complete_id_i[w];
    assign ld_cpl[i] = |wcol;
    for (genvar p = 0; p < NR_ALLOC; p++)
      assign ld_alloc_hit_m[p][i] = ld_alloc_i[p] && ld_oh[p][i];
  end
  // Per-entry winning update port (last in program order, matching the
  // emit's u-loop write order).
  logic [ST_ENTRIES-1:0][$clog2(NR_UPDATE)-1:0] st_au, st_du;
  logic [LD_ENTRIES-1:0][$clog2(NR_UPDATE)-1:0] ld_au;
  for (genvar i = 0; i < ST_ENTRIES; i++) begin : gen_st_u
    always_comb begin
      st_au[i] = '0;
      st_du[i] = '0;
      for (int unsigned u = 0; u < NR_UPDATE; u++) begin
        if (st_ahit_m[u][i]) st_au[i] = u[$clog2(NR_UPDATE)-1:0];
        if (st_dhit_m[u][i]) st_du[i] = u[$clog2(NR_UPDATE)-1:0];
      end
    end
  end
  for (genvar i = 0; i < LD_ENTRIES; i++) begin : gen_ld_u
    always_comb begin
      ld_au[i] = '0;
      for (int unsigned u = 0; u < NR_UPDATE; u++)
        if (ld_ahit_m[u][i]) ld_au[i] = u[$clog2(NR_UPDATE)-1:0];
    end
  end
  logic [ST_ENTRIES-1:0] st_ahit, st_dhit, st_ahit_a;
  logic [LD_ENTRIES-1:0] ld_ahit, ld_ahit_a, st_alloc_any, ld_alloc_any;
  for (genvar i = 0; i < ST_ENTRIES; i++) begin : gen_st_any
    logic [NR_UPDATE-1:0] acol, dcol;
    logic [NR_ALLOC-1:0]  pcol;
    for (genvar u = 0; u < NR_UPDATE; u++) begin
      assign acol[u] = st_ahit_m[u][i];
      assign dcol[u] = st_dhit_m[u][i];
    end
    for (genvar p = 0; p < NR_ALLOC; p++)
      assign pcol[p] = st_alloc_hit_m[p][i];
    assign st_ahit[i] = |acol;
    assign st_dhit[i] = |dcol;
    assign st_alloc_any[i] = |pcol;
  end
  for (genvar i = 0; i < LD_ENTRIES; i++) begin : gen_ld_any
    logic [NR_UPDATE-1:0] acol;
    logic [NR_ALLOC-1:0]  pcol;
    for (genvar u = 0; u < NR_UPDATE; u++)
      assign acol[u] = ld_ahit_m[u][i];
    for (genvar p = 0; p < NR_ALLOC; p++)
      assign pcol[p] = ld_alloc_hit_m[p][i];
    assign ld_ahit[i] = |acol;
    assign ld_alloc_any[i] = |pcol;
  end
  // Per-port alloc value select (at most one port hits each entry).
  logic [ST_ENTRIES-1:0][G6LCCfg.TRANS_ID_BITS-1:0] st_alloc_id_sel;
  logic [ST_ENTRIES-1:0][HID_W-1:0]               st_alloc_h_sel;
  logic [LD_ENTRIES-1:0][G6LCCfg.TRANS_ID_BITS-1:0] ld_alloc_id_sel;
  logic [LD_ENTRIES-1:0][HID_W-1:0]               ld_alloc_h_sel;
  logic [LD_ENTRIES-1:0][G6LCCfg.VLEN-1:0]        ld_alloc_pc_sel;
  for (genvar i = 0; i < ST_ENTRIES; i++) begin : gen_st_asel
    always_comb begin
      st_alloc_id_sel[i] = '0;
      st_alloc_h_sel[i]  = '0;
      for (int unsigned p = 0; p < NR_ALLOC; p++)
        if (st_alloc_hit_m[p][i]) begin
          st_alloc_id_sel[i] = alloc_id_i[p];
          st_alloc_h_sel[i]  = alloc_hart_i[p];
        end
    end
  end
  for (genvar i = 0; i < LD_ENTRIES; i++) begin : gen_ld_asel
    always_comb begin
      ld_alloc_id_sel[i] = '0;
      ld_alloc_h_sel[i]  = '0;
      ld_alloc_pc_sel[i] = '0;
      for (int unsigned p = 0; p < NR_ALLOC; p++)
        if (ld_alloc_hit_m[p][i]) begin
          ld_alloc_id_sel[i] = alloc_id_i[p];
          ld_alloc_h_sel[i]  = alloc_hart_i[p];
          ld_alloc_pc_sel[i] = alloc_pc_i[p];
        end
    end
  end

  always_comb begin
    st_d = st_q;
    ld_d = ld_q;
    ld_alloc_v_o   = '0;
    ld_alloc_idx_o = '0;

`ifdef G6LC_MUT_T1_SLOT
    // Review mutant: pre-T1 serial override chain on the live path.
    // Multi-port alloc (program order p=0 first) — emit behaviour kept.
    for (int unsigned p = 0; p < NR_ALLOC; p++) begin
      if (ld_alloc_i[p]) begin
        for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
          if (ld_oh[p][i]) begin
            ld_d[i].valid  = 1'b1;
            ld_d[i].addr_v = 1'b0;
            ld_d[i].done   = 1'b0;
            ld_d[i].id     = alloc_id_i[p];
            ld_d[i].hart   = alloc_hart_i[p];
            ld_d[i].addr   = '0;
            ld_d[i].size   = '0;
            ld_d[i].be     = '0;
            ld_d[i].pc     = alloc_pc_i[p];
            ld_alloc_v_o[p]   = 1'b1;
            ld_alloc_idx_o[p] = $clog2(LD_ENTRIES)'(i);
          end
        end
      end
      if (st_alloc_i[p]) begin
        for (int unsigned i = 0; i < ST_ENTRIES; i++) begin
          if (st_oh[p][i]) begin
            st_d[i].valid  = 1'b1;
            st_d[i].addr_v = 1'b0;
            st_d[i].data_v = 1'b0;
            st_d[i].id     = alloc_id_i[p];
            st_d[i].hart   = alloc_hart_i[p];
            st_d[i].addr   = '0;
            st_d[i].data   = '0;
            st_d[i].size   = 2'b10;
            st_d[i].be     = '0;
          end
        end
      end
    end

    // Staged AGU address / size — one cycle after the port asserted, and
    // suppressed when the record's id died in flight (contract §3 kill).
    for (int unsigned u = 0; u < NR_UPDATE; u++) begin
      if (!PHYS_VALIDATE && ev_addr_valid_i[u] &&
          !cancelled_mask_i[ev_addr_id_i[u]]) begin
        if (ev_addr_is_st_i[u]) begin
          for (int unsigned i = 0; i < ST_ENTRIES; i++)
            if (st_q[i].valid && st_q[i].id == ev_addr_id_i[u]) begin
              st_d[i].addr_v = 1'b1;
              st_d[i].addr   = ev_addr_i[u];
              st_d[i].size   = ev_addr_size_i[u];
              st_d[i].be     = ev_addr_be_i[u];
            end
        end else begin
          for (int unsigned i = 0; i < LD_ENTRIES; i++)
            if (ld_q[i].valid && ld_q[i].id == ev_addr_id_i[u]) begin
              ld_d[i].addr_v = 1'b1;
              ld_d[i].addr   = ev_addr_i[u];
              ld_d[i].size   = ev_addr_size_i[u];
              ld_d[i].be     = ev_addr_be_i[u];
            end
        end
      end
      if (ev_data_valid_i[u] && !cancelled_mask_i[ev_data_id_i[u]]) begin
        for (int unsigned i = 0; i < ST_ENTRIES; i++)
          if (st_q[i].valid && st_q[i].id == ev_data_id_i[u]) begin
            st_d[i].data_v = 1'b1;
            st_d[i].data   = ev_data_i[u];
          end
      end
    end

    // PHYS_VALIDATE updates from the staged phys records (+1 vs the emit;
    // the WT config folds this path).
    if (PHYS_VALIDATE) begin
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ev_phys_valid_i[0] && ld_q[i].valid && sb_live_i[ld_q[i].id] &&
            !cancelled_mask_i[ev_phys_id_i[0]] &&
            ld_q[i].id == ev_phys_id_i[0] && ld_q[i].hart == ev_phys_hart_i[0]) begin
          ld_d[i].addr_v = 1'b1;
          ld_d[i].addr   = ev_phys_addr_i[0];
          ld_d[i].size   = ev_phys_size_i[0];
          ld_d[i].be     = lane_be(ev_phys_addr_i[0], ev_phys_size_i[0]);
        end
      for (int unsigned i = 0; i < ST_ENTRIES; i++)
        if (ev_phys_valid_i[1] && st_q[i].valid && sb_live_i[st_q[i].id] &&
            !cancelled_mask_i[ev_phys_id_i[1]] &&
            st_q[i].id == ev_phys_id_i[1] && st_q[i].hart == ev_phys_hart_i[1]) begin
          st_d[i].addr_v = 1'b1;
          st_d[i].addr   = ev_phys_addr_i[1];
          st_d[i].size   = ev_phys_size_i[1];
          st_d[i].be     = lane_be(ev_phys_addr_i[1], ev_phys_size_i[1]);
        end
    end

    // Release committed loads by trans_id, on every commit port —
    // idempotent by-id release, as for stores. A committed load can no
    // longer be named by the violation CAM (commit already implies the
    // checked verdict), so the entry's lifetime must not depend on the
    // completion event having been captured. Unconditional: not gated
    // on PHYS_VALIDATE (architectural contract, mirrors stores).
    for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ev_commit_ld_i[c] && ld_q[i].valid && ld_q[i].id == ev_commit_id_i[c])
          ld_d[i].valid = 1'b0;

    // Multi-WB complete marks LOADS done; the entry frees only via the
    // release mask once no older store can still resolve against it.
    for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++) begin
      if (ev_complete_valid_i[w] && !ev_complete_is_st_i[w] &&
          !cancelled_mask_i[ev_complete_id_i[w]]) begin
        for (int unsigned i = 0; i < LD_ENTRIES; i++)
          if (ld_q[i].valid && ld_q[i].id == ev_complete_id_i[w])
            ld_d[i].done = 1'b1;
      end
    end

    // Completed-load release — replaces the emit's live st_d unresolved-
    // store scan (now the registered per-load mask in g6lc_lsq_release).
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_release_i[i]) ld_d[i].valid = 1'b0;

    // Release committed stores by trans_id, on every commit port —
    // idempotent by-id release, as the emit.
    for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++) begin
      if (ev_commit_st_i[c]) begin
        for (int unsigned i = 0; i < ST_ENTRIES; i++)
          if (st_q[i].valid && st_q[i].id == ev_commit_id_i[c])
            st_d[i].valid = 1'b0;
      end
    end
`else
    // hyp8 T1 item 14: parallel arms. Alloc and the event/commit hits
    // are disjoint by construction (events/commit require st_q.valid,
    // alloc requires !valid), so per entry each field takes exactly one
    // precomputed value; the write-order equivalents are:
    //   alloc → addr event → data event → phys → commit_ld → done →
    //   release → commit_st → kill → flush.
    for (int unsigned p = 0; p < NR_ALLOC; p++) begin
      ld_alloc_v_o[p]   = ld_alloc_i[p] && (|ld_oh[p]);
      ld_alloc_idx_o[p] = '0;
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ld_oh[p][i]) ld_alloc_idx_o[p] = $clog2(LD_ENTRIES)'(i);
    end
    for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
      if (ld_alloc_any[i]) begin
        ld_d[i].valid  = 1'b1;
        ld_d[i].addr_v = 1'b0;
        ld_d[i].done   = 1'b0;
        ld_d[i].id     = ld_alloc_id_sel[i];
        ld_d[i].hart   = ld_alloc_h_sel[i];
        ld_d[i].addr   = '0;
        ld_d[i].size   = '0;
        ld_d[i].be     = '0;
        ld_d[i].pc     = ld_alloc_pc_sel[i];
      end
    end
    for (int unsigned i = 0; i < ST_ENTRIES; i++) begin
      if (st_alloc_any[i]) begin
        st_d[i].valid  = 1'b1;
        st_d[i].addr_v = 1'b0;
        st_d[i].data_v = 1'b0;
        st_d[i].id     = st_alloc_id_sel[i];
        st_d[i].hart   = st_alloc_h_sel[i];
        st_d[i].addr   = '0;
        st_d[i].data   = '0;
        st_d[i].size   = 2'b10;
        st_d[i].be     = '0;
      end
    end

    // Staged AGU address / data events (PHYS_VALIDATE folds this path).
    for (int unsigned i = 0; i < ST_ENTRIES; i++) begin
      if (st_ahit[i]) begin
        st_d[i].addr_v = 1'b1;
        st_d[i].addr   = ev_addr_i[st_au[i]];
        st_d[i].size   = ev_addr_size_i[st_au[i]];
        st_d[i].be     = ev_addr_be_i[st_au[i]];
      end
      if (st_dhit[i]) begin
        st_d[i].data_v = 1'b1;
        st_d[i].data   = ev_data_i[st_du[i]];
      end
    end
    for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
      if (ld_ahit[i]) begin
        ld_d[i].addr_v = 1'b1;
        ld_d[i].addr   = ev_addr_i[ld_au[i]];
        ld_d[i].size   = ev_addr_size_i[ld_au[i]];
        ld_d[i].be     = ev_addr_be_i[ld_au[i]];
      end
    end

    // PHYS_VALIDATE updates from the staged phys records.
    if (PHYS_VALIDATE) begin
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ld_phit[i]) begin
          ld_d[i].addr_v = 1'b1;
          ld_d[i].addr   = ev_phys_addr_i[0];
          ld_d[i].size   = ev_phys_size_i[0];
          ld_d[i].be     = lane_be(ev_phys_addr_i[0], ev_phys_size_i[0]);
        end
      for (int unsigned i = 0; i < ST_ENTRIES; i++)
        if (st_phit[i]) begin
          st_d[i].addr_v = 1'b1;
          st_d[i].addr   = ev_phys_addr_i[1];
          st_d[i].size   = ev_phys_size_i[1];
          st_d[i].be     = lane_be(ev_phys_addr_i[1], ev_phys_size_i[1]);
        end
    end

    // Commit release (loads and stores), complete marks, ld_release.
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_cmt[i]) ld_d[i].valid = 1'b0;
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_cpl[i]) ld_d[i].done = 1'b1;
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_release_i[i]) ld_d[i].valid = 1'b0;
    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      if (st_cmt[i]) st_d[i].valid = 1'b0;
`endif

    // Drop cancelled younger memory ops (tid == SB slot).
    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      if (st_d[i].valid && cancelled_mask_i[st_d[i].id]) st_d[i].valid = 1'b0;
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_d[i].valid && cancelled_mask_i[ld_d[i].id]) ld_d[i].valid = 1'b0;

    // Flush clears the speculative arrays only (H7: LSU tombstones and
    // committed-store state are owned by store_buffer/wbuffer, not here).
    if (flush_i) begin
      st_d = '0;
      ld_d = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q <= '0;
      ld_q <= '0;
    end else begin
      st_q <= st_d;
      ld_q <= ld_d;
    end
  end

  //pragma translate_off
  // Store release is a staged contract: commit_st registers into
  // ev_commit_* (g6lc_lsq_event) one edge after the scoreboard clears
  // sb_live, and the by-id entry release applies at the following edge.
  // A store entry may therefore be valid with sb_live==0 for exactly
  // one cycle, the cycle its release is pending.  rel_pend_st names
  // that pending release; dead_st_* shadow the dead-entry facts into
  // real flops so the assertions hold under either IEEE preponed or
  // this simulator's post-edge sampling (same repair as store_buffer).
  logic [ST_ENTRIES-1:0] rel_pend_st;
  always_comb begin
    rel_pend_st = '0;
    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
        if (ev_commit_st_i[c] && ev_commit_id_i[c] == st_q[i].id)
          rel_pend_st[i] = 1'b1;
  end

  logic [ST_ENTRIES-1:0]                                dead_st_v_d, dead_st_v_q;
  logic [ST_ENTRIES-1:0][G6LCCfg.TRANS_ID_BITS-1:0]   dead_st_id_d, dead_st_id_q;
  always_comb begin
    for (int unsigned i = 0; i < ST_ENTRIES; i++) begin
      dead_st_v_d[i]  = st_q[i].valid && !sb_live_i[st_q[i].id];
      dead_st_id_d[i] = st_q[i].id;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dead_st_v_q  <= '0;
      dead_st_id_q <= '0;
    end else begin
      dead_st_v_q  <= dead_st_v_d;
      dead_st_id_q <= dead_st_id_d;
    end
  end

  for (genvar i = 0; i < ST_ENTRIES; i++) begin : gen_st_live_assert
    // A valid entry whose tid is dead must have its by-id release pending
    // this cycle (it clears at this edge).
    ooo_lsq_st_live: assert property (@(posedge clk_i) disable iff (!rst_ni)
        st_q[i].valid && !sb_live_i[st_q[i].id] |-> rel_pend_st[i]);
    // ...and it must be gone (or re-tagged) at the next edge.
    ooo_lsq_st_stale_one_cycle: assert property (@(posedge clk_i) disable iff (!rst_ni)
        dead_st_v_q[i] |-> !st_q[i].valid || st_q[i].id != dead_st_id_q[i]);
  end
  // Load release now has the same staged contract as stores: commit_ld
  // registers into ev_commit_* one edge after the scoreboard clears
  // sb_live, and the unconditional by-id entry release applies at the
  // following edge (or ld_release_i frees the entry earlier when the
  // unres/dwait verdict completes).  A load entry may therefore be
  // valid with sb_live==0 only while a release is pending this cycle.
  // rel_pend_ld names the commit-event release; dead_ld_* shadow the
  // dead-entry facts into real flops (same repair as the store side).
  logic [LD_ENTRIES-1:0] rel_pend_ld;
  always_comb begin
    rel_pend_ld = '0;
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
        if (ev_commit_ld_i[c] && ev_commit_id_i[c] == ld_q[i].id)
          rel_pend_ld[i] = 1'b1;
  end

  logic [LD_ENTRIES-1:0]                              dead_ld_v_d, dead_ld_v_q;
  logic [LD_ENTRIES-1:0][G6LCCfg.TRANS_ID_BITS-1:0]   dead_ld_id_d, dead_ld_id_q;
  always_comb begin
    for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
      dead_ld_v_d[i]  = ld_q[i].valid && !sb_live_i[ld_q[i].id];
      dead_ld_id_d[i] = ld_q[i].id;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dead_ld_v_q  <= '0;
      dead_ld_id_q <= '0;
    end else begin
      dead_ld_v_q  <= dead_ld_v_d;
      dead_ld_id_q <= dead_ld_id_d;
    end
  end

  for (genvar i = 0; i < LD_ENTRIES; i++) begin : gen_ld_live_assert
    ooo_lsq_ld_live: assert property (@(posedge clk_i) disable iff (!rst_ni)
        ld_q[i].valid && !sb_live_i[ld_q[i].id] |->
            (rel_pend_ld[i] || ld_release_i[i]));
    ooo_lsq_ld_stale_one_cycle: assert property (@(posedge clk_i) disable iff (!rst_ni)
        dead_ld_v_q[i] |-> !ld_q[i].valid || ld_q[i].id != dead_ld_id_q[i]);
  end

  // Allocation identity: an allocated tid must not already be held by
  // another valid entry unless that entry is being released this cycle
  // (tid reuse the edge after commit is legal).  A live duplicate would
  // let staged by-id events land on the wrong record.
  logic [NR_ALLOC-1:0] alloc_st_conflict, alloc_ld_conflict;
  always_comb begin
    alloc_st_conflict = '0;
    alloc_ld_conflict = '0;
    for (int unsigned p = 0; p < NR_ALLOC; p++) begin
      for (int unsigned i = 0; i < ST_ENTRIES; i++)
        if (st_q[i].valid && st_q[i].id == alloc_id_i[p] && !rel_pend_st[i])
          alloc_st_conflict[p] = 1'b1;
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ld_q[i].valid && ld_q[i].id == alloc_id_i[p] &&
            !ld_release_i[i] && !rel_pend_ld[i])
          alloc_ld_conflict[p] = 1'b1;
    end
  end
  for (genvar p = 0; p < NR_ALLOC; p++) begin : gen_alloc_id_assert
    ooo_lsq_alloc_st_id_unique: assert property (@(posedge clk_i) disable iff (!rst_ni)
        st_alloc_i[p] |-> !alloc_st_conflict[p]);
    ooo_lsq_alloc_ld_id_unique: assert property (@(posedge clk_i) disable iff (!rst_ni)
        ld_alloc_i[p] |-> !alloc_ld_conflict[p]);
  end

  // hyp8 T1 item 14: whole-next-state shadow — the pre-T1 serial form is
  // recomputed into shadow registers from its own state and compared
  // against the live st_q/ld_q every cycle.
  st_ent_t [ST_ENTRIES-1:0] t1_ref_st_d, t1_ref_st_q;
  ld_ent_t [LD_ENTRIES-1:0] t1_ref_ld_d, t1_ref_ld_q;
  always_comb begin : p_t1_slot_ref
    t1_ref_st_d = t1_ref_st_q;
    t1_ref_ld_d = t1_ref_ld_q;
    for (int unsigned p = 0; p < NR_ALLOC; p++) begin
      if (ld_alloc_i[p]) begin
        for (int unsigned i = 0; i < LD_ENTRIES; i++)
          if (ld_oh[p][i]) begin
            t1_ref_ld_d[i].valid  = 1'b1;
            t1_ref_ld_d[i].addr_v = 1'b0;
            t1_ref_ld_d[i].done   = 1'b0;
            t1_ref_ld_d[i].id     = alloc_id_i[p];
            t1_ref_ld_d[i].hart   = alloc_hart_i[p];
            t1_ref_ld_d[i].addr   = '0;
            t1_ref_ld_d[i].size   = '0;
            t1_ref_ld_d[i].be     = '0;
            t1_ref_ld_d[i].pc     = alloc_pc_i[p];
          end
      end
      if (st_alloc_i[p]) begin
        for (int unsigned i = 0; i < ST_ENTRIES; i++)
          if (st_oh[p][i]) begin
            t1_ref_st_d[i].valid  = 1'b1;
            t1_ref_st_d[i].addr_v = 1'b0;
            t1_ref_st_d[i].data_v = 1'b0;
            t1_ref_st_d[i].id     = alloc_id_i[p];
            t1_ref_st_d[i].hart   = alloc_hart_i[p];
            t1_ref_st_d[i].addr   = '0;
            t1_ref_st_d[i].data   = '0;
            t1_ref_st_d[i].size   = 2'b10;
            t1_ref_st_d[i].be     = '0;
          end
      end
    end
    for (int unsigned u = 0; u < NR_UPDATE; u++) begin
      if (!PHYS_VALIDATE && ev_addr_valid_i[u] &&
          !cancelled_mask_i[ev_addr_id_i[u]]) begin
        if (ev_addr_is_st_i[u]) begin
          for (int unsigned i = 0; i < ST_ENTRIES; i++)
            if (t1_ref_st_q[i].valid &&
                t1_ref_st_q[i].id == ev_addr_id_i[u]) begin
              t1_ref_st_d[i].addr_v = 1'b1;
              t1_ref_st_d[i].addr   = ev_addr_i[u];
              t1_ref_st_d[i].size   = ev_addr_size_i[u];
              t1_ref_st_d[i].be     = ev_addr_be_i[u];
            end
        end else begin
          for (int unsigned i = 0; i < LD_ENTRIES; i++)
            if (t1_ref_ld_q[i].valid &&
                t1_ref_ld_q[i].id == ev_addr_id_i[u]) begin
              t1_ref_ld_d[i].addr_v = 1'b1;
              t1_ref_ld_d[i].addr   = ev_addr_i[u];
              t1_ref_ld_d[i].size   = ev_addr_size_i[u];
              t1_ref_ld_d[i].be     = ev_addr_be_i[u];
            end
        end
      end
      if (ev_data_valid_i[u] && !cancelled_mask_i[ev_data_id_i[u]]) begin
        for (int unsigned i = 0; i < ST_ENTRIES; i++)
          if (t1_ref_st_q[i].valid &&
              t1_ref_st_q[i].id == ev_data_id_i[u]) begin
            t1_ref_st_d[i].data_v = 1'b1;
            t1_ref_st_d[i].data   = ev_data_i[u];
          end
      end
    end
    if (PHYS_VALIDATE) begin
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ev_phys_valid_i[0] && t1_ref_ld_q[i].valid &&
            sb_live_i[t1_ref_ld_q[i].id] &&
            !cancelled_mask_i[ev_phys_id_i[0]] &&
            t1_ref_ld_q[i].id == ev_phys_id_i[0] &&
            t1_ref_ld_q[i].hart == ev_phys_hart_i[0]) begin
          t1_ref_ld_d[i].addr_v = 1'b1;
          t1_ref_ld_d[i].addr   = ev_phys_addr_i[0];
          t1_ref_ld_d[i].size   = ev_phys_size_i[0];
          t1_ref_ld_d[i].be     = lane_be(ev_phys_addr_i[0],
                                        ev_phys_size_i[0]);
        end
      for (int unsigned i = 0; i < ST_ENTRIES; i++)
        if (ev_phys_valid_i[1] && t1_ref_st_q[i].valid &&
            sb_live_i[t1_ref_st_q[i].id] &&
            !cancelled_mask_i[ev_phys_id_i[1]] &&
            t1_ref_st_q[i].id == ev_phys_id_i[1] &&
            t1_ref_st_q[i].hart == ev_phys_hart_i[1]) begin
          t1_ref_st_d[i].addr_v = 1'b1;
          t1_ref_st_d[i].addr   = ev_phys_addr_i[1];
          t1_ref_st_d[i].size   = ev_phys_size_i[1];
          t1_ref_st_d[i].be     = lane_be(ev_phys_addr_i[1],
                                        ev_phys_size_i[1]);
        end
    end
    for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
      for (int unsigned i = 0; i < LD_ENTRIES; i++)
        if (ev_commit_ld_i[c] && t1_ref_ld_q[i].valid &&
            t1_ref_ld_q[i].id == ev_commit_id_i[c])
          t1_ref_ld_d[i].valid = 1'b0;
    for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++) begin
      if (ev_complete_valid_i[w] && !ev_complete_is_st_i[w] &&
          !cancelled_mask_i[ev_complete_id_i[w]])
        for (int unsigned i = 0; i < LD_ENTRIES; i++)
          if (t1_ref_ld_q[i].valid &&
              t1_ref_ld_q[i].id == ev_complete_id_i[w])
            t1_ref_ld_d[i].done = 1'b1;
    end
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (ld_release_i[i]) t1_ref_ld_d[i].valid = 1'b0;
    for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
      if (ev_commit_st_i[c])
        for (int unsigned i = 0; i < ST_ENTRIES; i++)
          if (t1_ref_st_q[i].valid &&
              t1_ref_st_q[i].id == ev_commit_id_i[c])
            t1_ref_st_d[i].valid = 1'b0;
    for (int unsigned i = 0; i < ST_ENTRIES; i++)
      if (t1_ref_st_d[i].valid && cancelled_mask_i[t1_ref_st_d[i].id])
        t1_ref_st_d[i].valid = 1'b0;
    for (int unsigned i = 0; i < LD_ENTRIES; i++)
      if (t1_ref_ld_d[i].valid && cancelled_mask_i[t1_ref_ld_d[i].id])
        t1_ref_ld_d[i].valid = 1'b0;
    if (flush_i) begin
      t1_ref_st_d = '0;
      t1_ref_ld_d = '0;
    end
  end
  int unsigned t1_slot_n = 0;
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_t1_slot_eq
    if (!rst_ni) begin
      t1_ref_st_q <= '0;
      t1_ref_ld_q <= '0;
      t1_slot_n   <= 0;
    end else begin
      t1_ref_st_q <= t1_ref_st_d;
      t1_ref_ld_q <= t1_ref_ld_d;
      if (!$isunknown({st_q, ld_q})) begin
        t1_slot_n <= t1_slot_n + 1;
        g6lc_t1_slot_eq: assert (st_q === t1_ref_st_q &&
                                 ld_q === t1_ref_ld_q)
          else $error("g6lc_lsq_slot: equiv arms");
      end
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_lsq_slot arms: checked=%0d", t1_slot_n);
  end
  //pragma translate_on

endmodule
