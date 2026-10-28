// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Billing fixture for the hi_last over-read found on
// g6lc_rename_resolve (hyp8 board analyze-ghz-r1: 41.6 FO4 in->out
// through a function-call prefix-OR one-hot; same module with the
// inline prefix measured 30.1 on analyze-ren-t1b1). Both modules
// compute the identical select (lowest-set index one-hot:
// o = x & ~prefix_or(x<<1)).
//
// Measured on delay-v44 @5000 MHz/20 ps/0.2 (2026-10-23):
//   fn_prefix_or_call          9.0 FO4   (function body billed ~9)
//   fn_prefix_or_inline       14.1 FO4   (serial dep-floor per var)
//   fn_prefix_or_call_gather  15.0 FO4   (7 boxed calls + gather)
//   fn_prefix_or_inline_gather 33.4 FO4  (all chains in one region)
// The isolated direction is REVERSED vs the board: the 41.6 reading
// is context-bound (function-call serial body stacked on the
// surrounding compare/gather cone), not a per-form constant — the
// region-boundary behaviour documented here is what the cost model
// must reconcile before a module-level fix lands.
module fn_prefix_or_call #(parameter int unsigned W = 6) (
    input  logic [W-1:0] x_i,
    output logic [W-1:0] o_o
);
  function automatic logic [W-1:0] hi_last(input logic [W-1:0] x);
    logic [W-1:0] a;
    a = x << 1;
    for (int unsigned l = 1; l < W; l = l << 1) a = a | (a << l);
    return x & ~a;
  endfunction
  assign o_o = hi_last(x_i);
endmodule

module fn_prefix_or_inline #(parameter int unsigned W = 6) (
    input  logic [W-1:0] x_i,
    output logic [W-1:0] o_o
);
  logic [W-1:0] pa;
  always_comb begin
    pa = x_i << 1;
    pa = pa | (pa << 1);
    pa = pa | (pa << 2);
    pa = pa | (pa << 4);
    if (W > 8)  pa = pa | (pa << 8);
    if (W > 16) pa = pa | (pa << 16);
  end
  assign o_o = x_i & ~pa;
endmodule

// The in-context shape: seven highest-set one-hots over independent
// compare vectors, OR-gathered per lane (the g6lc_rename_resolve
// pattern: hi_last called 7x per lane on 3*NR_PORTS=6-bit vectors,
// lane count 2). The function-call form bills the serial `for` body
// per call site; the inline form flattens to log depth.
module fn_prefix_or_call_gather #(parameter int unsigned W = 6) (
    input  logic [W-1:0] h0_i, h1_i, h2_i, h3_i, h4_i, h5_i, h6_i,
    output logic [W-1:0] o_o
);
  function automatic logic [W-1:0] hi_last(input logic [W-1:0] x);
    logic [W-1:0] a;
    a = x << 1;
    for (int unsigned l = 1; l < W; l = l << 1) a = a | (a << l);
    return x & ~a;
  endfunction
  logic [W-1:0] o0, o1, o2, o3, o4, o5, o6;
  assign o0 = hi_last(h0_i);
  assign o1 = hi_last(h1_i);
  assign o2 = hi_last(h2_i);
  assign o3 = hi_last(h3_i);
  assign o4 = hi_last(h4_i);
  assign o5 = hi_last(h5_i);
  assign o6 = hi_last(h6_i);
  assign o_o = o0 | o1 | o2 | o3 | o4 | o5 | o6;
endmodule

module fn_prefix_or_inline_gather #(parameter int unsigned W = 6) (
    input  logic [W-1:0] h0_i, h1_i, h2_i, h3_i, h4_i, h5_i, h6_i,
    output logic [W-1:0] o_o
);
  logic [W-1:0] o0, o1, o2, o3, o4, o5, o6;
  logic [W-1:0] a0, a1, a2, a3, a4, a5, a6;
  always_comb begin
    a0 = h0_i << 1; a0 = a0 | (a0 << 1); a0 = a0 | (a0 << 2);
    a1 = h1_i << 1; a1 = a1 | (a1 << 1); a1 = a1 | (a1 << 2);
    a2 = h2_i << 1; a2 = a2 | (a2 << 1); a2 = a2 | (a2 << 2);
    a3 = h3_i << 1; a3 = a3 | (a3 << 1); a3 = a3 | (a3 << 2);
    a4 = h4_i << 1; a4 = a4 | (a4 << 1); a4 = a4 | (a4 << 2);
    a5 = h5_i << 1; a5 = a5 | (a5 << 1); a5 = a5 | (a5 << 2);
    a6 = h6_i << 1; a6 = a6 | (a6 << 1); a6 = a6 | (a6 << 2);
    o0 = h0_i & ~a0; o1 = h1_i & ~a1; o2 = h2_i & ~a2; o3 = h3_i & ~a3;
    o4 = h4_i & ~a4; o5 = h5_i & ~a5; o6 = h6_i & ~a6;
  end
  assign o_o = o0 | o1 | o2 | o3 | o4 | o5 | o6;
endmodule
