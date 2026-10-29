// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r87 / delay-v49: a procedural `if (<param>)/else` inside always_comb —
// the constant-false arm must be dead for path enumeration.
module if_const_arm (
    input  logic        clk,
    input  logic [7:0]  a_i,
    output logic [7:0]  y_o
);
    parameter bit Use = 0;
    logic [7:0] y_q, y_d;
    always_comb begin
        if (!Use) y_d = a_i + 8'd1;
        else      y_d = ((a_i & 8'hff) * 8'h12 + a_i) * 8'h07 ^ a_i;
    end
    assign y_o = y_q;
    always_ff @(posedge clk) y_q <= y_d;
endmodule
