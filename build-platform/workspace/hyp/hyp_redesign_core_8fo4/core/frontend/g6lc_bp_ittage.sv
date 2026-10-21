// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget; P1/P2 lookup
// staging and the checkpoint-carried training token added for Hyp8)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 ITTAGE-lite: history-tagged indirect target table. Same role as BTB but
// indexed by PC XOR folded history so netfilter/ndo_* style targets are
// distinguishable. Exposes the existing btb_prediction_t port shape.
//
// hyp8 staging (override path, rank 4): same contract as g6lc_bp_tage —
//   P1 registers the PC^fold index/hash per slot; P2 runs the row read +
//   tag compare off the P1 registers and registers the {valid, target}
//   verdict plus the lookup token (lk_*_o) for checkpoint-carried training.
//   btb_update_i is the registered resolve record; the update index/tag is
//   the checkpoint token when its entry lives (upd_tok_v_i), else the
//   registered train-bank fallback fold — same hashing, register-sourced.
// Table geometry, hash functions and the debug-mode update gate are
// unchanged from the reference.

module g6lc_bp_ittage
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type btb_update_t = logic,
    parameter type btb_prediction_t = logic,
    parameter int unsigned NR_ENTRIES = 32,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned FOLD_W = 8,
    parameter int unsigned ITT_IDX_W =
        ((NR_ENTRIES / G6LCCfg.INSTR_PER_FETCH) <= 1) ? 1 : $clog2(NR_ENTRIES / G6LCCfg.INSTR_PER_FETCH)
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic                    debug_mode_i,
    input  logic [G6LCCfg.VLEN-1:0] vpc_i,
    input  logic [FOLD_W-1:0]       folded_i,
    // Folded history of the resolve/train hart for update index/tag.
    // hyp8: registered in g6lc_bp_top so the update path is register-sourced.
    input  logic [FOLD_W-1:0]       folded_update_i,
    // hyp8: checkpoint-carried lookup token for this CF (resolve+1).
    input  logic                    upd_tok_v_i,
    input  logic [ITT_IDX_W-1:0]    upd_tok_idx_i,
    input  logic [TAG_BITS-1:0]     upd_tok_tag_i,
    // hyp8: registered update record (resolve+1).
    input  btb_update_t             btb_update_i,
    // hyp8: registered verdict — live during the frontend stage-S cycle.
    output btb_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] btb_prediction_o,
    // hyp8: verdict-time lookup identity per fetch slot (for the checkpoint's
    // training token).
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][ITT_IDX_W-1:0] lk_index_o,
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][TAG_BITS-1:0]  lk_tag_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_bp_ittage status=proposal target=10-adjusted-FO4
  // svt-plan: cone PC/history hash -> indexed row/column read ->
  // tag validity and wide indirect target output.
  // svt-plan: boundary hash/address preparation -> table read/tag select;
  // or table response -> frontend provider selection when memory dominates.
  // svt-plan: carry slot PC, folded history snapshot, hart/fetch epoch,
  // target/tag/valid and query token; carry folded_update_i with training PC.
  // svt-plan: ownership flush/debug suppression applies at the defined
  // acceptance event; delayed training cannot revive invalidated entries.
  // svt-plan: effect separates address hashing from table/read selection;
  // bank by slot/row to limit mux fanout while preserving collision policy.
  // svt-plan: cost query/training registers and later indirect prediction;
  // frontend must keep an early fallback and resolve the matching token.
  // svt-plan: limit training and query use different history snapshots;
  // a live folded_i sampled a cycle later describes a different prediction.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 32.9 adjusted FO4 on the
  // Nangate45 board): indirect target predictor: table update state.
  // svt-pipe: require-contract
  // svt-pipe: protocol it valid=flush_i
  // svt-pipe: no-cut on=mem_q
  // svt-pipe: cycle it q=mem_q d=btb_prediction_o hold=flush_i steps=1

  localparam int unsigned OFFSET = G6LCCfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned NR_ROWS = NR_ENTRIES / G6LCCfg.INSTR_PER_FETCH;
  // Column bits select the instruction slot inside a row; row bits sit above
  // them, so an unaligned window's slots hash by their own PCs.
  localparam int unsigned COL_BITS = (G6LCCfg.INSTR_PER_FETCH <= 1) ? 0 : $clog2(G6LCCfg.INSTR_PER_FETCH);
  localparam int unsigned SLOT_W   = (COL_BITS == 0) ? 1 : COL_BITS;
  localparam int unsigned IDX_W = (NR_ROWS <= 1) ? 1 : $clog2(NR_ROWS);

  typedef struct packed {
    logic                    valid;
    logic [TAG_BITS-1:0]     tag;
    logic [G6LCCfg.VLEN-1:0] target;
  } entry_t;

  entry_t [NR_ROWS-1:0][G6LCCfg.INSTR_PER_FETCH-1:0] mem_d, mem_q;
  logic [G6LCCfg.VLEN-1:0] slot_pc [G6LCCfg.INSTR_PER_FETCH];
  // P1 hash (comb) and its registers; the read/column select rides the same
  // register stage.
  logic [IDX_W-1:0] index_c [G6LCCfg.INSTR_PER_FETCH];
  logic [IDX_W-1:0] index_q [G6LCCfg.INSTR_PER_FETCH];
  logic [SLOT_W-1:0] col_c  [G6LCCfg.INSTR_PER_FETCH];
  logic [SLOT_W-1:0] col_q  [G6LCCfg.INSTR_PER_FETCH];
  logic [TAG_BITS-1:0] tag_c [G6LCCfg.INSTR_PER_FETCH];
  logic [TAG_BITS-1:0] tag_q [G6LCCfg.INSTR_PER_FETCH];
  logic [IDX_W-1:0] uindex;
  logic [SLOT_W-1:0] urow;
  logic [TAG_BITS-1:0] utag;

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
    // hyp8 P1: PC ^ folded-history hash, captured by the stage-1 registers.
    assign index_c[i] = slot_pc[i][OFFSET+COL_BITS+:IDX_W] ^ folded_i[IDX_W-1:0];
    assign tag_c[i]   = slot_pc[i][OFFSET+COL_BITS+IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_i);
    if (COL_BITS == 0) begin : gen_col_single
      assign col_c[i] = '0;
    end else begin : gen_col_slot
      assign col_c[i] = slot_pc[i][OFFSET+:COL_BITS];
    end
  end

  // hyp8: update index/tag = the checkpoint token when its entry lives, else
  // the reference hash on the registered update PC and the registered
  // train-bank fold.
  assign uindex = upd_tok_v_i ? upd_tok_idx_i
                              : btb_update_i.pc[OFFSET+COL_BITS+:IDX_W] ^ folded_update_i[IDX_W-1:0];
  assign utag   = upd_tok_v_i ? upd_tok_tag_i
                              : btb_update_i.pc[OFFSET+COL_BITS+IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_update_i);

  if (COL_BITS == 0) begin : gen_row0
    assign urow = '0;
  end else begin : gen_row
    assign urow = btb_update_i.pc[OFFSET+:COL_BITS];
  end

  // hyp8 P2: row read + tag compare off the P1 registers, registered verdict
  // {valid, target} and the verdict-time lookup identity {index, tag}.
  for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_out
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        btb_prediction_o[i] <= '0;
        lk_index_o[i]       <= '0;
        lk_tag_o[i]         <= '0;
      end else begin
        btb_prediction_o[i].valid          <= mem_q[index_q[i]][col_q[i]].valid
                                            && (mem_q[index_q[i]][col_q[i]].tag == tag_q[i]);
        btb_prediction_o[i].target_address <= mem_q[index_q[i]][col_q[i]].target;
        lk_index_o[i] <= index_q[i];
        lk_tag_o[i]   <= tag_q[i];
      end
    end
  end

  always_comb begin
    mem_d = mem_q;
    if (btb_update_i.valid && !(G6LCCfg.DebugEn && debug_mode_i)) begin
      mem_d[uindex][urow].valid  = 1'b1;
      mem_d[uindex][urow].tag    = utag;
      mem_d[uindex][urow].target = btb_update_i.target_address;
    end
  end

  // hyp8 P1 registers: the slot hash of the stage-B window. Advisory data —
  // killed windows are deadened by the epoch check, no flush needed.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin
        index_q[i] <= '0;
        col_q[i]   <= '0;
        tag_q[i]   <= '0;
      end
    end else begin
      for (int unsigned i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin
        index_q[i] <= index_c[i];
        col_q[i]   <= col_c[i];
        tag_q[i]   <= tag_c[i];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mem_q <= '0;
    else if (flush_i) begin
      for (int unsigned r = 0; r < NR_ROWS; r++)
        for (int unsigned c = 0; c < G6LCCfg.INSTR_PER_FETCH; c++) mem_q[r][c].valid <= 1'b0;
    end else mem_q <= mem_d;
  end

endmodule
