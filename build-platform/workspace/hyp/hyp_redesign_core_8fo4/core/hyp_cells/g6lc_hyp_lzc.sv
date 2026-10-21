// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_hyp_lzc — the hyp8 replacement for the vendor lzc cell. Port and
// parameter list are identical so an instantiation only changes the module
// name. Function is identical to the vendor cell and implemented as an
// explicit balanced tree, combinational at every width: the design intent
// for WIDTH>32 is a two-half tree whose partial results are registered, but
// lzc has no clock port — the registered variant needs a clocked wrapper
// (future). This cell is the combinational drop-in.
//
// MODE=0: count of trailing zeros (from the LSB); MODE=1: leading zeros
// (from the MSB). in_i all zero -> empty_o=1 and cnt_o = WIDTH-1, matching
// the vendor cell.

module g6lc_hyp_lzc #(
    parameter int unsigned WIDTH = 2,
    parameter bit          MODE  = 1'b0,
    parameter int unsigned CNT_WIDTH = cf_math_pkg::idx_width(WIDTH)
) (
    input  logic [WIDTH-1:0]     in_i,
    output logic [CNT_WIDTH-1:0] cnt_o,
    output logic                 empty_o
);

  if (WIDTH == 1) begin : gen_degenerate
    assign cnt_o   = !in_i[0];
    assign empty_o = !in_i[0];
  end else begin : gen_tree
    // reverse once at this level for leading-zero mode, then count trailing
    logic [WIDTH-1:0] in;
    for (genvar i = 0; i < WIDTH; i++) begin : g_flip
      assign in[i] = MODE ? in_i[WIDTH-1-i] : in_i[i];
    end

    localparam int unsigned H    = WIDTH / 2;
    localparam int unsigned WC_L = cf_math_pkg::idx_width(H);
    localparam int unsigned WC_H = cf_math_pkg::idx_width(WIDTH - H);

    logic [WC_L-1:0] lo_cnt;
    logic            lo_empty;
    logic [WC_H-1:0] hi_cnt;
    logic            hi_empty;

    g6lc_hyp_lzc #(.WIDTH(H), .MODE(1'b0)) i_lo (
      .in_i(in[H-1:0]), .cnt_o(lo_cnt), .empty_o(lo_empty));
    g6lc_hyp_lzc #(.WIDTH(WIDTH - H), .MODE(1'b0)) i_hi (
      .in_i(in[WIDTH-1:H]), .cnt_o(hi_cnt), .empty_o(hi_empty));

    // trailing zeros of the whole vector: the low half's count when a '1'
    // lives there, else H + the high half's count. When both halves are
    // empty this yields (WIDTH-H-1)+H = WIDTH-1, matching the vendor cell.
    assign cnt_o   = lo_empty ? CNT_WIDTH'(hi_cnt) + CNT_WIDTH'(H)
                              : CNT_WIDTH'(lo_cnt);
    assign empty_o = lo_empty & hi_empty;
  end

endmodule
