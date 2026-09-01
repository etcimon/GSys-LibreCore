// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: `cva6_fifo_v3` data-order + control self-composition.
//
// I6 clause 1 (program-order issue) on `instr_queue` is a corollary of FIFO
// insertion order: each per-slot FIFO's `data_o` is the oldest unmatched push.
// `g6lc_fetch_iq_order.sby` previously *assumed* reachable `push_seq` values
// so `pseq_monotone` would not see unconstrained `mem_q`. That assumption is
// vacuously strong. This contract proves the FIFO property on the live module
// (FPGA_EN=0, FALL_THROUGH=0, DEPTH=4). IQ instantiates DEPTH=8; wrap, full,
// empty and simultaneous push+pop are the same cone at either depth.
//
// Two claims:
//   1. Data-order: a shadow queue of free payloads matches `data_o` at the head.
//   2. Self-composition: two copies, identical control, different payloads,
//      agree on empty/full/usage (control does not depend on data bits).
//
// Stimulus is top-level ports, not undriven internals. read_slang leaves
// undriven `logic push_i` as `1'x` *per instance* (`connect dut_a.push_i 1'x`),
// so two copies were not actually sharing control. Same shape as
// `g6lc_ooo_rob_props`. Reset is a generated `rst_init_q` (slang rejects
// `initial assume (!rst_ni)`). Asserts are `!en || P` with `en = rst_ni &
// armed_q` so they cannot fire before a clocked release from reset.
//
// Run: sby -f core/fetch_B/formal/cva6_fifo_v3_order.sby
//      cva6-build verify --formal --formal-remote

module cva6_fifo_v3_order_props (
    input logic       clk_i,
    input logic       flush_i,
    input logic       push_i,
    input logic       pop_i,
    input logic [7:0] data_a_i,
    input logic [7:0] data_b_i
);

`ifdef FORMAL
  localparam int unsigned DEPTH = 4;
  localparam int unsigned DW    = 8;
  localparam int unsigned PTRW  = $clog2(DEPTH);
  localparam int unsigned CNTW  = $clog2(DEPTH + 1);

  typedef logic [DW-1:0] dtype_t;

  logic rst_init_q = 1'b1;
  logic rst_ni;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  assign rst_ni = ~rst_init_q;

  logic armed_q = 1'b0;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) armed_q <= 1'b0;
    else armed_q <= 1'b1;
  end

  logic          full_a, empty_a, full_b, empty_b;
  logic [PTRW-1:0] usage_a, usage_b;
  dtype_t        data_a_o, data_b_o;

  cva6_fifo_v3 #(
      .FALL_THROUGH(1'b0),
      .FPGA_ALTERA (1'b0),
      .DATA_WIDTH  (DW),
      .DEPTH       (DEPTH),
      .dtype       (dtype_t),
      .FPGA_EN     (1'b0)
  ) dut_a (
      .clk_i, .rst_ni, .flush_i, .testmode_i(1'b0),
      .full_o(full_a), .empty_o(empty_a), .usage_o(usage_a),
      .data_i(data_a_i), .push_i(push_i),
      .data_o(data_a_o), .pop_i(pop_i)
  );

  cva6_fifo_v3 #(
      .FALL_THROUGH(1'b0),
      .FPGA_ALTERA (1'b0),
      .DATA_WIDTH  (DW),
      .DEPTH       (DEPTH),
      .dtype       (dtype_t),
      .FPGA_EN     (1'b0)
  ) dut_b (
      .clk_i, .rst_ni, .flush_i, .testmode_i(1'b0),
      .full_o(full_b), .empty_o(empty_b), .usage_o(usage_b),
      .data_i(data_b_i), .push_i(push_i),
      .data_o(data_b_o), .pop_i(pop_i)
  );

  dtype_t [DEPTH-1:0] shadow_q;
  logic [CNTW-1:0]    occ_q;
  logic [PTRW-1:0]    hd_q;
  logic [PTRW-1:0]    wr_idx;
  assign wr_idx = hd_q + occ_q[PTRW-1:0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      shadow_q <= '0;
      occ_q    <= '0;
      hd_q     <= '0;
    end else if (flush_i) begin
      occ_q <= '0;
      hd_q  <= '0;
    end else begin
      if (push_i) shadow_q[wr_idx] <= data_a_i;
      if (push_i && !pop_i) occ_q <= occ_q + 1'b1;
      else if (pop_i && !push_i) occ_q <= occ_q - 1'b1;
      if (pop_i) hd_q <= hd_q + 1'b1;
    end
  end

  wire en = rst_ni & armed_q;

  always_comb begin
    assume (!rst_ni || !full_a || !push_i);
    assume (!rst_ni || !empty_a || !pop_i);
    assume (!rst_ni || !flush_i || (!push_i && !pop_i));

    assert (!en || (empty_a == (occ_q == '0)));
    assert (!en || (full_a == (occ_q == CNTW'(DEPTH))));
    assert (!en || empty_a || flush_i || (data_a_o == shadow_q[hd_q]));

    assert (!en || (empty_a == empty_b));
    assert (!en || (full_a == full_b));
    assert (!en || (usage_a == usage_b));
  end

  always_ff @(posedge clk_i) begin
    if (en) begin
      cover (push_i);
      cover (pop_i);
      cover (push_i && pop_i);
      cover (!empty_a && (usage_a != '0));
      cover (full_a);
    end
  end
`endif

endmodule
