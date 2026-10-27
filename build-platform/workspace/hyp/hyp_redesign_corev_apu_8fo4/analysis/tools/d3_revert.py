from pathlib import Path
p = Path('build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_gemm_seq.sv')
s = p.read_text()

# (decl restore already landed in the previous partial run; verify absent-cand state)

# remove the F2 comb assigns block
start = s.find('  // F2 comb: beats -> stripe cap -> elems -> row_last, F1 regs only.')
end = s.find('  assign ar_b_row_last_w = ar_b_elems_w >= ar_b_f1_q.rem;')
assert start > 0 and end > start, 'comb block'
end = s.find('\n', end) + 1
s = s[:start] + s[end:]

# remove the cand/f1/tag writes inside the big ff (else arm)
start = s.find('      // F1: cheap terms from the live cursors (+ job-tag snapshot).')
end = s.find("        ar_job_tag_q <= ar_job_tag_q + 4'd1;")
assert start > 0 and end > start, 'ff writes'
end = s.find('\n', end) + 1
s = s[:start] + s[end:]

# remove the reset-arm cand writes
old = """      ar_a_cand_q <= '0; ar_b_cand_q <= '0; ar_job_tag_q <= '0;
      ar_a_f1_q   <= '0; ar_b_f1_q   <= '0;
"""
assert old in s, 'reset arm'
s = s.replace(old, '')

# remove the comment header of the cand block (left behind)
old = """  // D3: one-cycle-ahead AR candidates -- own always_ff per the rank-0
  // register-group rule (they must not compose with the cursor ff).
  // Sampled with the cursors that produced the payload and the job tag;
  // validity is a comb compare of the sampled context against the live
  // registers, so any cursor-write path is caught.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
    end else begin
"""
if old in s:
    s = s.replace(old, '')

# remove the cand_eq miter
mstart = s.find('      // pragma translate_off\n      // D3: when a candidate is offered')
mend = s.find('      // pragma translate_on', mstart)
assert mstart > 0 and mend > mstart, 'miter'
mend = s.find('\n', mend) + 1
s = s[:mstart] + s[mend:]

# restore consume sites
s = s.replace("""          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_i_q < m_q
              && ar_a_cand_v) begin
            axi_req_d.ar.addr  = ar_a_cand_q.addr;
            nb                 = ar_a_cand_q.nb;""",
"""          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_i_q < m_q) begin
            axi_req_d.ar.addr  = ar_a_pre_addr;
            nb                 = ar_a_pre_nb;""")
s = s.replace('ar_lane_push    = ar_a_cand_q.lane;', 'ar_lane_push    = ar_a_pre_lane;')
s = s.replace('              elems = ar_a_cand_q.elems;\n              if (ar_a_cand_q.row_last) begin',
              '              elems = ar_a_pre_elems;\n              if (ar_a_pre_row_last) begin')
s = s.replace("""          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_j_q < n_q
              && ar_b_cand_v) begin
            axi_req_d.ar.addr  = ar_b_cand_q.addr;
            nb                 = ar_b_cand_q.nb;""",
"""          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_j_q < n_q) begin
            axi_req_d.ar.addr  = ar_b_pre_addr;
            nb                 = ar_b_pre_nb;""")
s = s.replace('ar_lane_push    = ar_b_cand_q.lane;', 'ar_lane_push    = ar_b_pre_lane;')
s = s.replace('              elems = ar_b_cand_q.elems;\n              if (ar_b_cand_q.row_last) begin',
              '              elems = ar_b_pre_elems;\n              if (ar_b_pre_row_last) begin')

p.write_text(s, newline='\n')
print('D3/D3b reverted')
