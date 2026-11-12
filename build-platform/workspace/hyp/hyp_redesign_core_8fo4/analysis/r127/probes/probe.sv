// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r127 instrument probes: one shape per module, registers at both ends, so the
// analyzer's reading of a candidate FORM is known before any RTL is touched.

// ---- A: orc.b (alu.sv L803/L808) ------------------------------------------
module p_a1_orcb_concat (input logic clk_i, input logic [63:0] a_i, output logic [63:0] y_o);
  logic [63:0] a_q, y_d; logic [31:0] lo;
  always_ff @(posedge clk_i) begin a_q <= a_i; y_o <= y_d; end
  assign lo  = { {8{|a_q[31:24]}}, {8{|a_q[23:16]}}, {8{|a_q[15:8]}}, {8{|a_q[7:0]}} };
  assign y_d = { {8{|a_q[63:56]}}, {8{|a_q[55:48]}}, {8{|a_q[47:40]}}, {8{|a_q[39:32]}}, lo };
endmodule
module p_a2_orcb_bytes (input logic clk_i, input logic [63:0] a_i, output logic [63:0] y_o);
  logic [63:0] a_q, y_d;
  always_ff @(posedge clk_i) begin a_q <= a_i; y_o <= y_d; end
  for (genvar b = 0; b < 8; b++) begin : gen_b
    logic any;
    assign any = |a_q[8*b +: 8];
    assign y_d[8*b +: 8] = {8{any}};
  end
endmodule

// ---- B: nested wide guards (csr_regfile dpc_d L3746-3775) ------------------
module p_b1_nested (input logic clk_i, input logic [63:0] pc_i, tgt_i, tvec_i, epc_i, pc4_i,
                    input logic g_trap_i, g_step_i, g_cf_i, g_ex_i, g_eret_i, output logic [63:0] x_o);
  logic [63:0] pc, tgt, tvec, epc, pc4, x_q, x_d; logic g_trap, g_step, g_cf, g_ex, g_eret;
  always_ff @(posedge clk_i) begin
    pc <= pc_i; tgt <= tgt_i; tvec <= tvec_i; epc <= epc_i; pc4 <= pc4_i;
    g_trap <= g_trap_i; g_step <= g_step_i; g_cf <= g_cf_i; g_ex <= g_ex_i; g_eret <= g_eret_i;
    x_q <= x_d;
  end
  assign x_o = x_q;
  always_comb begin
    x_d = x_q;
    if (g_trap) x_d = pc;
    if (g_step) begin
      if (g_cf) x_d = tgt;
      else if (g_ex) x_d = tvec;
      else if (g_eret) x_d = epc;
      else x_d = pc4;
    end
  end
endmodule
module p_b2_flat_onehot (input logic clk_i, input logic [63:0] pc_i, tgt_i, tvec_i, epc_i, pc4_i,
                    input logic g_trap_i, g_step_i, g_cf_i, g_ex_i, g_eret_i, output logic [63:0] x_o);
  logic [63:0] pc, tgt, tvec, epc, pc4, x_q, x_d; logic g_trap, g_step, g_cf, g_ex, g_eret;
  always_ff @(posedge clk_i) begin
    pc <= pc_i; tgt <= tgt_i; tvec <= tvec_i; epc <= epc_i; pc4 <= pc4_i;
    g_trap <= g_trap_i; g_step <= g_step_i; g_cf <= g_cf_i; g_ex <= g_ex_i; g_eret <= g_eret_i;
    x_q <= x_d;
  end
  assign x_o = x_q;
  logic s_hold, s_pc, s_tgt, s_tvec, s_epc, s_pc4;
  assign s_tgt  = g_step && g_cf;
  assign s_tvec = g_step && !g_cf && g_ex;
  assign s_epc  = g_step && !g_cf && !g_ex && g_eret;
  assign s_pc4  = g_step && !g_cf && !g_ex && !g_eret;
  assign s_pc   = !g_step && g_trap;
  assign s_hold = !g_step && !g_trap;
  assign x_d = ({64{s_hold}} & x_q) | ({64{s_pc}} & pc) | ({64{s_tgt}} & tgt) |
               ({64{s_tvec}} & tvec) | ({64{s_epc}} & epc) | ({64{s_pc4}} & pc4);
