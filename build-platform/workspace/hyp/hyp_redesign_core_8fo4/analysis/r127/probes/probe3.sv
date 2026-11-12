// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r127 instrument probes, third set: current shape vs candidate form, one cone each.

// ---- J: ring winner (stb_fwd L336-349): rotate / highest-set / count / add / read
module p_j1_ring_cur (input logic clk_i, input logic [7:0] c_i, z_i, input logic [2:0] p_i, output logic z_o);
  logic [7:0] cand, cboz, rot, above, hi; logic [2:0] ptr, win; logic z_d;
  always_ff @(posedge clk_i) begin cand <= c_i; cboz <= z_i; ptr <= p_i; z_o <= z_d; end
  for (genvar k = 0; k < 8; k++) begin : gen_rot
    assign rot[k] = cand[ptr + 3'(k)];
  end
  always_comb begin
    above = rot >> 1;
    for (int unsigned l = 1; l < 8; l = l << 1) above = above | (above >> l);
  end
  assign hi  = rot & ~above;
  assign win = ptr + 3'($countones(hi - 8'(1)));
  assign z_d = (|rot) && cboz[win];
endmodule
// slot order: youngest = highest ring offset from ptr = the highest candidate
// BELOW ptr if any, else the highest candidate at/above ptr; one-hot read.
module p_j2_ring_slot (input logic clk_i, input logic [7:0] c_i, z_i, input logic [7:0] m_i, output logic z_o);
  logic [7:0] cand, cboz, below_q, lo, hi, lo_ab, hi_ab, lo_w, hi_w, win_oh; logic z_d;
  // below_q[i] = (i < ptr): thermometer of the pointer, kept beside it
  always_ff @(posedge clk_i) begin cand <= c_i; cboz <= z_i; below_q <= m_i; z_o <= z_d; end
  assign lo = cand & below_q;
  assign hi = cand & ~below_q;
  always_comb begin
    lo_ab = lo >> 1; hi_ab = hi >> 1;
    for (int unsigned l = 1; l < 8; l = l << 1) begin
      lo_ab = lo_ab | (lo_ab >> l);
      hi_ab = hi_ab | (hi_ab >> l);
    end
  end
  assign lo_w   = lo & ~lo_ab;
  assign hi_w   = hi & ~hi_ab;
  assign win_oh = (|lo) ? lo_w : hi_w;
  assign z_d    = |(win_oh & cboz);
endmodule

// ---- K: load-buffer pop (load_unit L1578-1639, L486)
module p_k1_pop_index (input logic clk_i, input logic [2:0] r_i, p_i, d_i, input logic [2:0] a_i,
                       input logic [7:0] v_i, output logic [7:0] v_o);
  logic [2:0] ridx, pidx, didx, rindex; logic ex, pub, drn, a_ex, a_data, a_drn; logic [7:0] v_q, v_d;
  always_ff @(posedge clk_i) begin ridx <= r_i; pidx <= p_i; didx <= d_i; {ex, pub, drn} <= a_i; v_q <= v_i; v_o <= v_d; end
  assign a_ex   = ex;
  assign a_data = pub && !a_ex;
  assign a_drn  = drn && !a_ex && !a_data;
  assign rindex = ({3{a_ex}} & ridx) | ({3{a_data}} & pidx) | ({3{a_drn}} & didx);
  always_comb begin
    v_d = v_q;
    if (a_ex || a_data || a_drn) v_d[rindex] = 1'b0;
  end
endmodule
module p_k2_pop_onehot (input logic clk_i, input logic [7:0] r_i, p_i, d_i, input logic [2:0] a_i,
                        input logic [7:0] v_i, output logic [7:0] v_o);
  logic [7:0] r_oh, p_oh, d_oh, pop_oh; logic ex, pub, drn; logic [7:0] v_q, v_d;
  always_ff @(posedge clk_i) begin r_oh <= r_i; p_oh <= p_i; d_oh <= d_i; {ex, pub, drn} <= a_i; v_q <= v_i; v_o <= v_d; end
  assign pop_oh = ({8{ex}} & r_oh) | ({8{pub && !ex}} & p_oh) | ({8{drn && !ex && !pub}} & d_oh);
  assign v_d    = v_q & ~pop_oh;
endmodule

// ---- M: slot -> fifo placement (instr_queue L268-275)
module p_m1_place_add (input logic clk_i, input logic [1:0] idx_i, input logic [3:0] v_i, f_i, output logic ov_o);
  logic [1:0] idx_q; logic [3:0] valid, full, fifo_pos; logic ov_d; logic [3:0][1:0] slot_fifo;
  always_ff @(posedge clk_i) begin idx_q <= idx_i; valid <= v_i; full <= f_i; ov_o <= ov_d; end
  for (genvar s = 0; s < 4; s++) begin : gen_s
    logic [1:0] rank;
    if (s == 0) begin : gen_z
      assign rank = '0;
    end else begin : gen_n
      assign rank = 2'($countones(valid[s-1:0]));
    end
    assign slot_fifo[s] = (idx_q + rank) & 2'b11;
  end
  always_comb begin
    fifo_pos = '0;
    for (int unsigned s = 0; s < 4; s++) if (valid[s]) fifo_pos[slot_fifo[s]] = 1'b1;
  end
  assign ov_d = |(full & fifo_pos);
