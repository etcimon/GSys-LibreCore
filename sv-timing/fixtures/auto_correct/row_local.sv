// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module row_local #(parameter int unsigned N = 8) (
  input logic clk_i, rst_ni, valid_i,
  input logic [$clog2(N)-1:0] uidx, ridx,
  output logic [7:0] result_o
);
  logic [N-1:0][7:0] q, d;
  always_comb begin
    d = q;
    // svt-pipe: row-local train index=uidx rows=N banks=q:d max-rows=16
    if (valid_i) begin
      // A comment containing q[uidx] must not be rewritten.
      if (q[uidx] != 8'hff) d[uidx] = q[uidx] + 8'd1;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) q <= '0;
    else q <= d;
  assign result_o = q[ridx];
endmodule

module row_local_record #(parameter int unsigned N = 4) (
  input logic clk_i, rst_ni, valid_i, taken_i,
  input logic [$clog2(N)-1:0] uidx, ridx,
  input logic [7:0] tag_i,
  output logic [7:0] result_o
);
  typedef struct packed {logic valid; logic [7:0] tag, count;} entry_t;
  entry_t [N-1:0] mem_q, mem_d;
  always_comb begin
    mem_d = mem_q;
    // svt-pipe: row-local owner index=uidx rows=N banks=mem_q:mem_d max-rows=16
    if (valid_i) begin
      if (mem_q[uidx].valid && mem_q[uidx].tag == tag_i)
        mem_d[uidx].count = mem_q[uidx].count + 8'd1;
      else if (taken_i) begin
        mem_d[uidx].valid = 1'b1;
        mem_d[uidx].tag = tag_i;
        mem_d[uidx].count = '0;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) mem_q <= '0;
    else mem_q <= mem_d;
  assign result_o = mem_q[ridx].count;
endmodule
