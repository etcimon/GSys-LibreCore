// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright (c) 2025 Thales DIS design services SAS
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Author: Maxime Colson - Thales
// Date: 21/05/2025
module slicer_DPTI #(
    parameter SLICE_LEN = 32,
    parameter NO_TIME   = 0    // 0 : include time ; 1 : exclude time
) (
    input logic clk_i,
    input logic rst_ni,

    input logic                         valid_i,
    input encap_pkg::encap_fifo_entry_s encap_fifo_entry_i,
    input logic                         fifo_full_i,

    output logic                 valid_o,
    output logic [SLICE_LEN-1:0] slice_o,
    output logic                 done_o
);
  localparam DATA_LEN = encap_pkg::H_LEN + (NO_TIME ? 0 : encap_pkg::T_LEN) + encap_pkg::PAYLOAD_LEN;
  localparam NUM_SLICES = DATA_LEN / SLICE_LEN;
  localparam COUNT_LEN = $clog2(NUM_SLICES);

  logic [DATA_LEN-1 : 0] data_to_slice_q, data_to_slice_d;
  logic [COUNT_LEN-1:0] slice_index_d, slice_index_q;
  logic running_q, running_d;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=slicer_DPTI  region=8784  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: data_to_slice_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to data_to_slice_q
// order expect: running_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to running_q
// order expect: slice_index_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to slice_index_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     data_to_slice_q <= …; // sv-timing: cycle 1/1 on clk_i
//     running_q <= …; // sv-timing: cycle 1/1 on clk_i
//     slice_index_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node28702 c=3.50 slack=0.00 */
//     /* node28703 c=3.50 slack=0.00 */
//     /* node28704 c=3.50 slack=0.00 */
//     /* node28705 c=3.50 slack=0.00 */
//     /* node28706 c=3.50 slack=0.00 */
//     /* node28707 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign slice_o = data_to_slice_q[DATA_LEN-1:DATA_LEN-SLICE_LEN];
  assign valid_o = running_q && !fifo_full_i;
  assign done_o  = running_q && (slice_index_q == NUM_SLICES - 1) && !fifo_full_i;

  always_comb begin
    data_to_slice_d = data_to_slice_q;
    slice_index_d = slice_index_q;
    running_d = running_q;

    if (valid_i && !running_q) begin
      //new data to slice 
      data_to_slice_d = NO_TIME ? {encap_fifo_entry_i.header,encap_fifo_entry_i.payload} :
            {encap_fifo_entry_i.header,encap_fifo_entry_i.timestamp,encap_fifo_entry_i.payload};
      slice_index_d = 0;
      running_d = 1;
    end else if (running_q && !fifo_full_i) begin  // Stall if fifo is full
      //Slicing 
      data_to_slice_d = data_to_slice_q << SLICE_LEN;
      slice_index_d   = slice_index_q + 1;
      if (slice_index_q == NUM_SLICES - 1) begin
        running_d = 0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_to_slice_q <= '0;
      slice_index_q <= '0;
      running_q <= '0;
    end else begin
      data_to_slice_q <= data_to_slice_d;
      slice_index_q <= slice_index_d;
      running_q <= running_d;
    end
  end


endmodule
