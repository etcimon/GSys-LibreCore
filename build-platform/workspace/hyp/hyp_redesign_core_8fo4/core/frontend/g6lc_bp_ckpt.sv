// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
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
// follows the oldest live entry (holes left by out-of-order frees are
// reclaimed at once); a mispredict reclaims everything from its own entry on
// (younger = allocated after it = wrong path).

module g6lc_bp_ckpt
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned GHIST_LEN = 24,
    parameter int unsigned DEPTH = 8,
    // RAS checkpoint field widths (0 → GHR-only checkpoints, RAS fields ignored)
    parameter int unsigned RAS_DEPTH = 0,
    parameter int unsigned RAS_PTR_W = 1,
    parameter int unsigned RAS_CNT_W = 1,
    parameter int unsigned RAS_VLEN = 64,
    // CF slots that may allocate in one cycle (fetch width)
    parameter int unsigned NR_PUSH = 2,
    // hyp8: width of the lookup token stored per entry (the predictor
    // index/tag the pushed CF's own lookup used; training replays it so the
    // update path never recomputes the folded hash)
    parameter int unsigned TOK_W = 1,
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
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] push_hart_i,
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] pop_hart_i,
    // Allocate one checkpoint per consumed CF slot (predict time)
    input  logic [NR_PUSH-1:0]   push_i,
    input  logic [GHIST_LEN-1:0] push_ghist_i,
    // hyp8: per pushed slot, the predictor lookup token of that slot's CF
    // (registered verdict-time index/tag of the pushed slot).
    input  logic [NR_PUSH-1:0][TOK_W-1:0] push_tok_i,
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
    output logic [TOK_W-1:0]     entry_tok_o,
    output logic [RAS_PTR_W-1:0] entry_ras_tos_o,
    output logic [RAS_CNT_W-1:0] entry_ras_cnt_o,
    output logic [RAS_VLEN-1:0]  entry_ras_top_o,
    // restore_i qualified by a live entry
    output logic                 restore_valid_o,
    output logic                 empty_o,
    output logic                 full_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_bp_ckpt status=proposal target=10-adjusted-FO4
  // svt-plan: cone restore truncation -> post-free vector -> oldest-live
  // search -> span/allocation; clear-side restore intentionally sees current frees.
  // svt-plan: reshape separate per-hart live/epoch metadata from checkpoint
  // payloads; search small groups for oldest survivor and merge ring offsets.
  // svt-plan: boundary post-free group summaries -> reclaim head/span;
  // keep resolve-side indexed restore separate from background reclamation.
  // svt-plan: carry hart, index+epoch, head/span snapshot and restore/clear
  // kind; preserve ghist and RAS pointer/count/top as one checkpoint value.
  // svt-plan: conflict while reclaim is pending, suppress reuse of uncertain
  // slots; a same-bank restore restarts the summary or invalidates its epoch.
  // svt-plan: consumer clear_restore_o needs a response handshake or a
  // frontend recovery hold; a stale oldest slot is not a valid restore point.
  // svt-plan: effect splits truncation from ring search, without adding an
  // absolute-slot-to-offset conversion to a consumer that needs ring distance.
  // svt-plan: cost summary registers and conservative allocation stalls;
  // guarantee reclamation progresses under repeated pushes and restores.
  // svt-plan: limit all-or-none multi-push and non-power-of-two geometry
  // still require explicit span arithmetic; no generic valid_d register cut.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 68.0 adjusted FO4 on the
  // Nangate45 board): branch checkpoint stack: push / restore state.
  // svt-pipe: require-contract
  // svt-pipe: protocol ck valid=push_i flush=flush_i
  // svt-pipe: no-cut on=valid_d
  // svt-pipe: cycle ck q=valid_d d=alloc_v_o hold=push_i steps=1

  localparam int unsigned NH = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
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
    // hyp8: lookup token — the registered index/tag this CF's own lookup used
    logic [TOK_W-1:0]     tok;
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
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_bp_ckpt  region=3612  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: alloc_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to alloc_q
// order expect: epoch_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to epoch_q
// order expect: head_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to head_q
// order expect: valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to valid_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     alloc_q <= …; // sv-timing: cycle 1/1 on clk_i
//     epoch_q <= …; // sv-timing: cycle 1/1 on clk_i
//     head_q <= …; // sv-timing: cycle 1/1 on clk_i
//     valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node13188 c=3.50 slack=0.00 */
//     /* node13189 c=3.50 slack=0.00 */
//     /* node13190 c=3.50 slack=0.00 */
//     /* node13191 c=3.50 slack=0.00 */
//     /* node13192 c=3.50 slack=0.00 */
//     /* node13193 c=3.50 slack=0.00 */
//     /* node13194 c=3.50 slack=0.00 */
//     /* node13195 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_bp_ckpt  region=3613  makespan=14.500 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: mem_q  ready_cycle=2  ready_fo4=14.500  OpenSTA: report_timing -from clk_i -to mem_q
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     /* cycle 1: no capture on this edge (slack) */
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     mem_q <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node13196 c=14.50 slack=0.00 */
// end
// ----------------------------------------------------------------
// sv-timing: origin <src>/core/frontend/g6lc_bp_ckpt.sv:202:10 edit=223
  // relocation t1_neutral_trial; rebalance_associative node 13145 depth 6->5 fo4 8.5->8.5
  // END sv-timing auto-correct (balance_mux rewrite)