endmodule
module p_b3_flat_regsel (input logic clk_i, input logic [63:0] pc_i, tgt_i, tvec_i, epc_i, pc4_i,
                    input logic [5:0] s_i, output logic [63:0] x_o);
  logic [63:0] pc, tgt, tvec, epc, pc4, x_q, x_d; logic [5:0] s_q;
  always_ff @(posedge clk_i) begin
    pc <= pc_i; tgt <= tgt_i; tvec <= tvec_i; epc <= epc_i; pc4 <= pc4_i; s_q <= s_i; x_q <= x_d;
  end
  assign x_o = x_q;
  assign x_d = ({64{s_q[0]}} & x_q) | ({64{s_q[1]}} & pc) | ({64{s_q[2]}} & tgt) |
               ({64{s_q[3]}} & tvec) | ({64{s_q[4]}} & epc) | ({64{s_q[5]}} & pc4);
endmodule
module p_b4_sliced_regsel (input logic clk_i, input logic [63:0] pc_i, tgt_i, tvec_i, epc_i, pc4_i,
                    input logic [5:0] s_i, output logic [63:0] x_o);
  logic [63:0] pc, tgt, tvec, epc, pc4, x_q, x_d; logic [7:0][5:0] s_q;
  always_ff @(posedge clk_i) begin
    pc <= pc_i; tgt <= tgt_i; tvec <= tvec_i; epc <= epc_i; pc4 <= pc4_i; x_q <= x_d;
    for (int b = 0; b < 8; b++) s_q[b] <= s_i;
  end
  assign x_o = x_q;
  for (genvar b = 0; b < 8; b++) begin : gen_b
    assign x_d[8*b +: 8] = ({8{s_q[b][0]}} & x_q[8*b +: 8]) | ({8{s_q[b][1]}} & pc[8*b +: 8]) |
                           ({8{s_q[b][2]}} & tgt[8*b +: 8]) | ({8{s_q[b][3]}} & tvec[8*b +: 8]) |
                           ({8{s_q[b][4]}} & epc[8*b +: 8]) | ({8{s_q[b][5]}} & pc4[8*b +: 8]);
  end
