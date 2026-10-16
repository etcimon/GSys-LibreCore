// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Equivalence fixtures for the find-first / popcount rewrites of A100
// (g6lc_rename pick_free/pick_ffree, g6lc_iq slot allocation, store_buffer
// insertion index). Each pair is the scan as written before and the
// arithmetic form after; `sat -verify` over all inputs is exhaustive at the
// widths used here (combinational, N <= 32).
module ff_scan #(parameter int unsigned N = 16, parameter int unsigned W = $clog2(N)) (
    input  logic [N-1:0] fr,
    output logic [W-1:0] pick,       // lowest set index >= 1 (0 when none)
    output logic [W-1:0] pick0,      // lowest set index >= 0 (0 when none)
    output logic         any,        // any bit set
    output logic [W:0]   cnt         // popcount
);
  always_comb begin
    pick = '0;
    for (int unsigned i = 1; i < N; i++) if (fr[i] && pick == '0) pick = W'(i);
    pick0 = '0;
    for (int unsigned i = 0; i < N; i++) if (fr[i] && pick0 == '0 && !fr[0]) pick0 = W'(i);
    if (fr[0]) pick0 = '0;
    any = 1'b0;
    for (int unsigned i = 0; i < N; i++) if (fr[i] && !any) any = 1'b1;
    cnt = '0;
    for (int unsigned i = 0; i < N; i++) if (fr[i]) cnt = cnt + 1'b1;
  end
endmodule

module ff_arith #(parameter int unsigned N = 16, parameter int unsigned W = $clog2(N)) (
    input  logic [N-1:0] fr,
    output logic [W-1:0] pick,
    output logic [W-1:0] pick0,
    output logic         any,
    output logic [W:0]   cnt
);
  logic [N-1:0] cand, lowest, lowest0;
  always_comb begin
    cand    = fr & ~N'(1);
    lowest  = cand & (~cand + 1'b1);
    lowest0 = fr & (~fr + 1'b1);
    pick = '0;
    for (int unsigned i = 1; i < N; i++) if (lowest[i]) pick = pick | W'(i);
    pick0 = '0;
    for (int unsigned i = 0; i < N; i++) if (lowest0[i]) pick0 = pick0 | W'(i);
    any = |lowest0;
    cnt = (W + 1)'($countones(fr));
  end
endmodule
