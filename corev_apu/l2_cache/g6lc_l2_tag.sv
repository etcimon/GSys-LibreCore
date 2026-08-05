// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.0 L2 tag array — parallel SET_ASSOC tag compare (single cycle).
// Stored in flops for modest geometries; swap to tc_sram when SET*ASSOC large.

module g6lc_l2_tag #(
    parameter int unsigned NUM_SETS   = 512,
    parameter int unsigned SET_ASSOC  = 8,
    parameter int unsigned TAG_WIDTH  = 48,
    parameter int unsigned IDX_WIDTH  = 9
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // Lookup
    input  logic                          lookup_i,
    input  logic [IDX_WIDTH-1:0]          index_i,
    input  logic [TAG_WIDTH-1:0]          tag_i,
    output logic                          hit_o,
    output logic [$clog2(SET_ASSOC)-1:0]  way_o,
    output logic [SET_ASSOC-1:0]          way_valid_o,
    // Probe tag of a selected way (for victim/evict address rebuild)
    input  logic [$clog2(SET_ASSOC)-1:0]  probe_way_i,
    output logic [TAG_WIDTH-1:0]          probe_tag_o,
    output logic                          probe_valid_o,
    // Allocate / update on fill
    input  logic                          write_i,
    input  logic [IDX_WIDTH-1:0]          write_index_i,
    input  logic [$clog2(SET_ASSOC)-1:0]  write_way_i,
    input  logic [TAG_WIDTH-1:0]          write_tag_i,
    input  logic                          write_valid_i,
    // Invalidate way
    input  logic                          inval_i,
    input  logic [IDX_WIDTH-1:0]          inval_index_i,
    input  logic [$clog2(SET_ASSOC)-1:0]  inval_way_i,
    // Address-match invalidate (L3→L2 inclusive back-inval): clear every way
    // in the set whose tag matches. Single-cycle, combinational into tags_d.
    input  logic                          inval_match_i,
    input  logic [IDX_WIDTH-1:0]          inval_match_index_i,
    input  logic [TAG_WIDTH-1:0]          inval_match_tag_i
);

  localparam int unsigned WAY_W = (SET_ASSOC <= 1) ? 1 : $clog2(SET_ASSOC);

  typedef struct packed {
    logic                 valid;
    logic [TAG_WIDTH-1:0] tag;
  } tag_entry_t;

  // [sets][ways]
  tag_entry_t [NUM_SETS-1:0][SET_ASSOC-1:0] tags_q, tags_d;

  // Parallel compare (contention-critical path: keep short)
  logic [SET_ASSOC-1:0] hit_way;
  always_comb begin
    hit_way = '0;
    for (int unsigned w = 0; w < SET_ASSOC; w++) begin
      hit_way[w] = lookup_i && tags_q[index_i][w].valid &&
                   (tags_q[index_i][w].tag == tag_i);
    end
  end
  assign hit_o = |hit_way;

  // One-hot → binary way
  always_comb begin
    way_o = '0;
    for (int unsigned w = 0; w < SET_ASSOC; w++) begin
      if (hit_way[w]) way_o = WAY_W'(w);
    end
  end

  always_comb begin
    for (int unsigned w = 0; w < SET_ASSOC; w++)
      way_valid_o[w] = tags_q[index_i][w].valid;
  end

  assign probe_tag_o   = tags_q[index_i][probe_way_i].tag;
  assign probe_valid_o = tags_q[index_i][probe_way_i].valid;

  // Victim: first invalid, else way 0 (RRIP later)
  // Exposed via write_way_i from parent.

  always_comb begin
    tags_d = tags_q;
    if (write_i) begin
      tags_d[write_index_i][write_way_i].valid = write_valid_i;
      tags_d[write_index_i][write_way_i].tag   = write_tag_i;
    end
    if (inval_i) begin
      tags_d[inval_index_i][inval_way_i].valid = 1'b0;
    end
    // Inclusive upper-level victim: drop matching L2 line (all ways, tag match)
    if (inval_match_i) begin
      for (int unsigned w = 0; w < SET_ASSOC; w++) begin
        if (tags_q[inval_match_index_i][w].valid &&
            tags_q[inval_match_index_i][w].tag == inval_match_tag_i) begin
          tags_d[inval_match_index_i][w].valid = 1'b0;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned s = 0; s < NUM_SETS; s++)
        for (int unsigned w = 0; w < SET_ASSOC; w++)
          tags_q[s][w] <= '0;
    end else begin
      tags_q <= tags_d;
    end
  end

endmodule