assign pop_slot  = pop_idx_i[IDX_W-1:0];
  assign pop_epoch = (EPOCH_W == 0) ? '0 : EP_W'(pop_idx_i >> IDX_W);

  logic [HID_W-1:0] psel, csel;
  assign psel = (NH <= 1) ? '0 : push_hart_i[HID_W-1:0];
  assign csel = (NH <= 1) ? '0 : pop_hart_i[HID_W-1:0];

  // Shipped depths are powers of two, so the ring index is the low bits.
  // The old `% DEPTH` arm lived in this function. A parameter compare is not
  // folded, so both arms were timed and the remainder is a divider.
  function automatic logic [IDX_W-1:0] idx_of(logic [SPAN_W-1:0] p);
    return p[IDX_W-1:0];
  endfunction

  if (DEPTH != (1 << IDX_W)) begin : gen_warn_ckpt_depth
    $warning("g6lc_bp_ckpt: DEPTH is not a power of two; index arithmetic keeps the low bits");
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
  // pop_dist: the entry's ring distance from the head. The slot subtraction
  // wraps modulo 2^SPAN_W when the entry lies past the ring boundary (slot <
  // head slot), so it is folded back onto the ring with idx_of -- for the
  // liveness test AND for the restore truncation below (the raw difference
  // there pulled the allocation pointer back a whole lap too far: the span
  // read d + DEPTH, nothing younger was reclaimed and the bank refused every
  // allocation until the next clear).
  logic [SPAN_W-1:0] pop_diff, pop_dist;
  logic              pop_live;
  logic              slot_vbit, in_span, epoch_ok;
  logic [IDX_W-1:0]  head_idx;
  // Low IDX_W bits are the ring index. Distance and the entry read are
  // separate assigns so the tag compare does not sit inside the subtract.
  assign head_idx  = head_q[csel][IDX_W-1:0];
  assign pop_diff  = SPAN_W'(pop_slot) - SPAN_W'(head_idx);
  assign pop_dist  = SPAN_W'(pop_diff[IDX_W-1:0]);
  assign slot_vbit = valid_q[csel][pop_slot];
  assign in_span   = pop_dist < span[csel];
  assign epoch_ok  = (EPOCH_W == 0) || (mem_q[csel][pop_slot].epoch == pop_epoch);
  // A reduction, not a left-folded chain. Same four terms.
  assign pop_live  = &{pop_v_i, slot_vbit, in_span, epoch_ok};
  // hyp8: the resolve-side read is registered (rank 4): entry payload and
  // restore_valid appear one cycle after pop/restore. The reclaim itself
  // still happens on the resolve cycle (below) — only the payload delivery
  // is staged. mem_q contents are not cleared by a free, so capturing them at
  // this edge reads the checkpoint before the reclaim lands.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_valid_o   <= 1'b0;
      entry_ghist_o   <= '0;
      entry_tok_o     <= '0;
      entry_ras_tos_o <= '0;
      entry_ras_cnt_o <= '0;
      entry_ras_top_o <= '0;
      restore_valid_o <= 1'b0;
    end else begin
      entry_valid_o   <= pop_live;
      entry_ghist_o   <= mem_q[csel][pop_slot].ghist;
      entry_tok_o     <= mem_q[csel][pop_slot].tok;
      entry_ras_tos_o <= mem_q[csel][pop_slot].ras_tos;
      entry_ras_cnt_o <= mem_q[csel][pop_slot].ras_cnt;
      entry_ras_top_o <= mem_q[csel][pop_slot].ras_top;
      restore_valid_o <= restore_i && pop_live;
    end
  end

  // ---- clear-side read: the fetch hart's oldest live entry (after this
  // cycle's frees -- a CF resolving on the clear cycle is older than the
  // frontier and must not be the restore point)
  logic [NH-1:0]            live_any;
  logic [NH-1:0][IDX_W-1:0] live_slot;
  assign clear_restore_o = clear_i && !flush_i && live_any[psel];
  assign clear_ras_tos_o = mem_q[psel][live_slot[psel]].ras_tos;
  assign clear_ras_cnt_o = mem_q[psel][live_slot[psel]].ras_cnt;
  assign clear_ras_top_o = mem_q[psel][live_slot[psel]].ras_top;

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

  // ---- post-free state: this cycle's valid vector / allocation pointer after
  // the resolve-side frees (plain resolve, restore truncation) and before
  // allocation and the bank drop. The oldest-live search and the clear-side
  // read work on this view: a CF resolving on the clear cycle is older than
  // the restart frontier and must not be the restore point, and the drop
  // must not hide the entry the clear restores from. alloc_free is the
  // allocation pointer that pairs with valid_free (restore pulls it back to
  // head + pop_dist); the head collapses onto it when nothing is live.
  logic [NH-1:0][DEPTH-1:0]  valid_free;
  logic [NH-1:0][SPAN_W-1:0] alloc_free;
  // Each slot's ring distance is independent. The old loop rewrote one
  // k_dist, so the tool billed DEPTH serial subtracts.
  logic [DEPTH-1:0] reclaim_k;
  // Bank and slot compares are independent of ring distance.
  logic [NH-1:0] bank_hit;
  logic [DEPTH-1:0] slot_is_pop;
  for (genvar h = 0; h < NH; h++) begin : gen_bank_hit
    assign bank_hit[h] = (h == csel);
  end
  for (genvar k = 0; k < DEPTH; k++) begin : gen_slot_is_pop
    assign slot_is_pop[k] = (k == int'(pop_slot));
  end
  for (genvar k = 0; k < DEPTH; k++) begin : gen_reclaim
    logic [SPAN_W-1:0] dist_raw, dist_k;
    logic              dist_ge, dist_lt;
    assign dist_raw = SPAN_W'(k) - SPAN_W'(head_idx);
    assign dist_k   = SPAN_W'(dist_raw[IDX_W-1:0]);
    assign dist_ge  = dist_k >= pop_dist;
    assign dist_lt  = dist_k < span[csel];
    assign reclaim_k[k] = restore_i && pop_live && dist_ge && dist_lt;
  end
  for (genvar h = 0; h < NH; h++) begin : gen_free
    for (genvar k = 0; k < DEPTH; k++) begin : gen_bit
      logic drop_k, pop_term, drop_or;
      // The resolving-slot term does not read ring distance. Reclaim
      // and that term meet in one OR, then the bank bit. Same cycle.
      assign pop_term = pop_i && pop_live && slot_is_pop[k];
      assign drop_or  = reclaim_k[k] || pop_term;
      assign drop_k   = bank_hit[h] && drop_or;
      assign valid_free[h][k] = drop_k ? 1'b0 : valid_q[h][k];
    end
    assign alloc_free[h] = (h == csel && restore_i && pop_live)
                          ? (head_q[h] + pop_dist) : alloc_q[h];
  end

  // ---- oldest live entry per bank (on the post-free valid vector). valid
  // bits only ever exist inside [head, alloc_free), so the first set bit of
  // the head-rotated vector is the oldest live entry.
  logic [NH-1:0][DEPTH-1:0]  valid_rot;
  logic [NH-1:0][IDX_W-1:0]  live_off;
  logic [NH-1:0]             live_none;
  for (genvar h = 0; h < NH; h++) begin : gen_oldest_live
    logic [2*DEPTH-1:0] rot_ext;
    assign rot_ext      = {valid_free[h], valid_free[h]} >> idx_of(head_q[h]);
    assign valid_rot[h] = rot_ext[DEPTH-1:0];
    if (DEPTH > 1) begin : gen_lzc
      g6lc_hyp_lzc #(.WIDTH(DEPTH), .MODE(1'b0)) i_lzc (
          .in_i   (valid_rot[h]),
          .cnt_o  (live_off[h]),
          .empty_o(live_none[h])
      );
    end else begin : gen_lzc1
      assign live_off[h]  = '0;
      assign live_none[h] = !valid_rot[h][0];
    end
    assign live_any[h]  = !live_none[h];
    assign live_slot[h] = idx_of(head_q[h] + SPAN_W'(live_off[h]));
  end

  // ---- next state (a separate block from the post-free view: it consumes
  // the lzc result, the post-free block feeds it -- one block for both would
  // read its own output through the search)
  always_comb begin
    valid_d = valid_free;
    alloc_d = alloc_free;
    epoch_d = epoch_q;
    if (restore_i && pop_live) epoch_d[csel] = epoch_q[csel] + EP_W'(1);

    // allocation bank (after the reclaim, so a same-bank restore + allocate
    // cannot coexist -- alloc_en already excludes it)
    if (alloc_en) begin
      for (int unsigned k = 0; k < NR_PUSH; k++) begin
        if (push_i[k]) valid_d[psel][idx_of(alloc_q[psel] + SPAN_W'(push_rank[k]))] = 1'b1;
      end
      alloc_d[psel] = alloc_q[psel] + SPAN_W'(push_cnt);
    end

    // head reclaim: the head moves to the oldest live entry (holes left by
    // out-of-order frees are reclaimed at once); an all-free span collapses
    // onto the post-free allocation pointer -- NOT onto alloc_d, which already
    // counts this cycle's allocations: those sit at [alloc_free, alloc_d) and
    // are the live entries the head must stop at.
    for (int unsigned h = 0; h < NH; h++) begin
      head_d[h] = live_none[h] ? alloc_free[h] : head_q[h] + SPAN_W'(live_off[h]);
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
              '{ghist: push_ghist_i, tok: push_tok_i[k], ras_tos: push_ras_tos_i,
                ras_cnt: push_ras_cnt_i, ras_top: push_ras_top_i, epoch: epoch_q[psel]};
        end
      end
    end
  end

endmodule
