// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-009A two-flop synchronizer for asynchronous slot inputs. This is the only
// new CDC path in Storamic; the dedicated module makes the boundary visible to
// CDC review and constraints. testmode_i selects a combinational passthrough
// so scan/ATPG can drive the state machines directly.
module g6lc_storamic_sync #(
  parameter int unsigned Width = 1,
  parameter logic [Width-1:0] ResetValue = '0
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input logic [Width-1:0] in_i,
  output logic [Width-1:0] out_o
);
  logic [Width-1:0] meta_q, sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      meta_q <= ResetValue;
      sync_q <= ResetValue;
    end else begin
      meta_q <= in_i;
      sync_q <= meta_q;
    end
  end

  assign out_o = testmode_i ? in_i : sync_q;
endmodule
