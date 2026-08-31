// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: leftover / alignment contract (I3, I5) over the pure
// functions of `g6lc_fetch_pkg`. Self-contained: no frontend elaboration.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_align.sby
//      cva6-build verify --formal

module g6lc_fetch_align_props (
    input logic        clk_i,
    input logic        rst_ni,
    input logic        lo_v,
    input logic [15:0] carry_lo,
    input logic [63:0] carry_pc,
    input logic [63:0] addr,
    input logic        start_hw0,
    input logic        valid,
    input logic        kill,
    input logic        flush,
    input logic        replay
);

`ifdef FORMAL
  import g6lc_fetch_pkg::*;

  logic lo_rvi;
  logic next_win;
  logic complete;
  logic pending;
  logic drop;
  logic upd;
  logic retake;

  always_comb begin
    lo_rvi   = rvi_prefix(carry_lo);
    next_win = leftover_next(addr, carry_pc);
    complete = leftover_complete(lo_v, next_win, lo_rvi, start_hw0);
    pending  = leftover_pending(lo_v, complete);
    drop     = leftover_drop(lo_v, complete, valid);
    upd      = leftover_update(flush, valid, kill);
    retake   = leftover_retake(replay, lo_v, next_win);
  end

  // No reset assumption: this module is stateless. Every property below is a
  // combinational implication over free inputs, so there is no initial state
  // for a free-running reset to corrupt. (`initial assume` is also rejected by
  // the slang frontend -- reading a net during design initialization.)

  // Host constraint: the realign stage presents `valid` already qualified by
  // window_accept, so a killed window never reaches the leftover tuple.
  always_ff @(posedge clk_i) begin
    if (rst_ni) assume (!(valid && kill));
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // A completion can only be reported for a carry that is actually held.
      if (complete) assert (lo_v);
      // I5: the carried low halfword is a legal RVI prefix.
      if (complete) assert (carry_lo[1:0] == 2'b11);
      // I3: the completing window is the immediately next halfword.
      if (complete) assert (addr == (carry_pc + 64'd2));
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // I3 drop (negative I4az): complete and drop are mutually exclusive.
      assert (!(drop && complete));
      // A pending carry meeting a valid non-next window is consumed.
      if (lo_v && valid && !complete) assert (drop);
      // A dropped carry always coincides with an accepted window update.
      if (drop) assert (upd);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(pending && complete));
      if (lo_v) assert (pending != complete);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Retake never blocks outside replay; under replay it needs carry+2.
      if (!replay) assert (retake);
      if (replay) assert (retake == (lo_v && next_win));
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (complete);
      cover (drop);
    end
  end
`endif

endmodule
