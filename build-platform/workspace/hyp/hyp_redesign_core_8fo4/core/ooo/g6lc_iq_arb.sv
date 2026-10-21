// hyp8 provenance: REWRITTEN (issue-queue cross-bank arbiter)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_iq_arb -- ordered bank candidates -> NrIssuePorts issue ports
// (analysis/g6lc_iq.md sec.5, cut_minimization "g6lc_iq" rank-2 row).
// Pipeline:
//   T+1  bank candidates captured in cand_q; their pairwise order bits
//        are evaluated against commit_ptr_i at the same edge and held in
//        the registered age matrix aq_q. Combinational merge: each
//        adjacent bank pair -> two oldest candidates by matrix order bit,
//        then per-port select (port 0 = global oldest; port p = oldest
//        remaining, with the FP read-port reservation -- the group has one
//        shared FP read-port set, so only one FP consumer per cycle).
//        A selected candidate pulses take to its bank (mark issued +
//        speculative producer broadcast) and its (bank, entry) index drives
//        the synchronous payload read in g6lc_iq_payload; win_q captures
//        the select record.
//   T+2  payload data has landed: win_q is presented as issue_sbe_o /
//        issue_orig_o / issue_prd_o / issue_valid_o / issue_spec_o. This is
//        the "payload read the cycle after the bank grant" boundary -- the
//        PRF operand read in g6lc_ooo_dispatch shares it (rank 2, no added
//        cycle on issue->execute; it replaces the IRO operand latch).
//        issue_ack_i retires the bank entry (ack_v). An un-acked
//        presentation moves into pres_q with its payload snapshot and is
//        held -- never re-selected, and a cancelled held record is dropped
//        before it can be taken. A cancelled win is likewise dropped.
// Selection is admitted only when both presentation slots are free (a held
// presentation blocks the next grant by one bubble after a stall) -- the
// conservative direction, never an early release.
//
// Kill identity: cancelled candidates are dropped before select (mask on
// cand_q), held/pending records drop on their tid appearing in
// cancelled_mask_i, and flush_i clears every register.

