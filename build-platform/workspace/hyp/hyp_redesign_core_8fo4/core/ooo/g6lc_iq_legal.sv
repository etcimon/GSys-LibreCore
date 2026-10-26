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
//
// r68 occupant identity (the D1 owner of the r62 kernel LR/SC wedge and
// the r67 smoke regression): every registered fact here is honoured only
// for the occupant it was computed for. Before r68, legal_d read the
// entry's STALE record in the cycle before a new occupant landed (an
// invalid entry with a non-ordering stale class, e.g. every entry after
// reset/flush with cls=0) and produced legal_o=1 for the new occupant's
// first cycle. A head-only op (AMO/LR/SC, system CSR, CVXIF) whose
// operands were ready at dispatch was therefore a candidate one cycle
// after allocation regardless of commit_ptr: the younger lr.d/sc.d of the
// Linux spin loop issued non-head, the younger LR opened the IRO's
// lr_sc_pair window keyed to itself, and the head LR was refused for
// ever (r37p: tids 5/7 issued at 21,945,784/790 while commit_ptr=3).
// The same stale cycle let a fresh load skip the older-unresolved-store
// check and a fresh CSR/store skip its N1d/T24 frontier.
// Contract restored:
//   * per-entry facts (at_head, older-unresolved) are computed from the
//     bank's NEXT-state tid (info_tid_d_i), so at the first cycle the new
//     occupant is live its registered facts already belong to it;
//   * cross-entry facts (the class frontiers) are computed from the live
//     records one cycle later, so a frontier-gated class (CSR/store) is
//     legal only once the entry has been live for a full cycle (warm);
//   * an entry that is not live is never legal (legal_d &= info_v_i).
// Classes without an ordering rule are not read through this module at
// all (g6lc_iq_bank `ord`), so their dispatch->issue distance is
// unchanged; head-only and load legality keep their intended distance;
// CSR/store legality moves one cycle later at allocation only.

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
    // r68: the bank's next-state tid (the occupant the entry holds at the
    // NEXT edge). Per-entry facts register against it so they already
    // describe a newly landed occupant in its first live cycle.
    input  logic [BANKS-1:0][ENTRIES-1:0][TID_W-1:0] info_tid_d_i,
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
  // One frontier per hart. Hart 0's oldest store does not hold hart 1's
  // store, and the same for CSRs. NH==1 keeps the bank-merged frontier.
  logic [NH-1:0]             csr_front_v_q, st_front_v_q;
  logic [NH-1:0][TID_W-1:0]  csr_front_tid_q, st_front_tid_q;
  logic [NH-1:0]             csr_front_v_d, st_front_v_d;
  logic [NH-1:0][TID_W-1:0]  csr_front_tid_d, st_front_tid_d;
  logic             mem_stall_q;
  logic [TID_W-1:0] commit_ptr_q;

