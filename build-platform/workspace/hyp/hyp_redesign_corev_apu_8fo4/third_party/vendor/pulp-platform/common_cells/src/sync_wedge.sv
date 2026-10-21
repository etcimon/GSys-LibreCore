// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Antonio Pullini <pullinia@iis.ee.ethz.ch>

module sync_wedge #(
    parameter int unsigned STAGES = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic en_i,
    input  logic serial_i,
    output logic r_edge_o,
    output logic f_edge_o,
    output logic serial_o
);
    logic clk;
    logic serial, serial_q;

    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk  period_ns=0.200000  B=8.000 FO4
// module=sync_wedge  region=8622  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk -period 0.200000 [get_ports clk]
// order expect: serial_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk -to serial_q
// --- factor stage 1/1  capture on posedge clk ---
// always_ff @(posedge clk or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     serial_q <= …; // sv-timing: cycle 1/1 on clk
//     /* node28085 c=3.50 slack=1.00 */
//     /* node28086 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign serial_o =  serial_q;
    assign f_edge_o = (~serial) & serial_q;
    assign r_edge_o =  serial & (~serial_q);

    sync #(
        .STAGES (STAGES)
    ) i_sync (
        .clk_i,
        .rst_ni,
        .serial_i,
        .serial_o ( serial )
    );

    pulp_clock_gating i_pulp_clock_gating (
        .clk_i,
        .en_i,
        .test_en_i ( 1'b0 ),
        .clk_o     ( clk  )
    );

    always_ff @(posedge clk, negedge rst_ni) begin
        if (!rst_ni) begin
            serial_q <= 1'b0;
        end else begin
            if (en_i) begin
                serial_q <= serial;
            end
        end
    end
endmodule
