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
    parameter int unsigned NI = 2
) (
    input logic clk_i
);

`ifdef FORMAL
  import ariane_pkg::*;

  localparam int unsigned VLEN  = 32;
  localparam int unsigned XLEN  = 32;
  localparam int unsigned GPLEN = 32;
  localparam int unsigned FUW   = 1;
  localparam int unsigned SLOTS = FW / 16;
  localparam int unsigned HARTW = (NH > 1) ? $clog2(NH) : 1;

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

  // --- stimulus -------------------------------------------------------------
  logic            flush_i, halt_i, set_pc_commit_i, set_debug_pc_i, eret_i, ex_valid_i;
  logic [VLEN-1:0] boot_addr_i, pc_commit_i, epc_i, trap_vector_base_i;
  bpr_t            resolved_branch_i;
  idrsp_t          icache_dreq_i;
  logic [NI-1:0]   fetch_entry_ready_i;

  idreq_t          icache_dreq_o;
  fe_t   [NI-1:0]  fetch_entry_o;
  logic  [NI-1:0]  fetch_entry_valid_o;

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
      .icache_dreq_i,
      .icache_dreq_o,
      .fetch_entry_o,
      .fetch_entry_valid_o,
      .fetch_entry_ready_i
  );

  // The I$ returns window-aligned addresses; anything else is a question the
  // cache never asks and the cursor arithmetic has no meaning for.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (icache_dreq_i.vaddr[AB-1:0] == '0);
      assume (trap_vector_base_i[0] == 1'b0);
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
  logic hold_now, hold_prev_q, hit_prev_q, flush_prev_q, arch_prev_q;
  assign hold_now = dut.redirect_hold;

  always_ff @(posedge clk_i) begin
    hold_prev_q  <= hold_now;
    hit_prev_q   <= dut.redirect_hit;
    flush_prev_q <= flush_i;
    // Any architectural redirect source may legitimately retarget a pending one.
    arch_prev_q  <= ex_valid_i | eret_i | set_pc_commit_i | set_debug_pc_i |
                    resolved_branch_i.is_mispredict;
  end

  // --- I9 safety: no SILENT release ----------------------------------------
  // A hold may only stop because the target arrived (redirect_hit), because the
  // frontend was flushed, or because a new architectural redirect superseded it.
  // Anything else is the `NEGATIVE.md` s1 early-lift class.
  always_ff @(posedge clk_i) begin
    if (rst_ni && hold_prev_q && !hold_now) begin
      assert (hit_prev_q || flush_prev_q || arch_prev_q);
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
  // not wander off the target while the hold is up.
  always_ff @(posedge clk_i) begin
    if (rst_ni && hold_now && icache_dreq_o.req) begin
      assert (icache_dreq_o.vaddr == dut.redirect_pc_q);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (hold_now);
      cover (hold_prev_q && !hold_now && hit_prev_q);
      cover (ex_valid_i);
    end
  end
`endif

endmodule
