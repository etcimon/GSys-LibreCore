// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget; P1/P2 lookup
// staging and the checkpoint-carried training token added for Hyp8)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 TAGE-lite: base bimodal (PC-indexed) + up to 8 tagged components with
// geometric history lengths. Provider = longest matching tagged table, else base.
// Allocation on mispredict into a useless entry; periodic useful-bit decay.
//
// hyp8 staging (override path, rank 4):
//   P1 (lookup stage): the folded-history hash — table index, tag and the
//     base row/column — is registered at the window's stage-B edge, so the
//     hash/XOR trees close at a register instead of feeding the table read.
//   P2 (verdict stage): each tagged table's read + tag-hit compare runs
//     combinationally off the P1 registers, the provider tournament selects,
//     and the per-slot verdict {valid, taken} is registered at the next edge.
//     bht_prediction_o is therefore a registered verdict live during the
//     frontend's stage-S cycle — the override module consumes it directly,
//     one cycle later than the reference. The lookup identity {index, tag}
//     is registered beside the verdict (lk_*_o) and rides the prediction
//     checkpoint: training uses the SAME index/tag the lookup used and never
//     recomputes the hash.
//   Update: bht_update_i is the resolve record already registered once in
//     g6lc_bp_top (the checkpoint entry read is registered too — the two are
//     cycle-aligned, resolve+1). The update index/tag is the checkpoint
//     token when the entry lives (upd_tok_v_i), else the registered
//     train-bank fallback fold exactly as the reference computed it.
// Table geometry, hashing functions, provider/tie rules, allocation and
// useful-decay policy are unchanged from the reference.

