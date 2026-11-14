// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 r127: exhaustive equivalence of the stb_fwd commit-winner forms at the
// instantiated depths. `ring` is the pre-r127 text (rotate by rd_ptr, highest
// set, popcount(hi-1), pointer add, indexed cbo.zero read); `slot` is the
// r127 text (pointer thermometer split, two downward prefix-OR isolates,
// OR-encoded index, one-hot cbo.zero read). Every (candidates, rd_ptr,
// cboz) value is compared: 2^D * D * 2^D cases per depth.
module cwin_forms #(parameter int unsigned D = 8) (
    input  logic [D-1:0]         cand_i, cboz_i,
    input  logic [$clog2(D)-1:0] ptr_i,
    output logic                 any_ring_o, cboz_ring_o, any_slot_o, cboz_slot_o,
    output logic [$clog2(D)-1:0] win_ring_o, win_slot_o
);
  localparam int unsigned CW2 = $clog2(D);
  // ---- pre-r127 ----
  logic [D-1:0] rf_rot, rf_above, rf_hi;
  for (genvar k = 0; k < D; k++) begin : gen_rf_rot
    assign rf_rot[k] = cand_i[ptr_i + CW2'(k)];
  end
  always_comb begin
    rf_above = rf_rot >> 1;
    for (int unsigned l = 1; l < D; l = l << 1) rf_above = rf_above | (rf_above >> l);
  end
  assign rf_hi       = rf_rot & ~rf_above;
  assign any_ring_o  = |rf_rot;
  assign win_ring_o  = ptr_i + CW2'($countones(rf_hi - D'(1)));
  assign cboz_ring_o = any_ring_o && cboz_i[win_ring_o];
  // ---- r127 ----
  logic [D-1:0] cmt_below, c_lo, c_hi, lo_ab, hi_ab, cwin_oh;
  logic [CW2-1:0] cwin_enc;
  for (genvar s = 0; s < D; s++) begin : gen_cmt_below
    assign cmt_below[s] = (CW2'(s) < ptr_i);
  end
  assign c_lo = cand_i & cmt_below;
  assign c_hi = cand_i & ~cmt_below;
  always_comb begin
    lo_ab = c_lo >> 1;
    hi_ab = c_hi >> 1;
    for (int unsigned l = 1; l < D; l = l << 1) begin
      lo_ab = lo_ab | (lo_ab >> l);
      hi_ab = hi_ab | (hi_ab >> l);
    end
  end
  assign cwin_oh = (|c_lo) ? (c_lo & ~lo_ab) : (c_hi & ~hi_ab);
  for (genvar j = 0; j < CW2; j++) begin : gen_cwin_enc
    logic [D-1:0] m;
    for (genvar s = 0; s < D; s++) begin : gen_m
      if (((s >> j) & 1) != 0) begin : gen_set
        assign m[s] = cwin_oh[s];
      end else begin : gen_clr
        assign m[s] = 1'b0;
      end
    end
    assign cwin_enc[j] = |m;
  end
  assign any_slot_o  = |cand_i;
  assign win_slot_o  = any_slot_o ? cwin_enc : ptr_i;
  assign cboz_slot_o = |(cwin_oh & cboz_i);
endmodule

module tb_g6lc_hyp8_cwin_eq;
  int unsigned checked = 0, bad = 0;
  for (genvar g = 0; g < 2; g++) begin : gen_d
    localparam int unsigned D = (g == 0) ? 4 : 8;
    logic [D-1:0] cand, cboz; logic [$clog2(D)-1:0] ptr, wr, ws; logic ar, zr, as, zs;
    cwin_forms #(.D(D)) u (.cand_i(cand), .cboz_i(cboz), .ptr_i(ptr), .any_ring_o(ar),
                           .cboz_ring_o(zr), .any_slot_o(as), .cboz_slot_o(zs),
                           .win_ring_o(wr), .win_slot_o(ws));
    initial begin
      for (int unsigned c = 0; c < (1 << D); c++)
        for (int unsigned p = 0; p < D; p++)
          for (int unsigned z = 0; z < (1 << D); z++) begin
            cand = D'(c); ptr = $clog2(D)'(p); cboz = D'(z); #1;
            checked++;
            if (ar !== as || wr !== ws || zr !== zs) begin
              bad++;
              if (bad < 6) $display("FAIL D=%0d cand=%b ptr=%0d cboz=%b ring=%b/%0d/%b slot=%b/%0d/%b",
                                    D, cand, ptr, cboz, ar, wr, zr, as, ws, zs);
            end
          end
    end
  end
  initial begin
    #2000000;
    if (bad == 0 && checked == (16*4*16 + 256*8*256)) $display("HYP8_CWIN_EQ_PASS checked=%0d", checked);
    else $display("HYP8_CWIN_EQ_FAIL checked=%0d bad=%0d", checked, bad);
    $finish;
  end
endmodule
