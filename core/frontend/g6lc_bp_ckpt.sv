// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// FSE S2 / U1 prediction checkpoint buffer: GHR + RAS top-of-stack snapshot so
// a mispredict can restore control-flow prediction state and the update fold
// can address the row the prediction used.
//
// Allocation happens at PREDICT time: one entry per control-flow instruction
// slot actually consumed by the instruction queue, in fetch order (a circular
// allocation pointer). The entry INDEX travels with the instruction
// (branch_predict.ckpt_idx) and comes back with its resolution, so every
// resolve and every restore addresses its own snapshot.
//
// T21: this replaces the order-paired FIFO (push in fetch order, pop one per
// resolve, "head == resolving CF"). That pairing assumed in-order resolution.
// The out-of-order backend resolves a ready younger branch before an older one
// waiting on a load, so the head was routinely another branch's snapshot: the
// TAGE/ITTAGE update folded the wrong history (the tables never converged on
// an always-taken libfdt branch) and a mispredict restored another branch's RAS
// (fdt_next_tag's return mispredicted on 96 % of its executions). Entries left
// behind by a pipeline flush that is not a mispredict (switch, replay) are
// cleared with the bank (clear_i); a resolve whose entry is gone simply falls
// back (no restore, live-history fold).
//
// FSE S5: banks per hart; allocation goes to the fetch hart's bank, resolve
// reads the resolving hart's bank. NrHarts==1 is identity (single bank).
//
// Capacity: span = alloc - head (entries ever allocated and not yet reclaimed
// at the head, holes included). A window whose CFs do not fit is not
// checkpointed (alloc_v_o low; the instructions carry ckpt_v = 0). The head
// advances one freed entry per cycle; a mispredict reclaims everything from
// its own entry on (younger = allocated after it = wrong path).

