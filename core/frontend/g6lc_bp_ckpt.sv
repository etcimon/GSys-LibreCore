// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// FSE S2 / U1 prediction checkpoint FIFO: GHR + full RAS stack snapshot so a
// mispredict can restore control-flow prediction state. Circular buffer.
// Prerequisite for U4/U5/FSE recovery.
//
// Push happens at PREDICT time: one entry per control-flow instruction slot
// actually consumed by the instruction queue, so the head entry always belongs
// to the oldest in-flight CF and each resolve pops exactly its own snapshot.
// The snapshot is the prediction-time context (fetch-hart GHR + RAS stack),
// which is what the update fold and RAS restore need.
//
// FSE S5: the FIFO is banked per hart; pushes go to the fetch hart's bank and
// pop/restore read the resolving hart's bank. A hart's instructions fetch and
// resolve on the same hart, so the association stays 1:1. NrHarts==1 is
// identity (single FIFO).
//
// Conservation: count_q tracks pushes minus pops exactly. A mispredict
// (restore_i) consumes the head and drops every younger entry — those pushes
// came from wrong-path fetches and must never be popped by a later resolve.
// Overflow refuses the tail pushes and raises desync_o until the bank drains:
// with a dropped entry the FIFO can no longer guarantee head==resolving-CF, so
// restore_valid_o stays low and the caller falls back instead of restoring a
// shifted context.

