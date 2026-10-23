// hyp8 provenance: REWRITTEN (banked stationary issue-queue slice)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_iq_bank -- one bank of HypCfg.IqBankEntries stationary entries
// (analysis/g6lc_iq.md). In-bank wakeup -> ready -> ranked candidate is a
// single-cycle combinational path off registered state; the candidates are
// registered one level up in g6lc_iq_arb.
//
// Wakeup forms:
//   - real WB (int and FP ports): the tag match captures into the
//     registered rdy bit at the edge and the entry becomes a candidate on
//     the following cycle. In the Hyp8 profile this is the ONLY wakeup --
//     dependent waits are not absorbed: a consumer presents strictly one
//     cycle after the producer's writeback.
//   - speculative wakeup (parameterized, IqSpecWakeup!=0 -- OFF in Hyp8):
//     when this bank's candidate is TAKEN by the arb, the taken entry's
//     producer tag + countdown (= hyp_lat_cycles(class)-2) is broadcast
//     back into this bank the same cycle (local copy) and out to the xbar
//     for the other banks (+1). A consumer matching the tag arms a
//     per-source countdown and presents when it reaches the bypass slot;
//     the rsX_spec bit records that the rdy came from speculation, and is
//     what issue_spec_o reports for the granted candidate. Hyp8 leaves
//     this path inert; the countdown fields are still sized by WAKE_W so
//     the mechanism remains elaboration-correct, not qualified.
//   - replay_i re-arms speculation: the draft keeps the bank-wide fallback --
//     every entry whose rdy came from speculation drops it and waits for
//     the real WB (correct for any replayed tid, conservative in coverage).
//
// Ordering inputs are registered facts only (legal_i from g6lc_iq_legal):
// N1d CSR age order, T24 store age order, head-only classes, may_bypass and
// mem_stall gating live there, not here. Kill identity: cancelled_mask_i
// hides the entry from candidacy this cycle and clears it at the edge; a
// taken-but-unacked entry is still killed (the arb drops its held record).

