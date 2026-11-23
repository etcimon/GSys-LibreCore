// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Two equivalent lowerings of a masked row reduction; no one-hot assumption.
module g6lc_masked_row_bench #(parameter bit PackedRows = 0) (
    input  logic [7:0][199:0] data_i,
    input  logic [3:0][7:0] enable_i,
    output logic [3:0][199:0] data_o
);
    for (genvar s = 0; s < 4; s++) begin
        if (PackedRows) begin
            always_comb begin
                data_o[s] = '0;
                for (int p = 0; p < 8; p++)
                    data_o[s] |= {200{enable_i[s][p]}} & data_i[p];
            end
        end else begin
            for (genvar i = 0; i < 200; i++) begin
                logic [7:0] col;
                for (genvar p = 0; p < 8; p++)
                    assign col[p] = enable_i[s][p] && data_i[p][i];
                assign data_o[s][i] = |col;
            end
        end
    end
endmodule