`ifndef G6LC_MUT_T1_IQLEG
  // hyp8 T1 item 15: the class frontier is the unique live bank whose
  // tid is not older-than-edged by any other live bank — computed from
  // the pairwise age matrix and a one-hot gather instead of the serial
  // keep/override chain. Tids are unique, so csr_win/st_win are
  // one-hot0 (asserted below).
  logic [BANKS-1:0][BANKS-1:0] csr_oldm, st_oldm;
  logic [BANKS-1:0]            csr_win, st_win;
  for (genvar b = 0; b < BANKS; b++) begin : gen_fm
    logic [BANKS-1:0] cl, sl;
    for (genvar bb = 0; bb < BANKS; bb++) begin : gen_fmm
      assign csr_oldm[b][bb] = csr_oldest_v_i[b] && csr_oldest_v_i[bb] &&
          ooo_age_older(TID_W, 32'(csr_oldest_tid_i[bb]),
                        32'(csr_oldest_tid_i[b]), 32'(commit_ptr_i));
      assign st_oldm[b][bb]  = st_oldest_v_i[b] && st_oldest_v_i[bb] &&
          ooo_age_older(TID_W, 32'(st_oldest_tid_i[bb]),
                        32'(st_oldest_tid_i[b]), 32'(commit_ptr_i));
      assign cl[bb] = csr_oldm[b][bb];
      assign sl[bb] = st_oldm[b][bb];
    end
    assign csr_win[b] = csr_oldest_v_i[b] && !(|cl);
    assign st_win[b]  = st_oldest_v_i[b]  && !(|sl);
  end
  // hyp8 T1 item 15 (NH>1 arm): the per-hart frontier is the unique live
  // entry with no older same-hart classmate — a pairwise win matrix plus
  // a one-hot tid gather, instead of the serial BANKS*ENTRIES keep/
  // override scan. Tids are unique so cwin/swin are one-hot0 per hart.
  logic [NH-1:0]            fh_csr_v, fh_st_v;
  logic [NH-1:0][TID_W-1:0] fh_csr_tid, fh_st_tid;
  if (NH > 1) begin : gen_fh
    localparam int unsigned NBE = BANKS * ENTRIES;
    logic [NBE-1:0][TID_W-1:0]  k_tid;
    logic [NBE-1:0][HID_W-1:0]  k_h;
    logic [NBE-1:0]             k_v, k_csr, k_st;
    logic [NH-1:0][NBE-1:0]     cwin, swin;
    for (genvar b = 0; b < BANKS; b++) begin : gen_fk_b
      for (genvar e = 0; e < ENTRIES; e++) begin : gen_fk_e
        assign k_v[b*ENTRIES+e]   = info_v_i[b][e];
        assign k_tid[b*ENTRIES+e] = info_tid_i[b][e];
        assign k_h[b*ENTRIES+e]   = info_hart_i[b][e];
        assign k_csr[b*ENTRIES+e] = info_cls_i[b][e][C_CSR];
        assign k_st[b*ENTRIES+e]  = info_cls_i[b][e][C_ST];
      end
    end
    for (genvar h = 0; h < NH; h++) begin : gen_fhw_h
      for (genvar k = 0; k < NBE; k++) begin : gen_fhw_k
        logic [NBE-1:0] colder, solder;
        for (genvar kk = 0; kk < NBE; kk++) begin : gen_fhw_kk
          assign colder[kk] = k_v[kk] && k_csr[kk] &&
              (k_h[kk] == HID_W'(h)) &&
              ooo_age_older(TID_W, 32'(k_tid[kk]), 32'(k_tid[k]),
                            32'(commit_ptr_i));
          assign solder[kk] = k_v[kk] && k_st[kk] &&
              (k_h[kk] == HID_W'(h)) &&
              ooo_age_older(TID_W, 32'(k_tid[kk]), 32'(k_tid[k]),
                            32'(commit_ptr_i));
        end
        assign cwin[h][k] = k_v[k] && k_csr[k] && (k_h[k] == HID_W'(h)) &&
                            !(|colder);
        assign swin[h][k] = k_v[k] && k_st[k] && (k_h[k] == HID_W'(h)) &&
                            !(|solder);
      end
      // r68b: the per-hart tid gather as a balanced masked-OR tree
      // (log2(NBE) levels) instead of the NBE-deep serial `|=` chain --
      // the module's billed into->out limiter (analyze-r68 :179 21.85).
      // cwin/swin are one-hot0 per hart, so the gather is exact.
      localparam int unsigned GLV = (NBE > 1) ? $clog2(NBE) : 1;
      logic [GLV:0][NBE-1:0][TID_W-1:0] cgt, sgt;
      for (genvar k = 0; k < NBE; k++) begin : gen_g0
        assign cgt[0][k] = {TID_W{cwin[h][k]}} & k_tid[k];
        assign sgt[0][k] = {TID_W{swin[h][k]}} & k_tid[k];
      end
      for (genvar l = 0; l < GLV; l++) begin : gen_gl
        for (genvar t = 0; t < NBE; t++) begin : gen_gt
          if (t < ((NBE + (1 << l) - 1) >> (l + 1))) begin : gen_in
            if ((2 * t + 1) < ((NBE + (1 << l) - 1) >> l)) begin : gen_pair
              assign cgt[l+1][t] = cgt[l][2*t] | cgt[l][2*t+1];
              assign sgt[l+1][t] = sgt[l][2*t] | sgt[l][2*t+1];
            end else begin : gen_odd
              assign cgt[l+1][t] = cgt[l][2*t];
              assign sgt[l+1][t] = sgt[l][2*t];
            end
          end else begin : gen_pad
            assign cgt[l+1][t] = '0;
            assign sgt[l+1][t] = '0;
          end
        end
      end
      assign fh_csr_v[h]   = |cwin[h];
      assign fh_st_v[h]    = |swin[h];
      assign fh_csr_tid[h] = cgt[GLV][0];
      assign fh_st_tid[h]  = sgt[GLV][0];
    end
  end else begin : gen_fh_off
    assign fh_csr_v   = '0;
    assign fh_st_v    = '0;
    assign fh_csr_tid = '0;
    assign fh_st_tid  = '0;
  end

  // r68b: one-hot masked-OR gathers of the bank frontier tids (balanced).
  logic [BANKS-1:0]            csr_front_tid_gather_v, st_front_tid_gather_v;
  logic [BANKS-1:0][TID_W-1:0] csr_gm, st_gm;
  logic [TID_W-1:0]            csr_front_tid_gather, st_front_tid_gather;
  assign csr_front_tid_gather_v = csr_win;
  assign st_front_tid_gather_v  = st_win;
  for (genvar b = 0; b < BANKS; b++) begin : gen_fgm
    assign csr_gm[b] = {TID_W{csr_win[b]}} & csr_oldest_tid_i[b];
    assign st_gm[b]  = {TID_W{st_win[b]}}  & st_oldest_tid_i[b];
  end
  always_comb begin
    csr_front_tid_gather = '0;
    st_front_tid_gather  = '0;
    for (int unsigned b = 0; b < BANKS; b++) begin
      csr_front_tid_gather |= csr_gm[b];
      st_front_tid_gather  |= st_gm[b];
    end
  end

  always_comb begin
    csr_front_v_d = '0;
    csr_front_tid_d = '0;
    st_front_v_d = '0;
    st_front_tid_d = '0;
    if (NH <= 1) begin
      csr_front_v_d[0] = |csr_front_tid_gather_v;
      st_front_v_d[0]  = |st_front_tid_gather_v;
      // r68b: csr_win/st_win are one-hot0 (asserted below), so the serial
      // last-wins `if` chain over BANKS arms is a masked-OR gather: one AND
      // level and a log2(BANKS) OR tree instead of a BANKS-deep priority
      // mux (the module's into->out limiter, analyze-r68 :179 21.85).
      csr_front_tid_d[0] = csr_front_tid_gather;
      st_front_tid_d[0]  = st_front_tid_gather;
    end else begin
      csr_front_v_d   = fh_csr_v;
      csr_front_tid_d = fh_csr_tid;
      st_front_v_d    = fh_st_v;
      st_front_tid_d  = fh_st_tid;
    end
  end
`else
  always_comb begin
    csr_front_v_d = '0;
    csr_front_tid_d = '0;
    st_front_v_d = '0;
    st_front_tid_d = '0;
    if (NH <= 1) begin
      for (int unsigned b = 0; b < BANKS; b++) begin
        if (csr_oldest_v_i[b] &&
            !(csr_front_v_d[0] &&
              ooo_age_older(TID_W, 32'(csr_front_tid_d[0]),
                            32'(csr_oldest_tid_i[b]), 32'(commit_ptr_i)))) begin
          csr_front_v_d[0]   = 1'b1;
          csr_front_tid_d[0] = csr_oldest_tid_i[b];
        end
        if (st_oldest_v_i[b] &&
            !(st_front_v_d[0] &&
              ooo_age_older(TID_W, 32'(st_front_tid_d[0]),
                            32'(st_oldest_tid_i[b]), 32'(commit_ptr_i)))) begin
          st_front_v_d[0]   = 1'b1;
          st_front_tid_d[0] = st_oldest_tid_i[b];
        end
      end
    end else begin
      for (int unsigned b = 0; b < BANKS; b++) begin
        for (int unsigned e = 0; e < ENTRIES; e++) begin
          if (info_v_i[b][e] && info_cls_i[b][e][C_CSR]) begin
            automatic logic [HID_W-1:0] h;
            h = info_hart_i[b][e];
            if (!csr_front_v_d[h] ||
                ooo_age_older(TID_W, 32'(info_tid_i[b][e]),
                              32'(csr_front_tid_d[h]), 32'(commit_ptr_i))) begin
              csr_front_v_d[h]   = 1'b1;
              csr_front_tid_d[h] = info_tid_i[b][e];
            end
          end
          if (info_v_i[b][e] && info_cls_i[b][e][C_ST]) begin
            automatic logic [HID_W-1:0] h;
            h = info_hart_i[b][e];
            if (!st_front_v_d[h] ||
                ooo_age_older(TID_W, 32'(info_tid_i[b][e]),
                              32'(st_front_tid_d[h]), 32'(commit_ptr_i))) begin
              st_front_v_d[h]   = 1'b1;
              st_front_tid_d[h] = info_tid_i[b][e];
            end
          end
        end
      end
    end
  end
