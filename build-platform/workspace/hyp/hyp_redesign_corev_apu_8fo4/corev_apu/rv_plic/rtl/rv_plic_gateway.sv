// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// RISC-V Platform-Level Interrupt Gateways module

module rv_plic_gateway #(
  parameter int N_SOURCE = 32
) (
  input clk_i,
  input rst_ni,

  input [N_SOURCE-1:0] src,
  input [N_SOURCE-1:0] le,      // Level0 Edge1

  input [N_SOURCE-1:0] claim, // $onehot0(claim)
  input [N_SOURCE-1:0] complete, // $onehot0(complete)

  output logic [N_SOURCE-1:0] ip
);

logic [N_SOURCE-1:0] ia;    // Interrupt Active

logic [N_SOURCE-1:0] set;   // Set: (le) ? src & ~src_d : src ;
logic [N_SOURCE-1:0] src_d;


  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=rv_plic_gateway  region=7610  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: src_d  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to src_d
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     src_d <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node26554 c=3.50 slack=0.00 */
//     /* node26555 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=rv_plic_gateway  region=7612  makespan=7.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ip  ready_cycle=1  ready_fo4=7.500  OpenSTA: report_timing -from clk_i -to ip
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ip <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node26557 c=3.50 slack=4.00 */
//     /* node26558 c=7.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=rv_plic_gateway  region=7613  makespan=6.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ia  ready_cycle=1  ready_fo4=6.500  OpenSTA: report_timing -from clk_i -to ia
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ia <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node26559 c=3.50 slack=3.00 */
//     /* node26560 c=6.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_ff @(posedge clk_i, negedge rst_ni) begin
  if (!rst_ni) src_d <= '0;
  else         src_d <= src;
end

always_comb begin
  for (int i = 0 ; i < N_SOURCE; i++) begin
    set[i] = (le[i]) ? src[i] & ~src_d[i] : src[i] ;
  end
end

// Interrupt pending is set by source (depends on le), cleared by claim.
// Until interrupt is claimed, set doesn't affect ip.
// RISC-V PLIC spec mentioned it can have counter for edge triggered
// But skipped the feature as counter consumes substantial logic size.
always_ff @(posedge clk_i, negedge rst_ni) begin
  if (!rst_ni) begin
    ip <= '0;
  end else begin
    ip <= (ip | (set & ~ia & ~ip)) & (~claim);
  end
end

// Interrupt active is to control ip. If ip is set then until completed
// by target, ip shouldn't be set by source even claim can clear ip.
always_ff @(posedge clk_i, negedge rst_ni) begin
  if (!rst_ni) begin
    ia <= '0;
  end else begin
    ia <= (ia | (set & ~ia)) & (~complete);
  end
end

endmodule
