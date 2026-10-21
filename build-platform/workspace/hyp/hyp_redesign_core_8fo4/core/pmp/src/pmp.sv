// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
// Copyright 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Moritz Schneider, ETH Zurich
// Date: 2.10.2019
// Description: PMP unit (with extraction for more complex configs such as
//              NAPOT) — hyp8: T3 datapath of the TLB lookup. The request
//              fields (address, access type, privilege) are registered at
//              this boundary so every per-entry TOR/NAPOT compare and the
//              privilege/allow reduction evaluate on captured operands:
//              allow_o is presented the cycle after the inputs (H15: no
//              side effect before the verdict). pmp_entry keeps the
//              quasi-static conf formation separate from the dynamic
//              compare.

module pmp
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
    input logic clk_i,
    input logic rst_ni,
    // Input
    input logic [G6LCCfg.PLEN-1:0] addr_i,
    input riscv::pmp_access_t access_type_i,
    input riscv::priv_lvl_t priv_lvl_i,
    // Configuration
    input logic [avoid_neg(G6LCCfg.NrPMPEntries-1):0][G6LCCfg.PLEN-3:0] conf_addr_i,
    input riscv::pmpcfg_t [avoid_neg(G6LCCfg.NrPMPEntries-1):0] conf_i,
    // Output
    output logic allow_o
);
  // hyp8: registered request boundary — every compare input is captured
  // here so the range selects below terminate at flops, and the verdict is
  // the following cycle's value.
  logic [G6LCCfg.PLEN-1:0] addr_q;
  riscv::pmp_access_t      access_type_q;
  riscv::priv_lvl_t        priv_lvl_q;

  if (G6LCCfg.NrPMPEntries > 0) begin : gen_pmp
    logic [(G6LCCfg.NrPMPEntries > 0 ? G6LCCfg.NrPMPEntries-1 : 0):0] match;

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_pmp_req
      if (!rst_ni) begin
        addr_q        <= '0;
        access_type_q <= riscv::ACCESS_READ;
        priv_lvl_q    <= riscv::PRIV_LVL_M;
      end else begin
        addr_q        <= addr_i;
        access_type_q <= access_type_i;
        priv_lvl_q    <= priv_lvl_i;
      end
    end

    for (genvar i = 0; i < G6LCCfg.NrPMPEntries; i++) begin
      logic [G6LCCfg.PLEN-3:0] conf_addr_prev;

      assign conf_addr_prev = (i == 0) ? '0 : conf_addr_i[i-1];

      pmp_entry #(
          .G6LCCfg(G6LCCfg)
      ) i_pmp_entry (
          .addr_i          (addr_q),
          .conf_addr_i     (conf_addr_i[i]),
          .conf_addr_prev_i(conf_addr_prev),
          .conf_addr_mode_i(conf_i[i].addr_mode),
          .match_o         (match[i])
      );
    end

    always_comb begin
      int i;

      allow_o = 1'b0;
      for (i = 0; i < G6LCCfg.NrPMPEntries; i++) begin
        // either we are in S or U mode or the config is locked in which
        // case it also applies in M mode
        if (priv_lvl_q != riscv::PRIV_LVL_M || conf_i[i].locked) begin
          if (match[i]) begin
            if ((access_type_q & conf_i[i].access_type) != access_type_q) allow_o = 1'b0;
            else allow_o = 1'b1;
            break;
          end
        end
      end
      if (i == G6LCCfg.NrPMPEntries) begin  // no PMP entry matched the address
        // allow all accesses from M-mode for no pmp match
        if (priv_lvl_q == riscv::PRIV_LVL_M) allow_o = 1'b1;
        // disallow accesses for all other modes
        else
          allow_o = 1'b0;
      end
    end
  end else begin : gen_no_pmp
    // no PMPs — the registered boundary is degenerate, grant immediately
    assign allow_o = 1'b1;
  end

endmodule
