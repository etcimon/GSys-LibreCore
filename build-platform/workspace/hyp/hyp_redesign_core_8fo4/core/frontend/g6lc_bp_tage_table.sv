// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1: one TAGE tagged component — tag + 3-bit ctr + useful bit.
// Small tables use flops (FPGA-friendly and small); sizing is G6LCCfg-driven.
// Allocation / useful decay live in the update path only.

module g6lc_bp_tage_table
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned NR_ENTRIES = 64,
    parameter int unsigned TAG_BITS   = 8,
    parameter int unsigned IDX_BITS   = 6,
    parameter int unsigned NR_LOOKUPS = 1
) (
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  logic                   flush_i,
    // Lookup (one read port per fetch slot)
    input  logic [NR_LOOKUPS-1:0][IDX_BITS-1:0] index_i,
    input  logic [NR_LOOKUPS-1:0][TAG_BITS-1:0] tag_i,
    output logic [NR_LOOKUPS-1:0]               hit_o,
    output logic [NR_LOOKUPS-1:0]               taken_o,
    output logic [NR_LOOKUPS-1:0][2:0]          ctr_o,
    output logic [NR_LOOKUPS-1:0]               useful_o,
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

  // Flop array: each fetch slot gets an independent combinational read.
  for (genvar l = 0; l < NR_LOOKUPS; l++) begin : gen_lookup
    entry_t rd;
    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_bp_tage_table  region=3620  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: mem_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to mem_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     mem_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node13211 c=3.50 slack=1.00 */
//     /* node13212 c=4.50 slack=0.00 */
//     /* node13213 c=4.50 slack=0.00 */
//     /* node13214 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// sv-timing: origin emit/core-8fo4/corrected\_prepared\0161\g6lc_bp_tage_table.sv:1:1 edit=0
  // prepared from <src>/core/frontend/g6lc_bp_tage_table.sv; see svt_pragma_preprocess.json
  // END sv-timing auto-correct (balance_mux rewrite)
assign rd         = mem_q[index_i[l]];
    assign hit_o[l]   = rd.valid && (rd.tag == tag_i[l]);
    assign taken_o[l] = rd.ctr[2];
    assign ctr_o[l]   = rd.ctr;
    assign useful_o[l] = rd.u;
  end

  always_comb begin
    mem_d = mem_q;
    // A147: row-local training (the A134/A135 pattern, applied by sv-timing's
    // initial-IR preprocessor before correction): each row computes its own
    // update from its registered entry and the row selected by
    // update_index_i takes it — no indexed read -> counter -> indexed
    // write-decode chain. Exact for any NR_ENTRIES <= 2**IDX_BITS (an
    // out-of-range index writes no row in either form).
    // svt-pipe: row-local-applied train rows=NR_ENTRIES index=update_index_i
    for (int unsigned __svt_row_train = 0; __svt_row_train < NR_ENTRIES; __svt_row_train++) begin
if (update_index_i == __svt_row_train) begin
if (update_valid_i) begin
      if (update_alloc_i) begin
        mem_d[__svt_row_train].valid = 1'b1;
        mem_d[__svt_row_train].tag   = update_tag_i;
        mem_d[__svt_row_train].ctr   = update_taken_i ? 3'b100 : 3'b011;
        mem_d[__svt_row_train].u     = 1'b0;
      end else if (mem_q[__svt_row_train].valid &&
                   mem_q[__svt_row_train].tag == update_tag_i) begin
        // Hit update: saturating 3-bit counter
        if (update_taken_i) begin
          if (mem_q[__svt_row_train].ctr != 3'b111)
            mem_d[__svt_row_train].ctr = mem_q[__svt_row_train].ctr + 3'b001;
        end else begin
          if (mem_q[__svt_row_train].ctr != 3'b000)
            mem_d[__svt_row_train].ctr = mem_q[__svt_row_train].ctr - 3'b001;
        end
        if (update_weak_i) mem_d[__svt_row_train].u = 1'b1;
      end
    end
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
