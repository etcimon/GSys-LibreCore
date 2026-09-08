// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Verilator-compatible chained select after an indexed part-select
// (CVA6 core/alu.sv xperm8 shape). IEEE 1800 forbids this; the g6lc
// sv-parser fork accepts it.

module chained_select;
  logic [63:0] operand_a, operand_b;
  logic [7:0] xperm8_result;
  genvar i;
  for (i = 0; i < 8; i++) begin : g
    assign xperm8_result[i << 3 +: 8] =
        operand_a[{operand_b[i << 3 +: 8][3:0], 3'b0} +: 8];
  end
endmodule
