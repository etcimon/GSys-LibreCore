// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r88 / delay-v49: the exact g6lc_lsq shape — a struct-typed module
// parameter bound through the param-map (`Cfg.Policy`), compared to a
// package enum member with sized literals, into a `localparam bit`
// that gates an `&&` chain. With `Cfg.Policy = 2` the deep `deep`
// cone is dead whole (no ternary arm — the `&&` folds); with 3 it is
// live.
package psf_pkg;
  typedef enum logic [1:0] {
    MODE_A = 2'd0,
    MODE_B = 2'd1,
    MODE_X = 2'd3
  } policy_t;
  typedef struct packed {
    int unsigned Width;
    policy_t     Policy;
  } cfg_t;
  localparam cfg_t cfg_empty = '{Width: 8, Policy: MODE_A};
endpackage

module pkg_struct_field_fold
  import psf_pkg::*;
#(
    parameter psf_pkg::cfg_t Cfg = psf_pkg::cfg_empty
) (
    input  logic        clk_i,
    input  logic [31:0] a_i,
    input  logic        en_i,
    output logic        y_o,
    output logic        z_o
);
  localparam bit ON  = Cfg.Policy == psf_pkg::MODE_X;
  localparam bit OFF = (Cfg.Policy != psf_pkg::MODE_X);
  logic [31:0] deep;
  assign deep = (a_i * 32'h12345 + (a_i >> 3)) ^ a_i;
  assign y_o = ON && en_i && (|deep);
  assign z_o = OFF && en_i;
endmodule
