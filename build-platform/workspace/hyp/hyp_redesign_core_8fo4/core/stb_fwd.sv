// hyp8 provenance: REWRITTEN (sv-timing emit at the 8-FO4 budget)
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright 2026 GSys — LibreCore hypothesis core (8-FO4 redesign).
// Description: store buffer forward pipeline (the A141 per-byte youngest-
//   writer merge, staged). F1 registers the per-entry per-byte candidate
//   bits (lane/full-PA match, byte overlap, program-age exclude for
//   speculative entries, hart tag) plus a snapshot of the age matrix.
//   F2 reduces the candidates to per-byte winner one-hots (speculative:
//   the candidate no younger candidate writes; commit queue: the newest
//   in queue order; arrivals override the queue as today). F3 gathers
//   the winning bytes and registers the response — forward data is valid
//   StoreFwdCycles after the request. Slot payloads are stationary and
//   persist >= 2 cycles after a slot frees, so F2/F3 reads of the queue
//   arrays re-pair correctly with the F1 match snapshot.

module stb_fwd
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned           DEPTH_SPEC   = 4,
    parameter int unsigned           DEPTH_COMMIT = 4,
    parameter int unsigned           CBOZ_OFF_W   = 6,
    parameter int unsigned           TAG_W        = 1,
    parameter bit                    AGE_EN       = 1'b1,  // OoOEn
    parameter bit                    HART_OWN     = 1'b0,  // same-hart spec filter
    parameter type                   entry_t      = logic,
    parameter type                   cbo_t        = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,  // clears the F1/F2/F3 records (in-flight forwards die)
    // forward request (load unit): physical address + the load's identity
    input  logic                             req_valid_i,
    input  logic [G6LCCfg.PLEN-1:0]          req_pa_i,
    input  logic [1:0]                       req_size_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] req_tid_i,
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] req_hart_i,
    input  logic [TAG_W-1:0]                 req_tag_i,
    // speculative queue view
    input  entry_t [DEPTH_SPEC-1:0]          spec_entries_i,
    input  logic [DEPTH_SPEC-1:0]            spec_valid_i,
    input  logic [DEPTH_SPEC-1:0][DEPTH_SPEC-1:0] spec_older_i,
    // commit queue view (architectural: always older than the load)
    input  entry_t [DEPTH_COMMIT-1:0]        cmt_entries_i,
    input  logic [DEPTH_COMMIT-1:0]          cmt_valid_i,
    input  logic [$clog2(DEPTH_COMMIT)-1:0]  cmt_rd_ptr_i,
    // arriving-store candidates (the live valid_without_flush term and
    // the staged S1 insert record — both are program-younger terms the
    // emit folded into its same-cycle merge)
    input  logic [1:0]                       ins_valid_i,
    input  logic [1:0][G6LCCfg.TRANS_ID_BITS-1:0] ins_tid_i,
    input  logic [1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ins_hart_i,
    input  logic [1:0][G6LCCfg.PLEN-1:0]     ins_pa_i,
    input  logic [1:0][G6LCCfg.XLEN-1:0]     ins_data_i,
    input  logic [1:0][(G6LCCfg.XLEN/8)-1:0] ins_be_i,
    input  cbo_t [1:0]                       ins_cbo_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] oldest_live_tid_i,
    // F3 response
    output logic                             rsp_valid_o,
    output logic [G6LCCfg.XLEN-1:0]          rsp_data_o,
    output logic [(G6LCCfg.XLEN/8)-1:0]      rsp_be_o,
    output logic                             rsp_possible_o,
    output logic [TAG_W-1:0]                 rsp_tag_o
);

  localparam int unsigned NB = G6LCCfg.XLEN / 8;
  localparam int unsigned LANE_W = $clog2(NB);

  function automatic logic ooo_older(input logic [G6LCCfg.TRANS_ID_BITS-1:0] a,
                                     input logic [G6LCCfg.TRANS_ID_BITS-1:0] b);
    return g6lc_ooo_pkg::ooo_age_older(G6LCCfg.TRANS_ID_BITS, 32'(a), 32'(b),
                                     32'(oldest_live_tid_i));
  endfunction

  // Visibility of a *speculative* store to the querying load — commit-queue
  // entries are architecturally older by construction and exempt, as in
  // the emit's spec_visible.
  function automatic logic spec_visible(input logic [G6LCCfg.TRANS_ID_BITS-1:0] sid);
    return !AGE_EN || ooo_older(sid, req_tid_i);
  endfunction

  function automatic logic pa_eq(input logic [G6LCCfg.PLEN-1:0] a,
                                 input logic [G6LCCfg.PLEN-1:0] b);
    return a[G6LCCfg.PLEN-1:LANE_W] == b[G6LCCfg.PLEN-1:LANE_W];
  endfunction

  function automatic logic cboz_covers(input cbo_t cop,
                                       input logic [G6LCCfg.PLEN-1:0] entry_pa,
                                       input logic [G6LCCfg.PLEN-1:0] byte_pa);
    return G6LCCfg.RVZiCboz && (cop == CBO_ZERO) &&
           (entry_pa[G6LCCfg.PLEN-1:CBOZ_OFF_W] ==
            byte_pa[G6LCCfg.PLEN-1:CBOZ_OFF_W]);
  endfunction

  // svt-stage: begin F1
  // ---------------- F1: candidate match (registered) ----------------
  logic [DEPTH_SPEC-1:0][NB-1:0]   f1_spec_cand_q;
  logic [DEPTH_SPEC-1:0]           f1_spec_cboz_q;
  logic [DEPTH_COMMIT-1:0][NB-1:0] f1_cmt_cand_q;
  logic [DEPTH_COMMIT-1:0]         f1_cmt_cboz_q;
  logic [1:0][NB-1:0]              f1_ins_cand_q;
  logic [1:0]                      f1_ins_cboz_q;
  logic [1:0][G6LCCfg.XLEN-1:0]    f1_ins_data_q;
  logic [DEPTH_SPEC-1:0][DEPTH_SPEC-1:0] f1_older_q;
  logic [$clog2(DEPTH_COMMIT)-1:0] f1_cmt_rd_ptr_q;
  logic                            f1_v_q;
  logic [G6LCCfg.PLEN-1:0]         f1_pa_q;
  logic [TAG_W-1:0]                f1_tag_q;

  // hyp8: the per-entry match and per-byte candidate bits are genvar
  // compare vectors (independent LHS); the F1 registers are one always_ff
  // per record slice, each a single bundled write.
  logic [DEPTH_SPEC-1:0]            f1_spec_match_c;
  logic [DEPTH_SPEC-1:0][NB-1:0]    f1_spec_cand_c;
  logic [DEPTH_SPEC-1:0]            f1_spec_cboz_c;
  logic [DEPTH_COMMIT-1:0]          f1_cmt_match_c;
  logic [DEPTH_COMMIT-1:0][NB-1:0]  f1_cmt_cand_c;
  logic [DEPTH_COMMIT-1:0]          f1_cmt_cboz_c;
  logic [1:0]                       f1_ins_match_c;
  logic [1:0][NB-1:0]               f1_ins_cand_c;
  logic [1:0]                       f1_ins_cboz_c;

  for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_f1_spec
    assign f1_spec_match_c[i] =
        spec_valid_i[i] &&
        spec_visible(spec_entries_i[i].trans_id) &&
        (!HART_OWN || spec_entries_i[i].hart == req_hart_i) &&
        (pa_eq(spec_entries_i[i].address, req_pa_i) ||
         cboz_covers(spec_entries_i[i].cbo_op,
                     spec_entries_i[i].address, req_pa_i));
    assign f1_spec_cboz_c[i] = f1_spec_match_c[i] &&
        (G6LCCfg.RVZiCboz && spec_entries_i[i].cbo_op == CBO_ZERO);
    for (genvar b = 0; b < NB; b++) begin : gen_f1_spec_b
      if (G6LCCfg.RVZiCboz) begin : gen_cboz
        assign f1_spec_cand_c[i][b] =
            (spec_entries_i[i].cbo_op == CBO_ZERO) ?
            (f1_spec_match_c[i] &&
             cboz_covers(spec_entries_i[i].cbo_op,
                         spec_entries_i[i].address,
                         req_pa_i + G6LCCfg.PLEN'(b))) :
            (f1_spec_match_c[i] && spec_entries_i[i].be[b]);
      end else begin : gen_plain
        assign f1_spec_cand_c[i][b] =
            f1_spec_match_c[i] && spec_entries_i[i].be[b];
      end
    end
  end
  for (genvar i = 0; i < DEPTH_COMMIT; i++) begin : gen_f1_cmt
    assign f1_cmt_match_c[i] =
        cmt_valid_i[i] &&
        (pa_eq(cmt_entries_i[i].address, req_pa_i) ||
         cboz_covers(cmt_entries_i[i].cbo_op,
                     cmt_entries_i[i].address, req_pa_i));
    assign f1_cmt_cboz_c[i] = f1_cmt_match_c[i] &&
        (G6LCCfg.RVZiCboz && cmt_entries_i[i].cbo_op == CBO_ZERO);
    for (genvar b = 0; b < NB; b++) begin : gen_f1_cmt_b
      if (G6LCCfg.RVZiCboz) begin : gen_cboz
        assign f1_cmt_cand_c[i][b] =
            (cmt_entries_i[i].cbo_op == CBO_ZERO) ?
            (f1_cmt_match_c[i] &&
             cboz_covers(cmt_entries_i[i].cbo_op,
                         cmt_entries_i[i].address,
                         req_pa_i + G6LCCfg.PLEN'(b))) :
            (f1_cmt_match_c[i] && cmt_entries_i[i].be[b]);
      end else begin : gen_plain
        assign f1_cmt_cand_c[i][b] =
            f1_cmt_match_c[i] && cmt_entries_i[i].be[b];
      end
    end
  end
  for (genvar k = 0; k < 2; k++) begin : gen_f1_ins
    assign f1_ins_match_c[k] =
        ins_valid_i[k] &&
        (!AGE_EN || ooo_older(ins_tid_i[k], req_tid_i)) &&
        (!HART_OWN || ins_hart_i[k] == req_hart_i) &&
        (pa_eq(ins_pa_i[k], req_pa_i) ||
         cboz_covers(ins_cbo_i[k], ins_pa_i[k], req_pa_i));
    assign f1_ins_cboz_c[k] = f1_ins_match_c[k] &&
        G6LCCfg.RVZiCboz && ins_cbo_i[k] == CBO_ZERO;
    for (genvar b = 0; b < NB; b++) begin : gen_f1_ins_b
      if (G6LCCfg.RVZiCboz) begin : gen_cboz
        assign f1_ins_cand_c[k][b] =
            (ins_cbo_i[k] == CBO_ZERO) ?
            (f1_ins_match_c[k] &&
             cboz_covers(ins_cbo_i[k], ins_pa_i[k],
                         req_pa_i + G6LCCfg.PLEN'(b))) :
            (f1_ins_match_c[k] && ins_be_i[k][b]);
      end else begin : gen_plain
        assign f1_ins_cand_c[k][b] = f1_ins_match_c[k] && ins_be_i[k][b];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_f1
    if (!rst_ni) begin
      f1_v_q <= 1'b0;
      f1_spec_cand_q <= '0; f1_spec_cboz_q <= '0;
      f1_cmt_cand_q  <= '0; f1_cmt_cboz_q  <= '0;
      f1_ins_cand_q  <= '0; f1_ins_cboz_q  <= '0; f1_ins_data_q <= '0;
      f1_older_q     <= '0; f1_cmt_rd_ptr_q <= '0;
      f1_pa_q        <= '0; f1_tag_q       <= '0;
    end else if (flush_i) begin
      f1_v_q <= 1'b0;
    end else begin
      f1_v_q <= req_valid_i;
      if (req_valid_i) begin
        f1_pa_q  <= req_pa_i;
        f1_tag_q <= req_tag_i;
        f1_older_q     <= spec_older_i;
        f1_cmt_rd_ptr_q <= cmt_rd_ptr_i;
        f1_spec_cand_q <= f1_spec_cand_c;
        f1_spec_cboz_q <= f1_spec_cboz_c;
        f1_cmt_cand_q  <= f1_cmt_cand_c;
        f1_cmt_cboz_q  <= f1_cmt_cboz_c;
        f1_ins_cand_q  <= f1_ins_cand_c;
        f1_ins_cboz_q  <= f1_ins_cboz_c;
        f1_ins_data_q  <= ins_data_i;
      end
    end
  end

  // svt-stage: end F1
  // svt-stage: begin F2
  // ---------------- F2: per-byte winner select (registered) ----------------
  // spec winners: the candidate no younger candidate also writes (A141).
  // commit winner: the newest entry in queue order (the emit's ordered
  // walk ending on the last match). Arrivals override queued sources.
  logic [NB-1:0][DEPTH_SPEC-1:0]   f2_spec_win_q;
  logic [DEPTH_SPEC-1:0]           f2_spec_cboz_q;
  logic [NB-1:0][$clog2(DEPTH_COMMIT)-1:0] f2_cmt_win_q;
  logic [NB-1:0]                   f2_cmt_hit_q;
  logic [NB-1:0]                   f2_cmt_cboz_q;
  logic [NB-1:0][1:0]              f2_ins_win_q;
  logic [NB-1:0]                   f2_ins_cboz_q;
  logic [1:0][G6LCCfg.XLEN-1:0]    f2_ins_data_q;
  logic [NB-1:0]                   f2_cover_q;
  logic                            f2_v_q;
  logic [TAG_W-1:0]                f2_tag_q;

  // hyp8: per-byte winners are computed combinationally as independent
  // cones and registered per byte:
  //  * spec: candidate i wins byte b iff no YOUNGER candidate also
  //    writes it -- |(age-row-i AND byte-b candidate column), a single
  //    AND/OR reduction per (b,i), the A141 form.
  //  * commit: newest writer in queue order -- rotate the byte column by
  //    rd_ptr, isolate the HIGHEST set bit with a downward prefix OR,
  //    index by popcount(hi-1), rotate back.
  //  * arrivals keep their fixed 2-deep priority and win outright.
  localparam int unsigned CW2 = $clog2(DEPTH_COMMIT);

  // byte-column transpose of the spec candidate matrix
  logic [NB-1:0][DEPTH_SPEC-1:0]   f1_sc_b;
  logic [NB-1:0][DEPTH_COMMIT-1:0] f1_cc_b;
  for (genvar b = 0; b < NB; b++) begin : gen_tr_b
    for (genvar i = 0; i < DEPTH_SPEC; i++)
      assign f1_sc_b[b][i] = f1_spec_cand_q[i][b];
    for (genvar i = 0; i < DEPTH_COMMIT; i++)
      assign f1_cc_b[b][i] = f1_cmt_cand_q[i][b];
  end

  logic [NB-1:0][DEPTH_SPEC-1:0]           spec_win_c;
  logic [NB-1:0][CW2-1:0]                  cwin_c;
  logic [NB-1:0]                           cmt_any_c, cmt_cboz_c;
  logic [NB-1:0][1:0]                      ins_win_c;
  logic [NB-1:0]                           ins_cboz_c, cover_c;

  for (genvar b = 0; b < NB; b++) begin : gen_f2
    // spec winners
    for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_swin
      assign spec_win_c[b][i] =
          f1_sc_b[b][i] && !(|(f1_older_q[i] & f1_sc_b[b]));
    end
    // commit winner: rotate, highest-set, rotate back
    logic [DEPTH_COMMIT-1:0] rot, above, hi;
    for (genvar k = 0; k < DEPTH_COMMIT; k++) begin : gen_rot
      assign rot[k] = f1_cc_b[b][f1_cmt_rd_ptr_q + CW2'(k)];
    end
    always_comb begin : c_above
      above = rot >> 1;
      for (int unsigned l = 1; l < DEPTH_COMMIT; l = l << 1)
        above = above | (above >> l);
    end
    assign hi         = rot & ~above;
    assign cmt_any_c[b] = |rot;
    assign cwin_c[b]    = f1_cmt_rd_ptr_q +
                          CW2'($countones(hi - DEPTH_COMMIT'(1)));
    assign cmt_cboz_c[b] = cmt_any_c[b] && f1_cmt_cboz_q[cwin_c[b]];
    // arrivals (fixed priority; index 0 is program-youngest)
    assign ins_win_c[b]  = f1_ins_cand_q[0][b] ? 2'd0 :
                           f1_ins_cand_q[1][b] ? 2'd1 : 2'd3;
    assign ins_cboz_c[b] = (f1_ins_cand_q[0][b] && f1_ins_cboz_q[0]) ||
                           (!f1_ins_cand_q[0][b] && f1_ins_cand_q[1][b] &&
                            f1_ins_cboz_q[1]);
    assign cover_c[b] = (|f1_sc_b[b]) || cmt_any_c[b] ||
                        (|{f1_ins_cand_q[0][b], f1_ins_cand_q[1][b]});
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_f2
    if (!rst_ni) begin
      f2_v_q <= 1'b0;
      f2_spec_cboz_q <= '0;
      f2_ins_data_q <= '0;
      f2_tag_q <= '0;
    end else if (flush_i) begin
      f2_v_q <= 1'b0;
    end else begin
      f2_v_q <= f1_v_q;
      f2_tag_q <= f1_tag_q;
      f2_ins_data_q <= f1_ins_data_q;
      f2_spec_cboz_q <= f1_spec_cboz_q;
    end
  end
  for (genvar b = 0; b < NB; b++) begin : gen_p_f2
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        f2_spec_win_q[b] <= '0;
        f2_cmt_win_q[b] <= '0; f2_cmt_hit_q[b] <= '0; f2_cmt_cboz_q[b] <= '0;
        f2_ins_win_q[b]  <= '0; f2_ins_cboz_q[b]  <= '0;
        f2_cover_q[b]    <= '0;
      end else begin
        f2_spec_win_q[b] <= spec_win_c[b];
        f2_cmt_win_q[b]  <= cwin_c[b];
        f2_cmt_hit_q[b]  <= cmt_any_c[b];
        f2_cmt_cboz_q[b] <= cmt_cboz_c[b];
        f2_ins_win_q[b]  <= ins_win_c[b];
        f2_ins_cboz_q[b] <= ins_cboz_c[b];
        f2_cover_q[b]    <= cover_c[b];
      end
    end
  end

  // svt-stage: end F2
  // svt-stage: begin F3
  // ---------------- F3: winner data gather + response ----------------
  logic [G6LCCfg.XLEN-1:0] f3_data;
  // hyp8: spec-byte gather is a masked-OR tree (one-hot winners) instead
  // of a serial |=, and the priority select is a flat expression.
  localparam int unsigned SLV = (DEPTH_SPEC > 1) ? $clog2(DEPTH_SPEC) : 1;
  for (genvar b = 0; b < NB; b++) begin : gen_f3
    logic [SLV:0][DEPTH_SPEC-1:0][7:0] sr;
    for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_st
      // cbo.zero winners contribute '0 -- the emit masks the data
      // explicitly rather than relying on the posted payload being zero
      assign sr[0][i] = {8{f2_spec_win_q[b][i] && !f2_spec_cboz_q[i]}} &
                        spec_entries_i[i].data[8*b +: 8];
    end
    for (genvar l = 0; l < SLV; l++) begin : gen_lvl
      for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_or
        if (i < ((DEPTH_SPEC + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
          if ((2 * i + 1) < ((DEPTH_SPEC + (1 << l) - 1) >> l)) begin : gen_pair
            assign sr[l+1][i] = sr[l][2*i] | sr[l][2*i+1];
          end else begin : gen_odd
            assign sr[l+1][i] = sr[l][2*i];
          end
        end else begin : gen_pad
          assign sr[l+1][i] = '0;
        end
      end
    end
    // arrivals win over every queued source (emit's overwrite order)
    assign f3_data[8*b +: 8] =
        (f2_ins_win_q[b] != 2'd3) ?
            (f2_ins_cboz_q[b] ? 8'h00
                              : f2_ins_data_q[f2_ins_win_q[b]][8*b +: 8]) :
        (|f2_spec_win_q[b])     ? sr[SLV][0] :
        f2_cmt_hit_q[b]         ? (f2_cmt_cboz_q[b] ? 8'h00
                              : cmt_entries_i[f2_cmt_win_q[b]].data[8*b +: 8])
                                : '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_f3
    if (!rst_ni) begin
      rsp_valid_o    <= 1'b0;
      rsp_data_o     <= '0;
      rsp_be_o       <= '0;
      rsp_possible_o <= 1'b0;
      rsp_tag_o      <= '0;
    end else if (flush_i) begin
      rsp_valid_o    <= 1'b0;
      rsp_possible_o <= 1'b0;
    end else begin
      rsp_valid_o    <= f2_v_q;
      rsp_tag_o      <= f2_tag_q;
      rsp_be_o       <= f2_cover_q;
      rsp_possible_o <= f2_v_q && (|f2_cover_q);
      // a cbo.zero spec winner contributes '0 (its data field is the
      // zero payload by construction); mask them for clarity
      for (int unsigned b = 0; b < NB; b++)
        rsp_data_o[8*b +: 8] <= f3_data[8*b +: 8];
    end
  end

  // svt-stage: end F3
  // svt-stage: class F1 value
  // svt-stage: class F2 value
  // svt-stage: class F3 value
endmodule
