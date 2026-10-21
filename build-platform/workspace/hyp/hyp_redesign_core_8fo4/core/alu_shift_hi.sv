// AluStages==2 shift operand: reverse, arithmetic sign, then places 32/16/8.
// Combo only, and only instantiated on that arm, so the places are not in
// alu's register-to-register cone. AluStages==3 does this from flops in alu.
module alu_shift_hi #(
    parameter int unsigned XLEN = 64
) (
    input  logic [XLEN-1:0] op_a_i,
    input  logic            shl_i,
    input  logic            arith_i,
    input  logic [2:0]      shamt_hi_i,
    output logic [XLEN:0]   shift_o,
    output logic [32:0]     shift32_o
);
  logic [XLEN-1:0] rev_a;
  logic [31:0]     rev32;
  logic [XLEN-1:0] sh_a;
  logic [31:0]     sh32;
  always_comb begin
    for (int k = 0; k < XLEN; k++) rev_a[k] = op_a_i[XLEN-1-k];
    for (int k = 0; k < 32; k++) rev32[k] = op_a_i[31-k];
    sh_a  = shl_i ? rev_a : op_a_i;
    sh32  = shl_i ? rev32 : op_a_i[31:0];
    shift_o = {arith_i & sh_a[XLEN-1], sh_a};
    if (shamt_hi_i[2]) shift_o = $unsigned($signed(shift_o) >>> 32);
    if (shamt_hi_i[1]) shift_o = $unsigned($signed(shift_o) >>> 16);
    if (shamt_hi_i[0]) shift_o = $unsigned($signed(shift_o) >>> 8);
    shift32_o = {arith_i & op_a_i[31], sh32};
    if (shamt_hi_i[1]) shift32_o = $unsigned($signed(shift32_o) >>> 16);
    if (shamt_hi_i[0]) shift32_o = $unsigned($signed(shift32_o) >>> 8);
  end
endmodule
