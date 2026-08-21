// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 TAGE-lite: base bimodal (PC-indexed) + up to 8 tagged components with
// geometric history lengths. Provider = longest matching tagged table, else base.
// Allocation on mispredict into a useless entry; periodic useful-bit decay.

module g6lc_bp_tage
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bht_update_t = logic,
    parameter int unsigned NR_ENTRIES = 128,
    parameter int unsigned NR_TABLES  = 3,
    parameter int unsigned TABLE_ENTRIES = 64,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned GHIST_LEN = 24
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         flush_bp_i,
    input  logic                         debug_mode_i,
    input  logic [CVA6Cfg.VLEN-1:0]      vpc_i,
    input  logic [GHIST_LEN-1:0]         ghist_i,
    input  logic [NR_TABLES-1:0][7:0]    folded_i,
    input  bht_update_t                  bht_update_i,
    output bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] bht_prediction_o,
    // To history/ckpt: request an architectural update
    output logic                         hist_update_valid_o,
    output logic                         hist_update_taken_o
);

  localparam int unsigned OFFSET = CVA6Cfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned NR_ROWS = NR_ENTRIES / CVA6Cfg.INSTR_PER_FETCH;
  localparam int unsigned ROW_ADDR_BITS = $clog2(CVA6Cfg.INSTR_PER_FETCH);
  localparam int unsigned ROW_INDEX_BITS = CVA6Cfg.RVC == 1'b1 ? $clog2(CVA6Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned BASE_IDX_W = (NR_ROWS <= 1) ? 1 : $clog2(NR_ROWS);
  localparam int unsigned TBL_IDX_W = (TABLE_ENTRIES <= 1) ? 1 : $clog2(TABLE_ENTRIES);

  // ----- Base bimodal table (PC index) -----
  typedef struct packed {
    logic       valid;
    logic [1:0] ctr;
  } base_entry_t;

  base_entry_t [NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0] base_d, base_q;
  logic [BASE_IDX_W-1:0] base_index, base_update_index;
  logic [ROW_INDEX_BITS-1:0] update_row;

  assign base_index = vpc_i[OFFSET+:BASE_IDX_W];
  assign base_update_index = bht_update_i.pc[OFFSET+:BASE_IDX_W];
  if (CVA6Cfg.RVC) begin : gen_row
    assign update_row = bht_update_i.pc[ROW_ADDR_BITS+OFFSET-1:OFFSET];
  end else begin : gen_row0
    assign update_row = '0;
  end

  // ----- Tagged tables -----
  logic [NR_TABLES-1:0] hit, taken_t, useful;
  logic [NR_TABLES-1:0][2:0] ctr_t;
  logic [NR_TABLES-1:0][TBL_IDX_W-1:0] t_index, t_uindex;
  logic [NR_TABLES-1:0][TAG_BITS-1:0] t_tag, t_utag;
  logic [NR_TABLES-1:0] t_upd_valid, t_alloc, t_weak;
  logic decay_q;
  logic [15:0] decay_cnt_q;

  for (genvar t = 0; t < NR_TABLES; t++) begin : gen_tables
    // Index = low PC XOR folded history; tag = high PC XOR rotated fold
    assign t_index[t] = vpc_i[OFFSET+:TBL_IDX_W] ^ folded_i[t][TBL_IDX_W-1:0];
    assign t_tag[t]   = vpc_i[OFFSET+TBL_IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_i[t]);
    assign t_uindex[t] = bht_update_i.pc[OFFSET+:TBL_IDX_W] ^ folded_i[t][TBL_IDX_W-1:0];
    assign t_utag[t]   = bht_update_i.pc[OFFSET+TBL_IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_i[t]);

    g6lc_bp_tage_table #(
        .CVA6Cfg    (CVA6Cfg),
        .NR_ENTRIES (TABLE_ENTRIES),
        .TAG_BITS   (TAG_BITS),
        .IDX_BITS   (TBL_IDX_W)
    ) i_table (
        .clk_i,
        .rst_ni,
        .flush_i         (flush_bp_i),
        .index_i         (t_index[t]),
        .tag_i           (t_tag[t]),
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

  // Provider = highest-index hit (longest history by construction of fold rotation)
  logic any_hit;
  logic provider_taken;

  always_comb begin
    any_hit        = 1'b0;
    provider_taken = 1'b0;
    for (int unsigned t = 0; t < NR_TABLES; t++) begin
      if (hit[t]) begin
        any_hit        = 1'b1;
        provider_taken = taken_t[t];
      end
    end
  end

  // Direction prediction per fetch slot (same index for all; RVC row uses base only for alt)
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_pred
    always_comb begin
      if (any_hit) begin
        bht_prediction_o[i].valid = 1'b1;
        bht_prediction_o[i].taken = provider_taken;
      end else begin
        bht_prediction_o[i].valid = base_q[base_index][i].valid;
        bht_prediction_o[i].taken = base_q[base_index][i].ctr[1];
      end
    end
  end

  // ----- Update -----
  assign hist_update_valid_o = bht_update_i.valid &&
      ((CVA6Cfg.DebugEn && !debug_mode_i) || !CVA6Cfg.DebugEn);
  assign hist_update_taken_o = bht_update_i.taken;

  logic base_taken_u;
  logic [1:0] base_ctr_upd;

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
        decay_cnt_q <= decay_cnt_q + 16'd1;
        if (decay_cnt_q == 16'h0fff) decay_q <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned r = 0; r < NR_ROWS; r++)
        for (int unsigned c = 0; c < CVA6Cfg.INSTR_PER_FETCH; c++) base_q[r][c] <= '0;
    end else if (flush_bp_i) begin
      for (int unsigned r = 0; r < NR_ROWS; r++)
        for (int unsigned c = 0; c < CVA6Cfg.INSTR_PER_FETCH; c++) begin
          base_q[r][c].valid <= 1'b0;
          base_q[r][c].ctr   <= 2'b10;
        end
    end else begin
      base_q <= base_d;
    end
  end

endmodule
