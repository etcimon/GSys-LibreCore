// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zabha subword AMO: extract byte/half from an aligned XLEN word, run the
// existing amo_alu, merge the result, sign-extend the old value to rd.
// size_i: 0=B, 1=H. Off-config is still the same merge (decode gates issue).

module g6lc_zabha (
    input  ariane_pkg::amo_t amo_op_i,
    input  logic [63:0]      mem_i,
    input  logic [63:0]      rs2_i,
    input  logic [2:0]       off_i,
    input  logic [1:0]       size_i,
    output logic [63:0]      mem_w_o,
    output logic [63:0]      rd_o
);

  logic sext;
  logic [63:0] a_ext, b_ext, alu_r, sh, mask, placed;
  logic [7:0]  b8;
  logic [15:0] h16;

  assign sext = (amo_op_i == ariane_pkg::AMO_MAX) || (amo_op_i == ariane_pkg::AMO_MIN);
  assign sh   = mem_i >> (8 * off_i);
  assign b8   = sh[7:0];
  assign h16  = sh[15:0];

  always_comb begin
    if (size_i == 2'b00) begin
      a_ext = sext ? {{56{b8[7]}}, b8} : {56'b0, b8};
      b_ext = sext ? {{56{rs2_i[7]}}, rs2_i[7:0]} : {56'b0, rs2_i[7:0]};
      mask  = 64'hFF << (8 * off_i);
      rd_o  = {{56{b8[7]}}, b8};
    end else begin
      a_ext = sext ? {{48{h16[15]}}, h16} : {48'b0, h16};
      b_ext = sext ? {{48{rs2_i[15]}}, rs2_i[15:0]} : {48'b0, rs2_i[15:0]};
      mask  = 64'hFFFF << (8 * off_i);
      rd_o  = {{48{h16[15]}}, h16};
    end
  end

  amo_alu #(
      .CVA6Cfg(config_pkg::cva6_cfg_empty)
  ) i_alu (
      .amo_op_i(amo_op_i),
      .amo_operand_a_i(a_ext),
      .amo_operand_b_i(b_ext),
      .amo_operand_c_i('0),
      .amo_result_o(alu_r)
  );

  assign placed  = alu_r << (8 * off_i);
  assign mem_w_o = (mem_i & ~mask) | (placed & mask);

endmodule
