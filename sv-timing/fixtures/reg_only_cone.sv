// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r87 / delay-v49: a region whose only sink is a register — the
// reg->reg path must survive dead-node pruning (no --keep-dead-nodes).
// probe3.sv p6 shape plus a second register-only 2:1-mux cone.
module reg_only_cone (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [3:0]  a_i,
    input  logic        s_i,
    output logic [3:0]  y_o
);
    logic [3:0] y_q, y_d;
    logic [7:0] z_q, z_d;

    assign y_d = ~y_q + a_i;
    assign z_d = s_i ? (z_q ^ 8'hA5) : (z_q + a_i);
    assign y_o = y_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_q <= '0;
            z_q <= '0;
        end else begin
            y_q <= y_d;
            z_q <= z_d;
        end
    end
endmodule
