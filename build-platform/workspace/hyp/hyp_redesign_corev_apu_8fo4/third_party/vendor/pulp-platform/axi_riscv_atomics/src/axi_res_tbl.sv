// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright (c) 2018 ETH Zurich, University of Bologna
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// AXI Reservation Table
module axi_res_tbl #(
    parameter int unsigned AXI_ADDR_WIDTH = 0,
    parameter int unsigned AXI_ID_WIDTH = 0
) (
    input  logic                        clk_i,
    input  logic                        rst_ni,
    input  logic [AXI_ADDR_WIDTH-1:0]   clr_addr_i,
    input  logic                        clr_req_i,
    output logic                        clr_gnt_o,
    input  logic [AXI_ADDR_WIDTH-1:0]   set_addr_i,
    input  logic [AXI_ID_WIDTH-1:0]     set_id_i,
    input  logic                        set_req_i,
    output logic                        set_gnt_o,
    input  logic [AXI_ADDR_WIDTH-1:0]   check_addr_i,
    input  logic [AXI_ID_WIDTH-1:0]     check_id_i,
    output logic                        check_res_o,
    input  logic                        check_req_i,
    output logic                        check_gnt_o
);

    localparam integer N_IDS = 2**AXI_ID_WIDTH;

    // Declarations of Signals and Types
    logic [N_IDS-1:0][AXI_ADDR_WIDTH-1:0]   tbl_d,                      tbl_q;
    logic                                   clr,
                                            set;

    generate for (genvar i = 0; i < N_IDS; ++i) begin: gen_tbl
        

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=axi_res_tbl  region=5583  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: tbl_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tbl_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     tbl_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node19756 c=3.50 slack=0.00 */
//     /* node19757 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_comb begin
            tbl_d[i] = tbl_q[i];
            if (set && i == set_id_i) begin
                tbl_d[i] = set_addr_i;
            end else if (clr && tbl_q[i] == clr_addr_i) begin
                tbl_d[i] = '0;
            end
        end
    end endgenerate

    // Table-Managing Logic
    always_comb begin
        clr         = 1'b0;
        set         = 1'b0;
        clr_gnt_o   = 1'b0;
        set_gnt_o   = 1'b0;
        check_res_o = 1'b0;
        check_gnt_o = 1'b0;

        if (clr_req_i) begin
            clr         = 1'b1;
            clr_gnt_o   = 1'b1;
        end else if (set_req_i) begin
            set         = 1'b1;
            set_gnt_o   = 1'b1;
        end else if (check_req_i) begin
            check_res_o = (tbl_q[check_id_i] == check_addr_i);
            check_gnt_o = 1'b1;
        end
    end

    // Registers
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (~rst_ni) begin
            tbl_q   <= '0;
        end else begin
            tbl_q   <= tbl_d;
        end
    end

    // Validate parameters.
// pragma translate_off
`ifndef VERILATOR
    initial begin: validate_params
        assert (AXI_ADDR_WIDTH > 0)
            else $fatal(1, "AXI_ADDR_WIDTH must be greater than 0!");
        assert (AXI_ID_WIDTH > 0)
            else $fatal(1, "AXI_ID_WIDTH must be greater than 0!");
    end
`endif
// pragma translate_on

endmodule
