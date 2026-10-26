// hyp8 provenance: REWRITTEN (sv-timing emit base, lifecycle stage)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// hyp8 (group 6): the scoreboard lifecycle engine -- owns the slot array
// (issued/cancelled/replay/sbe), the issue-ring pointer, the commit
// pointer, the registered issued-count and the alloc/issue/commit/flush
// next-state merge. The writeback "record" IS the module's
// wt_valid_i/trans_id_i/wbdata_i/ex_i inputs: in group 7 those inputs come
// straight from the registered FU lane records, so the install here is
// the rank-2 capture point -- there is deliberately no second register.
//
// Per-slot bits and sbe result/exception install happen in ONE next-state
// function (the emit's issue_fifo ordering):
//   alloc -> FU-NONE complete -> WB install -> bmiss kill install ->
//   violation/replay install -> commit-ack clear -> flush clear ->
//   (MixedSmt) reclaim re-anchor.
// The bmiss kill arrives pre-qualified from sb_cancel (kill_req_i): the
// window/hart/keep filtering lives there; the T20 ordering (mispredict
// cancel clears replay BEFORE a same-cycle violation can set it) lives
// here because it composes into mem_n.
//
// H20: a writeback on the resolve cycle of a to-be-cancelled op installs
// its result into mem_n AND the same pass marks the slot cancelled --
// the entry retires as a commit drop and the result can only be read
// through a cancelled slot, which every consumer treats as dead. The
// combined cancelled_mask_o gates the PRF write independently, so the
// data never architecturally survives.