module g6lc_bp_tage
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type bht_update_t = logic,
    parameter int unsigned NR_ENTRIES = 128,
    parameter int unsigned NR_TABLES  = 3,
    parameter int unsigned TABLE_ENTRIES = 64,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned GHIST_LEN = 24,
    parameter int unsigned TBL_IDX_W = (TABLE_ENTRIES <= 1) ? 1 : $clog2(TABLE_ENTRIES)
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         flush_bp_i,
    input  logic                         debug_mode_i,
    input  logic [G6LCCfg.VLEN-1:0]      vpc_i,
    input  logic [GHIST_LEN-1:0]         ghist_i,
    input  logic [NR_TABLES-1:0][7:0]    folded_i,
    // Folded history of the resolve/train hart: tagged-table update index/tag
    // hash the resolving branch's own history bank, not the live fetch fold.
    // hyp8: registered in g6lc_bp_top so the update path is register-sourced.
    input  logic [NR_TABLES-1:0][7:0]    folded_update_i,
    // hyp8: the resolving CF's checkpoint token — the registered index/tag its
    // own lookup used (one entry per table). Valid when the checkpoint entry
    // was live at resolve+1; falls back to folded_update_i when it was not.
    input  logic                         upd_tok_v_i,
    input  logic [NR_TABLES-1:0][TBL_IDX_W-1:0] upd_tok_idx_i,
    input  logic [NR_TABLES-1:0][TAG_BITS-1:0]  upd_tok_tag_i,
    // hyp8: registered update record (presented one cycle after the resolve,
    // aligned with the checkpoint entry read).
    input  bht_update_t                  bht_update_i,
    // hyp8: registered verdict — live during the frontend stage-S cycle.
    output bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] bht_prediction_o,
    // hyp8: the verdict-time lookup identity per fetch slot (the index/tag the
    // lookup used), exported for the checkpoint's training token.
    output logic [NR_TABLES-1:0][G6LCCfg.INSTR_PER_FETCH-1:0][TBL_IDX_W-1:0] lk_index_o,
    output logic [NR_TABLES-1:0][G6LCCfg.INSTR_PER_FETCH-1:0][TAG_BITS-1:0]  lk_tag_o,
    // To history/ckpt: request an architectural update
    output logic                         hist_update_valid_o,
    output logic                         hist_update_taken_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_bp_tage status=proposal target=10-adjusted-FO4
  // svt-plan: cone PC/history hashing and table reads feed ordered provider
  // selection; base update/allocation/decay are separate state recurrences.
  // svt-plan: boundary table hit/counter candidates -> provider/alternate
  // selection; merge candidates in a balanced tree preserving table priority.
  // svt-plan: carry PC/slot, history snapshot, provider/alternate identity,
  // confidence, hart/fetch epoch; align base prediction with tagged candidates.
  // svt-plan: training register addresses/outcomes, not stale updated rows;
  // preserve same-row update/allocate/decay order and folded_update_i context.
  // svt-plan: effect splits lookup from provider selection; local base-row
  // update and banked decay enables avoid a global read-modify-write chain.
  // svt-plan: cost candidate registers and later prediction; history update
  // fires once per accepted training event, independent of pipeline stalls.
  // svt-plan: limit frontend needs early fallback and token-based correction;
  // registered provider alone cannot be paired with a newer query's base result.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 29.2 adjusted FO4 on the
  // Nangate45 board): TAGE: table update and decay state.
  // svt-pipe: require-contract
  // svt-pipe: protocol tg valid=flush_bp_i
  // svt-pipe: no-cut on=decay_cnt_q
  // svt-pipe: cycle tg q=decay_cnt_q d=hist_update_valid_o hold=flush_bp_i steps=1

  localparam int unsigned OFFSET = G6LCCfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned NR_ROWS = NR_ENTRIES / G6LCCfg.INSTR_PER_FETCH;
  // Column bits select the instruction slot inside a row; row bits sit above
  // them. Output slot i is the instruction at column i of the aligned fetch
  // block (see gen_slot_pc), so its own PC bits drive row/column.
  localparam int unsigned COL_BITS = (G6LCCfg.INSTR_PER_FETCH <= 1) ? 0 : $clog2(G6LCCfg.INSTR_PER_FETCH);
  localparam int unsigned SLOT_W   = (COL_BITS == 0) ? 1 : COL_BITS;
  localparam int unsigned BASE_IDX_W = (NR_ROWS <= 1) ? 1 : $clog2(NR_ROWS);

  // svt-stage: begin P1
  // ----- Base bimodal table (PC index) -----
  typedef struct packed {
    logic       valid;
    logic [1:0] ctr;
  } base_entry_t;

  base_entry_t [NR_ROWS-1:0][G6LCCfg.INSTR_PER_FETCH-1:0] base_d, base_q;
  logic [G6LCCfg.VLEN-1:0] slot_pc [G6LCCfg.INSTR_PER_FETCH];

  // Base-table row of a PC. Direct: the BASE_IDX_W bits above the column bits.
  // BPBaseHash (T23): XOR the next BASE_IDX_W bits in, so two branches whose PCs
  // agree in the index window but differ above it (the T21i P2 alias pair at
  // row 751, `fdt_ro_probe_+0xfa` vs `fdt_get_property_by_offset_+0x18`) land in
  // different rows. Same function on the predict and the update path, one XOR
  // level on the row index (timing-neutral: the row register follows). When the
  // PC is too narrow for a second window the fold degenerates to the direct row.
  localparam int unsigned BASE_LO = OFFSET + COL_BITS;
  localparam bit BASE_HASH_FOLD = G6LCCfg.BPBaseHash && (BASE_LO + 2*BASE_IDX_W <= G6LCCfg.VLEN);
  // Second window base; aliases the first window when the fold is off so the
  // part-select is always in range (the XOR is then dropped, not applied twice).
  localparam int unsigned BASE_HI = BASE_HASH_FOLD ? BASE_LO + BASE_IDX_W : BASE_LO;
  function automatic logic [BASE_IDX_W-1:0] base_row_of(input logic [G6LCCfg.VLEN-1:0] pc);
    logic [BASE_IDX_W-1:0] row;
    row = pc[BASE_LO +: BASE_IDX_W];
    if (BASE_HASH_FOLD) row = row ^ pc[BASE_HI +: BASE_IDX_W];
    return row;
  endfunction
  // P1 hash results (combinational, captured into the stage-1 registers).
  logic [BASE_IDX_W-1:0] base_row_c  [G6LCCfg.INSTR_PER_FETCH];
  logic [SLOT_W-1:0]     base_col_c  [G6LCCfg.INSTR_PER_FETCH];
  // P1 registered lookup hash.
  logic [BASE_IDX_W-1:0] base_row_q  [G6LCCfg.INSTR_PER_FETCH];
  logic [SLOT_W-1:0]     base_col_q  [G6LCCfg.INSTR_PER_FETCH];
  logic [BASE_IDX_W-1:0] base_update_index;
  logic [SLOT_W-1:0]     update_row;

  for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_slot_pc
    // T21e: output slot i is consumed by COLUMN (frontend.sv
    // gen_prediction_shifted reads prediction[addr[i][2:1]] and saves
    // prediction[NrInstr-1] for the unaligned leftover), so slot i's PC is
    // the aligned window base plus i instructions -- not vpc_i + i, which on
    // an unaligned window (a redirect target mid-block) made every slot read
    // a neighbour PC's entry. The base / tagged / target indices and tags
    // derived from slot_pc then match what the resolving branch trains with.
    if (COL_BITS == 0) begin : gen_slot_pc_single
      assign slot_pc[i] = vpc_i;
    end else begin : gen_slot_pc_col
      assign slot_pc[i] = {vpc_i[G6LCCfg.VLEN-1:OFFSET+COL_BITS], COL_BITS'(i), {OFFSET{1'b0}}};
    end
    // hyp8 P1: the hash of slot i's own PC — combinational here, registered
    // below so the base read and the tagged-table reads run off registers.
    assign base_row_c[i] = base_row_of(slot_pc[i]);
    if (COL_BITS == 0) begin : gen_nocol
      assign base_col_c[i] = '0;
    end else begin : gen_col
      assign base_col_c[i] = slot_pc[i][OFFSET +: COL_BITS];
    end
  end

  // ----- Tagged tables -----
  // Per-slot lookups: each fetch slot hashes its own instruction PC so two
  // branches in one window can carry opposite predictions.
  logic [NR_TABLES-1:0][G6LCCfg.INSTR_PER_FETCH-1:0] hit, taken_t, useful;
  logic [NR_TABLES-1:0][G6LCCfg.INSTR_PER_FETCH-1:0][2:0] ctr_t;
  // P1 hash results (comb) and the P1 registers the table read uses.
  logic [NR_TABLES-1:0][G6LCCfg.INSTR_PER_FETCH-1:0][TBL_IDX_W-1:0] t_index_c, t_index_q;
  logic [NR_TABLES-1:0][G6LCCfg.INSTR_PER_FETCH-1:0][TAG_BITS-1:0]  t_tag_c, t_tag_q;
  logic [NR_TABLES-1:0][TBL_IDX_W-1:0] t_uindex;
  logic [NR_TABLES-1:0][TAG_BITS-1:0] t_utag;
  logic [NR_TABLES-1:0] t_upd_valid, t_alloc, t_weak;
  logic decay_q;
  logic [11:0] decay_cnt_q;

  for (genvar t = 0; t < NR_TABLES; t++) begin : gen_tables
    // Index = low PC XOR folded history; tag = high PC XOR rotated fold.
    // Predict folds come from the fetch hart (folded_i); update folds come
    // from the resolving branch's own hart (folded_update_i).
    for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_slot_idx
      assign t_index_c[t][i] = slot_pc[i][OFFSET+:TBL_IDX_W] ^ folded_i[t][TBL_IDX_W-1:0];
      assign t_tag_c[t][i]   = slot_pc[i][OFFSET+TBL_IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_i[t]);
    end
    // hyp8: the training index/tag is the checkpoint token (the index/tag the
    // resolving CF's own lookup used) when that entry survives; the fallback
    // recomputes the hash on the registered update PC and the registered
    // train-bank fold — same function, register-sourced (rank 4).
    assign t_uindex[t] = upd_tok_v_i ? upd_tok_idx_i[t]
                                   : bht_update_i.pc[OFFSET+:TBL_IDX_W] ^ folded_update_i[t][TBL_IDX_W-1:0];
    assign t_utag[t]   = upd_tok_v_i ? upd_tok_tag_i[t]
                                   : bht_update_i.pc[OFFSET+TBL_IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_update_i[t]);

    g6lc_bp_tage_table #(
        .G6LCCfg    (G6LCCfg),
        .NR_ENTRIES (TABLE_ENTRIES),
        .TAG_BITS   (TAG_BITS),
        .IDX_BITS   (TBL_IDX_W),
        .NR_LOOKUPS (G6LCCfg.INSTR_PER_FETCH)
    ) i_table (
        .clk_i,
        .rst_ni,
        .flush_i         (flush_bp_i),
        // hyp8 P2: the table read + hit compare run off the P1 hash registers
        // and their outputs are captured by the verdict registers below.
        .index_i         (t_index_q[t]),
        .tag_i           (t_tag_q[t]),
        .hit_o           (hit[t]),
        .taken_o         (taken_t[t]),
        .ctr_o           (ctr_t[t]),
        .useful_o        (useful[t]),
        .update_valid_i  (t_upd_valid[t]),
        .update_index_i  (t_uindex[t]),
        .update_tag_i    (t_utag[t]),
        .update_taken_i  (bht_update_i.taken),
        .update_alloc_i  (t_alloc[t]),
        .update_weak_i   (t_weak[t]),
        .decay_useful_i  (decay_q)
    );
  end

  // ------------------------------------------------------------------
  // hyp8 P1 registers: the folded-history hash of the stage-B window.
  // Advisory data — a killed window's stale hash is deadened downstream by
  // the epoch check, so no flush is applied here.
  // ------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin
        for (int unsigned t = 0; t < NR_TABLES; t++) begin
          t_index_q[t][i] <= '0;
          t_tag_q[t][i]   <= '0;
        end
        base_row_q[i] <= '0;
        base_col_q[i] <= '0;
      end
    end else begin
      for (int unsigned i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin
        for (int unsigned t = 0; t < NR_TABLES; t++) begin
          t_index_q[t][i] <= t_index_c[t][i];
          t_tag_q[t][i]   <= t_tag_c[t][i];
        end
        base_row_q[i] <= base_row_c[i];
        base_col_q[i] <= base_col_c[i];
      end
    end
  end

  // Provider per slot = highest-index hit (longest history by construction of
  // fold rotation). Each slot's prediction is owned by its own PC's lookup.
  // svt-stage: end P1
  // svt-stage: begin P2 window=1
  // hyp8 P2: comb off the P1 registers; the verdict registers follow.
  logic [G6LCCfg.INSTR_PER_FETCH-1:0] any_hit;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0] provider_taken;

  always_comb begin
    for (int unsigned i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin
      any_hit[i]        = 1'b0;
      provider_taken[i] = 1'b0;
      for (int unsigned t = 0; t < NR_TABLES; t++) begin
        if (hit[t][i]) begin
          any_hit[i]        = 1'b1;
          provider_taken[i] = taken_t[t][i];
        end
      end
    end
  end

  // Direction prediction per fetch slot: provider when a tagged table hits,
  // else the base counter — merged combinatorially and registered as the
  // verdict so the loop/statcor override merges in front of cf_select stay a
  // thin two-mux chain.
  logic [G6LCCfg.INSTR_PER_FETCH-1:0] pv_valid_c, pv_taken_c;
  for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_pred
    always_comb begin
      if (any_hit[i]) begin
        pv_valid_c[i] = 1'b1;
        pv_taken_c[i] = provider_taken[i];
      end else begin
        pv_valid_c[i] = base_q[base_row_q[i]][base_col_q[i]].valid;
        pv_taken_c[i] = base_q[base_row_q[i]][base_col_q[i]].ctr[1];
      end
    end
  end

  // hyp8 P2 verdict registers: the prediction the frontend consumes during
  // stage S, plus the lookup identity the checkpoint stores for training.
  bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] verdict_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin
        verdict_q[i] <= '0;
        for (int unsigned t = 0; t < NR_TABLES; t++) begin
          lk_index_o[t][i] <= '0;
          lk_tag_o[t][i]   <= '0;
        end
      end
    end else begin
      for (int unsigned i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin
        verdict_q[i].valid <= pv_valid_c[i];
        verdict_q[i].taken <= pv_taken_c[i];
        for (int unsigned t = 0; t < NR_TABLES; t++) begin
          lk_index_o[t][i] <= t_index_q[t][i];
          lk_tag_o[t][i]   <= t_tag_q[t][i];
        end
      end
    end
  end

  // svt-stage: end P2
  for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_out
    assign bht_prediction_o[i] = verdict_q[i];
  end

  // ----- Update -----
  // hyp8: bht_update_i is the registered resolve record (resolve+1), aligned
  // with the registered checkpoint entry read in g6lc_bp_top.
  assign hist_update_valid_o = bht_update_i.valid &&
      ((G6LCCfg.DebugEn && !debug_mode_i) || !G6LCCfg.DebugEn);
  assign hist_update_taken_o = bht_update_i.taken;

  logic base_taken_u;
  logic [1:0] base_ctr_upd;

  if (COL_BITS == 0) begin : gen_upd_nocol
    assign base_update_index = base_row_of(bht_update_i.pc);
    assign update_row        = '0;
  end else begin : gen_upd_col
    assign base_update_index = base_row_of(bht_update_i.pc);
    assign update_row        = bht_update_i.pc[OFFSET +: COL_BITS];
  end

  assign base_taken_u  = base_q[base_update_index][update_row].ctr[1];
  assign base_ctr_upd  = base_q[base_update_index][update_row].ctr;

  always_comb begin
    base_d      = base_q;
    t_upd_valid = '0;
    t_alloc     = '0;
    t_weak      = '0;

    if (hist_update_valid_o) begin
      // Train base bimodal
      base_d[base_update_index][update_row].valid = 1'b1;
      if (bht_update_i.taken) begin
        if (base_ctr_upd != 2'b11)
          base_d[base_update_index][update_row].ctr = base_ctr_upd + 2'b01;
      end else begin
        if (base_ctr_upd != 2'b00)
          base_d[base_update_index][update_row].ctr = base_ctr_upd - 2'b01;
      end

      // Train / allocate tagged components. Always issue an update; allocate into
      // the longest table when the base direction was wrong (lite TAGE policy).
      for (int unsigned t = 0; t < NR_TABLES; t++) begin
        t_upd_valid[t] = 1'b1;
        t_alloc[t]     = 1'b0;
        t_weak[t]      = 1'b0;
      end
      if (base_taken_u != bht_update_i.taken && NR_TABLES > 0) begin
        t_alloc[NR_TABLES-1] = 1'b1;
      end
    end
  end

  // Decay useful bits every 2^12 updates
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      decay_cnt_q <= '0;
      decay_q     <= 1'b0;
    end else begin
      decay_q <= 1'b0;
      if (hist_update_valid_o) begin
        decay_cnt_q <= decay_cnt_q + 12'd1;
        if (&decay_cnt_q) decay_q <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned r = 0; r < NR_ROWS; r++)
        for (int unsigned c = 0; c < G6LCCfg.INSTR_PER_FETCH; c++) base_q[r][c] <= '0;
    end else if (flush_bp_i) begin
      for (int unsigned r = 0; r < NR_ROWS; r++)
        for (int unsigned c = 0; c < G6LCCfg.INSTR_PER_FETCH; c++) begin
          base_q[r][c].valid <= 1'b0;
          base_q[r][c].ctr   <= 2'b10;
        end
    end else begin
      base_q <= base_d;
    end
  end

  // svt-stage: class P1 value
  // svt-stage: class P2 value
endmodule
