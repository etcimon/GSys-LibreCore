// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright (c) 2026 Etienne Cimon
//
// g6lc_ai_gemm_arplan — AR burst planner (r7 R2, caller-purposed segment).
// Owns the issue cursor {row,t} for ONE operand (gemm_seq instantiates one
// per A and B). Plans the next burst three stages ahead into a depth-2
// candidate FIFO so the gemm_seq issue arm only pops
// {addr, len, lane, elems, row_last} — the :2341-class precompute cone
// (beats_for_rem -> stripe cap -> elems_for_burst -> row_last) leaves the
// single-cycle AR issue path entirely.
//
//   S1 (from cursors):  {rem, lane, align_addr, stripe_room}
//   S2:                 {rem_beats -> cap -> nb}
//   S3:                 {elems, row_last, next cursor} -> FIFO push
//
// The cursor advances at every S3 push; a job_start resets it. The FIFO
// keeps up to two planned bursts so an ar_ready stall never leaves the
// issue arm starved.
//
// Timing: S1 registers a few ops (align, lane extract, subtract, stripe
// mask/shift); S2 folds beats_for_rem + cap; S3 folds elems + row_last +
// cursor arithmetic. Each stage is a single always_ff register group.

module g6lc_ai_gemm_arplan #(
    parameter int unsigned AddrWidth   = 64,
    parameter int unsigned BeatAlignW  = 6,   // log2(BytesPerBeat)
    parameter int unsigned BeatLaneW   = 6,   // lane index width into a beat
    parameter int unsigned BytesPerBeat= 64,
    parameter int unsigned ElemsPerBeatShift = 3,
    parameter int unsigned MaxBurstBeats = 16,
    parameter int unsigned NrChannels  = 2,
    parameter int unsigned ChanShift   = 30
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,

    // Job kick: latches the base params and resets the cursor.
    input  logic                  job_start_i,
    input  logic [AddrWidth-1:0]  base_i,      // operand base (pa/pb)
    input  logic [31:0]           ld_i,        // row stride in elements
    input  logic [31:0]           rows_i,      // m (A) or n (B)
    input  logic [31:0]           k_bytes_i,   // row length in bytes
    input  logic [2:0]            numfmt_i,

    // Candidate FIFO pop (gemm_seq fires + accepts an AR).
    input  logic                  pop_i,

    // Planned burst out.
    output logic                  plan_valid_o,
    output logic [AddrWidth-1:0]  plan_addr_o,
    output logic [7:0]            plan_nb_o,      // beats in this AR
    output logic [BeatLaneW-1:0]  plan_lane_o,
    output logic [31:0]           plan_elems_o,
    output logic                  plan_row_last_o,
    output logic                  done_o,        // cursor exhausted, FIFO empty
    // Cursor mirror for the caller's bookkeeping (AR slot row/col, miters).
    output logic [31:0]           cur_row_o,
    output logic [31:0]           cur_t_o
);
  import g6lc_ai_island_cfg_pkg::*;

  // ---------------------------------------------------------------- helpers
  function automatic logic [AddrWidth-1:0] beat_align(input logic [AddrWidth-1:0] a);
    return {a[AddrWidth-1:BeatAlignW], BeatAlignW'(0)};
  endfunction
  function automatic logic [AddrWidth-1:0] row_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] row, input logic [31:0] t,
      input logic [31:0] ld);
    return base + AddrWidth'(row) * AddrWidth'(ld) + AddrWidth'(t);
  endfunction
  function automatic logic [7:0] beats_for_rem(
      input logic [31:0] rem, input logic [BeatLaneW-1:0] lane0);
    return 8'(g6lc_ai_island_cfg_pkg::ai_beats_for_rem(
        rem, 32'(lane0), BytesPerBeat, ElemsPerBeatShift, MaxBurstBeats));
  endfunction
  function automatic logic [31:0] elems_for_burst(
      input logic [31:0] rem, input logic [BeatLaneW-1:0] lane0,
      input logic [7:0] nb);
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

  // ---------------------------------------------------------------- job regs
  logic [AddrWidth-1:0] base_q;
  logic [31:0]          ld_q, rows_q, k_bytes_q;
  logic [4:0]           elem_shift_q;
  logic [31:0]          cur_row_q, cur_t_q;

  // ---------------------------------------------------------------- cursor wire
  logic [AddrWidth-1:0] cur_addr;
  assign cur_addr = row_addr(base_q, cur_row_q, cur_t_q, ld_q);

  // ---------------------------------------------------------------- S1: cheap terms
  logic [AddrWidth-1:0] s1_addr_q;
  logic [BeatLaneW-1:0] s1_lane_q;
  logic [31:0]          s1_rem_q;
  logic [7:0]           s1_room_q;
  logic [31:0]          s1_row_q, s1_t_q;
  logic                 s1_vld_q;

  // ---------------------------------------------------------------- S2a: beats_for_rem
  logic [AddrWidth-1:0] s2a_addr_q;
  logic [BeatLaneW-1:0] s2a_lane_q;
  logic [31:0]          s2a_rem_q;
  logic [7:0]           s2a_room_q, s2a_rem_beats_q;
  logic [31:0]          s2a_row_q, s2a_t_q;
  logic                 s2a_vld_q;

  // ---------------------------------------------------------------- S2b: cap -> nb
  logic [AddrWidth-1:0] s2_addr_q;
  logic [BeatLaneW-1:0] s2_lane_q;
  logic [31:0]          s2_rem_q;
  logic [7:0]           s2_nb_q;
  logic [31:0]          s2_row_q, s2_t_q;
  logic                 s2_vld_q;

  // ---------------------------------------------------------------- S3: elems/row_last register stage
  // r8 R2c: S3 is a real register stage (was a comb folded into the
  // FIFO push) -- the post-push cursor feeds S1's launch with one add
  // instead of the full elems_for_burst chain.
  logic [31:0]          s3_elems_q;
  logic                 s3_row_last_q;
  logic [AddrWidth-1:0] s3_addr_q;
  logic [BeatLaneW-1:0] s3_lane_q;
  logic [7:0]           s3_nb_q;
  logic [31:0]          s3_row_q, s3_t_q;
  logic                 s3_vld_q;
  logic [31:0]          s3_elems_w;
  logic                 s3_row_last_w;
  assign s3_elems_w    = elems_for_burst(s2_rem_q, s2_lane_q, s2_nb_q);
  assign s3_row_last_w = s3_elems_w >= s2_rem_q;

  // ---------------------------------------------------------------- depth-2 candidate FIFO
  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic [7:0]           nb;
    logic [BeatLaneW-1:0] lane;
    logic [31:0]          elems;
    logic                 row_last;
    logic [31:0]          row, t;
  } plan_t;
  plan_t fifo_q [2];
  logic [1:0] fifo_depth_q;
  wire        fifo_push = s3_vld_q && (fifo_depth_q < 2);
  wire        fifo_pop  = pop_i && (fifo_depth_q != 0);

  // Launch discipline: S1 captures a new cursor sample only when the
  // downstream stages will be empty next cycle OR when the S2 plan is
  // pushing this cycle (launch on the drain edge, sampling the
  // post-push cursor) -- the cursor is shared state, so two in-flight
  // samples would plan the same burst twice (the r8 diag's row=1 t=0
  // pin). S3 is folded into the push: the elems/row_last wire IS the
  // S3 comb of the S2 registers, so the next cursor is known at the
  // push edge.
  wire s3_ready   = !s3_vld_q || fifo_push;
  wire s2_ready   = !s2_vld_q || s3_ready;
  wire s2a_ready  = !s2a_vld_q || s2_ready;
  wire [31:0] post_row = s3_row_last_q ? s3_row_q + 32'd1 : s3_row_q;
  wire [31:0] post_t   = s3_row_last_q ? 32'd0 : s3_t_q + s3_elems_q;
  wire s1_launch  = !s1_vld_q && !s2a_vld_q &&
                    (!s2_vld_q || (fifo_push && (fifo_depth_q < 2))) &&
                    (fifo_push ? (post_row < rows_q) : (cur_row_q < rows_q));
  // Cursor advances at every S3 -> FIFO push.
  wire cursor_advance = fifo_push;

  // ---------------------------------------------------------------- registers
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      base_q <= '0; ld_q <= '0; rows_q <= '0; k_bytes_q <= '0;
      cur_row_q <= '0; cur_t_q <= '0;
    end else if (job_start_i) begin
      base_q <= base_i; ld_q <= ld_i; rows_q <= rows_i; k_bytes_q <= k_bytes_i;
      elem_shift_q <= {3'b0, g6lc_ai_island_cfg_pkg::ai_elem_shift(numfmt_i)};
      cur_row_q <= '0; cur_t_q <= '0;
    end else if (cursor_advance) begin
      // Advance along the row; on row_last go to the next row.
      if (s3_row_last_q) begin
        cur_row_q <= cur_row_q + 32'd1;
        cur_t_q   <= '0;
      end else begin
        cur_t_q <= cur_t_q + s3_elems_q;
      end
    end
  end

  // S1 register group: cheap per-cursor terms.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_addr_q <= '0; s1_lane_q <= '0; s1_rem_q <= '0; s1_room_q <= '0;
      s1_row_q <= '0; s1_t_q <= '0; s1_vld_q <= 1'b0;
    end else begin
      if (job_start_i) begin
        s1_vld_q <= 1'b0;
      end else if (s1_launch) begin
        // r8 R2c: next_addr is derived from the pushed plan's own fields
        // (addr + elems*elemsize, or row_start + ld on a row advance) --
        // NOT row_addr(post_cursor), whose row*ld mul was the deep cone.
        automatic logic [AddrWidth-1:0] addr_s;
        automatic logic [31:0]          row_s, t_s;
        row_s  = fifo_push ? post_row : cur_row_q;
        t_s    = fifo_push ? post_t   : cur_t_q;
        addr_s = s3_row_last_q
               ? (s3_addr_q + AddrWidth'(s3_lane_q) - AddrWidth'(s3_t_q)
                          + AddrWidth'(ld_q))
               : (s3_addr_q + AddrWidth'(s3_lane_q)
                          + AddrWidth'(s3_elems_q << elem_shift_q));
        s1_addr_q <= beat_align(addr_s);
        s1_lane_q <= addr_s[BeatAlignW-1:0];
        s1_rem_q  <= k_bytes_q - t_s;
        s1_room_q <= 8'(g6lc_ai_island_cfg_pkg::dram_beats_in_stripe(
            NrChannels, ChanShift, BytesPerBeat, 64'(beat_align(addr_s))));
        s1_row_q  <= row_s;
        s1_t_q    <= t_s;
        s1_vld_q  <= 1'b1;
      end else if (s2a_ready) begin
        s1_vld_q <= 1'b0;
      end
    end
  end

  // S2a register group: beats_for_rem.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2a_addr_q <= '0; s2a_lane_q <= '0; s2a_rem_q <= '0;
      s2a_room_q <= '0; s2a_rem_beats_q <= '0;
      s2a_row_q <= '0; s2a_t_q <= '0; s2a_vld_q <= 1'b0;
    end else if (job_start_i) begin
      s2a_vld_q <= 1'b0;
    end else if (s2a_ready) begin
      s2a_addr_q      <= s1_addr_q;
      s2a_lane_q      <= s1_lane_q;
      s2a_rem_q       <= s1_rem_q;
      s2a_room_q      <= s1_room_q;
      s2a_rem_beats_q <= beats_for_rem(s1_rem_q, s1_lane_q);
      s2a_row_q       <= s1_row_q;
      s2a_t_q         <= s1_t_q;
      s2a_vld_q       <= s1_vld_q;
    end
  end

  // S2b register group: stripe cap -> nb.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_addr_q <= '0; s2_lane_q <= '0; s2_rem_q <= '0; s2_nb_q <= '0;
      s2_row_q <= '0; s2_t_q <= '0; s2_vld_q <= 1'b0;
    end else if (job_start_i) begin
      s2_vld_q <= 1'b0;
    end else if (s2_ready) begin
      s2_addr_q <= s2a_addr_q;
      s2_lane_q <= s2a_lane_q;
      s2_rem_q  <= s2a_rem_q;
      s2_nb_q   <= (s2a_rem_beats_q > s2a_room_q) ? s2a_room_q : s2a_rem_beats_q;
      s2_row_q  <= s2a_row_q;
      s2_t_q    <= s2a_t_q;
      s2_vld_q  <= s2a_vld_q;
    end
  end

  // S3 register group: elems + row_last + plan fields.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s3_elems_q <= '0; s3_row_last_q <= 1'b0;
      s3_addr_q <= '0; s3_lane_q <= '0; s3_nb_q <= '0;
      s3_row_q <= '0; s3_t_q <= '0; s3_vld_q <= 1'b0;
    end else if (job_start_i) begin
      s3_vld_q <= 1'b0;
    end else if (s3_ready) begin
      s3_elems_q    <= s3_elems_w;
      s3_row_last_q <= s3_row_last_w;
      s3_addr_q     <= s2_addr_q;
      s3_lane_q     <= s2_lane_q;
      s3_nb_q       <= s2_nb_q;
      s3_row_q      <= s2_row_q;
      s3_t_q        <= s2_t_q;
      s3_vld_q      <= s2_vld_q;
    end
  end

  // FIFO register group: depth + two plan slots.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fifo_depth_q <= '0;
      fifo_q[0] <= '0; fifo_q[1] <= '0;
    end else if (job_start_i) begin
      fifo_depth_q <= '0;
      fifo_q[0] <= '0; fifo_q[1] <= '0;
    end else begin
      unique case ({fifo_push, fifo_pop})
        2'b10: begin
          fifo_q[fifo_depth_q] <= '{addr: s3_addr_q, nb: s3_nb_q,
                                    lane: s3_lane_q, elems: s3_elems_q,
                                    row_last: s3_row_last_q,
                                    row: s3_row_q, t: s3_t_q};
          fifo_depth_q <= fifo_depth_q + 2'd1;
        end
        2'b01: begin
          fifo_q[0] <= fifo_q[1];
          fifo_depth_q <= fifo_depth_q - 2'd1;
        end
        2'b11: begin
          if (fifo_depth_q == 2'd1) begin
            fifo_q[0] <= '{addr: s3_addr_q, nb: s3_nb_q,
                          lane: s3_lane_q, elems: s3_elems_q,
                          row_last: s3_row_last_q,
                          row: s3_row_q, t: s3_t_q};
          end else begin
            fifo_q[0] <= fifo_q[1];
            fifo_q[1] <= '{addr: s3_addr_q, nb: s3_nb_q,
                          lane: s3_lane_q, elems: s3_elems_q,
                          row_last: s3_row_last_q,
                          row: s3_row_q, t: s3_t_q};
          end
        end
        default: ;
      endcase
    end
  end

  assign plan_valid_o    = (fifo_depth_q != 0);
  assign plan_addr_o     = fifo_q[0].addr;
  assign plan_nb_o       = fifo_q[0].nb;
  assign plan_lane_o     = fifo_q[0].lane;
  assign plan_elems_o    = fifo_q[0].elems;
  assign plan_row_last_o = fifo_q[0].row_last;
  assign cur_row_o       = fifo_q[0].row;
  assign cur_t_o         = fifo_q[0].t;
  assign done_o          = (cur_row_q >= rows_q) && (fifo_depth_q == 0)
                           && !s1_vld_q && !s2_vld_q;

  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      fifo_pop |-> plan_valid_o);
  // r8 diag: S1/S2/S3 valid transitions + FIFO push/pop trace.
  always_ff @(posedge clk_i) begin
    if (job_start_i)
      $display("[arplan %m] %0t kick rows=%0d k=%0d ld=%0d base=%h",
               $time, rows_i, k_bytes_i, ld_i, base_i);
    if (s1_vld_q)
      $display("[arplan %m] %0t s1 row=%0d t=%0d rem=%0d lane=%0d room=%0d",
               $time, s1_row_q, s1_t_q, s1_rem_q, s1_lane_q, s1_room_q);
    if (fifo_push)
      $display("[arplan %m] %0t push nb=%0d elems=%0d rl=%0d row=%0d t=%0d depth->%0d",
               $time, s3_nb_q, s3_elems_q, s3_row_last_q, s3_row_q, s3_t_q,
               fifo_depth_q + 2'd1);
    if (fifo_pop)
      $display("[arplan %m] %0t pop nb=%0d elems=%0d rl=%0d row=%0d t=%0d depth->%0d",
               $time, fifo_q[0].nb, fifo_q[0].elems, fifo_q[0].row_last,
               fifo_q[0].row, fifo_q[0].t, fifo_depth_q - 2'd1);
  end
  // pragma translate_on
endmodule
