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

// Author: Florian Zaruba, ETH Zurich
// Date: 5.11.2018
// Description: 16-bit LFSR

// --------------
// 16-bit LFSR
// --------------
//
// Description: Shift register
//
module lfsr_16bit #(
    parameter logic [15:0] SEED  = 8'b0,
    parameter int unsigned WIDTH = 16
)(
    input  logic                      clk_i,
    input  logic                      rst_ni,
    input  logic                      en_i,
    output logic [WIDTH-1:0]          refill_way_oh,
    output logic [$clog2(WIDTH)-1:0]  refill_way_bin
);

    localparam int unsigned LogWidth = $clog2(WIDTH);

    logic [15:0] shift_d, shift_q;


    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=lfsr_16bit  region=8582  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: shift_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to shift_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     shift_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node27957 c=3.50 slack=0.00 */
//     /* node27958 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_comb begin

        automatic logic shift_in;
        shift_in = !(shift_q[15] ^ shift_q[12] ^ shift_q[5] ^ shift_q[1]);

        shift_d = shift_q;

        if (en_i)
            shift_d = {shift_q[14:0], shift_in};

        // output assignment
        refill_way_oh = 'b0;
        refill_way_oh[shift_q[LogWidth-1:0]] = 1'b1;
        refill_way_bin = shift_q;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_
        if(~rst_ni) begin
            shift_q <= SEED;
        end else begin
            shift_q <= shift_d;
        end
    end

    //pragma translate_off
    initial begin
        assert (WIDTH <= 16)
            else $fatal(1, "WIDTH needs to be less than 16 because of the 16-bit LFSR");
    end
    //pragma translate_on

endmodule
