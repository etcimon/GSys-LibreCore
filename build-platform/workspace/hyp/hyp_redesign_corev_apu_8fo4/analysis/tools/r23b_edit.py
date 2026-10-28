# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""r23b edits: static-indexed operand bank writes, dead receive cap, t_zero fact."""
from pathlib import Path
p = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_gemm_seq.sv')
s = p.read_text(encoding='utf-8')


def rep(old, new, count=1):
    global s
    assert s.count(old) == count, (s.count(old), old[:80])
    s = s.replace(old, new)


rep("""  always_comb begin : write_operand_banks
    for (int unsigned p = 0; p < PeLanes; p++) begin
      a_w_req[p] = 1'b0;
      a_w_addr[p] = '0;
      a_w_data[p] = '0;
      for (int unsigned g = 0; g < OutCols; g++) begin
        b_w_req[g][p] = 1'b0;
        b_w_addr[g][p] = '0;
        b_w_data[g][p] = '0;
      end
    end
    if (load_r_fire) begin
      for (int unsigned p = 0; p < PeLanes; p++) begin
        if (32'(p) < receive_count) begin
          if (load_a) begin
            a_w_req[t_bank(receive_col + 32'(p))] = 1'b1;
            a_w_addr[t_bank(receive_col + 32'(p))] =
                a_bank_addr(receive_row, receive_col + 32'(p));
            a_w_data[t_bank(receive_col + 32'(p))] =
                byte_from_beat(axi_resp_s.r.data, BeatLaneW'(32'(receive_lane) + p));
          end else begin
            for (int unsigned g = 0; g < OutCols; g++) begin
              if (col_grp(receive_row) == ColW'(g)) begin
                b_w_req[g][t_bank(receive_col + 32'(p))] = 1'b1;
                b_w_addr[g][t_bank(receive_col + 32'(p))] =
                    b_bank_addr(receive_col + 32'(p), receive_row);
                b_w_data[g][t_bank(receive_col + 32'(p))] =
                    byte_from_beat(axi_resp_s.r.data, BeatLaneW'(32'(receive_lane) + p));
              end
            end
          end
        end
      end
    end
  end""", """  // r23: static per-bank write routing. Beat byte p lands in bank
  // (col + p) mod PeLanes, so bank b takes byte p_b = (b - col_lane) mod
  // PeLanes when p_b < count, at the word of (row, col) plus one when the
  // lane wrapped (b < col_lane). No dynamic write index and one shared word.
  logic [LaneW-1:0] rx_col_lane;
  logic [OperandBankAddrW-1:0] rx_a_word_c, rx_b_word_c;
  logic [ColW-1:0] rx_b_group;
  assign rx_col_lane = LaneW'(receive_col & 32'(PeLanes - 1));
  assign rx_a_word_c = a_bank_addr(receive_row, receive_col);
  assign rx_b_word_c = b_bank_addr(receive_col, receive_row);
  assign rx_b_group = col_grp(receive_row);
  for (genvar b = 0; b < PeLanes; b++) begin : gen_rx_bank
    logic [LaneW-1:0] lane_off;
    logic live, carry;
    logic [7:0] byte_c;
    assign lane_off = LaneW'(b) - rx_col_lane;
    assign live = load_r_fire && 32'(lane_off) < receive_count;
    assign carry = LaneW'(b) < rx_col_lane;
    assign byte_c = byte_from_beat(axi_resp_s.r.data,
                                   BeatLaneW'(32'(receive_lane) + 32'(lane_off)));
    assign a_w_req[b] = live && load_a;
    assign a_w_addr[b] = rx_a_word_c + OperandBankAddrW'(carry);
    assign a_w_data[b] = byte_c;
    for (genvar g = 0; g < OutCols; g++) begin : gen_rx_group
      assign b_w_req[g][b] = live && load_b && rx_b_group == ColW'(g);
      assign b_w_addr[g][b] = rx_b_word_c + OperandBankAddrW'(carry);
      assign b_w_data[g][b] = byte_c;
    end
  end
  // pragma translate_off
  always @(negedge clk_i) if (rst_ni && load_r_fire) begin
    for (int unsigned p = 0; p < PeLanes; p++) begin
      automatic logic [LaneW-1:0] bank;
      if (32'(p) < receive_count) begin
        bank = t_bank(receive_col + 32'(p));
        if (load_a) begin
          assert (a_w_req[bank] && a_w_addr[bank] == a_bank_addr(receive_row, receive_col + 32'(p)) &&
                  a_w_data[bank] == byte_from_beat(axi_resp_s.r.data, BeatLaneW'(32'(receive_lane) + p)))
            else $error("r23 A bank write routing differs for byte %0d", p);
        end else begin
          assert (b_w_req[rx_b_group][bank] &&
                  b_w_addr[rx_b_group][bank] == b_bank_addr(receive_col + 32'(p), receive_row))
            else $error("r23 B bank write routing differs for byte %0d", p);
        end
      end
    end
  end
  // pragma translate_on""")
# dead receive cap when a beat cannot exceed the lane count
rep("""    if (receive_count > PeLanes) receive_count = PeLanes;
  end""", """    // A beat's room never exceeds BytesPerBeat, so the lane cap only exists
    // for beats wider than the lane array.
    if (BytesPerBeat > PeLanes && receive_count > PeLanes) receive_count = PeLanes;
  end""")
# t_zero fact beside mac_last_q
rep("""  logic mac_last_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mac_last_q <= 1'b0;
    else if (state_q == ST_MAC && i_q < m_q) begin
      if (ph_q)
        mac_last_q <= (t_q + mac_step >= k_q) ? (mac_step >= k_q)
                                              : (t_q + (mac_step << 1) >= k_q);
    end else mac_last_q <= mac_step >= k_q;
  end""", """  logic mac_last_q, t_zero_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin mac_last_q <= 1'b0; t_zero_q <= 1'b1; end
    else if (state_q == ST_MAC && i_q < m_q) begin
      if (ph_q) begin
        mac_last_q <= (t_q + mac_step >= k_q) ? (mac_step >= k_q)
                                              : (t_q + (mac_step << 1) >= k_q);
        t_zero_q <= t_q + mac_step >= k_q;
      end
    end else begin
      mac_last_q <= mac_step >= k_q;
      t_zero_q <= 1'b1;
    end
  end""")
rep("""      state_q == ST_MAC && i_q < m_q |-> mac_last_q == (t_q + mac_step >= k_q));""",
    """      state_q == ST_MAC && i_q < m_q |-> mac_last_q == (t_q + mac_step >= k_q) && t_zero_q == (t_q == 0));""")
rep("""      (dot_pipe_en ? (dot_valid && dot_first_out) : (issue_now && t_q == 0));""",
    """      (dot_pipe_en ? (dot_valid && dot_first_out) : (issue_now && t_zero_q));""")
rep("""    dot_first_issue = issue_now && t_q == 0;""", """    dot_first_issue = issue_now && t_zero_q;""")
rep("""    sum_first_d = issue_sum_now && t_q == 0;""", """    sum_first_d = issue_sum_now && t_zero_q;""")
p.write_text(s, encoding='utf-8')
print('ok r23b')
