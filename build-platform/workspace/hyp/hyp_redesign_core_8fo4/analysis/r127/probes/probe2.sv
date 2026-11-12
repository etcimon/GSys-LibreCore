// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r127 instrument probes, second set: candidate FORMS for the wide-select class.

// B6: nested wide guards with COMBINATIONAL compound guards (the csr dpc_d shape).
module p_b6_nested_comb (input logic clk_i, input logic [63:0] pc_i, tgt_i, tvec_i, epc_i, pc4_i,
                         input logic [3:0] fu_i, input logic step_i, ack_i, ex_i, eret_i, trap_i, output logic [63:0] x_o);
  logic [63:0] pc, tgt, tvec, epc, pc4, x_q, x_d; logic [3:0] fu; logic step, ack, ex, eret, trap;
  always_ff @(posedge clk_i) begin
    pc <= pc_i; tgt <= tgt_i; tvec <= tvec_i; epc <= epc_i; pc4 <= pc4_i;
    fu <= fu_i; step <= step_i; ack <= ack_i; ex <= ex_i; eret <= eret_i; trap <= trap_i; x_q <= x_d;
  end
  assign x_o = x_q;
  always_comb begin
    x_d = x_q;
    if (trap && ex) x_d = pc;
    if (step && ack) begin
      if (fu == 4'd9) x_d = tgt;
      else if (ex) x_d = tvec;
      else if (eret) x_d = epc;
      else x_d = pc4;
    end
  end
endmodule
// B7: same function; one-hot selects formed once, then REPLICATED per byte slice
// (the predicate logic is duplicated, each copy drives 8 bits).
module p_b7_flat_sliced_comb (input logic clk_i, input logic [63:0] pc_i, tgt_i, tvec_i, epc_i, pc4_i,
                         input logic [3:0] fu_i, input logic step_i, ack_i, ex_i, eret_i, trap_i, output logic [63:0] x_o);
  logic [63:0] pc, tgt, tvec, epc, pc4, x_q, x_d; logic [3:0] fu; logic step, ack, ex, eret, trap;
  always_ff @(posedge clk_i) begin
    pc <= pc_i; tgt <= tgt_i; tvec <= tvec_i; epc <= epc_i; pc4 <= pc4_i;
    fu <= fu_i; step <= step_i; ack <= ack_i; ex <= ex_i; eret <= eret_i; trap <= trap_i; x_q <= x_d;
  end
  assign x_o = x_q;
  for (genvar b = 0; b < 8; b++) begin : gen_b
    logic st, cf, s_tgt, s_tvec, s_epc, s_pc4, s_pc, s_hold;
    assign st     = step && ack;
    assign cf     = (fu == 4'd9);
    assign s_tgt  = st && cf;
    assign s_tvec = st && !cf && ex;
    assign s_epc  = st && !cf && !ex && eret;
    assign s_pc4  = st && !cf && !ex && !eret;
    assign s_pc   = !st && trap && ex;
    assign s_hold = !st && !(trap && ex);
    assign x_d[8*b +: 8] = ({8{s_hold}} & x_q[8*b +: 8]) | ({8{s_pc}} & pc[8*b +: 8]) |
                           ({8{s_tgt}} & tgt[8*b +: 8]) | ({8{s_tvec}} & tvec[8*b +: 8]) |
                           ({8{s_epc}} & epc[8*b +: 8]) | ({8{s_pc4}} & pc4[8*b +: 8]);
  end
endmodule
// B8: 2:1 wide mux, comb compare select replicated per byte slice.
module p_b8_mux2_sliced (input logic clk_i, input logic [63:0] a_i, b_i, input logic [3:0] k_i, output logic [63:0] x_o);
  logic [63:0] a, b, x_d; logic [3:0] k;
  always_ff @(posedge clk_i) begin a <= a_i; b <= b_i; k <= k_i; x_o <= x_d; end
  for (genvar s = 0; s < 8; s++) begin : gen_s
    logic sel;
    assign sel = (k == 4'd9);
    assign x_d[8*s +: 8] = sel ? a[8*s +: 8] : b[8*s +: 8];
  end
endmodule

// H3: register-file read with the bypass-vs-array select PREDECODED into a flop.
module p_h3_read_predecoded (input logic clk_i, input logic [6:0] ra_i, wa_i, input logic we_i,
                             input logic [63:0] wd_i, input logic [71:0][63:0] m_i, output logic [63:0] d_o);
  logic [6:0] ra_q; logic [63:0] wd_q; logic [71:0][63:0] mem_q; logic [63:0] d_d; logic byp_q;
  always_ff @(posedge clk_i) begin
    ra_q <= ra_i; wd_q <= wd_i; mem_q <= m_i; d_o <= d_d;
    byp_q <= we_i && (wa_i == ra_i);
  end
  assign d_d = byp_q ? wd_q : mem_q[ra_q];
endmodule
// H4: the current shape: compare on the registered record, then the wide select.
module p_h4_read_late_cmp (input logic clk_i, input logic [6:0] ra_i, wa_i, input logic we_i,
                             input logic [63:0] wd_i, input logic [71:0][63:0] m_i, output logic [63:0] d_o);
  logic [6:0] ra_q, wa_q; logic we_q; logic [63:0] wd_q; logic [71:0][63:0] mem_q; logic [63:0] d_d; logic hit;
  always_ff @(posedge clk_i) begin
    ra_q <= ra_i; wa_q <= wa_i; we_q <= we_i; wd_q <= wd_i; mem_q <= m_i; d_o <= d_d;
  end
  assign hit = we_q && (wa_q == ra_q);
  always_comb begin
    d_d = '0;
    d_d |= {64{hit}} & wd_q;
    if (!hit) d_d = mem_q[ra_q];
  end
endmodule

// F3/F4: an address-compare predicate enabling a wide array write (loop buffer fill).
module p_f3_enable_wide (input logic clk_i, input logic [63:0] a_i, base_i, input logic [2:0] ptr_i,
                         input logic [31:0] d_i, output logic [7:0][31:0] q_o, output logic [2:0] p_o);
  logic [63:0] a, base_q; logic [2:0] ptr_q, ptr_d; logic [31:0] d; logic [7:0][31:0] data_q, data_d; logic acc;
  always_ff @(posedge clk_i) begin a <= a_i; base_q <= base_i; ptr_q <= ptr_d; d <= d_i; data_q <= data_d; end
  assign q_o = data_q; assign p_o = ptr_q;
  assign acc = (a[63:6] == base_q[63:6]) && (a[5:3] == ptr_q);
  always_comb begin
    data_d = data_q; ptr_d = ptr_q;
    if (acc) begin data_d[ptr_q] = d; ptr_d = ptr_q + 3'd1; end
  end
endmodule
module p_f4_write_uncond (input logic clk_i, input logic [63:0] a_i, base_i, input logic [2:0] ptr_i,
                         input logic v_i, input logic [31:0] d_i, output logic [7:0][31:0] q_o, output logic [2:0] p_o);
  logic [63:0] a, base_q; logic [2:0] ptr_q, ptr_d; logic [31:0] d; logic v; logic [7:0][31:0] data_q, data_d; logic acc;
  always_ff @(posedge clk_i) begin a <= a_i; base_q <= base_i; ptr_q <= ptr_d; d <= d_i; v <= v_i; data_q <= data_d; end
  assign q_o = data_q; assign p_o = ptr_q;
  assign acc = (a[63:6] == base_q[63:6]) && (a[5:3] == ptr_q);
  always_comb begin
    data_d = data_q; ptr_d = ptr_q;
    if (v) data_d[ptr_q] = d;          // slot is not counted until the pointer advances
    if (acc) ptr_d = ptr_q + 3'd1;
  end
endmodule
