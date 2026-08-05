// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U4 Register Map Table — dependency *bypass* tracker between A/B queues.
// Not a renamer: tracks which arch reg is produced by an in-flight instruction
// so the sibling queue can wait. Dual combinational query ports for A/B heads.
// Cleared on flush / complete.

module g6lc_slice_rmt
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input  logic                             clk_i,
    input  logic                             rst_ni,
    input  logic                             flush_i,
    // Producer allocate (dispatch into an IQ)
    input  logic                             alloc_i,
    input  logic [4:0]                       alloc_rd_i,
    input  logic                             alloc_rd_is_fp_i,
    input  logic                             alloc_from_a_i,  // 1 = A-IQ producer
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] alloc_id_i,
    // Producer complete (result available)
    input  logic                             complete_i,
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] complete_id_i,
    // Query port A (A-IQ head)
    input  logic [4:0]                       a_rs1_i,
    input  logic                             a_rs1_is_fp_i,
    input  logic [4:0]                       a_rs2_i,
    input  logic                             a_rs2_is_fp_i,
    output logic                             a_rs1_ready_o,
    output logic                             a_rs2_ready_o,
    // Query port B (B-IQ head)
    input  logic [4:0]                       b_rs1_i,
    input  logic                             b_rs1_is_fp_i,
    input  logic [4:0]                       b_rs2_i,
    input  logic                             b_rs2_is_fp_i,
    output logic                             b_rs1_ready_o,
    output logic                             b_rs2_ready_o
);

  typedef struct packed {
    logic                             pending;
    logic                             from_a;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] id;
  } slot_t;

  slot_t [31:0] gpr_q, gpr_d;
  slot_t [31:0] fpr_q, fpr_d;

  function automatic logic src_ready(
      input logic [4:0] rs,
      input logic is_fp,
      input slot_t [31:0] gpr,
      input slot_t [31:0] fpr
  );
    if (rs == 5'd0 && !is_fp) return 1'b1;
    if (is_fp && CVA6Cfg.FpPresent) return !fpr[rs].pending;
    return !gpr[rs].pending;
  endfunction

  assign a_rs1_ready_o = src_ready(a_rs1_i, a_rs1_is_fp_i, gpr_q, fpr_q);
  assign a_rs2_ready_o = src_ready(a_rs2_i, a_rs2_is_fp_i, gpr_q, fpr_q);
  assign b_rs1_ready_o = src_ready(b_rs1_i, b_rs1_is_fp_i, gpr_q, fpr_q);
  assign b_rs2_ready_o = src_ready(b_rs2_i, b_rs2_is_fp_i, gpr_q, fpr_q);

  always_comb begin
    gpr_d = gpr_q;
    fpr_d = fpr_q;

    if (flush_i) begin
      gpr_d = '0;
      fpr_d = '0;
    end else begin
      if (complete_i) begin
        for (int unsigned i = 0; i < 32; i++) begin
          if (gpr_d[i].pending && gpr_d[i].id == complete_id_i) gpr_d[i].pending = 1'b0;
          if (CVA6Cfg.FpPresent && fpr_d[i].pending && fpr_d[i].id == complete_id_i)
            fpr_d[i].pending = 1'b0;
        end
      end
      if (alloc_i && (alloc_rd_i != 5'd0 || alloc_rd_is_fp_i)) begin
        if (alloc_rd_is_fp_i && CVA6Cfg.FpPresent) begin
          fpr_d[alloc_rd_i].pending = 1'b1;
          fpr_d[alloc_rd_i].from_a  = alloc_from_a_i;
          fpr_d[alloc_rd_i].id      = alloc_id_i;
        end else if (!alloc_rd_is_fp_i && alloc_rd_i != 5'd0) begin
          gpr_d[alloc_rd_i].pending = 1'b1;
          gpr_d[alloc_rd_i].from_a  = alloc_from_a_i;
          gpr_d[alloc_rd_i].id      = alloc_id_i;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      gpr_q <= '0;
      fpr_q <= '0;
    end else begin
      gpr_q <= gpr_d;
      fpr_q <= fpr_d;
    end
  end

endmodule
