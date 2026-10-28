# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""r27: g6lc_ai_exec requant product as a carry-save shift-add across four
phases (four scale bits per phase, final carry-propagate phase) and dot4
products as explicit row trees."""
from pathlib import Path
p = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai/g6lc_ai_exec.sv')
s = p.read_text(encoding='utf-8')


def rep(old, new, count=1):
    global s
    assert s.count(old) == count, (s.count(old), old[:70])
    s = s.replace(old, new)


# dot4: explicit 8-row trees (A140), no Mul operator.
rep("""  for (genvar di = 0; di < 4; di++) begin : gen_dot4
    assign dot4_s_p[di] = 32'(signed'(dot4_a[di*8 +: 8]) * signed'(dot4_b[di*8 +: 8]));
    assign dot4_u_p[di] = 32'(dot4_a[di*8 +: 8] * dot4_b[di*8 +: 8]);
  end""", """  // r27: each byte product is eight conditional shifted rows summed in a
  // balanced tree (signed: operand a sign-extended, row 7 subtracted), so
  // no atomic multiplier sits on the result path. Exact in 16 bits.
  for (genvar di = 0; di < 4; di++) begin : gen_dot4
    logic [7:0] ba, bb;
    logic [15:0] sa_ext;
    logic [15:0] rs [8];
    logic [15:0] ru [8];
    logic [15:0] ps, pu;
    assign ba = dot4_a[di*8 +: 8];
    assign bb = dot4_b[di*8 +: 8];
    assign sa_ext = {{8{ba[7]}}, ba};
    for (genvar bi = 0; bi < 8; bi++) begin : gen_rows
      if (bi == 7) begin : gen_row_neg
        assign rs[bi] = bb[bi] ? -(sa_ext << bi) : 16'd0;
      end else begin : gen_row
        assign rs[bi] = bb[bi] ? (sa_ext << bi) : 16'd0;
      end
      assign ru[bi] = bb[bi] ? ({8'd0, ba} << bi) : 16'd0;
    end
    assign ps = ((rs[0] + rs[1]) + (rs[2] + rs[3])) + ((rs[4] + rs[5]) + (rs[6] + rs[7]));
    assign pu = ((ru[0] + ru[1]) + (ru[2] + ru[3])) + ((ru[4] + ru[5]) + (ru[6] + ru[7]));
    assign dot4_s_p[di] = 32'(signed'(ps));
    assign dot4_u_p[di] = {16'd0, pu};
    // pragma translate_off
    always_comb begin
      assert (ps == 16'(signed'(ba) * signed'(bb)) && pu == 16'(ba * bb))
        else $error("dot4 row tree identity");
    end
    // pragma translate_on
  end""")
# requant product: carry-save rows over phases 2..5, carry-propagate at 6.
rep("""  assign rq_prod   = rq_aval_q * rq_sc_w;""", """  // r27: the 48 x 16 product as four scale bits per phase in carry-save
  // form (phases 2..5; bit 15 of the two's-complement scale is subtracted
  // as its inverted row plus one), then one carry-propagate add in phase 6.
  // Modulo 2^48, identical to the truncated product.
  logic [47:0] rq_cs_sum_q, rq_cs_carry_q, rq_cs_sum_d, rq_cs_carry_d;
  logic [47:0] rq_row [4];
  always_comb begin
    logic [47:0] a, b, c, s1, c1, s2, c2, s3, c3;
    logic [3:0] bit_base;
    bit_base = {rq_ph_q[1:0] - 2'd2, 2'b00};
    for (int unsigned k = 0; k < 4; k++) begin
      logic [3:0] bit_idx;
      bit_idx = bit_base + 4'(k);
      rq_row[k] = rq_sc[bit_idx] ? (48'(rq_aval_q) << bit_idx) : 48'd0;
      if (bit_idx == 4'd15) rq_row[k] = rq_sc[15] ? ~(48'(rq_aval_q) << 15) : 48'd0;
    end
    // (sum, carry) + row0 + row1 + row2 + row3 (+1 for the subtracted row)
    a = rq_cs_sum_q; b = rq_cs_carry_q; c = rq_row[0];
    s1 = a ^ b ^ c; c1 = ((a & b) | (a & c) | (b & c)) << 1;
    a = s1; b = c1; c = rq_row[1];
    s2 = a ^ b ^ c; c2 = ((a & b) | (a & c) | (b & c)) << 1;
    a = s2; b = c2; c = rq_row[2];
    s3 = a ^ b ^ c; c3 = ((a & b) | (a & c) | (b & c)) << 1;
    a = s3; b = c3; c = rq_row[3] | ((rq_ph_q == 3'd5 && rq_sc[15]) ? 48'd1 : 48'd0);
    rq_cs_sum_d = a ^ b ^ c;
    rq_cs_carry_d = ((a & b) | (a & c) | (b & c)) << 1;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_cs_ff
    if (!rst_ni) begin rq_cs_sum_q <= '0; rq_cs_carry_q <= '0; end
    else if (state_q == ST_RQ && rq_ph_q == 3'd1) begin rq_cs_sum_q <= '0; rq_cs_carry_q <= '0; end
    else if (state_q == ST_RQ && rq_ph_q inside {3'd2, 3'd3, 3'd4, 3'd5}) begin
      rq_cs_sum_q <= rq_cs_sum_d; rq_cs_carry_q <= rq_cs_carry_d;
    end
  end
  assign rq_prod   = rq_cs_sum_q + rq_cs_carry_q;
  // pragma translate_off
  always @(posedge clk_i) if (rst_ni && state_q == ST_RQ && rq_ph_q == 3'd6)
    assert (rq_prod == 48'(rq_aval_q * rq_sc_w)) else $error("requant product identity");
  // pragma translate_on""")
rep("""  logic [1:0]         rq_ph_q;""", """  logic [2:0]         rq_ph_q;   // r27: 0 index, 1 extend, 2..5 rows, 6 product""")
rep("""    if (!rst_ni) rq_ph_q <= 2'd0;
    else if (state_q == ST_RQ) rq_ph_q <= (rq_ph_q == 2'd2) ? 2'd0 : rq_ph_q + 2'd1;
    else rq_ph_q <= 2'd0;""", """    if (!rst_ni) rq_ph_q <= 3'd0;
    else if (state_q == ST_RQ) rq_ph_q <= (rq_ph_q == 3'd6) ? 3'd0 : rq_ph_q + 3'd1;
    else rq_ph_q <= 3'd0;""")
rep("""    else if (state_q == ST_RQ && rq_ph_q == 2'd0) rq_c_q <= rq_ok ? rq_c_wide : 16'd0;""",
    """    else if (state_q == ST_RQ && rq_ph_q == 3'd0) rq_c_q <= rq_ok ? rq_c_wide : 16'd0;""")
rep("""    else if (state_q == ST_RQ && rq_ph_q == 2'd1) rq_aval_q <= rq_aval_w;""",
    """    else if (state_q == ST_RQ && rq_ph_q == 3'd1) rq_aval_q <= rq_aval_w;""")
rep("""    else if (state_q == ST_RQ && rq_ph_q == 2'd2) rq_prod_q <= rq_prod;""",
    """    else if (state_q == ST_RQ && rq_ph_q == 3'd6) rq_prod_q <= rq_prod;""")
rep("""    else if (state_q == ST_RQ && rq_ph_q == 2'd2) rq_neg_q <= rq_prod[47];""",
    """    else if (state_q == ST_RQ && rq_ph_q == 3'd6) rq_neg_q <= rq_prod[47];""")
rep("""    else if (state_q == ST_RQ && rq_ph_q == 2'd2) rq_sh0_q <= (rq_sh == 4'd0);""",
    """    else if (state_q == ST_RQ && rq_ph_q == 3'd6) rq_sh0_q <= (rq_sh == 4'd0);""")
rep("""        state_d = (rq_ph_q == 2'd2) ? ST_RQ_S : ST_RQ;""",
    """        state_d = (rq_ph_q == 3'd6) ? ST_RQ_S : ST_RQ;""")
assert "2'd2" not in s.split("rq_ph_q")[1][:0]  # no-op guard
p.write_text(s, encoding='utf-8')
print('ok r27', s.count("rq_ph_q == 2'd"))
