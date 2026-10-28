# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""r23c: registered operand-bank read stage (tile read latency 1; issue
cursors one cycle ahead of packing and dot issue)."""
from pathlib import Path
seq = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_gemm_seq.sv')
tile = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_tile_sram.sv')
s = seq.read_text(encoding='utf-8')
t = tile.read_text(encoding='utf-8')


def rep(old, new, count=1):
    global s
    assert s.count(old) == count, (s.count(old), old[:80])
    s = s.replace(old, new)


# tile: read latency parameter
assert t.count("""    parameter              ImplKey   = "g6lc_ai_tile",""") == 1
t = t.replace("""    parameter              ImplKey   = "g6lc_ai_tile",""",
              """    parameter              ImplKey   = "g6lc_ai_tile",
    // r23: operand banks register their read data (the sequencer's read
    // stage); the C bank keeps the latency-0 read its store/seed paths assume.
    parameter int unsigned ReadLatency = 0,""")
assert t.count("        .Latency    (0),") == 3
t = t.replace("        .Latency    (0),", "        .Latency    (ReadLatency),")
tile.write_text(t, encoding='utf-8')

rep("""        .ImplKey  ("g6lc_ai_tile_a")""", """        .ImplKey  ("g6lc_ai_tile_a"),
        .ReadLatency(OperandReadLatency)""")
rep("""        .ImplKey  ("g6lc_ai_tile_b")""", """        .ImplKey  ("g6lc_ai_tile_b"),
        .ReadLatency(OperandReadLatency)""")
rep("""  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_a_banks""", """  // r23: operand words are read one cycle before they are packed. The issue
  // cursors advance on the read; the read stage carries the facts the
  // packing, dot tags and seed read need.
`ifdef G6LC_AI_GEMM_LEGACY_CONTROL
  localparam int unsigned OperandReadLatency = 0;
`else
  localparam int unsigned OperandReadLatency = 1;
