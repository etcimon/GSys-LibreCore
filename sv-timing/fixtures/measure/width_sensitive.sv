// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// P14 golden fixture (M3 — width scaling, reference width 32).
//
// The same operator class at three declared widths plus one host-parameterized
// width. Expected after M3:
//   * fo4(add64) > fo4(add8) > fo4(add1), all floored at `logic_bit`
//   * a node whose width is NOT resolvable stays `width_defaulted = true` and
//     costs exactly the fo4-v1 base (reference width 32) — so existing goldens
//     do not move until a width is actually inferred
//   * with `--assume-xlen 64` / `--param-map {"CVA6Cfg.XLEN":64}` the
//     `xw_o` port resolves to 64 and scales like `add64`
// The mul rows pin the (w/32)^2 rule; `mul1` must not fall below `logic_bit`.

module width_sensitive #(
    parameter int unsigned WIDTH = 8
) (
    input  logic                      a1_i,
    input  logic                      b1_i,
    input  logic [7:0]                a8_i,
    input  logic [7:0]                b8_i,
    input  logic [63:0]               a64_i,
    input  logic [63:0]               b64_i,
    input  logic [WIDTH-1:0]          ap_i,
    input  logic [WIDTH-1:0]          bp_i,
    input  logic [CVA6Cfg.XLEN-1:0]   ax_i,
    input  logic [CVA6Cfg.XLEN-1:0]   bx_i,
    output logic                      add1_o,
    output logic [8:0]                add8_o,
    output logic [64:0]               add64_o,
    output logic [WIDTH:0]            addp_o,
    output logic [CVA6Cfg.XLEN-1:0]   xw_o,
    output logic                      mul1_o,
    output logic [127:0]              mul64_o
);
  always_comb begin : widths
    add1_o  = a1_i + b1_i;
    add8_o  = a8_i + b8_i;
    add64_o = a64_i + b64_i;
    addp_o  = ap_i + bp_i;
    xw_o    = ax_i + bx_i;
    mul1_o  = a1_i * b1_i;
    mul64_o = a64_i * b64_i;
  end
endmodule
