from pathlib import Path
p = Path('build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_gemm_seq.sv')
s = p.read_text()

# ---- 1) retire the ar_*_pre comb + decls (:2330-2350 region)
old = """  logic [AddrWidth-1:0] ar_a_pre_addr,  ar_b_pre_addr;
  logic [BeatLaneW-1:0] ar_a_pre_lane,  ar_b_pre_lane;
  logic [31:0]          ar_a_pre_rem,   ar_b_pre_rem;
  logic [7:0]           ar_a_pre_nb,    ar_b_pre_nb;
  logic [31:0]          ar_a_pre_elems, ar_b_pre_elems;
  logic                 ar_a_pre_row_last, ar_b_pre_row_last;
  always_comb begin
    ar_a_pre_lane     = a_ar_cur[BeatAlignW-1:0];
    ar_a_pre_addr     = beat_align(a_ar_cur);
    ar_a_pre_rem      = beats_for_rem(k_bytes - ar_t_q, ar_a_pre_lane);
    ar_a_pre_nb       = cap_beats_to_stripe(ar_a_pre_addr, ar_a_pre_rem);
    ar_a_pre_elems    = elems_for_burst(k_bytes - ar_t_q, ar_a_pre_lane, ar_a_pre_nb);
    ar_a_pre_row_last = (ar_t_q + ar_a_pre_elems) >= k_bytes;
  end
  always_comb begin
    ar_b_pre_lane     = b_ar_cur[BeatAlignW-1:0];
    ar_b_pre_addr     = beat_align(b_ar_cur);
    ar_b_pre_rem      = beats_for_rem(k_bytes - ar_t_q, ar_b_pre_lane);
    ar_b_pre_nb       = cap_beats_to_stripe(ar_b_pre_addr, ar_b_pre_rem);
    ar_b_pre_elems    = elems_for_burst(k_bytes - ar_t_q, ar_b_pre_lane, ar_b_pre_nb);
    ar_b_pre_row_last = (ar_t_q + ar_b_pre_elems) >= k_bytes;
  end"""
assert old in s, 'pre wires'
s = s.replace(old, """  // r7 R2: the AR precompute moved into g6lc_ai_gemm_arplan -- the
  // planner runs the identical cursor ahead of the issue arm and hands
  // it {addr, nb, lane, elems, row_last} plans from a depth-2 FIFO.
  logic                  plan_a_valid, plan_b_valid;
  logic [AddrWidth-1:0]  plan_a_addr,  plan_b_addr;
  logic [7:0]            plan_a_nb,    plan_b_nb;
  logic [BeatLaneW-1:0]  plan_a_lane,  plan_b_lane;
  logic [31:0]           plan_a_elems, plan_b_elems;
  logic                  plan_a_row_last, plan_b_row_last;
  logic                  plan_a_done, plan_b_done;
  logic [31:0]           plan_a_row, plan_a_t, plan_b_row, plan_b_t;
  logic                  ar_pop_a, ar_pop_b;

  g6lc_ai_gemm_arplan #(
      .AddrWidth         (AddrWidth),
      .BeatAlignW        (BeatAlignW),
      .BeatLaneW         (BeatLaneW),
      .BytesPerBeat      (BytesPerBeat),
      .ElemsPerBeatShift (ElemsPerBeatShift),
      .MaxBurstBeats     (MaxBurstBeats),
      .NrChannels        (NrChannels),
      .ChanShift         (ChanShift)
  ) i_arplan_a (
      .clk_i, .rst_ni,
      .job_start_i    ((state_q != ST_LA) && (state_d == ST_LA)),
      .base_i         (pa_q),
      .ld_i           (fmt_ld_to_stride(lda_q)),
      .rows_i         (m_q),
      .k_bytes_i      (k_bytes),
      .pop_i          (ar_pop_a),
      .plan_valid_o   (plan_a_valid),
      .plan_addr_o    (plan_a_addr),
      .plan_nb_o      (plan_a_nb),
      .plan_lane_o    (plan_a_lane),
      .plan_elems_o   (plan_a_elems),
      .plan_row_last_o(plan_a_row_last),
      .done_o         (plan_a_done),
      .cur_row_o      (plan_a_row),
      .cur_t_o        (plan_a_t));
  g6lc_ai_gemm_arplan #(
      .AddrWidth         (AddrWidth),
      .BeatAlignW        (BeatAlignW),
      .BeatLaneW         (BeatLaneW),
      .BytesPerBeat      (BytesPerBeat),
      .ElemsPerBeatShift (ElemsPerBeatShift),
      .MaxBurstBeats     (MaxBurstBeats),
      .NrChannels        (NrChannels),
      .ChanShift         (ChanShift)
  ) i_arplan_b (
      .clk_i, .rst_ni,
      .job_start_i    ((state_q != ST_LB) && (state_d == ST_LB)),
      .base_i         (pb_q),
      .ld_i           (fmt_ld_to_stride(ldb_q)),
      .rows_i         (n_q),
      .k_bytes_i      (k_bytes),
      .pop_i          (ar_pop_b),
      .plan_valid_o   (plan_b_valid),
      .plan_addr_o    (plan_b_addr),
      .plan_nb_o      (plan_b_nb),
      .plan_lane_o    (plan_b_lane),
      .plan_elems_o   (plan_b_elems),
      .plan_row_last_o(plan_b_row_last),
      .done_o         (plan_b_done),
      .cur_row_o      (plan_b_row),
      .cur_t_o        (plan_b_t));

  // pragma translate_off
  // r7 R2: the planner's cursor must track the sequencer's -- the head
  // of each plan FIFO is issued against the seq cursor every cycle it is
  // valid, so their (row,t) must agree.
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      plan_a_valid |-> (plan_a_row == ar_i_q && plan_a_t == ar_t_q))
    else $error("gemm_seq: arplan_a cursor diverged row %0d/%0d t %0d/%0d",
                plan_a_row, ar_i_q, plan_a_t, ar_t_q);
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      plan_b_valid |-> (plan_b_row == ar_j_q && plan_b_t == ar_t_q))
    else $error("gemm_seq: arplan_b cursor diverged row %0d/%0d t %0d/%0d",
                plan_b_row, ar_j_q, plan_b_t, ar_t_q);
  // pragma translate_on""")

