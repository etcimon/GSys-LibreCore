// hyp8 provenance: ADAPTED (sv-timing emit base, registered read)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
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
// Description:    Architectural register file (flip-flop form), used only on
//                 the non-OoO (OoOEn==0) paths; the OoO backend reads g6lc_prf.
//                 Register 0 is fixed to 0.
//
// hyp8 (group 7): the read port is registered -- raddr is captured at the
// edge and rdata_o is mem[raddr_q], so the write-decode/array-select cone
// no longer sits on the issue-cycle operand path. Read latency +1 for every
// consumer of this file (they are all on the compiled-out-when-OoOEn
// architectural path; the OoO PRF carries its own 2-step read).

module g6lc_regfile #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg       = config_pkg::g6lc_cfg_empty,
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
    input  logic [G6LCCfg.NrCommitPorts-1:0][           4:0] waddr_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0][DATA_WIDTH-1:0] wdata_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0]                 we_i
);

  localparam ADDR_WIDTH = 5;
  localparam NUM_WORDS = 2 ** ADDR_WIDTH;

  logic [            NUM_WORDS-1:0][DATA_WIDTH-1:0] mem;
  logic [G6LCCfg.NrCommitPorts-1:0][ NUM_WORDS-1:0] we_dec;

  // hyp8: registered read address -- the array index is a flop, not the
  // live request. A write landing on this edge is read next cycle, exactly
  // as a same-edge write was read next cycle before.
  logic [NR_READ_PORTS-1:0][4:0] raddr_q;

  always_comb begin : we_decoder
    for (int unsigned j = 0; j < G6LCCfg.NrCommitPorts; j++) begin
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
      for (int unsigned j = 0; j < G6LCCfg.NrCommitPorts; j++) begin
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

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) raddr_q <= '0;
    else         raddr_q <= raddr_i;
  end

  for (genvar i = 0; i < NR_READ_PORTS; i++) begin
    assign rdata_o[i] = mem[raddr_q[i]];
  end

  // test_en_i is carried for interface parity with the rest of the file
  // set; there is no clock gate inside this module.
  logic _unused;
  assign _unused = test_en_i;

endmodule