`endif

  // Per-entry registered facts: at_head, older-unresolved-store.
  logic [BANKS-1:0][ENTRIES-1:0] at_head_q, unres_q;

  logic [BANKS-1:0][ENTRIES-1:0] at_head_d, unres_d;
  // r68: the identity the per-entry facts are computed for. The next-state
  // tid is the occupant present at the edge that registers the fact, so a
  // fresh occupant's first live cycle reads facts about itself. The
  // review mutant restores the pre-r68 live-tid source (one cycle stale
  // for a newly landed occupant).
  logic [BANKS-1:0][ENTRIES-1:0][TID_W-1:0] fact_tid;
`ifdef G6LC_MUT_IQLEG_STALE_OCCUPANT
  assign fact_tid = info_tid_i;
`else
  assign fact_tid = info_tid_d_i;
`endif
  // The hart of the next occupant is not exported; a hart change on
  // re-allocation is covered by the NH>1 frontier warm gate and by the
  // conservative direction of the unresolved scan (NH<=1 ignores it).
`ifndef G6LC_MUT_T1_IQLEG
  // hyp8 T1 item 15: the unresolved-older-store scan as a flat AND-OR
  // per entry — same predicate set, one reduce instead of the serial
  // NR_SB-deep accumulate.
  for (genvar b = 0; b < BANKS; b++) begin : gen_unres_b
    for (genvar e = 0; e < ENTRIES; e++) begin : gen_unres_e
      logic [G6LCCfg.NR_SB_ENTRIES-1:0] uvec;
      for (genvar s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin : gen_us
        assign uvec[s] = st_unresolved_mask_i[s] &&
            (NH <= 1 || st_hart_mask_i[info_hart_i[b][e]][s]) &&
            ooo_age_older(TID_W, 32'(s), 32'(fact_tid[b][e]),
                          32'(commit_ptr_i));
      end
      assign unres_d[b][e] = |uvec;
    end
  end
`endif
  always_comb begin
    for (int unsigned b = 0; b < BANKS; b++) begin
      for (int unsigned e = 0; e < ENTRIES; e++) begin
        automatic logic [HID_W-1:0] h;
        automatic logic             ou;
        h = info_hart_i[b][e];
        at_head_d[b][e] = (fact_tid[b][e] == commit_ptr_i);
