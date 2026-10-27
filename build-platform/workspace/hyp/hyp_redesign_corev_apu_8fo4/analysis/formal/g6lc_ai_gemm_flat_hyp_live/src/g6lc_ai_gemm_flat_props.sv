// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: the AI island GEMM sequencer's flat-panel operand mapping,
// stripe-capped bursts and resident-B slot placement, over the pure functions
// of g6lc_ai_island_cfg_pkg that g6lc_ai_gemm_seq's address paths call.
//
// These are the contracts whose violation surfaces far away (a wrong C word, an
// AXI burst parked on the wrong DRAM channel, a slot overwriting its neighbour)
// and which the 8-lane backend bench samples only at its own geometry. The .sby
// sweeps the two geometries in use: lane shift 3 (8-lane bench) and 9 (the live
// 512-lane island), with the bench and live bank sizes. Everything here is
// combinational, so depth 1 is exhaustive over the constrained inputs.
//
// Run: sby -f corev_apu/ai_island/formal/g6lc_ai_gemm_flat.sby
//      cva6-build verify --formal

module g6lc_ai_gemm_flat_props #(
    parameter int unsigned LS    = 3,      // lane shift: log2(PeLanes bytes per bank word)
    parameter int unsigned WORDS = 2048,   // operand bank words (OperandWordsB)
    parameter int unsigned SLOTS = 2,      // resident-B directory depth
    parameter int unsigned BPB   = 8,      // AXI bytes per beat
    parameter int unsigned EPBS  = 3,      // log2(elements absorbed per beat)
    parameter int unsigned NCH   = 2,      // DRAM channels (stripe test needs > 1)
    parameter int unsigned CSH   = 6       // DramChanShift
) (
    input logic        clk_i,
    input logic        rst_ni,
    input logic [31:0] k_bytes,
    input logic [31:0] rows,
    input logic [31:0] row,
    input logic [31:0] t,
    input logic [31:0] rem,
    input logic [31:0] lane0,
    input logic [63:0] addr,
    input logic [7:0]  nb,
    input logic [31:0] n_slot
);

`ifdef FORMAL
  import g6lc_ai_island_cfg_pkg::*;

  localparam int unsigned SlotWords = WORDS / SLOTS;
  localparam int unsigned MaxBeats  = 255;

  int unsigned pitch;
  logic [63:0] last_word, first_next, row_end;
  int unsigned beats, capped, stripe_max;

  always_comb begin
    pitch      = ai_flat_pitch_shift(k_bytes, LS);
    last_word  = ai_flat_row_word(row, pitch, t, LS);
    row_end    = ai_flat_row_word(row, pitch, k_bytes - 32'd1, LS);
    first_next = ai_flat_row_word(row + 32'd1, pitch, 32'd0, LS);
    beats      = ai_beats_for_rem(rem, lane0, BPB, EPBS, MaxBeats);
    stripe_max = dram_beats_in_stripe(NCH, CSH, BPB, addr);
    capped     = (32'(nb) > stripe_max) ? stripe_max : 32'(nb);
  end

  // Envelope: k up to the 16-bit lda/ldb box at 4 bytes per element; rows and
  // the probed row inside the operand box; t inside the row; lane inside a beat.
  always_comb begin
    assume (k_bytes >= 32'd1 && k_bytes <= 32'd65535 * 32'd4);
    assume (rows >= 32'd1 && rows <= 32'(WORDS));
    assume (row < rows);
    assume (t < k_bytes);
    assume (lane0 < 32'(BPB));
    // `rem` is the bytes left in the row (k_bytes - t): the caller's domain.
    assume (rem <= k_bytes);
    assume (nb >= 8'd1);
    // Burst start addresses are beat-aligned (A/B: beat_align; C: 8-byte pairs). Without
    // this the stripe function's "never 0 beats" floor can straddle by construction --
    // an envelope statement, and the reason the sequencer aligns before it caps.
    assume ((addr & 64'(BPB - 1)) == 64'd0);
    assume (n_slot >= 32'd1);
  end

  // F1  A row fits its pitch: the last byte of a row lands below the next row's base.
  always_comb assert (64'(k_bytes - 32'd1) >> LS < (64'd1 << pitch));

  // F2  If the panel fits the bank at this pitch, no byte of any of its rows
  //     addresses a word outside the bank.
  always_comb if (ai_flat_fits(rows, pitch, WORDS)) assert (last_word < 64'(WORDS));

  // F3  Rows never overlap: the end of row r is strictly below the start of r+1.
  always_comb assert (row_end < first_next);

  // F4  The pitch is minimal among powers of two (no more than 2x slack): half the
  //     pitch could not hold the row.
  always_comb if (pitch > 0) assert (((k_bytes + (32'd1 << LS) - 32'd1) >> LS) > (32'd1 << (pitch - 1)));

  // F5  Burst length: at least one beat, at most the cap, and when not capped the
  //     beats carry the remaining bytes (first partial beat + full beats).
  always_comb begin
    assert (beats >= 1 && beats <= MaxBeats);
    if (rem != 0 && beats < MaxBeats)
      assert (((32'(BPB) - lane0) > rem ? rem : (32'(BPB) - lane0)) + ((beats - 1) << EPBS) >= rem);
  end

  // F6  Stripe cap: a capped burst never crosses a 2^CSH DRAM channel stripe.
  always_comb if (NCH > 1) assert ((addr[31:0] & ((32'd1 << CSH) - 32'd1)) + capped * BPB <= (32'd1 << CSH));

  // F7  Slot placement: a small panel in slot s ends at or before slot s+1's base
  //     and inside the bank; slot bases are disjoint and increasing.
  always_comb begin
    if (ai_slot_small(n_slot, pitch, SlotWords)) begin
      for (int unsigned s = 0; s < SLOTS; s++)
        assert (ai_slot_base(s, SlotWords) + (64'(n_slot) << pitch) <= ai_slot_base(s + 1, SlotWords));
      assert (ai_slot_base(SLOTS - 1, SlotWords) + (64'(n_slot) << pitch) <= 64'(WORDS));
    end
  end
`endif

endmodule