module g6lc_iq_arb
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned BANKS   = 8,
    parameter int unsigned ENTRIES = 4,
    parameter int unsigned TID_W   = 5,
    parameter int unsigned PRF_W   = 6,
    parameter int unsigned NPORTS  = 2,   // NrIssuePorts
    parameter type scoreboard_entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    input  logic [TID_W-1:0]                 commit_ptr_i,
    // Bank candidates (comb from g6lc_iq_bank).
    input  logic [BANKS-1:0][1:0]             cand_v_i,
    input  logic [BANKS-1:0][1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] cand_i_i,
    input  logic [BANKS-1:0][1:0][TID_W-1:0]  cand_tid_i,
    input  logic [BANKS-1:0][1:0]             cand_fp_i,
    input  logic [BANKS-1:0][1:0]             cand_spec_i,
    // hyp8 g7: per-operand spec-arm bits + producer tids (forwarded to
    // the issue record) and the candidate resource needs for the
    // take-gate reservation table.
    input  logic [BANKS-1:0][1:0][1:0]        cand_spec_ab_i,
    input  logic [BANKS-1:0][1:0][1:0][TID_W-1:0] cand_ptid_i,
    input  logic [BANKS-1:0][1:0]             cand_fluin_i,
    input  logic [BANKS-1:0][1:0][1:0]        cand_wbport_i,
    input  logic [BANKS-1:0][1:0][4:0]        cand_wboff_i,
    input  logic [BANKS-1:0][1:0][3:0]        cand_gate_i,
    input  logic [BANKS-1:0][1:0]             cand_div_i,
    // FU ready status for the take-gate ({lsu,fpu,csr,mult} order).
    input  logic                            lsu_ready_i,
    input  logic                            fpu_ready_i,
    input  logic                            csr_ready_i,
    input  logic                            mult_ready_i,
    // Payload read index out (winner per port) / payload back next cycle.
    output logic [NPORTS-1:0][$clog2(BANKS > 1 ? BANKS : 2)-1:0] pay_bank_o,
    output logic [NPORTS-1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] pay_entry_o,
    input  scoreboard_entry_t [NPORTS-1:0]    pay_sbe_i,
    input  logic [NPORTS-1:0][31:0]           pay_orig_i,
    input  logic [NPORTS-1:0][PRF_W-1:0]      pay_prd_i,
    // Issue presentation (registered -- from win_q/pres_q + payload regs).
    output scoreboard_entry_t [NPORTS-1:0]    issue_sbe_o,
    output logic [NPORTS-1:0][31:0]           issue_orig_o,
    output logic [NPORTS-1:0][PRF_W-1:0]      issue_prd_o,
    output logic [NPORTS-1:0]                 issue_valid_o,
    output logic [NPORTS-1:0]                 issue_spec_o,
    // hyp8 g7: per-operand spec-arm bits + ALU-class producer tids for
    // the issue-stage in-ALU forward select.
    output logic [NPORTS-1:0][1:0]            issue_spec_ab_o,
    output logic [NPORTS-1:0][1:0][TID_W-1:0] issue_ptid_o,
    input  logic [NPORTS-1:0]                 issue_ack_i,
    // hyp8 H27: perf pulse — a port's selected (oldest ready) candidate was
    // not taken this cycle only because its FLU_IN/FLU_WB/FPU_WB/div
    // reservation slot was occupied (FU ready-gates would have passed).
    output logic                              hyp_wb_reserve_stall_o,
    // Back-signals to the banks.
    output logic [BANKS-1:0][NPORTS-1:0]      take_v_o,
    output logic [BANKS-1:0][NPORTS-1:0]      take_cand_o,
    output logic [BANKS-1:0][NPORTS-1:0]      ack_v_o,
    output logic [BANKS-1:0][NPORTS-1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] ack_idx_o
);

  localparam int unsigned BW = (BANKS > 1) ? $clog2(BANKS) : 1;
  localparam int unsigned EW = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam int unsigned NPAIR = (BANKS + 1) / 2;
  localparam int unsigned NCAND = NPAIR * 2;    // merged candidates to select over

  typedef struct packed {
    logic               v;
    logic [BW-1:0]      bank;
    logic               ci;       // bank-local candidate index (0/1)
    logic [EW-1:0]      entry;
    logic [TID_W-1:0]   tid;
    logic               fp;
    logic               spec;
    logic [1:0]         spec_ab;  // {rs1,rs2} spec-armed
    logic [1:0][TID_W-1:0] ptid;  // ALU-class producer tid per operand
    logic               flu_in;
    logic [1:0]         wb_port;  // 0 FLU_WB, 1 FPU_WB, 2 none
    logic [4:0]         wb_off;
    logic [3:0]         gate;     // {lsu,fpu,csr,mult} ready-gates
    logic               div;
  } sel_t;

  // Pending presentation: the select record captured at T+1, presented at
  // T+2 alongside the payload registers it addressed.
  typedef struct packed {
    logic               v;
    logic [BW-1:0]      bank;
    logic [EW-1:0]      entry;
    logic [TID_W-1:0]   tid;
    logic               spec;
    logic [1:0]         spec_ab;
    logic [1:0][TID_W-1:0] ptid;
    scoreboard_entry_t  sbe;
    logic [31:0]        orig;
    logic [PRF_W-1:0]   prd;
  } pres_t;

  // svt-stage: begin ARB
  // ----------------------------------------------------------------------
  // Registered bank candidates
  // ----------------------------------------------------------------------
  logic [BANKS-1:0][1:0]            cand_v_q;
  logic [BANKS-1:0][1:0][EW-1:0]    cand_i_q;
  logic [BANKS-1:0][1:0][TID_W-1:0] cand_tid_q;
  logic [BANKS-1:0][1:0]            cand_fp_q;
  logic [BANKS-1:0][1:0]            cand_spec_q;
  logic [BANKS-1:0][1:0][1:0]       cand_spec_ab_q;
  logic [BANKS-1:0][1:0][1:0][TID_W-1:0] cand_ptid_q;
  logic [BANKS-1:0][1:0]            cand_fluin_q;
  logic [BANKS-1:0][1:0][1:0]       cand_wbport_q;
  logic [BANKS-1:0][1:0][4:0]       cand_wboff_q;
  logic [BANKS-1:0][1:0][3:0]       cand_gate_q;
  logic [BANKS-1:0][1:0]            cand_div_q;

  // Presentation registers: win_q = selected at T+1, payload arrives T+2;
  // pres_q = un-acked hold (own sbe snapshot, payload regs may be reused).
  sel_t  [NPORTS-1:0] win_q;
  pres_t [NPORTS-1:0] pres_q;

  function automatic logic age_older(input logic [TID_W-1:0] a,
                                     input logic [TID_W-1:0] b);
    return ooo_age_older(TID_W, 32'(a), 32'(b), 32'(commit_ptr_i));
  endfunction

  // ----------------------------------------------------------------------
  // hyp8 r5: registered cross-bank candidate-age matrix. The pairwise
  // order compare leaves the select cycle entirely: at the candidate
  // capture edge every (bank,ci) slot pair's order bit is evaluated and
  // registered alongside cand_*_q, so pair-merge and the port tournament
  // read static matrix bits instead of comparing tids. The matrix is
  // maintained on population change: a refreshed capture writes a new
  // candidate's row/column against the population it joins, and a
  // departed candidate's bits are never read (pool.v masks it before any
  // matrix bit is consumed). Order among scoreboard-live tids is
  // commit-pointer-drift stable (ooo_age_older's own soundness
  // precondition), so a captured bit stays valid for the whole compare
  // lifetime of the pair it was captured with.
  // ----------------------------------------------------------------------
  localparam int unsigned NSLOT = BANKS * 2;
  logic [NSLOT-1:0][NSLOT-1:0] aq_d, aq_q;

  function automatic int unsigned slot_of(input logic [BW-1:0] b,
                                          input logic ci);
    return int'(b) * 2 + int'(ci);
  endfunction

  for (genvar a = 0; a < NSLOT; a++) begin : gen_aq_r
    for (genvar b = 0; b < NSLOT; b++) begin : gen_aq_c
      if (a == b) begin : gen_diag
        assign aq_d[a][b] = 1'b0;
      end else begin : gen_nd
        assign aq_d[a][b] = age_older(cand_tid_i[a/2][a%2],
                                      cand_tid_i[b/2][b%2]);
      end
    end
  end

  // ----------------------------------------------------------------------
  // Pair merge + port select over cand_q (cancelled dropped first)
  // ----------------------------------------------------------------------
  sel_t [NCAND-1:0] merged;

  // hyp8: per-pair merge as a 4-record pool + gated selects. Per-bank
  // ranking (cand0 older than cand1) makes the two-bank min/next two
  // pairwise age compares; every pool/merged write is an independent LHS.
  // hyp8 r5: the three order terms read the registered matrix (aq_q)
  // instead of comparing tids -- indices are static slot numbers.
  for (genvar pr = 0; pr < NPAIR; pr++) begin : gen_pmerge
    localparam int unsigned B0 = pr * 2;
    localparam int unsigned B1 = pr * 2 + 1;
    // Clamped slot indices for the (possibly absent) odd second bank;
    // pool[2]/pool[3] are already .v-masked when B1 is out of range.
    localparam int unsigned S00 = B0 * 2;
    localparam int unsigned S01 = B0 * 2 + 1;
    localparam int unsigned S10 = (B1 < BANKS) ? B1 * 2     : 0;
    localparam int unsigned S11 = (B1 < BANKS) ? B1 * 2 + 1 : 0;
    sel_t [3:0] pool;
    logic a0_old, m1a, m1c;
    sel_t m0, m1;

    for (genvar ci = 0; ci < 2; ci++) begin : gen_a
      assign pool[ci] = '{
        v: cand_v_q[B0][ci] && !cancelled_mask_i[cand_tid_q[B0][ci]],
        bank: BW'(B0), ci: 1'(ci), entry: cand_i_q[B0][ci],
        tid: cand_tid_q[B0][ci], fp: cand_fp_q[B0][ci],
        spec: cand_spec_q[B0][ci], spec_ab: cand_spec_ab_q[B0][ci],
        ptid: cand_ptid_q[B0][ci], flu_in: cand_fluin_q[B0][ci],
        wb_port: cand_wbport_q[B0][ci], wb_off: cand_wboff_q[B0][ci],
        gate: cand_gate_q[B0][ci], div: cand_div_q[B0][ci]};
    end
    for (genvar ci = 0; ci < 2; ci++) begin : gen_c
      assign pool[2+ci] = '{
        v: (B1 < BANKS) && cand_v_q[B1][ci] &&
           !cancelled_mask_i[cand_tid_q[B1][ci]],
        bank: BW'(B1), ci: 1'(ci), entry: cand_i_q[B1][ci],
        tid: cand_tid_q[B1][ci], fp: cand_fp_q[B1][ci],
        spec: cand_spec_q[B1][ci], spec_ab: cand_spec_ab_q[B1][ci],
        ptid: cand_ptid_q[B1][ci], flu_in: cand_fluin_q[B1][ci],
        wb_port: cand_wbport_q[B1][ci], wb_off: cand_wboff_q[B1][ci],
        gate: cand_gate_q[B1][ci], div: cand_div_q[B1][ci]};
    end

    assign a0_old = pool[0].v &&
        (!pool[2].v || !aq_q[S10][S00]);
    assign m1a = pool[1].v &&
        (!pool[2].v || !aq_q[S10][S01]);
    assign m1c = pool[3].v &&
        (!pool[0].v || !aq_q[S00][S11]);
    // hyp8 r7: age is one aq_q bit. m_oh is which of the four static
    // slots this merged candidate is (bit0 S00, bit1 S10, bit2 S01,
    // bit3 S11). A 16-bit row mux plus an OR-reduce is the same bit
    // and a deeper cone.
    // {bit3, bit2, bit1, bit0}
    assign m_oh[pr*2]   = {2'b00, !a0_old, a0_old};
    assign m_oh[pr*2+1] = (a0_old && m1a) ? 4'b0100 :
                          a0_old          ? 4'b0010 :
                          m1c             ? 4'b1000 : 4'b0001;
    assign m0 = a0_old ? pool[0] : pool[2];
    assign m1 = a0_old ? (m1a ? pool[1] : pool[2])
                       : (m1c ? pool[3] : pool[0]);
    assign merged[pr*2+0] = m0.v ? m0 : sel_t'('0);
    assign merged[pr*2+1] = m1.v ? m1 : sel_t'('0);
  end

  // Port select: oldest eligible merged candidate per port; the first FP
  // consumer reserves the shared FP read-port set (later FP held).
  sel_t [NPORTS-1:0] win;
  logic [NPORTS-1:0] win_v;

  // hyp8: the serial best-scan fold is replaced by per-port compare
  // vectors. Port p's eligible set = merged[c].v not already used and not
  // FP-blocked; the winner is the eligible candidate no other eligible
  // candidate is older than (strict tid order -> unique one-hot). The
  // used/fp_taken prefix over ports is the only serial dependency left
  // (2 OR bits per hop). Payload select is a masked-OR pairwise tree.
  localparam int unsigned MLEV = (NCAND > 1) ? $clog2(NCAND) : 1;

  // hyp8 r7: aold[c][k] = aq_q[slot(c)][slot(k)], both slots a
  // one-hot of four constants. Each term is one AND of two predicates
  // and one matrix bit. No NSLOT-wide reduce, no variable index.
  logic [NCAND-1:0][3:0] m_oh;
  logic [NCAND-1:0][NCAND-1:0] aold;
  for (genvar c = 0; c < NCAND; c++) begin : gen_am_r
    for (genvar k = 0; k < NCAND; k++) begin : gen_am_c
      if (k == c) begin : gen_diag
        assign aold[c][k] = 1'b0;
      end else begin : gen_bit
        localparam int unsigned PC = int'(c) / 2;
        localparam int unsigned PK = int'(k) / 2;
        localparam int unsigned C00 = (PC * 2) * 2;
        localparam int unsigned C01 = C00 + 1;
        localparam int unsigned C10 = ((PC * 2 + 1) < BANKS) ? (PC * 2 + 1) * 2 : 0;
        localparam int unsigned C11 = ((PC * 2 + 1) < BANKS) ? C10 + 1 : 0;
        localparam int unsigned K00 = (PK * 2) * 2;
        localparam int unsigned K01 = K00 + 1;
        localparam int unsigned K10 = ((PK * 2 + 1) < BANKS) ? (PK * 2 + 1) * 2 : 0;
        localparam int unsigned K11 = ((PK * 2 + 1) < BANKS) ? K10 + 1 : 0;
        assign aold[c][k] =
            (m_oh[c][0] & m_oh[k][0] & aq_q[C00][K00]) |
            (m_oh[c][0] & m_oh[k][1] & aq_q[C00][K10]) |
            (m_oh[c][0] & m_oh[k][2] & aq_q[C00][K01]) |
            (m_oh[c][0] & m_oh[k][3] & aq_q[C00][K11]) |
            (m_oh[c][1] & m_oh[k][0] & aq_q[C10][K00]) |
            (m_oh[c][1] & m_oh[k][1] & aq_q[C10][K10]) |
            (m_oh[c][1] & m_oh[k][2] & aq_q[C10][K01]) |
            (m_oh[c][1] & m_oh[k][3] & aq_q[C10][K11]) |
            (m_oh[c][2] & m_oh[k][0] & aq_q[C01][K00]) |
            (m_oh[c][2] & m_oh[k][1] & aq_q[C01][K10]) |
            (m_oh[c][2] & m_oh[k][2] & aq_q[C01][K01]) |
            (m_oh[c][2] & m_oh[k][3] & aq_q[C01][K11]) |
            (m_oh[c][3] & m_oh[k][0] & aq_q[C11][K00]) |
            (m_oh[c][3] & m_oh[k][1] & aq_q[C11][K10]) |
            (m_oh[c][3] & m_oh[k][2] & aq_q[C11][K01]) |
            (m_oh[c][3] & m_oh[k][3] & aq_q[C11][K11]);
      end
    end
  end

  logic [NPORTS:0][NCAND-1:0] usedp;      // used before port p
  logic [NPORTS:0]            fp_taken_p;
  assign usedp[0]     = '0;
  assign fp_taken_p[0] = 1'b0;

  logic [NPORTS-1:0][NCAND-1:0] elig, win_oh;
  for (genvar p = 0; p < NPORTS; p++) begin : gen_psel
    for (genvar c = 0; c < NCAND; c++) begin : gen_ec
      logic [NCAND-1:0] older_than_c;
      for (genvar k = 0; k < NCAND; k++) begin : gen_ot
        assign older_than_c[k] = elig[p][k] && aold[k][c];
      end
      assign elig[p][c]   = merged[c].v && !usedp[p][c] &&
                            !(fp_taken_p[p] && merged[c].fp);
      assign win_oh[p][c] = elig[p][c] && !(|older_than_c);
    end
    assign win_v[p] = |win_oh[p];
    // payload gather: masked-OR pairwise tree over NCAND
    logic [MLEV:0][NCAND-1:0][$bits(sel_t)-1:0] wt;
    for (genvar c = 0; c < NCAND; c++) begin : gen_wt0
      assign wt[0][c] = {$bits(sel_t){win_oh[p][c]}} & sel_t'(merged[c]);
    end
    for (genvar l = 0; l < MLEV; l++) begin : gen_lvl
      for (genvar i = 0; i < NCAND; i++) begin : gen_or
        if (i < ((NCAND + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
          if ((2 * i + 1) < ((NCAND + (1 << l) - 1) >> l)) begin : gen_pair
            assign wt[l+1][i] = wt[l][2*i] | wt[l][2*i+1];
          end else begin : gen_odd
            assign wt[l+1][i] = wt[l][2*i];
          end
        end else begin : gen_pad
          assign wt[l+1][i] = '0;
        end
      end
    end
    assign win[p] = sel_t'(wt[MLEV][0]);
    assign usedp[p+1]     = usedp[p] | win_oh[p];
    assign fp_taken_p[p+1] = fp_taken_p[p] | (win_v[p] && win[p].fp);
  end

  // ----------------------------------------------------------------------
  // hyp8 g7: take-time resource gate (WbReserve). Sliding windows, one
  // bit per future cycle per shared resource: FLU_IN (the shared ALU0
  // operand register at take+4), FLU_WB (fixed-latency completions on
  // the FLU writeback port) and FPU_WB. A take reserves its slots only
  // when every needed slot is free and the candidate's FU ready-gates
  // hold, so a taken spec-broadcast producer can never stall between
  // the IQ grant and the FU input registers -- the precondition for the
  // take-relative wakeup countdowns. A divider take additionally
  // requires the FLU_WB window empty and no div already live; while a
  // div is live no FLU-lane candidate may take (its completion time is
  // unschedulable -- the fus_busy precedent).
  // ----------------------------------------------------------------------
  localparam int unsigned RES_WIN = 16;
  localparam int unsigned KIN     = 5;  // take -> ALU0 input register (A1)
  localparam logic [1:0] WB_FLU = 2'd0, WB_FPU = 2'd1;
  logic [RES_WIN-1:0] flu_in_q, flu_wb_q, fpu_wb_q;
  logic               div_live_q;
  logic [NPORTS-1:0]  take_ok;
  logic               div_take;
  logic [RES_WIN-1:0] flu_in_next, flu_wb_next, fpu_wb_next;

  // hyp8: port p's block conditions are evaluated directly against the
  // window registers plus "an earlier port took the same resource this
  // cycle" compare terms; the only serial dependence is the take_ok
  // prefix itself (one AND/OR hop per port). The final table next-state
  // ORs every successful reservation's decoded slot in one pass.
  logic [NPORTS-1:0][RES_WIN-1:0] dec_off;
  logic [NPORTS-1:0]            res_block, gate_ok;
  logic [NPORTS-1:0]            w_flu_tk, w_fpu_tk, w_in_tk;
  for (genvar p = 0; p < NPORTS; p++) begin : gen_dec
    assign dec_off[p] = RES_WIN'(1) << win[p].wb_off;
  end
  for (genvar p = 0; p < NPORTS; p++) begin : gen_gate
    logic blk_in, blk_flu, blk_fpu, blk_div, blk_dliv;
    logic [NPORTS-1:0] ein, eflu, efpu, ediv;
    for (genvar q = 0; q < NPORTS; q++) begin : gen_earl
      if (q < p) begin : gen_q
        assign ein[q]  = take_ok[q] && win[q].flu_in;
        assign eflu[q] = take_ok[q] && (win[q].wb_port == WB_FLU) &&
                         (win[q].wb_off == win[p].wb_off);
        assign efpu[q] = take_ok[q] && (win[q].wb_port == WB_FPU) &&
                         (win[q].wb_off == win[p].wb_off);
        assign ediv[q] = take_ok[q] && (win[q].wb_port == WB_FLU);
      end else begin : gen_nq
        assign ein[q]  = 1'b0;
        assign eflu[q] = 1'b0;
        assign efpu[q] = 1'b0;
        assign ediv[q] = 1'b0;
      end
    end
    assign blk_in   = win[p].flu_in &&
                      (flu_in_q[KIN] || (|ein));
    assign blk_flu  = (win[p].wb_port == WB_FLU) &&
                      ((|(flu_wb_q & dec_off[p])) || (|eflu));
    assign blk_fpu  = (win[p].wb_port == WB_FPU) &&
                      ((|(fpu_wb_q & dec_off[p])) || (|efpu));
    assign blk_div  = win[p].div &&
                      ((|flu_wb_q) || (|ediv) || div_live_q);
    assign blk_dliv = div_live_q &&
                      (win[p].flu_in || (win[p].wb_port == WB_FLU));
    assign res_block[p] = blk_in | blk_flu | blk_fpu | blk_div | blk_dliv;
    assign gate_ok[p]   = !(win[p].gate[0] && !lsu_ready_i) &&
                          !(win[p].gate[1] && !fpu_ready_i) &&
                          !(win[p].gate[2] && !csr_ready_i) &&
                          !(win[p].gate[3] && !mult_ready_i);
    assign take_ok[p] = win_v[p] && !res_block[p] && gate_ok[p];
    assign w_in_tk[p]  = take_ok[p] && win[p].flu_in;
    assign w_flu_tk[p] = take_ok[p] && (win[p].wb_port == WB_FLU);
    assign w_fpu_tk[p] = take_ok[p] && (win[p].wb_port == WB_FPU);
  end
  logic [NPORTS-1:0] stall_p, div_tk;
  for (genvar p = 0; p < NPORTS; p++) begin : gen_stall
    // hyp8 H27: declined ONLY by a reservation slot (the port could
    // take and every FU ready-gate passed).
    assign stall_p[p] = win_v[p] && res_block[p] && gate_ok[p] &&
                        !pres_q[p].v;
    assign div_tk[p]  = take_ok[p] && win[p].div;
  end
  assign hyp_wb_reserve_stall_o = |stall_p;
  assign div_take = |div_tk;
  // Next window images: q register contents OR every taken reservation
  // (each port contributes at most one decoded bit; disjoint masks ORed).
  logic [NPORTS-1:0][RES_WIN-1:0] in_mk, flu_mk, fpu_mk;
  for (genvar p = 0; p < NPORTS; p++) begin : gen_mk
    assign in_mk[p]  = {RES_WIN{w_in_tk[p]}}  & (RES_WIN'(1) << KIN);
    assign flu_mk[p] = {RES_WIN{w_flu_tk[p]}} & dec_off[p];
    assign fpu_mk[p] = {RES_WIN{w_fpu_tk[p]}} & dec_off[p];
  end
  always_comb begin : res_next
    flu_in_next  = flu_in_q;
    flu_wb_next  = flu_wb_q;
    fpu_wb_next  = fpu_wb_q;
    for (int unsigned p = 0; p < NPORTS; p++) begin
      flu_in_next  = flu_in_next  | in_mk[p];
      flu_wb_next  = flu_wb_next  | flu_mk[p];
      fpu_wb_next  = fpu_wb_next  | fpu_mk[p];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : res_regs
    if (!rst_ni) begin
      flu_in_q  <= '0;
      flu_wb_q  <= '0;
      fpu_wb_q  <= '0;
      div_live_q <= 1'b0;
    end else if (flush_i) begin
      flu_in_q  <= '0;
      flu_wb_q  <= '0;
      fpu_wb_q  <= '0;
      div_live_q <= 1'b0;
    end else begin
      // Bit k holds a reservation k cycles out; the window slides so a
      // reservation made at offset o arrives at bit 0 when its slot is
      // consumed by the WB presentation.
      flu_in_q  <= {1'b0, flu_in_next[RES_WIN-1:1]};
      flu_wb_q  <= {1'b0, flu_wb_next[RES_WIN-1:1]};
      fpu_wb_q  <= {1'b0, fpu_wb_next[RES_WIN-1:1]};
      if (mult_ready_i) div_live_q <= 1'b0;
      if (div_take)     div_live_q <= 1'b1;
    end
  end

  // ----------------------------------------------------------------------
  // Presentation: held record wins over a fresh win_q. Payload registers
  // (addressed at T+1 by the winning indices) supply win_q's sbe/orig/prd.
  // ----------------------------------------------------------------------
  always_comb begin
    take_v_o = '0;
    take_cand_o = '0;
    ack_v_o = '0;
    ack_idx_o = '0;
    pay_bank_o = '0;
    pay_entry_o = '0;
    issue_valid_o = '0;
    issue_spec_o = '0;
    issue_spec_ab_o = '0;
    issue_ptid_o = '0;
    for (int unsigned p = 0; p < NPORTS; p++) begin
      issue_sbe_o[p] = '0;
      issue_orig_o[p] = '0;
      issue_prd_o[p] = '0;
      if (pres_q[p].v && !cancelled_mask_i[pres_q[p].tid]) begin
        issue_valid_o[p] = 1'b1;
        issue_spec_o[p] = pres_q[p].spec;
        issue_spec_ab_o[p] = pres_q[p].spec_ab;
        issue_ptid_o[p] = pres_q[p].ptid;
        issue_sbe_o[p] = pres_q[p].sbe;
        issue_orig_o[p] = pres_q[p].orig;
        issue_prd_o[p] = pres_q[p].prd;
        if (issue_ack_i[p]) begin
          ack_v_o[pres_q[p].bank][p] = 1'b1;
          ack_idx_o[pres_q[p].bank][p] = pres_q[p].entry;
        end
      end else if (win_q[p].v && !cancelled_mask_i[win_q[p].tid]) begin
        issue_valid_o[p] = 1'b1;
        issue_spec_o[p] = win_q[p].spec;
        issue_spec_ab_o[p] = win_q[p].spec_ab;
        issue_ptid_o[p] = win_q[p].ptid;
        issue_sbe_o[p] = pay_sbe_i[p];
        issue_orig_o[p] = pay_orig_i[p];
        issue_prd_o[p] = pay_prd_i[p];
        if (issue_ack_i[p]) begin
          ack_v_o[win_q[p].bank][p] = 1'b1;
          ack_idx_o[win_q[p].bank][p] = win_q[p].entry;
        end
      end
      // Select for the NEXT presentation whenever no held record owns the
      // port: win_q is either empty, being acknowledged, or about to move
      // into pres_q, so the port never loses a cycle in steady state.
      // hyp8 g7: a selected candidate takes only when the resource gate
      // admits it; a declined candidate simply stays in the cand
      // registers and is re-evaluated against the next capture.
      if (!pres_q[p].v && win_v[p] && take_ok[p]) begin
        take_v_o[win[p].bank][p] = 1'b1;
        take_cand_o[win[p].bank][p] = win[p].ci;
        pay_bank_o[p] = win[p].bank;
        pay_entry_o[p] = win[p].entry;
      end
    end
  end

  // ----------------------------------------------------------------------
  // Registers
  // ----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cand_v_q <= '0;
      cand_i_q <= '0;
      cand_tid_q <= '0;
      cand_fp_q <= '0;
      cand_spec_q <= '0;
      cand_spec_ab_q <= '0;
      cand_ptid_q <= '0;
      cand_fluin_q <= '0;
      cand_wbport_q <= '0;
      cand_wboff_q <= '0;
      cand_gate_q <= '0;
      cand_div_q <= '0;
      aq_q <= '0;
      for (int unsigned p = 0; p < NPORTS; p++) begin
        win_q[p] <= '{v: 1'b0, default: '0};
        pres_q[p] <= '0;
      end
    end else if (flush_i) begin
      cand_v_q <= '0;
      aq_q <= '0;
      for (int unsigned p = 0; p < NPORTS; p++) begin
        win_q[p].v <= 1'b0;
        pres_q[p].v <= 1'b0;
      end
    end else begin
      cand_v_q <= cand_v_i;
      cand_i_q <= cand_i_i;
      cand_tid_q <= cand_tid_i;
      cand_fp_q <= cand_fp_i;
      cand_spec_q <= cand_spec_i;
      cand_spec_ab_q <= cand_spec_ab_i;
      cand_ptid_q <= cand_ptid_i;
      cand_fluin_q <= cand_fluin_i;
      cand_wbport_q <= cand_wbport_i;
      cand_wboff_q <= cand_wboff_i;
      cand_gate_q <= cand_gate_i;
      cand_div_q <= cand_div_i;
      aq_q <= aq_d;
      for (int unsigned p = 0; p < NPORTS; p++) begin
        // Held record: acked or cancelled -> free the port.
        if (pres_q[p].v &&
            (issue_ack_i[p] || cancelled_mask_i[pres_q[p].tid]))
          pres_q[p].v <= 1'b0;
        // Pending presentation: presented this cycle only while no held
        // record owns the port; on no-ack it moves into pres_q (payload
        // snapshot), on ack/cancel it is simply done.
        if (win_q[p].v) begin
          if (cancelled_mask_i[win_q[p].tid]) begin
            win_q[p].v <= 1'b0;
          end else if (!pres_q[p].v) begin
            if (issue_ack_i[p]) begin
              win_q[p].v <= 1'b0;
            end else begin
              pres_q[p].v <= 1'b1;
              pres_q[p].bank <= win_q[p].bank;
              pres_q[p].entry <= win_q[p].entry;
              pres_q[p].tid <= win_q[p].tid;
              pres_q[p].spec <= win_q[p].spec;
              pres_q[p].spec_ab <= win_q[p].spec_ab;
              pres_q[p].ptid <= win_q[p].ptid;
              pres_q[p].sbe <= pay_sbe_i[p];
              pres_q[p].orig <= pay_orig_i[p];
              pres_q[p].prd <= pay_prd_i[p];
              win_q[p].v <= 1'b0;
            end
          end
        end
        // Fresh select: pres_q free (win_q is empty, acked, or moving)
        // and the resource gate admits the take; a cancelled winner is
        // dropped before it can hold the port.
        if (!pres_q[p].v && win_v[p] && take_ok[p] &&
            !cancelled_mask_i[win[p].tid])
          win_q[p] <= win[p];
      end
    end
  end

  // svt-stage: end ARB
  // svt-stage: class ARB decision
  // svt-stage: absorb ARB by=spec-wakeup cond="registered age row is a static 2:1 or 4:1; ack addresses the held candidate"

  // pragma translate_off
  // ----------------------------------------------------------------------
  // hyp8 r5 equivalence reference: the registered age matrix bit must
  // equal the original same-cycle tid compare (ooo_age_older on the
  // registered candidate tids) for every slot pair whose candidates are
  // valid. Order among scoreboard-live tids is commit-pointer-drift
  // stable (ooo_age_older's soundness precondition), so the captured bit
  // matches the live compare for the pair's whole compare lifetime.
  for (genvar a = 0; a < NSLOT; a++) begin : gen_ref_r
    for (genvar b = 0; b < NSLOT; b++) begin : gen_ref_c
      if (a != b) begin : gen_ref_p
        assert property (@(posedge clk_i) disable iff (!rst_ni)
            (cand_v_q[a/2][a%2] && cand_v_q[b/2][b%2])
            |-> (aq_q[a][b] ==
                 age_older(cand_tid_q[a/2][a%2], cand_tid_q[b/2][b%2])))
          else $fatal(1, "iq_arb ARB: age matrix bit mismatch slots %0d/%0d",
                      a, b);
      end
    end
  end
  // pragma translate_on
endmodule
