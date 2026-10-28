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
// Engineer:       Francesco Conti - f.conti@unibo.it
//
// Additional contributions by:
//                 Markus Wegmann - markus.wegmann@technokrat.ch
//
// Design Name:    RISC-V register file
// Project Name:   zero-riscy
// Language:       SystemVerilog
//
// Description:    Register file with 31 or 15x 32 bit wide registers.
//                 Register 0 is fixed to 0. This register file is based on
//                 flip flops.
//

module ariane_regfile #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg       = config_pkg::cva6_cfg_empty,
    parameter int unsigned           DATA_WIDTH    = 32,
    parameter int unsigned           NR_READ_PORTS = 2,
    parameter bit                    ZERO_REG_ZERO = 0
) (
    // clock and reset
    input  logic                                             clk_i,
    input  logic                                             rst_ni,
    // disable clock gates for testing
    input  logic                                             test_en_i,
    // read port
    input  logic [        NR_READ_PORTS-1:0][           4:0] raddr_i,
    output logic [        NR_READ_PORTS-1:0][DATA_WIDTH-1:0] rdata_o,
    // write port
    input  logic [CVA6Cfg.NrCommitPorts-1:0][           4:0] waddr_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0][DATA_WIDTH-1:0] wdata_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0]                 we_i
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin ariane_regfile status=proposal target=10-adjusted-FO4
  // svt-plan: cone write decode into mem and combinational indexed reads;
  // unlike g6lc_prf, this implementation has no explicit current-write bypass.
  // svt-plan: boundary optional accepted commit-write capture -> local
  // bank writes, with read overlay for writes whose original edge has passed.
  // svt-plan: carry every commit port's we/address/data and cycle order;
  // preserve highest-port collision priority and ZERO_REG_ZERO behavior.
  // svt-plan: visibility pending committed writes are architectural;
  // never expose current-cycle pre-edge writes early as a new bypass behavior.
  // svt-plan: effect separates late commit transport from row write decode;
  // bank-local read muxes can bound each data-selection subtree.
  // svt-plan: cost write packet storage and read overlays; registered reads
  // instead require a new issue_read_operands schedule, not a local substitution.
  // svt-plan: limit existing combinational read timing and integer/FP zero
  // differences are contractual; no benefit is guaranteed from write capture alone.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 54.3 adjusted FO4 on the
  // Nangate45 board): architectural register file: write-through read; a stage is a bypass change.
  // svt-pipe: require-contract
  // svt-pipe: protocol rf valid=we_i
  // svt-pipe: no-cut on=mem
  // svt-pipe: cycle rf q=mem d=rdata_o hold=we_i steps=1

  localparam ADDR_WIDTH = 5;
  localparam NUM_WORDS = 2 ** ADDR_WIDTH;

  logic [            NUM_WORDS-1:0][DATA_WIDTH-1:0] mem;
  logic [CVA6Cfg.NrCommitPorts-1:0][ NUM_WORDS-1:0] we_dec;


  always_comb begin : we_decoder
    for (int unsigned j = 0; j < CVA6Cfg.NrCommitPorts; j++) begin
      for (int unsigned i = 0; i < NUM_WORDS; i++) begin
        if (waddr_i[j] == i) we_dec[j][i] = we_i[j];
        else we_dec[j][i] = 1'b0;
      end
    end
  end

  // loop from 1 to NUM_WORDS-1 as R0 is nil
  always_ff @(posedge clk_i, negedge rst_ni) begin : register_write_behavioral
    if (~rst_ni) begin
      mem <= '{default: '0};
    end else begin
      for (int unsigned j = 0; j < CVA6Cfg.NrCommitPorts; j++) begin
        for (int unsigned i = 0; i < NUM_WORDS; i++) begin
          if (we_dec[j][i]) begin
            mem[i] <= wdata_i[j];
          end
        end
        if (ZERO_REG_ZERO) begin
          mem[0] <= '0;
        end
      end
    end
  end

  for (genvar i = 0; i < NR_READ_PORTS; i++) begin
    assign rdata_o[i] = mem[raddr_i[i]];
  end

endmodule
