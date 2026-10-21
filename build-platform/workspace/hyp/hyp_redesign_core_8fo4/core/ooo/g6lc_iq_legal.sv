// hyp8 provenance: REWRITTEN (registered issue legality)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_iq_legal -- per-entry legality bits for the banked issue queue,
// recomputed from REGISTERED events only (analysis/g6lc_iq.md, contract
// A132): a bit may stay 0 a cycle longer, never 1 too early.
//
// The unbanked IQ folded four ordering predicates into the select cone:
//   * N1d: CSR ops issue strictly in IQ age order;
//   * T24: stores issue in age order among stores;
//   * head-only classes: CVXIF, fence/system-CSR ops and AMOs issue only
//     when their tid sits at commit_ptr (the scoreboard head);
//   * loads wait on older UNRESOLVED stores (st_unresolved_mask + hart mask)
//     unless the dispatch-time predictor marked may_bypass; mem_stall_i
//     gates loads as well.
// Here each is a registered bit:
//   - class frontiers (oldest live CSR tid / oldest live store tid across
//     all banks) are merged from the banks' reports and registered -- a
//     store/CSR issue or removal moves the frontier one cycle later, so a
//     younger same-class entry can only wait LONGER, never fire early;
//   - at_head (tid == commit_ptr) is a registered per-entry compare, so a
//     head-class op becomes legal the cycle AFTER it reaches the head;
//   - older_unres (any unresolved older store) is a registered per-entry
//     mask scan, so a resolving store frees the load a cycle late;
//   - mem_stall is registered the same way.
// A newly allocated entry reads legal=0 until its first update -- it could
// not have been a candidate that cycle anyway (its rdy path registers too).

