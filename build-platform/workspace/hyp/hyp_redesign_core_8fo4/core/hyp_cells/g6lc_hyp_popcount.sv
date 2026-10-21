// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_hyp_popcount — the hyp8 replacement for the vendor popcount cell.
// Port and parameter list are identical so an instantiation only changes
// the module name. Function is identical to the vendor cell: the Hamming
// weight of data_i, computed by a balanced binary adder tree, combinational
// at every width (as with g6lc_hyp_lzc, a registered variant would need a
// clocked wrapper — future). Output width is ceil(log2(INPUT_WIDTH))+1.

module g6lc_hyp_popcount #(
    parameter int unsigned INPUT_WIDTH = 256,
    localparam int unsigned PopcountWidth = $clog2(INPUT_WIDTH) + 1
) (
    input  logic [INPUT_WIDTH-1:0]     data_i,
    output logic [PopcountWidth-1:0]   popcount_o
);

  localparam int unsigned PaddedWidth = 1 << $clog2(INPUT_WIDTH);

  logic [PaddedWidth-1:0]       padded_input;
  logic [PopcountWidth-2:0]     left_result, right_result;

  // zero-pad the input to the next power of two
  assign padded_input = {{(PaddedWidth - INPUT_WIDTH) {1'b0}}, data_i};

  if (INPUT_WIDTH == 1) begin : gen_single
    assign left_result  = 1'b0;
    assign right_result = padded_input[0];
  end else if (INPUT_WIDTH == 2) begin : gen_leaf
    assign left_result  = padded_input[1];
    assign right_result = padded_input[0];
  end else begin : gen_node
    g6lc_hyp_popcount #(.INPUT_WIDTH(PaddedWidth / 2)) i_left (
      .data_i(padded_input[PaddedWidth-1:PaddedWidth/2]),
      .popcount_o(left_result));
    g6lc_hyp_popcount #(.INPUT_WIDTH(PaddedWidth / 2)) i_right (
      .data_i(padded_input[PaddedWidth/2-1:0]),
      .popcount_o(right_result));
  end

  assign popcount_o = left_result + right_result;

endmodule