module g6lc_bp_ckpt
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned GHIST_LEN = 24,
    parameter int unsigned DEPTH = 8,
    // RAS checkpoint field widths (0 → GHR-only checkpoints, RAS fields ignored)
    parameter int unsigned RAS_DEPTH = 0,
    parameter int unsigned RAS_PTR_W = 1,
    parameter int unsigned RAS_CNT_W = 1,
    parameter int unsigned RAS_VLEN = 64,
    // CF slots that may allocate in one cycle (fetch width)
    parameter int unsigned NR_PUSH = 2,
    parameter int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    // Width of the tag carried by the instruction: {epoch, index}. The spare
    // bits above the index hold a per-bank epoch that advances on every
    // reclaim (restore / clear), so a resolve that arrives after its entry was
    // reclaimed and the index reallocated cannot touch the new owner.
    parameter int unsigned TAG_W = IDX_W
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    // flush_bp: drop the fetch hart's bank (exception / fence)
    input  logic                 flush_i,
    // T21: IF-level flush that is not a mispredict (switch, commit replay):
    // the consumed CFs of the fetch hart die unresolved -- drop its bank. The
    // oldest live entry is the prediction context at the restart frontier
    // (every CF between the frontier and it would be an older live entry), so
    // its RAS snapshot is offered for a restore (clear_restore_o): the killed
    // parcels' speculative pushes/pops are undone before they are refetched.
    input  logic                 clear_i,
    output logic                 clear_restore_o,
    output logic [RAS_PTR_W-1:0] clear_ras_tos_o,
    output logic [RAS_CNT_W-1:0] clear_ras_cnt_o,
    output logic [RAS_VLEN-1:0]  clear_ras_top_o,
    // FSE S5: fetch hart whose bank allocates; resolve hart whose bank is read
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] push_hart_i,
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] pop_hart_i,
    // Allocate one checkpoint per consumed CF slot (predict time)
    input  logic [NR_PUSH-1:0]   push_i,
    input  logic [GHIST_LEN-1:0] push_ghist_i,
    input  logic [RAS_PTR_W-1:0] push_ras_tos_i,
    input  logic [RAS_CNT_W-1:0] push_ras_cnt_i,
    input  logic [RAS_VLEN-1:0]  push_ras_top_i,
    // Allocation result for this cycle's slots (index per slot; valid for all
    // pushed slots or none)
    output logic                 alloc_v_o,
    output logic [NR_PUSH-1:0][TAG_W-1:0] alloc_idx_o,
    // Resolve: the resolving CF's own entry (tag carried with the instruction)
    input  logic                 pop_i,
    input  logic                 pop_v_i,
    input  logic [TAG_W-1:0]     pop_idx_i,
    // Mispredict: restore from the resolving CF's entry and reclaim it and
    // every younger entry of that bank
    input  logic                 restore_i,
    // The resolving CF's prediction-time snapshot (valid while its entry lives)
    output logic                 entry_valid_o,
    output logic [GHIST_LEN-1:0] entry_ghist_o,
    output logic [RAS_PTR_W-1:0] entry_ras_tos_o,
    output logic [RAS_CNT_W-1:0] entry_ras_cnt_o,
    output logic [RAS_VLEN-1:0]  entry_ras_top_o,
    // restore_i qualified by a live entry
    output logic                 restore_valid_o,
    output logic                 empty_o,
    output logic                 full_o
);

  localparam int unsigned NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);
  localparam int unsigned PUSH_CNT_W = (NR_PUSH <= 1) ? 1 : $clog2(NR_PUSH + 1);
  // span counters: one bit wider than the index so DEPTH is representable
  localparam int unsigned SPAN_W = IDX_W + 1;
  localparam int unsigned EPOCH_W = (TAG_W > IDX_W) ? TAG_W - IDX_W : 0;
  localparam int unsigned EP_W = (EPOCH_W == 0) ? 1 : EPOCH_W;

  if (TAG_W < IDX_W) begin : gen_err_ckpt_tag_width
    $error("g6lc_bp_ckpt: TAG_W must hold the entry index");
  end

  typedef struct packed {
    logic [GHIST_LEN-1:0] ghist;
    logic [RAS_PTR_W-1:0] ras_tos;
    logic [RAS_CNT_W-1:0] ras_cnt;
    logic [RAS_VLEN-1:0]  ras_top;
    logic [EP_W-1:0]      epoch;
  } ckpt_t;

  ckpt_t [NH-1:0][DEPTH-1:0] mem_q;
  logic  [NH-1:0][DEPTH-1:0] valid_q, valid_d;
  // head: oldest entry not yet reclaimed; alloc: next free. Free-running in
  // SPAN_W bits; the index is the low IDX_W bits.
  logic  [NH-1:0][SPAN_W-1:0] head_q, head_d, alloc_q, alloc_d;
  // per-bank reclaim epoch (carried in the tag above the index)
  logic  [NH-1:0][EP_W-1:0]   epoch_q, epoch_d;
  logic  [IDX_W-1:0]          pop_slot;
  logic  [EP_W-1:0]           pop_epoch;
  assign pop_slot  = pop_idx_i[IDX_W-1:0];
  assign pop_epoch = (EPOCH_W == 0) ? '0 : EP_W'(pop_idx_i >> IDX_W);

  logic [HID_W-1:0] psel, csel;
  assign psel = (NH <= 1) ? '0 : push_hart_i[HID_W-1:0];
  assign csel = (NH <= 1) ? '0 : pop_hart_i[HID_W-1:0];

  function automatic logic [IDX_W-1:0] idx_of(logic [SPAN_W-1:0] p);
    return (DEPTH == (1 << IDX_W)) ? p[IDX_W-1:0] : IDX_W'(p % SPAN_W'(DEPTH));
  endfunction

  // DEPTH is a power of two in every shipped package; the modulo above keeps
  // the generic case correct, the guard keeps the cheap case the shipped one.
  if (DEPTH != (1 << IDX_W)) begin : gen_warn_ckpt_depth
    $warning("g6lc_bp_ckpt: DEPTH is not a power of two; index arithmetic uses a modulo");
  end

  // ---- per-bank occupancy
  logic [NH-1:0][SPAN_W-1:0] span;
  for (genvar h = 0; h < NH; h++) begin : gen_span
    assign span[h] = alloc_q[h] - head_q[h];
  end
  assign empty_o = (span[csel] == '0);
  assign full_o  = (span[csel] == SPAN_W'(DEPTH));

  // ---- resolve-side read: the resolving CF's own entry
  // An entry is live when its valid bit is set and its index lies inside the
  // bank's span (distance from head < span); indices outside the span belong
  // to reclaimed generations.
  logic [SPAN_W-1:0] pop_dist;
  logic              pop_live;
  assign pop_dist = SPAN_W'(idx_of({1'b0, pop_slot})) - SPAN_W'(idx_of(head_q[csel]));
  assign pop_live = pop_v_i && valid_q[csel][pop_slot] &&
                    (SPAN_W'(idx_of(pop_dist)) < span[csel]) &&
                    (EPOCH_W == 0 || mem_q[csel][pop_slot].epoch == pop_epoch);
  assign entry_valid_o   = pop_live;
  assign entry_ghist_o   = mem_q[csel][pop_slot].ghist;
  assign entry_ras_tos_o = mem_q[csel][pop_slot].ras_tos;
  assign entry_ras_cnt_o = mem_q[csel][pop_slot].ras_cnt;
  assign entry_ras_top_o = mem_q[csel][pop_slot].ras_top;
  assign restore_valid_o = restore_i && pop_live;

  // ---- clear-side read: the fetch hart's oldest live entry
  logic [IDX_W-1:0] head_slot;
  assign head_slot       = idx_of(head_q[psel]);
  assign clear_restore_o = clear_i && !flush_i && (span[psel] != '0) && valid_q[psel][head_slot];
  assign clear_ras_tos_o = mem_q[psel][head_slot].ras_tos;
  assign clear_ras_cnt_o = mem_q[psel][head_slot].ras_cnt;
  assign clear_ras_top_o = mem_q[psel][head_slot].ras_top;

  // ---- allocation: all of this cycle's slots or none
  logic [PUSH_CNT_W-1:0] push_cnt;
  logic [NR_PUSH-1:0][PUSH_CNT_W-1:0] push_rank;
  always_comb begin
    push_cnt = '0;
    for (int unsigned k = 0; k < NR_PUSH; k++) begin
      push_rank[k] = push_cnt;
      push_cnt += PUSH_CNT_W'(push_i[k]);
    end
  end
  // A window consumed on the mispredict cycle of the same bank is wrong-path:
  // never checkpoint it.
  logic alloc_en;
  assign alloc_en = (push_cnt != '0) && !(restore_i && psel == csel) && !flush_i && !clear_i &&
                    ((span[psel] + SPAN_W'(push_cnt)) <= SPAN_W'(DEPTH));
  assign alloc_v_o = alloc_en;
  for (genvar k = 0; k < NR_PUSH; k++) begin : gen_alloc_idx
    if (EPOCH_W == 0) begin : gen_tag_idx
      assign alloc_idx_o[k] = TAG_W'(idx_of(alloc_q[psel] + SPAN_W'(push_rank[k])));
    end else begin : gen_tag_epoch
      assign alloc_idx_o[k] = {epoch_q[psel][EPOCH_W-1:0],
                               idx_of(alloc_q[psel] + SPAN_W'(push_rank[k]))};
    end
  end

  // ---- next state
  logic [SPAN_W-1:0] k_dist;
  always_comb begin
    valid_d = valid_q;
    head_d  = head_q;
    alloc_d = alloc_q;
    epoch_d = epoch_q;
    k_dist  = '0;

    // resolve bank: restore reclaims the entry and every younger one; a plain
    // resolve frees its entry
    if (restore_i && pop_live) begin
      for (int unsigned k = 0; k < DEPTH; k++) begin
        k_dist = SPAN_W'(IDX_W'(k)) - SPAN_W'(idx_of(head_q[csel]));
        k_dist = SPAN_W'(idx_of(k_dist));
        if (k_dist >= pop_dist && k_dist < span[csel]) valid_d[csel][k] = 1'b0;
      end
      alloc_d[csel] = head_q[csel] + pop_dist;
      epoch_d[csel] = epoch_q[csel] + EP_W'(1);
    end else if (pop_i && pop_live) begin
      valid_d[csel][pop_slot] = 1'b0;
    end

    // allocation bank (after the reclaim, so a same-bank restore + allocate
    // cannot coexist -- alloc_en already excludes it)
    if (alloc_en) begin
      for (int unsigned k = 0; k < NR_PUSH; k++) begin
        if (push_i[k]) valid_d[psel][idx_of(alloc_q[psel] + SPAN_W'(push_rank[k]))] = 1'b1;
      end
      alloc_d[psel] = alloc_q[psel] + SPAN_W'(push_cnt);
    end

    // head reclaim: one freed entry per cycle (frees arrive at most one per
    // cycle; the span shrinks as fast as it needs to)
    for (int unsigned h = 0; h < NH; h++) begin
      if ((alloc_d[h] - head_q[h]) != '0 && !valid_d[h][idx_of(head_q[h])])
        head_d[h] = head_q[h] + SPAN_W'(1);
    end

    // fetch-hart bank drop: exception/fence flush, or an IF flush that is not
    // a mispredict (its consumed CFs never resolve)
    if (flush_i || clear_i) begin
      valid_d[psel] = '0;
      head_d[psel]  = '0;
      alloc_d[psel] = '0;
      epoch_d[psel] = epoch_q[psel] + EP_W'(1);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= '0;
      head_q  <= '0;
      alloc_q <= '0;
      epoch_q <= '0;
    end else begin
      valid_q <= valid_d;
      head_q  <= head_d;
      alloc_q <= alloc_d;
      epoch_q <= epoch_d;
    end
  end

  // Payload array: qualified by valid_q, so it needs no reset.
  always_ff @(posedge clk_i) begin
    if (alloc_en) begin
      for (int unsigned k = 0; k < NR_PUSH; k++) begin
        if (push_i[k]) begin
          mem_q[psel][idx_of(alloc_q[psel] + SPAN_W'(push_rank[k]))] <=
              '{ghist: push_ghist_i, ras_tos: push_ras_tos_i, ras_cnt: push_ras_cnt_i,
                ras_top: push_ras_top_i, epoch: epoch_q[psel]};
        end
      end
    end
  end

endmodule
