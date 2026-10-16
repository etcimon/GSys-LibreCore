// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Equivalence fixture for the scoreboard younger-cancel window
// (ALGORITHMS-EXPERTS A98). `sb_walk` is the production shape before the
// change: step a TRANS_ID_BITS pointer from `after` through the ring until it
// meets `ip` (exclusive), marking every slot that passes a per-slot gate.
// `sb_window` is the production shape after: per-slot membership in the ring
// interval [after, ip) — two compares and a mux per slot, no chain.
//
// Proved equal with `sat -verify` over all inputs for N = 8 and 16 on the
// builder; the 32-entry miter is a million variables (the walk's dynamic
// index chain) and is run separately with a time budget. Mapped on Nangate45
// at N = 32 (delay-oriented ABC): walk 144 cells / 14.7 ns, window 12 cells /
// 0.78 ns, area 6773 -> 613 um^2.
module sb_walk #(
    parameter int unsigned N = 8
) (
    input  logic [$clog2(N)-1:0] after_i, ip_i,
    input  logic [N-1:0]         ok_i,
    output logic [N-1:0]         mask_o
);
  localparam int unsigned W = $clog2(N);
  always_comb begin
    logic [W-1:0] cid;
    mask_o = '0;
    cid = after_i;
    for (int unsigned k = 0; k < N; k++) begin
      if (cid == ip_i) break;
      if (ok_i[cid]) mask_o[cid] = 1'b1;
      cid = cid + 1'b1;
    end
  end
endmodule

module sb_window #(
    parameter int unsigned N = 8
) (
    input  logic [$clog2(N)-1:0] after_i, ip_i,
    input  logic [N-1:0]         ok_i,
    output logic [N-1:0]         mask_o
);
  localparam int unsigned W = $clog2(N);
  always_comb begin
    for (int unsigned i = 0; i < N; i++) begin
      logic [W-1:0] slot_i;
      logic in_range;
      slot_i   = W'(i);
      in_range = (after_i != ip_i) &&
                 ((ip_i > after_i) ? (slot_i >= after_i && slot_i < ip_i)
                                   : (slot_i >= after_i || slot_i < ip_i));
      mask_o[i] = in_range & ok_i[i];
    end
  end
endmodule