endmodule
// the pushed fifos are the `n` consecutive ones from the write pointer: a
// thermometer of the valid count, rotated by the one-hot pointer.
module p_m2_place_rot (input logic clk_i, input logic [3:0] idx_oh_i, input logic [3:0] v_i, f_i, output logic ov_o);
  logic [3:0] idx_oh_q, valid, full, therm, fifo_pos; logic ov_d;
  always_ff @(posedge clk_i) begin idx_oh_q <= idx_oh_i; valid <= v_i; full <= f_i; ov_o <= ov_d; end
  // count as thermometer: therm[k] = at least k+1 valid slots (slots are dense from 0)
  assign therm = valid;
  always_comb begin
    fifo_pos = '0;
    for (int unsigned r = 0; r < 4; r++)
      fifo_pos |= {4{idx_oh_q[r]}} & 4'((therm << r) | (therm >> (4 - r)));
  end
  assign ov_d = |(full & fifo_pos);
endmodule

// ---- N: store data placement (store_unit L598): function return vs per-byte one-hot AND-OR
module p_n1_fn_rotate (input logic clk_i, input logic [63:0] d_i, input logic [2:0] o_i, output logic [63:0] q_o);
  logic [63:0] d, q_d; logic [2:0] off;
  always_ff @(posedge clk_i) begin d <= d_i; off <= o_i; q_o <= q_d; end
  function automatic logic [7:0] byte_at(input logic [63:0] x, input logic [2:0] i);
    unique case (i)
      3'd0: return x[7:0];   3'd1: return x[15:8];  3'd2: return x[23:16]; 3'd3: return x[31:24];
      3'd4: return x[39:32]; 3'd5: return x[47:40]; 3'd6: return x[55:48]; default: return x[63:56];
    endcase
  endfunction
  function automatic logic [63:0] fused(input logic [63:0] x, input logic [2:0] o);
    return {byte_at(x, 3'd7 - o), byte_at(x, 3'd6 - o), byte_at(x, 3'd5 - o), byte_at(x, 3'd4 - o),
            byte_at(x, 3'd3 - o), byte_at(x, 3'd2 - o), byte_at(x, 3'd1 - o), byte_at(x, 3'd0 - o)};
  endfunction
  assign q_d = fused(d, off);
endmodule
module p_n2_onehot_bytes (input logic clk_i, input logic [63:0] d_i, input logic [2:0] o_i, output logic [63:0] q_o);
  logic [63:0] d, q_d; logic [2:0] off;
  always_ff @(posedge clk_i) begin d <= d_i; off <= o_i; q_o <= q_d; end
  for (genvar j = 0; j < 8; j++) begin : gen_j
    logic [7:0] sel;                       // one decode per output byte lane
    for (genvar s = 0; s < 8; s++) begin : gen_s
      assign sel[s] = (off == 3'((j - s) & 7));
    end
    always_comb begin
      q_d[8*j +: 8] = '0;
      for (int unsigned s = 0; s < 8; s++) q_d[8*j +: 8] |= {8{sel[s]}} & d[8*s +: 8];
    end
  end
endmodule

// ---- Q: privilege legality (g6lc_decode_s3 L161-289): recompute vs class x cached table
module p_q1_legal_chain (input logic clk_i, input logic [31:0] i_i, input logic [1:0] p_i, input logic [3:0] c_i, output logic ill_o);
  logic [31:0] instr; logic [1:0] priv; logic tsr, tvm, tw, exv; logic ill_d;
  always_ff @(posedge clk_i) begin instr <= i_i; priv <= p_i; {tsr, tvm, tw, exv} <= c_i; ill_o <= ill_d; end
  logic sys, c_sret, c_mret, c_wfi, c_sf, ill_a, ill_b;
  assign sys    = (instr[6:0] == 7'b1110011) && (instr[14:12] == 3'b000);
  assign c_sret = sys && (instr[31:20] == 12'h102);
  assign c_mret = sys && (instr[31:20] == 12'h302);
  assign c_wfi  = sys && (instr[31:20] == 12'h105);
  assign c_sf   = sys && (instr[31:25] == 7'b0001001);
  assign ill_a  = (c_sret && (priv == 2'b00)) | (c_sret && (priv == 2'b01) && tsr) | (c_mret && (priv != 2'b11)) |
                  (c_wfi && (priv == 2'b01) && tw) | (c_wfi && (priv == 2'b00));
  assign ill_b  = c_sf ? ((priv == 2'b00) || ((priv == 2'b01) && tvm)) : ill_a;
  assign ill_d  = exv ? 1'b0 : ill_b;
endmodule
module p_q2_legal_table (input logic clk_i, input logic [3:0] cls_i, input logic [3:0] tab_i, input logic exv_i, output logic ill_o);
  logic [3:0] cls_q, ill_tab_q; logic exv, ill_d;   // class one-hot from the earlier decode stage; table from the CSR side
  always_ff @(posedge clk_i) begin cls_q <= cls_i; ill_tab_q <= tab_i; exv <= exv_i; ill_o <= ill_d; end
  assign ill_d = !exv && (|(cls_q & ill_tab_q));
endmodule
