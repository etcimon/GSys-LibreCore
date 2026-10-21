// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
// Modified by: Etienne Cimon (2026) - A139 pipeline-design comments.
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 19.04.2017
// Description: Load Store Unit, handles address calculation and memory interface signals


// ------------------
// LSU Control
// ------------------
// The LSU consists of two independent blocks which share a common address translation block.
// One block is the load unit, the other one is the store unit. They will signal their readiness
// with separate signals. If they are not ready the LSU control should keep the last applied signals stable.
// Furthermore it can be the case that another request for one of the two store units arrives in which case
// the LSU control should sample it and store it for later application to the units. It does so, by storing it in a
// two element FIFO. This is necessary as we only know very late in the cycle whether the load/store will succeed (address check,
// TLB hit mainly). So we better unconditionally allow another request to arrive and store this request in case we need to.
module lsu_bypass
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type lsu_ctrl_t = logic,
    parameter type bp_resolve_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic flush_i,
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,

    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input lsu_ctrl_t lsu_req_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic      lsu_req_valid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic      pop_ld_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic      pop_st_i,

    // Result from branch unit - EX_STAGE
    input bp_resolve_t resolved_branch_i,

    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output lsu_ctrl_t lsu_ctrl_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic      ready_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin lsu_bypass status=proposal target=10-adjusted-FO4
  // svt-plan: cone posted request, two pop sources and branch/cancel
  // marking share memory/count/pointer update; ready_o currently means empty.
  // svt-plan: reshape separate payload writes from per-entry live/kill
  // metadata; derive count/pointers directly from normalized accepted events.
  // svt-plan: boundary optional held head packet -> load/store destination;
  // include that packet in capacity and preserve the current posting protocol.
  // svt-plan: carry complete lsu_req, TID lifetime and sticky speculative
  // cancellation; a transient cancelled_mask cannot be the only remembered kill.
  // svt-plan: effect removes wide mem_n dependencies from occupancy and
  // exposes only a local validity mux on the common bypass path.
  // svt-plan: cost head storage if staged and possible LSU dispatch delay;
  // simultaneous pop_ld_i/pop_st_i semantics need normalization before retiming.
  // svt-plan: limit do not replace empty-only ready with ordinary FIFO
  // not-full semantics without changing the upstream producer's contract.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 32.3 adjusted FO4 on the
  // Nangate45 board): LSU bypass queue: push / pop next-state.
  // svt-pipe: require-contract
  // svt-pipe: protocol lsu valid=lsu_req_valid_i flush=flush_i
  // svt-pipe: no-cut on=mem_n
  // svt-pipe: cycle lsu q=mem_n d=ready_o hold=lsu_req_valid_i steps=1

  lsu_ctrl_t [1:0] mem_n, mem_q;
  logic read_pointer_n, read_pointer_q;
  logic write_pointer_n, write_pointer_q;
  logic [1:0] status_cnt_n, status_cnt_q;

  logic empty;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=lsu_bypass  region=3183  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: mem_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to mem_q
// order expect: read_pointer_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to read_pointer_q
// order expect: status_cnt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to status_cnt_q
// order expect: write_pointer_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to write_pointer_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     mem_q <= …; // sv-timing: cycle 1/1 on clk_i
//     read_pointer_q <= …; // sv-timing: cycle 1/1 on clk_i
//     status_cnt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     write_pointer_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node11801 c=3.50 slack=0.00 */
//     /* node11802 c=3.50 slack=0.00 */
//     /* node11803 c=3.50 slack=0.00 */
//     /* node11804 c=3.50 slack=0.00 */
//     /* node11805 c=3.50 slack=0.00 */
//     /* node11806 c=3.50 slack=0.00 */
//     /* node11807 c=3.50 slack=0.00 */
//     /* node11808 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign empty   = (status_cnt_q == 0);
  assign ready_o = empty;

  always_comb begin
    automatic logic [1:0] status_cnt;
    automatic logic write_pointer;
    automatic logic read_pointer;

    status_cnt = status_cnt_q;
    write_pointer = write_pointer_q;
    read_pointer = read_pointer_q;

    mem_n = mem_q;
    // we've got a valid LSU request
    if (lsu_req_valid_i) begin
      mem_n[write_pointer_q] = lsu_req_i;
      if (lsu_req_i.is_speculative_load && resolved_branch_i.valid &&
          (!G6LCCfg.OoOEn || !resolved_branch_i.is_mispredict)) begin
        if (resolved_branch_i.is_mispredict) begin
          // missprediction: mark speculative loads as misspredicted
          mem_n[write_pointer_q].is_speculative_load_miss = 1'b1;
        end else begin
          // correct prediction: the load is no longer speculative
          mem_n[write_pointer_q].is_speculative_load = 1'b0;
        end
      end
      write_pointer++;
      status_cnt++;
    end

    if (pop_ld_i) begin
      // invalidate the result
      mem_n[read_pointer_q].valid = 1'b0;
      read_pointer++;
      status_cnt--;
    end

    if (pop_st_i) begin
      // invalidate the result
      mem_n[read_pointer_q].valid = 1'b0;
      read_pointer++;
      status_cnt--;
    end

    if (pop_st_i && pop_ld_i) mem_n = '0;

    // T35: a cancelled STORE (AMOs included, fu == STORE) is marked the same
    // way. The mask names a tid only until the cancelled entry is
    // commit-dropped; a store held here behind a translation (PTW) or a full
    // store buffer outlives that window, and without the sticky mark the
    // store unit pushed it into the speculative queue under a tid whose slot
    // was already free (server1 Linux, cycle 76,935,847) or re-allocated.
    if (G6LCCfg.OoOEn) begin
      for (int unsigned i = 0; i < 2; i++) begin
        if (mem_n[i].valid && (mem_n[i].fu == LOAD || mem_n[i].fu == STORE) &&
            cancelled_mask_i[mem_n[i].trans_id])
          mem_n[i].is_speculative_load_miss = 1'b1;
      end
    end

    if (flush_i) begin
      status_cnt = '0;
      write_pointer = '0;
      read_pointer = '0;
      mem_n = '0;
    end
    // default assignments
    read_pointer_n  = read_pointer;
    write_pointer_n = write_pointer;
    status_cnt_n    = status_cnt;
  end

  // hyp8: registered head — the emit bypassed a live request through the
  // `empty ? lsu_req_i : mem_q[rd]` output mux (the 32.3-FO4 cone). The
  // head packet is now captured from the NEXT-state queue (post-pop), so
  // every request appears at lsu_ctrl_o one cycle after it posts (+1 on
  // request presentation; recorded). mem_n[read_pointer_n] already
  // equals the arriving request when the queue drains to empty, so no
  // separate bypass path is needed.
  lsu_ctrl_t head_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_head
    if (~rst_ni) head_q <= '0;
    else         head_q <= mem_n[read_pointer_n];
  end

  always_comb begin : output_assignments
    lsu_ctrl_o = head_q;
    if (G6LCCfg.OoOEn && lsu_ctrl_o.valid && (lsu_ctrl_o.fu == LOAD || lsu_ctrl_o.fu == STORE) &&
        cancelled_mask_i[lsu_ctrl_o.trans_id])
      lsu_ctrl_o.is_speculative_load_miss = 1'b1;
  end

  // registers
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mem_q           <= '0;
      status_cnt_q    <= '0;
      write_pointer_q <= '0;
      read_pointer_q  <= '0;
    end else begin
      mem_q           <= mem_n;
      status_cnt_q    <= status_cnt_n;
      write_pointer_q <= write_pointer_n;
      read_pointer_q  <= read_pointer_n;
    end
  end
endmodule
