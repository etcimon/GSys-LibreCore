// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 ITTAGE-lite: history-tagged indirect target table. Same role as BTB but
// indexed by PC XOR folded history so netfilter/ndo_* style targets are
// distinguishable. Exposes the existing btb_prediction_t port shape.

module g6lc_bp_ittage
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type btb_update_t = logic,
    parameter type btb_prediction_t = logic,
    parameter int unsigned NR_ENTRIES = 32,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned FOLD_W = 8
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic                    debug_mode_i,
    input  logic [CVA6Cfg.VLEN-1:0] vpc_i,
    input  logic [FOLD_W-1:0]       folded_i,
    // Folded history of the resolve/train hart for update index/tag.
    input  logic [FOLD_W-1:0]       folded_update_i,
    input  btb_update_t             btb_update_i,
    output btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] btb_prediction_o
);

  localparam int unsigned OFFSET = CVA6Cfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned NR_ROWS = NR_ENTRIES / CVA6Cfg.INSTR_PER_FETCH;
  // Column bits select the instruction slot inside a row; row bits sit above
  // them, so an unaligned window's slots hash by their own PCs.
  localparam int unsigned COL_BITS = (CVA6Cfg.INSTR_PER_FETCH <= 1) ? 0 : $clog2(CVA6Cfg.INSTR_PER_FETCH);
  localparam int unsigned SLOT_W   = (COL_BITS == 0) ? 1 : COL_BITS;
  localparam int unsigned IDX_W = (NR_ROWS <= 1) ? 1 : $clog2(NR_ROWS);

  typedef struct packed {
    logic                    valid;
    logic [TAG_BITS-1:0]     tag;
    logic [CVA6Cfg.VLEN-1:0] target;
  } entry_t;

  entry_t [NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0] mem_d, mem_q;
  logic [CVA6Cfg.VLEN-1:0] slot_pc [CVA6Cfg.INSTR_PER_FETCH];
  logic [IDX_W-1:0] index  [CVA6Cfg.INSTR_PER_FETCH];
  logic [IDX_W-1:0] uindex;
  logic [SLOT_W-1:0] urow;
  logic [TAG_BITS-1:0] tag [CVA6Cfg.INSTR_PER_FETCH];
  logic [TAG_BITS-1:0] utag;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_slot_pc
    assign slot_pc[i] = vpc_i + CVA6Cfg.VLEN'(i << OFFSET);
    assign index[i]   = slot_pc[i][OFFSET+COL_BITS+:IDX_W] ^ folded_i[IDX_W-1:0];
    assign tag[i]     = slot_pc[i][OFFSET+COL_BITS+IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_i);
  end
  assign uindex = btb_update_i.pc[OFFSET+COL_BITS+:IDX_W] ^ folded_update_i[IDX_W-1:0];
  assign utag   = btb_update_i.pc[OFFSET+COL_BITS+IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_update_i);

  if (COL_BITS == 0) begin : gen_row0
    assign urow = '0;
  end else begin : gen_row
    assign urow = btb_update_i.pc[OFFSET+:COL_BITS];
  end

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_out
    if (COL_BITS == 0) begin : gen_out_nocol
      assign btb_prediction_o[i].valid = mem_q[index[i]][0].valid && (mem_q[index[i]][0].tag == tag[i]);
      assign btb_prediction_o[i].target_address = mem_q[index[i]][0].target;
    end else begin : gen_out_col
      logic [SLOT_W-1:0] col;
      assign col = slot_pc[i][OFFSET+:COL_BITS];
      assign btb_prediction_o[i].valid = mem_q[index[i]][col].valid && (mem_q[index[i]][col].tag == tag[i]);
      assign btb_prediction_o[i].target_address = mem_q[index[i]][col].target;
    end
  end

  always_comb begin
    mem_d = mem_q;
    if (btb_update_i.valid && !(CVA6Cfg.DebugEn && debug_mode_i)) begin
      mem_d[uindex][urow].valid  = 1'b1;
      mem_d[uindex][urow].tag    = utag;
      mem_d[uindex][urow].target = btb_update_i.target_address;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mem_q <= '0;
    else if (flush_i) begin
      for (int unsigned r = 0; r < NR_ROWS; r++)
        for (int unsigned c = 0; c < CVA6Cfg.INSTR_PER_FETCH; c++) mem_q[r][c].valid <= 1'b0;
    end else mem_q <= mem_d;
  end

endmodule
