// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 r127: equivalence of the g6lc_ai_gemm_arplan S3 forms. `ref_elems` is
// the module's elems_for_burst function verbatim; `new_*` is the r127 closed
// form verbatim (max(nb,1) * BytesPerBeat - lane0, clamped to rem by one
// compare that also yields row_last). g6lc_ai_gemm_arplan is instantiated
// nowhere, so no bench reaches its in-module assertion; this sweep is the
// check. Every lane0 and nb value is crossed with a rem set that holds all
// small values, every value within +-2 of a beat multiple up to the largest
// burst, the 32-bit corners and random words. No delays: one initial block.
module tb_g6lc_ai_arplan_eq;
  localparam int unsigned BeatAlignW   = 6;
  localparam int unsigned BeatLaneW    = 6;
  localparam int unsigned BytesPerBeat = 64;
  localparam int unsigned EfbW         = 8 + BeatAlignW + 1;

  function automatic logic [31:0] ref_elems(
      input logic [31:0] rem, input logic [BeatLaneW-1:0] lane0, input logic [7:0] nb);
    automatic logic [31:0] first, cap, nbb;
    if (rem == 0) return 32'd0;
    first = 32'(BytesPerBeat) - 32'(lane0);
    if (first > rem) first = rem;
    nbb = 32'(nb);
    if (nbb <= 32'd1) return first;
    cap = first + (nbb - 32'd1) * 32'(BytesPerBeat);
    if (cap > rem) cap = rem;
    return cap;
  endfunction

  int unsigned checked = 0, bad = 0;
  logic [31:0] rem_set [$];

  task automatic one(input logic [31:0] rem, input logic [BeatLaneW-1:0] lane0, input logic [7:0] nb);
    logic [7:0]      nb_e;
    logic [EfbW-1:0] total;
    logic            lt;
    logic [31:0]     elems_n, elems_r;
    logic            last_n;
`ifdef G6LC_MUT_ARPLAN_EQ
    nb_e    = nb;                       // negative control: drop the nb==0 clamp
`else
    nb_e    = (nb == 8'd0) ? 8'd1 : nb;
`endif
    total   = {1'b0, nb_e, {BeatAlignW{1'b0}}} - EfbW'(lane0);
    lt      = (|rem[31:EfbW]) || (total < rem[EfbW-1:0]);
    elems_n = lt ? 32'(total) : rem;
    last_n  = !lt;
    elems_r = ref_elems(rem, lane0, nb);
    checked++;
    if (elems_n !== elems_r || last_n !== (elems_r >= rem)) begin
      bad++;
      if (bad < 8) $display("FAIL rem=%0d lane=%0d nb=%0d new=%0d/%b ref=%0d/%b",
                            rem, lane0, nb, elems_n, last_n, elems_r, elems_r >= rem);
    end
  endtask

  initial begin
    for (int unsigned r = 0; r <= 300; r++) rem_set.push_back(r);
    for (int unsigned k = 1; k <= 257; k++)
      for (int d = -2; d <= 2; d++) rem_set.push_back(32'(k * BytesPerBeat + d));
    rem_set.push_back(32'hFFFF_FFFF); rem_set.push_back(32'hFFFF_FFFE);
    rem_set.push_back(32'h8000_0000); rem_set.push_back(32'h7FFF_FFFF);
    rem_set.push_back(32'h0000_8000); rem_set.push_back(32'h0000_7FFF);
    rem_set.push_back(32'h0001_0000); rem_set.push_back(32'h0000_FFFF);
    for (int unsigned i = 0; i < 400; i++) rem_set.push_back($urandom());
    for (int unsigned i = 0; i < 400; i++) rem_set.push_back($urandom() & 32'h0000_7FFF);
    foreach (rem_set[i])
      for (int unsigned l = 0; l < (1 << BeatLaneW); l++)
        for (int unsigned n = 0; n < 256; n++)
          one(rem_set[i], BeatLaneW'(l), 8'(n));
    if (bad == 0) $display("HYP8_AI_ARPLAN_EQ_PASS checked=%0d", checked);
    else $display("HYP8_AI_ARPLAN_EQ_FAIL checked=%0d bad=%0d", checked, bad);
    $finish;
  end
endmodule
