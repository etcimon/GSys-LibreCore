// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: the SAFETY half of I9/I23 against the LIVE `frontend`
// (`core/fetch_B/frontend.sv`, predictors and queue included).
//
// I9 has two clauses and they need different treatment:
//
//   SAFETY  (proven here) "exception entry to mtvec is HELD until that
//           instruction is consumed by decode", and its sharp corollary: the
//           hold is never released except by the target actually arriving or by
//           an architectural redirect. `NEGATIVE.md` s1 is the unbounded-hold
//           family and the recorded negative there is a SILENT RELEASE -- a
//           hold that lifted early. That is a safety property and it is exactly
//           what this file pins.
//
//   LIVENESS (deliberately NOT proven here) "...and the hold is bounded (I23)".
//           A hold terminates only when the I$ eventually returns the target, so
//           boundedness is conditional on an environment fairness assumption. A
//           BMC would only show "no violation within N cycles", which is not the
//           claim; and `prove` would need the fairness assumption stated, at
//           which point the proof is about the assumption. It therefore stays an
//           L3 OBSERVATION (`g6lc_fetch_dbg` reports `hold_age > geo.hold_max`
//           once per run as a warning) -- and per NEGATIVE that is on purpose:
//           silently releasing a hold to make a bound hold is the bug, not the
//           fix. See core-fetch/SPEC.md s10.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_hold.sby
//      cva6-build verify --formal

module g6lc_fetch_hold_props #(
    parameter int unsigned FW = 64,
    parameter int unsigned AB = 3,
    parameter int unsigned NH = 2,
    parameter int unsigned NI = 2,
    parameter int unsigned VLEN  = 32,
    parameter int unsigned XLEN  = 32,
    parameter int unsigned GPLEN = 32,
    parameter int unsigned FUW   = 1,
    parameter int unsigned HARTW = (NH > 1) ? $clog2(NH) : 1
) (
    input logic clk_i,
    // Stimulus enters through ports: an undriven internal logic is split into
    // independent free variables by the slang frontend, and the alignment and
    // token assumptions below would then constrain nothing the DUT sees.
    input logic flush_i,
    input logic halt_i,
    input logic set_pc_commit_i,
    input logic set_debug_pc_i,
    input logic eret_i,
    input logic ex_valid_i,
    input logic [VLEN-1:0] boot_addr_i,
    input logic [VLEN-1:0] pc_commit_i,
    input logic [VLEN-1:0] epc_i,
    input logic [VLEN-1:0] trap_vector_base_i,
    input logic rb_valid_i,
    input logic [VLEN-1:0] rb_pc_i,
    input logic [VLEN-1:0] rb_target_i,
    input logic rb_is_mispredict_i,
    input logic rb_is_taken_i,
    input logic [2:0] rb_cf_type_i,
    input logic [HARTW-1:0] rb_hart_id_i,
    input logic rb_ckpt_restore_i,
    input logic rsp_ready_i,
    input logic rsp_valid_i,
    input logic [FW-1:0] rsp_data_i,
    input logic [FUW-1:0] rsp_user_i,
    input logic [1:0] rsp_token_i,
    input logic [VLEN-1:0] rsp_vaddr_i,
    input logic [NI-1:0] fetch_entry_ready_i,
    // Hart switch: the thread selector restores a hart only while no redirect
    // is pending (assumed below; the selector's own proof owes it).
    input logic smt_restore_i,
    input logic [VLEN-1:0] smt_npc_restore_i,
    input logic [HARTW-1:0] smt_hart_i,
    input logic [HARTW-1:0] commit_hart_i,
    // T6b-2a: peer-hart flush restart of the active hart (SRC_PEER), a free
    // input here like every other redirect source.
    input logic peer_restart_valid_i,
    input logic [VLEN-1:0] peer_restart_pc_i
);