module g6lc_iq_legal
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned BANKS   = 8,
    parameter int unsigned ENTRIES = 4,
    parameter int unsigned TID_W   = 5,
    parameter int unsigned HID_W   = 1,
    parameter int unsigned NH      = 1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // Per-entry info from the banks.
    input  logic [BANKS-1:0][ENTRIES-1:0]           info_v_i,
    input  logic [BANKS-1:0][ENTRIES-1:0][TID_W-1:0] info_tid_i,
    input  logic [BANKS-1:0][ENTRIES-1:0][HID_W-1:0] info_hart_i,
    input  logic [BANKS-1:0][ENTRIES-1:0][6:0]      info_cls_i,
    input  logic [BANKS-1:0][ENTRIES-1:0]           info_bypass_i,
    // Bank-local class frontiers.
    input  logic [BANKS-1:0]                        csr_oldest_v_i,
    input  logic [BANKS-1:0][TID_W-1:0]             csr_oldest_tid_i,
    input  logic [BANKS-1:0]                        st_oldest_v_i,
    input  logic [BANKS-1:0][TID_W-1:0]             st_oldest_tid_i,
    // Registered ordering events.
    input  logic [TID_W-1:0]                        commit_ptr_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]        st_unresolved_mask_i,
    input  logic [NH-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] st_hart_mask_i,
    input  logic                                    mem_stall_i,
    // Registered legality, per bank per entry.
    output logic [BANKS-1:0][ENTRIES-1:0]           legal_o
);

  localparam int unsigned C_LD = 0, C_ST = 1, C_CSR = 2, C_CSYS = 3,
                          C_AMO = 4, C_CVXI = 5, C_FP = 6;

  // ----------------------------------------------------------------------
  // Registered global facts
  // ----------------------------------------------------------------------
  // Class frontiers: oldest CSR / store tid across banks, merged by the
  // circular age key and registered.
  logic             csr_front_v_q, st_front_v_q;
  logic [TID_W-1:0] csr_front_tid_q, st_front_tid_q;
  logic             csr_front_v_d, st_front_v_d;
  logic [TID_W-1:0] csr_front_tid_d, st_front_tid_d;
  logic             mem_stall_q;
  logic [TID_W-1:0] commit_ptr_q;

  always_comb begin
    csr_front_v_d = 1'b0;
    csr_front_tid_d = '0;
    st_front_v_d = 1'b0;
    st_front_tid_d = '0;
    for (int unsigned b = 0; b < BANKS; b++) begin
      if (csr_oldest_v_i[b] &&
          !(csr_front_v_d &&
            ooo_age_older(TID_W, 32'(csr_front_tid_d),
                          32'(csr_oldest_tid_i[b]), 32'(commit_ptr_i)))) begin
        csr_front_v_d   = 1'b1;
        csr_front_tid_d = csr_oldest_tid_i[b];
      end
      if (st_oldest_v_i[b] &&
          !(st_front_v_d &&
            ooo_age_older(TID_W, 32'(st_front_tid_d),
                          32'(st_oldest_tid_i[b]), 32'(commit_ptr_i)))) begin
        st_front_v_d   = 1'b1;
        st_front_tid_d = st_oldest_tid_i[b];
      end
    end
  end

  // Per-entry registered facts: at_head, older-unresolved-store.
  logic [BANKS-1:0][ENTRIES-1:0] at_head_q, unres_q;

  logic [BANKS-1:0][ENTRIES-1:0] at_head_d, unres_d;
  always_comb begin
    for (int unsigned b = 0; b < BANKS; b++) begin
      for (int unsigned e = 0; e < ENTRIES; e++) begin
        automatic logic [HID_W-1:0] h;
        automatic logic             ou;
        h = info_hart_i[b][e];
        at_head_d[b][e] = (info_tid_i[b][e] == commit_ptr_i);
        ou = 1'b0;
        for (int unsigned s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin
          if (st_unresolved_mask_i[s] &&
              (NH <= 1 || st_hart_mask_i[h][s]) &&
              ooo_age_older(TID_W, 32'(s), 32'(info_tid_i[b][e]),
                            32'(commit_ptr_i)))
            ou = 1'b1;
        end
        unres_d[b][e] = ou;
      end
    end
  end

  // ----------------------------------------------------------------------
  // Registered legality per entry.
  // ----------------------------------------------------------------------
  logic [BANKS-1:0][ENTRIES-1:0] legal_d;

  always_comb begin
    for (int unsigned b = 0; b < BANKS; b++) begin
      for (int unsigned e = 0; e < ENTRIES; e++) begin
        automatic logic head_only, is_ld, is_csr, is_st;
        automatic logic older_csr, older_st;
        head_only = info_cls_i[b][e][C_CVXI] | info_cls_i[b][e][C_AMO] |
                    info_cls_i[b][e][C_CSYS];
        is_ld  = info_cls_i[b][e][C_LD];
        is_csr = info_cls_i[b][e][C_CSR];
        is_st  = info_cls_i[b][e][C_ST];
        // N1d / T24 via the registered class frontier: an entry of the
        // class is legal only when the frontier IS its own tid.
        older_csr = csr_front_v_q && (csr_front_tid_q != info_tid_i[b][e]);
        older_st  = st_front_v_q  && (st_front_tid_q  != info_tid_i[b][e]);
        legal_d[b][e] =
            !(head_only && !at_head_q[b][e]) &&
            !(is_ld && (mem_stall_q ||
                        (unres_q[b][e] && !info_bypass_i[b][e]))) &&
            !(is_csr && older_csr) &&
            !(is_st && older_st);
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      legal_o <= '0;
      at_head_q <= '0;
      unres_q <= '0;
      csr_front_v_q <= 1'b0;
      csr_front_tid_q <= '0;
      st_front_v_q <= 1'b0;
      st_front_tid_q <= '0;
      mem_stall_q <= 1'b0;
      commit_ptr_q <= '0;
    end else if (flush_i) begin
      legal_o <= '0;
      at_head_q <= '0;
      unres_q <= '0;
      csr_front_v_q <= 1'b0;
      st_front_v_q <= 1'b0;
      mem_stall_q <= 1'b0;
    end else begin
      legal_o <= legal_d;
      at_head_q <= at_head_d;
      unres_q <= unres_d;
      csr_front_v_q <= csr_front_v_d;
      csr_front_tid_q <= csr_front_tid_d;
      st_front_v_q <= st_front_v_d;
      st_front_tid_q <= st_front_tid_d;
      mem_stall_q <= mem_stall_i;
      commit_ptr_q <= commit_ptr_i;
    end
  end

endmodule