endmodule
module p_b5_mux2_comb_sel (input logic clk_i, input logic [63:0] a_i, b_i, input logic [3:0] k_i, output logic [63:0] x_o);
  logic [63:0] a, b, x_d; logic [3:0] k;
  always_ff @(posedge clk_i) begin a <= a_i; b <= b_i; k <= k_i; x_o <= x_d; end
  logic s;
  assign s = (k == 4'd9);
  assign x_d = s ? a : b;
endmodule

// ---- C: free-list pick (g6lc_rename_read L115-154, L220, L285) --------------
module p_c1_pick_cur #(parameter int unsigned N = 72, parameter int unsigned W = 7)
   (input logic clk_i, input logic [N-1:0] free_i, output logic [W-1:0] tag_o, output logic ok_o);
  logic [N-1:0] free_q, lone; logic [W-1:0] tag_d; logic ok_d;
  always_ff @(posedge clk_i) begin free_q <= free_i; tag_o <= tag_d; ok_o <= ok_d; end
  function automatic logic [N-1:0] lowest_set(input logic [N-1:0] x);
    logic [N-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < N; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction
  function automatic logic [N-1:0] pick_free_mask(input logic [N-1:0] fr, input logic high);
    logic [N-1:0] cand, ordered, lowest, reversed, reversed_lowest;
    cand = fr & ~N'(1);
    reversed = {<<{cand}};
    ordered = high ? reversed : cand;
    lowest = lowest_set(ordered);
    reversed_lowest = {<<{lowest}};
    return high ? reversed_lowest : lowest;
  endfunction
  function automatic logic [W-1:0] mask_to_tag(input logic [N-1:0] m);
    mask_to_tag = '0;
    for (int unsigned i = 0; i < N; i++) if (m[i]) mask_to_tag = mask_to_tag | W'(i);
  endfunction
  assign lone  = pick_free_mask(free_q, 1'b0);
  assign ok_d  = |lone;
  assign tag_d = ok_d ? mask_to_tag(lone) : '0;
endmodule
module p_c2_pick_low_only #(parameter int unsigned N = 72, parameter int unsigned W = 7)
   (input logic clk_i, input logic [N-1:0] free_i, output logic [W-1:0] tag_o, output logic ok_o);
  logic [N-1:0] free_q, lone, cand; logic [W-1:0] tag_d; logic ok_d;
  always_ff @(posedge clk_i) begin free_q <= free_i; tag_o <= tag_d; ok_o <= ok_d; end
  function automatic logic [N-1:0] lowest_set(input logic [N-1:0] x);
    logic [N-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < N; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction
  function automatic logic [W-1:0] mask_to_tag(input logic [N-1:0] m);
    mask_to_tag = '0;
    for (int unsigned i = 0; i < N; i++) if (m[i]) mask_to_tag = mask_to_tag | W'(i);
  endfunction
  assign cand  = free_q & ~N'(1);
  assign lone  = lowest_set(cand);
  assign ok_d  = |lone;
  assign tag_d = ok_d ? mask_to_tag(lone) : '0;
endmodule
// 9 groups x 8 bits: group-any, per-group 8-bit isolate, 9-bit group isolate,
// tag = {group index, in-group index} formed by small one-hot OR encodes.
module p_c3_pick_groups (input logic clk_i, input logic [71:0] free_i, output logic [6:0] tag_o, output logic ok_o);
  logic [71:0] free_q, cand; logic [6:0] tag_d; logic ok_d;
  always_ff @(posedge clk_i) begin free_q <= free_i; tag_o <= tag_d; ok_o <= ok_d; end
  assign cand = free_q & ~72'(1);
  logic [8:0] gany, gpick; logic [8:0][7:0] lsel; logic [8:0][2:0] lidx;
  for (genvar g = 0; g < 9; g++) begin : gen_g
    logic [7:0] x;
    assign x = cand[8*g +: 8];
    assign gany[g] = |x;
    for (genvar i = 0; i < 8; i++) begin : gen_i
      if (i == 0) begin : gen_z
        assign lsel[g][i] = x[0];
      end else begin : gen_n
        assign lsel[g][i] = x[i] & ~(|x[i-1:0]);
      end
    end
    assign lidx[g][2] = lsel[g][7] | lsel[g][6] | lsel[g][5] | lsel[g][4];
    assign lidx[g][1] = lsel[g][7] | lsel[g][6] | lsel[g][3] | lsel[g][2];
    assign lidx[g][0] = lsel[g][7] | lsel[g][5] | lsel[g][3] | lsel[g][1];
  end
  for (genvar g = 0; g < 9; g++) begin : gen_gp
    if (g == 0) begin : gen_z
      assign gpick[g] = gany[0];
    end else begin : gen_n
      assign gpick[g] = gany[g] & ~(|gany[g-1:0]);
    end
  end
  logic [3:0] gidx; logic [2:0] lix;
  assign gidx[3] = gpick[8];
  assign gidx[2] = gpick[7] | gpick[6] | gpick[5] | gpick[4];
  assign gidx[1] = gpick[7] | gpick[6] | gpick[3] | gpick[2];
  assign gidx[0] = gpick[7] | gpick[5] | gpick[3] | gpick[1];
  always_comb begin
    lix = '0;
    for (int unsigned g = 0; g < 9; g++) lix |= {3{gpick[g]}} & lidx[g];
  end
  assign ok_d  = |gany;
  assign tag_d = {gidx, lix};
endmodule

// ---- D: small popcount under a genvar slice (id_stage L1508) ----------------
module p_d1_rank_slice (input logic clk_i, input logic [7:0] v_i, output logic [7:0][3:0] r_o);
  logic [7:0] v_q; logic [7:0][3:0] r_d;
  always_ff @(posedge clk_i) begin v_q <= v_i; r_o <= r_d; end
  assign r_d[0] = '0;
  for (genvar i = 1; i < 8; i++) begin : gen_r
    assign r_d[i] = 4'($countones(v_q[i-1:0]));
  end
endmodule
module p_d2_rank_masked (input logic clk_i, input logic [7:0] v_i, output logic [7:0][3:0] r_o);
  logic [7:0] v_q; logic [7:0][3:0] r_d;
  always_ff @(posedge clk_i) begin v_q <= v_i; r_o <= r_d; end
  for (genvar i = 0; i < 8; i++) begin : gen_r
    logic [7:0] m;
    assign m = v_q & 8'((8'd1 << i) - 8'd1);
    assign r_d[i] = 4'($countones(m));
  end
endmodule

// ---- E: lowest-set index by the countones trick (stb_fwd L347) --------------
module p_e1_ctz_countones (input logic clk_i, input logic [3:0] hi_i, input logic [1:0] p_i, output logic [1:0] w_o);
  logic [3:0] hi; logic [1:0] p, w_d;
  always_ff @(posedge clk_i) begin hi <= hi_i; p <= p_i; w_o <= w_d; end
  assign w_d = p + 2'($countones(hi - 4'(1)));
endmodule
module p_e2_ctz_encode (input logic clk_i, input logic [3:0] hi_i, input logic [1:0] p_i, output logic [1:0] w_o);
  logic [3:0] hi; logic [1:0] p, w_d, k;
  always_ff @(posedge clk_i) begin hi <= hi_i; p <= p_i; w_o <= w_d; end
  assign k = {hi[3] | hi[2], hi[3] | hi[1]};
  assign w_d = p + k;
endmodule

// ---- F: loop-buffer fill compare (g6lc_loop_buffer L209-221, L281) ----------
module p_f1_addr_eq_case (input logic clk_i, input logic [63:0] a_i, base_i, input logic [57:0] hip1_i,
                          input logic [2:0] ptr_i, output logic hit_o);
  logic [63:0] a, base_q; logic [57:0] base_hi_p1_q; logic [2:0] ptr_q; logic hit_d;
  always_ff @(posedge clk_i) begin a <= a_i; base_q <= base_i; base_hi_p1_q <= hip1_i; ptr_q <= ptr_i; hit_o <= hit_d; end
  logic [6:0] low_sum;
  assign low_sum = {1'b0, base_q[5:0]} + {1'b0, ptr_q[2:0], 3'b0};
  function automatic logic addr_eq(input logic [63:0] x, input logic [6:0] ls);
    logic hi_eq;
    unique case (ls[6])
      1'b1:    hi_eq = (x[63:6] == base_hi_p1_q);
      default: hi_eq = (x[63:6] == base_q[63:6]);
    endcase
    return (x[5:0] == ls[5:0]) && hi_eq;
  endfunction
  assign hit_d = addr_eq(a, low_sum);
endmodule
module p_f2_addr_eq_split (input logic clk_i, input logic [63:0] a_i, base_i, input logic [57:0] hip1_i,
                          input logic [2:0] ptr_i, output logic hit_o);
  logic [63:0] a, base_q; logic [57:0] base_hi_p1_q; logic [2:0] ptr_q; logic hit_d;
  always_ff @(posedge clk_i) begin a <= a_i; base_q <= base_i; base_hi_p1_q <= hip1_i; ptr_q <= ptr_i; hit_o <= hit_d; end
  logic [6:0] low_sum; logic hi_eq0, hi_eq1, lo_eq;
  assign low_sum = {1'b0, base_q[5:0]} + {1'b0, ptr_q[2:0], 3'b0};
  assign hi_eq0  = (a[63:6] == base_q[63:6]);
  assign hi_eq1  = (a[63:6] == base_hi_p1_q);
  assign lo_eq   = (a[5:0] == low_sum[5:0]);
  assign hit_d   = lo_eq && (low_sum[6] ? hi_eq1 : hi_eq0);
endmodule

// ---- G: 5-deep 1-bit priority chain (wt_axi_adapter L762-767) ---------------
module p_g1_prio_chain (input logic clk_i, input logic [4:0] r_i, output logic [4:0] g_o);
  logic [4:0] r, g_d;
  always_ff @(posedge clk_i) begin r <= r_i; g_o <= g_d; end
  logic g0, g1, g2, g3, g4;
  assign g0 = r[0];
  assign g1 = r[1] && !g0;
  assign g2 = r[2] && !g0 && !g1;
  assign g3 = r[3] && !g0 && !g1 && !g2;
  assign g4 = r[4] && !g3 && !g2 && !g1 && !g0;
  assign g_d = {g4, g3, g2, g1, g0};
endmodule
module p_g2_prio_flat (input logic clk_i, input logic [4:0] r_i, output logic [4:0] g_o);
  logic [4:0] r, g_d;
  always_ff @(posedge clk_i) begin r <= r_i; g_o <= g_d; end
  assign g_d[0] = r[0];
  assign g_d[1] = r[1] && !r[0];
  assign g_d[2] = r[2] && !(|r[1:0]);
  assign g_d[3] = r[3] && !(|r[2:0]);
  assign g_d[4] = r[4] && !(|r[3:0]);
endmodule

// ---- H: 72 x 64 register-file read (g6lc_prf L55-72) -------------------------
module p_h1_read_index (input logic clk_i, input logic [6:0] ra_i, input logic [71:0][63:0] m_i, output logic [63:0] d_o);
  logic [6:0] ra_q; logic [71:0][63:0] mem_q; logic [63:0] d_d;
  always_ff @(posedge clk_i) begin ra_q <= ra_i; mem_q <= m_i; d_o <= d_d; end
  assign d_d = mem_q[ra_q];
endmodule
module p_h2_read_onehot_q (input logic clk_i, input logic [71:0] rs_i, input logic [71:0][63:0] m_i, output logic [63:0] d_o);
  logic [71:0] rsel_q; logic [71:0][63:0] mem_q; logic [63:0] d_d;
  always_ff @(posedge clk_i) begin rsel_q <= rs_i; mem_q <= m_i; d_o <= d_d; end
  always_comb begin
    d_d = '0;
    for (int unsigned i = 0; i < 72; i++) d_d |= {64{rsel_q[i]}} & mem_q[i];
  end
endmodule
