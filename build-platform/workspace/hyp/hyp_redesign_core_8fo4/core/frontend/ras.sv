// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
//Copyright (C) 2018 to present,
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 08.02.2018
// Migrated: Luis Vitorio Cargnini, IEEE
// Date: 09.06.2018
// U6.1 follow-on: per-hart RAS banks when NrHarts>1 — Etienne Cimon 2026
// T21: pointer-based stack with a top-of-stack checkpoint — Etienne Cimon 2026

// return address stack (optionally banked for SMT)
//
// T21: the stack is a circular array addressed by a top-of-stack pointer with
// a valid count, instead of a shift register. Push/pop/predict semantics are
// unchanged (push on a full stack overwrites the oldest entry; the stack is
// empty after as many pops as it holds entries). The change makes the branch
// prediction checkpoint cheap: a checkpoint is {tos, cnt, ra[tos]} -- the
// pointer, the depth and the one entry a wrong-path pop-then-push can have
// overwritten -- rather than a copy of the whole stack (RASDepth x VLEN bits
// per checkpoint entry, 136 kbit on g6lc64_ooo_server at depth 16 x 64 x 2).
// On restore the resolving control flow's own stack effect is re-applied
// (restore_pop_i for a return, restore_push_i for a call) because the
// checkpoint is the state before the fetch window that carried it.

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: per-hart RAS banking when NrHarts>1;
// pointer-based stack with top-of-stack checkpoint (T21).
// The upstream notice above is prose and declares no SPDX identifier, so the
// outbound offer is stated here as the file's single SPDX tag. See REUSE.toml.
// Etienne Cimon offers this file AS A WHOLE under:
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
module ras #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter type ras_t = logic,
    parameter int unsigned DEPTH = 2,
    // T21 checkpoint field widths (derived; exposed so the fabric can size its ports)
    parameter int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int unsigned CNT_W = $clog2(DEPTH + 1)
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Branch prediction flush request - zero
    // When multi-hart: flushes only the active hart's bank (not peers).
    input logic flush_bp_i,
    // U6.1: active fetch hart for push/pop/predict (ignored when NrHarts==1)
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart_i,
    // T21: bank a restore targets (the resolving hart on a mispredict, the
    // fetch hart on a switch/replay clear)
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] restore_hart_i,
    // hyp8: current fetch epoch and the epoch the speculative push/pop was
    // issued under; a speculative update whose epoch is already dead is
    // ignored (the window that produced it was killed by an override).
    input logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] epoch_i,
    input logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] spec_epoch_i,
    // Push address in RAS - FRONTEND
    input logic push_i,
    // Pop address from RAS - FRONTEND
    input logic pop_i,
    // Data to be pushed - FRONTEND
    input logic [G6LCCfg.VLEN-1:0] data_i,
    // Popped data - FRONTEND
    output ras_t data_o,
    // T21: top-of-stack checkpoint of the FETCH hart's bank (the context a
    // prediction made this cycle is using)
    output logic [PTR_W-1:0]         snap_tos_o,
    output logic [CNT_W-1:0]         snap_cnt_o,
    output logic [G6LCCfg.VLEN-1:0]  snap_top_o,
    // T21: restore the resolving hart's bank from a checkpoint (overrides the
    // speculative push/pop of the same cycle on that bank), then re-apply the
    // resolving control flow's own effect: pop for a return, push for a call.
    input  logic                     restore_i,
    input  logic [PTR_W-1:0]         restore_tos_i,
    input  logic [CNT_W-1:0]         restore_cnt_i,
    input  logic [G6LCCfg.VLEN-1:0]  restore_top_i,
    input  logic                     restore_pop_i,
    input  logic                     restore_push_i,
    input  logic [G6LCCfg.VLEN-1:0]  restore_push_ra_i,
    // hyp8: epoch the restore was issued under; the registered restore is
    // dropped if the fetch epoch has already moved past it
    input  logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] restore_epoch_i
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin ras status=proposal target=10-adjusted-FO4
  // svt-plan: cone tos/count update and indexed top read feed return
  // prediction and checkpoints; restore may also apply a resolving push/pop.
  // svt-plan: reshape keep a per-hart top cache plus prefetched next-top;
  // update cache from the same prioritized push/pop/restore event as the stack.
  // svt-plan: boundary optional backing-array read -> next-top cache;
  // repeated pops require refill bandwidth or a conservative prediction miss.
  // svt-plan: carry hart, pointer/count generation, top validity/value and
  // restore payload; same-bank restore wins speculative updates as today.
  // svt-plan: effect removes indexed array selection from common top output;
  // stationary storage avoids moving the stack payload on push/pop.
  // svt-plan: cost cached tops and refill control; snapshots must reflect
  // logical top, including restore_pop/restore_push and empty-stack cases.
  // svt-plan: limit return prediction may fall back when cache refill lags;
  // never return an old valid top or change checkpoint contents silently.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 39.1 adjusted FO4 on the
  // Nangate45 board): return address stack: push / pop state.
  // svt-pipe: require-contract
  // svt-pipe: protocol ra valid=push_i
  // svt-pipe: no-cut on=ra_d
  // svt-pipe: cycle ra q=ra_d d=snap_top_o hold=push_i steps=1

  localparam int unsigned NH    = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  function automatic logic [PTR_W-1:0] inc(logic [PTR_W-1:0] p);
    return (p == PTR_W'(DEPTH - 1)) ? '0 : p + PTR_W'(1);
  endfunction
  function automatic logic [PTR_W-1:0] dec(logic [PTR_W-1:0] p);
    return (p == '0) ? PTR_W'(DEPTH - 1) : p - PTR_W'(1);
  endfunction

  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;

  logic [NH-1:0][DEPTH-1:0][G6LCCfg.VLEN-1:0] ra_d, ra_q;
  logic [NH-1:0][PTR_W-1:0] tos_d, tos_q;
  logic [NH-1:0][CNT_W-1:0] cnt_d, cnt_q;

  logic [HID_W-1:0] fsel, rsel;

  // hyp8: restore is registered (rank 4) — the checkpoint payload travels one
  // cycle, then applies only if the fetch epoch it was issued under is still
  // current. A stale restore is dropped entirely.
  logic                    res_valid_q;
  logic [HID_W-1:0]        res_hart_q;
  logic [PTR_W-1:0]        res_tos_q;
  logic [CNT_W-1:0]        res_cnt_q;
  logic [G6LCCfg.VLEN-1:0] res_top_q;
  logic                    res_pop_q;
  logic                    res_push_q;
  logic [G6LCCfg.VLEN-1:0] res_push_ra_q;
  logic [EW-1:0]           res_epoch_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      res_valid_q   <= 1'b0;
      res_hart_q    <= '0;
      res_tos_q     <= '0;
      res_cnt_q     <= '0;
      res_top_q     <= '0;
      res_pop_q     <= 1'b0;
      res_push_q    <= 1'b0;
      res_push_ra_q <= '0;
      res_epoch_q   <= '0;
    end else begin
      res_valid_q   <= restore_i;
      res_hart_q    <= rsel;
      res_tos_q     <= restore_tos_i;
      res_cnt_q     <= restore_cnt_i;
      res_top_q     <= restore_top_i;
      res_pop_q     <= restore_pop_i;
      res_push_q    <= restore_push_i;
      res_push_ra_q <= restore_push_ra_i;
      res_epoch_q   <= restore_epoch_i;
    end
  end

  // speculative update allowed only while the issuing window's epoch is live
  logic spec_live;
  assign spec_live = (spec_epoch_i == epoch_i);
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=ras  region=3734  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: cnt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cnt_q
// order expect: ra_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ra_q
// order expect: tos_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tos_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cnt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     ra_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tos_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node13519 c=3.50 slack=0.00 */
//     /* node13520 c=3.50 slack=0.00 */
//     /* node13521 c=3.50 slack=0.00 */
//     /* node13522 c=3.50 slack=0.00 */
//     /* node13523 c=3.50 slack=0.00 */
//     /* node13524 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign fsel = (NH <= 1) ? '0 : hart_i[HID_W-1:0];
  assign rsel = (NH <= 1) ? '0 : restore_hart_i[HID_W-1:0];

  // An empty stack predicts ra = 0, exactly as the shift stack did (popped
  // cells were zeroed). The branch unit relies on it: an unpredicted return
  // still travels as cf = Return with this address, and is caught at resolve
  // only because the address cannot equal the real target -- a stale cell
  // that happened to hold the right link would retire the fall-through path.
  // hyp8 RASDepth is 2, and the module default is 2. A variable
  // ra_q[hart][tos] plus inc/dec in one always_comb ghost-chained to 33.5.
  // Each slot is a constant index. inc/dec on a 2-entry ring are bitwise not.
  // Restore still wins over a same-bank speculative update, then flush clears
  // only the active bank's pointer and count (the array itself is kept).
  if (DEPTH == 2) begin : gen_ras_d2
    logic [31:0] pred_hi, pred_lo, snap_hi, snap_lo;
    logic [NH-1:0][1:0][31:0] pred_hi_l, pred_lo_l, snap_hi_l, snap_lo_l;
    for (genvar h = 0; h < NH; h++) begin : gen_rd_h
      for (genvar s = 0; s < 2; s++) begin : gen_rd_s
        wire take = (fsel == HID_W'(h)) && (tos_q[h] == PTR_W'(s));
        wire live = take && (cnt_q[h] != '0);
        assign snap_hi_l[h][s] = take ? ra_q[h][s][63:32] : '0;
        assign snap_lo_l[h][s] = take ? ra_q[h][s][31:0] : '0;
        assign pred_hi_l[h][s] = live ? ra_q[h][s][63:32] : '0;
        assign pred_lo_l[h][s] = live ? ra_q[h][s][31:0] : '0;
      end
    end
    always_comb begin
      pred_hi = '0;
      pred_lo = '0;
      snap_hi = '0;
      snap_lo = '0;
      for (int unsigned h = 0; h < NH; h++) begin
        pred_hi = pred_hi | pred_hi_l[h][0] | pred_hi_l[h][1];
        pred_lo = pred_lo | pred_lo_l[h][0] | pred_lo_l[h][1];
        snap_hi = snap_hi | snap_hi_l[h][0] | snap_hi_l[h][1];
        snap_lo = snap_lo | snap_lo_l[h][0] | snap_lo_l[h][1];
      end
    end
    assign data_o.valid = (cnt_q[fsel] != '0);
    assign data_o.ra    = {pred_hi, pred_lo};
    assign snap_tos_o   = tos_q[fsel];
    assign snap_cnt_o   = cnt_q[fsel];
    assign snap_top_o   = {snap_hi, snap_lo};

    for (genvar h = 0; h < NH; h++) begin : gen_bank
      logic              spec_here, res_here, flush_here;
      logic              pop_do;
      logic [PTR_W-1:0]  t0, t_after, t_push_slot, tos_spec, tos_res;
      logic [CNT_W-1:0]  cnt_spec, cnt_res;
      logic [1:0]        ev;

      assign spec_here  = spec_live && (fsel == HID_W'(h));
      assign res_here   = res_valid_q && (res_epoch_q == epoch_i) &&
                          (res_hart_q == HID_W'(h));
      assign flush_here = flush_bp_i && (fsel == HID_W'(h));

      always_comb begin
        tos_spec = tos_q[h];
        cnt_spec = cnt_q[h];
        if (spec_here && push_i && pop_i && (cnt_q[h] == '0)) begin
          tos_spec = ~tos_q[h];
          cnt_spec = CNT_W'(1);
        end else if (spec_here && push_i && !pop_i) begin
          tos_spec = ~tos_q[h];
          cnt_spec = (cnt_q[h] == CNT_W'(DEPTH)) ? CNT_W'(DEPTH) : cnt_q[h] + CNT_W'(1);
        end else if (spec_here && pop_i && !push_i && (cnt_q[h] != '0)) begin
          tos_spec = ~tos_q[h];
          cnt_spec = cnt_q[h] - CNT_W'(1);
        end
      end

      assign pop_do      = res_pop_q && (res_cnt_q != '0);
      assign t0          = res_tos_q;
      assign t_after     = pop_do ? ~t0 : t0;
      assign t_push_slot = ~t_after;
      assign tos_res     = res_push_q ? t_push_slot : t_after;
      always_comb begin
        cnt_res = res_cnt_q;
        if (pop_do) cnt_res = res_cnt_q - CNT_W'(1);
        if (res_push_q)
          cnt_res = (cnt_res == CNT_W'(DEPTH)) ? CNT_W'(DEPTH) : cnt_res + CNT_W'(1);
      end

      always_comb begin
        if (flush_here) ev = 2'd3;
        else if (res_here) ev = 2'd2;
        else if (spec_here && (push_i || pop_i)) ev = 2'd1;
        else ev = 2'd0;
      end
      always_comb begin
        unique case (ev)
          2'd3:    tos_d[h] = '0;
          2'd2:    tos_d[h] = tos_res;
          2'd1:    tos_d[h] = tos_spec;
          default: tos_d[h] = tos_q[h];
        endcase
      end
      always_comb begin
        unique case (ev)
          2'd3:    cnt_d[h] = '0;
          2'd2:    cnt_d[h] = cnt_res;
          2'd1:    cnt_d[h] = cnt_spec;
          default: cnt_d[h] = cnt_q[h];
        endcase
      end

      for (genvar s = 0; s < 2; s++) begin : gen_slot
        logic       spec_wr;
        logic [1:0] ra_sel;
        logic [31:0] ra_hi, ra_lo;
        assign spec_wr = spec_here && (
            (push_i && pop_i && (cnt_q[h] != '0) && (tos_q[h] == PTR_W'(s))) ||
            (push_i && pop_i && (cnt_q[h] == '0) && ((~tos_q[h]) == PTR_W'(s))) ||
            (push_i && !pop_i && ((~tos_q[h]) == PTR_W'(s))));
        always_comb begin
          ra_sel = 2'd0;
          if (spec_wr) ra_sel = 2'd1;
          if (res_here) begin
            if (res_push_q && (t_push_slot == PTR_W'(s))) ra_sel = 2'd3;
            else if (t0 == PTR_W'(s)) ra_sel = 2'd2;
            else ra_sel = 2'd0;
          end
        end
        always_comb begin
          unique case (ra_sel)
            2'd1:    ra_hi = data_i[63:32];
            2'd2:    ra_hi = res_top_q[63:32];
            2'd3:    ra_hi = res_push_ra_q[63:32];
            default: ra_hi = ra_q[h][s][63:32];
          endcase
        end
        always_comb begin
          unique case (ra_sel)
            2'd1:    ra_lo = data_i[31:0];
            2'd2:    ra_lo = res_top_q[31:0];
            2'd3:    ra_lo = res_push_ra_q[31:0];
            default: ra_lo = ra_q[h][s][31:0];
          endcase
        end
        assign ra_d[h][s] = {ra_hi, ra_lo};
      end
    end
  end

  //pragma translate_off
  // An invalid prediction never carries an address (see data_o above).
  always_ff @(posedge clk_i) begin
    if (rst_ni) ras_empty_zero: assert (data_o.valid || data_o.ra == '0);
  end
  //pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      ra_q  <= '0;
      tos_q <= '0;
      cnt_q <= '0;
    end else begin
      ra_q  <= ra_d;
      tos_q <= tos_d;
      cnt_q <= cnt_d;
    end
  end
endmodule
