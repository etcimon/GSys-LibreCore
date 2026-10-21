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
// Modified by: Etienne Cimon
// Date: 2.10.2019
// Description: single PMP entry

module pmp_entry #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned PLEN = 56,
    parameter int unsigned PMP_LEN = 54
) (
    // Input
    input logic [G6LCCfg.PLEN-1:0] addr_i,

    // Configuration
    input logic [G6LCCfg.PLEN-3:0] conf_addr_i,
    input logic [G6LCCfg.PLEN-3:0] conf_addr_prev_i,
    input riscv::pmp_addr_mode_t conf_addr_mode_i,

    // Output
    output logic match_o
);
  logic [G6LCCfg.PLEN-1:0] conf_addr_n;
  logic [$clog2(G6LCCfg.PLEN)-1:0] trail_ones;
  logic [G6LCCfg.PLEN-1:0] base;
  logic [G6LCCfg.PLEN-1:0] mask;
  int unsigned size;
  assign conf_addr_n = {2'b11, ~conf_addr_i};
  g6lc_hyp_lzc #(
      .WIDTH(G6LCCfg.PLEN),
      .MODE (1'b0)
  ) i_lzc (
      .in_i   (conf_addr_n),
      .cnt_o  (trail_ones),
      .empty_o()
  );

  // hyp8: conf-side formation separated from the dynamic compare. The
  // NAPOT trailing-ones -> size -> mask -> base chain and the TOR bounds
  // are quasi-static per entry (they move only on a pmpaddr/pmpcfg write),
  // so the address-side cone is one mask- or range-compare. The compare
  // itself evaluates on addr_i = pmp's registered request boundary, so the
  // match verdict is the following cycle's value (H15: no side effect
  // before the verdict).
  logic [G6LCCfg.PLEN-1:0] conf_lo, conf_hi;
  always_comb begin : conf_prep
    conf_lo = {2'b0, conf_addr_prev_i} << 2;
    conf_hi = {2'b0, conf_addr_i} << 2;
    // use the extracted trailing ones
    size = {{(32 - $clog2(G6LCCfg.PLEN)) {1'b0}}, trail_ones} + 3;
    mask = '1 << size;
    base = ({2'b0, conf_addr_i} << 2) & mask;
  end

  always_comb begin
    case (conf_addr_mode_i)
      riscv::TOR: begin
        // check that the requested address is in between the two
        // configuration addresses
        match_o = (addr_i >= conf_lo) && (addr_i < conf_hi);

        // synthesis translate_off
        if (match_o == 0) begin
          assert (addr_i >= ({2'b0, conf_addr_i} << 2) || addr_i < ({2'b0, conf_addr_prev_i} << 2));
        end else begin
          assert (addr_i < ({2'b0, conf_addr_i} << 2) && addr_i >= ({2'b0, conf_addr_prev_i} << 2));
        end
        // synthesis translate_on

      end
      riscv::NAPOT: begin
        match_o = (addr_i & mask) == base ? 1'b1 : 1'b0;

        // synthesis translate_off
        // size extract checks
        assert (size >= 2);
        if (conf_addr_mode_i == riscv::NAPOT) begin : napot_canonical_chk
          // G6LC: recompute the trailing-ones count locally. `size`/`trail_ones`
          // are driven by the separate i_lzc instance and lag one delta when
          // conf_addr_i transitions — the per-hart conf bank muxes switch
          // conf_addr_i and conf_addr_mode_i in the same delta — which made the
          // immediate asserts below evaluate a stale count against a fresh
          // address and fire on legal encodings (Verilator eval-order hazard).
          automatic int unsigned chk_trail = 0;
          automatic bit          chk_zero_seen = 1'b0;
          for (int i = 0; i < G6LCCfg.PLEN - 2; i++) begin
            if (!chk_zero_seen && conf_addr_i[i]) chk_trail++;
            else chk_zero_seen = 1'b1;
          end
          assert (chk_trail + 3 > 2);
          if (chk_trail + 3 < G6LCCfg.PLEN - 2) assert (conf_addr_i[chk_trail] == 0);
          for (int i = 0; i < G6LCCfg.PLEN - 2; i++) begin
            if (chk_trail > 0 && i <= chk_trail - 1) begin
              assert (conf_addr_i[i] == 1);  // check that all the rest are ones
            end
          end
        end

        if (size < G6LCCfg.PLEN - 1) begin
          if (base + 2 ** size > base) begin  // check for overflow
            if (match_o == 0) begin
              assert (addr_i >= base + 2 ** size || addr_i < base);
            end else begin
              assert (addr_i < base + 2 ** size && addr_i >= base);
            end
          end else begin
            if (match_o == 0) begin
              assert (addr_i - 2 ** size >= base || addr_i < base);
            end else begin
              assert (addr_i - 2 ** size < base && addr_i >= base);
            end
          end
        end
        // synthesis translate_on

      end
      riscv::OFF: begin
        match_o = 1'b0;
      end
      default: begin
        match_o = 0;
      end
    endcase
  end

endmodule
