// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// CVA6-style unit: patterns drawn from core/load_unit.sv + core/scoreboard.sv
// without CVA6Cfg / ariane_pkg — validates package import, localparam, named
// always_comb / always_ff begin blocks, posedge+negedge sensitivity.

module cva6_style_unit
  import cva6_style_pkg::*;
#(
    parameter int unsigned W = 16
) (
    input  logic             clk_i,
    input  logic             rst_ni,
    input  logic             valid_i,
    input  logic [W-1:0]     a_i,
    input  logic [W-1:0]     b_i,
    input  logic [W-1:0]     c_i,
    output logic [W-1:0]     y_o,
    output logic             full_o
);
  // load_unit-style localparams
  localparam logic LDBUF_FALLTHROUGH = 1'b0;
  localparam int unsigned REQ_ID_BITS = PKG_DEPTH > 1 ? $clog2(PKG_DEPTH) : 1;

  typedef logic [REQ_ID_BITS-1:0] ldbuf_id_t;

  logic [W-1:0] t0, t1, t2;
  logic [W-1:0] mem_q, mem_n;
  logic [W-1:0] issue_q, issue_n;
  ldbuf_id_t    idx_q, idx_n;

  // scoreboard / load_unit style: always_comb begin : name
  always_comb begin : comb_datapath
    t0 = pkg_add(a_i, b_i);
    t1 = t0 + c_i;
    t2 = pkg_mux(valid_i, t1, t0);
    mem_n   = t2 + mem_q;
    issue_n = issue_q + t0;
    idx_n   = idx_q + ldbuf_id_t'(1);
    full_o  = LDBUF_FALLTHROUGH ? 1'b0 : (idx_q == ldbuf_id_t'(PKG_DEPTH - 1));
  end

  // load_unit ldbuf_ff / scoreboard regs: always_ff posedge+negedge begin : name
  always_ff @(posedge clk_i or negedge rst_ni) begin : regs
    if (!rst_ni) begin
      mem_q   <= '0;
      issue_q <= '0;
      idx_q   <= '0;
      y_o     <= '0;
    end else begin
      mem_q   <= mem_n;
      issue_q <= issue_n;
      idx_q   <= idx_n;
      if (valid_i) begin
        y_o <= mem_n;
      end
    end
  end

  // Second named comb block (load_control style)
  always_comb begin : load_control
    // intentionally light — density of named begins + package use
    if (valid_i) begin : accept
      // accept path
    end else begin : stall
      // stall path
    end
  end
endmodule