`endif
  logic rd_v_q, rd_ph_q, rd_first_q, rd_last_q;
  logic [31:0] rd_t_q, rd_i_q, rd_j_q;
  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_a_banks""")
# packing from the read stage
rep("""  logic [31:0] operand_byte_base;
  logic [7:0] operand_b [OutCols][PeLanes];
  assign operand_active = state_q == ST_MAC && i_q < m_q;""", """  logic [31:0] operand_byte_base, pk_byte_base;
  logic [7:0] operand_b [OutCols][PeLanes];
  logic [ColW-1:0] grp_of_rd [OutCols];
  logic col_v_rd [OutCols];
  assign operand_active = state_q == ST_MAC && i_q < m_q;
  assign pk_byte_base = rd_t_q << ai_fmt_shift();
  always_comb for (int unsigned g = 0; g < OutCols; g++) begin
    grp_of_rd[g] = col_grp(rd_j_q + 32'(g));
    col_v_rd[g] = (32'(g) < cols_eff) && (rd_j_q + 32'(g) < n_q);
  end""")
rep("""      assign operand_b[g][p] = acc_mode_q ? b_r_data[grp_of[g]][p] : b_r_data[g][p];""",
    """      assign operand_b[g][p] = acc_mode_q ? b_r_data[grp_of_rd[g]][p] : b_r_data[g][p];""")
rep("""    assign nibble0_live = operand_active && t_q + 32'(2*p) < k_q;
    assign nibble1_live = operand_active && t_q + 32'(2*p+1) < k_q;
    assign byte_live = operand_active && operand_byte_base + 32'(p) < k_bytes;
    assign float_live = operand_active && numfmt_q != 3'd1 &&
                        32'(p) < mac_step && t_q + 32'(p) < k_q;
    assign pe_v[p] = numfmt_q == 3'd1 ? nibble0_live : float_live;
    assign lane_live[p] = numfmt_q == 3'd1 ? nibble0_live : byte_live;""",
    """    assign nibble0_live = rd_v_q && rd_t_q + 32'(2*p) < k_q;
    assign nibble1_live = rd_v_q && rd_t_q + 32'(2*p+1) < k_q;
    assign byte_live = rd_v_q && pk_byte_base + 32'(p) < k_bytes;
    assign float_live = rd_v_q && numfmt_q != 3'd1 &&
                        32'(p) < mac_step && rd_t_q + 32'(p) < k_q;
    assign pe_v[p] = numfmt_q == 3'd1 ? nibble0_live : float_live;
    // Read requests use the live cursor; packing uses the read stage.
    assign lane_live[p] = numfmt_q == 3'd1 ? (operand_active && t_q + 32'(2*p) < k_q)
                                           : (operand_active && operand_byte_base + 32'(p) < k_bytes);""")
# shadow check follows the read stage
rep("""      base = numfmt_q == 3'd1 ? t_q >> 1 : t_q << ai_fmt_shift();
      for (int p = 0; p < PeLanes; p++) begin
        ai = '0; af = '0; v = 1'b0;
        e0 = t_q + 32'(2*p); e1 = e0 + 32'd1;
        off = 32'(p) << ai_fmt_shift();
        if (operand_active) begin""", """      base = numfmt_q == 3'd1 ? rd_t_q >> 1 : rd_t_q << ai_fmt_shift();
      for (int p = 0; p < PeLanes; p++) begin
        ai = '0; af = '0; v = 1'b0;
        e0 = rd_t_q + 32'(2*p); e1 = e0 + 32'd1;
        off = 32'(p) << ai_fmt_shift();
        if (rd_v_q) begin""")
rep("""            v = 32'(p) < mac_step && t_q + 32'(p) < k_q;""", """            v = 32'(p) < mac_step && rd_t_q + 32'(p) < k_q;""")
rep("""          if (operand_active) begin
            if (numfmt_q == 3'd1) begin
              if (v) bi = {e1 < k_q ? b_r_data[grp_of[g]][p][7:4] : 4'd0,
                           b_r_data[grp_of[g]][p][3:0]};
            end else begin
              if (base + 32'(p) < k_bytes) bi = b_r_data[grp_of[g]][p];
              if (v) case (ai_fmt_bytes())
                1: bf = {24'd0, b_r_data[grp_of[g]][off]};
                2: bf = {16'd0, b_r_data[grp_of[g]][off+1], b_r_data[grp_of[g]][off]};
                4: bf = {b_r_data[grp_of[g]][off+3], b_r_data[grp_of[g]][off+2],
                         b_r_data[grp_of[g]][off+1], b_r_data[grp_of[g]][off]};""",
    """          if (rd_v_q) begin
            if (numfmt_q == 3'd1) begin
              if (v) bi = {e1 < k_q ? b_r_data[grp_of_rd[g]][p][7:4] : 4'd0,
                           b_r_data[grp_of_rd[g]][p][3:0]};
            end else begin
              if (base + 32'(p) < k_bytes) bi = b_r_data[grp_of_rd[g]][p];
              if (v) case (ai_fmt_bytes())
                1: bf = {24'd0, b_r_data[grp_of_rd[g]][off]};
                2: bf = {16'd0, b_r_data[grp_of_rd[g]][off+1], b_r_data[grp_of_rd[g]][off]};
                4: bf = {b_r_data[grp_of_rd[g]][off+3], b_r_data[grp_of_rd[g]][off+2],
                         b_r_data[grp_of_rd[g]][off+1], b_r_data[grp_of_rd[g]][off]};""")
rep("""      if (operand_active) begin
        r20_operand_checks = r20_operand_checks + PeLanes;""", """      if (rd_v_q) begin
        r20_operand_checks = r20_operand_checks + PeLanes;""")
# read stage registers + issue from it
rep("""  assign issue_now = state_q == ST_MAC && rows_left_q && (!ph_q || pair_present);""",
    """  assign issue_now = state_q == ST_MAC && rows_left_q && (!ph_q || pair_present);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_v_q <= 1'b0; rd_ph_q <= 1'b0; rd_first_q <= 1'b0; rd_last_q <= 1'b0;
      rd_t_q <= '0; rd_i_q <= '0; rd_j_q <= '0;
    end else begin
      rd_v_q <= issue_now;
      if (issue_now) begin
        rd_ph_q <= ph_q; rd_first_q <= t_zero_q; rd_last_q <= mac_last_q;
        rd_t_q <= t_q; rd_i_q <= i_q; rd_j_q <= j_issue;
      end
    end
  end""")
rep("""  assign issue_sum_now = issue_now && !(DotPipeFloat && pe_float_en);
  always_comb begin : issue_step
    dot_start = issue_now && dot_pipe_en;
    dot_first_issue = issue_now && t_zero_q;
    dot_last_issue = issue_now && mac_last_q;
    dot_i_issue = {32{issue_now}} & i_q;
    dot_j_issue = {32{issue_now}} & j_issue;
    for (int unsigned g = 0; g < OutCols; g++) begin
      sum_d[g] = {32{issue_sum_now}} & pe_sum[g];
      sum_cv_d[g] = issue_sum_now && col_v[g];
    end
    sum_v_d = issue_sum_now;
    sum_first_d = issue_sum_now && t_zero_q;
    sum_last_d = issue_sum_now && mac_last_q;
    sum_i_d = {32{issue_sum_now}} & i_q;
    sum_j_d = {32{issue_sum_now}} & j_issue;
    sum_ph_d = issue_sum_now && ph_q;
  end""", """  assign issue_sum_now = rd_v_q && !(DotPipeFloat && pe_float_en);
  always_comb begin : issue_step
    dot_start = rd_v_q && dot_pipe_en;
    dot_first_issue = rd_v_q && rd_first_q;
    dot_last_issue = rd_v_q && rd_last_q;
    dot_i_issue = {32{rd_v_q}} & rd_i_q;
    dot_j_issue = {32{rd_v_q}} & rd_j_q;
    for (int unsigned g = 0; g < OutCols; g++) begin
      sum_d[g] = {32{issue_sum_now}} & pe_sum[g];
      sum_cv_d[g] = issue_sum_now && col_v_rd[g];
    end
    sum_v_d = issue_sum_now;
    sum_first_d = issue_sum_now && rd_first_q;
    sum_last_d = issue_sum_now && rd_last_q;
    sum_i_d = {32{issue_sum_now}} & rd_i_q;
    sum_j_d = {32{issue_sum_now}} & rd_j_q;
    sum_ph_d = issue_sum_now && rd_ph_q;
  end""")
rep("""      always_comb for (int unsigned g = 0; g < OutCols; g++) col_v_vec[g] = col_v[g];""",
    """      always_comb for (int unsigned g = 0; g < OutCols; g++) col_v_vec[g] = col_v_rd[g];""")
rep("""          dot_ph_pipe    <= {dot_ph_pipe[DOT_LATENCY-2:0], dot_start && ph_q};""",
    """          dot_ph_pipe    <= {dot_ph_pipe[DOT_LATENCY-2:0], dot_start && rd_ph_q};""")
rep("""      (dot_pipe_en ? (dot_valid && dot_first_out) : (issue_now && t_zero_q));
  assign seed_i = dot_pipe_en ? dot_i_out : i_q;
  assign seed_j = dot_pipe_en ? dot_j_out : j_issue;
  assign seed_set = dot_pipe_en ? dot_ph_out : ph_q;""", """      (dot_pipe_en ? (dot_valid && dot_first_out) : (rd_v_q && rd_first_q));
  assign seed_i = dot_pipe_en ? dot_i_out : rd_i_q;
  assign seed_j = dot_pipe_en ? dot_j_out : rd_j_q;
  assign seed_set = dot_pipe_en ? dot_ph_out : rd_ph_q;""")
rep("""        if (i_q >= m_q && stc_i_q >= m_q && !aw_sent_q && !sum_v_q && !s1_v_q &&
            !commit_v_q && dot_pending_q == '0) state_d = ST_DONE;""", """        if (i_q >= m_q && stc_i_q >= m_q && !aw_sent_q && !rd_v_q && !sum_v_q && !s1_v_q &&
            !commit_v_q && dot_pending_q == '0) state_d = ST_DONE;""")
rep("""       i_q >= m_q && dot_pending_q == '0 && !sum_v_q && !s1_v_q && !commit_v_q);""",
    """       i_q >= m_q && dot_pending_q == '0 && !rd_v_q && !sum_v_q && !s1_v_q && !commit_v_q);""")
seq.write_text(s, encoding='utf-8')
print('ok r23c')
