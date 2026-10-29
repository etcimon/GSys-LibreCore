// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r87 / delay-v49: `pkg::NAME` enum members + package localparams must
// resolve in const_value so `Cfg.Policy == pkg::MODE_X` folds.
package pkg_enum_fold_pkg;
    localparam int POLICY_A = 1;
    typedef enum logic [1:0] {
        MODE_X = 2'd3,
        MODE_Y = 2'd0
    } mode_t;
endpackage

module pkg_enum_fold (
    input  logic        clk,
    input  logic [7:0]  a_i,
    output logic [7:0]  y_o
);
    parameter int Policy = 2;
    localparam bit ON = (Policy == pkg_enum_fold_pkg::MODE_X);
    logic [7:0] y_q, y_d;
    assign y_d = ON ? ((a_i * 8'h12 + a_i) * 8'h07 ^ a_i) : (a_i + 8'd1);
    assign y_o = y_q;
    always_ff @(posedge clk) y_q <= y_d;
endmodule
