# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""r26: subcode constant gain table + registered choose threshold; inval_queue
constant-shift AW last byte and narrowed line subtract."""
from pathlib import Path
D = Path('E:/cva6/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island')


def edit(path, pairs):
    s = path.read_text(encoding='utf-8')
    for old, new in pairs:
        assert s.count(old) == 1, (path.name, s.count(old), old[:60])
        s = s.replace(old, new)
    path.write_text(s, encoding='utf-8')


edit(D / 'g6lc_ai_policy_subcode.sv', [
    ("""        candidate_d.gain_16ths = policy_reuse_gain(r, c);""",
     """        candidate_d.gain_16ths = reuse_gain_tab[r][c];"""),
    ("""    // r25 registered shape facts (PREP -> COST)""",
     """    // r26: the reuse gain depends only on (r, c) in 0..4: an elaboration
    // table selected by the pair replaces the package function's divide.
    logic [3:0] reuse_gain_tab [8][8];
    for (genvar gr = 0; gr < 8; gr++) begin : gen_gain_rows
      for (genvar gc = 0; gc < 8; gc++) begin : gen_gain_cols
        assign reuse_gain_tab[gr][gc] = policy_reuse_gain(3'(gr), 3'(gc));
      end
    end
    // pragma translate_off
    always @(posedge clk_i) if (rst_ni && state_q == PREP)
      assert (reuse_gain_tab[r][c] == policy_reuse_gain(r, c)) else $error("reuse gain table");
    // pragma translate_on
    // r26: the self-charging threshold is one registered fact per
    // evaluation; the per-candidate decision is a single compare.
    logic [27:0] threshold_q;
    logic threshold_ok_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin threshold_q <= '0; threshold_ok_q <= 1'b0; end
      else begin
        threshold_ok_q <= 64'(base_cost_q) > 64'(SwitchCycles) + 64'(EvaluationCycles) + 64'(MinSavingsCycles);
        threshold_q <= 28'(64'(base_cost_q) - 64'(SwitchCycles) - 64'(EvaluationCycles) - 64'(MinSavingsCycles));
      end
    end
    // r25 registered shape facts (PREP -> COST)"""),
    ("""      choose = winner_index != 0 &&
          64'(winner_cost) + 64'(SwitchCycles) + 64'(EvaluationCycles) +
          64'(MinSavingsCycles) < 64'(base_cost_q);""",
     """      choose = winner_index != 0 && threshold_ok_q && winner_cost < threshold_q;
      // pragma translate_off
      assert (choose == (winner_index != 0 &&
          64'(winner_cost) + 64'(SwitchCycles) + 64'(EvaluationCycles) +
          64'(MinSavingsCycles) < 64'(base_cost_q)) || state_q != COMPARE)
        else $error("choose threshold identity");
      // pragma translate_on"""),
])
edit(D / 'g6lc_ai_inval_queue.sv', [
    ("""    aw_last_byte = aw_addr_i + ((AddrWidth'(aw_len_i) + 1) << aw_size_i) - 1;  // kept: OR-form was the rise
    aw_line0  = aw_addr_i[AddrWidth-1:LineShift];
    aw_line1  = aw_last_byte[AddrWidth-1:LineShift];
    aw_nlines = 8'(aw_line1 - aw_line0);""",
     """    // r26: the burst byte count is (len+1) << size with a 3-bit size: eight
    // constant shifts selected one-hot, then one add. The line difference
    // needs only the low 8 + LineShift address bits.
    aw_last_byte = aw_addr_i + aw_burst_bytes - 1;
    aw_line0  = aw_addr_i[AddrWidth-1:LineShift];
    aw_line1  = aw_last_byte[AddrWidth-1:LineShift];
    aw_nlines = aw_last_byte[LineShift+7:LineShift] - aw_addr_i[LineShift+7:LineShift];"""),
    ("""  logic [7:0] aw_nlines;
  always_comb begin""",
     """  logic [7:0] aw_nlines;
  logic [AddrWidth-1:0] aw_burst_bytes;
  always_comb begin
    aw_burst_bytes = '0;
    for (int unsigned sz = 0; sz < 8; sz++)
      if (aw_size_i == 3'(sz)) aw_burst_bytes = (AddrWidth'(aw_len_i) + 1) << sz;
  end
  // pragma translate_off
  always @(posedge clk_i) if (rst_ni && aw_fire_i)
    assert (aw_burst_bytes == ((AddrWidth'(aw_len_i) + 1) << aw_size_i) &&
            aw_nlines == 8'(aw_line1 - aw_line0)) else $error("AW line arithmetic");
  // pragma translate_on
  always_comb begin"""),
])
print('ok r26')