module sb_lifecycle
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type exception_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type forwarding_t = logic,
    parameter type sb_mem_t = logic,
    // hyp8 bring-up: writeback record type (parameter in the original
    // scoreboard); the forwarding array below is built from it.
    parameter type writeback_t = logic
) (
    input  logic                                          clk_i,
    input  logic                                          rst_ni,
    // Scoreboard occupancy - PERF_COUNTERS
    output logic                                          sb_full_o,
    output logic                                          sb_empty_o,
    // Per-slot issued mask (OoO IQ/LSQ liveness assertions)
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]              sb_live_o,
    // LSQ alias validation: youngest load that read bytes an older store
    // resolved later - OoO only, tied low in order.
    input  logic                                          mem_violation_i,
    input  logic              [G6LCCfg.TRANS_ID_BITS-1:0] mem_violation_id_i,
    // T33: load unit hands back a load parked on a speculative store
    input  logic                                          lu_replay_i,
    input  logic              [G6LCCfg.TRANS_ID_BITS-1:0] lu_replay_id_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]              phys_replay_i,
    // Prevent from issuing - CONTROLLER
    input  logic                                          flush_unissued_instr_i,
    // Flush whole scoreboard - CONTROLLER
    input  logic                                          flush_i,
    // Writeback Handling of CVXIF
    input  logic                                          x_transaction_accepted_i,
    input  logic                                          x_issue_writeback_i,
    input  logic              [G6LCCfg.TRANS_ID_BITS-1:0] x_id_i,
    // Commit acknowledge - COMMIT_STAGE (registered, one cycle after the
    // presented bundle's decision)
    input  logic              [G6LCCfg.NrCommitPorts-1:0] commit_ack_i,
    // Presented commit slots (from sb_commit_bundle)
    input  logic              [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_sel_slot_i,

    // instruction to put on top of scoreboard e.g.: top pointer
    input  scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0]       decoded_instr_i,
    input  logic              [G6LCCfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    input  logic              [G6LCCfg.NrIssuePorts-1:0]       decoded_instr_valid_i,
    output logic              [G6LCCfg.NrIssuePorts-1:0]       decoded_instr_ack_o,

    // instruction to issue logic
    output scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0]       issue_instr_o,
    output logic              [G6LCCfg.NrIssuePorts-1:0][31:0] orig_instr_o,
    output logic              [G6LCCfg.NrIssuePorts-1:0]       issue_instr_valid_o,
    input  logic              [G6LCCfg.NrIssuePorts-1:0]       issue_ack_i,
    // Forwarding - ISSUE_READ_OPERANDS (non-bypass under OoO; the PRF
    // stage-2 forward owns bypass -- produced from registered records)
    output forwarding_t                                        fwd_o,

    // Result from branch unit - EX_STAGE (registered B2 record)
    input  bp_resolve_t                                   resolved_branch_i,
    // Same-cycle mispredict + per-slot kill request - SB_CANCEL
    input  logic                                          bmiss_i,
    input  logic              [G6LCCfg.NR_SB_ENTRIES-1:0] kill_req_i,
    // Transaction ID at which to write the result back - EX_STAGE
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] trans_id_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.XLEN-1:0] wbdata_i,
    input  exception_t [G6LCCfg.NrWbPorts-1:0] ex_i,
    input  logic [G6LCCfg.NrWbPorts-1:0] wt_valid_i,
    input  logic x_we_i,
    input  logic [4:0] x_rd_i,

    // Issue pointer - RVFI
    output logic [ G6LCCfg.NrIssuePorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] rvfi_issue_pointer_o,
    // Live entry array + ring pointers for the sibling stages
    output sb_mem_t [G6LCCfg.NR_SB_ENTRIES-1:0]           mem_q_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]              issue_pointer_q_o,
    output logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_pointer_q_o,
    // T6b-4b: reclaim pointer -- the oldest live slot. Under mixed SMT this
    // is the age anchor for dispatch/IQ/LSQ and the store buffer; under
    // legacy commit order it aliases commit_pointer_q[0].
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]                    reclaim_ptr_o,
    // G1mf: result-valid aligned-00 RVI LOAD per hart (SMT+SS only)
    output logic [G6LCCfg.NrHarts-1:0] g1mf_v_o,
    output logic [G6LCCfg.NrHarts-1:0][4:0] g1mf_rd_o,
    output logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:4] g1mf_line_o,
    output logic [G6LCCfg.NrHarts-1:0] g1mf_a3_o
);

  sb_mem_t [G6LCCfg.NR_SB_ENTRIES-1:0] mem_q, mem_n;
  assign mem_q_o = mem_q;

  logic [G6LCCfg.NR_SB_ENTRIES-1:0] still_issued;

  logic [G6LCCfg.NrIssuePorts-1:0] issue_full;

  logic [G6LCCfg.NrIssuePorts-1:0] num_issue;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] issue_pointer_n, issue_pointer_q;
  logic [G6LCCfg.NrIssuePorts:0][G6LCCfg.TRANS_ID_BITS-1:0] issue_pointer;

  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_pointer_n, commit_pointer_q;
  logic [$clog2(G6LCCfg.NrCommitPorts):0] num_commit;

  // Free-slot count for N-wide issue (port k needs k+1 free entries).
  logic [$clog2(G6LCCfg.NR_SB_ENTRIES+1)-1:0] sb_issued_cnt, sb_free_cnt;

  // T6b-4b: per-hart commit heads over the shared ring. Under mixed SMT
  // residency the commit ports present per-hart head slots instead of
  // consecutive ring slots; commit_pointer_q[0] is the reclaim pointer
  // (the oldest live slot) and window accounting replaces the popcount so
  // a committed non-head hole cannot alias as allocatable space. Drained
  // and single-hart keep the legacy contiguous commit logic bit-identical.
  localparam bit MixedSmt = (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;

  assign issue_pointer_q_o   = issue_pointer_q;
  assign commit_pointer_q_o  = commit_pointer_q;
  assign reclaim_ptr_o       = commit_pointer_q[0];

  for (genvar i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin : gen_slot_bits
    // A cancelled entry still occupies its slot and still retires in order
    // as a commit_drop, but it must never source a forward: it is
    // wrong-path.
    assign still_issued[i] = mem_q[i].issued & ~mem_q[i].cancelled;
    assign sb_live_o[i]    = mem_q[i].issued;
  end

  // Issued count as a register (sv-timing A106): the popcount over the
  // `issued` flags fed the free count, the full flags and the issue
  // enable. `issued` is set only by an issue, cleared only by a commit
  // ack or a flush, so the count advances by the issues minus the acks
  // and clears on flush; the popcount equality is asserted in simulation.
  logic [$clog2(G6LCCfg.NR_SB_ENTRIES+1)-1:0] sb_issued_cnt_q, sb_issued_cnt_d;
  always_comb begin
    sb_issued_cnt = sb_issued_cnt_q;
`ifdef G6LC_MUT_SB_POPCOUNT_FREE
    // MUTANT: restore the popcount free count under MIXED.
    sb_free_cnt = $clog2(G6LCCfg.NR_SB_ENTRIES+1)'(G6LCCfg.NR_SB_ENTRIES) - sb_issued_cnt;
`else
    if (MixedSmt) begin
      // Window accounting: only the tail [issue_ptr, reclaim) is
      // allocatable. Committed holes inside [reclaim, issue_ptr) stay
      // non-allocatable until the reclaim pointer passes them.
      automatic logic [G6LCCfg.TRANS_ID_BITS-1:0] wdist;
      wdist = issue_pointer_q - commit_pointer_q[0];
      if ((wdist == '0) && (sb_issued_cnt != '0)) begin
        sb_free_cnt = '0;
      end else begin
        sb_free_cnt = $clog2(G6LCCfg.NR_SB_ENTRIES+1)'(G6LCCfg.NR_SB_ENTRIES) -
                      $clog2(G6LCCfg.NR_SB_ENTRIES+1)'(wdist);
      end
    end else begin
      sb_free_cnt = $clog2(G6LCCfg.NR_SB_ENTRIES+1)'(G6LCCfg.NR_SB_ENTRIES) - sb_issued_cnt;
    end
`endif
  end

  // Port i is full when fewer than (i+1) free scoreboard slots remain.
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_issue_full
    assign issue_full[i] = sb_free_cnt < $clog2(G6LCCfg.NR_SB_ENTRIES+1)'(i + 1);
  end
  // r63: the port-open predicate is shared by the offer/ack cone below --
  // one wire each instead of two reads of the comparator.
  logic [G6LCCfg.NrIssuePorts-1:0] issue_open;
  assign issue_open = ~issue_full;

  assign sb_full_o  = issue_full[0];
  assign sb_empty_o = sb_issued_cnt == '0;

  assign sb_issued_cnt_d = flush_i ? '0
                         : sb_issued_cnt_q + $clog2(G6LCCfg.NR_SB_ENTRIES+1)'(num_issue)
                                           - $clog2(G6LCCfg.NR_SB_ENTRIES+1)'(num_commit);
//pragma translate_off
  // This reference count is consumed only by the assertion. Keep its
  // calculation out of synthesis/timing just like the assertion itself.
  logic [$clog2(G6LCCfg.NR_SB_ENTRIES+1)-1:0] sb_issued_popcnt;
  always_comb begin
    sb_issued_popcnt = '0;
    for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
      if (mem_q[i].issued) sb_issued_popcnt += 1'b1;
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni)
      sb_issued_cnt_is_popcount: assert (sb_issued_cnt_q == sb_issued_popcnt)
        else $error("scoreboard: issued count %0d != popcount %0d", sb_issued_cnt_q, sb_issued_popcnt);
  end
//pragma translate_on

  // Lowest set bit as a log-depth prefix OR (the A136 form), used by the
  // MixedSmt reclaim re-anchor below.
  function automatic logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_lowest_set(input logic [G6LCCfg.NR_SB_ENTRIES-1:0] x);
    logic [G6LCCfg.NR_SB_ENTRIES-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < G6LCCfg.NR_SB_ENTRIES; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction

  logic [G6LCCfg.TRANS_ID_BITS-1:0] reclaim_n;

  assign issue_pointer[0] = issue_pointer_q;
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    assign issue_pointer[i+1] = issue_pointer[i] + 'd1;
  end

  // an instruction is ready for issue if we have place in the issue FIFO
  // and the decoder says it is valid
  always_comb begin
    issue_instr_o = decoded_instr_i;
    orig_instr_o  = orig_instr_i;
    for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
      // make sure we assign the correct trans ID
      issue_instr_o[i].trans_id = issue_pointer[i];

      issue_instr_valid_o[i]    = decoded_instr_valid_i[i] & issue_open[i];
      decoded_instr_ack_o[i]    = issue_ack_i[i] & issue_open[i];
    end
  end

  //pragma translate_off
  // M3 bring-up probe (+icf_trace): SB offer/ack + fullness around the
  // "Issue acknowledged but instruction is not valid" assertion.
  logic sbl_trace;
  initial sbl_trace = $test$plusargs("icf_trace");
  always_ff @(negedge clk_i) begin
    if (rst_ni && sbl_trace && $time() < 420 && $time() > 280) begin
      $display("[sbl] t=%0t dv=%b ack_i=%b dack=%b full=%b free=%0d iptr=%0d cptr=%0d fu_i=%b f=%b | pc0=%h fu0=%0d | iss0=%b iss1=%b cack=%b wt=%b tid=%0d",
        $time, decoded_instr_valid_i, issue_ack_i, decoded_instr_ack_o, issue_full,
        sb_free_cnt, issue_pointer[0], commit_pointer_q[0],
        flush_unissued_instr_i, flush_i,
        decoded_instr_i[0].pc, decoded_instr_i[0].fu,
        mem_q[0].issued, mem_q[1].issued, commit_ack_i, wt_valid_i, trans_id_i[0]);
    end
  end
  //pragma translate_on

  // maintain a FIFO with issued instructions
//pragma translate_off
  // O7 alloc trace. Opt-in (`+sb_alloc`).
  logic sb_alloc_en;
  initial sb_alloc_en = $test$plusargs("sb_alloc");
//pragma translate_on
  // hyp8: per-slot event-mask form -- the emit's dynamic-index patches to
  // mem_n serialize into one dependency chain. Each slot's always_comb
  // applies the same ordered events at a static index (alloc -> fuNONE ->
  // wb(+predecessor) -> cancel -> violation -> lu_replay -> phys_replay ->
  // commit-free -> flush), so each slot bills as an independent LHS.
  logic [G6LCCfg.NrIssuePorts-1:0] alloc_fire, alloc_link;
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_af
    assign alloc_fire[i] = decoded_instr_valid_i[i] && decoded_instr_ack_o[i] &&
`ifdef G6LC_FETCH_B
        !flush_unissued_instr_i;
`else
        g6lc_sb_keep::alloc(
            G6LCCfg,
            flush_unissued_instr_i,
            decoded_instr_i[i].fu,
            decoded_instr_i[i].rd[4:0]);
`endif
`ifndef G6LC_FETCH_B
    assign alloc_link[i] = G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
        g6lc_sb_keep::link_jal(
            G6LCCfg.SuperscalarEn,
            decoded_instr_i[i].fu,
            decoded_instr_i[i].rd[4:0]);
`else
    assign alloc_link[i] = 1'b0;
`endif
  end
  assign num_issue = $bits(num_issue)'($countones(alloc_fire));

  // hyp8 T1 item 13: the dynamic mem_q[tid] reads become masked-OR
  // columns — the tid decode is per-port one-hot, the gathered field a
  // single AND-OR instead of an indexed read on the slot cone.
  logic [G6LCCfg.NrWbPorts-1:0]               wb_issued_c;
  logic [G6LCCfg.NrWbPorts-1:0]               wb_dr_c, wb_mi_c, wb_lm_c;
  logic                                       vio_issued_c;
  logic                                       lur_issued_c, lur_load_c;
`ifndef G6LC_MUT_T1_SBLC
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] vio_col, lur_vcol, lur_fcol;
  for (genvar i = 0; i < G6LCCfg.NrWbPorts; i++) begin : gen_wbc
    logic [G6LCCfg.NR_SB_ENTRIES-1:0] icol, dcol, mcol, lcol;
    for (genvar s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin : gen_wbcs
      assign icol[s] = (trans_id_i[i] == G6LCCfg.TRANS_ID_BITS'(s)) &&
                       mem_q[s].issued;
      assign dcol[s] = (trans_id_i[i] == G6LCCfg.TRANS_ID_BITS'(s)) &&
                       mem_q[s].sbe.is_double_rd_macro_instr;
      assign mcol[s] = (trans_id_i[i] == G6LCCfg.TRANS_ID_BITS'(s)) &&
                       mem_q[s].sbe.is_macro_instr;
      assign lcol[s] = (trans_id_i[i] == G6LCCfg.TRANS_ID_BITS'(s)) &&
                       mem_q[s].sbe.is_last_macro_instr;
    end
    assign wb_issued_c[i] = |icol;
    assign wb_dr_c[i]     = |dcol;
    assign wb_mi_c[i]     = |mcol;
    assign wb_lm_c[i]     = |lcol;
  end
  for (genvar s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin : gen_vs
    assign vio_col[s]  = (mem_violation_id_i ==
                          G6LCCfg.TRANS_ID_BITS'(s)) && mem_q[s].issued;
    assign lur_vcol[s] = (lu_replay_id_i ==
                          G6LCCfg.TRANS_ID_BITS'(s)) && mem_q[s].issued;
    assign lur_fcol[s] = (lu_replay_id_i ==
                          G6LCCfg.TRANS_ID_BITS'(s)) &&
                         (mem_q[s].sbe.fu == g6lc_core_pkg::LOAD);
  end
  assign vio_issued_c = |vio_col;
  assign lur_issued_c = |lur_vcol;
  assign lur_load_c   = |lur_fcol;
`endif

  logic [G6LCCfg.NrWbPorts-1:0] wb_fire;
  for (genvar i = 0; i < G6LCCfg.NrWbPorts; i++)
    assign wb_fire[i] = wt_valid_i[i] &&
`ifdef G6LC_MUT_T1_SBLC
        mem_q[trans_id_i[i]].issued;
`else
        wb_issued_c[i];
`endif

  for (genvar s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin : gen_mn
    logic [G6LCCfg.NrIssuePorts-1:0] a_sel;
    logic [G6LCCfg.NrWbPorts-1:0]  w_sel, wp_sel;
    logic [G6LCCfg.NrCommitPorts-1:0] cf_sel;
    logic                          a_hit, w_hit_s, wp_hit_s, c_hit, r_hit,
                                   v_hit, l_hit, p_hit, cf_hit, none_fu,
                                   fu_cvxif, fpu_ex;
    scoreboard_entry_t             a_sbe;
    logic                          a_link_s;
    sb_mem_t                       a_mem;
    logic [G6LCCfg.XLEN-1:0]       w_res;
    exception_t                    w_ex;
    logic                          w_valid, w_bpw, w_keep;
    logic                          can_mid, rep_mid, can_mid2, rep_mid2;

    // --- alloc (issue ports; last matching index wins as the emit's
    // sequential loop wrote them) ---
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++)
      assign a_sel[i] = alloc_fire[i] &&
                        (issue_pointer[i] ==
                         G6LCCfg.TRANS_ID_BITS'(s));
    assign a_hit = |a_sel;
    always_comb begin
      a_sbe    = '0;
      a_link_s = 1'b0;
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++)
        if (a_sel[i]) begin
          a_sbe    = decoded_instr_i[i];
          a_link_s = alloc_link[i];
        end
    end
    always_comb begin
      // Alloc record: OoO tags cleared (dispatch renames later); G1v
      // link-jal folds result=pc+ilen and valid into the record.
      scoreboard_entry_t z;
      z = a_sbe;
      z.p_rs1       = '0;
      z.p_rs2       = '0;
      z.p_rd        = '0;
      z.ooo_renamed = 1'b0;
`ifndef G6LC_FETCH_B
      if (a_link_s) begin
        z.result = g6lc_sb_keep::link(64'(z.pc), z.is_compressed);
        z.valid  = 1'b1;
      end
`endif
      a_mem = '{issued: 1'b1, cancelled: 1'b0, replay: 1'b0,
                is_rd_fpr_flag: G6LCCfg.FpPresent &&
                                g6lc_core_pkg::is_rd_fpr(a_sbe.op),
                sbe: z};
    end
    assign fu_cvxif = ((a_hit ? a_sbe.fu : mem_q[s].sbe.fu) ==
                       g6lc_core_pkg::CVXIF);

    // --- write-back ports (last matching port wins) ---
    for (genvar i = 0; i < G6LCCfg.NrWbPorts; i++) begin
      assign w_sel[i]  = wb_fire[i] &&
                         (trans_id_i[i] == G6LCCfg.TRANS_ID_BITS'(s));
`ifdef G6LC_MUT_T1_SBLC
      assign wp_sel[i] = wb_fire[i] &&
                         mem_q[trans_id_i[i]].sbe.is_double_rd_macro_instr &&
                         mem_q[trans_id_i[i]].sbe.is_macro_instr &&
                         mem_q[trans_id_i[i]].sbe.is_last_macro_instr &&
                         (8'(trans_id_i[i]) - 8'd1 ==
                          G6LCCfg.TRANS_ID_BITS'(s));
`else
      // hyp8 T1 item 13: gathered columns instead of indexed reads.
      assign wp_sel[i] = wb_fire[i] &&
                         wb_dr_c[i] && wb_mi_c[i] && wb_lm_c[i] &&
                         (8'(trans_id_i[i]) - 8'd1 ==
                          G6LCCfg.TRANS_ID_BITS'(s));
`endif
    end
    assign w_hit_s  = |w_sel;
    assign wp_hit_s = |wp_sel;
    always_comb begin
      w_res = '0;
      w_ex  = '0;
      for (int unsigned i = 0; i < G6LCCfg.NrWbPorts; i++)
        if (w_sel[i]) begin
          w_res = wbdata_i[i];
          w_ex  = ex_i[i];
        end
    end
    assign w_valid = !(mem_q[s].sbe.is_double_rd_macro_instr &&
                       mem_q[s].sbe.is_macro_instr &&
                       !mem_q[s].sbe.is_last_macro_instr);
    assign w_bpw   = G6LCCfg.DebugEn ||
                     (G6LCCfg.NrHarts > 1 &&
                      mem_q[s].sbe.fu == g6lc_core_pkg::CTRL_FLOW);
`ifdef G6LC_FETCH_B
    assign w_keep = 1'b0;
`else
    // G1w: flu of a link-jal must not replace G1v's pc+ilen.
    assign w_keep = g6lc_sb_keep::keep_alloc_link(
                        G6LCCfg,
                        mem_q[s].sbe.fu,
                        mem_q[s].sbe.rd[4:0],
                        64'(mem_q[s].sbe.result));
`endif

    // --- cancel / replay events (mid-state reads preserve the emit's
    // post-cancel gate; T20) ---
    assign c_hit = bmiss_i && kill_req_i[s];
    assign can_mid = c_hit ? 1'b1
                     : (a_hit ? 1'b0 : mem_q[s].cancelled);
    assign rep_mid = c_hit ? 1'b0
                     : (a_hit ? 1'b0 : mem_q[s].replay);
    assign v_hit = G6LCCfg.OoOEn && mem_violation_i &&
`ifdef G6LC_MUT_T1_SBLC
                   mem_q[mem_violation_id_i].issued &&
`else
                   vio_issued_c &&
`endif
                   (mem_violation_id_i == G6LCCfg.TRANS_ID_BITS'(s)) &&
                   !(can_mid && !rep_mid);
    assign l_hit = G6LCCfg.OoOEn && lu_replay_i &&
`ifdef G6LC_MUT_T1_SBLC
                   mem_q[lu_replay_id_i].issued &&
                   (mem_q[lu_replay_id_i].sbe.fu == g6lc_core_pkg::LOAD) &&
`else
                   lur_issued_c && lur_load_c &&
`endif
                   (lu_replay_id_i == G6LCCfg.TRANS_ID_BITS'(s)) &&
                   !(can_mid && !rep_mid);
    assign can_mid2 = (c_hit || v_hit || l_hit) ? 1'b1
                      : (a_hit ? 1'b0 : mem_q[s].cancelled);
    assign rep_mid2 = (v_hit || l_hit) ? 1'b1
                      : (c_hit ? 1'b0
                         : (a_hit ? 1'b0 : mem_q[s].replay));
    assign p_hit = (G6LCCfg.CohPolicy == config_pkg::COH_OOO) &&
                   phys_replay_i[s] && mem_q[s].issued &&
                   (mem_q[s].sbe.fu == g6lc_core_pkg::LOAD) &&
                   !(can_mid2 && !rep_mid2);
    assign r_hit = v_hit || l_hit || p_hit;
    assign none_fu = (mem_q[s].sbe.fu == g6lc_core_pkg::NONE) &&
                     mem_q[s].issued;
    for (genvar i = 0; i < G6LCCfg.NrCommitPorts; i++)
      assign cf_sel[i] = commit_ack_i[i] &&
                         (commit_sel_slot_i[i] ==
                          G6LCCfg.TRANS_ID_BITS'(s));
    assign cf_hit = |cf_sel;
    assign fpu_ex = G6LCCfg.FpPresent &&
                    (mem_q[s].sbe.fu == g6lc_core_pkg::FPU ||
                     mem_q[s].sbe.fu == g6lc_core_pkg::FPU_VEC);

    always_comb begin : p_mn
      mem_n[s] = a_hit ? a_mem : mem_q[s];
      // FU NONE -> valid immediately
      if (none_fu) mem_n[s].sbe.valid = 1'b1;
      // write-back lane record
      if (w_hit_s) begin
        mem_n[s].sbe.valid = w_valid;
`ifdef G6LC_FETCH_B
        mem_n[s].sbe.result = w_res;
`else
        if (!w_keep) mem_n[s].sbe.result = w_res;
`endif
        if (w_bpw)
          mem_n[s].sbe.bp.predict_address = resolved_branch_i.target_address;
        if (fu_cvxif)
          mem_n[s].sbe.rd = x_we_i ? x_rd_i : 5'b0;
        if (w_ex.valid) mem_n[s].sbe.ex = w_ex;
        else if (fpu_ex)
          mem_n[s].sbe.ex.cause = w_ex.cause;
      end
      // predecessor slot of a completed double-rd macro pair
      if (wp_hit_s) mem_n[s].sbe.valid = 1'b1;
      // cancel younger than the mispredicted branch (T20: drop replay)
      if (c_hit) begin
        mem_n[s].cancelled = 1'b1;
        mem_n[s].sbe.valid = 1'b1;
        mem_n[s].replay    = 1'b0;
      end
      // memory-order violation / LU replay / physical replay
      if (r_hit) begin
        mem_n[s].cancelled = 1'b1;
        mem_n[s].replay    = 1'b1;
        mem_n[s].sbe.valid = 1'b1;
      end
      // commit ack frees the slot
      if (cf_hit) begin
        mem_n[s].issued    = 1'b0;
        mem_n[s].cancelled = 1'b0;
        mem_n[s].replay    = 1'b0;
        mem_n[s].sbe.valid = 1'b0;
      end
      // flush
      if (flush_i) begin
        mem_n[s].issued       = 1'b0;
        mem_n[s].cancelled    = 1'b0;
        mem_n[s].replay       = 1'b0;
        mem_n[s].sbe.valid    = 1'b0;
        mem_n[s].sbe.ex.valid = 1'b0;
      end
    end
  end

//pragma translate_off
  always_comb begin
    if (sb_alloc_en && $time() < 200000)
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++)
        if (alloc_fire[i])
          $display("[sb-alloc] t=%0t idx=%0d pc=%h instr=%h ex.valid=%b valid=%b",
                   $time, issue_pointer[i], decoded_instr_i[i].pc, orig_instr_i[i],
                   decoded_instr_i[i].ex.valid, decoded_instr_valid_i[i]);
  end
//pragma translate_on

  // T6b-4b reclaim (MIXED only): the next-cycle reclaim pointer is the
  // oldest slot still live in mem_n at or after the current pointer.
  always_comb begin : p_reclaim
    reclaim_n = commit_pointer_q[0];
    if (MixedSmt) begin
      automatic logic [G6LCCfg.NR_SB_ENTRIES-1:0] live, ge, hi_c, lo_c, first;
      for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
        live[i] = mem_n[i].issued;
        ge[i]   = (G6LCCfg.TRANS_ID_BITS'(i) >= commit_pointer_q[0]);
      end
      hi_c  = live & ge;
      lo_c  = live & ~ge;
      first = (|hi_c) ? sb_lowest_set(hi_c) : sb_lowest_set(lo_c);
      reclaim_n = '0;
      for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++)
        if (first[i]) reclaim_n = reclaim_n | G6LCCfg.TRANS_ID_BITS'(i);
      if (live == '0) reclaim_n = issue_pointer[num_issue];
    end
  end

  // FIFO counter updates: count acknowledged commits across ALL ports.
  always_comb begin : gen_commit_count
    num_commit = '0;
    for (int unsigned i = 0; i < G6LCCfg.NrCommitPorts; i++)
      num_commit = num_commit + $clog2(G6LCCfg.NrCommitPorts+1)'(commit_ack_i[i]);
  end

  // T6b-4b: under MIXED, commit_pointer_q[0] is the reclaim pointer -- it
  // jumps over committed holes to the oldest remaining live slot instead
  // of advancing by the ack popcount.
  // hyp8: inline the condition so const-eval prunes the MixedSmt
  // reclaim-pointer leg under NrHarts==1.
  if ((G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff) begin : gen_reclaim_ptr
    assign commit_pointer_n[0] = (flush_i) ? '0 : reclaim_n;
    for (genvar k = 1; k < G6LCCfg.NrCommitPorts; k++) begin : gen_reclaim_incr
      assign commit_pointer_n[k] = (flush_i) ? '0 : reclaim_n + G6LCCfg.TRANS_ID_BITS'(k);
    end
  end else begin : gen_commit_ptr
    // Precomputed constant increments selected by the ack count (sv-timing
    // A88/A105): `commit_pointer_q[0] + num_commit + k` was a popcount
    // feeding an adder feeding the flush mux; `commit_pointer_q[0] + c`
    // for every constant c in 0..NrCommitPorts+k is a bank of
    // incrementers that start from the register, and the count only
    // steers a select.
    for (genvar k = 0; k < G6LCCfg.NrCommitPorts; k++) begin : gen_commit_incr
      logic [G6LCCfg.NrCommitPorts:0][G6LCCfg.TRANS_ID_BITS-1:0] cand;
      for (genvar c = 0; c <= G6LCCfg.NrCommitPorts; c++) begin : gen_cand
        assign cand[c] = commit_pointer_q[0] + G6LCCfg.TRANS_ID_BITS'(c + k);
      end
      assign commit_pointer_n[k] = (flush_i) ? '0 : cand[num_commit];
    end
  end

  always_comb begin : assign_issue_pointer_n
    issue_pointer_n = issue_pointer[num_issue];
    if (flush_i) issue_pointer_n = '0;
  end

  // Forwarding logic
  writeback_t [G6LCCfg.NrWbPorts-1:0] wb;
  for (genvar i = 0; i < G6LCCfg.NrWbPorts; i++) begin
    assign wb[i].valid = wt_valid_i[i];
    assign wb[i].data = wbdata_i[i];
    assign wb[i].ex_valid = ex_i[i].valid;
    assign wb[i].trans_id = trans_id_i[i];
  end

  assign fwd_o.still_issued = still_issued;
  assign fwd_o.issue_pointer = issue_pointer[0];
  assign fwd_o.wb = wb;
  for (genvar i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
    assign fwd_o.sbe[i] = mem_q[i].sbe;
  end

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin : regs
    if (!rst_ni) begin
      mem_q            <= '{default: sb_mem_t'(0)};
      commit_pointer_q <= '0;
      issue_pointer_q  <= '0;
      sb_issued_cnt_q  <= '0;
    end else begin
      issue_pointer_q <= issue_pointer_n;
      sb_issued_cnt_q <= sb_issued_cnt_d;
      mem_q <= mem_n;
      mem_q[x_id_i].sbe.rd <= (x_transaction_accepted_i && ~x_issue_writeback_i) ? 5'b0 : mem_n[x_id_i].sbe.rd;
      commit_pointer_q <= commit_pointer_n;
    end
  end

  //RVFI
  assign rvfi_issue_pointer_o  = issue_pointer[G6LCCfg.NrIssuePorts-1:0];

  // G1mf: last result-valid aligned-00 RVI LOAD per hart (SMT+SS only)
  always_comb begin
    g1mf_v_o    = '0;
    g1mf_rd_o   = '0;
    g1mf_line_o = '0;
    g1mf_a3_o   = '0;
    if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
        G6LCCfg.FETCH_WIDTH >= 64) begin
`ifndef G6LC_FETCH_B
      for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
        if (g6lc_sib_cjalr::sb_load00(
                G6LCCfg, mem_q[i].issued, mem_q[i].cancelled,
                mem_q[i].sbe.valid, mem_q[i].sbe.ex.valid,
                mem_q[i].sbe.is_compressed,
                mem_q[i].sbe.pc[2:1] == 2'b00,
                mem_q[i].sbe.fu == g6lc_core_pkg::LOAD,
                mem_q[i].sbe.rd[4:0] != 5'd0)) begin
          g1mf_v_o[mem_q[i].sbe.hart_id]    = 1'b1;
          g1mf_rd_o[mem_q[i].sbe.hart_id]   = mem_q[i].sbe.rd[4:0];
          g1mf_line_o[mem_q[i].sbe.hart_id] = mem_q[i].sbe.pc[G6LCCfg.VLEN-1:4];
          g1mf_a3_o[mem_q[i].sbe.hart_id]   = mem_q[i].sbe.pc[3];
        end
      end
`endif
    end
  end

//pragma translate_off
  bit smt_progress_enabled;
  localparam int SMT_TRACE_HARTS = G6LCCfg.NrHarts > 0 ? G6LCCfg.NrHarts : 1;
  longint unsigned smt_retired_count[SMT_TRACE_HARTS];
  logic [G6LCCfg.VLEN-1:0] smt_last_retired_pc[SMT_TRACE_HARTS];
  // The smt-progress/flow traces read the *presented* commit slots through
  // commit_sel_slot_i + mem_q (the wrapper maps them to commit_*_o).
  function automatic logic [$bits(mem_q[0].sbe.hart_id)-1:0] sbe_hart(input int p);
    return mem_q[commit_sel_slot_i[p]].sbe.hart_id;
  endfunction
  function automatic logic [G6LCCfg.VLEN-1:0] sbe_pc(input int p);
    return mem_q[commit_sel_slot_i[p]].sbe.pc;
  endfunction
  logic [G6LCCfg.NrCommitPorts-1:0] commit_instr_c;
  always_comb
    for (int p = 0; p < G6LCCfg.NrCommitPorts; p++)
      commit_instr_c[p] = mem_q[commit_sel_slot_i[p]].cancelled;
  initial smt_progress_enabled = $test$plusargs("smt_progress");
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      foreach (smt_retired_count[h]) begin
        smt_retired_count[h] = 0;
        smt_last_retired_pc[h] = '0;
      end
    end else if (smt_progress_enabled) begin
      for (int p = 0; p < G6LCCfg.NrCommitPorts; p++)
        if (commit_ack_i[p] && !commit_instr_c[p]) begin
          smt_retired_count[sbe_hart(p)] = smt_retired_count[sbe_hart(p)] + 1'b1;
          smt_last_retired_pc[sbe_hart(p)] = sbe_pc(p);
        end
    end
  end
  final begin
    if (smt_progress_enabled)
      foreach (smt_retired_count[h])
        $display("[smt-progress] scope=%m hart=%0d retired=%0d last_pc=%h",
                 h, smt_retired_count[h], smt_last_retired_pc[h]);
  end
  bit smt_flow_enabled;
  int unsigned smt_flow_cycle = 0;
  int unsigned smt_flow_idle = 0;
  int unsigned smt_flow_snapshots = 0;
  int unsigned smt_flow_generation[G6LCCfg.NR_SB_ENTRIES];
  initial smt_flow_enabled = $test$plusargs("smt_flow_trace");

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      smt_flow_cycle = 0;
      smt_flow_idle = 0;
      smt_flow_snapshots = 0;
      foreach (smt_flow_generation[s]) smt_flow_generation[s] = 0;
    end else if (smt_flow_enabled) begin
      smt_flow_cycle++;
      smt_flow_idle = (|commit_ack_i || flush_i) ? 0 : smt_flow_idle + 1;
      for (int p = 0; p < G6LCCfg.NrCommitPorts; p++)
        if (commit_ack_i[p])
          $display("[smt-flow] retire cycle=%0d port=%0d id=%0d gen=%0d hart=%0d pc=%h rd=%0d result=%h valid=%b drop=%b ex=%b replay=%b scope=%m",
                   smt_flow_cycle, p, commit_sel_slot_i[p], smt_flow_generation[commit_sel_slot_i[p]],
                   mem_q[commit_sel_slot_i[p]].sbe.hart_id, mem_q[commit_sel_slot_i[p]].sbe.pc,
                   mem_q[commit_sel_slot_i[p]].sbe.rd[4:0], mem_q[commit_sel_slot_i[p]].sbe.result,
                   mem_q[commit_sel_slot_i[p]].sbe.valid,
                   mem_q[commit_sel_slot_i[p]].cancelled, mem_q[commit_sel_slot_i[p]].sbe.ex.valid,
                   mem_q[commit_sel_slot_i[p]].replay);
      for (int p = 0; p < G6LCCfg.NrWbPorts; p++)
        if (wt_valid_i[p])
          $display("[smt-flow] wb cycle=%0d port=%0d id=%0d gen=%0d hart=%0d pc=%h issued=%b cancelled=%b data=%h ex=%b scope=%m",
                   smt_flow_cycle, p, trans_id_i[p], smt_flow_generation[trans_id_i[p]],
                   mem_q[trans_id_i[p]].sbe.hart_id, mem_q[trans_id_i[p]].sbe.pc,
                   mem_q[trans_id_i[p]].issued, mem_q[trans_id_i[p]].cancelled, wbdata_i[p], ex_i[p].valid);
      for (int p = 0; p < G6LCCfg.NrIssuePorts; p++)
        if (decoded_instr_valid_i[p] && decoded_instr_ack_o[p] && !flush_unissued_instr_i) begin
          smt_flow_generation[issue_pointer[p]]++;
          $display("[smt-flow] alloc cycle=%0d port=%0d id=%0d gen=%0d hart=%0d pc=%h insn=%h fu=%0d op=%0d rd=%0d rs1=%0d rs2=%0d scope=%m",
                   smt_flow_cycle, p, issue_pointer[p], smt_flow_generation[issue_pointer[p]],
                   decoded_instr_i[p].hart_id, decoded_instr_i[p].pc, orig_instr_i[p],
                   decoded_instr_i[p].fu, decoded_instr_i[p].op, decoded_instr_i[p].rd,
                   decoded_instr_i[p].rs1, decoded_instr_i[p].rs2);
        end
      if (flush_i || flush_unissued_instr_i || resolved_branch_i.valid)
        $display("[smt-flow] control cycle=%0d flush=%b flush_unissued=%b resolve=%b mispredict=%b target=%h",
                 smt_flow_cycle, flush_i, flush_unissued_instr_i, resolved_branch_i.valid,
                 resolved_branch_i.is_mispredict, resolved_branch_i.target_address);
      if (smt_flow_idle != 0 && smt_flow_idle % 1024 == 0 && smt_flow_snapshots < 4) begin
        smt_flow_snapshots++;
        $display("[smt-flow] stalled cycle=%0d idle=%0d issue_ptr=%0d commit_ptr=%0d full=%b decoded=%b ack=%b",
                 smt_flow_cycle, smt_flow_idle, issue_pointer_q, commit_pointer_q[0],
                 sb_full_o, decoded_instr_valid_i, decoded_instr_ack_o);
        for (int p = 0; p < G6LCCfg.NrIssuePorts; p++)
          $display("[smt-flow] offered port=%0d hart=%0d pc=%h insn=%h fu=%0d op=%0d rd=%0d rs1=%0d rs2=%0d",
                   p, decoded_instr_i[p].hart_id, decoded_instr_i[p].pc, orig_instr_i[p],
                   decoded_instr_i[p].fu, decoded_instr_i[p].op, decoded_instr_i[p].rd,
                   decoded_instr_i[p].rs1, decoded_instr_i[p].rs2);
        for (int s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++)
          if (mem_q[s].issued)
            $display("[smt-flow] slot id=%0d gen=%0d hart=%0d pc=%h valid=%b cancelled=%b fu=%0d op=%0d rd=%0d result=%h",
                     s, smt_flow_generation[s], mem_q[s].sbe.hart_id, mem_q[s].sbe.pc,
                     mem_q[s].sbe.valid, mem_q[s].cancelled, mem_q[s].sbe.fu,
                     mem_q[s].sbe.op, mem_q[s].sbe.rd, mem_q[s].sbe.result);
      end
    end
  end

  initial begin
    assert (G6LCCfg.NR_SB_ENTRIES == 2 ** G6LCCfg.TRANS_ID_BITS)
    else $fatal(1, "Scoreboard size needs to be a power of two.");
  end

  // ----------------------------------------------------------------------
  // M3b recovery-cost probe (+misp_stats). For each mispredict resolution
  // records: cycles until the first commit of an entry allocated *after*
  // the resolution, and the number of in-flight entries at resolution.
  // Entirely report-only: no functional signal is read into logic.
  // ----------------------------------------------------------------------
  bit    misp_en;
  int unsigned misp_epoch_q = 0;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][31:0] slot_epoch_q = '0;
  logic         misp_pend_q = 1'b0;
  int unsigned  misp_hart_q = 0;
  longint unsigned misp_start_q = 0;
  int unsigned  misp_inflight_q = 0;
  longint unsigned misp_cycle_q = 0;
  int unsigned  misp_events = 0, misp_resolved = 0, misp_superseded = 0;
  longint unsigned misp_sum_cyc = 0, misp_sum_inf = 0;
  int unsigned  misp_max_cyc = 0, misp_max_inf = 0;
  int unsigned  misp_hist[32] = '{default:0};
  int unsigned  misp_bptrain[2] = '{default:0};
  int unsigned  misp_misses[2]  = '{default:0};
  initial misp_en = $test$plusargs("misp_stats");
  always @(posedge clk_i) begin : misp_stats_ff
    int unsigned infl;
    int unsigned bucket;
    bit found;
    if (!rst_ni) begin
      misp_pend_q  = 1'b0;
      misp_cycle_q = '0;
      misp_epoch_q = '0;
    end else if (misp_en) begin
      misp_cycle_q = misp_cycle_q + 1;
      // Allocation epoch shadow (mirrors the scoreboard alloc term).
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        if (decoded_instr_valid_i[i] && decoded_instr_ack_o[i] &&
`ifdef G6LC_FETCH_B
            !flush_unissued_instr_i
`else
            g6lc_sb_keep::alloc(
                G6LCCfg, flush_unissued_instr_i,
                decoded_instr_i[i].fu, decoded_instr_i[i].rd[4:0])
`endif
           )
          slot_epoch_q[issue_pointer[i]] = 32'(misp_epoch_q);
      end
      // bp training traffic per hart (predictor update = every resolve).
      if (resolved_branch_i.valid) begin
        misp_bptrain[int'(resolved_branch_i.hart_id)] =
          misp_bptrain[int'(resolved_branch_i.hart_id)] + 1;
        if (resolved_branch_i.is_mispredict)
          misp_misses[int'(resolved_branch_i.hart_id)] =
            misp_misses[int'(resolved_branch_i.hart_id)] + 1;
      end
      if (bmiss_i) begin
        misp_events++;
        if (misp_pend_q) misp_superseded++;
        misp_pend_q    = 1'b1;
        misp_start_q   = misp_cycle_q;
        misp_hart_q    = int'(resolved_branch_i.hart_id);
        misp_epoch_q   = misp_epoch_q + 1;
        infl = 0;
        for (int unsigned s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++)
          if (mem_q[s].issued) infl++;
        misp_inflight_q = infl;
        misp_sum_inf    = misp_sum_inf + infl;
        if (infl > misp_max_inf) misp_max_inf = infl;
      end else if (misp_pend_q) begin
        // First same-hart commit of a post-resolution entry = recovered.
        found = 1'b0;
        for (int unsigned p = 0; p < G6LCCfg.NrCommitPorts; p++) begin
          if (!found && commit_ack_i[p] &&
              int'(mem_q[commit_sel_slot_i[p]].sbe.hart_id) == misp_hart_q &&
              slot_epoch_q[commit_sel_slot_i[p]] == misp_epoch_q &&
              !mem_q[commit_sel_slot_i[p]].cancelled) begin
            found = 1'b1;
            misp_pend_q    = 1'b0;
            misp_resolved++;
            misp_sum_cyc = misp_sum_cyc + (misp_cycle_q - misp_start_q);
            if ((misp_cycle_q - misp_start_q) > 64'(misp_max_cyc))
              misp_max_cyc = int'(misp_cycle_q - misp_start_q);
            bucket = int'((misp_cycle_q - misp_start_q) / 4);
            if (bucket > 31) bucket = 31;
            misp_hist[bucket]++;
          end
        end
      end
    end
  end
  final begin
    if (misp_en) begin
      $write("[ooo-misp] n=%0d resolved=%0d superseded=%0d", misp_events,
             misp_resolved, misp_superseded);
      if (misp_resolved > 0)
        $write(" mean=%0d.%02d max=%0d",
               int'(misp_sum_cyc / 64'(misp_resolved)),
               int'((misp_sum_cyc * 100 / 64'(misp_resolved)) % 100),
               misp_max_cyc);
      else
        $write(" mean=na max=na");
      if (misp_events > 0)
        $write(" infl_mean=%0d.%02d infl_max=%0d",
               int'(misp_sum_inf / 64'(misp_events)),
               int'((misp_sum_inf * 100 / 64'(misp_events)) % 100),
               misp_max_inf);
      else
        $write(" infl_mean=na infl_max=na");
      $write(" bptrain_h0=%0d bptrain_h1=%0d miss_h0=%0d miss_h1=%0d hist:",
             misp_bptrain[0], misp_bptrain[1], misp_misses[0], misp_misses[1]);
      for (int b = 0; b < 32; b++)
        if (misp_hist[b] > 0) $write(" %0d:%0d", b * 4, misp_hist[b]);
      $write("\n");
    end
  end

  // hyp8 T1 item 13: masked-OR columns equal the indexed reads they
  // replaced, checked every cycle on the live ids.
  int unsigned t1_sblc_n = 0;
  always_ff @(posedge clk_i) begin : p_t1_sblc_eq
    if (rst_ni) begin
      t1_sblc_n <= t1_sblc_n + 1;
`ifndef G6LC_MUT_T1_SBLC
      for (int w = 0; w < G6LCCfg.NrWbPorts; w++) begin
        g6lc_t1_sblc_wi: assert (wb_issued_c[w] ===
            mem_q[trans_id_i[w]].issued)
          else $error("sb_lifecycle: equiv wb_issued");
        g6lc_t1_sblc_wr: assert ({wb_dr_c[w], wb_mi_c[w], wb_lm_c[w]} ===
            {mem_q[trans_id_i[w]].sbe.is_double_rd_macro_instr,
             mem_q[trans_id_i[w]].sbe.is_macro_instr,
             mem_q[trans_id_i[w]].sbe.is_last_macro_instr})
          else $error("sb_lifecycle: equiv wb macro flags");
      end
      g6lc_t1_sblc_v: assert (vio_issued_c ===
          mem_q[mem_violation_id_i].issued)
        else $error("sb_lifecycle: equiv vio_issued");
      g6lc_t1_sblc_l: assert ({lur_issued_c, lur_load_c} ===
          {mem_q[lu_replay_id_i].issued,
           (mem_q[lu_replay_id_i].sbe.fu == g6lc_core_pkg::LOAD)})
        else $error("sb_lifecycle: equiv lu_replay");
`endif
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] sb_lifecycle col: checked=%0d", t1_sblc_n);
  end
//pragma translate_on

endmodule