`ifdef G6LC_MUT_T1_IQLEG
        // Review mutant: pre-T1 serial accumulate.
        ou = 1'b0;
        for (int unsigned s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin
          if (st_unresolved_mask_i[s] &&
              (NH <= 1 || st_hart_mask_i[h][s]) &&
              ooo_age_older(TID_W, 32'(s), 32'(fact_tid[b][e]),
                            32'(commit_ptr_i)))
            ou = 1'b1;
        end
        unres_d[b][e] = ou;
`endif
      end
    end
  end

  // r68: live-for-a-full-cycle ("warm") per entry -- the frontier facts
  // registered this cycle were computed from last cycle's live records,
  // which include this occupant only if it was already live then.
  logic [BANKS-1:0][ENTRIES-1:0] info_v_q, warm;
  assign warm = info_v_i & info_v_q;

  // ----------------------------------------------------------------------
  // Registered legality per entry.
  // ----------------------------------------------------------------------
  logic [BANKS-1:0][ENTRIES-1:0] legal_d;

  always_comb begin
    for (int unsigned b = 0; b < BANKS; b++) begin
      for (int unsigned e = 0; e < ENTRIES; e++) begin
        automatic logic head_only, is_ld, is_csr, is_st;
        automatic logic older_csr, older_st;
        automatic logic [HID_W-1:0] h;
        head_only = info_cls_i[b][e][C_CVXI] | info_cls_i[b][e][C_AMO] |
                    info_cls_i[b][e][C_CSYS];
        is_ld  = info_cls_i[b][e][C_LD];
        is_csr = info_cls_i[b][e][C_CSR];
        is_st  = info_cls_i[b][e][C_ST];
        h = info_hart_i[b][e];
        // N1d / T24: oldest of THIS hart only. Another hart's store or
        // CSR does not hold this one.
        older_csr = csr_front_v_q[h] && (csr_front_tid_q[h] != info_tid_i[b][e]);
        older_st  = st_front_v_q[h] && (st_front_tid_q[h] != info_tid_i[b][e]);
        // r62b: at_head_q is one cycle staler than the entry's class/tid.
        // When an IQ entry is re-allocated right after its previous
        // occupant (a head-only op) left from the head, the stale bit
        // made the NEW occupant legal for one cycle -- a younger AMO of
        // the kernel spin loop issued non-head, posted into the depth-1
        // amo_buffer and blocked the older head AMO forever (r34q probe:
        // tid-5 push at 21,945,777 while tid 7 was the head). The live
        // tid-vs-registered-pointer compare rejects the stale bit; the
        // "legal the cycle after it reaches the head" contract is kept.
        // r68: at_head_q/unres_q now register against the next-state tid
        // (fact_tid) so they belong to the live occupant; the live compare
        // stays as defence. A non-live entry is never legal, and the
        // frontier-gated classes wait for the warm cycle (see header).
