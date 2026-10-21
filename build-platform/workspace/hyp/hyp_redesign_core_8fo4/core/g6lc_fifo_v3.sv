// hyp8 provenance: REWRITTEN (group-10 T5) -- thin wrapper over
// core/hyp_cells/g6lc_hyp_fifo.sv
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_fifo_v3 -- drop-in replacement for the reference fifo_v3 with the
// identical port and parameter surface (FALL_THROUGH, FPGA_ALTERA,
// DATA_WIDTH, DEPTH, dtype, FPGA_EN, ADDR_DEPTH all forwarded). Every
// consumer in the tree keeps its instantiation unchanged; the timing
// departure lives in g6lc_hyp_fifo (registered fall-through/pop path --
// see the hyp8 note there). FPGA_ALTERA/FPGA_EN are accepted and ignored
// by the single implementation, as in g6lc_hyp_fifo.

module g6lc_fifo_v3 #(
    parameter bit FALL_THROUGH = 1'b0,  // fifo is in fall-through mode
    parameter bit FPGA_ALTERA = 1'b0,  // FPGA Altera optimizations enabled
    parameter int unsigned DATA_WIDTH = 32,  // default data width if the fifo is of type logic
    parameter int unsigned DEPTH = 8,  // depth can be arbitrary from 0 to 2**32
    parameter type dtype = logic [DATA_WIDTH-1:0],
    parameter bit FPGA_EN = 1'b0,
    // DO NOT OVERWRITE THIS PARAMETER
    parameter int unsigned ADDR_DEPTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                  clk_i,       // Clock
    input  logic                  rst_ni,      // Asynchronous reset active low
    input  logic                  flush_i,     // flush the queue
    input  logic                  testmode_i,  // test_mode to bypass clock gating
    // status flags
    output logic                  full_o,      // queue is full
    output logic                  empty_o,     // queue is empty
    output logic [ADDR_DEPTH-1:0] usage_o,     // fill pointer
    // data and transaction
    input  dtype                  data_i,      // data to push into the queue
    input  logic                  push_i,      // data is valid and can be pushed
    output dtype                  data_o,      // output data
    input  logic                  pop_i        // pop head from queue
);

  g6lc_hyp_fifo #(
      .FALL_THROUGH (FALL_THROUGH),
      .FPGA_ALTERA  (FPGA_ALTERA),
      .DATA_WIDTH   (DATA_WIDTH),
      .DEPTH        (DEPTH),
      .dtype        (dtype),
      .FPGA_EN      (FPGA_EN),
      .ADDR_DEPTH   (ADDR_DEPTH)
  ) i_fifo (
      .clk_i       (clk_i),
      .rst_ni      (rst_ni),
      .flush_i     (flush_i),
      .testmode_i  (testmode_i),
      .full_o      (full_o),
      .empty_o     (empty_o),
      .usage_o     (usage_o),
      .data_i      (data_i),
      .push_i      (push_i),
      .data_o      (data_o),
      .pop_i       (pop_i)
  );

endmodule
