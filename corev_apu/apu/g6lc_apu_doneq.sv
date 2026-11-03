// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Engine completion queue (§7b/5a-ii): cmdexec counts one work_done_i
// per completion, but engine done pulses are single-cycle and engines
// run concurrently — two coincident pulses would collapse into one
// outst_q decrement and strand it (StDrain livelock, fence never
// signals).  Up to four sources push in one cycle in fixed priority
// order {0,1,2,3}; one completion pops per cycle.  Factored out of
// g6lc_apu_vgtop so the multi-source collision is unit-testable
// (tb_g6lc_apu_doneq) — no engine pair collides in the session corpus.
//
// Depth: the caller sizes Depth to the worst-case outstanding set plus
// one slot of slack so head != tail distinguishes a full queue.
module g6lc_apu_doneq #(
  parameter int unsigned Depth = 8,         // power of two >= 2
  parameter type         pl_t  = logic [31:0]
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [3:0]  push_i,
  input  pl_t  [3:0]  pl_i,
  output logic        pop_o,               // = valid; pops every cycle
  output pl_t         pl_o,
  output logic [2:0]  push_n_o             // completions pushed this cycle
);
  localparam int unsigned W = $clog2(Depth);
  pl_t            q_q [Depth];
  logic [W-1:0]   head_q, tail_q;
  logic [W-1:0]   n0, n1, n2;

  assign n0       = W'(push_i[0]);
  assign n1       = W'(push_i[1]);
  assign n2       = W'(push_i[2]);
  assign push_n_o = 3'(push_i[0]) + 3'(push_i[1]) + 3'(push_i[2]) +
                    3'(push_i[3]);
  assign pop_o    = head_q != tail_q;
  assign pl_o     = q_q[head_q];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
    end else begin
      if (push_i[0]) q_q[tail_q]                <= pl_i[0];
      if (push_i[1]) q_q[tail_q + n0]           <= pl_i[1];
      if (push_i[2]) q_q[tail_q + n0 + n1]      <= pl_i[2];
      if (push_i[3]) q_q[tail_q + n0 + n1 + n2] <= pl_i[3];
      tail_q <= tail_q + W'(push_n_o);
      head_q <= head_q + W'(pop_o);
    end
  end

  // pragma translate_off
`ifndef SYNTHESIS
  if (Depth < 2 || (Depth & (Depth - 1)) != 0) begin : gen_bad_depth
    initial $fatal(1, "g6lc_apu_doneq: Depth must be a power of two >= 2");
  end
  // occupancy equal to Depth would alias head == tail back to empty and
  // silently drop a completion
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      ({1'b0, W'(tail_q - head_q)} + (W+1)'(push_n_o) - (W+1)'(pop_o))
      <= (W+1)'(Depth - 1))
    else $fatal(1, "g6lc_apu_doneq: overflow");
`endif
  // pragma translate_on
endmodule