module g6lc_iq_bank
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter int unsigned ENTRIES = 4,
    parameter int unsigned PRF_W   = 6,
    parameter int unsigned FPRF_W  = 1,
    parameter int unsigned NR_WB   = 4,   // integer WB tag ports (incl. commit mirrors)
    parameter int unsigned NR_FWB  = 4,   // FP WB tag ports
    parameter int unsigned TID_W   = 5,
    parameter int unsigned NLANES  = 2,   // dispatch lanes that may land here
    parameter int unsigned NTAKE   = 2,   // arb take ports (issue width)
    parameter int unsigned NXW     = 8,   // cross-bank wake inputs
    parameter int unsigned HID_W   = 1,
    // Countdown width shared with the wrapper/xbar (g6lc_iq derives it from
    // the longest producer latency class).
    parameter int unsigned WAKE_W  = 3
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Allocation: lanes already steered to this bank by the wrapper; lane
    // order is the intra-group age order (lane 0 older).
    input  logic [NLANES-1:0]                 alloc_i,
    input  logic [NLANES-1:0][6:0]            alloc_cls_i,   // {needfp,cvxi,amo,csys,csr,st,ld}
    input  logic [NLANES-1:0][3:0]            alloc_fu_i,    // hyp8 g7: fu_t
    input  g6lc_hyp_pkg::hyp_lat_class_e [NLANES-1:0] alloc_lat_i,
    input  logic [NLANES-1:0][TID_W-1:0]      alloc_tid_i,
    input  logic [NLANES-1:0][HID_W-1:0]      alloc_hart_i,
    input  logic [NLANES-1:0][PRF_W-1:0]      alloc_prs1_i,
    input  logic [NLANES-1:0][PRF_W-1:0]      alloc_prs2_i,
    input  logic [NLANES-1:0][PRF_W-1:0]      alloc_prd_i,
    input  logic [NLANES-1:0][FPRF_W-1:0]     alloc_fprs1_i,
    input  logic [NLANES-1:0][FPRF_W-1:0]     alloc_fprs2_i,
    input  logic [NLANES-1:0][FPRF_W-1:0]     alloc_fprs3_i,
    input  logic [NLANES-1:0][FPRF_W-1:0]     alloc_fprd_i,
    input  logic [NLANES-1:0]                 alloc_fpr_rs1_i,
    input  logic [NLANES-1:0]                 alloc_fpr_rs2_i,
    input  logic [NLANES-1:0]                 alloc_fpr_rs3_i,
    input  logic [NLANES-1:0]                 alloc_is_fprd_i,
    input  logic [NLANES-1:0]                 alloc_may_bypass_i,
    input  logic [NLANES-1:0]                 alloc_rs1_rdy_i,
    input  logic [NLANES-1:0]                 alloc_rs2_rdy_i,
    input  logic [NLANES-1:0]                 alloc_rs3_rdy_i,
    output logic [NLANES-1:0]                 alloc_ack_o,
    // Entry index each accepted lane landed in (drives the payload write).
    output logic [NLANES-1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] alloc_slot_o,
    output logic [$clog2(ENTRIES+1)-1:0]      free_cnt_o,
    // Real writeback tags (comb capture into rdy, as the unbanked q_wake).
    input  logic [NR_WB-1:0]                  wb_valid_i,
    input  logic [NR_WB-1:0][PRF_W-1:0]       wb_prd_i,
    input  logic [NR_FWB-1:0]                 fwb_valid_i,
    input  logic [NR_FWB-1:0][FPRF_W-1:0]     fwb_prd_i,
    // Cross-bank registered broadcasts (all banks, this bank's own included --
    // a re-broadcast of an already-set rdy is harmless).
    input  logic [NXW-1:0]                    xw_v_i,
    input  logic [NXW-1:0][PRF_W-1:0]         xw_prd_i,
    input  logic [NXW-1:0][FPRF_W-1:0]        xw_fprd_i,
    input  logic [NXW-1:0]                    xw_fp_i,
    input  logic [NXW-1:0][WAKE_W-1:0]        xw_cnt_i,
    // hyp8 g7: producer identity carried with the wake (for the IRO
    // pipe-stage forward) and the producer class (alu/lo gating).
    input  logic [NXW-1:0][TID_W-1:0]         xw_tid_i,
    input  logic [NXW-1:0]                    xw_alu_i,
    input  logic [NXW-1:0]                    xw_lo_i,
    // Producer broadcast when this bank's candidate is taken (per take port).
    output logic [NTAKE-1:0]                  bcast_v_o,
    output logic [NTAKE-1:0][PRF_W-1:0]       bcast_prd_o,
    output logic [NTAKE-1:0][FPRF_W-1:0]      bcast_fprd_o,
    output logic [NTAKE-1:0]                  bcast_fp_o,
    output logic [NTAKE-1:0][WAKE_W-1:0]      bcast_cnt_o,
    output logic [NTAKE-1:0][TID_W-1:0]       bcast_tid_o,
    output logic [NTAKE-1:0]                  bcast_alu_o,
    output logic [NTAKE-1:0]                  bcast_lo_o,
    // Registered legality bits from g6lc_iq_legal.
    input  logic [ENTRIES-1:0]                legal_i,
    // Ranked candidates (comb): cand 0 = oldest ready, cand 1 = next.
    output logic [1:0]                        cand_v_o,
    output logic [1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] cand_i_o,
    output logic [1:0][TID_W-1:0]             cand_tid_o,
    output logic [1:0]                        cand_fp_o,
    output logic [1:0]                        cand_spec_o,
    // hyp8 g7: per-operand spec-arm bits + armed producer tids + the
    // candidate FU class (arb resource gate + issue-stage forward).
    output logic [1:0][1:0]                   cand_spec_ab_o,
    output logic [1:0][1:0][TID_W-1:0]        cand_ptid_o,
    output logic [1:0][3:0]                   cand_fu_o,
    // hyp8 g7: resource needs of the candidate for the arb take-gate:
    // the shared ALU0-input slot, the WB-port completion slot, the FU
    // ready-gates (lsu/fpu/csr/mult), and the divider all-clear flag.
    output logic [1:0]                        cand_fluin_o,
    output logic [1:0][1:0]                   cand_wbport_o,
    output logic [1:0][4:0]                   cand_wboff_o,
    output logic [1:0][3:0]                   cand_gate_o,
    output logic [1:0]                        cand_div_o,
    // Serial FU classes (CSR/AMO/CVXIF) may only occupy issue port 0.
    output logic [1:0]                        cand_port0_o,
    // Arb take: take_v_i[p] means port p took candidate take_cand_i[p].
    input  logic [NTAKE-1:0]                  take_v_i,
    input  logic [NTAKE-1:0]                  take_cand_i,
    // Entry the arb captured with the grant. The issued mark uses this,
    // not the cand one-hot, because the grant is one cycle after the cand.
    input  logic [NTAKE-1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] take_idx_i,
    // Arb ack: retire entry ack_idx_i[p].
    input  logic [NTAKE-1:0]                  ack_v_i,
    input  logic [NTAKE-1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] ack_idx_i,
    // Replay kill-by-tid re-arm (fallback: drop every spec rdy).
    input  logic                              replay_i,
    // Per-entry info for g6lc_iq_legal.
    output logic [ENTRIES-1:0]                info_v_o,
    output logic [ENTRIES-1:0][TID_W-1:0]     info_tid_o,
    output logic [ENTRIES-1:0][HID_W-1:0]     info_hart_o,
    output logic [ENTRIES-1:0][6:0]           info_cls_o,
    output logic [ENTRIES-1:0]                info_bypass_o,
    // hyp8 g10: rdy/prs export for the top-level sim debug windows (the
    // emit's flat i_iq.q_q view went away with the banked iq).
    output logic [ENTRIES-1:0][2:0]           info_rdy_o,
    output logic [ENTRIES-1:0][PRF_W-1:0]     info_prs1_o,
    output logic [ENTRIES-1:0][PRF_W-1:0]     info_prs2_o,
    // Class frontiers (bank-local oldest live CSR / store by in-bank age).
    output logic                              csr_oldest_v_o,
    output logic [TID_W-1:0]                  csr_oldest_tid_o,
    output logic                              st_oldest_v_o,
    output logic [TID_W-1:0]                  st_oldest_tid_o
);

  localparam int unsigned EW = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam int unsigned FCNT_W = $clog2(ENTRIES + 1);

  // cls bit indices
  localparam int unsigned C_LD = 0, C_ST = 1, C_CSR = 2, C_CSYS = 3,
                          C_AMO = 4, C_CVXI = 5, C_FP = 6;

  typedef struct packed {
    logic                valid;
    logic                issued;   // candidate taken; waits on ack or cancel
    logic [TID_W-1:0]    tid;
    logic [HID_W-1:0]    hart;
    logic [6:0]          cls;
    logic                may_bypass;
    g6lc_hyp_pkg::hyp_lat_class_e lat;
    logic                is_fprd;   // producer's destination is the FP file
    logic [PRF_W-1:0]    prs1, prs2, prd;
    logic [FPRF_W-1:0]   fprs1, fprs2, fprs3, fprd;
    logic                fpr_rs1, fpr_rs2, fpr_rs3;
    logic                rs1_rdy, rs2_rdy, rs3_rdy;
    logic                rs1_spec, rs2_spec, rs3_spec;
    // hyp8 r5: the arming broadcast's alu-low class. The select's only
    // same-cycle arm is a LAT_ALU_LOW one (distance-1); all latency>=2
    // arms complete through the registered rdy alone.
    logic                rs1_low, rs2_low;
    logic [WAKE_W-1:0]   rs1_cnt, rs2_cnt, rs3_cnt;
    // hyp8 g7: trans_id of the ALU-class producer that spec-armed this
    // operand (set only when the arming broadcast was ALU-class). The
    // issue stage matches it against the ALU pipe-stage tids for the
    // distance-1/2 in-ALU operand forward.
    logic [TID_W-1:0]    rs1_ptid, rs2_ptid;
    logic [3:0]          fu;   // fu_t of the op (arb resource gating)
  } iqb_entry_t;

  iqb_entry_t [ENTRIES-1:0] e_q, e_d;
  // Bank-local age matrix: older_q[a][b] == 1 means a is older than b.
  logic [ENTRIES-1:0][ENTRIES-1:0] older_q, older_d;

  // ----------------------------------------------------------------------
  // Producer latency countdown for the speculative wakeup broadcast.
  // ----------------------------------------------------------------------
  localparam int unsigned MULT_ST =
      (HypCfg.MultStagesOverride != 0) ? HypCfg.MultStagesOverride
                                       : int'(G6LCCfg.MultStages);
  // Cast adds p_int_cap, p_renorm, p_exp_align, p_cast_shift,
  // p_cast_post, and p_cast_uint on top of the fpnew pipes.
  // Live FMA is 8 distributed pipes plus the raw-exponent flop and
  // p_fma_exp. 10 keeps speculative wakeup from landing before that
  // result. Cast and noncomp wake no earlier than their results.
  localparam int unsigned FP_LAT = 10;

  function automatic logic [WAKE_W-1:0] wake_cnt(input g6lc_hyp_pkg::hyp_lat_class_e c);
    logic [31:0] cy;
    cy = g6lc_hyp_pkg::hyp_lat_cycles(HypCfg, c, MULT_ST, FP_LAT);
    // hyp8 r5: countdown shifted -1 for every cy>=2 class. The select
    // reads the registered rdy bits only (the CAM match captures at the
    // edge); arming one cycle earlier lands the registered rdy exactly on
    // the producer's publish cycle -- the same select cycle the old
    // spec-and-cnt==0 comb term granted. LAT_ALU_LOW (cy==1) keeps 0 and
    // uses the rsX_low same-cycle arm instead.
    return WAKE_W'((cy <= 1) ? 0 : (cy - 2));
  endfunction

  // hyp8 g7: raw cycle count. wake_cnt==0 is ambiguous between "arm next
  // cycle" (LAT_ALU_LOW, cy==1) and "never spec-wake" (LAT_NONSPEC,
  // cy==0): only cy!=0 producers may broadcast.
  function automatic logic [31:0] wake_cy(input g6lc_hyp_pkg::hyp_lat_class_e c);
    return g6lc_hyp_pkg::hyp_lat_cycles(HypCfg, c, MULT_ST, FP_LAT);
  endfunction

  // ----------------------------------------------------------------------
  // hyp8 g7: candidate resource encoding for the arb take-gate. fu_t
  // values are the g6lc_core_pkg encoding (NONE=0,LOAD=1,STORE=2,ALU=3,
  // CTRL_FLOW=4,MULT=5,CSR=6,FPU=7,FPU_VEC=8,CVXIF=9,ACCEL=10,AES=11).
  // Take-relative slot model (the arb gate slides the windows by one each
  // cycle): take -> payload read +1 -> iqi presentation +2 -> iss_q +3
  // -> fu_data +4 -> FU input/A1 registers +5. FLU_WB completions: the
  // A2 result_q (low-class alu) at +6, the A3 result3_q (LAT_ALU_FULL alu)
  // at +7 under AluStages==3, branch/csr/aes lane records at +7, the mul
  // pipe (8 stages after the input register) at +13; FPU_WB at
  // +6+flat. Offsets are conservative-late by intent: a slot held one
  // cycle too long costs an issue slot, a slot freed early collides.
  // ----------------------------------------------------------------------
  localparam logic [3:0] FU_LOAD = 4'd1, FU_STORE = 4'd2, FU_ALU = 4'd3,
                        FU_CTRL = 4'd4, FU_MULT = 4'd5, FU_CSR = 4'd6,
                        FU_FPU = 4'd7, FU_FPUV = 4'd8, FU_AES = 4'd11;
  localparam logic [1:0] WB_FLU = 2'd0, WB_FPU = 2'd1, WB_NONE = 2'd2;

  function automatic logic flu_in_of(input logic [3:0] fu);
    // Every one-cycle-class op occupies the shared one_cycle operand pick
    // in ex_stage: ALU/CTRL via alu_data[0], CSR via csr_buffer.fu_data_i
    // and AES via aes_i.fu_data_i all read one_cycle_data, so two such ops
    // taken in the same cycle would collide on the highest-port select.
    // The arbiter reads this bit together with wb_off==6: that pair on a
    // non-zero port is LAT_ALU_LOW and is steered to ALU2 / FPU_WB.
    // ALU-full, branch, CSR, and AES stay here (their offset is 7).
    return (fu == FU_ALU) || (fu == FU_CTRL) || (fu == FU_CSR) || (fu == FU_AES);
  endfunction
  function automatic logic [1:0] wb_port_of(input logic [3:0] fu);
    // hyp8: disjoint compares merged by OR (fu is a single value, so the
    // emit's priority chain is a one-hot select).
    logic flu, fpu;
    flu = (fu == FU_ALU) || (fu == FU_CTRL) || (fu == FU_CSR) ||
          (fu == FU_AES) || (fu == FU_MULT);
    fpu = (fu == FU_FPU) || (fu == FU_FPUV);
    return ({2{flu}} & WB_FLU) | ({2{fpu}} & WB_FPU) |
           ({2{~flu & ~fpu}} & WB_NONE);
  endfunction
  function automatic logic [4:0] wb_off_of(input logic [3:0] fu,
                                           input g6lc_hyp_pkg::hyp_lat_class_e lat);
    // hyp8: disjoint one-hot compare + masked-OR merge (fu selects exactly
    // one arm of the emit's priority chain).
    logic csr_a, alu, ctrl, mult, fpu;
    csr_a = (fu == FU_CSR) || (fu == FU_AES);
    alu   = (fu == FU_ALU);
    ctrl  = (fu == FU_CTRL);
    mult  = (fu == FU_MULT);
    fpu   = (fu == FU_FPU) || (fu == FU_FPUV);
    // hyp8 r5: LAT_ALU_FULL publishes through the A3 result3_q one cycle
    // later than the A2 result_q, so its FLU_WB reservation sits at +7;
    // LAT_ALU_LOW keeps +6. The +1 makes the gate keep a +2-completion
    // candidate from colliding with a +3 completion on the same port.
    return ({5{csr_a}} & 5'd7) |
           ({5{alu}} & (5'd6 + 5'(lat == g6lc_hyp_pkg::LAT_ALU_FULL))) |
           ({5{ctrl}} & 5'd7) |
           ({5{mult}} & 5'd13) | ({5{fpu}} & 5'(6 + wake_cy(lat)));
  endfunction
  function automatic logic [3:0] gate_of(input logic [3:0] fu,
                                         input logic [6:0] cls,
                                         input g6lc_hyp_pkg::hyp_lat_class_e lat);
    // {lsu, fpu, csr, mult} ready-gates evaluated at take: a gated op
    // cannot be taken, so a spec-broadcast producer can never stall
    // between the IQ grant and the FU input registers.
    // hyp8: four independent bit compares as one concat (each bit of the
    // emit's g vector was written by a disjoint if).
    return { (fu == FU_MULT) && (lat != g6lc_hyp_pkg::LAT_MUL),
             (fu == FU_CSR),
             cls[C_FP] || (fu == FU_FPU) || (fu == FU_FPUV),
             cls[C_LD] };
  endfunction
  function automatic logic div_of(input logic [3:0] fu,
                                  input g6lc_hyp_pkg::hyp_lat_class_e lat);
    return (fu == FU_MULT) && (lat != g6lc_hyp_pkg::LAT_MUL);
  endfunction

  // ----------------------------------------------------------------------
  // svt-stage: begin SEL
  // Candidate eligibility: live, not taken, not cancelled, rdy bits set
  // (real-WB comb hits count this cycle, as the unbanked q_wake), and the
  // registered legality bit.
  // ----------------------------------------------------------------------
  logic [ENTRIES-1:0] rs1_hit, rs2_hit, rs3_hit;   // real WB comb tag hits
  logic [ENTRIES-1:0] ready;
  logic [ENTRIES-1:0] e_cancl;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_cdec
    assign e_cancl[e] = cancelled_mask_i[e_q[e].tid];
  end

  // hyp8: per-(entry, wb-port) compare vectors; each hit is an OR-reduce.
  logic [ENTRIES-1:0][NR_WB-1:0]  ih1, ih2;
  logic [ENTRIES-1:0][NR_FWB-1:0] fh1, fh2, fh3;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_hit
    logic rs1_ok, rs2_ok;
    for (genvar w = 0; w < NR_WB; w++) begin : gen_iw
      assign ih1[e][w] = e_q[e].valid && wb_valid_i[w] &&
          !e_q[e].fpr_rs1 && (e_q[e].prs1 == wb_prd_i[w]);
      assign ih2[e][w] = e_q[e].valid && wb_valid_i[w] &&
          !e_q[e].fpr_rs2 && (e_q[e].prs2 == wb_prd_i[w]);
    end
    for (genvar w = 0; w < NR_FWB; w++) begin : gen_fw
      assign fh1[e][w] = e_q[e].valid && fwb_valid_i[w] &&
          e_q[e].fpr_rs1 && (e_q[e].fprs1 == fwb_prd_i[w]);
      assign fh2[e][w] = e_q[e].valid && fwb_valid_i[w] &&
          e_q[e].fpr_rs2 && (e_q[e].fprs2 == fwb_prd_i[w]);
      assign fh3[e][w] = e_q[e].valid && fwb_valid_i[w] &&
          e_q[e].fpr_rs3 && (e_q[e].fprs3 == fwb_prd_i[w]);
    end
    assign rs1_hit[e] = (|ih1[e]) | (|fh1[e]);
    assign rs2_hit[e] = (|ih2[e]) | (|fh2[e]);
    assign rs3_hit[e] = |fh3[e];
    // hyp8 r5: the select reads the REGISTERED wakeup state only. The
    // real-WB tag match (rs*_hit) now captures into rsX_rdy at the edge
    // and no longer feeds this cycle's ready -- a LAT_NONSPEC consumer
    // wakes one cycle after the writeback instead of in it (conservative:
    // the operand is already architecturally written; recorded +1). Every
    // latency>=2 arm completes through the shifted countdown's registered
    // rdy on the same select cycle as before; the only same-cycle arm
    // left is the distance-1 LAT_ALU_LOW bypass (rsX_low && cnt==0).
    // Each source is its own assign so the two src_done calls are not
    // one statement chained onto ready.
    assign rs1_ok = e_q[e].rs1_rdy ||
        (e_q[e].rs1_spec && e_q[e].rs1_low && (e_q[e].rs1_cnt == '0));
    assign rs2_ok = e_q[e].rs2_rdy ||
        (e_q[e].rs2_spec && e_q[e].rs2_low && (e_q[e].rs2_cnt == '0));
    assign ready[e] = e_q[e].valid && !e_q[e].issued &&
        !e_cancl[e] && legal_i[e] && rs1_ok && rs2_ok && e_q[e].rs3_rdy;
  end

  // hyp8 r5: registered-rdy select with the narrow LAT_ALU_LOW same-cycle
  // arm (speculative countdown at zero, armed from a low-class broadcast).
  // src_done is the rs1_ok / rs2_ok assigns above.

  // ----------------------------------------------------------------------
  // Ranked candidates: oldest ready (no older ready) and next (exactly one
  // older ready), by the bank-local age matrix.
  // ----------------------------------------------------------------------
  logic [ENTRIES-1:0] cand0_oh, cand1_oh;
  // hyp8: older_ready is a vector AND of ready with the transposed age
  // row; "at most one older ready" is the single-bit test x&(x-1)==0.
  logic [ENTRIES-1:0][ENTRIES-1:0] older_t;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_oldert
    for (genvar o = 0; o < ENTRIES; o++)
      assign older_t[e][o] = older_q[o][e];
  end
  logic [ENTRIES-1:0][ENTRIES-1:0] ort;
  // Exactly one older ready, without a subtract. ort & (ort-1) is an
  // adder on the candidate cone. Each bit's "I am the only one" mask
  // is a constant.
  logic [ENTRIES-1:0] one_older;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_one
    logic [ENTRIES-1:0] only;
    for (genvar b = 0; b < ENTRIES; b++) begin : gen_b
      assign only[b] = ort[e][b] && !(|(ort[e] & ~((ENTRIES'(1) << b))));
    end
    assign one_older[e] = |only;
  end
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_cand
    assign ort[e] = ready & older_t[e];
    assign cand0_oh[e] = ready[e] && (ort[e] == '0);
    assign cand1_oh[e] = ready[e] && one_older[e];
  end

  // hyp8: the per-entry winner record is a packed struct masked by the
  // one-hot and merged by a balanced OR tree (independent-LHS / log-depth
  // form), not a serial |= accumulator.
  typedef struct packed {
    logic [EW-1:0]         i;
    logic [TID_W-1:0]      tid;
    logic                  fp;
    logic                  spec;
    logic [1:0]            spec_ab;
    logic [1:0][TID_W-1:0] ptid;
    logic [3:0]            fu;
    logic                  fluin;
    logic [1:0]            wbport;
    logic [4:0]            wboff;
    logic [3:0]            gate;
    logic                  div;
    logic                  port0;
  } crec_t;
  localparam int unsigned ELV = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;

  crec_t [ENTRIES-1:0] cterm0, cterm1;
  logic [ELV:0][ENTRIES-1:0][$bits(crec_t)-1:0] cr0, cr1;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_cterm
    assign cterm0[e] = '{
      i: EW'(e), tid: e_q[e].tid, fp: e_q[e].cls[C_FP],
      spec: {e_q[e].rs3_spec, e_q[e].rs2_spec, e_q[e].rs1_spec} |
            {e_q[e].rs1_spec | e_q[e].rs2_spec | e_q[e].rs3_spec,
             e_q[e].rs1_spec | e_q[e].rs2_spec | e_q[e].rs3_spec,
             e_q[e].rs1_spec | e_q[e].rs2_spec | e_q[e].rs3_spec},
      spec_ab: {e_q[e].rs2_spec, e_q[e].rs1_spec},
      ptid: {e_q[e].rs2_ptid, e_q[e].rs1_ptid},
      fu: e_q[e].fu,
      fluin: flu_in_of(e_q[e].fu),
      wbport: wb_port_of(e_q[e].fu),
      wboff: wb_off_of(e_q[e].fu, e_q[e].lat),
      gate: gate_of(e_q[e].fu, e_q[e].cls, e_q[e].lat),
      div: div_of(e_q[e].fu, e_q[e].lat),
      // serial classes share the single port-0 operand/result path
      port0: e_q[e].cls[C_CSR] | e_q[e].cls[C_AMO] | e_q[e].cls[C_CVXI]};
    assign cterm1[e] = cterm0[e];
    assign cr0[0][e] = {$bits(crec_t){cand0_oh[e]}} & cterm0[e];
    assign cr1[0][e] = {$bits(crec_t){cand1_oh[e]}} & cterm1[e];
  end
  for (genvar l = 0; l < ELV; l++) begin : gen_clvl
    for (genvar i = 0; i < ENTRIES; i++) begin : gen_cor
      if (i < ((ENTRIES + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
        if ((2 * i + 1) < ((ENTRIES + (1 << l) - 1) >> l)) begin : gen_pair
          assign cr0[l+1][i] = cr0[l][2*i] | cr0[l][2*i+1];
          assign cr1[l+1][i] = cr1[l][2*i] | cr1[l][2*i+1];
        end else begin : gen_odd
          assign cr0[l+1][i] = cr0[l][2*i];
          assign cr1[l+1][i] = cr1[l][2*i];
        end
      end else begin : gen_pad
        assign cr0[l+1][i] = '0;
        assign cr1[l+1][i] = '0;
      end
    end
  end
  crec_t crec0, crec1;
  assign crec0 = crec_t'(cr0[ELV][0]);
  assign crec1 = crec_t'(cr1[ELV][0]);
  assign cand_v_o[0]     = |cand0_oh;
  assign cand_v_o[1]     = |cand1_oh;
  assign cand_i_o[0]     = crec0.i;     assign cand_i_o[1]     = crec1.i;
  assign cand_tid_o[0]   = crec0.tid;   assign cand_tid_o[1]   = crec1.tid;
  assign cand_fp_o[0]    = crec0.fp;    assign cand_fp_o[1]    = crec1.fp;
  assign cand_spec_o[0]  = crec0.spec; assign cand_spec_o[1]  = crec1.spec;
  assign cand_spec_ab_o[0] = crec0.spec_ab;
  assign cand_spec_ab_o[1] = crec1.spec_ab;
  assign cand_ptid_o[0]  = crec0.ptid;  assign cand_ptid_o[1]  = crec1.ptid;
  assign cand_fu_o[0]    = crec0.fu;    assign cand_fu_o[1]    = crec1.fu;
  assign cand_fluin_o[0] = crec0.fluin; assign cand_fluin_o[1] = crec1.fluin;
  assign cand_wbport_o[0] = crec0.wbport;
  assign cand_wbport_o[1] = crec1.wbport;
  assign cand_wboff_o[0] = crec0.wboff; assign cand_wboff_o[1] = crec1.wboff;
  assign cand_gate_o[0]  = crec0.gate;  assign cand_gate_o[1]  = crec1.gate;
  assign cand_div_o[0]   = crec0.div;   assign cand_div_o[1]   = crec1.div;
  assign cand_port0_o[0] = crec0.port0; assign cand_port0_o[1] = crec1.port0;

  // ----------------------------------------------------------------------
  // Producer broadcast at take (local same-cycle + into the xbar): the taken
  // entry's destination tag and its class countdown.
  // ----------------------------------------------------------------------
  // Take-port entry select shared by broadcast and the take mark.
  logic [NTAKE-1:0][EW-1:0] take_ei;
  for (genvar p = 0; p < NTAKE; p++) begin : gen_take_ei
    assign take_ei[p] = take_cand_i[p] ? cand_i_o[1] : cand_i_o[0];
  end
  // hyp8: per-entry broadcast payload packed once; each take port gathers
  // it with a one-hot (take_ei decode) masked-OR pairwise tree instead of
  // a fat dynamic-index record read. e_cy0 gates both the valid and every
  // payload bit (a LAT_NONSPEC producer never broadcasts: its completion
  // time is unknown, so an armed consumer would read a stale operand).
  localparam int unsigned BCW = 1 + PRF_W + FPRF_W + WAKE_W + TID_W + 1 + 1;
  // Hyp8 IqSpecWakeup is 0. Turning this arm on (analyze-wake-r1/r2)
  // left plain reg-to-reg at 30.15 but raised the SEL reg-to-out
  // candidate path from 32.90 to 70.7, which the arbiter flops. The
  // countdown math stays in the folded arm: take_idx (not the live
  // cand one-hot) and no low broadcast for a port!=0 ALU-low (ALU2
  // has no distance-1 forward). Real writeback still wakes through
  // rs*_hit, one cycle after the result is on the bus.
  if (1'b0) begin : gen_spec_bcast
  logic [ENTRIES-1:0][BCW-1:0] e_bc;
  logic [ENTRIES-1:0]          e_cy0;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_ebc
    logic cy0, alu_b, lo_b;
    logic [WAKE_W-1:0] cnt_b;
    always_comb begin
      unique case (e_q[e].lat)
        g6lc_hyp_pkg::LAT_ALU_LOW: begin
          cy0 = 1'b1; cnt_b = '0; alu_b = 1'b1; lo_b = 1'b1;
        end
        g6lc_hyp_pkg::LAT_ALU_FULL: begin
          cy0 = 1'b1; cnt_b = WAKE_W'(1); alu_b = 1'b1; lo_b = 1'b0;
        end
        g6lc_hyp_pkg::LAT_LOAD: begin
          cy0 = 1'b1; cnt_b = WAKE_W'(4); alu_b = 1'b0; lo_b = 1'b0;
        end
        g6lc_hyp_pkg::LAT_MUL: begin
          cy0 = 1'b1; cnt_b = WAKE_W'(6); alu_b = 1'b0; lo_b = 1'b0;
        end
        g6lc_hyp_pkg::LAT_FP_FIXED: begin
          cy0 = 1'b1; cnt_b = WAKE_W'(8); alu_b = 1'b0; lo_b = 1'b0;
        end
        default: begin
          cy0 = 1'b0; cnt_b = '0; alu_b = 1'b0; lo_b = 1'b0;
        end
      endcase
    end
    assign e_cy0[e] = cy0;
    assign e_bc[e]  = {e_q[e].is_fprd, e_q[e].prd, e_q[e].fprd,
                       cnt_b, e_q[e].tid, alu_b, lo_b};
  end
  for (genvar p = 0; p < NTAKE; p++) begin : gen_bcast
    logic [ENTRIES-1:0] mcy;
    for (genvar e = 0; e < ENTRIES; e++) begin : gen_mcy
      assign mcy[e] = take_v_i[p] && (take_idx_i[p] == EW'(e)) && e_cy0[e] &&
                      !((p != 0) && (e_q[e].lat == g6lc_hyp_pkg::LAT_ALU_LOW));
    end
    assign bcast_v_o[p] = |mcy;
    localparam int unsigned BLV = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
    logic [BLV:0][ENTRIES-1:0][BCW-1:0] bt;
    for (genvar e = 0; e < ENTRIES; e++) begin : gen_bt0
      assign bt[0][e] = {BCW{mcy[e]}} & e_bc[e];
    end
    for (genvar l = 0; l < BLV; l++) begin : gen_lvl
      for (genvar i = 0; i < ENTRIES; i++) begin : gen_or
        if (i < ((ENTRIES + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
          if ((2 * i + 1) < ((ENTRIES + (1 << l) - 1) >> l)) begin : gen_pair
            assign bt[l+1][i] = bt[l][2*i] | bt[l][2*i+1];
          end else begin : gen_odd
            assign bt[l+1][i] = bt[l][2*i];
          end
        end else begin : gen_pad
          assign bt[l+1][i] = '0;
        end
      end
    end
    assign {bcast_fp_o[p], bcast_prd_o[p], bcast_fprd_o[p], bcast_cnt_o[p],
            bcast_tid_o[p], bcast_alu_o[p], bcast_lo_o[p]} = bt[BLV][0];
  end
  end else begin : gen_nospec_bcast
    for (genvar p = 0; p < NTAKE; p++) begin : gen_z
      assign bcast_v_o[p]    = 1'b0;
      assign bcast_fp_o[p]   = 1'b0;
      assign bcast_prd_o[p]  = '0;
      assign bcast_fprd_o[p] = '0;
      assign bcast_cnt_o[p]  = '0;
      assign bcast_tid_o[p]  = '0;
      assign bcast_alu_o[p]  = 1'b0;
      assign bcast_lo_o[p]   = 1'b0;
    end
  end

  // ----------------------------------------------------------------------
  // Next state: allocation, wakeup, speculative countdown, replay re-arm,
  // take/ack bookkeeping, cancel, flush.
  // ----------------------------------------------------------------------
  // Wake events feeding the spec countdown: local same-cycle broadcast +
  // the registered cross-bank tags.
  localparam int unsigned NWAKE = NTAKE + NXW;
  logic [NWAKE-1:0]           wk_v;
  logic [NWAKE-1:0][PRF_W-1:0] wk_prd;
  logic [NWAKE-1:0][FPRF_W-1:0] wk_fprd;
  logic [NWAKE-1:0]           wk_fp;
  logic [NWAKE-1:0][WAKE_W-1:0] wk_cnt;
  logic [NWAKE-1:0][TID_W-1:0] wk_tid;
  logic [NWAKE-1:0]           wk_alu;
  logic [NWAKE-1:0]           wk_lo;

  for (genvar k = 0; k < NTAKE; k++) begin : gen_wk_l
    assign wk_v[k]    = bcast_v_o[k];
    assign wk_fp[k]   = bcast_fp_o[k];
    assign wk_prd[k]  = bcast_prd_o[k];
    assign wk_fprd[k] = bcast_fprd_o[k];
    assign wk_cnt[k]  = bcast_cnt_o[k];
    assign wk_tid[k]  = bcast_tid_o[k];
    assign wk_alu[k]  = bcast_alu_o[k];
    assign wk_lo[k]   = bcast_lo_o[k];
  end
  for (genvar k = 0; k < NXW; k++) begin : gen_wk_x
    assign wk_v[NTAKE+k]    = xw_v_i[k];
    assign wk_fp[NTAKE+k]   = xw_fp_i[k];
    assign wk_prd[NTAKE+k]  = xw_prd_i[k];
    assign wk_fprd[NTAKE+k] = xw_fprd_i[k];
    assign wk_cnt[NTAKE+k]  = xw_cnt_i[k];
    assign wk_tid[NTAKE+k]  = xw_tid_i[k];
    assign wk_alu[NTAKE+k]  = xw_alu_i[k];
    assign wk_lo[NTAKE+k]   = xw_lo_i[k];
  end

  // Free-slot selection for up to NLANES allocations, in lane order.
  // A slot accepted this cycle is not valid until the next edge, so the
  // pick also hides pend_slot_q. Both lanes are chosen here, together.
  logic [NLANES-1:0][ENTRIES-1:0] pend_slot_d;
  logic [NLANES-1:0][ENTRIES-1:0] pend_slot_q;
  iqb_entry_t [NLANES-1:0]        pend_rec_q;
  logic [ENTRIES-1:0]             pend_busy;
  logic [ENTRIES-1:0]             pend_wb1, pend_wb2, pend_wb3;
  logic [ENTRIES-1:0] free_mask;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_freem
    logic [NLANES-1:0] pb;
    for (genvar p = 0; p < NLANES; p++) begin : gen_pb
      assign pb[p] = pend_slot_q[p][e];
    end
    assign pend_busy[e] = |pb;
    assign free_mask[e] = ~e_q[e].valid & ~pend_busy[e];
  end

  // svt-stage: begin ALC
  // Same-cycle ack for every lane. The entry record is the registered
  // pend below, so this scan does not chain into the wakeup mux.
  logic [NLANES-1:0][ENTRIES-1:0] slotv;
  always_comb begin
    automatic logic [ENTRIES-1:0] taken;
    automatic logic [ENTRIES-1:0] lone;
    taken = '0;
    for (int unsigned p = 0; p < NLANES; p++) begin
      lone = (free_mask & ~taken) & (~(free_mask & ~taken) + 1'b1);
      alloc_ack_o[p]  = alloc_i[p] && |lone;
      alloc_slot_o[p] = (|lone) ? EW'($countones(lone - 1'b1)) : '0;
      slotv[p] = lone;
      // A lane not steered to this bank takes nothing: without the
      // alloc_i gate its pick would still mask the lowest free slot out
      // of the scan for later lanes, and a bank that fits only lane 1
      // would ack a partial group (hyp8-osbi-scalar-r7 mechanism).
      taken |= lone & {ENTRIES{alloc_i[p]}};
    end
  end
  for (genvar p = 0; p < NLANES; p++) begin : gen_pendd
    for (genvar e = 0; e < ENTRIES; e++) begin : gen_pende
      assign pend_slot_d[p][e] = alloc_i[p] && slotv[p][e];
    end
  end
  // svt-stage: end ALC
  // svt-stage: class ALC decision

  // ----------------------------------------------------------------------
  // hyp8: next state is written per entry (one always_comb per e, its
  // phases in the emit's order) and the age matrix per cell, so each LHS
  // is billed as an independent cone instead of one serial sweep.
  // Wakeup arms are per-(entry, source) compare vectors resolved by a
  // downward-prefix highest-set + popcount index (the last-hit-wins
  // priority of the emit's serial k-loop).
  // ----------------------------------------------------------------------
  // Highest set bit, on a literal 32-bit word. Shifts of a
  // NWAKE-wide vector do not fold. NWAKE is 10 at the module
  // default and 18 in g6lc_iq (2 issue ports, 8 banks).

  logic [ENTRIES-1:0] e_alu_cons;
  logic [ENTRIES-1:0][NWAKE-1:0] wk_ok, wk_h1, wk_h2, wk_h3, wk_h1a, wk_h2a;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_wkh
    assign e_alu_cons[e] = (e_q[e].lat == g6lc_hyp_pkg::LAT_ALU_LOW) ||
                           (e_q[e].lat == g6lc_hyp_pkg::LAT_ALU_FULL);
    for (genvar k = 0; k < NWAKE; k++) begin : gen_wkk
      logic h1i;
      logic h1f;
      logic h2i;
      logic h2f;
      assign h1i = !e_q[e].fpr_rs1 && !wk_fp[k] && (e_q[e].prs1 == wk_prd[k]);
      assign h1f = e_q[e].fpr_rs1 && wk_fp[k] && (e_q[e].fprs1 == wk_fprd[k]);
      assign h2i = !e_q[e].fpr_rs2 && !wk_fp[k] && (e_q[e].prs2 == wk_prd[k]);
      assign h2f = e_q[e].fpr_rs2 && wk_fp[k] && (e_q[e].fprs2 == wk_fprd[k]);
      assign wk_ok[e][k] = wk_v[k] && !(wk_lo[k] && !e_alu_cons[e]);
      assign wk_h1[e][k] = wk_ok[e][k] && !e_q[e].rs1_rdy &&
          !e_q[e].rs1_spec && (h1i || h1f);
      assign wk_h2[e][k] = wk_ok[e][k] && !e_q[e].rs2_rdy &&
          !e_q[e].rs2_spec && (h2i || h2f);
      assign wk_h3[e][k] = wk_ok[e][k] && !e_q[e].rs3_rdy &&
          !e_q[e].rs3_spec && e_q[e].fpr_rs3 && wk_fp[k] &&
          (e_q[e].fprs3 == wk_fprd[k]);
      assign wk_h1a[e][k] = wk_h1[e][k] && wk_alu[k];
      assign wk_h2a[e][k] = wk_h2[e][k] && wk_alu[k];
    end
  end
  // hyp8: highest-set is two levels of constant-width prefix. Groups of
  // four bits resolve in parallel (shift 1, then 2). The highest live
  // group is an 8-bit prefix, which covers NWAKE up to 32; groups past
  // NWAKE stay zero. The winner's countdown, tid, and low bit are that
  // group's masked OR, selected by the group one-hot. This is the same
  // bit as x & ~prefix(x>>1): the highest index wins. It is not a
  // per-bit scan of the issued word.
  logic [ENTRIES-1:0][WAKE_W-1:0] wk_c1, wk_c2, wk_c3;
  logic [ENTRIES-1:0][TID_W-1:0] wk_t1, wk_t2;
  logic [ENTRIES-1:0]          wk_l1, wk_l2;
  // Hit and payload snapshot. The priority resolve reads these flops,
  // so the tag compare and the countdown mux are different cycles.
  // LAT_ALU_LOW still arms from the combo hits in the broadcast cycle.
  logic [ENTRIES-1:0][NWAKE-1:0] h1_q;
  logic [ENTRIES-1:0][NWAKE-1:0] h2_q;
  logic [ENTRIES-1:0][NWAKE-1:0] h3_q;
  logic [ENTRIES-1:0][NWAKE-1:0] h1a_q;
  logic [ENTRIES-1:0][NWAKE-1:0] h2a_q;
  logic [NWAKE-1:0][WAKE_W-1:0]  cnt_q;
  logic [NWAKE-1:0][TID_W-1:0]   tid_q;
  logic [NWAKE-1:0]              lo_q;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_wki
    for (genvar s = 0; s < 5; s++) begin : gen_src
      logic [NWAKE-1:0] hit;
      logic [7:0][3:0]  nib;
      logic [7:0][3:0]  one;
      logic [7:0]       gany;
      logic [7:0]       g0;
      logic [7:0]       g1;
      logic [7:0]       g2;
      logic [7:0]       g3;
      logic [7:0]       gwin;

      if (s == 0)      assign hit = h1_q[e];
      else if (s == 1) assign hit = h2_q[e];
      else if (s == 2) assign hit = h3_q[e];
      else if (s == 3) assign hit = h1a_q[e];
      else             assign hit = h2a_q[e];

      for (genvar g = 0; g < 8; g++) begin : gen_g
        logic [3:0] s0;
        logic [3:0] s1;
        for (genvar b = 0; b < 4; b++) begin : gen_b
          if ((4 * g + b) < NWAKE) begin : gen_ib
            assign nib[g][b] = hit[4 * g + b];
          end else begin : gen_zb
            assign nib[g][b] = 1'b0;
          end
        end
        assign s0     = nib[g] >> 1;
        assign s1     = s0 | (s0 >> 1);
        assign one[g] = nib[g] & ~s1;
        assign gany[g] = |nib[g];
      end

      assign g0   = gany >> 1;
      assign g1   = g0 | (g0 >> 1);
      assign g2   = g1 | (g1 >> 2);
      assign g3   = g2 | (g2 >> 4);
      assign gwin = gany & ~g3;

      if (s < 3) begin : gen_cnt
        logic [7:0][WAKE_W-1:0] gc;
        logic [3:0][WAKE_W-1:0] cp;
        logic [1:0][WAKE_W-1:0] cq;
        for (genvar g = 0; g < 8; g++) begin : gen_gc
          logic [3:0][WAKE_W-1:0] nb;
          logic [WAKE_W-1:0] n0;
          logic [WAKE_W-1:0] n1;
          for (genvar b = 0; b < 4; b++) begin : gen_nb
            if ((4 * g + b) < NWAKE) begin : gen_ib
              assign nb[b] = {WAKE_W{one[g][b]}} & cnt_q[4 * g + b];
            end else begin : gen_zb
              assign nb[b] = '0;
            end
          end
          assign n0   = nb[0] | nb[1];
          assign n1   = nb[2] | nb[3];
          assign gc[g] = n0 | n1;
        end
        for (genvar i = 0; i < 4; i++) begin : gen_cp
          assign cp[i] = ({WAKE_W{gwin[2 * i]}} & gc[2 * i]) |
                         ({WAKE_W{gwin[2 * i + 1]}} & gc[2 * i + 1]);
        end
        assign cq[0] = cp[0] | cp[1];
        assign cq[1] = cp[2] | cp[3];
        if (s == 0)      assign wk_c1[e] = cq[0] | cq[1];
        else if (s == 1) assign wk_c2[e] = cq[0] | cq[1];
        else             assign wk_c3[e] = cq[0] | cq[1];
      end

      if (s < 2) begin : gen_lo
        logic [7:0] gl;
        logic [3:0] lp;
        logic [1:0] lq;
        for (genvar g = 0; g < 8; g++) begin : gen_gl
          logic [3:0] lb;
          logic l0;
          logic l1;
          for (genvar b = 0; b < 4; b++) begin : gen_lb
            if ((4 * g + b) < NWAKE) begin : gen_ib
              assign lb[b] = one[g][b] & lo_q[4 * g + b];
            end else begin : gen_zb
              assign lb[b] = 1'b0;
            end
          end
          assign l0    = lb[0] | lb[1];
          assign l1    = lb[2] | lb[3];
          assign gl[g] = l0 | l1;
        end
        for (genvar i = 0; i < 4; i++) begin : gen_lp
          assign lp[i] = (gwin[2 * i] & gl[2 * i]) |
                         (gwin[2 * i + 1] & gl[2 * i + 1]);
        end
        assign lq[0] = lp[0] | lp[1];
        assign lq[1] = lp[2] | lp[3];
        if (s == 0) assign wk_l1[e] = lq[0] | lq[1];
        else        assign wk_l2[e] = lq[0] | lq[1];
      end

      if (s >= 3) begin : gen_tid
        logic [7:0][TID_W-1:0] gt;
        logic [3:0][TID_W-1:0] tp;
        logic [1:0][TID_W-1:0] tq;
        for (genvar g = 0; g < 8; g++) begin : gen_gt
          logic [3:0][TID_W-1:0] nb;
          logic [TID_W-1:0] n0;
          logic [TID_W-1:0] n1;
          for (genvar b = 0; b < 4; b++) begin : gen_nb
            if ((4 * g + b) < NWAKE) begin : gen_ib
              assign nb[b] = {TID_W{one[g][b]}} & tid_q[4 * g + b];
            end else begin : gen_zb
              assign nb[b] = '0;
            end
          end
          assign n0    = nb[0] | nb[1];
          assign n1    = nb[2] | nb[3];
          assign gt[g] = n0 | n1;
        end
        for (genvar i = 0; i < 4; i++) begin : gen_tp
          assign tp[i] = ({TID_W{gwin[2 * i]}} & gt[2 * i]) |
                         ({TID_W{gwin[2 * i + 1]}} & gt[2 * i + 1]);
        end
        assign tq[0] = tp[0] | tp[1];
        assign tq[1] = tp[2] | tp[3];
        if (s == 3) assign wk_t1[e] = tq[0] | tq[1];
        else        assign wk_t2[e] = tq[0] | tq[1];
      end
    end
  end

  // Newcomer record per alloc lane, incl. the same-cycle WB capture.
  iqb_entry_t [NLANES-1:0] newrec;
  logic [NLANES-1:0][ENTRIES-1:0] alloc_hit_p;   // lane p takes entry e
  logic [ENTRIES-1:0]             alloc_hit;
  logic [ENTRIES-1:0][NLANES-1:0] slott;          // slott[e][p] = pend_slot_q[p][e]
  logic [ENTRIES-1:0][NLANES-1:0] lane_lt;        // lane_lt[r][p]: an earlier lane's slot hit r
  logic [ENTRIES-1:0][ENTRIES-1:0] earlier;

  for (genvar e = 0; e < ENTRIES; e++) begin : gen_slot_t
    for (genvar p = 0; p < NLANES; p++) begin : gen_slot_tp
      assign slott[e][p] = pend_slot_q[p][e];
      if (p == 0) begin : gen_p0
        assign lane_lt[e][p] = 1'b0;
      end else if (p == 1) begin : gen_p1
        assign lane_lt[e][p] = slott[e][0];
      end else begin : gen_pN
        assign lane_lt[e][p] = |slott[e][p-1:0];
      end
    end
    assign alloc_hit[e] = pend_busy[e];
    for (genvar r = 0; r < ENTRIES; r++) begin : gen_earlier
      logic [NLANES-1:0] lt;
      for (genvar p = 0; p < NLANES; p++)
        assign lt[p] = slott[e][p] && lane_lt[r][p];
      assign earlier[r][e] = |lt;
    end
  end

  for (genvar p = 0; p < NLANES; p++) begin : gen_newrec
    logic [NR_WB-1:0]  aih1, aih2;
    logic [NR_FWB-1:0] afh1, afh2, afh3;
    for (genvar w = 0; w < NR_WB; w++) begin : gen_aw
      assign aih1[w] = wb_valid_i[w] && !alloc_fpr_rs1_i[p] &&
                       (alloc_prs1_i[p] == wb_prd_i[w]);
      assign aih2[w] = wb_valid_i[w] && !alloc_fpr_rs2_i[p] &&
                       (alloc_prs2_i[p] == wb_prd_i[w]);
    end
    for (genvar w = 0; w < NR_FWB; w++) begin : gen_afw
      assign afh1[w] = fwb_valid_i[w] && alloc_fpr_rs1_i[p] &&
                       (alloc_fprs1_i[p] == fwb_prd_i[w]);
      assign afh2[w] = fwb_valid_i[w] && alloc_fpr_rs2_i[p] &&
                       (alloc_fprs2_i[p] == fwb_prd_i[w]);
      assign afh3[w] = fwb_valid_i[w] && alloc_fpr_rs3_i[p] &&
                       (alloc_fprs3_i[p] == fwb_prd_i[w]);
    end
    assign newrec[p] = '{
      valid: 1'b1, issued: 1'b0, tid: alloc_tid_i[p], hart: alloc_hart_i[p],
      cls: alloc_cls_i[p], may_bypass: alloc_may_bypass_i[p],
      lat: alloc_lat_i[p], is_fprd: alloc_is_fprd_i[p],
      prs1: alloc_prs1_i[p], prs2: alloc_prs2_i[p], prd: alloc_prd_i[p],
      fprs1: alloc_fprs1_i[p], fprs2: alloc_fprs2_i[p],
      fprs3: alloc_fprs3_i[p], fprd: alloc_fprd_i[p],
      fpr_rs1: alloc_fpr_rs1_i[p], fpr_rs2: alloc_fpr_rs2_i[p],
      fpr_rs3: alloc_fpr_rs3_i[p],
      rs1_rdy: alloc_rs1_rdy_i[p] | (|aih1) | (|afh1),
      rs2_rdy: alloc_rs2_rdy_i[p] | (|aih2) | (|afh2),
      rs3_rdy: alloc_rs3_rdy_i[p] | (|afh3),
      rs1_spec: 1'b0, rs2_spec: 1'b0, rs3_spec: 1'b0,
      rs1_low: 1'b0, rs2_low: 1'b0,
      rs1_cnt: '0, rs2_cnt: '0, rs3_cnt: '0,
      rs1_ptid: '0, rs2_ptid: '0,
      fu: alloc_fu_i[p]};
    for (genvar e = 0; e < ENTRIES; e++) begin : gen_ahp
      assign alloc_hit_p[p][e] = pend_slot_q[p][e];
    end
  end

  // Payload and slot captured with the ack. The entry becomes valid on
  // the following edge, after dispatch has already moved on.
  always_ff @(posedge clk_i or negedge rst_ni) begin : pend_regs
    if (!rst_ni || flush_i) begin
      pend_slot_q <= '0;
      pend_rec_q  <= '0;
    end else begin
      pend_slot_q <= pend_slot_d;
      pend_rec_q  <= newrec;
    end
  end

  // Writeback in the cycle the entry is still pending. The ack-cycle
  // hit is already in pend_rec_q.rs*_rdy; this cycle's tag is not.
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_pwb
    logic [NLANES-1:0] w1, w2, w3;
    for (genvar p = 0; p < NLANES; p++) begin : gen_pl
      logic [NR_WB-1:0] i1, i2;
      logic [NR_FWB-1:0] f1, f2, f3;
      for (genvar w = 0; w < NR_WB; w++) begin : gen_iw
        assign i1[w] = wb_valid_i[w] && !pend_rec_q[p].fpr_rs1 &&
                       (pend_rec_q[p].prs1 == wb_prd_i[w]);
        assign i2[w] = wb_valid_i[w] && !pend_rec_q[p].fpr_rs2 &&
                       (pend_rec_q[p].prs2 == wb_prd_i[w]);
      end
      for (genvar w = 0; w < NR_FWB; w++) begin : gen_fw
        assign f1[w] = fwb_valid_i[w] && pend_rec_q[p].fpr_rs1 &&
                       (pend_rec_q[p].fprs1 == fwb_prd_i[w]);
        assign f2[w] = fwb_valid_i[w] && pend_rec_q[p].fpr_rs2 &&
                       (pend_rec_q[p].fprs2 == fwb_prd_i[w]);
        assign f3[w] = fwb_valid_i[w] && pend_rec_q[p].fpr_rs3 &&
                       (pend_rec_q[p].fprs3 == fwb_prd_i[w]);
      end
      assign w1[p] = pend_slot_q[p][e] && ((|i1) || (|f1));
      assign w2[p] = pend_slot_q[p][e] && ((|i2) || (|f2));
      assign w3[p] = pend_slot_q[p][e] && (|f3);
    end
    assign pend_wb1[e] = |w1;
    assign pend_wb2[e] = |w2;
    assign pend_wb3[e] = |w3;
  end

  // Per-entry ack/take decode vectors (genvar compare + OR-reduce).
  logic [ENTRIES-1:0] ack_any, take_any, cancl;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_decode
    // hyp8: the take mark reads the candidate one-hots selected by
    // take_cand_i -- no index round-trip through cand_i_o/take_ei.
    logic [NTAKE-1:0] ak, tk;
    for (genvar p = 0; p < NTAKE; p++) begin : gen_p
      assign ak[p] = ack_v_i[p] && (ack_idx_i[p] == EW'(e));
      assign tk[p] = take_v_i[p] && (take_idx_i[p] == EW'(e));
    end
    assign ack_any[e]  = |ak;
    assign take_any[e] = |tk;
    assign cancl[e]    = e_q[e].valid && e_cancl[e];
  end

  // hyp8: next state written as one continuous assign per field of e_d[e]
  // so every field is billed as an independent LHS cone. Field next-values
  // are single expressions that preserve the emit's phase order:
  // cancel/ack drop -> take mark -> WB capture -> wake arm -> countdown
  // tick -> replay re-arm -> allocation -> flush.
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_upd
    logic        tick1, tick2, tick3;
    logic        fast1, fast2;
    logic        pipe1, pipe2, pipe3;
    logic        z1, z2, z3;
    logic        arm1, arm2, arm3;
    logic        ref_arm1, ref_arm2, ref_arm3;
    logic        r1r, r2r, r3r, r1s, r2s, r3s, r1l, r2l;
    logic [WAKE_W-1:0] r1c, r2c, r3c;
    logic [WAKE_W-1:0] ref_add1, ref_add2, ref_add3;
    logic [TID_W-1:0] r1p, r2p;
    logic [TID_W-1:0] ft1, ft2;
    iqb_entry_t  nrec_sel;
    // 32-slot pad covers NWAKE up to 32 (module default 10, g6lc_iq 18).
    logic [31:0][TID_W-1:0] lf1;
    logic [31:0][TID_W-1:0] lf2;
    logic [31:0][TID_W-1:0] lf1_q;
    logic [31:0][TID_W-1:0] lf2_q;
    logic [15:0][TID_W-1:0] t1a;
    logic [15:0][TID_W-1:0] t1b;
    logic [7:0][TID_W-1:0] t2a;
    logic [7:0][TID_W-1:0] t2b;
    logic [3:0][TID_W-1:0] t3a;
    logic [3:0][TID_W-1:0] t3b;
    logic [1:0][TID_W-1:0] t4a;
    logic [1:0][TID_W-1:0] t4b;

    assign tick1 = e_q[e].valid && e_q[e].rs1_spec && !e_q[e].rs1_rdy;
    assign tick2 = e_q[e].valid && e_q[e].rs2_spec && !e_q[e].rs2_rdy;
    assign tick3 = e_q[e].valid && e_q[e].rs3_spec && !e_q[e].rs3_rdy;
    // Same-cycle arm only when every match is ALU-low. Echoes of one
    // broadcast share lo and tid, so the masked OR is that producer.
    // The tag compare is the previous cycle (h*_q, lo_q). spec, low,
    // count, and ptid all update on this cycle, with the tid OR.
    assign fast1 = e_q[e].valid && (|(h1_q[e] & lo_q)) && !(|(h1_q[e] & ~lo_q));
    assign fast2 = e_q[e].valid && (|(h2_q[e] & lo_q)) && !(|(h2_q[e] & ~lo_q));
    // Non-low resolve is the registered hit from the previous cycle.
    // Capturing one count earlier puts rdy on the original publish cycle.
    assign pipe1 = e_q[e].valid && (|h1_q[e]) && !fast1;
    assign pipe2 = e_q[e].valid && (|h2_q[e]) && !fast2;
    assign pipe3 = e_q[e].valid && (|h3_q[e]);
    assign z1 = pipe1 && (wk_c1[e] == '0);
    assign z2 = pipe2 && (wk_c2[e] == '0);
    assign z3 = pipe3 && (wk_c3[e] == '0);
    assign arm1 = fast1 || pipe1;
    assign arm2 = fast2 || pipe2;
    assign arm3 = pipe3;
    assign ref_arm1 = fast1 || (pipe1 && !e_q[e].rs1_spec);
    assign ref_arm2 = fast2 || (pipe2 && !e_q[e].rs2_spec);
    assign ref_arm3 = pipe3 && !e_q[e].rs3_spec;
    assign ref_add1 = fast1 ? '0 : (wk_c1[e] + (wk_l1[e] ? WAKE_W'(0) : WAKE_W'(1)));
    assign ref_add2 = fast2 ? '0 : (wk_c2[e] + (wk_l2[e] ? WAKE_W'(0) : WAKE_W'(1)));
    assign ref_add3 = wk_c3[e] + WAKE_W'(1);

    // newcomer record select: disjoint slot one-hots -> masked OR. hyp8:
    // unrolled pairwise OR (log depth) instead of a serial accumulate.
    always_comb begin : sel_nrec
      iqb_entry_t acc [NLANES+1];
      acc[0] = '0;
      for (int unsigned p = 0; p < NLANES; p++)
        acc[p+1] = acc[p] | ({($bits(iqb_entry_t)){alloc_hit_p[p][e]}}
                             & pend_rec_q[p]);
      nrec_sel = acc[NLANES];
    end

    // -- dynamic fields (single-expression next values)
    // Literal pairwise OR. A genvar index of the running tree
    // is billed as a variable select.
    for (genvar k = 0; k < 32; k++) begin : gen_lf
      if (k < NWAKE) begin : gen_k
        assign lf1[k] = {TID_W{wk_h1[e][k] & wk_lo[k]}} & wk_tid[k];
        assign lf2[k] = {TID_W{wk_h2[e][k] & wk_lo[k]}} & wk_tid[k];
      end else begin : gen_z
        assign lf1[k] = '0;
        assign lf2[k] = '0;
      end
    end
    // Compare cycle ends here. The tid OR and the arm share the next cycle.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni || flush_i) lf1_q <= '0;
      else                    lf1_q <= lf1;
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni || flush_i) lf2_q <= '0;
      else                    lf2_q <= lf2;
    end
    assign t1a[0] = lf1_q[0] | lf1_q[1];
    assign t1b[0] = lf2_q[0] | lf2_q[1];
    assign t1a[1] = lf1_q[2] | lf1_q[3];
    assign t1b[1] = lf2_q[2] | lf2_q[3];
    assign t1a[2] = lf1_q[4] | lf1_q[5];
    assign t1b[2] = lf2_q[4] | lf2_q[5];
    assign t1a[3] = lf1_q[6] | lf1_q[7];
    assign t1b[3] = lf2_q[6] | lf2_q[7];
    assign t1a[4] = lf1_q[8] | lf1_q[9];
    assign t1b[4] = lf2_q[8] | lf2_q[9];
    assign t1a[5] = lf1_q[10] | lf1_q[11];
    assign t1b[5] = lf2_q[10] | lf2_q[11];
    assign t1a[6] = lf1_q[12] | lf1_q[13];
    assign t1b[6] = lf2_q[12] | lf2_q[13];
    assign t1a[7] = lf1_q[14] | lf1_q[15];
    assign t1b[7] = lf2_q[14] | lf2_q[15];
    assign t1a[8] = lf1_q[16] | lf1_q[17];
    assign t1b[8] = lf2_q[16] | lf2_q[17];
    assign t1a[9] = lf1_q[18] | lf1_q[19];
    assign t1b[9] = lf2_q[18] | lf2_q[19];
    assign t1a[10] = lf1_q[20] | lf1_q[21];
    assign t1b[10] = lf2_q[20] | lf2_q[21];
    assign t1a[11] = lf1_q[22] | lf1_q[23];
    assign t1b[11] = lf2_q[22] | lf2_q[23];
    assign t1a[12] = lf1_q[24] | lf1_q[25];
    assign t1b[12] = lf2_q[24] | lf2_q[25];
    assign t1a[13] = lf1_q[26] | lf1_q[27];
    assign t1b[13] = lf2_q[26] | lf2_q[27];
    assign t1a[14] = lf1_q[28] | lf1_q[29];
    assign t1b[14] = lf2_q[28] | lf2_q[29];
    assign t1a[15] = lf1_q[30] | lf1_q[31];
    assign t1b[15] = lf2_q[30] | lf2_q[31];
    assign t2a[0] = t1a[0] | t1a[1];
    assign t2b[0] = t1b[0] | t1b[1];
    assign t2a[1] = t1a[2] | t1a[3];
    assign t2b[1] = t1b[2] | t1b[3];
    assign t2a[2] = t1a[4] | t1a[5];
    assign t2b[2] = t1b[4] | t1b[5];
    assign t2a[3] = t1a[6] | t1a[7];
    assign t2b[3] = t1b[6] | t1b[7];
    assign t2a[4] = t1a[8] | t1a[9];
    assign t2b[4] = t1b[8] | t1b[9];
    assign t2a[5] = t1a[10] | t1a[11];
    assign t2b[5] = t1b[10] | t1b[11];
    assign t2a[6] = t1a[12] | t1a[13];
    assign t2b[6] = t1b[12] | t1b[13];
    assign t2a[7] = t1a[14] | t1a[15];
    assign t2b[7] = t1b[14] | t1b[15];
    assign t3a[0] = t2a[0] | t2a[1];
    assign t3b[0] = t2b[0] | t2b[1];
    assign t3a[1] = t2a[2] | t2a[3];
    assign t3b[1] = t2b[2] | t2b[3];
    assign t3a[2] = t2a[4] | t2a[5];
    assign t3b[2] = t2b[4] | t2b[5];
    assign t3a[3] = t2a[6] | t2a[7];
    assign t3b[3] = t2b[6] | t2b[7];
    assign t4a[0] = t3a[0] | t3a[1];
    assign t4b[0] = t3b[0] | t3b[1];
    assign t4a[1] = t3a[2] | t3a[3];
    assign t4b[1] = t3b[2] | t3b[3];
    assign ft1 = t4a[0] | t4a[1];
    assign ft2 = t4b[0] | t4b[1];

    always_comb begin
      unique casez ({flush_i, alloc_hit[e]})
        2'b1?: r1r = 1'b0;
        2'b01: r1r = nrec_sel.rs1_rdy || pend_wb1[e];
        default: r1r = (e_q[e].rs1_rdy || (e_q[e].valid && rs1_hit[e]) || z1 ||
                        (tick1 && (e_q[e].rs1_cnt == '0))) &&
                       !(replay_i && e_q[e].valid && e_q[e].rs1_spec);
      endcase
    end
    always_comb begin
      unique casez ({flush_i, alloc_hit[e]})
        2'b1?: r2r = 1'b0;
        2'b01: r2r = nrec_sel.rs2_rdy || pend_wb2[e];
        default: r2r = (e_q[e].rs2_rdy || (e_q[e].valid && rs2_hit[e]) || z2 ||
                        (tick2 && (e_q[e].rs2_cnt == '0))) &&
                       !(replay_i && e_q[e].valid && e_q[e].rs2_spec);
      endcase
    end
    always_comb begin
      unique casez ({flush_i, alloc_hit[e]})
        2'b1?: r3r = 1'b0;
        2'b01: r3r = nrec_sel.rs3_rdy || pend_wb3[e];
        default: r3r = (e_q[e].rs3_rdy || (e_q[e].valid && rs3_hit[e]) || z3 ||
                        (tick3 && (e_q[e].rs3_cnt == '0))) &&
                       !(replay_i && e_q[e].valid && e_q[e].rs3_spec);
      endcase
    end
    assign r1s = !flush_i && !alloc_hit[e] &&
        (fast1 || (pipe1 && !z1) ||
         (e_q[e].rs1_spec && !(e_q[e].valid && rs1_hit[e]) &&
          !(replay_i && e_q[e].valid)));
    assign r2s = !flush_i && !alloc_hit[e] &&
        (fast2 || (pipe2 && !z2) ||
         (e_q[e].rs2_spec && !(e_q[e].valid && rs2_hit[e]) &&
          !(replay_i && e_q[e].valid)));
    assign r3s = !flush_i && !alloc_hit[e] &&
        ((pipe3 && !z3) ||
         (e_q[e].rs3_spec && !(e_q[e].valid && rs3_hit[e]) &&
          !(replay_i && e_q[e].valid)));
    always_comb begin
      unique casez ({flush_i || alloc_hit[e], fast1, pipe1, z1,
                     tick1 && (e_q[e].rs1_cnt != '0)})
        5'b1????: r1c = '0;
        5'b01???: r1c = '0;
        5'b0011?: r1c = '0;
        5'b0010?: r1c = wk_c1[e] - WAKE_W'(1);
        5'b00001: r1c = e_q[e].rs1_cnt - WAKE_W'(1);
        default:  r1c = e_q[e].rs1_cnt;
      endcase
    end
    always_comb begin
      unique casez ({flush_i || alloc_hit[e], fast2, pipe2, z2,
                     tick2 && (e_q[e].rs2_cnt != '0)})
        5'b1????: r2c = '0;
        5'b01???: r2c = '0;
        5'b0011?: r2c = '0;
        5'b0010?: r2c = wk_c2[e] - WAKE_W'(1);
        5'b00001: r2c = e_q[e].rs2_cnt - WAKE_W'(1);
        default:  r2c = e_q[e].rs2_cnt;
      endcase
    end
    always_comb begin
      unique casez ({flush_i || alloc_hit[e], pipe3, z3,
                     tick3 && (e_q[e].rs3_cnt != '0)})
        4'b1???: r3c = '0;
        4'b011?: r3c = '0;
        4'b010?: r3c = wk_c3[e] - WAKE_W'(1);
        4'b0001: r3c = e_q[e].rs3_cnt - WAKE_W'(1);
        default: r3c = e_q[e].rs3_cnt;
      endcase
    end
    // One mux. The fast-path tid OR and the pipe-path tid OR are arms,
    // so their trees are not added.
    always_comb begin
      unique casez ({flush_i || alloc_hit[e], fast1, pipe1 && (|h1a_q[e])})
        3'b1??: r1p = '0;
        3'b01?: r1p = ft1;
        3'b001: r1p = wk_t1[e];
        default: r1p = e_q[e].rs1_ptid;
      endcase
    end
    always_comb begin
      unique casez ({flush_i || alloc_hit[e], fast2, pipe2 && (|h2a_q[e])})
        3'b1??: r2p = '0;
        3'b01?: r2p = ft2;
        3'b001: r2p = wk_t2[e];
        default: r2p = e_q[e].rs2_ptid;
      endcase
    end
    assign r1l = !flush_i && !alloc_hit[e] &&
        (fast1 || (pipe1 ? wk_l1[e]
                         : (e_q[e].rs1_low && e_q[e].rs1_spec &&
                            !(e_q[e].valid && rs1_hit[e]) &&
                            !(replay_i && e_q[e].valid))));
    assign r2l = !flush_i && !alloc_hit[e] &&
        (fast2 || (pipe2 ? wk_l2[e]
                         : (e_q[e].rs2_low && e_q[e].rs2_spec &&
                            !(e_q[e].valid && rs2_hit[e]) &&
                            !(replay_i && e_q[e].valid))));

    // -- per-field continuous assigns (independent LHS cones)
    assign e_d[e].valid  = !flush_i &&
        (alloc_hit[e] || (e_q[e].valid && !cancl[e] && !ack_any[e]));
    assign e_d[e].issued = !flush_i && !alloc_hit[e] &&
        (e_q[e].issued || take_any[e]);
    assign e_d[e].tid    = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.tid
                                                        : e_q[e].tid);
    assign e_d[e].hart   = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.hart
                                                        : e_q[e].hart);
    assign e_d[e].cls    = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.cls
                                                        : e_q[e].cls);
    assign e_d[e].may_bypass = !flush_i &&
        (alloc_hit[e] ? nrec_sel.may_bypass : e_q[e].may_bypass);
    assign e_d[e].lat    = flush_i ? g6lc_hyp_pkg::LAT_NONSPEC
                          : (alloc_hit[e] ? nrec_sel.lat : e_q[e].lat);
    assign e_d[e].is_fprd = !flush_i &&
        (alloc_hit[e] ? nrec_sel.is_fprd : e_q[e].is_fprd);
    assign e_d[e].prs1   = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.prs1
                                                        : e_q[e].prs1);
    assign e_d[e].prs2   = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.prs2
                                                        : e_q[e].prs2);
    assign e_d[e].prd    = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.prd
                                                        : e_q[e].prd);
    assign e_d[e].fprs1  = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.fprs1
                                                        : e_q[e].fprs1);
    assign e_d[e].fprs2  = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.fprs2
                                                        : e_q[e].fprs2);
    assign e_d[e].fprs3  = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.fprs3
                                                        : e_q[e].fprs3);
    assign e_d[e].fprd   = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.fprd
                                                        : e_q[e].fprd);
    assign e_d[e].fpr_rs1 = !flush_i &&
        (alloc_hit[e] ? nrec_sel.fpr_rs1 : e_q[e].fpr_rs1);
    assign e_d[e].fpr_rs2 = !flush_i &&
        (alloc_hit[e] ? nrec_sel.fpr_rs2 : e_q[e].fpr_rs2);
    assign e_d[e].fpr_rs3 = !flush_i &&
        (alloc_hit[e] ? nrec_sel.fpr_rs3 : e_q[e].fpr_rs3);
    assign e_d[e].rs1_rdy  = r1r;
    assign e_d[e].rs2_rdy  = r2r;
    assign e_d[e].rs3_rdy  = r3r;
    assign e_d[e].rs1_spec = r1s;
    assign e_d[e].rs2_spec = r2s;
    assign e_d[e].rs3_spec = r3s;
    assign e_d[e].rs1_low  = r1l;
    assign e_d[e].rs2_low  = r2l;
    assign e_d[e].rs1_cnt  = r1c;
    assign e_d[e].rs2_cnt  = r2c;
    assign e_d[e].rs3_cnt  = r3c;
    assign e_d[e].rs1_ptid = r1p;
    assign e_d[e].rs2_ptid = r2p;
    assign e_d[e].fu       = flush_i ? '0 : (alloc_hit[e] ? nrec_sel.fu
                                                        : e_q[e].fu);
  end
  logic [ENTRIES-1:0] e_vd;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_evd
    assign e_vd[e] = e_d[e].valid;
  end

  // -- age matrix: newcomer column set, newcomer row cleared, dead
  //    rows/columns cleared -- per cell.
  for (genvar r = 0; r < ENTRIES; r++) begin : gen_om_r
    for (genvar c = 0; c < ENTRIES; c++) begin : gen_om_c
      logic dead;
      assign dead = !e_vd[r] || !e_vd[c];
      always_comb begin
        unique casez ({dead, alloc_hit[c], alloc_hit[r]})
          3'b1??: older_d[r][c] = 1'b0;
          3'b01?: older_d[r][c] = (e_q[r].valid && (r != c)) || earlier[r][c];
          3'b001: older_d[r][c] = 1'b0;
          default: older_d[r][c] = older_q[r][c];
        endcase
      end
    end
  end

  // ----------------------------------------------------------------------
  // Reports
  // ----------------------------------------------------------------------
  // Occupancy for steering/full: live entries (issued still occupies).
  // hyp8: popcount tree instead of the serial adder loop.
  logic [ENTRIES-1:0] e_live;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_elive
    assign e_live[e] = e_q[e].valid;
  end
  assign free_cnt_o = FCNT_W'(ENTRIES) - FCNT_W'($countones(e_live | pend_busy));

  // Per-entry info + bank-local class frontiers (oldest live CSR / store).
  // Frontier = the live same-class entry no other same-class entry is older
  // than; the strict total order makes it unique per class. hyp8: per-entry
  // compare vectors (live same-class AND the age column over older_t) +
  // one-hot frontier bit + popcount index select.
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_info
    assign info_v_o[e]     = e_q[e].valid;
    assign info_tid_o[e]   = e_q[e].tid;
    assign info_hart_o[e]  = e_q[e].hart;
    assign info_cls_o[e]   = e_q[e].cls;
    assign info_bypass_o[e] = e_q[e].may_bypass;
    assign info_rdy_o[e]   = {e_q[e].rs3_rdy, e_q[e].rs2_rdy, e_q[e].rs1_rdy};
    assign info_prs1_o[e]  = e_q[e].prs1;
    assign info_prs2_o[e]  = e_q[e].prs2;
  end
  logic [ENTRIES-1:0] live_csr, live_st, front_csr, front_st;
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_front
    assign live_csr[e]  = e_q[e].valid && e_q[e].cls[C_CSR];
    assign live_st[e]   = e_q[e].valid && e_q[e].cls[C_ST];
    assign front_csr[e] = live_csr[e] && !(|(live_csr & older_t[e]));
    assign front_st[e]  = live_st[e]  && !(|(live_st  & older_t[e]));
  end
  assign csr_oldest_v_o = |front_csr;
  assign st_oldest_v_o  = |front_st;
  assign csr_oldest_tid_o =
      e_q[EW'($countones(front_csr - 1'b1)) % ENTRIES].tid;
  assign st_oldest_tid_o =
      e_q[EW'($countones(front_st - 1'b1)) % ENTRIES].tid;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      e_q <= '0;
      older_q <= '0;
    end else begin
      e_q <= e_d;
      older_q <= older_d;
    end
  end

  // One block per snapshot. Unrelated fields in one always_ff are
  // billed as a chain. Flush drops the snapshot so a killed broadcast
  // cannot arm on the following cycle.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) h1_q <= '0;
    else                    h1_q <= wk_h1;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) h2_q <= '0;
    else                    h2_q <= wk_h2;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) h3_q <= '0;
    else                    h3_q <= wk_h3;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) h1a_q <= '0;
    else                    h1a_q <= wk_h1a;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) h2a_q <= '0;
    else                    h2a_q <= wk_h2a;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) cnt_q <= '0;
    else                    cnt_q <= wk_cnt;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) tid_q <= '0;
    else                    tid_q <= wk_tid;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) lo_q <= '0;
    else                    lo_q <= wk_lo;
  end

  // svt-stage: end SEL
  // svt-stage: class SEL decision
  // hyp8: no absorb claim -- the SEL wait is NOT hidden by real-WB
  // scheduling. The speculative countdown is literal-off (analyze-wake-r2
  // SEL reg-to-out 70.7). IqSpecWakeup stays 0.

  // pragma translate_off
  initial begin
    assert (HypCfg.IqSpecWakeup == 0)
      else $fatal(1, "iq_bank: spec broadcast is literal-off; IqSpecWakeup must be 0");
  end
  // ----------------------------------------------------------------------
  // hyp8 r5 equivalence reference: pre-restructure same-cycle select
  // terms. ref_cntX mirrors the un-shifted arm (one count longer than the
  // shifted arm for every non-low class; identical for LAT_ALU_LOW).
  // Checks, per entry and source:
  //   (a) LAT_ALU_LOW arm: the same-cycle bypass fires in the identical
  //       cycle the old (spec && cnt==0) comb term fired;
  //   (b) latency>=2 arm: the registered rdy is already set in the cycle
  //       the old comb term would have fired (shifted arm lands it on the
  //       publish cycle);
  //   (c) real-WB comb hit: captures into the registered rdy at the next
  //       edge (the documented LAT_NONSPEC +1 wake).
  for (genvar e = 0; e < ENTRIES; e++) begin : gen_sel_ref
    logic [WAKE_W-1:0] ref_cnt1, ref_cnt2, ref_cnt3;
    wire ref_arm1 = gen_upd[e].ref_arm1;
    wire ref_arm2 = gen_upd[e].ref_arm2;
    wire ref_arm3 = gen_upd[e].ref_arm3;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ref_cnt1 <= '0;
        ref_cnt2 <= '0;
        ref_cnt3 <= '0;
      end else begin
        ref_cnt1 <= ref_arm1 ? gen_upd[e].ref_add1
            : ((e_q[e].rs1_spec && !e_q[e].rs1_rdy && (ref_cnt1 != '0))
               ? ref_cnt1 - WAKE_W'(1) : ref_cnt1);
        ref_cnt2 <= ref_arm2 ? gen_upd[e].ref_add2
            : ((e_q[e].rs2_spec && !e_q[e].rs2_rdy && (ref_cnt2 != '0))
               ? ref_cnt2 - WAKE_W'(1) : ref_cnt2);
        ref_cnt3 <= ref_arm3 ? gen_upd[e].ref_add3
            : ((e_q[e].rs3_spec && !e_q[e].rs3_rdy && (ref_cnt3 != '0))
               ? ref_cnt3 - WAKE_W'(1) : ref_cnt3);
      end
    end
    // (a) low bypass alignment: low arms carry identical counts, so the
    //     same-cycle fire coincides with the old comb term's fire.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (e_q[e].rs1_low && e_q[e].rs1_spec && (e_q[e].rs1_cnt == '0))
        |-> (ref_cnt1 == '0))
      else $fatal(1, "iq_bank SEL: LAT_ALU_LOW rs1 bypass misaligned e%0d", e);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (e_q[e].rs2_low && e_q[e].rs2_spec && (e_q[e].rs2_cnt == '0))
        |-> (ref_cnt2 == '0))
      else $fatal(1, "iq_bank SEL: LAT_ALU_LOW rs2 bypass misaligned e%0d", e);
    // (b) latency>=2 arms: registered rdy present at the old fire cycle.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (e_q[e].rs1_spec && !e_q[e].rs1_low && (ref_cnt1 == '0))
        |-> e_q[e].rs1_rdy)
      else $fatal(1, "iq_bank SEL: rs1 registered rdy late vs ref fire e%0d", e);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (e_q[e].rs2_spec && !e_q[e].rs2_low && (ref_cnt2 == '0))
        |-> e_q[e].rs2_rdy)
      else $fatal(1, "iq_bank SEL: rs2 registered rdy late vs ref fire e%0d", e);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (e_q[e].rs3_spec && (ref_cnt3 == '0))
        |-> e_q[e].rs3_rdy)
      else $fatal(1, "iq_bank SEL: rs3 registered rdy late vs ref fire e%0d", e);
    // (c) real-WB comb hit captures into the registered rdy (+1 wake for
    //     LAT_NONSPEC consumers; operand already architecturally written).
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (e_q[e].valid && !alloc_hit[e] && !flush_i && !replay_i && rs1_hit[e])
        |=> e_q[e].rs1_rdy || !e_q[e].valid)
      else $fatal(1, "iq_bank SEL: rs1 WB hit did not capture e%0d", e);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (e_q[e].valid && !alloc_hit[e] && !flush_i && !replay_i && rs2_hit[e])
        |=> e_q[e].rs2_rdy || !e_q[e].valid)
      else $fatal(1, "iq_bank SEL: rs2 WB hit did not capture e%0d", e);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (e_q[e].valid && !alloc_hit[e] && !flush_i && !replay_i && rs3_hit[e])
        |=> e_q[e].rs3_rdy || !e_q[e].valid)
      else $fatal(1, "iq_bank SEL: rs3 WB hit did not capture e%0d", e);
  end
  // pragma translate_on

endmodule
