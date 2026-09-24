// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module g6lc_ooo_snoop_props #(
    parameter bit NEGATIVE = 1'b0
) (
    input logic clk_i,
    input logic alloc_valid_i, lookup_valid_i, alloc_core_i,
    input logic [1:0] alloc_line_i, lookup_line_i,
    output logic saw_conflict_o = 1'b0
);
  logic reset_q = 1'b1;
  logic rst_n, ready, ar, lr, rv, expected_valid_q;
  logic [1:0] present, expected_q;
  logic [3:0][1:0] held_q;
  logic seen_first_q, seen_alias_q;
  assign rst_n = !reset_q;
  always_ff @(posedge clk_i) reset_q <= 1'b0;

  g6lc_ooo_snoop_filter #(.NR_CORES(2), .NR_ENTRIES(2), .LINE_BYTES(16)) dut (
      .clk_i, .rst_ni(rst_n), .alloc_valid_i, .alloc_addr_i(64'(alloc_line_i) << 4),
      .alloc_core_i, .alloc_ready_o(ar), .lookup_valid_i,
      .lookup_addr_i(64'(lookup_line_i) << 4), .lookup_ready_o(lr),
      .result_valid_o(rv), .present_o(present), .ready_o(ready)
  );

  always_ff @(posedge clk_i) begin
    if (!rst_n) begin
      held_q <= '0;
      expected_q <= '0;
      expected_valid_q <= 1'b0;
      seen_first_q <= 1'b0;
      seen_alias_q <= 1'b0;
      saw_conflict_o <= 1'b0;
    end else begin
      assert (rv == expected_valid_q);
      assert (lr == ready);
      assert (ar == (ready && !lookup_valid_i));
      if (rv) assert ((expected_q & ~(NEGATIVE ? 2'b00 : present)) == 0);
      expected_valid_q <= lookup_valid_i && lr;
      if (lookup_valid_i && lr) expected_q <= held_q[lookup_line_i];
      if (alloc_valid_i && ar) begin
        held_q[alloc_line_i][alloc_core_i] <= 1'b1;
        if (alloc_line_i == 0 && alloc_core_i == 0) seen_first_q <= 1'b1;
        if (seen_first_q && alloc_line_i == 2 && alloc_core_i == 1) seen_alias_q <= 1'b1;
      end
      if (seen_alias_q && rv && expected_q[0]) saw_conflict_o <= 1'b1;
    end
  end
endmodule
