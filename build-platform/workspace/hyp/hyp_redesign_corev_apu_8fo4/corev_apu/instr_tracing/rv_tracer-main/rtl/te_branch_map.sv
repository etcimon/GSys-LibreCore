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

/* BRANCH MAP */
/*
It keeps track of taken and non taken branches.

Whenever a branch happens it updates the branch map
and the number of branches stored.
    
When flush_i signal is asserted, the branch map is
cleaned.
*/

module te_branch_map #(
    parameter N = 1 // max number of committed branches in one cycle
)
(
    input logic                                 clk_i,
    input logic                                 rst_ni,

    input logic [N-1:0]                         valid_i,
    input logic [N-1:0]                         branch_taken_i,
    input logic                                 flush_i,
    
    output logic [te_pkg::BRANCH_MAP_LEN-1:0]   map_o,
    output logic [te_pkg::BRANCH_COUNT_LEN-1:0] branches_o,
    output logic                                is_full_o,
    output logic                                is_empty_o
);


    logic [te_pkg::BRANCH_MAP_LEN-1:0]      map_d, map_q;
    logic [te_pkg::BRANCH_COUNT_LEN-1:0]    branch_cnt_d, branch_cnt_q;

    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=te_branch_map  region=8642  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: branch_cnt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to branch_cnt_q
// order expect: map_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to map_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     branch_cnt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     map_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node28113 c=3.50 slack=0.00 */
//     /* node28114 c=3.50 slack=0.00 */
//     /* node28115 c=3.50 slack=0.00 */
//     /* node28116 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_comb begin
        map_d = map_q;
        branch_cnt_d = branch_cnt_q;

        if (flush_i) begin
            map_d = '0;
            branch_cnt_d = '0;
        end

        if (valid_i) begin 
            if(flush_i) begin
                map_d[0] = ~branch_taken_i;
                branch_cnt_d = 5'b1;
            end else begin
                map_d[branch_cnt_q] = ~branch_taken_i ;
                branch_cnt_d  = branch_cnt_q +1;
            end
        end 
    end

    assign map_o = map_d;
    assign branches_o = branch_cnt_d;
    assign is_full_o = (branch_cnt_d == 31);
    assign is_empty_o = (branch_cnt_d == 0);


    always_ff @(posedge clk_i, negedge rst_ni) begin
        if(~rst_ni) begin
            map_q <= '0;
            branch_cnt_q <= '0;

        end else begin
            map_q <= map_d;
            branch_cnt_q <= branch_cnt_d;
        end
    end     
    
endmodule
