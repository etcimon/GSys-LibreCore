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
    // Empty: the accelerator MMU waits for this. Not the issue credit.
    output logic      ready_o,
    // Posts captured in the queue (0..DEPTH). Issue adds the two grants
    // still in the AGU shadow and stops at DEPTH.
    output logic [2:0] count_o
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

  // Depth 4 covers the two-cycle AGU shadow plus a head waiting on
  // the load or store unit. A depth-2 queue forced a grant, then a skip,
  // because three back-to-back posts overflowed it.
  localparam int unsigned DEPTH = 4;
  lsu_ctrl_t [DEPTH-1:0] mem_n, mem_q;
  logic [1:0] read_pointer_n, read_pointer_q;
  logic [1:0] write_pointer_n, write_pointer_q;
  logic [2:0] status_cnt_n, status_cnt_q;

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
  assign count_o = status_cnt_q;

  lsu_ctrl_t req_wr;
  always_comb begin
    req_wr = lsu_req_i;
    if (lsu_req_valid_i && lsu_req_i.is_speculative_load &&
        resolved_branch_i.valid &&
        (!G6LCCfg.OoOEn || !resolved_branch_i.is_mispredict)) begin
      if (resolved_branch_i.is_mispredict)
        req_wr.is_speculative_load_miss = 1'b1;
      else
        req_wr.is_speculative_load = 1'b0;
    end
  end

  // Pointers and the count. Payload slots are sibling generates so a
  // variable index of the wide record is not on this cone.
  always_comb begin
    automatic logic [2:0] status_cnt;
    automatic logic [1:0] write_pointer;
    automatic logic [1:0] read_pointer;

    status_cnt    = status_cnt_q;
    write_pointer = write_pointer_q;
    read_pointer  = read_pointer_q;

    if (lsu_req_valid_i) begin
      write_pointer++;
      status_cnt++;
    end
    if (pop_ld_i) begin
      read_pointer++;
      status_cnt--;
    end
    if (pop_st_i) begin
      read_pointer++;
      status_cnt--;
    end
    if (flush_i) begin
      status_cnt    = '0;
      write_pointer = '0;
      read_pointer  = '0;
    end
    read_pointer_n  = read_pointer;
    write_pointer_n = write_pointer;
    status_cnt_n    = status_cnt;
  end

  for (genvar s = 0; s < DEPTH; s++) begin : gen_slot
    // r42-T item 23 (A22): the serial field-override chain becomes
    // parallel arms. The cancel index is predecoded per source record so
    // the wr/q merge select happens BEFORE the trans_id -> cancelled
    // mask dynamic read instead of after it.
    always_comb begin
      logic do_flush, wr_s, pop_s, mx_cncl;
      do_flush = flush_i || (pop_ld_i && pop_st_i);
      wr_s     = !do_flush && lsu_req_valid_i && (write_pointer_q == 2'(s));
      pop_s    = !do_flush && (pop_ld_i || pop_st_i) &&
                 (read_pointer_q == 2'(s));
`ifdef G6LC_MUT_T2_LBYP_MEMN
      mem_n[s] = mem_q[s];
      if (do_flush) begin
        mem_n[s] = '0;
      end else if (wr_s) begin
        mem_n[s] = req_wr;
      end
      if (pop_s)
        mem_n[s].valid = 1'b0;
      if (G6LCCfg.OoOEn && mem_n[s].valid &&
          (mem_n[s].fu == LOAD || mem_n[s].fu == STORE) &&
          cancelled_mask_i[mem_n[s].trans_id])
        mem_n[s].is_speculative_load_miss = 1'b1;
`else
      mx_cncl = G6LCCfg.OoOEn &&
          (wr_s ? (req_wr.fu == LOAD || req_wr.fu == STORE) &&
                  cancelled_mask_i[req_wr.trans_id]
                : (mem_q[s].fu == LOAD || mem_q[s].fu == STORE) &&
                  cancelled_mask_i[mem_q[s].trans_id]);
      mem_n[s] = do_flush ? '0 : (wr_s ? req_wr : mem_q[s]);
      if (pop_s)
        mem_n[s].valid = 1'b0;
      // T35: sticky cancel. The mask names a tid only until the entry
      // is commit-dropped; a store held for translation outlives that.
      if (mem_n[s].valid && mx_cncl)
        mem_n[s].is_speculative_load_miss = 1'b1;
`endif
    end
  end

  // hyp8: registered head — the emit bypassed a live request through the
  // `empty ? lsu_req_i : mem_q[rd]` output mux (the 32.3-FO4 cone). The
  // head packet is now captured from the NEXT-state queue (post-pop), so
  // every request appears at lsu_ctrl_o one cycle after it posts (+1 on
  // request presentation; recorded). mem_n[read_pointer_n] already
  // equals the arriving request when the queue drains to empty, so no
  // separate bypass path is needed.
  lsu_ctrl_t head_q, head_d;
  // Constant slot arms. A variable index of this record is a per-bit select.
  always_comb begin
    unique case (read_pointer_n)
      2'd0: head_d = mem_n[0];
      2'd1: head_d = mem_n[1];
      2'd2: head_d = mem_n[2];
      default: head_d = mem_n[3];
    endcase
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_head
    if (~rst_ni) head_q <= '0;
    else         head_q <= head_d;
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

//pragma translate_off
  // +smt_flow_trace window probe (+trace_from/+trace_to, default 0..3000):
  // [lsqb]  per-cycle queue state — mem entries, pointers, count, the
  //         posted request, both pops, flush and the presented head.
  // [lsqb-evt] labelled queue events: insert, pop_ld, pop_st, flush,
  //         cancel-mask mark, and head-slot overwrite (insert while full).
  bit lsqb_tr;
  int unsigned lsqb_cyc = 0;
  int unsigned lsqb_lo, lsqb_hi;
  initial begin
    lsqb_tr = $test$plusargs("smt_flow_trace");
    lsqb_lo = 0;
    lsqb_hi = 3000;
    void'($value$plusargs("trace_from=%d", lsqb_lo));
    void'($value$plusargs("trace_to=%d", lsqb_hi));
  end

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      lsqb_cyc = 0;
    end else if (lsqb_tr) begin
      lsqb_cyc++;
      if ((lsqb_cyc >= lsqb_lo) && (lsqb_cyc <= lsqb_hi)) begin
        $display("[lsqb] c=%0d cnt=%0d rd=%b wp=%b m0[v=%b fu=%0d tid=%0d slm=%b] m1[v=%b fu=%0d tid=%0d slm=%b] m2[v=%b tid=%0d] m3[v=%b tid=%0d] ins_v=%b ins_tid=%0d ins_fu=%0d pld=%b pst=%b fls=%b out[v=%b fu=%0d tid=%0d slm=%b]",
                 lsqb_cyc, status_cnt_q, read_pointer_q, write_pointer_q,
                 mem_q[0].valid, mem_q[0].fu, mem_q[0].trans_id,
                 mem_q[0].is_speculative_load_miss,
                 mem_q[1].valid, mem_q[1].fu, mem_q[1].trans_id,
                 mem_q[1].is_speculative_load_miss,
                 mem_q[2].valid, mem_q[2].trans_id,
                 mem_q[3].valid, mem_q[3].trans_id,
                 lsu_req_valid_i, lsu_req_i.trans_id, lsu_req_i.fu,
                 pop_ld_i, pop_st_i, flush_i,
                 lsu_ctrl_o.valid, lsu_ctrl_o.fu, lsu_ctrl_o.trans_id,
                 lsu_ctrl_o.is_speculative_load_miss);
        if (lsu_req_valid_i)
          $display("[lsqb-evt] c=%0d insert tid=%0d fu=%0d wp=%b cnt=%0d %s",
                   lsqb_cyc, lsu_req_i.trans_id, lsu_req_i.fu,
                   write_pointer_q, status_cnt_q,
                   (status_cnt_q >= 4) ? "OVERWRITE-FULL" :
                   (write_pointer_q == read_pointer_q &&
                    status_cnt_q != 0) ? "WP-EQ-RD" : "ok");
        if (pop_ld_i)
          $display("[lsqb-evt] c=%0d pop_ld head_tid=%0d head_fu=%0d",
                   lsqb_cyc, mem_q[read_pointer_q].trans_id,
                   mem_q[read_pointer_q].fu);
        if (pop_st_i)
          $display("[lsqb-evt] c=%0d pop_st head_tid=%0d head_fu=%0d",
                   lsqb_cyc, mem_q[read_pointer_q].trans_id,
                   mem_q[read_pointer_q].fu);
        if (flush_i)
          $display("[lsqb-evt] c=%0d flush", lsqb_cyc);
        if (G6LCCfg.OoOEn) begin
          for (int unsigned i = 0; i < 4; i++) begin
            if (mem_q[i].valid && !mem_q[i].is_speculative_load_miss &&
                (mem_q[i].fu == LOAD || mem_q[i].fu == STORE) &&
                cancelled_mask_i[mem_q[i].trans_id])
              $display("[lsqb-evt] c=%0d cancel-mark idx=%0d tid=%0d fu=%0d",
                       lsqb_cyc, i, mem_q[i].trans_id, mem_q[i].fu);
          end
        end
      end
    end
  end

  // r42-T item 23 equivalence: the parallel-arm mem_n must equal the
  // serial override chain every cycle.
  int unsigned t2_lbyp_n = 0;
  lsu_ctrl_t ref_n;
  bit ref_flush, ref_wr, ref_pop;
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      t2_lbyp_n <= t2_lbyp_n + 1;
      ref_flush = flush_i || (pop_ld_i && pop_st_i);
      for (int unsigned s = 0; s < DEPTH; s++) begin
        ref_n   = mem_q[s];
        ref_wr  = !ref_flush && lsu_req_valid_i && (write_pointer_q == 2'(s));
        ref_pop = !ref_flush && (pop_ld_i || pop_st_i) &&
                  (read_pointer_q == 2'(s));
        if (ref_flush) ref_n = '0;
        else if (ref_wr) ref_n = req_wr;
        if (ref_pop) ref_n.valid = 1'b0;
        if (G6LCCfg.OoOEn && ref_n.valid &&
            (ref_n.fu == LOAD || ref_n.fu == STORE) &&
            cancelled_mask_i[ref_n.trans_id])
          ref_n.is_speculative_load_miss = 1'b1;
        g6lc_t2_lbyp_eq: assert (mem_n[s] === ref_n)
          else $error("lsu_bypass: equiv mem_n slot=%0d", s);
      end
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] lsu_bypass memn: checked=%0d", t2_lbyp_n);
  end
//pragma translate_on
endmodule
