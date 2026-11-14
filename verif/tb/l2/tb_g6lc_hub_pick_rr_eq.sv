// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 r127: exhaustive equivalence of the two g6lc_coherence_hub pick_rr forms
// (transcribed verbatim): `ref` is the pre-r127 modulo first-found scan, `slot`
// the r127 slot-order form. Every request vector and every start value that
// fits CID_W (including start >= NC for a non-power-of-two NC) at NC = 1..8.
module pick_rr_forms #(parameter int unsigned NC = 2) (
    input  logic [NC-1:0] reqs_i,
    input  logic [((NC <= 1) ? 1 : $clog2(NC))-1:0] start_i,
    output logic [((NC <= 1) ? 1 : $clog2(NC))-1:0] ref_o, slot_o
);
  localparam int unsigned CID_W = (NC <= 1) ? 1 : $clog2(NC);
  function automatic logic [CID_W-1:0] pick_ref(
      input logic [NC-1:0] reqs, input logic [CID_W-1:0] start);
    logic [CID_W-1:0] sel;
    logic found;
    sel   = start;
    found = 1'b0;
    for (int unsigned k = 0; k < NC; k++) begin
      automatic logic [CID_W-1:0] cand;
      cand = CID_W'((int'(start) + k) % NC);
      if (reqs[cand] && !found) begin
        sel   = cand;
        found = 1'b1;
      end
    end
    return sel;
  endfunction
  function automatic logic [CID_W-1:0] pick_slot(
      input logic [NC-1:0] reqs, input logic [CID_W-1:0] start);
    logic [NC-1:0]    ge, hi, lo, hi_bl, lo_bl, pick;
    logic [CID_W-1:0] sel, st;
    st = start;
    if (((NC & (NC - 1)) != 0) && (int'(start) >= NC)) st = CID_W'(int'(start) - NC);
    for (int unsigned i = 0; i < NC; i++) ge[i] = (i >= int'(st));
    hi    = reqs & ge;
    lo    = reqs & ~ge;
    hi_bl = hi << 1;
    lo_bl = lo << 1;
    for (int unsigned l = 1; l < NC; l = l << 1) begin
      hi_bl = hi_bl | (hi_bl << l);
      lo_bl = lo_bl | (lo_bl << l);
    end
`ifdef G6LC_MUT_PICK_RR_EQ
    pick = (|hi) ? (hi & ~hi_bl) : (lo & ~hi_bl);   // negative control
`else
    pick = (|hi) ? (hi & ~hi_bl) : (lo & ~lo_bl);
`endif
    sel  = '0;
    for (int unsigned i = 0; i < NC; i++) if (pick[i]) sel = sel | CID_W'(i);
    return (|reqs) ? sel : start;
  endfunction
  assign ref_o  = pick_ref(reqs_i, start_i);
  assign slot_o = pick_slot(reqs_i, start_i);
endmodule

module tb_g6lc_hub_pick_rr_eq;
  int unsigned checked = 0, bad = 0;
  for (genvar g = 1; g <= 8; g++) begin : gen_nc
    localparam int unsigned W = (g <= 1) ? 1 : $clog2(g);
    logic [g-1:0] reqs; logic [W-1:0] start, r, s;
    pick_rr_forms #(.NC(g)) u (.reqs_i(reqs), .start_i(start), .ref_o(r), .slot_o(s));
    initial begin
      for (int unsigned q = 0; q < (1 << g); q++)
        for (int unsigned st = 0; st < (1 << W); st++) begin
          reqs = g'(q); start = W'(st); #1;
          checked++;
          if (r !== s) begin
            bad++;
            if (bad < 6) $display("FAIL NC=%0d reqs=%b start=%0d ref=%0d slot=%0d", g, reqs, start, r, s);
          end
        end
    end
  end
  initial begin
    #100000;
    if (bad == 0 && checked != 0) $display("HYP8_HUB_PICK_RR_EQ_PASS checked=%0d", checked);
    else $display("HYP8_HUB_PICK_RR_EQ_FAIL checked=%0d bad=%0d", checked, bad);
    $finish;
  end
endmodule
