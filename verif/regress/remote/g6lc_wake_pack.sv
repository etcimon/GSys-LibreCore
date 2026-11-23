// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module g6lc_wake_pack (
    input logic [63:0] valid, veto,
    input logic allow_low,
    output logic [55:0] ready,
    output logic [15:0] swapped
);
    for (genvar k = 0; k < 56; ++k)
        assign ready[k] = valid[k+2] && !(veto[k+5] && !allow_low);
    // Not a contiguous veto slice; a matcher must not change its order.
    for (genvar k = 0; k < 16; ++k)
        assign swapped[k] = valid[k] && !(veto[15-k] && !allow_low);
endmodule
