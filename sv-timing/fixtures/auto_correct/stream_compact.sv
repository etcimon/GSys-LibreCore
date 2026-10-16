// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Stream compaction (ALGORITHMS-EXPERTS A103): the speculative store queue's
// cancel squash — walk the live window, keep the entries not cancelled,
// rewrite them dense from slot 0. `dst` is a conditional running count and
// `a_*[dst] = q[src]` a write at a running index: a serial chain of N
// incrementers and N demuxes. The LoopRewrite pass replaces it with a keep
// vector, independent prefix popcounts and a one-hot gather.
module stream_compact #(parameter int unsigned N = 8, parameter int unsigned W = $clog2(N) + 1) (
    input  logic          clk_i, rst_ni,
    input  logic [N-1:0]  valid_i, cancel_i,
    input  logic [N-1:0][15:0] addr_i,
    input  logic [N-1:0][7:0]  data_i,
    input  logic [$clog2(N)-1:0] rd_ptr_i,
    input  logic [W-1:0]  cnt_i,
    output logic [N-1:0][15:0] addr_o,
    output logic [N-1:0][7:0]  data_o,
    output logic [W-1:0]  live_o
);
  logic [N-1:0][15:0] a_addr;
  logic [N-1:0][7:0]  a_data;
  logic [W-1:0] dst, live;
  logic [$clog2(N)-1:0] src;

  always_comb begin
    a_addr = '0;
    a_data = '0;
    live = '0;
    dst  = '0;
    src  = '0;
    for (int unsigned k = 0; k < N; k++) begin
      if (k < unsigned'(cnt_i)) begin
        src = rd_ptr_i + $clog2(N)'(k);
        if (valid_i[src] && !cancel_i[src]) begin
          a_addr[dst] = addr_i[src];
          a_data[dst] = data_i[src];
          dst  = dst + 1'b1;
          live = live + 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      addr_o <= '0; data_o <= '0; live_o <= '0;
    end else begin
      addr_o <= a_addr; data_o <= a_data; live_o <= live;
    end
  end
endmodule
