# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""r24 large pass: exact operator narrowing on the worst non-GEMM modules."""
from pathlib import Path
D = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island')
E = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai')


def edit(path, pairs):
    s = path.read_text(encoding='utf-8')
    for old, new in pairs:
        assert s.count(old) == 1, (path.name, s.count(old), old[:60])
        s = s.replace(old, new)
    path.write_text(s, encoding='utf-8')


# 1. pe_dot: 8x8 products in a 16-bit context, sign-extended afterwards.
edit(D / 'g6lc_ai_pe_dot.sv', [
    ("""    automatic logic signed [7:0]  op_a, op_b;
    automatic logic signed [31:0] node [2*Lanes];""",
     """    automatic logic signed [7:0]  op_a, op_b;
    // r24: an 8x8 signed product fits 16 bits exactly; the context-determined
    // multiply then sign-extends, instead of a 32x32 multiplier per lane.
    automatic logic signed [15:0] prod_lo, prod_hi;
    automatic logic signed [31:0] node [2*Lanes];"""),
    ("""        op_a = $signed(a_i[l][3:0]);
        op_b = $signed(b_i[l][3:0]);
        node[2*l]   = valid_i[l] ? (32'($signed(op_a)) * 32'($signed(op_b))) : 32'sd0;
        op_a = $signed(a_i[l][7:4]);
        op_b = $signed(b_i[l][7:4]);
        node[2*l+1] = valid_i[l] ? (32'($signed(op_a)) * 32'($signed(op_b))) : 32'sd0;""",
     """        op_a = $signed(a_i[l][3:0]);
        op_b = $signed(b_i[l][3:0]);
        prod_lo = op_a * op_b;
        node[2*l]   = valid_i[l] ? 32'(prod_lo) : 32'sd0;
        op_a = $signed(a_i[l][7:4]);
        op_b = $signed(b_i[l][7:4]);
        prod_hi = op_a * op_b;
        node[2*l+1] = valid_i[l] ? 32'(prod_hi) : 32'sd0;"""),
    ("""        node[2*l]   = valid_i[l]
                    ? (32'($signed(a_i[l])) * 32'($signed(b_i[l])))
                    : 32'sd0;
        node[2*l+1] = 32'sd0;""",
     """        op_a = a_i[l];
        op_b = b_i[l];
        prod_lo = op_a * op_b;
        node[2*l]   = valid_i[l] ? 32'(prod_lo) : 32'sd0;
        node[2*l+1] = 32'sd0;"""),
])
# 2. codec: "at least six zero bytes" == "at most two nonzero bytes".
edit(D / 'g6lc_ai_policy_codec.sv', [
    ("""        features.sparse = sample_valid_i && policy_sparse_residue(sample_i);""",
     """        features.sparse = sample_valid_i && sparse_residue_c;"""),
    ("""    always_comb begin
      features = '0;
      if (accept) begin""",
     """    // r24: policy_sparse_residue(sample) is "six or more zero bytes", i.e.
    // at most two nonzero bytes: clear the lowest set bit twice.
    logic [7:0] nonzero_bytes, nonzero_m1, nonzero_m2;
    logic sparse_residue_c;
    always_comb for (int i = 0; i < 8; i++) nonzero_bytes[i] = |sample_i[i*8 +: 8];
    assign nonzero_m1 = nonzero_bytes & (nonzero_bytes - 8'd1);
    assign nonzero_m2 = nonzero_m1 & (nonzero_m1 - 8'd1);
    assign sparse_residue_c = nonzero_m2 == 8'd0;
    // pragma translate_off
    always @(posedge clk_i) if (rst_ni)
      assert (sparse_residue_c == policy_sparse_residue(sample_i))
        else $error("sparse residue identity");
    // pragma translate_on
    always_comb begin
      features = '0;
      if (accept) begin"""),
])
# 3. subcode: inputs_per_group is 2^r + 2^c, so the byte products are shift-adds.
edit(D / 'g6lc_ai_policy_subcode.sv', [
    ("""      full_bytes = 16'(inputs_per_group) * 16'(row_bytes(depth, fmt_q));
      tail_bytes = 16'(inputs_per_group) * 16'(row_bytes(tail, fmt_q));""",
     """      // r24: (2^r + 2^c) * bytes as two shifts and one add (mod 2^16, as the
      // 16-bit product truncates).
      full_bytes = (16'(row_bytes(depth, fmt_q)) << r) + (16'(row_bytes(depth, fmt_q)) << c);
      tail_bytes = (16'(row_bytes(tail, fmt_q)) << r) + (16'(row_bytes(tail, fmt_q)) << c);"""),
])
# 4. exec: the 16-bit scale is the multiplier's narrow operand.
edit(E / 'g6lc_ai_exec.sv', [
    ("""  assign rq_prod   = rq_aval_q * rq_sc_w;""",
     """  // r24: the scale is 16 bits; let the context extend it rather than
  // presenting a 48x48 multiply.
  assign rq_prod   = rq_aval_q * $signed(rq_sc);"""),
])
print('ok r24')
