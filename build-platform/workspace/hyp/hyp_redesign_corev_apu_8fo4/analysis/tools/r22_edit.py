# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""r22 interleaved two-set accumulator edits for g6lc_ai_gemm_seq.sv (one-shot)."""
from pathlib import Path
p = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_gemm_seq.sv')
s = p.read_text(encoding='utf-8')


def rep(old, new, count=1):
    global s
    assert s.count(old) == count, (s.count(old), old[:80])
    s = s.replace(old, new)


rep("""  logic [31:0] mac_seed;
  logic [31:0] mac_seed_q;
  logic seed_capture, issue_now, issue_sum_now;""", """  logic [31:0] mac_seed_q [2];
  logic seed_capture, seed_set, issue_now, issue_sum_now;""")
rep("""  assign seed_i = dot_pipe_en ? dot_i_out : i_q;
  assign seed_j = dot_pipe_en ? dot_j_out : j_q;""", """  assign seed_i = dot_pipe_en ? dot_i_out : i_q;
  assign seed_j = dot_pipe_en ? dot_j_out : j_issue;
  assign seed_set = dot_pipe_en ? dot_ph_out : ph_q;""")
rep("""  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mac_seed_q <= '0;
    else if (seed_capture) mac_seed_q <= c_r0_data;
  end
  assign mac_seed          = acc_mode_q ? mac_seed_q : 32'd0;""", """  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin mac_seed_q[0] <= '0; mac_seed_q[1] <= '0; end
    else if (seed_capture) mac_seed_q[seed_set] <= c_r0_data;
  end""")
rep("""  g6lc_ai_gemm_fp32_add i_seed_add (
    .a_i(mac_seed), .b_i(sum_q[0]), .result_o(mac_fp32_seed_add)
  );
  for (genvar g = 0; g < OutCols; g++) begin : gen_accumulate_column
    logic [31:0] int_base, int_next, float_next;
    g6lc_ai_gemm_fp32_add i_acc_add (
      .a_i(acc_q[g]), .b_i(sum_q[g]), .result_o(mac_fp32_add[g])
    );
    assign int_base = sum_first_q ? ((g == 0) ? mac_seed : 32'd0) : acc_q[g];
    assign int_next = int_base + sum_q[g];
    assign float_next = sum_first_q ?
        ((acc_mode_q && g == 0) ? mac_fp32_seed_add[31:0] : sum_q[g]) :
        mac_fp32_add[g][31:0];
    assign mac_acc_next[g] = pe_float_en ? float_next : int_next;
  end""", """  // Stage 1 (sum_q valid): the base is the set's accumulator, or on the first
  // partial the seed (accumulate mode, column 0) or zero. The adders register
  // their aligned operands; the integer sum and the raw first partial (which
  // the reference publishes unadded) are registered beside them.
  // Stage 2 (s1_v_q): the normalized result updates the set's accumulator.
  for (genvar g = 0; g < OutCols; g++) begin : gen_accumulate_column
    logic [31:0] base, fp_result_bits;
    logic seed_case;
    assign seed_case = acc_mode_q && g == 0;
    assign base = sum_first_q ? (seed_case ? mac_seed_q[sum_ph_q] : 32'd0)
                              : acc_q[sum_ph_q][g];
    g6lc_ai_gemm_fp32_add_p2 i_acc_add (
      .clk_i, .rst_ni, .en_i(sum_v_q),
      .a_i(base), .b_i(sum_q[g]), .result_o(mac_fp32_add[g])
    );
    assign fp_result_bits = mac_fp32_add[g][31:0];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        s1_int_q[g] <= '0; s1_raw_q[g] <= '0; s1_bypass_q[g] <= 1'b0;
      end else if (sum_v_q) begin
        s1_int_q[g] <= base + sum_q[g];
        s1_raw_q[g] <= sum_q[g];
        s1_bypass_q[g] <= sum_first_q && !seed_case;
      end
    end
    assign mac_acc_next[g] = pe_float_en ? (s1_bypass_q[g] ? s1_raw_q[g] : fp_result_bits)
                                         : s1_int_q[g];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_v_q <= 1'b0; s1_ph_q <= 1'b0; s1_last_q <= 1'b0;
      s1_i_q <= '0; s1_j_q <= '0; s1_cv_q <= '0;
    end else begin
      s1_v_q <= state_q == ST_MAC && sum_v_q;
      if (sum_v_q) begin
        s1_ph_q <= sum_ph_q; s1_last_q <= sum_last_q;
        s1_i_q <= sum_i_q; s1_j_q <= sum_j_q;
        for (int unsigned g = 0; g < OutCols; g++) s1_cv_q[g] <= sum_cv_q[g];
      end
    end
  end
  // pragma translate_off
  // A set's partials are at least two edges apart, so its stage-1 result
  // always lands before the next partial reads the accumulator.
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      sum_v_q && s1_v_q |-> sum_ph_q != s1_ph_q);
  // pragma translate_on""")
