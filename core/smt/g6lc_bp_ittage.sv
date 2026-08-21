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
    input  btb_update_t             btb_update_i,
    output btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] btb_prediction_o
);

  localparam int unsigned OFFSET = CVA6Cfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned NR_ROWS = NR_ENTRIES / CVA6Cfg.INSTR_PER_FETCH;
  localparam int unsigned ROW_ADDR_BITS = $clog2(CVA6Cfg.INSTR_PER_FETCH);
  localparam int unsigned ROW_INDEX_BITS = CVA6Cfg.RVC == 1'b1 ? $clog2(CVA6Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned IDX_W = (NR_ROWS <= 1) ? 1 : $clog2(NR_ROWS);

  typedef struct packed {
    logic                    valid;
    logic [TAG_BITS-1:0]     tag;
    logic [CVA6Cfg.VLEN-1:0] target;
  } entry_t;

  entry_t [NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0] mem_d, mem_q;
  logic [IDX_W-1:0] index, uindex;
  logic [ROW_INDEX_BITS-1:0] urow;
  logic [TAG_BITS-1:0] tag, utag;

  assign index  = vpc_i[OFFSET+:IDX_W] ^ folded_i[IDX_W-1:0];
  assign tag    = vpc_i[OFFSET+IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_i);
  assign uindex = btb_update_i.pc[OFFSET+:IDX_W] ^ folded_i[IDX_W-1:0];
  assign utag   = btb_update_i.pc[OFFSET+IDX_W+:TAG_BITS] ^ TAG_BITS'(folded_i);

  if (CVA6Cfg.RVC) begin : gen_row
    assign urow = btb_update_i.pc[ROW_ADDR_BITS+OFFSET-1:OFFSET];
  end else begin : gen_row0
    assign urow = '0;
  end

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_out
    assign btb_prediction_o[i].valid = mem_q[index][i].valid && (mem_q[index][i].tag == tag);
    assign btb_prediction_o[i].target_address = mem_q[index][i].target;
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