`ifdef FORMAL
  import ariane_pkg::*;

  localparam int unsigned SLOTS = FW / 16;

  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c;
    c                      = config_pkg::cva6_cfg_empty;
    c.XLEN                 = XLEN;
    c.VLEN                 = VLEN;
    c.GPLEN                = GPLEN;
    c.FETCH_WIDTH          = FW;
    c.FETCH_ALIGN_BITS     = AB;
    c.FETCH_USER_WIDTH     = FUW;
    c.INSTR_PER_FETCH      = SLOTS;
    c.LOG2_INSTR_PER_FETCH = $clog2(SLOTS);
    c.RVC                  = 1'b1;
    c.NrHarts              = NH;
    c.NrIssuePorts         = NI;
    c.FtqDepth             = 0;  // smt2 ships FtqDepth=0; redirect_rehold needs !ftq
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t Cfg = mk_cfg();

  // Layout-identical to the localparam types in `core/cva6.sv`.
  typedef struct packed {
    logic [XLEN-1:0]  cause;
    logic [XLEN-1:0]  tval;
    logic [GPLEN-1:0] tval2;
    logic [31:0]      tinst;
    logic             gva;
    logic             valid;
  } exc_t;

  typedef struct packed {
    cf_t             cf;
    logic [VLEN-1:0] predict_address;
  } bp_sbe_t;

  typedef struct packed {
    logic [VLEN-1:0]  address;
    logic [31:0]      instruction;
    bp_sbe_t          branch_predict;
    exc_t             ex;
    logic [HARTW-1:0] hart_id;
  } fe_t;

  typedef struct packed {
    logic             valid;
    logic [VLEN-1:0]  pc;
    logic [VLEN-1:0]  target_address;
    logic             is_mispredict;
    logic             is_taken;
    cf_t              cf_type;
    logic [HARTW-1:0] hart_id;
    logic             ckpt_restore;
  } bpr_t;

  typedef struct packed {
    logic            req;
    logic            kill_s1;
    logic            kill_s2;
    logic            spec;
    logic [1:0]      token;
    logic [VLEN-1:0] vaddr;
  } idreq_t;

  typedef struct packed {
    logic            ready;
    logic            valid;
    logic [FW-1:0]   data;
    logic [FUW-1:0]  user;
    logic [1:0]      token;
    logic [VLEN-1:0] vaddr;
    exc_t            ex;
  } idrsp_t;

  // --- stimulus (assembled from ports) ---------------------------------------
  bpr_t   resolved_branch_i;
  idrsp_t icache_dreq_i;
  assign resolved_branch_i = '{valid: rb_valid_i, pc: rb_pc_i, target_address: rb_target_i,
                               is_mispredict: rb_is_mispredict_i, is_taken: rb_is_taken_i,
                               cf_type: cf_t'(rb_cf_type_i), hart_id: rb_hart_id_i,
                               ckpt_restore: rb_ckpt_restore_i};
  assign icache_dreq_i = '{ready: rsp_ready_i, valid: rsp_valid_i, data: rsp_data_i,
                           user: rsp_user_i, token: rsp_token_i, vaddr: rsp_vaddr_i,
                           ex: exc_t'('0)};

  idreq_t          icache_dreq_o;
  fe_t   [NI-1:0]  fetch_entry_o;
  logic  [NI-1:0]  fetch_entry_valid_o;
  logic  [VLEN-1:0] fetch_frontier_pc;

  logic rst_init_q = 1'b1;
  logic rst_ni;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  assign rst_ni = ~rst_init_q;

  frontend #(
      .CVA6Cfg      (Cfg),
      .bp_resolve_t (bpr_t),
      .fetch_entry_t(fe_t),
      .icache_dreq_t(idreq_t),
      .icache_drsp_t(idrsp_t)
  ) dut (
      .clk_i,
      .rst_ni,
      .boot_addr_i,
      .flush_i,
      .halt_i,
      .set_pc_commit_i,
      .pc_commit_i,
      .mem_replay_pc_i (1'b0),
      .ex_valid_i,
      .resolved_branch_i,
      .eret_i,
      .epc_i,
      .trap_vector_base_i,
      .set_debug_pc_i,
      .smt_hart_i,
      .smt_restore_i,
      .smt_npc_restore_i,
      .peer_restart_valid_i,
      .peer_restart_pc_i,
      .fetch_frontier_pc_o(fetch_frontier_pc),
      .commit_hart_i,
      .icache_dreq_i,
      .icache_dreq_o,
      .fetch_entry_o,
      .fetch_entry_valid_o,
      .fetch_entry_ready_i
  );

  // The I$ returns window-aligned addresses; anything else is a question the
  // cache never asks and the cursor arithmetic has no meaning for.
  // Hart switch contract: the selector never restores a hart while the
  // frontend still holds a pending redirect. The RTL exports only the trap
  // case as `smt_trap_hold_o`; the general case is an obligation on the
  // selector (recorded in AGENTS-todo), not something this proof may assume
  // silently -- hence the explicit assumption here.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (icache_dreq_i.vaddr[AB-1:0] == '0);
      assume (trap_vector_base_i[0] == 1'b0);
      assume (!smt_restore_i || !dut.redirect_pend_q);
    end
  end

  // Token ledger: the environment returns the token of the last accepted
  // request, which is what a real I$ echoes on its response.
  logic [1:0] tok_q;
  always_ff @(posedge clk_i)
    if (icache_dreq_o.req && icache_dreq_i.ready)
      tok_q <= icache_dreq_o.token;

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (!icache_dreq_i.valid || icache_dreq_i.token == tok_q);
    end
  end

  // --- observe the hold state ----------------------------------------------
  logic hold_now, hold_prev_q, hit_prev_q, flush_prev_q, arch_prev_q, accept_prev_q;
  assign hold_now = dut.redirect_hold;

  always_ff @(posedge clk_i) begin
    hold_prev_q   <= hold_now;
    hit_prev_q    <= dut.redirect_hit;
    flush_prev_q  <= flush_i;
    // Any architectural redirect source may legitimately retarget a pending one.
    arch_prev_q   <= ex_valid_i | eret_i | set_pc_commit_i | set_debug_pc_i |
                     resolved_branch_i.is_mispredict | smt_restore_i |
                     peer_restart_valid_i;
    // The held target was re-presented and the I$ accepted it: the redirect is
    // in flight again (pend_q stays up until it arrives), so the HOLD ends but
    // the redirect itself does not.
    accept_prev_q <= dut.redirect_accept;
  end

  // --- I9 safety: no SILENT release ----------------------------------------
  // A hold may only stop because the target arrived (redirect_hit), because the
  // I$ re-accepted the held target (redirect_accept), because the frontend was
  // flushed, or because a new architectural redirect superseded it. Anything
  // else is the `NEGATIVE.md` s1 early-lift class.
  always_ff @(posedge clk_i) begin
    if (rst_ni && hold_prev_q && !hold_now) begin
      assert (hit_prev_q || accept_prev_q || flush_prev_q || arch_prev_q);
    end
  end

  // Re-acceptance ends the hold, never the redirect: the target is still owed.
  always_ff @(posedge clk_i) begin
    if (rst_ni && hold_prev_q && !hold_now && accept_prev_q && !flush_prev_q && !arch_prev_q) begin
      assert (dut.redirect_pend_q);
    end
  end

  // --- I9 safety: a hold means a redirect really is outstanding -------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && hold_now) begin
      // redirect_rehold's own precondition, now checked on the live state.
      assert (dut.redirect_pend_q);
      assert (dut.redirect_lost_q);
      assert (!dut.redirect_hit);
      // FtqDepth=0 in this envelope, so the FTQ path must never be the reason.
      assert (Cfg.FtqDepth == 0);
    end
  end

  // --- I9 safety: while holding, the request is the held target -------------
  // "Held until consumed" observably means the address presented to the I$ does
  // not wander off the target while the hold is up. The one legitimate
  // exception is the cycle a NEW architectural source fires (I8: exception,
  // eret, commit, debug, restore outrank the hold): the request then presents
  // the new target and redirect_pc_q takes it at the edge, which the release
  // rule above already treats as a supersede, not a silent lift.
  always_ff @(posedge clk_i) begin
    if (rst_ni && hold_now && icache_dreq_o.req && !dut.arch_valid) begin
      assert (icache_dreq_o.vaddr == dut.redirect_pc_q);
    end
  end

  // --- I8 safety: an outranked mispredict leaves no trace ---------------------
  // A branch resolving in the cycle a commit-side redirect (or trap/eret) fires
  // is younger than that redirect and squashed by it. It must not arm the
  // mispredict target filter: absent a same-cycle prediction (the only other
  // writer of bp_tgt_q), the filter target is unchanged the cycle after.
  logic misp_outranked_q;
  logic [VLEN-1:0] misp_tgt_before_q;
  always_ff @(posedge clk_i) begin
    // Same hart qualification as the frontend: a resolution for the other hart
    // is not a redirect here, and PC_COMMIT reseeds only the active hart.
    misp_outranked_q <= rst_ni && resolved_branch_i.valid && resolved_branch_i.is_mispredict &&
                        rb_hart_id_i == smt_hart_i &&
                        ((set_pc_commit_i && commit_hart_i == smt_hart_i) || ex_valid_i || eret_i) &&
                        !dut.bp_fire;
    misp_tgt_before_q <= dut.bp_tgt_q;
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni && misp_outranked_q) begin
      assert (dut.bp_tgt_q == misp_tgt_before_q);
    end
  end

  // --- T6b-2a SRC_PEER: peer restart registers its target -------------------
  // With no higher-priority source the peer restart is the redirect: its PC is
  // registered and presented. A same-cycle active-hart commit redirect
  // outranks it (SRC_COMMIT > SRC_PEER).
  logic peer_fire_q, peer_outranked_q;
  logic [VLEN-1:0] peer_pc_q, peer_commit_pc_q;
  always_ff @(posedge clk_i) begin
    peer_fire_q <= rst_ni && peer_restart_valid_i && !ex_valid_i && !eret_i &&
                   !g6lc_fetch_pkg::commit_for_hart(
                       Cfg.NrHarts > 1, set_pc_commit_i,
                       8'(commit_hart_i), 8'(smt_hart_i));
    peer_outranked_q <= rst_ni && peer_restart_valid_i && !ex_valid_i && !eret_i &&
                        g6lc_fetch_pkg::commit_for_hart(
                            Cfg.NrHarts > 1, set_pc_commit_i,
                            8'(commit_hart_i), 8'(smt_hart_i));
    peer_pc_q        <= peer_restart_pc_i;
    // mem_replay_pc_i is tied 0 in this fixture; commit_next_pc's halt term
    // still applies.
    peer_commit_pc_q <= pc_commit_i + (halt_i ? '0 : {{VLEN - 3{1'b0}}, 3'b100});
  end
  // The winning redirect presents its target combinationally the cycle it
  // fires (fetch_address = arch_pc); the registered copy is checked on the
  // next edge.
  always_ff @(posedge clk_i) begin
    if (rst_ni && peer_restart_valid_i && !ex_valid_i && !eret_i &&
        !g6lc_fetch_pkg::commit_for_hart(
            Cfg.NrHarts > 1, set_pc_commit_i,
            8'(commit_hart_i), 8'(smt_hart_i)) &&
        icache_dreq_o.req) begin
      assert (icache_dreq_o.vaddr == peer_restart_pc_i);
    end
    if (rst_ni && peer_restart_valid_i && !ex_valid_i && !eret_i &&
        g6lc_fetch_pkg::commit_for_hart(
            Cfg.NrHarts > 1, set_pc_commit_i,
            8'(commit_hart_i), 8'(smt_hart_i)) &&
        icache_dreq_o.req) begin
      assert (icache_dreq_o.vaddr ==
              pc_commit_i + (halt_i ? '0 : {{VLEN - 3{1'b0}}, 3'b100}));
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni && peer_fire_q) begin
      assert (dut.redirect_pc_q == peer_pc_q);
    end
    if (rst_ni && peer_outranked_q) begin
      assert (dut.redirect_pc_q == peer_commit_pc_q);
    end
  end

  // --- T6b-3b: the restart frontier's fetch-side candidate ------------------
  // cva6's peer restart samples this output as the killed fetch stream's
  // frontier. While a redirect is owed it is the redirect target — the
  // oldest undelivered position; with an accepted request still in flight it
  // is that parcel; otherwise the NPC cursor. A parcel killed in flight is
  // therefore never skipped by the restart (the 0x80008c2e loss).
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (dut.redirect_pend_q)
        assert (fetch_frontier_pc == dut.redirect_pc_q);
      else if (dut.inflight_q)
        assert (fetch_frontier_pc == dut.inflight_addr_q);
      else
        assert (fetch_frontier_pc == dut.npc_q);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (hold_now);
      cover (hold_prev_q && !hold_now && hit_prev_q);
      cover (ex_valid_i);
      cover (misp_outranked_q);
    end
  end
`endif

endmodule
