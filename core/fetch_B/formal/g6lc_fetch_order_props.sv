// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: packet / slot ordering contract (I2, I7) over the pure
// functions of `g6lc_fetch_pkg`. Self-contained: no frontend elaboration.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_order.sby
//      cva6-build verify --formal

module g6lc_fetch_order_props #(
    parameter int unsigned N = 4
) (
    input logic        clk_i,
    input logic        rst_ni,
    input logic [31:0] n,
    input logic [7:0]  taken,
    input logic [7:0]  slot_valid,
    input logic [7:0]  consumed,
    input logic        overflow,
    input logic        complete,
    input logic        slot0_v,
    input logic        slot0_full,
    input logic        ge,
    input logic        link
);

`ifdef FORMAL
  import g6lc_fetch_pkg::*;

  logic [7:0] mask;
  logic       accept;
  logic       push;
  logic       keep;
  logic       cf;
  logic       cf_witness;

  always_comb begin
    mask   = packet_upto_cf(taken, n);
    accept = packet_accept(overflow);
    push   = leftover_slot0_push(complete, slot0_v, slot0_full, overflow);
    keep   = slot_keep_link(ge, link);
    cf     = cf_consumed(slot_valid, taken, consumed);
  end

  always_comb begin
    cf_witness = 1'b0;
    for (int unsigned i = 0; i < 8; i++) begin
      if (slot_valid[i] && taken[i] && consumed[i]) cf_witness = 1'b1;
    end
  end

  // BMC/prove: start from a forced reset (no free-state induction trap).
  initial assume (!rst_ni);

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // `n` is geo.slots; packet_upto_cf only iterates 8 halfword slots.
      assume (n <= 32'd8);
      // Host drives geo.slots (N) slots; the spare upper bits are tied 0.
      for (int unsigned i = N; i < 8; i++) begin
        assume (!taken[i]);
        assume (!slot_valid[i]);
        assume (!consumed[i]);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Contiguous prefix: no holes.
      for (int unsigned i = 0; i < 8; i++) begin
        for (int unsigned j = 0; j < 8; j++) begin
          if (i < j && mask[j]) assert (mask[i]);
        end
      end
      // Nothing at or beyond the live slot count.
      for (int unsigned i = 0; i < 8; i++) begin
        if (i >= n) assert (!mask[i]);
      end
      // I2: keep through the first taken CF inclusive, nothing after it.
      for (int unsigned i = 0; i < 8; i++) begin
        if (taken[i] && mask[i]) begin
          for (int unsigned j = 0; j < 8; j++) begin
            if (j > i) assert (!mask[j]);
          end
        end
      end
      // A non-empty packet always keeps its first slot.
      if (n > 32'd0) assert (mask[0]);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // I7: whole packet or none.
      assert (accept == !overflow);
      // The slot0 carry push only exists as an overflow escape.
      if (push) begin
        assert (complete && slot0_v && !slot0_full && overflow);
        assert (!accept);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Link keep is monotone in the ge test.
      if (ge) assert (keep);
      // A consumed CF needs a slot that is valid, taken and consumed.
      if (cf) assert (cf_witness);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (mask[0] && !mask[1]);
      cover (push);
      cover (cf);
    end
  end
`endif

endmodule