rep("""  logic [31:0] seed_i, seed_j;
  logic [36:0] mac_fp32_seed_add;""", """  logic [31:0] seed_i, seed_j;""")
rep("""  logic mac_state;
  assign mac_state = state_q == ST_MAC;
  for (genvar g = 0; g < OutCols; g++) begin : gen_accumulate_partial
    logic update;
    assign update = sum_v_q && sum_cv_q[g];
    assign acc_d[g] = {32{mac_state}} & (update ? mac_acc_next[g] : acc_q[g]);
  end""", """  logic mac_state;
  assign mac_state = state_q == ST_MAC;
  for (genvar st = 0; st < 2; st++) begin : gen_accumulate_set
    for (genvar g = 0; g < OutCols; g++) begin : gen_accumulate_partial
      logic update;
      assign update = s1_v_q && s1_cv_q[g] && s1_ph_q == st;
      assign acc_d[st][g] = {32{mac_state}} & (update ? mac_acc_next[g] : acc_q[st][g]);
    end
  end""")
rep("""      commit_v_q <= state_q == ST_MAC && sum_v_q && sum_last_q;
      if (sum_v_q && sum_last_q) begin
        commit_i_q <= sum_i_q; commit_j_q <= sum_j_q;
        for (int unsigned g = 0; g < OutCols; g++) commit_cv_q[g] <= sum_cv_q[g];
      end""", """      commit_v_q <= s1_v_q && s1_last_q;
      if (s1_v_q && s1_last_q) begin
        commit_i_q <= s1_i_q; commit_j_q <= s1_j_q; commit_ph_q <= s1_ph_q;
        commit_cv_q <= s1_cv_q;
      end""")
rep("""      commit_v_q <= 1'b0; commit_i_q <= '0; commit_j_q <= '0; commit_cv_q <= '0;""",
    """      commit_v_q <= 1'b0; commit_i_q <= '0; commit_j_q <= '0; commit_cv_q <= '0; commit_ph_q <= 1'b0;""")
rep("""            c_w_addr = c_bank_addr(commit_i_q, commit_j_q); c_w_data = acc_q[0];""",
    """            c_w_addr = c_bank_addr(commit_i_q, commit_j_q); c_w_data = acc_q[commit_ph_q][0];""")
rep("""            c_wx_data[g] = acc_q[g];""", """            c_wx_data[g] = acc_q[commit_ph_q][g];""")
rep("""        if (i_q >= m_q && stc_i_q >= m_q && !aw_sent_q && !sum_v_q &&
            !commit_v_q && dot_pending_q == '0) state_d = ST_DONE;""", """        if (i_q >= m_q && stc_i_q >= m_q && !aw_sent_q && !sum_v_q && !s1_v_q &&
            !commit_v_q && dot_pending_q == '0) state_d = ST_DONE;""")
rep("""       i_q >= m_q && dot_pending_q == '0 && !sum_v_q && !commit_v_q);""",
    """       i_q >= m_q && dot_pending_q == '0 && !sum_v_q && !s1_v_q && !commit_v_q);""")
rep("""  assign issue_now = state_q == ST_MAC && i_q < m_q;""", """  assign pair_present = j_pair_q < n_q;
  assign j_issue = ph_q ? j_pair_q : j_q;
  // Slot 1 issues only when a second column group exists; otherwise the slot
  // is a bubble that keeps the set's two-edge spacing.
  assign issue_now = state_q == ST_MAC && i_q < m_q && (!ph_q || pair_present);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin ph_q <= 1'b0; j_pair_q <= '0; end
    else begin
      ph_q <= (state_q == ST_MAC && i_q < m_q) ? !ph_q : 1'b0;
      j_pair_q <= j_q + cols_eff;
    end
  end""")