`ifdef G6LC_MUT_IQLEG_STALE_OCCUPANT
        // Review mutant (negative control): the pre-r68 form -- legality
        // computed for whatever record the entry holds, live or not.
        legal_d[b][e] =
            !(head_only && !(at_head_q[b][e] &&
                             (info_tid_i[b][e] == commit_ptr_q))) &&
            !(is_ld && (mem_stall_q ||
                        (unres_q[b][e] && !info_bypass_i[b][e]))) &&
            !(is_csr && older_csr) &&
            !(is_st && older_st);
`else
        legal_d[b][e] = info_v_i[b][e] &&
            !(head_only && !(at_head_q[b][e] &&
                             (info_tid_i[b][e] == commit_ptr_q))) &&
            !(is_ld && (mem_stall_q ||
                        (unres_q[b][e] && !info_bypass_i[b][e]))) &&
            !(is_csr && (!warm[b][e] || older_csr)) &&
            !(is_st && (!warm[b][e] || older_st));
`endif
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      legal_o <= '0;
      at_head_q <= '0;
      unres_q <= '0;
      info_v_q <= '0;
      csr_front_v_q <= '0;
      csr_front_tid_q <= '0;
      st_front_v_q <= '0;
      st_front_tid_q <= '0;
      mem_stall_q <= 1'b0;
      commit_ptr_q <= '0;
    end else if (flush_i) begin
      legal_o <= '0;
      at_head_q <= '0;
      unres_q <= '0;
      info_v_q <= '0;
      csr_front_v_q <= '0;
      st_front_v_q <= 1'b0;
      mem_stall_q <= 1'b0;
    end else begin
      legal_o <= legal_d;
      at_head_q <= at_head_d;
      unres_q <= unres_d;
      info_v_q <= info_v_i;
      csr_front_v_q <= csr_front_v_d;
      csr_front_tid_q <= csr_front_tid_d;
      st_front_v_q <= st_front_v_d;
      st_front_tid_q <= st_front_tid_d;
      mem_stall_q <= mem_stall_i;
      commit_ptr_q <= commit_ptr_i;
    end
  end

  //pragma translate_off
  // r68 L3 contract: a live head-only entry carries legal_o=1 only while
  // its tid is the commit head; a live entry's legality was computed for
  // this occupant (it was live when the bit was formed). Fires on the
  // cycle of the violation, in every simulation that elaborates the IQ --
  // the r62 wedge would have named this module at 21,945,78x instead of
  // the amo_buffer forty cycles later.
  int unsigned r68_iqleg_n = 0;
  always_ff @(posedge clk_i) begin : p_r68_iqleg
    if (rst_ni && !flush_i) begin
      for (int unsigned b = 0; b < BANKS; b++) begin
        for (int unsigned e = 0; e < ENTRIES; e++) begin
          if (info_v_i[b][e] && legal_o[b][e] &&
              !$isunknown({info_tid_i[b][e], info_cls_i[b][e]})) begin
            r68_iqleg_n <= r68_iqleg_n + 1;
            g6lc_r68_iqleg_head_only: assert (
                !(info_cls_i[b][e][C_CVXI] | info_cls_i[b][e][C_AMO] |
                  info_cls_i[b][e][C_CSYS]) ||
                (info_tid_i[b][e] == commit_ptr_i))
              else $error("g6lc_iq_legal: head-only entry b=%0d e=%0d tid=%0d legal while commit_ptr=%0d",
                          b, e, info_tid_i[b][e], commit_ptr_i);
          end
        end
      end
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_iq_legal r68 head-only: checked=%0d", r68_iqleg_n);
  end
  // hyp8 T1 item 15: equivalence. The pre-T1 serial forms — bank-merge
  // frontier chain and per-entry unresolved accumulate — are recomputed
  // and compared against the live comb results every cycle; the frontier
  // one-hot0 property is checked too.
  logic [NH-1:0]            ref_csr_v, ref_st_v;
  logic [NH-1:0][TID_W-1:0] ref_csr_tid, ref_st_tid;
  logic [BANKS-1:0][ENTRIES-1:0] ref_unres;
  always_comb begin : p_t1_iqleg_ref
    ref_csr_v = '0; ref_csr_tid = '0;
    ref_st_v  = '0; ref_st_tid  = '0;
    for (int unsigned b = 0; b < BANKS; b++) begin
      for (int unsigned e = 0; e < ENTRIES; e++) begin
        automatic logic [HID_W-1:0] h;
        automatic logic             ou;
        h = info_hart_i[b][e];
        ou = 1'b0;
        // r68: the reference must scan for the same occupant identity the
        // live form registers (fact_tid = next-state tid).
        for (int unsigned s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin
          if (st_unresolved_mask_i[s] &&
              (NH <= 1 || st_hart_mask_i[h][s]) &&
              ooo_age_older(TID_W, 32'(s), 32'(fact_tid[b][e]),
                            32'(commit_ptr_i)))
            ou = 1'b1;
        end
        ref_unres[b][e] = ou;
      end
    end
    if (NH <= 1) begin
      for (int unsigned b = 0; b < BANKS; b++) begin
        if (csr_oldest_v_i[b] &&
            !(ref_csr_v[0] &&
              ooo_age_older(TID_W, 32'(ref_csr_tid[0]),
                            32'(csr_oldest_tid_i[b]), 32'(commit_ptr_i)))) begin
          ref_csr_v[0]   = 1'b1;
          ref_csr_tid[0] = csr_oldest_tid_i[b];
        end
        if (st_oldest_v_i[b] &&
            !(ref_st_v[0] &&
              ooo_age_older(TID_W, 32'(ref_st_tid[0]),
                            32'(st_oldest_tid_i[b]), 32'(commit_ptr_i)))) begin
          ref_st_v[0]   = 1'b1;
          ref_st_tid[0] = st_oldest_tid_i[b];
        end
      end
    end else begin
      // NH>1 reference: the pre-T1 serial per-hart entry scan.
      for (int unsigned b = 0; b < BANKS; b++) begin
        for (int unsigned e = 0; e < ENTRIES; e++) begin
          automatic logic [HID_W-1:0] h;
          h = info_hart_i[b][e];
          if (info_v_i[b][e] && info_cls_i[b][e][C_CSR] &&
              (!ref_csr_v[h] ||
               ooo_age_older(TID_W, 32'(info_tid_i[b][e]),
                             32'(ref_csr_tid[h]), 32'(commit_ptr_i)))) begin
            ref_csr_v[h]   = 1'b1;
            ref_csr_tid[h] = info_tid_i[b][e];
          end
          if (info_v_i[b][e] && info_cls_i[b][e][C_ST] &&
              (!ref_st_v[h] ||
               ooo_age_older(TID_W, 32'(info_tid_i[b][e]),
                             32'(ref_st_tid[h]), 32'(commit_ptr_i)))) begin
            ref_st_v[h]   = 1'b1;
            ref_st_tid[h] = info_tid_i[b][e];
          end
        end
      end
    end
  end
  int unsigned t1_iqleg_n = 0;
  always_ff @(posedge clk_i) begin : p_t1_iqleg_eq
    if (rst_ni) begin
      if (!$isunknown({csr_front_v_d, st_front_v_d, unres_d})) begin
        t1_iqleg_n <= t1_iqleg_n + 1;
        g6lc_t1_iqleg_eq: assert (unres_d === ref_unres &&
                                  csr_front_v_d === ref_csr_v &&
                                  st_front_v_d  === ref_st_v &&
                                  csr_front_tid_d === ref_csr_tid &&
                                  st_front_tid_d  === ref_st_tid)
          else $error("g6lc_iq_legal: equiv leg");
`ifndef G6LC_MUT_T1_IQLEG
        g6lc_t1_iqleg_oh: assert ($onehot0(csr_win) && $onehot0(st_win))
          else $error("g6lc_iq_legal: equiv leg (frontier not onehot)");
`endif
      end
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_iq_legal leg: checked=%0d", t1_iqleg_n);
  end
  //pragma translate_on

endmodule
