// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Formal-only `fpnew_top` for the FP owner proof (g6lc_ooo_fp_owner.sby).
// read_slang does not honor `(* anyseq *)`, so freedom is taken from the
// already-free operand inputs (the solver steers them like anyseq sources):
//   operands_i[1][3:0]  — accept throttle (in_ready_o)
//   operands_i[0][3:0]  — return throttle (out_valid_o timing)
//   operands_i[2][0]    — corrupt return: emit a foreign tag even with an
//                         empty queue (a tag-faithful FPU never does this;
//                         keeping it makes the owner-live compare load-
//                         bearing so the mut_owner control fails)
//   operands_i[2][3:1]  — foreign tag value
//
// A small FIFO records accepted tags in order, so the stub is *also* a
// faithful producer: each submission can produce exactly one return, the
// S2-leaf scenario (cancel in flight -> stale return -> slot reuse) is
// reachable, and a spurious return carries either a queued tag or a foreign
// one — the worst case for the owner tables.
//
// Only ever read by the .sby file list; never in a production flist.

module fpnew_top #(
  parameter fpnew_pkg::fpu_features_t       Features       = fpnew_pkg::RV64D_Xsflt,
  parameter fpnew_pkg::fpu_implementation_t Implementation = fpnew_pkg::DEFAULT_NOREGS,
  parameter fpnew_pkg::divsqrt_unit_t       DivSqrtSel     = fpnew_pkg::THMULTI,
  parameter type                            TagType        = logic,
  parameter int unsigned                    TrueSIMDClass  = 0,
  parameter int unsigned                    EnableSIMDMask = 0,
  localparam int unsigned NumLanes     = fpnew_pkg::max_num_lanes(Features.Width, Features.FpFmtMask, Features.EnableVectors),
  localparam type         MaskType     = logic [NumLanes-1:0],
  localparam int unsigned WIDTH        = Features.Width,
  localparam int unsigned NUM_OPERANDS = 3
) (
  input logic                               clk_i,
  input logic                               rst_ni,
  input logic [NUM_OPERANDS-1:0][WIDTH-1:0] operands_i,
  input fpnew_pkg::roundmode_e              rnd_mode_i,
  input fpnew_pkg::operation_e              op_i,
  input logic                               op_mod_i,
  input fpnew_pkg::fp_format_e              src_fmt_i,
  input fpnew_pkg::fp_format_e              dst_fmt_i,
  input fpnew_pkg::int_format_e             int_fmt_i,
  input logic                               vectorial_op_i,
  input TagType                             tag_i,
  input MaskType                            simd_mask_i,
  input  logic                              in_valid_i,
  output logic                              in_ready_o,
  input  logic                              flush_i,
  output logic [WIDTH-1:0]                  result_o,
  output fpnew_pkg::status_t                status_o,
  output TagType                            tag_o,
  output logic                              out_valid_o,
  input  logic                              out_ready_i,
  output logic                              busy_o,
  output logic                              early_valid_o
);

  localparam int unsigned TAGW = $bits(TagType);

  // Accepted tags waiting to return (depth 4 is enough for the proof window;
  // overflow simply drops the entry — losing a return stays sound).
  TagType        pend_q [0:3];
  logic [2:0]    phead_q, pnum_q;
  wire           free_ready = ^operands_i[1][3:0];
  wire           free_fire  = ^operands_i[0][3:0];
  wire           free_xtra  = operands_i[2][0];   // emit without a queued tag
  wire [TAGW-1:0] free_tag  = operands_i[2][TAGW:1];
  wire           accept     = in_valid_i && in_ready_o;
  wire           consume    = out_valid_o && out_ready_i;
  wire [1:0]     tail       = (phead_q + pnum_q);

  assign in_ready_o    = free_ready;
  assign out_valid_o   = free_fire && (pnum_q != '0 || free_xtra);
  assign tag_o         = (pnum_q != '0) ? pend_q[phead_q[1:0]] : TagType'(free_tag);
  assign result_o      = WIDTH'(operands_i[0]);
  assign status_o      = fpnew_pkg::status_t'(operands_i[1][4:0]);
  assign busy_o        = |pnum_q;
  assign early_valid_o = free_fire && |pnum_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phead_q <= '0;
      pnum_q  <= '0;
      for (int i = 0; i < 4; i++) pend_q[i] <= TagType'(0);
    end else if (flush_i) begin
      phead_q <= '0;
      pnum_q  <= '0;
    end else begin
      if (consume) begin
        phead_q <= phead_q + 3'd1;
        pnum_q  <= pnum_q - 3'd1;
      end
      if (accept && (consume || pnum_q < 3'd4)) begin
        pend_q[tail] <= tag_i;
        if (!consume) pnum_q <= pnum_q + 3'd1;
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, rnd_mode_i, op_i, op_mod_i, src_fmt_i, dst_fmt_i,
                       int_fmt_i, vectorial_op_i, simd_mask_i};

endmodule
