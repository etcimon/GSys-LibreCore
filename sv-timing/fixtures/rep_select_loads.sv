// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r87 / delay-v49: `{W{s}} & x` replication operands drive one mask
// gate per bit — same W-load fanout as a bare-ident mux select, so
// `p_andor64` must bill within ~2 FO4 of `p_mux64_bare`.
module p_mux64_bare (input logic clk, input logic s_q,
    input logic [63:0] a_q, b_q, output logic [63:0] y_o);
    logic [63:0] y_d;
    assign y_d = s_q ? a_q : b_q;
    assign y_o = y_d;
endmodule
module p_andor64 (input logic clk, input logic s_q,
    input logic [63:0] a_q, b_q, output logic [63:0] y_o);
    logic [63:0] y_d;
    assign y_d = ({64{s_q}} & a_q) | ({64{!s_q}} & b_q);
    assign y_o = y_d;
endmodule
module p_and48rep (input logic clk, input logic s_q,
    input logic [47:0] a_q, output logic [47:0] y_o);
    logic [47:0] y_d;
    assign y_d = {48{s_q}} & a_q;
    assign y_o = y_d;
endmodule
