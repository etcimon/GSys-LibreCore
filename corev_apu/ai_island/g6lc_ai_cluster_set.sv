// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// N copies of one cluster. Clusters=1 has no mux in front of the lane.
// g6lc_ai_island_top stays the single-engine elaboration and rejects N>1.
// Float codes use g6lc_ai_fp_dot. Integer codes use the INT8 MAC cell.
// Structured 2:4 is refused on every mask.

module g6lc_ai_cluster_set
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned CLUSTERS = 1,
    parameter logic [15:0] DTYPE_MASK = AiIslandDtypeMask,
    // See g6lc_ai_cluster_tile. Float products exist only in the sim model.
    parameter bit          FP_REAL_MODEL = 1'b0
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,
    input  logic [2:0]  fmt_i,
    input  logic [7:0]  cluster_i,
    input  logic [31:0] a0_i,
    input  logic [31:0] a1_i,
    input  logic [31:0] b0_i,
    input  logic [31:0] b1_i,
    output logic        done_o,
    output logic [15:0] status_o,
    output logic [31:0] c_o,
    output logic        wrote_o
);
  localparam logic [15:0] ST_OK      = 16'd0;
  localparam logic [15:0] ST_BAD_FMT = 16'd8;

  logic [31:0] c_lane [CLUSTERS];
  logic        wrote_lane [CLUSTERS];
  function automatic bit granted(input logic [2:0] fmt);
    if (fmt == 3'd2) return 1'b0;
    if (fmt > 3'd1 && !FP_REAL_MODEL) return 1'b0;
    return DTYPE_MASK[fmt];
  endfunction

  // Integer arm is shared. The float arm exists only in the sim generate,
  // so a default elaboration does not name g6lc_ai_fp_dot.
  if (FP_REAL_MODEL) begin : gen_fp_model
    g6lc_ai_fp_dot i_fp ();
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        done_o   <= 1'b0;
        status_o <= ST_OK;
        c_o      <= '0;
        wrote_o  <= 1'b0;
        for (int unsigned i = 0; i < CLUSTERS; i++) begin
          c_lane[i]     <= '0;
          wrote_lane[i] <= 1'b0;
        end
      end else begin
        done_o <= start_i;
        if (start_i) begin
          if (int'(cluster_i) >= CLUSTERS || !granted(fmt_i)) begin
            status_o <= ST_BAD_FMT;
            wrote_o  <= 1'b0;
            c_o      <= '0;
          end else if (fmt_i == 3'd0 || fmt_i == 3'd1) begin
            status_o <= ST_OK;
            wrote_o  <= 1'b1;
            c_lane[cluster_i] <= a0_i * b0_i + a1_i * b1_i;
            c_o <= a0_i * b0_i + a1_i * b1_i;
            wrote_lane[cluster_i] <= 1'b1;
          end else begin
            status_o <= ST_OK;
            wrote_o  <= 1'b1;
            c_lane[cluster_i] <= gen_fp_model.i_fp.dot2(32'(fmt_i), a0_i, a1_i, b0_i, b1_i);
            c_o <= gen_fp_model.i_fp.dot2(32'(fmt_i), a0_i, a1_i, b0_i, b1_i);
            wrote_lane[cluster_i] <= 1'b1;
          end
        end else begin
          wrote_o <= 1'b0;
        end
      end
    end
  end else begin : gen_int_only
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        done_o   <= 1'b0;
        status_o <= ST_OK;
        c_o      <= '0;
        wrote_o  <= 1'b0;
        for (int unsigned i = 0; i < CLUSTERS; i++) begin
          c_lane[i]     <= '0;
          wrote_lane[i] <= 1'b0;
        end
      end else begin
        done_o <= start_i;
        if (start_i) begin
          if (int'(cluster_i) >= CLUSTERS || !granted(fmt_i) || fmt_i > 3'd1) begin
            status_o <= ST_BAD_FMT;
            wrote_o  <= 1'b0;
            c_o      <= '0;
          end else begin
            // INT8 / INT4. INT4 nibbles are sign-extended by the caller.
            status_o <= ST_OK;
            wrote_o  <= 1'b1;
            c_lane[cluster_i] <= a0_i * b0_i + a1_i * b1_i;
            c_o <= a0_i * b0_i + a1_i * b1_i;
            wrote_lane[cluster_i] <= 1'b1;
          end
        end else begin
          wrote_o <= 1'b0;
        end
      end
    end
  end
endmodule
