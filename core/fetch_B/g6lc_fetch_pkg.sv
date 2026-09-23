// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Fetch geometry and value-table combos for core/fetch_B (R6-R11 workspace).
// Frozen A pkg is core/smt/g6lc_fetch_pkg.sv. No g1*/I4* names. Hosts call;
// muxes stay in the frontend/realign. Timing: same compares already on NPC /
// leftover / kill.

package g6lc_fetch_pkg;
  import config_pkg::*;

  typedef struct packed {
    int unsigned w_bytes;
    int unsigned align_bits;
    int unsigned slots;
    int unsigned log2_slots;
    int unsigned hw_per_w;
    int unsigned issue;
    int unsigned harts;
    int unsigned hart_idx_w;
    int unsigned hold_max;
    logic        smt;
    logic        rvc;
    logic        ftq;
    logic        rvh;
  } fetch_geo_t;

  // Which capability rows are live. Const-folded from CVA6Cfg.
  typedef struct packed {
    logic align;      // leftover + cursor (R4 mixed C/I)
    logic accept;     // window tag match (keep without opcode tests)
    logic order;      // oldest-PC issue ports
    logic redirect;   // priority encoder
    logic restore;    // SMT PC restore (T>1 only)
    logic trap_hold;  // bounded exception-entry (R3)
    logic bp_hint;    // predict filter only (R5 / I19)
  } fetch_en_t;

  function automatic fetch_geo_t geo(input cva6_cfg_t cfg);
    fetch_geo_t g;
    g.w_bytes     = cfg.FETCH_WIDTH / 8;
    g.align_bits  = cfg.FETCH_ALIGN_BITS;
    g.slots       = cfg.INSTR_PER_FETCH;
    g.log2_slots  = cfg.LOG2_INSTR_PER_FETCH;
    g.hw_per_w    = cfg.FETCH_WIDTH / 16;
    g.issue       = cfg.NrIssuePorts;
    g.harts       = cfg.NrHarts;
    g.hart_idx_w  = (cfg.NrHarts > 1) ? $clog2(cfg.NrHarts) : 1;
    // Every hold needs an explicit bound (I23). With an FTQ the queue depth is
    // that bound; without one a redirect can only be re-presented per slot.
    g.hold_max    = (cfg.FtqDepth != 0) ? cfg.FtqDepth : cfg.INSTR_PER_FETCH;
    g.smt         = cfg.NrHarts > 1;
    g.rvc         = cfg.RVC;
    g.ftq         = cfg.FtqDepth != 0;
    g.rvh         = cfg.RVH;
    geo = g;
  endfunction

  function automatic fetch_en_t en(input cva6_cfg_t cfg);
    fetch_en_t e;
    e.align     = 1'b1;
    e.accept    = 1'b1;
    e.order     = 1'b1;
    e.redirect  = 1'b1;
    e.restore   = cfg.NrHarts > 1;
    e.trap_hold = 1'b1;
    e.bp_hint   = 1'b1;
    en = e;
  endfunction

  // L1-L4's ONLY encoding knowledge (SPEC §1): [1:0]==2'b11 is a 32-bit RVI.
  // Opcode class belongs to instr_scan and the decoder; L2/L3 must not consult it.
  function automatic int unsigned ilen_of(input cva6_cfg_t cfg, input logic [15:0] hw);
    if (!cfg.RVC) ilen_of = 4;
    else ilen_of = (hw[1:0] == 2'b11) ? 4 : 2;
  endfunction

  function automatic logic rvi_prefix(input logic [15:0] hw);
    rvi_prefix = (hw[1:0] == 2'b11);
  endfunction

  // Window tag: replaces A [VLEN-1:3] / [VLEN-1:4] literals.
  function automatic logic [63:0] win_tag(
      input cva6_cfg_t cfg,
      input logic [63:0] pc
  );
    win_tag = pc >> cfg.FETCH_ALIGN_BITS;
  endfunction

  // Halfword offset inside the fetch window. Replaces A [ALIGN-1:1] / [2:1].
  // Halfword index WITHIN the window, so the mask drops one more bit than
  // win_base: bit 0 of a PC is always 0 and carries no offset information.
  function automatic logic [7:0] hw_off(
      input cva6_cfg_t cfg,
      input logic [63:0] pc
  );
    logic [63:0] m;
    m = (64'(1) << (cfg.FETCH_ALIGN_BITS - 1)) - 64'(1);
    hw_off = 8'((pc >> 1) & m);
  endfunction

  function automatic logic [63:0] win_base(
      input cva6_cfg_t cfg,
      input logic [63:0] pc
  );
    logic [63:0] m;
    m = ~((64'(1) << cfg.FETCH_ALIGN_BITS) - 64'(1));
    win_base = pc & m;
  endfunction

  function automatic logic [63:0] next_block(
      input cva6_cfg_t cfg,
      input logic [63:0] pc
  );
    next_block = win_base(cfg, pc) + (64'(cfg.FETCH_WIDTH) / 64'(8));
  endfunction

  function automatic logic same_win(
      input cva6_cfg_t cfg,
      input logic [63:0] a,
      input logic [63:0] b
  );
    same_win = (win_tag(cfg, a) == win_tag(cfg, b));
  endfunction

  // Next halfword after a split RVI (I3). Fetch stream is already shifted
  // so that halfword 0 is the completing high half.
  function automatic logic leftover_next(
      input logic [63:0] addr,
      input logic [63:0] carry_pc
  );
    leftover_next = (addr == (carry_pc + 64'd2));
  endfunction

  // Leftover completes only from that next halfword, and only if the
  // carried low half is a legal RVI prefix (I3, I5). start_hw0 is 1 when
  // the host presents a shifted window (slot0 = completing high half).
  function automatic logic leftover_complete(
      input logic lo_v,
      input logic next_win,
      input logic lo_rvi,
      input logic start_hw0
  );
    leftover_complete = lo_v && next_win && lo_rvi && start_hw0;
  endfunction

  // L2 keep: live window vs expected PC. No opcode, no rd.
  function automatic logic window_accept(
      input logic valid,
      input logic kill,
      input logic same
  );
    window_accept = valid && !kill && same;
  endfunction

  function automatic logic accepted_target(
      input int unsigned slots,
      input logic take,
      input logic flush,
      input logic [7:0] consumed,
      input logic [7:0][63:0] pc,
      input logic [63:0] target
  );
    logic found;
    found = 1'b0;
    for (int p = 0; p < 8; p++) begin
      if (p < slots && consumed[p] && pc[p] == target) found = 1'b1;
    end
    return take && !flush && found;
  endfunction

  function automatic logic slot_live(
      input logic slot_v,
      input logic accept,
      input logic pc_ge_expected
  );
    slot_live = slot_v && accept && pc_ge_expected;
  endfunction

  // A's kill *capability* without spares (NEGATIVE: unbounded/over-narrow spare).
  function automatic logic kill_s1(
      input logic is_mispredict,
      input logic flush,
      input logic replay
  );
    kill_s1 = is_mispredict | flush | replay;
  endfunction

  function automatic logic kill_s2(
      input logic s1,
      input logic bp_valid
  );
    kill_s2 = s1 | bp_valid;
  endfunction

  // L4 source ids — firmware-boot-principles I8 / SPEC §5.
  localparam logic [3:0] SRC_NONE    = 4'd0;
  localparam logic [3:0] SRC_EX      = 4'd1;
  localparam logic [3:0] SRC_DEBUG   = 4'd2;
  localparam logic [3:0] SRC_ERET    = 4'd3;
  localparam logic [3:0] SRC_COMMIT  = 4'd4;
  localparam logic [3:0] SRC_RESTORE = 4'd5;
  localparam logic [3:0] SRC_MISP    = 4'd6;
  // T6b-2a: peer-hart flush restart of the active fetch hart (mixed residency
  // only) — below COMMIT, above debug/restore/mispredict.
  localparam logic [3:0] SRC_PEER    = 4'd7;

  // I8: exception > eret > pc-commit > peer restart > debug > SMT restore >
  // resolve. Restore must not outrank trap (post-pre-ladder I4y).
  // en_restore const-folds; peer is constant-0 on drained configurations.
  function automatic logic [3:0] arch_src_sel(
      input logic en_restore,
      input logic restore,
      input logic debug_en,
      input logic commit,
      input logic peer,
      input logic ex,
      input logic eret,
      input logic misp
  );
    if (ex) arch_src_sel = SRC_EX;
    else if (eret) arch_src_sel = SRC_ERET;
    else if (commit) arch_src_sel = SRC_COMMIT;
    else if (peer) arch_src_sel = SRC_PEER;
    else if (debug_en) arch_src_sel = SRC_DEBUG;
    else if (en_restore && restore) arch_src_sel = SRC_RESTORE;
    else if (misp) arch_src_sel = SRC_MISP;
    else arch_src_sel = SRC_NONE;
  endfunction

  // I8: PC_COMMIT reseeds fetch only for the active hart. An outgoing hart
  // may still retire CSR/fence (switch does not flush EX); that must not
  // steal the incoming restore (hart1 ROM `jr s0` vs hart0 `spin_lock`).
  function automatic logic commit_for_hart(
      input logic en_smt,
      input logic commit,
      input logic [7:0] commit_hart,
      input logic [7:0] active_hart
  );
    commit_for_hart = commit && (!en_smt || (commit_hart == active_hart));
  endfunction

  function automatic logic redirect_for_hart(
      input logic en_smt,
      input logic valid,
      input logic [7:0] owner,
      input logic [7:0] active_hart
  );
    return valid && (!en_smt || owner == active_hart);
  endfunction

  function automatic logic leftover_pending(input logic lo_v, input logic complete);
    leftover_pending = lo_v && !complete;
  endfunction

  // I3 drop: a valid window that is not leftover_next consumes the carry.
  // Keep only on I$ bubbles (`!valid`). Do not keep across a foreign window
  // (NEGATIVE I4az). Flush is architectural and is a separate clear.
  function automatic logic leftover_drop(
      input logic lo_v,
      input logic complete,
      input logic valid
  );
    leftover_drop = lo_v && valid && !complete;
  endfunction

  // Kill and flush are inert on leftover *state* (SPEC L1). A pending
  // carry is consumed only by leftover_complete or overwritten by a
  // valid unkilled non-next window (leftover_drop / I4az).
  // NEGATIVE: spec leftover hold / I3 keep (do not skip drop on spec_req);
  // I4ac (leftover_next is strict — foreign windows still overwrite).
  function automatic logic leftover_update(
      input logic flush,
      input logic valid,
      input logic kill
  );
    leftover_update = valid && !kill;
  endfunction

  // During IQ replay, still take a leftover_complete I$ return
  // (carry+2). Does not block leftover_drop when !replay (I4az).
  // leftover_take_ok gated ALL take on leftover_pending — MINI-FAIL hang.
  // pipe_keep held leftover_drop windows — MINI-FAIL osbi/beqz/nested.
  // lo_v gates leftover_next so carry X cannot reach take (0 && X = 0).
  function automatic logic leftover_retake(
      input logic replay,
      input logic lo_v,
      input logic next_win
  );
    leftover_retake = !replay || (lo_v && next_win);
  endfunction

  // I7 exception: leftover-complete slot0 is the previous window's
  // carry (A_no_loss). If it fits and the rest overflow, push slot0
  // and replay the rest. pipe_keep / leftover_replay_hold MINI-FAIL
  // osbi 129b8. Not leftover_drop npc mux.
  function automatic logic leftover_slot0_push(
      input logic complete,
      input logic slot0_v,
      input logic slot0_full,
      input logic overflow
  );
    leftover_slot0_push = complete && slot0_v && !slot0_full && overflow;
  endfunction

  // I10: NPC steps on I$ accept (next_block). Switch flush kills that
  // in-flight window, so the restart PC is the accepted address, not
  // fetch-ahead npc. Not I4av (unissued decode) or I4aw (same-page guess).
  function automatic logic [63:0] snap_pc(
      input logic en,
      input logic inflight,
      input logic [63:0] inflight_addr,
      input logic [63:0] npc
  );
    snap_pc = (en && inflight) ? inflight_addr : npc;
  endfunction

  typedef struct packed {
    logic valid;
    logic [63:0] pc;
  } restart_t;

  function automatic restart_t restart_frontier(
      input int unsigned ports,
      input logic [7:0] owner,
      input logic [7:0] decode_valid,
      input logic [7:0][7:0] decode_hart,
      input logic [7:0][63:0] decode_pc,
      input logic [7:0] queue_valid,
      input logic [7:0][7:0] queue_hart,
      input logic [7:0][63:0] queue_pc,
      input restart_t transport,
      input logic redirect_valid,
      input logic [7:0] redirect_hart,
      input logic [63:0] redirect_pc
  );
    restart_t selected;
    selected = transport;
    for (int p = 7; p >= 0; p--) begin
      if (p < ports && queue_valid[p] && queue_hart[p] == owner)
        selected = '{valid: 1'b1, pc: queue_pc[p]};
    end
    for (int p = 7; p >= 0; p--) begin
      if (p < ports && decode_valid[p] && decode_hart[p] == owner)
        selected = '{valid: 1'b1, pc: decode_pc[p]};
    end
    if (redirect_valid && redirect_hart == owner)
      selected = '{valid: 1'b1, pc: redirect_pc};
    return selected;
  endfunction

  // L3: the packet carries the hart that fetched it. Decode must not retag
  // with the active hart after a switch (R1: parked hart keeps sp=0).
  // `en.restore` const-folds; T=1 stamps 0.
  function automatic logic [7:0] packet_hart(
      input fetch_en_t e,
      input logic [7:0] hart
  );
    packet_hart = e.restore ? hart : 8'b0;
  endfunction

  // Bytes consumed by the halfword at `hw` (I2 cursor). Used by dbg SVA and
  // by L3 when split out; n-wide issue does not change the step.
  function automatic logic [63:0] pc_ilen(input cva6_cfg_t cfg, input logic [15:0] hw);
    pc_ilen = 64'(ilen_of(cfg, hw));
  endfunction

  // I7: enqueue the whole packet or none.
  function automatic logic packet_accept(input logic overflow);
    packet_accept = !overflow;
  endfunction

  // I19 / I21: prediction may be suppressed if the target is not fetchable.
  // Never call on resolve (I11). Uses PMA execute regions (identity map).
  function automatic logic predict_fetchable(
      input cva6_cfg_t cfg,
      input logic [63:0] target
  );
    predict_fetchable = is_inside_execute_regions(cfg, target);
  endfunction

  // L4: redirect only if IQ accepted a CF slot. ras_push/ras_pop already
  // require consumed. Without this, bp_fire drops icache_valid_q while a
  // leftover-complete jal is still unissued. Does not classify CF
  // (NEGATIVE G1br). Timing: OR of slots already on the consume path.
  function automatic logic cf_consumed(
      input logic [7:0] valid,
      input logic [7:0] taken,
      input logic [7:0] consumed
  );
    cf_consumed = |(valid & taken & consumed);
  endfunction

  // L2 expected PC for live[] / prefix drop. Not npc (npc has already
  // next_block'd). Leftover slot0 is the previous window — always ge.
  function automatic logic [63:0] window_expected(
      input logic hold,
      input logic [63:0] redirect_pc,
      input logic [63:0] vaddr
  );
    window_expected = hold ? redirect_pc : vaddr;
  endfunction

  // Monotonic-progress filter: only sound because fetch addresses increase
  // within a window. A leftover head is the PREVIOUS window and is exempt,
  // otherwise the carry it completes would always compare below `exp`.
  function automatic logic slot_ge_expected(
      input logic lo_head,
      input logic [63:0] pc,
      input logic [63:0] exp
  );
    slot_ge_expected = lo_head || (pc >= exp);
  endfunction

  // Prefix drop must not eat a direct jal/call when RAS returns into the
  // same window (jal@12990 vs beqz@12994). Return/branch/addi still drop
  // (12970 +16/ret vs next_tag@12974). Scan bits already on this cone.
  function automatic logic slot_keep_link(
      input logic ge,
      input logic link
  );
    slot_keep_link = ge || link;
  endfunction

  // Latch on I$ take: predicted-target window uses tgt (mid-window
  // prefix drop). Sequential uses the return vaddr. Not npc.
  function automatic logic [63:0] present_expected(
      input logic pend,
      input logic [63:0] tgt,
      input logic [63:0] vaddr
  );
    present_expected = pend ? tgt : vaddr;
  endfunction

  // Re-present a killed redirect (no FTQ). Not a stall: NPC holds the
  // target only while that request was lost. I9 observe; I23 bound is
  // dbg-only (do not silent-release — NEGATIVE unbounded vs early lift).
  function automatic logic redirect_rehold(
      input logic ftq,
      input logic pend,
      input logic lost,
      input logic hit
  );
    redirect_rehold = !ftq && pend && lost && !hit;
  endfunction

  // L2: after bp_fire, keep sequential HIT; drop only a return that is
  // not the predicted window (NEGATIVE icache_ret_ok gated every return).
  // Exact vaddr==tgt MINI-FAIL (s4-v-bppc-minis): I$ vaddr is window-aligned.
  function automatic logic bp_ret_ok(input logic pend, input logic same);
    bp_ret_ok = !pend || same;
  endfunction

  // L3: keep through the first taken CF inclusive. Width is geo.slots
  // (n-wide); taken[i] is cf!=NoCF (predict). BTB-miss jalr is NoCF —
  // do not force JumpR (NEGATIVE R5).
  function automatic logic [7:0] packet_upto_cf(
      input logic [7:0] taken,
      input int unsigned n
  );
    packet_upto_cf = '0;
    // Bound the loop by the 8-slot geometry ceiling, not by `n`: a constant
    // bound is what keeps this elaborating under an open synthesis frontend.
    for (int unsigned i = 0; i < 8; i++) begin
      if (i < n) begin
        packet_upto_cf[i] = 1'b1;
        if (taken[i]) break;
      end
    end
  endfunction

endpackage
