// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Combinational `for (int unsigned w = 0; w < N; w++)` unrolls; `w * SETS`
// is a constant index (hpdcache_mshr hit_comb), not a 56 FO4 multiply.

module comb_for_scale;
  localparam int unsigned WAYS = 4;
  localparam int unsigned SETS = 8;
  logic [7:0] check_set_st1;
  logic [3:0] hit_way;
  logic hit_o;
  logic [7:0] mshr_valid_q[0:31];

  always_comb begin
    for (int unsigned w = 0; w < WAYS; w++) begin
      hit_way[w] = mshr_valid_q[w * SETS + check_set_st1];
    end
    hit_o = |hit_way;
  end
endmodule
