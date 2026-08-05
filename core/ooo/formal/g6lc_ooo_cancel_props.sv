// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal scaffold: cancelled younger SB slots must not take
// architectural commit. Self-contained cancel→drop policy model.
//
// Run: sby -f core/ooo/formal/g6lc_ooo_cancel.sby
//      cva6-build verify --formal

module g6lc_ooo_cancel_props #(
    parameter int unsigned NR_SB     = 8,
    parameter int unsigned NR_COMMIT = 2,
    parameter int unsigned TID_W     = $clog2(NR_SB)
) (
    input logic                            clk_i,
    input logic                            rst_ni,
    input logic [NR_SB-1:0]                cancelled_next,
    input logic [NR_COMMIT-1:0]            commit_ack_i,
    input logic [NR_COMMIT-1:0][TID_W-1:0] commit_tid_i
);

`ifdef FORMAL
  logic [NR_SB-1:0] cancelled_mask_q;
  logic [NR_COMMIT-1:0] commit_drop_o;

  always_comb begin
    for (int unsigned c = 0; c < NR_COMMIT; c++) begin
      commit_drop_o[c] = commit_ack_i[c] && cancelled_mask_q[commit_tid_i[c]];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cancelled_mask_q <= '0;
    else         cancelled_mask_q <= cancelled_next;
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned c = 0; c < NR_COMMIT; c++) begin
        assume (commit_tid_i[c] < NR_SB[TID_W-1:0]);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned c = 0; c < NR_COMMIT; c++) begin
        if (commit_ack_i[c] && cancelled_mask_q[commit_tid_i[c]])
          assert (commit_drop_o[c]);
        if (commit_ack_i[c] && !cancelled_mask_q[commit_tid_i[c]])
          assert (!commit_drop_o[c]);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) cover (|cancelled_mask_q && |commit_drop_o);
  end
`endif

endmodule