rep("""    dot_i_issue = {32{issue_now}} & i_q;
    dot_j_issue = {32{issue_now}} & j_q;""", """    dot_i_issue = {32{issue_now}} & i_q;
    dot_j_issue = {32{issue_now}} & j_issue;""")
rep("""    sum_i_d = {32{issue_sum_now}} & i_q;
    sum_j_d = {32{issue_sum_now}} & j_q;""", """    sum_i_d = {32{issue_sum_now}} & i_q;
    sum_j_d = {32{issue_sum_now}} & j_issue;
    sum_ph_d = issue_sum_now && ph_q;""")
rep("""        sum_i_q     <= dot_valid ? dot_i_out     : '0;
        sum_j_q     <= dot_valid ? dot_j_out     : '0;
      end else begin""", """        sum_i_q     <= dot_valid ? dot_i_out     : '0;
        sum_j_q     <= dot_valid ? dot_j_out     : '0;
        sum_ph_q    <= dot_valid && dot_ph_out;
      end else begin""")
rep("""        sum_i_q     <= sum_i_d;
        sum_j_q     <= sum_j_d;
      end""", """        sum_i_q     <= sum_i_d;
        sum_j_q     <= sum_j_d;
        sum_ph_q    <= sum_ph_d;
      end""")
rep("""      for (int unsigned g = 0; g < OutCols; g++) begin acc_q[g] <= '0; sum_q[g] <= '0; sum_cv_q[g] <= 1'b0; end""",
    """      for (int unsigned g = 0; g < OutCols; g++) begin acc_q[0][g] <= '0; acc_q[1][g] <= '0; sum_q[g] <= '0; sum_cv_q[g] <= 1'b0; end
      sum_ph_q <= 1'b0;""")
rep("""      for (int unsigned g = 0; g < OutCols; g++) acc_q[g] <= acc_d[g];""",
    """      for (int unsigned g = 0; g < OutCols; g++) begin acc_q[0][g] <= acc_d[0][g]; acc_q[1][g] <= acc_d[1][g]; end""")
rep("""  assign b_rd_addr_c = b_bank_addr(rd_byte_base, j_q);""", """  assign b_rd_addr_c = b_bank_addr(rd_byte_base, j_issue);""")
rep("""      assert (!col_v[g] || b_rd_addr_c == b_bank_addr(rd_byte_base, j_q + 32'(g)))""",
    """      assert (!col_v[g] || b_rd_addr_c == b_bank_addr(rd_byte_base, j_issue + 32'(g)))""")
rep("""  always @(posedge clk_i) if (rst_ni && operand_active && !acc_mode_q)
    assert ((j_q & 32'(OutCols-1)) == 0)""", """  always @(posedge clk_i) if (rst_ni && operand_active && !acc_mode_q)
    assert ((j_issue & 32'(OutCols-1)) == 0)""")
rep("""    else if (state_q == ST_MAC && i_q < m_q)
      mac_last_q <= (t_q + mac_step >= k_q) ? (mac_step >= k_q)
                                            : (t_q + (mac_step << 1) >= k_q);
    else mac_last_q <= mac_step >= k_q;""", """    else if (state_q == ST_MAC && i_q < m_q) begin
      if (ph_q)
        mac_last_q <= (t_q + mac_step >= k_q) ? (mac_step >= k_q)
                                              : (t_q + (mac_step << 1) >= k_q);
    end else mac_last_q <= mac_step >= k_q;""")
rep("""      if (state_q == ST_MAC && i_q < m_q) begin
        if (t_q + mac_step >= k_q) begin
          t_q   <= '0;
          if (j_q + cols_eff >= n_q) begin""", """      if (state_q == ST_MAC && i_q < m_q && ph_q) begin
        if (t_q + mac_step >= k_q) begin
          t_q   <= '0;
          if (j_q + (cols_eff << 1) >= n_q) begin""")
rep("""            j_q <= j_q + cols_eff;
            b_row_base_q <= b_row_base_q + AddrWidth'(stride_b_grp_q);
            b_cur_q      <= b_row_base_q + AddrWidth'(stride_b_grp_q);
            a_cur_q      <= a_row_base_q;""", """            j_q <= j_q + (cols_eff << 1);
            b_row_base_q <= b_row_base_q + (AddrWidth'(stride_b_grp_q) << 1);
            b_cur_q      <= b_row_base_q + (AddrWidth'(stride_b_grp_q) << 1);
            a_cur_q      <= a_row_base_q;""")
p.write_text(s, encoding='utf-8')
print('ok part2')
