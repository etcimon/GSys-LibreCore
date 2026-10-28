// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r85 / delay-v48: a localparam-gated output whose dead arm carries a
// deep cone — the measured path must come from the shallow live arm
// only (the dead arm's assign is a region node pruned off the path).
module dead_arm_region (
    input  logic        clk,
    input  logic [7:0]  a_i,
    output logic [7:0]  y_o
);
    parameter int unsigned Stages = 1;
    localparam bit REC = (Stages == 2);

    logic [7:0] g_a, r_q;
    // Deep dead arm (multiplier chain) — never read when REC == 0.
    assign g_a = ((a_i & 8'hff) * 8'h12 + a_i) * 8'h07 ^ a_i;
    assign y_o = REC ? g_a : r_q;

    always_ff @(posedge clk) r_q <= a_i + 8'h1;
endmodule
