// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Sim-only value snapshot for core/fetch. Does not drive kill/NPC/bytes.
// Bind into frontend so the host stays a handful of combo assigns.
// Envelope knobs (n-wide, SMT, speculation) appear only as geo/en folds.
//
// Slot rows (`sK=pc:hw:cf`) are how an I=2/I=4/I=8 envelope is debugged
// without a new combo: same print, `geo.slots` / `geo.issue` widen.

//pragma translate_off
module g6lc_fetch_dbg
  import g6lc_fetch_pkg::*;
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input logic clk_i,
    input logic rst_ni,
    input logic [CVA6Cfg.VLEN-1:0] npc_i,
    input logic [CVA6Cfg.VLEN-1:0] fetch_addr_i,
    input logic [CVA6Cfg.VLEN-1:0] vaddr_q_i,
    input logic icache_valid_q_i,
    input logic [CVA6Cfg.FETCH_WIDTH-1:0] data_q_i,
    input logic serving_unaligned_i,
    input logic leftover_pending_i,
    // Leftover carry state (I3/I5). Read-only observation of the realigner's
    // per-hart bank so the emitted slot0 can be checked against the carry it
    // claims to complete.
    input logic leftover_valid_i,
    input logic [CVA6Cfg.VLEN-1:0] leftover_pc_i,
    input logic [15:0] leftover_lo_i,
    input logic [7:0] hart_i,
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0] slot_v_i,
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] slot_pc_i,
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0][31:0] slot_instr_i,
    input cf_t [CVA6Cfg.INSTR_PER_FETCH-1:0] slot_cf_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0] issue_v_i,
    input logic kill_s1_i,
    input logic kill_s2_i,
    input logic bp_valid_i,
    input logic spec_i,
    input logic flush_i,
    input logic is_mispredict_i,
    input logic replay_i,
    input logic redirect_hold_i,
    input logic redirect_hit_i,
    input logic [CVA6Cfg.VLEN-1:0] redirect_pc_i,
    input logic arch_valid_i,
    input logic [CVA6Cfg.VLEN-1:0] arch_pc_i,
    input logic [CVA6Cfg.VLEN-1:0] resolve_pc_i,
    input logic smt_restore_i,
    input logic set_debug_pc_i,
    input logic set_pc_commit_i,
    input logic ex_valid_i,
    input logic eret_i,
    // ---- Fetch-supply neutral observation (P1 warm fetch) -----------------
    // Read-only probes of the module-scope handshake signals; the joint
    // distribution of "request refused" x "IQ ready" is what decides whether
    // registered request/response overlap can raise the warm II. Nothing in
    // this block may feed back into a ready/valid path.
    input logic icache_req_i,
    input logic icache_rdy_i,
    input logic icache_rsp_i,
    input logic icache_take_i,
    input logic iq_ready_i,
    input logic demand_req_i,
    input logic demand_fire_i,
    input logic ftq_full_i,
    input logic ftq_head_valid_i,
    input logic lbuf_hit_i,
    input logic lbuf_consume_i,
    input logic pf_req_i,
    input logic if_ready_i,
    input logic halt_frontend_i,
    input logic bp_fire_i,
    input logic arch_reseed_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i,
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0] iq_full_i,
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0] iq_empty_i,
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0][$clog2(8)-1:0] iq_use_i
);

  localparam fetch_geo_t Geo = geo(CVA6Cfg);
  localparam fetch_en_t  En  = en(CVA6Cfg);
  localparam int unsigned Slots = Geo.slots;
  localparam int unsigned Issue = Geo.issue;
  localparam int unsigned HwPerW = Geo.hw_per_w;

  typedef struct packed {
    logic [CVA6Cfg.VLEN-1:0] npc;
    logic [CVA6Cfg.VLEN-1:0] fetch_addr;
    logic [CVA6Cfg.VLEN-1:0] vaddr_q;
    logic [CVA6Cfg.VLEN-1:0] expected;
    logic [63:0]             win_tag_v;
    logic [63:0]             win_tag_e;
    logic [7:0]              hw_off_f;
    logic                    icache_valid_q;
    logic                    leftover;
    logic                    leftover_pend;
    logic                    leftover_drop;
    logic [7:0]              hart;
    logic                    same_win;
    logic                    accept;
    logic [Slots-1:0]        live_mask;
    logic [Slots-1:0]        cf_mask;
    logic [Issue-1:0]        issue_v;
    logic                    kill_s1;
    logic                    kill_s2;
    logic                    bp_valid;
    logic                    spec;
    logic                    redirect_hold;
    logic                    redirect_hit;
    logic                    win_rej;
    logic                    arch_valid;
    logic [3:0]              arch_src;
    logic                    restore_fire;
    logic [7:0]              geo_issue;
    logic [7:0]              geo_harts;
    logic [7:0]              geo_slots;
    logic [7:0]              geo_hold_max;
    logic [7:0]              hold_age;
  } fetch_snap_t;

  fetch_snap_t snap;
  logic [63:0] expected_pc;
  logic        fetch_snap_en;
  logic        fetch_snap_filt;
  logic [63:0] fetch_snap_lo;
  logic [63:0] fetch_snap_hi;
  logic        snap_in_win;
  logic        snap_edge;
  logic        slot_cf_any;
  logic [Slots-1:0] slot_same_win;
  logic [Slots-1:0] slot_bytes_ok;
  logic [7:0]       hold_age_q;

  always_comb begin
    // L2 expected is the registered / redirect PC, not npc (npc has
    // already next_block'd). live[] is then prefix-drop, not starve.
    expected_pc = window_expected(redirect_hold_i, 64'(redirect_pc_i),
        64'(vaddr_q_i));

    snap.npc            = npc_i;
    snap.fetch_addr     = fetch_addr_i;
    snap.vaddr_q        = vaddr_q_i;
    snap.expected       = expected_pc[CVA6Cfg.VLEN-1:0];
    snap.win_tag_v      = win_tag(CVA6Cfg, 64'(vaddr_q_i));
    snap.win_tag_e      = win_tag(CVA6Cfg, expected_pc);
    snap.hw_off_f       = hw_off(CVA6Cfg, 64'(fetch_addr_i));
    snap.icache_valid_q = icache_valid_q_i;
    snap.leftover       = serving_unaligned_i;
    snap.leftover_pend  = leftover_pending_i;
    snap.leftover_drop  = g6lc_fetch_pkg::leftover_drop(leftover_pending_i,
        serving_unaligned_i, icache_valid_q_i);
    snap.hart           = hart_i;
    snap.same_win       = same_win(CVA6Cfg, 64'(vaddr_q_i), expected_pc);
    snap.accept         = window_accept(icache_valid_q_i, kill_s2_i, snap.same_win);
    snap.win_rej        = icache_valid_q_i && !snap.same_win;
    snap.geo_hold_max   = 8'(Geo.hold_max);
    snap.hold_age       = hold_age_q;
    snap.kill_s1        = kill_s1_i;
    snap.kill_s2        = kill_s2_i;
    snap.bp_valid       = bp_valid_i;
    snap.spec           = spec_i;
    snap.redirect_hold  = redirect_hold_i;
    snap.redirect_hit   = redirect_hit_i;
    snap.arch_valid     = arch_valid_i;
    snap.restore_fire   = smt_restore_i;
    snap.geo_issue      = 8'(Geo.issue);
    snap.geo_harts      = 8'(Geo.harts);
    snap.geo_slots      = 8'(Geo.slots);
    snap.issue_v        = issue_v_i;
    snap.live_mask      = '0;
    snap.cf_mask        = '0;
    slot_cf_any         = 1'b0;
    slot_same_win       = '0;
    for (int unsigned k = 0; k < Slots; k++) begin
      snap.live_mask[k] = slot_live(slot_v_i[k], snap.accept,
          slot_ge_expected(k == 0 && serving_unaligned_i,
              64'(slot_pc_i[k]), expected_pc));
      snap.cf_mask[k] = slot_v_i[k] && (slot_cf_i[k] != NoCF);
      slot_cf_any |= snap.cf_mask[k];
      slot_same_win[k] = slot_v_i[k] && same_win(CVA6Cfg, 64'(slot_pc_i[k]),
          64'(vaddr_q_i));
    end

    snap.arch_src = arch_src_sel(En.restore, smt_restore_i,
        CVA6Cfg.DebugEn && set_debug_pc_i, set_pc_commit_i, ex_valid_i,
        eret_i, is_mispredict_i);

    snap_in_win =
        (64'(snap.npc) >= fetch_snap_lo && 64'(snap.npc) <= fetch_snap_hi)
        || (64'(snap.fetch_addr) >= fetch_snap_lo && 64'(snap.fetch_addr) <= fetch_snap_hi)
        || (64'(snap.vaddr_q) >= fetch_snap_lo && 64'(snap.vaddr_q) <= fetch_snap_hi)
        || (64'(resolve_pc_i) >= fetch_snap_lo && 64'(resolve_pc_i) <= fetch_snap_hi)
        || (64'(arch_pc_i) >= fetch_snap_lo && 64'(arch_pc_i) <= fetch_snap_hi);
    for (int unsigned k = 0; k < Slots; k++) begin
      if (slot_v_i[k] && 64'(slot_pc_i[k]) >= fetch_snap_lo &&
          64'(slot_pc_i[k]) <= fetch_snap_hi)
        snap_in_win = 1'b1;
    end
    // Without an address filter, print on EVENTS only: a per-cycle dump of a
    // 10M-cycle firmware run is unreadable, and these are the states a fetch
    // pin is ever diagnosed from.
    snap_edge = serving_unaligned_i || leftover_pending_i || snap.leftover_drop
        || (icache_valid_q_i && !snap.accept) || smt_restore_i
        || (spec_i && kill_s2_i) || redirect_hold_i || arch_valid_i
        || slot_cf_any || snap.win_rej;
  end

  // I1: a same-window slot's low halfword is the I$ halfword at that PC.
  // Leftover slot 0 is the previous window — skip it (serving_unaligned).
  // data_q is already shifted so halfword 0 is vaddr_q.
  always_comb begin
    slot_bytes_ok = '0;
    for (int unsigned k = 0; k < Slots; k++) begin
      automatic int unsigned hi;
      automatic logic [15:0] mem_hw;
      hi = 0;
      mem_hw = '0;
      // A leftover head came from the PREVIOUS window, so there is no halfword
      // in data_q to compare it against; its own contract is checked below.
      if (slot_same_win[k] && !(k == 0 && serving_unaligned_i)) begin
        hi = 32'((64'(slot_pc_i[k]) - 64'(vaddr_q_i)) >> 1);
        if (hi < HwPerW) begin
          mem_hw = data_q_i[16*hi+:16];
          slot_bytes_ok[k] = (mem_hw == slot_instr_i[k][15:0]);
        end
      end else if (slot_v_i[k]) begin
        slot_bytes_ok[k] = 1'b1;
      end
    end
  end

  initial begin
    fetch_snap_en   = $test$plusargs("fetch_snap");
    fetch_snap_filt = 1'b0;
    fetch_snap_lo   = '0;
    fetch_snap_hi   = {64{1'b1}};
    if ($value$plusargs("fetch_snap_lo=%h", fetch_snap_lo)) fetch_snap_filt = 1'b1;
    if ($value$plusargs("fetch_snap_hi=%h", fetch_snap_hi)) begin
    end
  end

  // Envelope folds: restore is SMT-only; n-wide port 1 needs port 0; accept ⇒ same window.
  // verilog_lint: waive always-ff-non-reset
  always_ff @(posedge clk_i) begin
    if (rst_ni && !En.restore && smt_restore_i)
      $error("g6lc_fetch_dbg: SMT restore fired with en.restore=0");
    if (rst_ni && En.restore && Geo.harts < 2)
      $error("g6lc_fetch_dbg: en.restore with NrHarts<2");
    if (rst_ni && snap.accept && !snap.same_win)
      $error("g6lc_fetch_dbg: accept without win_tag match");
    if (rst_ni && kill_s1_i && !(is_mispredict_i || flush_i || replay_i))
      $error("g6lc_fetch_dbg: kill_s1 outside misp|flush|replay");
    if (rst_ni && En.redirect && ex_valid_i && smt_restore_i && snap.arch_src != SRC_EX)
      $error("g6lc_fetch_dbg: restore outranked exception");
    if (rst_ni && snap.leftover_drop && snap.leftover)
      $error("g6lc_fetch_dbg: leftover drop and complete in one cycle");
    // live[] prefix-drop + keep_link jal can zero slot 0 and keep slot 1
    // (s4-v-20m $stop t=2474812). One contiguous run: leading/trailing
    // zeros OK (s4-v-slotfix 2jr 1100 is not a hole).
    if (rst_ni && En.align && icache_valid_q_i) begin
      automatic logic seen_live, seen_gap;
      automatic int unsigned first_live;
      automatic logic [63:0] expect_pc;
      seen_live  = 1'b0;
      seen_gap   = 1'b0;
      first_live = Slots;
      expect_pc  = '0;
      for (int unsigned k = 0; k < Slots; k++) begin
        if (slot_v_i[k]) begin
          if (seen_gap)
            $error("g6lc_fetch_dbg: slot hole at %0d", k);
          if (first_live == Slots) first_live = k;
          seen_live = 1'b1;
        end else if (seen_live) begin
          seen_gap = 1'b1;
        end
      end
      if (first_live < Slots) begin
        expect_pc = 64'(slot_pc_i[first_live])
            + pc_ilen(CVA6Cfg, slot_instr_i[first_live][15:0]);
        for (int unsigned k = first_live + 1; k < Slots; k++) begin
          if (slot_v_i[k]) begin
            if (64'(slot_pc_i[k]) != expect_pc)
              $error("g6lc_fetch_dbg: slot pc step k=%0d got %x want %x",
                  k, slot_pc_i[k], expect_pc[CVA6Cfg.VLEN-1:0]);
            expect_pc = 64'(slot_pc_i[k]) + pc_ilen(CVA6Cfg, slot_instr_i[k][15:0]);
          end
        end
      end
      for (int unsigned k = 0; k < Slots; k++) begin
        if (slot_same_win[k] && !(k == 0 && serving_unaligned_i) && !slot_bytes_ok[k])
          $error("g6lc_fetch_dbg: I1 bytes!=memory k=%0d pc=%x hw=%04x",
              k, slot_pc_i[k], slot_instr_i[k][15:0]);
      end
    end
    // ---- L1 leftover EMISSION contract (I2 / I3 / I5) --------------------
    // The realigner's *enable* (carry_ok) is built from the same
    // `g6lc_fetch_pkg` functions the bounded formal proves, so re-checking it
    // here would be a tautology. What is NOT proven downstream is that the
    // slot actually emitted is the carry it claims to complete: `addr_o[0]`
    // must be the carried PC and `instr_o[0][15:0]` the carried halfword, and
    // nothing between the realigner and the queue may rewrite them (I2).
    //
    // The RVI check is the one with a firmware consequence. OpenSBI's CSR
    // probe (`include/sbi/sbi_csr_detect.h:17`) arms mtvec, executes a
    // possibly-illegal `csrr`, and its handler (`lib/sbi/sbi_expected_trap.S:23`)
    // advances mepc by a FIXED 4. That is sound only because `csrr` is always
    // a 4-byte RVI. A completion that emits a 16-bit fragment at the probe's
    // address turns a legal probe into an illegal instruction AND mis-advances
    // mepc -- the R3(c) obligation, and it would surface ~10M cycles later as
    // an unrelated firmware hang rather than here.
    if (rst_ni && En.align && serving_unaligned_i && slot_v_i[0]) begin
      if (64'(slot_pc_i[0]) != 64'(leftover_pc_i))
        $error("g6lc_fetch_dbg: I3 slot0 pc %x is not the carried pc %x",
            slot_pc_i[0], leftover_pc_i);
      if (slot_instr_i[0][15:0] != leftover_lo_i)
        $error("g6lc_fetch_dbg: I2 slot0 low half %04x rewritten from carry %04x",
            slot_instr_i[0][15:0], leftover_lo_i);
      if (!rvi_prefix(slot_instr_i[0][15:0]))
        $error("g6lc_fetch_dbg: I5 completed slot0 is not RVI lo=%04x pc=%x",
            slot_instr_i[0][15:0], slot_pc_i[0]);
      if (ilen_of(CVA6Cfg, slot_instr_i[0][15:0]) != 4)
        $error("g6lc_fetch_dbg: I5 completed slot0 ilen!=4 pc=%x", slot_pc_i[0]);
    end
    // A carry cannot be completing and still be held for later.
    if (rst_ni && En.align && serving_unaligned_i && !leftover_valid_i)
      $error("g6lc_fetch_dbg: I3 completion without a held carry");
    if (rst_ni && fetch_snap_en &&
        ((fetch_snap_filt && snap_in_win) || (!fetch_snap_filt && snap_edge))) begin
      $display(
          "[fetch_snap] t=%0t npc=%x fa=%x vq=%x exp=%x h=%0d lo=%0d pend=%0d drop=%0d acc=%0d wr=%0d live=%b cf=%b issue=%b k1=%0d k2=%0d spec=%0d rh=%0d age=%0d hm=%0d src=%0d rst=%0d rpc=%x tgt=%x I=%0d T=%0d S=%0d",
          $time, snap.npc, snap.fetch_addr, snap.vaddr_q, snap.expected, snap.hart,
          snap.leftover, snap.leftover_pend, snap.leftover_drop, snap.accept, snap.win_rej,
          snap.live_mask, snap.cf_mask, snap.issue_v, snap.kill_s1, snap.kill_s2,
          snap.spec, snap.redirect_hold, snap.hold_age, snap.geo_hold_max, snap.arch_src, snap.restore_fire,
          resolve_pc_i, arch_pc_i, snap.geo_issue, snap.geo_harts, snap.geo_slots);
      for (int unsigned k = 0; k < Slots; k++) begin
        if (slot_v_i[k])
          $display("[fetch_slot] t=%0t k=%0d pc=%x hw=%04x cf=%0d ilen=%0d same=%0d ok=%0d",
              $time, k, slot_pc_i[k], slot_instr_i[k][15:0], slot_cf_i[k],
              ilen_of(CVA6Cfg, slot_instr_i[k][15:0]), slot_same_win[k], slot_bytes_ok[k]);
      end
    end
  end

  // I23 observe: age of redirect_hold. Do not silent-release (NEGATIVE).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) hold_age_q <= '0;
    else if (redirect_hold_i) begin
      if (hold_age_q != 8'hff) hold_age_q <= hold_age_q + 8'd1;
    end else hold_age_q <= '0;
  end

  // I23 bound: "every hold carries an explicit bound", and NEGATIVE section 1
  // is the unbounded-hold family. The bound is observed, never enforced --
  // silently releasing a hold is itself a recorded negative (unbounded vs
  // early lift), so this reports and does not touch the hold. Warning, and
  // latched to one report per run, so an over-long hold names itself on the
  // cycle it happens without turning every later run into noise.
  logic hold_bound_reported_q;
  // verilog_lint: waive always-ff-non-reset
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hold_bound_reported_q <= 1'b0;
    end else if (redirect_hold_i && !hold_bound_reported_q &&
                 32'(hold_age_q) > Geo.hold_max) begin
      hold_bound_reported_q <= 1'b1;
      $warning("g6lc_fetch_dbg: I23 redirect_hold age %0d exceeds geo.hold_max %0d (pc=%x)",
          hold_age_q, Geo.hold_max, redirect_pc_i);
    end
  end

  if (Issue > 1) begin : gen_issue_order
    // verilog_lint: waive always-ff-non-reset
    always_ff @(posedge clk_i) begin
      if (rst_ni && En.order && issue_v_i[1] && !issue_v_i[0])
        $error("g6lc_fetch_dbg: issue port 1 live without port 0");
    end
  end

  // ---- Fetch-supply neutral observation (P1 warm fetch) ------------------
  // The II=2 warm signature is already known structurally (I$ accepts only in
  // IDLE, responds in READ). What is NOT known is the joint distribution:
  // during refused cycles, could the IQ/backend have absorbed an overlapped
  // response? These counters classify every cycle exactly once, in priority
  // order, so "supply-bound" vs "demand-bound" is measured, not assumed.
  //   redirect  - flush/mispredict/reseed/bp_fire/kill/replay (correctness
  //               bubbles; the pipeline is deliberately restarted)
  //   take      - an I$ response was registered into the response stage
  //   refused   - req offered, I$ not ready (the II=2 arm), split by whether
  //               the IQ could have taken a packet that cycle
  //   iq_stall  - IQ full: backend-limited, overlap would not help
  //   halt      - controller halt
  //   be_stall  - entries offered to ID stage but not all accepted
  //   empty     - IQ fully empty and no staged response: starved
  //   idle      - nothing outstanding at all
  logic        supply_en;
  longint unsigned supply_row_limit;
  logic [63:0] supply_lo, supply_hi;
  int unsigned sup_total, sup_redir, sup_take, sup_accept;
  int unsigned sup_refused, sup_ref_iqrdy, sup_ref_iqfull;
  int unsigned sup_iq_stall, sup_halt, sup_be_stall, sup_empty, sup_idle;
  int unsigned iq_use_total;

  always_comb begin
    iq_use_total = 0;
    for (int unsigned k = 0; k < Slots; k++)
      iq_use_total += int'(iq_use_i[k]);
  end

  initial begin
    supply_en = $test$plusargs("fetch_supply");
    supply_lo = '0;
    supply_hi = {64{1'b1}};
    supply_row_limit = 30000;
    void'($value$plusargs("fetch_supply_lo=%h", supply_lo));
    void'($value$plusargs("fetch_supply_hi=%h", supply_hi));
    void'($value$plusargs("fetch_supply_limit=%d", supply_row_limit));
  end

  // verilog_lint: waive always-ff-non-reset
  always_ff @(posedge clk_i) begin
    automatic logic redir, active;
    if (!rst_ni) begin
      sup_total <= '0; sup_redir <= '0; sup_take <= '0; sup_accept <= '0;
      sup_refused <= '0; sup_ref_iqrdy <= '0; sup_ref_iqfull <= '0;
      sup_iq_stall <= '0; sup_halt <= '0; sup_be_stall <= '0;
      sup_empty <= '0; sup_idle <= '0;
    end else if (supply_en) begin
      redir = flush_i || is_mispredict_i || arch_reseed_i || bp_fire_i
              || kill_s1_i || kill_s2_i || replay_i;
      sup_total <= sup_total + 1;
      if (redir) begin
        sup_redir <= sup_redir + 1;
      end else if (icache_take_i) begin
        sup_take <= sup_take + 1;
      end else if (icache_req_i && !icache_rdy_i) begin
        sup_refused <= sup_refused + 1;
        if (iq_ready_i) sup_ref_iqrdy <= sup_ref_iqrdy + 1;
        else sup_ref_iqfull <= sup_ref_iqfull + 1;
      end else if (!iq_ready_i) begin
        sup_iq_stall <= sup_iq_stall + 1;
      end else if (halt_frontend_i) begin
        sup_halt <= sup_halt + 1;
      end else if (|issue_v_i && !(&fetch_entry_ready_i)) begin
        sup_be_stall <= sup_be_stall + 1;
      end else if (&iq_empty_i && !icache_valid_q_i) begin
        sup_empty <= sup_empty + 1;
      end else begin
        sup_idle <= sup_idle + 1;
      end
      if (icache_req_i && icache_rdy_i) sup_accept <= sup_accept + 1;

      // Per-cycle row only while fetch is doing something (ic-cycle
      // convention): a fully quiet pipeline emits nothing.
      active = icache_req_i || icache_rsp_i || icache_valid_q_i
               || !(&iq_empty_i) || !iq_ready_i || demand_req_i || pf_req_i
               || flush_i || is_mispredict_i || replay_i || halt_frontend_i
               || |issue_v_i;
      if (active && $time <= supply_row_limit
          && 64'(vaddr_q_i) >= supply_lo && 64'(vaddr_q_i) <= supply_hi)
        $display(
            "[fetch_supply] t=%0t req=%0d rdy=%0d rsp=%0d take=%0d qv=%0d dem=%0d dfire=%0d ftqfull=%0d ftqhv=%0d ifrdy=%0d iqrdy=%0d iqfull=%h iqempty=%h iquse=%0d bevld=%b berdy=%b bpf=%0d ars=%0d k1=%0d k2=%0d misp=%0d flush=%0d halt=%0d rpl=%0d unal=%0d lpend=%0d lbuf=%0d lcons=%0d pf=%0d npc=%h",
            $time, icache_req_i, icache_rdy_i, icache_rsp_i, icache_take_i,
            icache_valid_q_i, demand_req_i, demand_fire_i, ftq_full_i,
            ftq_head_valid_i, if_ready_i, iq_ready_i, iq_full_i, iq_empty_i,
            iq_use_total, issue_v_i, fetch_entry_ready_i, bp_fire_i,
            arch_reseed_i, kill_s1_i, kill_s2_i, is_mispredict_i, flush_i,
            halt_frontend_i, replay_i, serving_unaligned_i, leftover_pending_i,
            lbuf_hit_i, lbuf_consume_i, pf_req_i, npc_i);
    end
  end

  final begin
    if (supply_en)
      $display(
          "[fetch_supply_sum] total=%0d redir=%0d take=%0d accept=%0d refused=%0d ref_iqrdy=%0d ref_iqfull=%0d iq_stall=%0d halt=%0d be_stall=%0d empty=%0d idle=%0d",
          sup_total, sup_redir, sup_take, sup_accept, sup_refused,
          sup_ref_iqrdy, sup_ref_iqfull, sup_iq_stall, sup_halt,
          sup_be_stall, sup_empty, sup_idle);
  end

  logic unused_dbg;
  assign unused_dbg = |{snap.npc[0], snap.fetch_addr[0], snap.vaddr_q[0], snap.expected[0],
      snap.win_tag_v[0], snap.win_tag_e[0], snap.hw_off_f[0], snap.icache_valid_q,
      snap.leftover, snap.leftover_pend, snap.leftover_drop, |snap.hart, snap.same_win, snap.accept, |snap.live_mask, |snap.issue_v,
      |snap.cf_mask, snap.kill_s1, snap.kill_s2, snap.bp_valid, snap.spec, snap.redirect_hold,
      snap.redirect_hit, snap.win_rej, snap.arch_valid, |snap.arch_src, snap.restore_fire,
      |snap.geo_issue, |snap.geo_harts, |snap.geo_slots, |snap.geo_hold_max, |snap.hold_age,
      |arch_pc_i, |resolve_pc_i, Geo.smt, leftover_valid_i, |leftover_pc_i, |leftover_lo_i,
      hold_bound_reported_q, supply_en, |supply_lo, |supply_hi,
      iq_ready_i, demand_req_i, demand_fire_i, ftq_full_i, ftq_head_valid_i,
      lbuf_hit_i, lbuf_consume_i, pf_req_i, if_ready_i, halt_frontend_i,
      bp_fire_i, arch_reseed_i, |fetch_entry_ready_i, |iq_full_i, |iq_empty_i,
      |iq_use_i, icache_req_i, icache_rdy_i, icache_rsp_i, icache_take_i,
      Geo.rvc, Geo.ftq, Geo.rvh, En.align, En.accept, En.redirect, En.trap_hold,
      En.bp_hint, |data_q_i, |slot_instr_i, |slot_bytes_ok};

endmodule

bind frontend g6lc_fetch_dbg #(
    .CVA6Cfg(CVA6Cfg)
) i_g6lc_fetch_dbg (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .npc_i              (npc_q),
    .fetch_addr_i       (fetch_address),
    .vaddr_q_i          (icache_vaddr_q),
    .icache_valid_q_i   (icache_valid_q),
    .data_q_i           (icache_data_q),
    .serving_unaligned_i(serving_unaligned),
    .leftover_pending_i (leftover_pending),
    .leftover_valid_i   (leftover_valid),
    .leftover_pc_i      (leftover_pc),
    // The carried halfword is not a realigner output: it is observed
    // hierarchically so the synthesizable port list stays unchanged for a
    // translate_off-only check.
    .leftover_lo_i      (i_instr_realign.carry_instr_q),
    .hart_i             (8'(smt_hart_i)),
    .slot_v_i           (instruction_valid),
    .slot_pc_i          (addr),
    .slot_instr_i       (instr),
    .slot_cf_i          (cf_type),
    .issue_v_i          (fetch_entry_valid_o),
    .kill_s1_i          (kill_s1),
    .kill_s2_i          (kill_s2),
    .bp_valid_i         (bp_valid),
    .spec_i             (spec_req),
    .flush_i            (flush_i),
    .is_mispredict_i    (is_mispredict),
    .replay_i           (replay),
    .redirect_hold_i    (redirect_hold),
    .redirect_hit_i     (redirect_hit),
    .redirect_pc_i      (redirect_pc_q),
    .arch_valid_i       (arch_valid),
    .arch_pc_i          (arch_pc),
    .resolve_pc_i       (resolved_branch_i.pc),
    .smt_restore_i      (smt_restore_i),
    .set_debug_pc_i     (set_debug_pc_i),
    .set_pc_commit_i    (set_pc_commit_i),
    .ex_valid_i         (ex_valid_i),
    .eret_i             (eret_i),
    .icache_req_i       (icache_dreq_o.req),
    .icache_rdy_i       (icache_dreq_i.ready),
    .icache_rsp_i       (icache_dreq_i.valid),
    .icache_take_i      (icache_take),
    .iq_ready_i         (instr_queue_ready),
    .demand_req_i       (demand_req),
    .demand_fire_i      (demand_fire),
    .ftq_full_i         (ftq_full),
    .ftq_head_valid_i   (ftq_head_valid),
    .lbuf_hit_i         (lbuf_hit),
    .lbuf_consume_i     (lbuf_consume),
    .pf_req_i           (pf_req),
    .if_ready_i         (if_ready),
    .halt_frontend_i    (halt_frontend_i),
    .bp_fire_i          (bp_fire),
    .arch_reseed_i      (arch_reseed),
    .fetch_entry_ready_i(fetch_entry_ready_i),
    .iq_full_i          (i_instr_queue.instr_queue_full),
    .iq_empty_i         (i_instr_queue.instr_queue_empty),
    .iq_use_i           (i_instr_queue.instr_queue_usage)
);
//pragma translate_on