# ---- 2) pop default in the comb
old = """    ar_lane_push    = '0;
    ar_lane_push_en = 1'b0;"""
assert old in s, 'comb defaults'
s = s.replace(old, """    ar_pop_a = 1'b0; ar_pop_b = 1'b0;
    ar_lane_push    = '0;
    ar_lane_push_en = 1'b0;""", 1)

# ---- 3) A arm: issue from plan_a, pop on ar_push
old = """          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_i_q < m_q) begin
            axi_req_d.ar.addr  = ar_a_pre_addr;
            nb                 = ar_a_pre_nb;
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            if (SplitArId)
              axi_req_d.ar.id = ArIdBase + IdWidth'(free_s);
            axi_req_d.ar_valid = 1'b1;
            if (axi_resp_s.ar_ready) begin
              ar_push         = 1'b1;
              ar_lane_push_en = 1'b1;
              ar_lane_push    = ar_a_pre_lane;
              ar_slot_we       = SplitArId;
              ar_slot_widx     = free_s;
              ar_slot_push_row = ar_i_q;
              ar_slot_push_col = ar_t_q;
              elems = ar_a_pre_elems;
              if (ar_a_pre_row_last) begin"""
new = """          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_i_q < m_q
              && plan_a_valid) begin
            axi_req_d.ar.addr  = plan_a_addr;
            nb                 = plan_a_nb;
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            if (SplitArId)
              axi_req_d.ar.id = ArIdBase + IdWidth'(free_s);
            axi_req_d.ar_valid = 1'b1;
            if (axi_resp_s.ar_ready) begin
              ar_push         = 1'b1;
              ar_pop_a        = 1'b1;
              ar_lane_push_en = 1'b1;
              ar_lane_push    = plan_a_lane;
              ar_slot_we       = SplitArId;
              ar_slot_widx     = free_s;
              ar_slot_push_row = ar_i_q;
              ar_slot_push_col = ar_t_q;
              elems = plan_a_elems;
              if (plan_a_row_last) begin"""
assert old in s, 'A arm'
s = s.replace(old, new)

# ---- 4) B arm: issue from plan_b, pop on ar_push
old = """          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_j_q < n_q) begin
            axi_req_d.ar.addr  = ar_b_pre_addr;
            nb                 = ar_b_pre_nb;
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            if (SplitArId)
              axi_req_d.ar.id = ArIdBase + IdWidth'(free_s);
            axi_req_d.ar_valid = 1'b1;
            if (axi_resp_s.ar_ready) begin
              ar_push         = 1'b1;
              ar_lane_push_en = 1'b1;
              ar_lane_push    = ar_b_pre_lane;
              ar_slot_we       = SplitArId;
              ar_slot_widx     = free_s;
              ar_slot_push_row = ar_j_q;
              ar_slot_push_col = ar_t_q;
              elems = ar_b_pre_elems;
              if (ar_b_pre_row_last) begin"""
new = """          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_j_q < n_q
              && plan_b_valid) begin
            axi_req_d.ar.addr  = plan_b_addr;
            nb                 = plan_b_nb;
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            if (SplitArId)
              axi_req_d.ar.id = ArIdBase + IdWidth'(free_s);
            axi_req_d.ar_valid = 1'b1;
            if (axi_resp_s.ar_ready) begin
              ar_push         = 1'b1;
              ar_pop_b        = 1'b1;
              ar_lane_push_en = 1'b1;
              ar_lane_push    = plan_b_lane;
              ar_slot_we       = SplitArId;
              ar_slot_widx     = free_s;
              ar_slot_push_row = ar_j_q;
              ar_slot_push_col = ar_t_q;
              elems = plan_b_elems;
              if (plan_b_row_last) begin"""
assert old in s, 'B arm'
s = s.replace(old, new)
p.write_text(s, newline='\n')
print('R2 splice applied')
