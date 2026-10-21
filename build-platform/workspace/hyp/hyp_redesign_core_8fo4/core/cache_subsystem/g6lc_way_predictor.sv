// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
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
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
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

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_way_predictor status=proposal target=10-adjusted-FO4
  // svt-plan: cone indexed {valid,way} read then binary-to-one-hot decode;
  // update index drives a separate small table write.
  // svt-plan: reshape decode way per row before bounded row selection;
  // one-hot stored ways are an area alternative when NR_WAYS is small.
  // svt-plan: boundary optional lookup preparation -> selected way hint;
  // svt-plan: carry request index/token and cache epoch across a lookup edge.
  // svt-plan: ownership a stale hint must cause full tag verification or
  // retry, never a hit; preserve invalid-entry default and flush priority.
  // svt-plan: effect removes selected binary-way decode from the serial
  // lookup path; banking bounds row mux depth without changing hint latency.
  // svt-plan: cost wider row data or query registers; later hints help only
  // if the cache can launch lookup earlier or tolerate a fallback access.
  // svt-plan: limit tag validity is authoritative; delaying the hint alone
  // can reduce usefulness even when its local path becomes shorter.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 23.2 adjusted FO4 on the
  // Nangate45 board): way predictor: table update.
  // svt-pipe: require-contract
  // svt-pipe: protocol wp valid=lookup_i flush=flush_i
  // svt-pipe: no-cut on=mem_q
  // svt-pipe: cycle wp q=mem_q d=valid_o hold=lookup_i steps=1

  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);
  localparam int unsigned WAY_W = (NR_WAYS <= 1) ? 1 : $clog2(NR_WAYS);

  typedef struct packed {
    logic              valid;
    logic [WAY_W-1:0]  way;
  } entry_t;

  entry_t [NR_ENTRIES-1:0] mem_d, mem_q;
  logic [IDX_W-1:0] idx, uidx;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_way_predictor  region=3722  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: mem_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to mem_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     mem_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node13455 c=3.50 slack=1.00 */
//     /* node13456 c=4.50 slack=0.00 */
//     /* node13457 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign idx  = index_i[IDX_W-1:0];
  assign uidx = update_index_i[IDX_W-1:0];

  // hyp8: one registered boundary on the lookup decode (svt-pipe
  // q=mem_q d=valid_o hold=lookup_i). The hint registers when a lookup is
  // presented and holds otherwise, so the consumer at verdict time reads
  // the prediction issued for ITS request rather than the latest
  // speculative probe. Consequence: a chip-enable launched the same cycle
  // as the lookup sees the previous hint and may take the all-ways
  // re-read fallback — the tag compare keeps correctness regardless.
  logic                    valid_q;
  logic [WAY_W-1:0]        way_q;
  logic [NR_WAYS-1:0]      way_oh_q;
  logic [WAY_W-1:0]        way_c;
  logic [NR_WAYS-1:0]      way_oh_c;

  assign way_c = mem_q[idx].valid ? WAY_W'(mem_q[idx].way) : '0;

  always_comb begin
    way_oh_c = '0;
    if (NR_WAYS == 1) way_oh_c = '1;
    else if (mem_q[idx].valid) way_oh_c[way_c] = 1'b1;
    else way_oh_c[0] = 1'b1;  // cold start: try way 0
  end

  assign valid_o = valid_q;
  assign way_o   = way_q;
  assign way_oh_o = way_oh_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_lookup
    if (!rst_ni) begin
      valid_q  <= 1'b0;
      way_q    <= '0;
      way_oh_q <= {{(NR_WAYS-1){1'b0}}, 1'b1};
    end else if (lookup_i) begin
      valid_q  <= mem_q[idx].valid;
      way_q    <= way_c;
      way_oh_q <= way_oh_c;
    end
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
