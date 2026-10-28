// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Join completion and telemetry in either order. This only governs admission
// of the next telemetry owner; it never delays the engine's completion event.
module g6lc_ai_policy_publish #(
  parameter int unsigned Width = 128
) (
  input logic clk_i, rst_ni,
  input logic start_i, done_i, cancel_i, result_valid_i,
  input logic [Width-1:0] result_i,
  output logic ready_o,
  output logic [Width-1:0] snapshot_o
);
  logic active_q, done_q, result_q;
  logic [Width-1:0] held_q;
  logic publish;
  assign ready_o = !active_q && !cancel_i;
  assign publish = active_q && (done_q || done_i) && (result_q || result_valid_i);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q <= 1'b0; done_q <= 1'b0; result_q <= 1'b0;
    end else if (cancel_i) begin
      active_q <= 1'b0; done_q <= 1'b0; result_q <= 1'b0;
    end else if (start_i) begin
      active_q <= 1'b1; done_q <= 1'b0; result_q <= 1'b0;
    end else if (publish) begin
      active_q <= 1'b0; done_q <= 1'b0; result_q <= 1'b0;
    end else if (active_q) begin
      if (done_i) done_q <= 1'b1;
      if (result_valid_i) result_q <= 1'b1;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) held_q <= '0;
    else if (active_q && result_valid_i) held_q <= result_i;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) snapshot_o <= '0;
    else if (cancel_i) snapshot_o <= '0;
    else if (publish) snapshot_o <= result_valid_i ? result_i : held_q;
  end
  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni) start_i |-> ready_o);
  // pragma translate_on
endmodule
