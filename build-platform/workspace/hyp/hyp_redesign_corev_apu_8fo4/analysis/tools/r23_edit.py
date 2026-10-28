# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""r23 edits for g6lc_ai_gemm_seq.sv: receive remaining-byte facts, narrow
beat count selection, constant-shift AR stripe cap, issuing fact (one-shot)."""
from pathlib import Path
p = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_gemm_seq.sv')
s = p.read_text(encoding='utf-8')


def rep(old, new, count=1):
    global s
    assert s.count(old) == count, (s.count(old), old[:80])
    s = s.replace(old, new)


# A. receive decode: remaining bytes carried as a fact, narrow min.
rep("""    receive_rem = k_bytes - receive_col;
    receive_room = 32'(BytesPerBeat) - 32'(receive_lane);
    receive_count = receive_rem < receive_room ? receive_rem : receive_room;
    if (receive_count > PeLanes) receive_count = PeLanes;
  end""", """    // r23: the remaining byte count is a carried fact (slot or ordered
    // cursor), and the beat room is below 2*BytesPerBeat, so the select
    // compares only the low bits once the high bits are known zero.
    receive_rem = SplitArId ? ar_slot_q[receive_slot].rem : recv_rem_q;
    receive_room = 32'(BytesPerBeat) - 32'(receive_lane);
    receive_count = (receive_rem[31:BeatAlignW+1] == '0 &&
                     receive_rem[BeatAlignW:0] < receive_room[BeatAlignW:0]) ?
                    receive_rem : receive_room;
    if (receive_count > PeLanes) receive_count = PeLanes;
  end
  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      load_active |-> receive_rem == k_bytes - receive_col);
  // pragma translate_on
  // Ordered-ID receive remaining bytes: k_bytes - t_q while a load runs.
  logic [31:0] recv_rem_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) recv_rem_q <= '0;
    else if (!load_active) recv_rem_q <= k_bytes;
    else if (load_r_fire)
      recv_rem_q <= recv_rem_q <= 32'(load_a ? la_n_d : lb_n_d) ?
                    k_bytes : recv_rem_q - 32'(load_a ? la_n_d : lb_n_d);
  end""")
# slot record carries rem
rep("""    logic [31:0]          row;
    logic [31:0]          col;
  } ar_slot_t;""", """    logic [31:0]          row;
    logic [31:0]          col;
    logic [31:0]          rem;   // k_bytes - col
  } ar_slot_t;""")
rep("""          ar_slot_q[ar_slot_widx].row   <= ar_slot_push_row;
          ar_slot_q[ar_slot_widx].col   <= ar_slot_push_col;""", """          ar_slot_q[ar_slot_widx].row   <= ar_slot_push_row;
          ar_slot_q[ar_slot_widx].col   <= ar_slot_push_col;
          ar_slot_q[ar_slot_widx].rem   <= k_bytes - ar_slot_push_col;""")
rep("""            if (ar_slot_q[ar_slot_ridx].col + ar_slot_ntake >= k_bytes) begin
              ar_slot_q[ar_slot_ridx].col <= '0;
              ar_slot_q[ar_slot_ridx].row <=
                  ar_slot_q[ar_slot_ridx].row + 32'd1;
            end else
              ar_slot_q[ar_slot_ridx].col <=""", """            if (ar_slot_q[ar_slot_ridx].rem <= ar_slot_ntake) begin
              ar_slot_q[ar_slot_ridx].col <= '0;
              ar_slot_q[ar_slot_ridx].rem <= k_bytes;
              ar_slot_q[ar_slot_ridx].row <=
                  ar_slot_q[ar_slot_ridx].row + 32'd1;
            end else begin
              ar_slot_q[ar_slot_ridx].rem <= ar_slot_q[ar_slot_ridx].rem - ar_slot_ntake;
              ar_slot_q[ar_slot_ridx].col <=""")
# B. AR planner stripe cap with constant shifts
rep("""        3'd2: begin
          ar_plan_nb_q <= cap_beats_to_stripe(ar_plan_addr_q, ar_plan_nb_q);
          ar_plan_phase_q <= 3'd3;
        end""", """        3'd2: begin
          ar_plan_nb_q <= 32'(ar_plan_nb_q) > ar_stripe_beats_c ? ar_stripe_beats_c[7:0] : ar_plan_nb_q;
          ar_plan_phase_q <= 3'd3;
        end""")
rep("""  assign ar_plan_valid = ar_plan_phase_q == 3'd5 &&""", """  // r23: beats left in the DRAM stripe at the planned (beat-aligned) address,
  // as 2^(C-s) - offset/2^s with constant shifts (same identity as the store
  // planner; the planned address is beat aligned so no sticky term exists).
  logic [31:0] ar_stripe_beats_c;
  if (NrChannels <= 1) begin : gen_ar_stripe_single
    assign ar_stripe_beats_c = 32'd255;
  end else if (ChanShift > BeatAlignW) begin : gen_ar_stripe
    logic [31:0] ar_stripe_raw;
    assign ar_stripe_raw = (32'd1 << (ChanShift - BeatAlignW)) -
        ((32'(ar_plan_addr_q) & ((32'd1 << ChanShift) - 32'd1)) >> BeatAlignW);
    assign ar_stripe_beats_c = ar_stripe_raw > 32'd255 ? 32'd255 : ar_stripe_raw;
  end else begin : gen_ar_stripe_unit
    assign ar_stripe_beats_c = 32'd1;
  end
  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      ar_plan_phase_q == 3'd2 |-> ar_plan_nb_q > 0 &&
      (32'(ar_plan_nb_q) > ar_stripe_beats_c ? ar_stripe_beats_c[7:0] : ar_plan_nb_q) ==
          cap_beats_to_stripe(ar_plan_addr_q, ar_plan_nb_q));
  // pragma translate_on
  assign ar_plan_valid = ar_plan_phase_q == 3'd5 &&""")
# C. issuing fact: i_q < m_q registered alongside the row cursor
rep("""  assign issue_now = state_q == ST_MAC && i_q < m_q && (!ph_q || pair_present);""",
    """  assign issue_now = state_q == ST_MAC && rows_left_q && (!ph_q || pair_present);""")
rep("""      ph_q <= (state_q == ST_MAC && i_q < m_q) ? !ph_q : 1'b0;""",
    """      ph_q <= (state_q == ST_MAC && rows_left_q) ? !ph_q : 1'b0;""")
rep("""  assign pair_present = j_pair_q < n_q;""", """  assign pair_present = j_pair_q < n_q;
  // r23: `i_q < m_q` as a registered fact; it only changes when the MAC row
  // cursor is written (row advance to m) or the job starts / the loads reset
  // the cursor to zero.
  logic rows_left_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rows_left_q <= 1'b0;
    else if (state_q == ST_MAC && rows_left_q && ph_q && t_q + mac_step >= k_q &&
             j_q + (cols_eff << 1) >= n_q)
      rows_left_q <= i_q + 32'd1 < m_q;
    else if (state_q != ST_MAC) rows_left_q <= i_q < m_q;
  end
  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == ST_MAC |-> rows_left_q == (i_q < m_q));
  // pragma translate_on""")
p.write_text(s, encoding='utf-8')
print('ok r23')
