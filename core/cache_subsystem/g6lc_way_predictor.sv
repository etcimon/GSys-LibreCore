// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U3 MRU way predictor (Inoue/Powell-style).
// PC- or set-indexed table of last-hit way. On access, predicts one way so the
// data array can chip-enable only that way; full-tag compare still runs, and a
// way mispredict costs a 1-cycle data re-read (never wrong data).

module g6lc_way_predictor
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned NR_WAYS    = 4,
    parameter int unsigned NR_ENTRIES = 128,
    parameter int unsigned INDEX_WIDTH = 0  // 0 → use $clog2(NR_ENTRIES) from index_i width
) (
    input  logic                       clk_i,
    input  logic                       rst_ni,
    input  logic                       flush_i,
    // Lookup
    input  logic                       lookup_i,
    input  logic [31:0]                index_i,   // PC or set index (low bits used)
    output logic [$clog2(NR_WAYS)-1:0] way_o,
    output logic [NR_WAYS-1:0]         way_oh_o,
    output logic                       valid_o,
    // Train with the way that actually hit (or was filled)
    input  logic                       update_i,
    input  logic [31:0]                update_index_i,
    input  logic [$clog2(NR_WAYS)-1:0] update_way_i
);

  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);
  localparam int unsigned WAY_W = (NR_WAYS <= 1) ? 1 : $clog2(NR_WAYS);

  typedef struct packed {
    logic              valid;
    logic [WAY_W-1:0]  way;
  } entry_t;

  entry_t [NR_ENTRIES-1:0] mem_d, mem_q;
  logic [IDX_W-1:0] idx, uidx;

  assign idx  = index_i[IDX_W-1:0];
  assign uidx = update_index_i[IDX_W-1:0];

  assign valid_o = mem_q[idx].valid;
  assign way_o   = mem_q[idx].valid ? WAY_W'(mem_q[idx].way) : '0;

  always_comb begin
    way_oh_o = '0;
    if (NR_WAYS == 1) way_oh_o = 1'b1;
    else if (mem_q[idx].valid) way_oh_o[way_o] = 1'b1;
    else way_oh_o[0] = 1'b1;  // cold start: try way 0
  end

  always_comb begin
    mem_d = mem_q;
    if (update_i) begin
      mem_d[uidx].valid = 1'b1;
      mem_d[uidx].way   = WAY_W'(update_way_i);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < NR_ENTRIES; i++) mem_q[i] <= '0;
    end else if (flush_i) begin
      for (int unsigned i = 0; i < NR_ENTRIES; i++) mem_q[i].valid <= 1'b0;
    end else begin
      mem_q <= mem_d;
    end
  end

endmodule
