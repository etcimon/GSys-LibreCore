// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Fetch geometry and value-table combos for frozen A (core/frontend +
// core/instr_realign). Workspace B is core/fetch_B/g6lc_fetch_pkg.sv.
// No g1*/I4* names. Hosts call; muxes stay in the frontend/realign.
// Timing: same compares already on NPC / leftover / kill.

package g6lc_fetch_pkg;
  import config_pkg::*;

  typedef struct packed {
    int unsigned w_bytes;
    int unsigned align_bits;
    int unsigned slots;
    int unsigned hw_per_w;
    int unsigned issue;
    int unsigned harts;
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
    g.w_bytes    = cfg.FETCH_WIDTH / 8;
    g.align_bits = cfg.FETCH_ALIGN_BITS;
    g.slots      = cfg.INSTR_PER_FETCH;
    g.hw_per_w   = cfg.FETCH_WIDTH / 16;
    g.issue      = cfg.NrIssuePorts;
    g.harts      = cfg.NrHarts;
    g.hold_max   = (cfg.FtqDepth != 0) ? cfg.FtqDepth : cfg.INSTR_PER_FETCH;
    g.smt        = cfg.NrHarts > 1;
    g.rvc        = cfg.RVC;
    g.ftq        = cfg.FtqDepth != 0;
    g.rvh        = cfg.RVH;
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

  // I8: exception > eret > pc-commit > debug > SMT restore > resolve.
  // Restore must not outrank trap (post-pre-ladder I4y). en_restore const-folds.
  function automatic logic [3:0] arch_src_sel(
      input logic en_restore,
      input logic restore,
      input logic debug_en,
      input logic commit,
      input logic ex,
      input logic eret,
      input logic misp
  );
    if (ex) arch_src_sel = SRC_EX;
    else if (eret) arch_src_sel = SRC_ERET;
    else if (commit) arch_src_sel = SRC_COMMIT;
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

  // L2 expected PC for live[] / prefix drop. Not npc (npc has already
  // next_block'd). Leftover slot0 is the previous window — always ge.
  function automatic logic [63:0] window_expected(
      input logic hold,
      input logic [63:0] redirect_pc,
      input logic [63:0] vaddr
  );
    window_expected = hold ? redirect_pc : vaddr;
  endfunction

  function automatic logic slot_ge_expected(
      input logic lo_head,
      input logic [63:0] pc,
      input logic [63:0] exp
  );
    slot_ge_expected = lo_head || (pc >= exp);
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

  // L3: keep through the first taken CF inclusive. Width is geo.slots
  // (n-wide); taken[i] is cf!=NoCF (predict). BTB-miss jalr is NoCF —
  // do not force JumpR (NEGATIVE R5).
  function automatic logic [7:0] packet_upto_cf(
      input logic [7:0] taken,
      input int unsigned n
  );
    packet_upto_cf = '0;
    for (int unsigned i = 0; i < 8; i++) begin
      if (i < n) begin
        packet_upto_cf[i] = 1'b1;
        if (taken[i]) break;
      end
    end
  endfunction

endpackage
