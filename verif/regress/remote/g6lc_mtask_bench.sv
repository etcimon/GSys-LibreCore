// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module g6lc_mtask_bench #(parameter int Rounds = 0) (
    input logic clk,
    input logic [31:0] stimulus,
    output logic [31:0] digest
);
    localparam int N = 24;
    logic [31:0] x[N], y[N];

    function automatic logic [31:0] mix(logic [31:0] v, logic [31:0] z);
        for (int j = 0; j < Rounds; j++) v = {v[20:0], v[31:21]} ^ ((v + z) >> 3);
        return v;
    endfunction

    for (genvar k = 0; k < N; k++) begin
        initial begin
            x[k] = k + 1;
            y[k] = k;
        end
        always_ff @(posedge clk) begin
            x[k] <= mix({x[k][24:0], x[k][31:25]} + (stimulus ^ (32'd37 * k)), stimulus);
            y[k] <= (x[k] ^ x[(k+1)%N]) + y[k];
        end
    end
    always_comb begin
        digest = 0;
        for (int k = 0; k < N; k++) digest += y[k];
    end
endmodule
