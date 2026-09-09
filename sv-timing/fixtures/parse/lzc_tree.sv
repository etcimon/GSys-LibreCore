// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Reduced leading-zero / OR-mux tree (lzc). Depth is logarithmic in WIDTH;
// statement-order serial sum of generate assigns is not the FO4.

module lzc_tree #(
    parameter int unsigned WIDTH = 8
) (
    input  logic [WIDTH-1:0] in_i,
    output logic [2:0]       cnt_o,
    output logic             empty_o
);
  localparam int unsigned NumLevels = 3;
  logic [7:0] sel_nodes;
  logic [7:0][2:0] index_nodes;
  logic [WIDTH-1:0] in_tmp;
  logic [WIDTH-1:0][2:0] index_lut;

  always_comb begin
    for (int unsigned i = 0; i < WIDTH; i++) in_tmp[i] = in_i[i];
  end

  for (genvar j = 0; j < WIDTH; j++) begin : g_lut
    assign index_lut[j] = 3'(j);
  end

  for (genvar k = 0; k < 4; k++) begin : g_leaf
    if (k * 2 < WIDTH - 1) begin : g_reduce
      assign sel_nodes[4 + k] = in_tmp[k * 2] | in_tmp[k * 2 + 1];
      assign index_nodes[4 + k] = (in_tmp[k * 2] == 1'b1) ? index_lut[k * 2]
                                                          : index_lut[k * 2 + 1];
    end
  end

  assign sel_nodes[1] = sel_nodes[4] | sel_nodes[5];
  assign index_nodes[1] = (sel_nodes[4] == 1'b1) ? index_nodes[4] : index_nodes[5];
  assign sel_nodes[2] = sel_nodes[6] | sel_nodes[7];
  assign index_nodes[2] = (sel_nodes[6] == 1'b1) ? index_nodes[6] : index_nodes[7];
  assign sel_nodes[0] = sel_nodes[1] | sel_nodes[2];
  assign index_nodes[0] = (sel_nodes[1] == 1'b1) ? index_nodes[1] : index_nodes[2];

  assign cnt_o = index_nodes[0];
  assign empty_o = ~sel_nodes[0];
endmodule
