// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// RISC-V Platform-Level Interrupt Generator for Target
//
// This module basically doing IE & IP based on priority and threshold.
// Keep in mind that increasing MAX_PRIO affects logic size a lot.

module rv_plic_target #(
  parameter int N_SOURCE = 32,
  parameter int MAX_PRIO = 7,
  parameter     ALGORITHM = "SEQUENTIAL", // SEQUENTIAL | MATRIX

  // Local param (Do not change this through parameter
  parameter int unsigned SRCW  = $clog2(N_SOURCE+1),
  parameter int unsigned PRIOW = $clog2(MAX_PRIO+1) // Bits to represent MAX_PRIO
) (
  input clk_i,
  input rst_ni,

  input [N_SOURCE-1:0] ip,
  input [N_SOURCE-1:0] ie,

  input [N_SOURCE-1:0][PRIOW-1:0] prio,
  input [PRIOW-1:0] threshold,

  output logic            irq,
  output logic [SRCW-1:0] irq_id
);


//always_ff @(posedge clk_i, negedge rst_ni) begin
//  if (!rst_ni) begin
//    gt_th <= '0;
//  end else begin
//    for (int i = 0 ; i < N_SOURCE ; i++) begin
//      gt_th[i] = (prio[i] > threshold) ? 1'b1 : 1'b0 ;
//    end
//  end
//end


if (ALGORITHM == "SEQUENTIAL") begin : gen_sequential
  // Let first implementation be brute-force
  // As N_SOURCE increasing logic depth increases O(logN)
  // This approach slows down the simulation.
  logic [PRIOW-1:0] max_prio;
  logic irq_next;
  logic [SRCW-1:0] irq_id_next;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=rv_plic_target  region=7605  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: irq  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to irq
// order expect: irq_id  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to irq_id
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     irq <= …; // sv-timing: cycle 1/1 on clk_i
//     irq_id <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node26538 c=3.50 slack=0.00 */
//     /* node26539 c=3.50 slack=0.00 */
//     /* node26540 c=3.50 slack=0.00 */
//     /* node26541 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=rv_plic_target  region=7609  makespan=9.500 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: irq  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to irq
// order expect: irq_id  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to irq_id
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node26548 c=3.50 slack=6.00 */
//     /* node26549 c=3.50 slack=6.00 */
//     /* node26552 c=8.00 slack=1.50 */
//     /* node26553 c=8.00 slack=1.50 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     irq <= …; // sv-timing: cycle 2/2 on clk_i
//     irq_id <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node26550 c=9.50 slack=0.00 */
//     /* node26551 c=9.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // hyp8: the single 30-iteration priority scan (~17 FO4 structural) is
  // split into four registered group winners (each ~N/4 sequential
  // compare-selects) merged by a short 4-way final select. One extra cycle
  // of EIP latency; pending-bit semantics unchanged.
  localparam int unsigned NGRP = 4;
  localparam int unsigned GRPW = (N_SOURCE + NGRP - 1) / NGRP;

  logic [NGRP-1:0][PRIOW-1:0] grp_max_q;
  logic [NGRP-1:0][SRCW-1:0]  grp_id_q;
  logic [NGRP-1:0]            grp_irq_q;

  logic [NGRP-1:0][PRIOW-1:0] grp_max;
  logic [NGRP-1:0][SRCW-1:0]  grp_id;
  logic [NGRP-1:0]            grp_irq;

  always_comb begin
    for (int unsigned g = 0; g < NGRP; g++) begin
      grp_max[g] = threshold + 1'b1;
      grp_id[g]  = '0;
      grp_irq[g] = 1'b0;
      for (int unsigned i = 0; i < GRPW; i++) begin
        // group g covers sources [ (NGRP-1-g)*GRPW .. ) scanned high->low
        automatic int s = (NGRP - 1 - g) * GRPW + (GRPW - 1 - i);
        if (s < N_SOURCE) begin
          if ((ip[s] & ie[s]) == 1'b1 && prio[s] >= grp_max[g]) begin
            grp_max[g] = prio[s];
            grp_id[g]  = SRCW'(s + 1);
            grp_irq[g] = 1'b1;
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      grp_max_q <= '0;
      grp_id_q  <= '0;
      grp_irq_q <= '0;
    end else begin
      grp_max_q <= grp_max;
      grp_id_q  <= grp_id;
      grp_irq_q <= grp_irq;
    end
  end

  // final select over the registered group winners. Groups cover disjoint
  // source ranges in descending order — pick the highest group with a
  // winner, i.e. lowest g whose grp_irq is set.
  always_comb begin
    irq_next    = '0;
    irq_id_next = '0;
    for (int g = NGRP - 1; g >= 0; g--) begin
      if (grp_irq_q[g]) begin
        irq_next    = 1'b1;
        irq_id_next = grp_id_q[g];
      end
    end
  end

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      irq <= 1'b0;
      irq_id <= '0;
    end else begin
      irq <= irq_next;
      irq_id <= irq_id_next;
    end
  end
end else if (ALGORITHM == "MATRIX") begin : gen_mat
  // Second trial : N X N matrix
  // Set mat[i][j] to 1 if prio[i] >= prio[j] and ip[i] & ie[i] & ip[j] & ie[j]
  // Comparator depth is just 1 then logN AND gate then Leading One detector
  // It is to find the max value of priority
  //
  // This uses a lot of comparators: (N x (N-1))/2.
  // So if above approach(ALGORITHM 1) meets timing, don't use this algorithm.
  logic [N_SOURCE-1:0] is;

  logic [N_SOURCE-1:0][N_SOURCE-1:0] mat;
  logic [N_SOURCE-1:0] merged_row;

  assign is = ip & ie;
  always_comb begin
    merged_row[N_SOURCE-1] = is[N_SOURCE-1] & (prio[N_SOURCE-1] > threshold);
    for (int i = 0 ; i < N_SOURCE-1 ; i++) begin
      merged_row[i] = 1'b1;
      for (int j = i+1 ; j < N_SOURCE ; j++) begin
        mat[i][j] = (prio[i] <= threshold) ? 1'b0 :         // No compare if less than TH
                    (is[i] & is[j]) ? prio[i] >= prio[j] :
                    (is[i]) ? 1'b 1 : 1'b 0 ;
        merged_row[i] = merged_row[i] & mat[i][j]; // all should be 1
      end // for j
    end // for i
  end // always_comb

  // Leading One detector
  logic [N_SOURCE-1:0] lod;
  assign lod = merged_row & (~merged_row + 1'b1);
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      irq <= 1'b0;
      irq_id <= '0; // No interrupt
    end else if (|lod) begin
      // as $onehot0(lod), at most one bit set.
      // so, safely run for loop
      for (int i = N_SOURCE-1 ; i >= 0 ; i--) begin
        if (lod[i] == 1'b1) begin
          irq <= 1'b 1;
          irq_id <= SRCW'(i + 1);
        end
      end // for
    end else begin
      // No pending interrupt
      irq <= 1'b0;
      irq_id <= '0;
    end
  end // always_ff
end // ALGORITHM

endmodule

