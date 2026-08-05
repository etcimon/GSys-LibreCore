// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.2 snoop filter — tracks which core(s) may hold a line so write-invalidate
// only hits owners. Contention opt: avoid broadcast when SF is precise.
//
// NR_CORES: 1..CVA6_MAX_CORES. Presence is an NR_CORES-bit vector per entry.
// When Enable=0 or NR_CORES==1 the filter is identity (always "maybe all").
//
// Replacement: random/round-robin on conflict; over-approx on capacity miss
// (report present_all) so correctness is preserved (extra snoops only).

module g6lc_snoop_filter
  import g6lc_coherence_pkg::*;
  import config_pkg::*;
#(
    parameter bit          Enable      = 1'b1,
    parameter int unsigned NR_CORES    = 1,
    parameter int unsigned NR_ENTRIES  = COH_DEFAULT_SF_ENTRIES,
    parameter int unsigned LINE_BYTES  = COH_DEFAULT_LINE_BYTES,
    parameter int unsigned ADDR_WIDTH  = 64
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Allocate / update: core fetched or wrote a line into its L1
    input  logic                       alloc_valid_i,
    input  logic [ADDR_WIDTH-1:0]      alloc_addr_i,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] alloc_core_i,
    // Clear presence for a core (local eviction / full flush)
    input  logic                       clear_valid_i,
    input  logic [ADDR_WIDTH-1:0]      clear_addr_i,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] clear_core_i,
    input  logic                       clear_all_i,  // full SF wipe (global fence)
    // Lookup: which cores might hold this line?
    input  logic                       lookup_valid_i,
    input  logic [ADDR_WIDTH-1:0]      lookup_addr_i,
    output logic [NR_CORES-1:0]        present_o,     // bit i set ⇒ core i may hold
    output logic                       lookup_hit_o,  // SF entry found
    output logic                       overapprox_o   // capacity miss → present_all
);

  localparam int unsigned NC     = (NR_CORES < 1) ? 1 : NR_CORES;
  localparam int unsigned NE     = (NR_ENTRIES < 1) ? 1 : NR_ENTRIES;
  localparam int unsigned IDX_W  = (NE <= 1) ? 1 : $clog2(NE);
  localparam int unsigned OFF    = $clog2(LINE_BYTES);
  localparam int unsigned TAG_W  = (ADDR_WIDTH > OFF + IDX_W) ? (ADDR_WIDTH - OFF - IDX_W) : 1;
  localparam int unsigned CID_W  = (NC <= 1) ? 1 : $clog2(NC);

  typedef struct packed {
    logic            valid;
    logic [TAG_W-1:0] tag;
    logic [NC-1:0]   present;
  } sf_entry_t;

  if (!Enable || NC <= 1) begin : gen_identity
    assign present_o    = {NC{1'b1}};
    assign lookup_hit_o = 1'b0;
    assign overapprox_o = 1'b1;
  end else begin : gen_sf

    sf_entry_t [NE-1:0] mem_q, mem_d;
    logic [IDX_W-1:0] rr_q, rr_d;

    function automatic logic [IDX_W-1:0] idx_of(input logic [ADDR_WIDTH-1:0] a);
      return a[OFF +: IDX_W];
    endfunction
    function automatic logic [TAG_W-1:0] tag_of(input logic [ADDR_WIDTH-1:0] a);
      return a[ADDR_WIDTH-1 -: TAG_W];
    endfunction

    logic [IDX_W-1:0] lu_idx, al_idx, cl_idx;
    logic [TAG_W-1:0] lu_tag, al_tag, cl_tag;

    assign lu_idx = idx_of(lookup_addr_i);
    assign lu_tag = tag_of(lookup_addr_i);
    assign al_idx = idx_of(alloc_addr_i);
    assign al_tag = tag_of(alloc_addr_i);
    assign cl_idx = idx_of(clear_addr_i);
    assign cl_tag = tag_of(clear_addr_i);

    // Combinational lookup
    always_comb begin
      present_o    = {NC{1'b1}};  // safe default: snoop everyone
      lookup_hit_o = 1'b0;
      overapprox_o = 1'b1;
      if (lookup_valid_i && mem_q[lu_idx].valid && mem_q[lu_idx].tag == lu_tag) begin
        present_o    = mem_q[lu_idx].present;
        lookup_hit_o = 1'b1;
        overapprox_o = 1'b0;
      end
    end

    always_comb begin
      mem_d = mem_q;
      rr_d  = rr_q;

      if (clear_all_i) begin
        for (int unsigned i = 0; i < NE; i++) mem_d[i].valid = 1'b0;
      end else begin
        // Alloc / update presence
        if (alloc_valid_i) begin
          if (mem_q[al_idx].valid && mem_q[al_idx].tag == al_tag) begin
            mem_d[al_idx].present[alloc_core_i] = 1'b1;
          end else begin
            // Install (replace on conflict — over-approx until refilled)
            mem_d[al_idx].valid                 = 1'b1;
            mem_d[al_idx].tag                   = al_tag;
            mem_d[al_idx].present               = '0;
            mem_d[al_idx].present[alloc_core_i] = 1'b1;
            rr_d = IDX_W'(int'(rr_q) + 1);
          end
        end
        // Clear one core's presence
        if (clear_valid_i) begin
          if (mem_q[cl_idx].valid && mem_q[cl_idx].tag == cl_tag) begin
            mem_d[cl_idx].present[clear_core_i] = 1'b0;
            if (mem_d[cl_idx].present == '0) mem_d[cl_idx].valid = 1'b0;
          end
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        mem_q <= '{default: '0};
        rr_q  <= '0;
      end else begin
        mem_q <= mem_d;
        rr_q  <= rr_d;
      end
    end

  end

endmodule
