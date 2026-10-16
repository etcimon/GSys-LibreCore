// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// SelectIncrement fixture (ALGORITHMS-EXPERTS A88): a 16-bit sequence counter
// and a 2-bit ring index both advance by a 0..NR step that is the end product
// of a control cone (valid mask -> compaction -> overflow -> partial admission).
// `seq_q + 16'(step)` puts the 16-bit adder after that cone; the transform
// precomputes `seq_q + j` for every j the 3-bit `step` can encode and selects.
// The ring index is 2 bits wide: its adder is already cheaper than a select,
// so the transform must leave it alone.
module select_increment_fixture #(
    parameter int unsigned NR = 4
) (
    input  logic              clk_i,
    input  logic              rst_ni,
    input  logic [NR-1:0]     valid_i,
    input  logic [NR-1:0]     full_i,
    input  logic              addr_overflow_i,
    input  logic              leftover_i,
    output logic [15:0]       seq_o,
    output logic [1:0]        idx_o
);
  localparam int unsigned StepW = $clog2(NR + 1);
  typedef logic [1:0] idx_t;
  localparam idx_t IdxMask = idx_t'(NR - 1);

  logic [15:0]      seq_q, seq_d;
  idx_t             idx_q, idx_d;
  logic [StepW-1:0] step;
  logic             instr_overflow, lo_partial;
  logic [NR-1:0]    pos;

  // Admission cone (the critical input of the adders).
  always_comb begin : gen_pos
    idx_t rank;
    rank = '0;
    pos = '0;
    for (int unsigned s = 0; s < NR; s++) begin
      if (valid_i[s]) begin
        pos[(idx_q + rank) & IdxMask] = 1'b1;
        rank = rank + 1'b1;
      end
    end
  end
  assign instr_overflow = |(full_i & pos);
  assign lo_partial     = leftover_i & valid_i[0] & ~full_i[idx_q];

  always_comb begin : gen_step
    logic [StepW-1:0] count;
    count = '0;
    for (int unsigned i = 0; i < NR; i++) if (valid_i[i]) count = count + 1'b1;
    step = addr_overflow_i ? '0 : lo_partial ? StepW'(1) : instr_overflow ? '0 : count;
  end

  assign seq_d = seq_q + 16'(step);
  assign idx_d = (idx_q + idx_t'(step)) & IdxMask;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      seq_q <= '0;
      idx_q <= '0;
    end else begin
      seq_q <= seq_d;
      idx_q <= idx_d;
    end
  end

  assign seq_o = seq_q;
  assign idx_o = idx_q;
endmodule
