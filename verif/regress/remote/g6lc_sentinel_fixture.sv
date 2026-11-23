// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module g6lc_sentinel_fixture (
    input logic clk,
    input logic [63:0] row,
    input logic [7:0] enable_mask,
    output logic [7:0] plane,
    output logic selected,
    output logic [31:0] digest
);
    assign plane = {row[63], row[55], row[47], row[39], row[31], row[23], row[15], row[7]};
    assign selected = |(plane & enable_mask);
    logic [31:0] state[24];
    for (genvar i = 0; i < 24; ++i) begin
        always_ff @(posedge clk)
            state[i] <= {state[i][20:0], state[i][31:21]} + (row[31:0] ^ i);
    end
    always_comb begin
        digest = 0;
        for (int i = 0; i < 24; ++i) digest ^= state[i];
    end
endmodule
