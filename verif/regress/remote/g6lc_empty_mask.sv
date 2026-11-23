// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module g6lc_empty_mask (
    input logic [39:0] cand,
    input logic [39:0][39:0] columns,
    output logic [39:0] winner
);
    for (genvar i=0; i<40; ++i)
        assign winner[i] = cand[i] & ~|(cand & columns[i]);
endmodule
