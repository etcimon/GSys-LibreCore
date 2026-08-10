// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai I1 PE slice: dense INT8 multi-lane MAC (dot product step).
//
//   acc_o = acc_i + sum_{lane=0..Lanes-1} (valid[lane] ? a[lane]*b[lane] : 0)
//
// Pure combinational; synthesizable. Lanes is the replication unit for the
// sequential GEMM engine (banked A/B tiles feed one product per lane/cycle).
// Timing: MAC tree depth ~Lanes; live I1 uses PeLanes=64 - pipeline later if
// critical path exceeds island timing budget.

module g6lc_ai_pe_dot #(
    parameter int unsigned Lanes = 4
) (
    input  logic signed [7:0]  a_i     [Lanes],
    input  logic signed [7:0]  b_i     [Lanes],
    input  logic               valid_i [Lanes],
    input  logic        [31:0] acc_i,
    output logic        [31:0] acc_o
);

  logic signed [31:0] prod   [Lanes];
  logic signed [31:0] partial[Lanes+1];

  for (genvar l = 0; l < int'(Lanes); l++) begin : gen_mul
    assign prod[l] = valid_i[l]
                   ? (32'($signed(a_i[l])) * 32'($signed(b_i[l])))
                   : 32'sd0;
  end

  assign partial[0] = $signed(acc_i);
  for (genvar l = 0; l < int'(Lanes); l++) begin : gen_sum
    assign partial[l+1] = partial[l] + prod[l];
  end
  assign acc_o = partial[Lanes];

endmodule
