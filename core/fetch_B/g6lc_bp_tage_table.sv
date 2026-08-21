// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1: one TAGE tagged component ΓÇö tag + 3-bit ctr + useful bit.
// Small tables use flops (FPGA-friendly and small); sizing is CVA6Cfg-driven.
// Allocation / useful decay live in the update path only.

module g6lc_bp_tage_table
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned NR_ENTRIES = 64,
    parameter int unsigned TAG_BITS   = 8,
    parameter int unsigned IDX_BITS   = 6
) (
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  logic                   flush_i,
    // Lookup
    input  logic [IDX_BITS-1:0]    index_i,
    input  logic [TAG_BITS-1:0]    tag_i,
    output logic                   hit_o,
    output logic                   taken_o,
    output logic [2:0]             ctr_o,
    output logic                   useful_o,
    // Update / allocate
    input  logic                   update_valid_i,
    input  logic [IDX_BITS-1:0]    update_index_i,
    input  logic [TAG_BITS-1:0]    update_tag_i,
    input  logic                   update_taken_i,
    input  logic                   update_alloc_i,   // allocate this entry
    input  logic                   update_weak_i,    // ctr was weak provider
    input  logic                   decay_useful_i    // periodic u-bit clear
);

  typedef struct packed {
    logic                valid;
    logic [TAG_BITS-1:0] tag;
    logic [2:0]          ctr;  // 0..7, taken if >= 4
    logic                u;    // useful
  } entry_t;

  entry_t [NR_ENTRIES-1:0] mem_d, mem_q;
  entry_t rd;

  assign rd      = mem_q[index_i];
  assign hit_o   = rd.valid && (rd.tag == tag_i);
  assign taken_o = rd.ctr[2];
  assign ctr_o   = rd.ctr;
  assign useful_o = rd.u;

  always_comb begin
    mem_d = mem_q;
    if (update_valid_i) begin
      if (update_alloc_i) begin
        mem_d[update_index_i].valid = 1'b1;
        mem_d[update_index_i].tag   = update_tag_i;
        mem_d[update_index_i].ctr   = update_taken_i ? 3'b100 : 3'b011;
        mem_d[update_index_i].u     = 1'b0;
      end else if (mem_q[update_index_i].valid &&
                   mem_q[update_index_i].tag == update_tag_i) begin
        // Hit update: saturating 3-bit counter
        if (update_taken_i) begin
          if (mem_q[update_index_i].ctr != 3'b111)
            mem_d[update_index_i].ctr = mem_q[update_index_i].ctr + 3'b001;
        end else begin
          if (mem_q[update_index_i].ctr != 3'b000)
            mem_d[update_index_i].ctr = mem_q[update_index_i].ctr - 3'b001;
        end
        if (update_weak_i) mem_d[update_index_i].u = 1'b1;
      end
    end
    if (decay_useful_i) begin
      for (int unsigned i = 0; i < NR_ENTRIES; i++) mem_d[i].u = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < NR_ENTRIES; i++) mem_q[i] <= '0;
    end else if (flush_i) begin
      for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
        mem_q[i].valid <= 1'b0;
        mem_q[i].u     <= 1'b0;
      end
    end else begin
      mem_q <= mem_d;
    end
  end

endmodule
