// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module g6lc_byte_plane (
    input logic [63:0] row,
    input logic [63:0] other,
    output logic [63:0] planes,
    output logic [7:0] reversed_plane,
    output logic [7:0] mixed_plane
);
    for (genvar p = 0; p < 8; ++p) begin
        assign planes[8*p +: 8] = {row[56+p], row[48+p], row[40+p], row[32+p],
                                    row[24+p], row[16+p], row[8+p], row[p]};
    end
    assign reversed_plane = {other[0], other[8], other[16], other[24],
                             other[32], other[40], other[48], other[56]};
    assign mixed_plane = {other[57], other[49], other[41], other[33],
                          row[25], other[17], other[9], other[1]};
endmodule
