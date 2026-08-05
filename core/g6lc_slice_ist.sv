// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U4 Instruction Slice Table (IST) — hint structure only.
// PC-indexed; clearing it at any cycle is behaviour-preserving.
// Learns which PCs belong to an address-generating backward slice.

module g6lc_slice_ist
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned NR_ENTRIES = 64
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,       // clear all (hint-safe)
    // Lookup at dispatch
    input  logic [CVA6Cfg.VLEN-1:0] lookup_pc_i,
    output logic                    is_slice_o,
    // Train: mark a PC as (not) belonging to an address slice
    input  logic                    train_valid_i,
    input  logic [CVA6Cfg.VLEN-1:0] train_pc_i,
    input  logic                    train_is_slice_i
);

  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);
  // Tag = PC bits above the index; drop fetch-align LSBs
  localparam int unsigned TAG_LSB = CVA6Cfg.FETCH_ALIGN_BITS + IDX_W;
  localparam int unsigned TAG_W   = (CVA6Cfg.VLEN > TAG_LSB) ? (CVA6Cfg.VLEN - TAG_LSB) : 1;

  typedef struct packed {
    logic            valid;
    logic            is_slice;
    logic [TAG_W-1:0] tag;
  } entry_t;

  entry_t [NR_ENTRIES-1:0] mem_q, mem_d;

  logic [IDX_W-1:0] lookup_idx, train_idx;
  logic [TAG_W-1:0] lookup_tag, train_tag;

  assign lookup_idx = lookup_pc_i[CVA6Cfg.FETCH_ALIGN_BITS +: IDX_W];
  assign train_idx  = train_pc_i[CVA6Cfg.FETCH_ALIGN_BITS +: IDX_W];
  assign lookup_tag = lookup_pc_i[CVA6Cfg.VLEN-1:TAG_LSB];
  assign train_tag  = train_pc_i[CVA6Cfg.VLEN-1:TAG_LSB];

  // Combinational lookup — single entry, no CAM
  assign is_slice_o = mem_q[lookup_idx].valid &&
                      (mem_q[lookup_idx].tag == lookup_tag) &&
                      mem_q[lookup_idx].is_slice;

  always_comb begin
    mem_d = mem_q;
    if (flush_i) begin
      for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
        mem_d[i].valid = 1'b0;
      end
    end else if (train_valid_i) begin
      mem_d[train_idx].valid    = 1'b1;
      mem_d[train_idx].is_slice = train_is_slice_i;
      mem_d[train_idx].tag      = train_tag;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
        mem_q[i] <= '0;
      end
    end else begin
      mem_q <= mem_d;
    end
  end

endmodule
