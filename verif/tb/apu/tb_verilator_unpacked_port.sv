// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

package vlt_unpacked_port_pkg;
  typedef struct {
    int value;
    int items[2];
  } state_t;
  typedef struct packed {
    logic [7:0] tag;
    logic [15:0] value;
  } packed_t;
endpackage

module vlt_unpacked_port_child (
  input vlt_unpacked_port_pkg::state_t in_i,
  output vlt_unpacked_port_pkg::state_t out_o,
  input vlt_unpacked_port_pkg::packed_t packed_i,
  output vlt_unpacked_port_pkg::packed_t packed_o,
  input logic [31:0] words_i[2],
  output logic [31:0] words_o[2],
  input vlt_unpacked_port_pkg::state_t states_i[2],
  output vlt_unpacked_port_pkg::state_t states_o[2]
);
  /* verilator no_inline_module */
  assign out_o = in_i;
  assign packed_o = packed_i;
  assign words_o = words_i;
  assign states_o = states_i;
endmodule

module tb_verilator_unpacked_port;
  import vlt_unpacked_port_pkg::*;
  state_t src, dst;
  state_t sources[2], destinations[2];
  packed_t packed_src, packed_dst;
  logic [31:0] words_src[2], words_dst[2];
  vlt_unpacked_port_child child(
    .in_i(src), .out_o(dst), .packed_i(packed_src), .packed_o(packed_dst),
    .words_i(words_src), .words_o(words_dst),
    .states_i(sources), .states_o(destinations));
  initial begin
    src = '{value: 42, items: '{17, 23}};
    packed_src = '{tag: 8'hAB, value: 16'h1234};
    words_src = '{32'h12345678, 32'hABCD1234};
    sources = '{src, src};
    #1;
    if (dst.value != 42 || dst.items[1] != 23) $fatal(1, "port data");
    if (child.out_o.value != 42 || child.in_i.items[0] != 17)
      $fatal(1, "hierarchical port data");
    if (packed_dst !== packed_src || words_dst[1] !== words_src[1] ||
        child.packed_o !== packed_src || child.words_o[0] !== words_src[0])
      $fatal(1, "packed and scalar-array controls");
    if (destinations[1].items[1] != 23 || child.states_o[0].value != 42)
      $fatal(1, "unpacked struct-array ports");
    $display("PASS tb_verilator_unpacked_port");
    $finish;
  end
endmodule
