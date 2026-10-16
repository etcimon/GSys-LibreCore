// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Equivalence fixture for the instr_queue push-count rewrite (ALGORITHMS-EXPERTS
// A80 / A91). Both modules copy the production admission cone of
// core/fetch_B/instr_queue.sv verbatim (slot compaction, slot0 leftover,
// overflow gating) and differ only in how `shamt` — the number of FIFOs pushed
// this cycle — is produced:
//
//   old: popcount of `push_instr_fifo` (the end of the cone, serial adds)
//   new: popcount of `valid` (the start of the cone) selected by the three
//        admission outcomes
//
// The new form is exact because `fifo_pos` sets one distinct bit per valid
// slot (slot_fifo ranks are distinct modulo NrFifo), `slot0_pos` is one-hot
// exactly when `valid[0]` holds, and `lo_partial` implies `valid[0]`
// (g6lc_fetch_pkg::leftover_slot0_push). Proved with `sat -verify` over all
// inputs on the builder (see the Part LIII notes).
package iq_shamt_pkg;
  function automatic logic packet_accept(input logic overflow);
    packet_accept = !overflow;
  endfunction
  function automatic logic leftover_slot0_push(
      input logic complete, input logic slot0_v, input logic slot0_full, input logic overflow);
    leftover_slot0_push = complete && slot0_v && !slot0_full && overflow;
  endfunction
endpackage

module iq_shamt_old #(
    parameter int unsigned NrFifo = 4
) (
    input  logic [NrFifo-1:0]         valid,
    input  logic [$clog2(NrFifo)-1:0] idx_is_q,
    input  logic [NrFifo-1:0]         instr_queue_full,
    input  logic                      leftover_complete_i,
    input  logic                      address_overflow,
    output logic [3:0]                shamt
);
  localparam int unsigned IdxW = $clog2(NrFifo);
  typedef logic [IdxW-1:0] fifo_idx_t;
  localparam fifo_idx_t IdxMask = fifo_idx_t'(NrFifo - 1);
  logic [NrFifo-1:0] fifo_pos, slot0_pos, push_instr, push_instr_fifo;
  fifo_idx_t [NrFifo-1:0] slot_fifo;
  logic instr_overflow, slot0_full, lo_partial;
  always_comb begin
    fifo_idx_t rank;
    rank = '0;
    fifo_pos = '0;
    for (int unsigned s = 0; s < NrFifo; s++) begin
      slot_fifo[s] = (idx_is_q + rank) & IdxMask;
      if (valid[s]) begin
        fifo_pos[slot_fifo[s]] = 1'b1;
        rank = rank + 1'b1;
      end
    end
  end
  assign instr_overflow = |(instr_queue_full & fifo_pos);
  assign slot0_pos = {{(NrFifo - 1) {1'b0}}, valid[0]} << idx_is_q;
  assign slot0_full = |(instr_queue_full & slot0_pos);
  assign lo_partial = iq_shamt_pkg::leftover_slot0_push(
      leftover_complete_i, valid[0], slot0_full, instr_overflow);
  assign push_instr = lo_partial ? slot0_pos
      : (fifo_pos & {NrFifo{iq_shamt_pkg::packet_accept(instr_overflow)}});
  assign push_instr_fifo = push_instr
      & {NrFifo{iq_shamt_pkg::packet_accept(address_overflow)}};
  always_comb begin
    shamt = '0;
    for (int unsigned i = 0; i < NrFifo; i++) shamt = shamt + {{3{1'b0}}, push_instr_fifo[i]};
  end
endmodule

module iq_shamt_new #(
    parameter int unsigned NrFifo = 4
) (
    input  logic [NrFifo-1:0]         valid,
    input  logic [$clog2(NrFifo)-1:0] idx_is_q,
    input  logic [NrFifo-1:0]         instr_queue_full,
    input  logic                      leftover_complete_i,
    input  logic                      address_overflow,
    output logic [3:0]                shamt
);
  localparam int unsigned IdxW = $clog2(NrFifo);
  localparam int unsigned ShamtW = $clog2(NrFifo + 1);
  typedef logic [IdxW-1:0] fifo_idx_t;
  localparam fifo_idx_t IdxMask = fifo_idx_t'(NrFifo - 1);
  logic [NrFifo-1:0] fifo_pos, slot0_pos;
  fifo_idx_t [NrFifo-1:0] slot_fifo;
  logic instr_overflow, slot0_full, lo_partial;
  logic [ShamtW-1:0] shamt_n;
  always_comb begin
    fifo_idx_t rank;
    rank = '0;
    fifo_pos = '0;
    for (int unsigned s = 0; s < NrFifo; s++) begin
      slot_fifo[s] = (idx_is_q + rank) & IdxMask;
      if (valid[s]) begin
        fifo_pos[slot_fifo[s]] = 1'b1;
        rank = rank + 1'b1;
      end
    end
  end
  assign instr_overflow = |(instr_queue_full & fifo_pos);
  assign slot0_pos = {{(NrFifo - 1) {1'b0}}, valid[0]} << idx_is_q;
  assign slot0_full = |(instr_queue_full & slot0_pos);
  assign lo_partial = iq_shamt_pkg::leftover_slot0_push(
      leftover_complete_i, valid[0], slot0_full, instr_overflow);
  // Count the window before admission decides; the three outcomes select.
  always_comb begin
    logic [ShamtW-1:0] valid_count;
    valid_count = '0;
    for (int unsigned i = 0; i < NrFifo; i++) valid_count = valid_count + ShamtW'(valid[i]);
    shamt_n = address_overflow ? '0
            : lo_partial       ? ShamtW'(1)
            : instr_overflow   ? '0
            : valid_count;
  end
  assign shamt = 4'(shamt_n);
endmodule
