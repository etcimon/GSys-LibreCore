// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq_release — hyp8 LSQ completed-load release + checked tracking.
//
// Replaces the emit's live `st_d` unresolved-older-store scan with two
// REGISTERED per-load masks, keyed by store transaction id:
//
//   unres_q[i][tid] — older same-hart stores whose address had not
//     resolved when load entry i was allocated.  Set at allocation from
//     the wrapper's hart-filtered st_unresolved mask plus same-cycle
//     older store allocations; a bit clears when the named store's
//     address resolves (staged addr/phys event), the store commits, the
//     tid is cancelled, or the pipe flushes.  Bits can never be set for
//     stores younger than the load: the mask is a snapshot at alloc.
//   dwait_q[i][tid] — stores that matched the load's STL CAM at verdict
//     time but had no data yet (g6lc_lsq_verdict's registered
//     dwait set).  A bit clears when the named store's data event lands,
//     it commits, the tid is cancelled, or flush.
//
// `unres_empty_o`/`dwait_empty_o` feed the wrapper's `ld_checked_o`
// formation (the checked bit must never assert early — a load may only
// be published once its verdict is final AND no older store can still
// resolve or deliver data against it).
//
// `ld_release_o[i]` frees a completed load's entry once both masks are
// empty.  The emit freed on the unresolved-addr scan alone; gating on
// dwait as well is the conservative hyp8 form — a load whose forward
// data is still in flight keeps its record so the violation CAM can
// still name it (contract §1).
//
// Kill identities (contract §3): masks clear per cancelled tid, and the
// whole module clears on flush_i.

module g6lc_lsq_release #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned LD_ENTRIES = 8,
    parameter int unsigned NR_ALLOC   = 2,
    parameter int unsigned NLD        = 3
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,

    // Registered load entry state (from g6lc_lsq_slot).
    input  logic [LD_ENTRIES-1:0]                          ld_valid_i,
    input  logic [LD_ENTRIES-1:0]                          ld_done_i,
    input  logic [LD_ENTRIES-1:0][G6LCCfg.TRANS_ID_BITS-1:0] ld_id_i,

    // Allocation: which entries fire this cycle and their older-store
    // snapshot (hart-filtered unresolved mask + same-cycle older allocs).
    input  logic [NR_ALLOC-1:0]                            ld_alloc_v_i,
    input  logic [NR_ALLOC-1:0][$clog2(LD_ENTRIES)-1:0]    ld_alloc_idx_i,
    input  logic [NR_ALLOC-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] alloc_older_i,

    // Per-tid resolution events (formed in the wrapper from the staged
    // records): store address resolved / store data landed.
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]               st_resolved_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]               st_data_res_i,

    // Registered verdict data-wait sets (one per load verdict event).
    input  logic [NLD-1:0]                                 vld_dwait_v_i,
    input  logic [NLD-1:0][G6LCCfg.TRANS_ID_BITS-1:0]      vld_dwait_id_i,
    input  logic [NLD-1:0][G6LCCfg.NR_SB_ENTRIES-1:0]      vld_dwait_i,

    output logic [LD_ENTRIES-1:0]                          unres_empty_o,
    output logic [LD_ENTRIES-1:0]                          dwait_empty_o,
    output logic [LD_ENTRIES-1:0]                          ld_release_o
);

  logic [LD_ENTRIES-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] unres_q, dwait_q;

  always_comb begin
    for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
      unres_empty_o[i] = (unres_q[i] == '0);
      dwait_empty_o[i] = (dwait_q[i] == '0);
      ld_release_o[i]  = ld_valid_i[i] && ld_done_i[i] &&
                         unres_empty_o[i] && dwait_empty_o[i];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      unres_q <= '0;
      dwait_q <= '0;
    end else if (flush_i) begin
      unres_q <= '0;
      dwait_q <= '0;
    end else begin
      for (int unsigned i = 0; i < LD_ENTRIES; i++) begin
        // Per-bit clears: a store's resolution, a tid's cancellation,
        // or the entry itself dying frees the bit.
        unres_q[i] <= unres_q[i] & ~st_resolved_i & ~cancelled_mask_i;
        dwait_q[i] <= dwait_q[i] & ~st_data_res_i & ~cancelled_mask_i;
        if (!ld_valid_i[i] || cancelled_mask_i[ld_id_i[i]]) begin
          unres_q[i] <= '0;
          dwait_q[i] <= '0;
        end
        // Verdict-driven data-wait set (entry found by transaction id).
        for (int unsigned v = 0; v < NLD; v++) begin
          if (vld_dwait_v_i[v] && ld_valid_i[i] &&
              ld_id_i[i] == vld_dwait_id_i[v]) begin
            dwait_q[i] <= (dwait_q[i] & ~st_data_res_i &
                           ~cancelled_mask_i) | vld_dwait_i[v];
          end
        end
        // Allocation snapshot (overrides — the entry starts clean).
        for (int unsigned p = 0; p < NR_ALLOC; p++) begin
          if (ld_alloc_v_i[p] && ld_alloc_idx_i[p] == $clog2(LD_ENTRIES)'(i)) begin
            unres_q[i] <= alloc_older_i[p] & ~st_resolved_i &
                          ~cancelled_mask_i;
            dwait_q[i] <= '0;
          end
        end
      end
    end
  end

endmodule