module g6lc_bp_ckpt
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned GHIST_LEN = 24,
    parameter int unsigned DEPTH = 8,
    // RAS stack depth (0 → GHR-only checkpoints, RAS fields ignored)
    parameter int unsigned RAS_DEPTH = 0,
    parameter int unsigned RAS_VLEN = 64,
    // CF slots that may push in one cycle (fetch width)
    parameter int unsigned NR_PUSH = 2
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic                 flush_i,
    // FSE S5: fetch hart whose bank accepts pushes; resolve hart whose bank
    // supplies pop/restore (ignored when NrHarts==1)
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] push_hart_i,
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] pop_hart_i,
    // Push one checkpoint per consumed CF slot (predict time)
    input  logic [NR_PUSH-1:0]   push_i,
    input  logic [GHIST_LEN-1:0] push_ghist_i,
    // Full RAS stack snapshot at push (ignored when RAS_DEPTH==0)
    input  logic [RAS_DEPTH == 0 ? 0 : RAS_DEPTH-1:0]                 push_ras_valid_i,
    input  logic [RAS_DEPTH == 0 ? 0 : RAS_DEPTH-1:0][RAS_VLEN-1:0]    push_ras_ra_i,
    // Pop on CF resolution (one per cycle); restore_i additionally drops all
    // younger entries (mispredict: everything pushed after the head's CF came
    // from the wrong path).
    input  logic                 pop_i,
    input  logic                 restore_i,
    // Head entry: the resolving branch's own prediction-time snapshot.
    output logic [GHIST_LEN-1:0] restore_ghist_o,
    output logic [RAS_DEPTH == 0 ? 0 : RAS_DEPTH-1:0]              restore_ras_valid_o,
    output logic [RAS_DEPTH == 0 ? 0 : RAS_DEPTH-1:0][RAS_VLEN-1:0] restore_ras_ra_o,
    output logic                 restore_valid_o,
    output logic                 empty_o,
    output logic                 full_o,
    // Sticky: a push was dropped on a full bank; association can no longer be
    // trusted until the bank drains.
    output logic                 desync_o
);

  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned RD = (RAS_DEPTH < 1) ? 1 : RAS_DEPTH;
  localparam int unsigned NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);
  localparam int unsigned PUSH_CNT_W = (NR_PUSH <= 1) ? 1 : $clog2(NR_PUSH + 1);

  typedef struct packed {
    logic [GHIST_LEN-1:0] ghist;
    logic [RD-1:0] ras_v;
    logic [RD-1:0][RAS_VLEN-1:0] ras_ra;
  } ckpt_t;

  // One circular FIFO per hart when multi-hart; single when NrHarts==1.
  ckpt_t [NH-1:0][DEPTH-1:0] mem_q;
  logic [NH-1:0][PTR_W-1:0] head_q, tail_q;
  logic [NH-1:0][PTR_W:0] count_q;  // 0..DEPTH
  logic [NH-1:0]            desync_q;

  logic [HID_W-1:0] psel, csel;
  assign psel = push_hart_i[HID_W-1:0];
  assign csel = pop_hart_i[HID_W-1:0];

  logic [PUSH_CNT_W-1:0] push_cnt;
  always_comb begin
    push_cnt = '0;
    for (int unsigned k = 0; k < NR_PUSH; k++) push_cnt += PUSH_CNT_W'(push_i[k]);
  end

  assign empty_o  = (count_q[csel] == '0);
  assign full_o   = (count_q[csel] == DEPTH[PTR_W:0]);
  assign desync_o = desync_q[csel];
  // Head of the resolve bank is the resolving CF's prediction-time snapshot.
  assign restore_ghist_o = mem_q[csel][head_q[csel]].ghist;
  // Restore (mispredict) only when the association is trustworthy: a live head
  // and no dropped pushes. The caller falls back when this is low. Ordinary
  // pops do not qualify — the head entry still feeds the update-fold source
  // through empty_o/desync_o regardless.
  assign restore_valid_o = restore_i && !empty_o && !desync_q[csel];

  if (RAS_DEPTH == 0) begin : gen_no_ras
    assign restore_ras_valid_o = '0;
    assign restore_ras_ra_o    = '0;
  end else begin : gen_ras
    assign restore_ras_valid_o = mem_q[csel][head_q[csel]].ras_v;
    assign restore_ras_ra_o    = mem_q[csel][head_q[csel]].ras_ra;
  end

  // Next-state bookkeeping. Resolve-side drain first, then the push bank, so
  // a same-bank restore also suppresses the push: a window consumed on the
  // mispredict cycle is wrong-path and its CFs never resolve.
  logic [NH-1:0][PTR_W-1:0] head_d, tail_d;
  logic [NH-1:0][PTR_W:0]   count_d;
  logic [NH-1:0]            desync_d;
  logic [PUSH_CNT_W-1:0]    n_push;
  logic [PTR_W:0]           tail_plus;
  logic                     push_en;

  always_comb begin
    head_d   = head_q;
    tail_d   = tail_q;
    count_d  = count_q;
    desync_d = desync_q;
    n_push   = '0;
    tail_plus = '0;
    // Resolve bank: restore consumes the head and drops every younger
    // (wrong-path) entry; pop consumes only the head.
    if (restore_i && count_q[csel] != '0) begin
      head_d[csel]  = (head_q[csel] == PTR_W'(DEPTH - 1)) ? '0 : head_q[csel] + PTR_W'(1);
      tail_d[csel]  = (head_q[csel] == PTR_W'(DEPTH - 1)) ? '0 : head_q[csel] + PTR_W'(1);
      count_d[csel] = '0;
    end else if (pop_i && count_q[csel] != '0) begin
      head_d[csel]  = (head_q[csel] == PTR_W'(DEPTH - 1)) ? '0 : head_q[csel] + PTR_W'(1);
      count_d[csel] = count_q[csel] - (PTR_W+1)'(1);
    end
    // A drained bank re-establishes association: clear desync.
    if (restore_i) desync_d[csel] = 1'b0;
    // Push bank: same-cycle drain on this bank frees space first. The space
    // comparison runs in the PTR_W+1 domain — DEPTH does not fit PUSH_CNT_W.
    push_en = (push_cnt != '0) && !(restore_i && psel == csel);
    if (push_en) begin
      if ((PTR_W+1)'(push_cnt) <= DEPTH[PTR_W:0] - count_d[psel]) n_push = push_cnt;
      else begin
        n_push = PUSH_CNT_W'(DEPTH[PTR_W:0] - count_d[psel]);
        desync_d[psel] = 1'b1;
      end
      tail_plus     = (PTR_W+1)'(tail_d[psel]) + (PTR_W+1)'(n_push);
      tail_d[psel]  = (tail_plus >= DEPTH[PTR_W:0]) ? PTR_W'(tail_plus - DEPTH[PTR_W:0])
                                                  : PTR_W'(tail_plus);
      count_d[psel] = count_d[psel] + (PTR_W+1)'(n_push);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q   <= '0;
      tail_q   <= '0;
      count_q  <= '0;
      desync_q <= '0;
      mem_q    <= '0;
    end else begin
      if (flush_i) begin
        // Flush drops the fetch-side bank's in-flight checkpoints.
        head_q[psel]   <= '0;
        tail_q[psel]   <= '0;
        count_q[psel]  <= '0;
        desync_q[psel] <= 1'b0;
      end else begin
        head_q   <= head_d;
        tail_q   <= tail_d;
        count_q  <= count_d;
        desync_q <= desync_d;
      end
      // Entry writes are independent of the pointer bookkeeping: writes are
      // idempotent (same payload for every slot pushed in a window) and a
      // dropped push only leaves a stale cell that count_q never exposes.
      // The index wraps modulo DEPTH; tail_q < DEPTH and k < NR_PUSH <= DEPTH,
      // so a single conditional subtract is exact.
      if (push_en) begin
        for (int unsigned k = 0; k < NR_PUSH; k++) begin
          if (PUSH_CNT_W'(k) < n_push) begin
            automatic int unsigned widx = int'(tail_q[psel]) + k;
            if (widx >= DEPTH) widx -= DEPTH;
            mem_q[psel][widx[PTR_W-1:0]] <=
                '{ghist: push_ghist_i, ras_v: push_ras_valid_i, ras_ra: push_ras_ra_i};
          end
        end
      end
    end
  end

endmodule
