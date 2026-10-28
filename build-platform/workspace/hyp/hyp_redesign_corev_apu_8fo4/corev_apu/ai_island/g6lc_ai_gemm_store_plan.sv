// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One C-store plan owns the cursor until its B response. Capture committed
// credit, limit/stripe in parallel, then publish a stable burst descriptor.
module g6lc_ai_gemm_store_plan #(
  parameter int unsigned AddrWidth = 64,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned NrChannels = 1,
  parameter int unsigned ChanShift = 6,
  parameter int unsigned MaxBurstBeats = 16,
  parameter int unsigned ShiftW = 1
) (
  input logic clk_i, rst_ni,
  input logic job_start_i,
  input logic [AddrWidth-1:0] base_i,
  input logic [31:0] pitch_words_i,
  input logic request_i, retire_i, retire_row_i,
  input logic [15:0] retire_words_i,
  input logic [31:0] n_i, column_i, committed_i,
  input logic row_complete_i, pair_i, wide_i,
  input logic [ShiftW-1:0] word_shift_i,
  output logic valid_o,
  output logic [AddrWidth-1:0] addr_o,
  output logic [31:0] beats_o
);
  typedef enum logic [2:0] {IDLE, CREDIT, LIMITS, PUBLISH, HOLD} phase_t;
  phase_t phase_q;
  logic [AddrWidth-1:0] address_q, row_base_q, stride_q;
  logic [31:0] remaining_q, committed_q, beat_limit_q, stripe_limit_q;
  logic [ShiftW-1:0] shift_q;
  logic row_complete_q, pair_q, wide_q;
  logic [31:0] credit_words, credit_beats_q, stripe_beats_q;
  assign addr_o = address_q;
  assign valid_o = phase_q == HOLD;
  assign credit_words = row_complete_q || remaining_q < committed_q ? remaining_q : committed_q;
  // r21: beats left in the DRAM stripe from the stripe offset, in the width
  // of the stripe: 2^(C-s) - ceil(offset / 2^s) for each constant beat size,
  // selected by the captured beat width. Equal to
  // ((1 << ChanShift) - offset) >> s for every offset (bounded witness in
  // analysis/gemm-windows-r20.md); the pair (8-byte) and wide beat sizes
  // are the only two shift amounts the caller can present.
  localparam int unsigned PairShift = 3;
  localparam int unsigned WideShift = $clog2(DataWidth / 8);
  logic [31:0] stripe_offset, stripe_pair, stripe_wide;
  assign stripe_offset = 32'(address_q) & ((32'd1 << ChanShift) - 32'd1);
  if (ChanShift > PairShift) begin : gen_stripe_pair
    assign stripe_pair = (32'd1 << (ChanShift - PairShift)) -
        (stripe_offset >> PairShift) - 32'(|stripe_offset[PairShift-1:0]);
  end else begin : gen_stripe_pair_unit
    assign stripe_pair = 32'(stripe_offset == 0 && ChanShift == PairShift);
  end
  if (ChanShift > WideShift) begin : gen_stripe_wide
    assign stripe_wide = (32'd1 << (ChanShift - WideShift)) -
        (stripe_offset >> WideShift) - 32'(|stripe_offset[WideShift-1:0]);
  end else begin : gen_stripe_wide_unit
    assign stripe_wide = 32'(stripe_offset == 0 && ChanShift == WideShift);
  end
  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      stripe_pair == (((32'd1 << ChanShift) - stripe_offset) >> PairShift) &&
      stripe_wide == (((32'd1 << ChanShift) - stripe_offset) >> WideShift));
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin address_q <= '0; row_base_q <= '0; stride_q <= '0; end
    else if (job_start_i) begin
      address_q <= base_i; row_base_q <= base_i;
      stride_q <= AddrWidth'(pitch_words_i) << 2;
    end else if (retire_i) begin
      address_q <= retire_row_i ? row_base_q + stride_q :
          address_q + (AddrWidth'(retire_words_i) << 2);
      if (retire_row_i) row_base_q <= row_base_q + stride_q;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      remaining_q <= '0; committed_q <= '0;
      row_complete_q <= 1'b0; pair_q <= 1'b0; wide_q <= 1'b0; shift_q <= '0;
    end else if (phase_q == IDLE && request_i && !job_start_i) begin
      remaining_q <= n_i - column_i;
      committed_q <= committed_i - column_i;
      row_complete_q <= row_complete_i; pair_q <= pair_i;
      wide_q <= wide_i; shift_q <= word_shift_i;
    end
  end
  // CREDIT selects the credit and converts it to beats while the stripe count
  // forms from the stable address; LIMITS only clamps both.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) credit_beats_q <= '0;
    else if (phase_q == CREDIT) credit_beats_q <= credit_words >> shift_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) stripe_beats_q <= '0;
    else if (phase_q == CREDIT) stripe_beats_q <= wide_q ? stripe_wide : stripe_pair;
  end
  // One register per process: the two clamps are independent.
  logic credit_over, stripe_zero, stripe_over;
  assign credit_over = credit_beats_q > 32'(MaxBurstBeats);
  assign stripe_zero = stripe_beats_q == 32'd0;
  assign stripe_over = stripe_beats_q > 32'd255;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) beat_limit_q <= '0;
    else if (phase_q == LIMITS)
      beat_limit_q <= credit_over ? 32'(MaxBurstBeats) : credit_beats_q;
  end
  if (NrChannels <= 1) begin : gen_single_channel
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) stripe_limit_q <= '0;
      else if (phase_q == LIMITS) stripe_limit_q <= 32'd255;
    end
  end else begin : gen_striped
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) stripe_limit_q <= '0;
      else if (phase_q == LIMITS)
        stripe_limit_q <= ({32{stripe_zero}} & 32'd1) | ({32{stripe_over}} & 32'd255) |
                          ({32{!stripe_zero && !stripe_over}} & stripe_beats_q);
    end
  end
  logic unit_burst, beat_lt_stripe;
  assign unit_burst = !pair_q || beat_limit_q == 32'd0;
  assign beat_lt_stripe = beat_limit_q < stripe_limit_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) beats_o <= '0;
    else if (phase_q == PUBLISH)
      beats_o <= ({32{unit_burst}} & 32'd1) |
                 ({32{!unit_burst && beat_lt_stripe}} & beat_limit_q) |
                 ({32{!unit_burst && !beat_lt_stripe}} & stripe_limit_q);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) phase_q <= IDLE;
    else if (job_start_i) phase_q <= IDLE;
    else begin
      unique case (phase_q)
        IDLE: if (request_i) phase_q <= CREDIT;
        CREDIT: phase_q <= LIMITS;
        LIMITS: phase_q <= PUBLISH;
        PUBLISH: phase_q <= HOLD;
        HOLD: if (retire_i) phase_q <= IDLE;
        default: phase_q <= IDLE;
      endcase
    end
  end
  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni) retire_i |-> valid_o);
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      valid_o && !retire_i && !job_start_i |=> $stable({addr_o, beats_o}) || job_start_i);
  // pragma translate_on
endmodule
