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
    output logic [NR_ALLOC-1:0][$clog2(LD_ENTRIES)-1:0]   ld_alloc_idx_o
);

  localparam int unsigned HID_W =
      $clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2);
  localparam bit PHYS_VALIDATE = G6LCCfg.CohPolicy == config_pkg::COH_OOO;

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
          ld_pool &= ~ld_oh[q];
          st_pool &= ~st_oh[q];
        end
    end
    assign ld_oh[p] = ld_pool & (~ld_pool + {{LD_ENTRIES-1{1'b0}}, 1'b1});
    assign st_oh[p] = st_pool & (~st_pool + {{ST_ENTRIES-1{1'b0}}, 1'b1});
  end

  always_comb begin
    st_d = st_q;
    ld_d = ld_q;
    ld_alloc_v_o   = '0;
    ld_alloc_idx_o = '0;

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
            end
        end else begin
          for (int unsigned i = 0; i < LD_ENTRIES; i++)
            if (ld_q[i].valid && ld_q[i].id == ev_addr_id_i[u]) begin
              ld_d[i].addr_v = 1'b1;
              ld_d[i].addr   = ev_addr_i[u];
              ld_d[i].size   = ev_addr_size_i[u];
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
        end
      for (int unsigned i = 0; i < ST_ENTRIES; i++)
        if (ev_phys_valid_i[1] && st_q[i].valid && sb_live_i[st_q[i].id] &&
            !cancelled_mask_i[ev_phys_id_i[1]] &&
            st_q[i].id == ev_phys_id_i[1] && st_q[i].hart == ev_phys_hart_i[1]) begin
          st_d[i].addr_v = 1'b1;
          st_d[i].addr   = ev_phys_addr_i[1];
          st_d[i].size   = ev_phys_size_i[1];
        end
      for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
        for (int unsigned i = 0; i < LD_ENTRIES; i++)
          if (ev_commit_ld_i[c] && ld_q[i].valid && ld_q[i].id == ev_commit_id_i[c])
            ld_d[i].valid = 1'b0;
    end

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
  for (genvar i = 0; i < ST_ENTRIES; i++) begin : gen_st_live_assert
    ooo_lsq_st_live: assert property (@(posedge clk_i) disable iff (!rst_ni)
        st_q[i].valid |-> sb_live_i[st_q[i].id]);
  end
  for (genvar i = 0; i < LD_ENTRIES; i++) begin : gen_ld_live_assert
    ooo_lsq_ld_live: assert property (@(posedge clk_i) disable iff (!rst_ni)
        ld_q[i].valid |-> sb_live_i[ld_q[i].id]);
  end
  //pragma translate_on

endmodule
