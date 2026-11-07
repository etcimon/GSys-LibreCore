// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Fixed, bounded compiler workload; not a functional device qualification.
module vlt_pgo_train (
  input logic clk_i,
  input logic rst_ni,
  input logic [3:0] index_i,
  input logic [31:0] data_i,
  output logic [31:0] data_o
);
  logic [31:0] bank [16] /* verilator split_var */;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < 16; i++) bank[i] <= '0;
    end else begin
      for (int i = 0; i < 16; i++)
        if (index_i == 4'(i)) bank[i] <= data_i ^ 32'(i);
    end
  end
  always_comb begin
    data_o = '0;
    for (int i = 0; i < 16; i++) data_o ^= bank[i] + 32'(i);
  end
endmodule
