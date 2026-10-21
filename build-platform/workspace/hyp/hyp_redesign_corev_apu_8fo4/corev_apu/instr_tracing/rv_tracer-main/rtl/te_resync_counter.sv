// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2025 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
// SPDX-License-Identifier: SHL-0.51

// Author:  Umberto Laghi
// Contact: umberto.laghi2@unibo.it
// Github:  @ubolakes

/* RESYNC COUNTER */
/*
It keeps track of the emitted packets or cycles elapsed,
operational mode and threshold are set by the user.

It produces a signal when the counter reaches the specified
threshold and it remains to 1 until it receives a reset signal.

In packed mode: the packets that exceeds the defined threshold
are discarded, because they belong to a pre-resync period.
Packets received while the counter is requesting a resync are
ignored.
*/

module te_resync_counter #(
    parameter N = 1,
    parameter MODE = te_pkg::CYCLE_MODE, // counts cycles as default
    parameter MAX_VALUE = 16'hFFFF // default max value, can be personalized
    )
    (
    input logic         clk_i,
    input logic         rst_ni,

    input logic         trace_enabled_i, // it comes from filter
    input logic [N-1:0] packet_emitted_i,
    input logic         resync_rst_i,

    output logic        gt_resync_max_o, // greater than the max value, in reality MAX_VALUE
    output logic        et_resync_max_o // equals to the max value, in reality MAX_VALUE-1
    );

    /*
        The packets that exceeds the defined threshold are discarded,
        because they belong to a pre-resync period.
        Packets received while the counter is requesting a resync are
        ignored.
    */
    
    // signals declaration
    logic [$clog2(MAX_VALUE):0] counter_d, counter_q;
    logic [$clog2(N):0]         n_packets;
    logic                       overflow;

    // assignments
    // both for packet and cycle mode
    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=te_resync_counter  region=8730  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: counter_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to counter_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     counter_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node28575 c=3.50 slack=0.00 */
//     /* node28576 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign et_resync_max_o = counter_d == $bits(counter_d)'(MAX_VALUE);
    assign gt_resync_max_o = counter_d > $bits(counter_d)'(MAX_VALUE) && ~resync_rst_i;
    
    always_comb begin
        // init
        counter_d = counter_q;
        n_packets = '0;

        // packet mode
        if (MODE == te_pkg::PACKET_MODE && trace_enabled_i) begin
            // counting the packets received
            for (int i = 0; i < N; i++) begin
                if (packet_emitted_i[i]) begin
                    n_packets += 1;
                end 
            end

            // summing the packets counted
            for (int i = 0; i < n_packets; i++) begin
                if (counter_d <= $bits(counter_d)'(MAX_VALUE)) begin
                    counter_d += 1;
                end
            end
        end

        // cycle mode
        if (MODE == te_pkg::CYCLE_MODE && trace_enabled_i && counter_d <= $bits(counter_d)'(MAX_VALUE)) begin
            counter_d += 1;
        end

        // synchronous reset
        if (resync_rst_i) begin
            counter_d = '0;
        end
    end


    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (~rst_ni) begin
            counter_q <= '0;
        end else begin
            counter_q <= counter_d;
        end
    end

endmodule
