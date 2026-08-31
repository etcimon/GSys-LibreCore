// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: redirect priority contract (I8, I4y) over the pure
// functions of `g6lc_fetch_pkg`. Self-contained: no frontend elaboration.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_redirect.sby
//      cva6-build verify --formal

module g6lc_fetch_redirect_props (
    input logic       clk_i,
    input logic       rst_ni,
    input logic       en_restore,
    input logic       restore,
    input logic       debug_en,
    input logic       commit,
    input logic       ex,
    input logic       eret,
    input logic       misp,
    input logic       en_smt,
    input logic [7:0] commit_hart,
    input logic [7:0] active_hart,
    input logic       bp_pend,
    input logic       bp_same,
    input logic       ftq,
    input logic       pend,
    input logic       lost,
    input logic       hit
);

`ifdef FORMAL
  import g6lc_fetch_pkg::*;

  logic [3:0] sel;
  logic [6:0] sel_hit;
  logic [3:0] sel_cnt;
  logic       any_src;
  logic       cfh;
  logic       ret_ok;
  logic       rehold;

  always_comb begin
    sel     = arch_src_sel(en_restore, restore, debug_en, commit, ex, eret, misp);
    any_src = ex || eret || commit || debug_en || (en_restore && restore) || misp;
    cfh     = commit_for_hart(en_smt, commit, commit_hart, active_hart);
    ret_ok  = bp_ret_ok(bp_pend, bp_same);
    rehold  = redirect_rehold(ftq, pend, lost, hit);
  end

  always_comb begin
    sel_hit[0] = (sel == SRC_NONE);
    sel_hit[1] = (sel == SRC_EX);
    sel_hit[2] = (sel == SRC_DEBUG);
    sel_hit[3] = (sel == SRC_ERET);
    sel_hit[4] = (sel == SRC_COMMIT);
    sel_hit[5] = (sel == SRC_RESTORE);
    sel_hit[6] = (sel == SRC_MISP);
    sel_cnt    = 4'd0;
    for (int unsigned s = 0; s < 7; s++) begin
      if (sel_hit[s]) sel_cnt = sel_cnt + 4'd1;
    end
  end

  // BMC/prove: start from a forced reset (no free-state induction trap).
  initial assume (!rst_ni);

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // I8: the encoder is a total order — exactly one source id, always.
      assert (sel_cnt == 4'd1);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (ex) assert (sel == SRC_EX);
      if (!ex && eret) assert (sel == SRC_ERET);
      if (!ex && !eret && commit) assert (sel == SRC_COMMIT);
      if (!ex && !eret && !commit && debug_en) assert (sel == SRC_DEBUG);
      // I4y: an SMT restore never outranks an exception entry.
      if (ex && restore) assert (sel == SRC_EX);
      // en.restore const-fold is honoured.
      if (!en_restore) assert (sel != SRC_RESTORE);
      // Idle iff no source asserts, restore counted only when enabled.
      assert ((sel == SRC_NONE) == !any_src);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (!en_smt) assert (cfh == commit);
      if (en_smt && cfh) assert (commit && (commit_hart == active_hart));
      if (!bp_pend) assert (ret_ok);
      if (rehold) assert (!ftq);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (sel == SRC_NONE);
      cover (sel == SRC_EX);
      cover (sel == SRC_DEBUG);
      cover (sel == SRC_ERET);
      cover (sel == SRC_COMMIT);
      cover (sel == SRC_RESTORE);
      cover (sel == SRC_MISP);
    end
  end
`endif

endmodule
