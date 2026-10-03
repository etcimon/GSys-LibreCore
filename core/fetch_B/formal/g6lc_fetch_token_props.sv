// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: fetch-response ownership by REQUEST TOKEN against the LIVE
// `frontend` (core/fetch_B/frontend.sv).
//
// The environment is an independent ledger of the I$ contract, not the
// frontend's own bookkeeping: it records the one request the I$ may hold,
// marks it killed when the frontend asserts kill_s1/kill_s2 while it is
// outstanding, and is free to return that request's response at any later
// cycle -- which is exactly how a stale window reached decode before the
// token repair (a hit one cycle after a flush, a refill after bp_fire).
//
// Proven: every response the frontend TAKES belongs to the outstanding
// request and that request was never killed after acceptance. A same-address
// refetch after a kill is therefore distinguished by token, not by address.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_token.sby
//      negative: FAULT_REVIEW_FETCH_TOKEN_MUTATE=1 (frontend take gate removed)

module g6lc_fetch_token_props #(
    parameter int unsigned FW   = 64,
    parameter int unsigned AB   = 3,
    parameter int unsigned NH   = 1,
    parameter int unsigned NI   = 2,
    parameter int unsigned FTQD = 0,
    parameter int unsigned VLEN  = 32,
    parameter int unsigned XLEN  = 32,
    parameter int unsigned GPLEN = 32,
    parameter int unsigned FUW   = 1,
    parameter int unsigned TOKW  = 2,
    parameter int unsigned HARTW = (NH > 1) ? $clog2(NH) : 1
) (
    input logic clk_i,
    // the I$ may silently drop a killed request (KILL_MISS / IDLE re-arm)
    input logic env_drop_i,
    // Stimulus enters through ports so every use sees one coherent free
    // value per cycle; an undriven internal logic is split into independent
    // free variables by the slang frontend and the ledger cannot be trusted.
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
    input logic [TOKW-1:0] rsp_token_i,
    input logic [VLEN-1:0] rsp_vaddr_i,
    input logic [NI-1:0] fetch_entry_ready_i
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
    c.FtqDepth             = FTQD;
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
    logic [TOKW-1:0] token;
    logic [VLEN-1:0] vaddr;
  } idreq_t;

  typedef struct packed {
    logic            ready;
    logic            valid;
    logic [FW-1:0]   data;
    logic [FUW-1:0]  user;
    logic [TOKW-1:0] token;
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
      .halt_frontend_i (1'b0),
      .set_pc_commit_i,
      .commit_hart_i   ('0),
      .pc_commit_i,
      .mem_replay_pc_i (1'b0),
      .ex_valid_i,
      .resolved_branch_i,
      .eret_i,
      .epc_i,
      .trap_vector_base_i,
      .set_debug_pc_i,
      .debug_mode_i    (1'b0),
      .smt_hart_i      ('0),
      .smt_restore_i   (1'b0),
      .smt_npc_restore_i ('0),
      .peer_restart_valid_i (1'b0),
      .peer_restart_pc_i    ('0),
      .icache_dreq_i,
      .icache_dreq_o,
      .fetch_entry_o,
      .fetch_entry_valid_o,
      .fetch_entry_ready_i
  );

  // --- independent I$ ledger -------------------------------------------------
  // One request may be outstanding. It is accepted when the frontend requests
  // and the environment is ready; a request offered under kill_s1 is dropped
  // by the I$ (IDLE re-arms), so it never enters the ledger. The response may
  // return in any later cycle, including the cycle a new request is accepted
  // (hit/request overlap). A kill asserted while the request is outstanding
  // and not being answered marks it killed; its response may still return.
  logic            out_v_q, out_killed_q;
  logic [TOKW-1:0] out_tok_q;
  logic [VLEN-1:0] out_vaddr_q;
  logic            accept, respond, kill_now;

  assign kill_now = dut.kill_s1 | dut.kill_s2;
  assign accept   = icache_dreq_o.req & icache_dreq_i.ready & ~dut.kill_s1;
  assign respond  = icache_dreq_i.valid;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      out_v_q      <= 1'b0;
      out_killed_q <= 1'b0;
      out_tok_q    <= '0;
      out_vaddr_q  <= '0;
    end else begin
      if (accept) begin
        out_v_q      <= 1'b1;
        out_killed_q <= kill_now;
        out_tok_q    <= icache_dreq_o.token;
        out_vaddr_q  <= icache_dreq_o.vaddr;
      end else if (respond) begin
        out_v_q      <= 1'b0;
        out_killed_q <= 1'b0;
      end else if (kill_now && out_v_q) begin
        out_killed_q <= 1'b1;
      end else if (out_killed_q && env_drop_i) begin
        out_v_q      <= 1'b0;
        out_killed_q <= 1'b0;
      end
    end
  end

  // Environment constraints: respond only to the outstanding request and only
  // with its identity; accept a new request only when none is outstanding or
  // the outstanding one is being answered this cycle.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (!respond || out_v_q);
      assume (!respond || (icache_dreq_i.token == out_tok_q && icache_dreq_i.vaddr == out_vaddr_q));
      assume (!icache_dreq_i.ready || !out_v_q || respond);
      assume (icache_dreq_i.vaddr[AB-1:0] == '0);
      assume (trap_vector_base_i[0] == 1'b0);
    end
  end

  // --- ownership: a taken response is the live, unkilled request -----------
  always_ff @(posedge clk_i) begin
    if (rst_ni && dut.icache_take && respond) begin
      assert (out_v_q);
      assert (icache_dreq_i.token == out_tok_q);
      assert (!out_killed_q);
    end
  end

  // The frontend's own view agrees with the ledger: the token it will accept
  // is the outstanding one whenever it expects a response at all.
  always_ff @(posedge clk_i) begin
    if (rst_ni && dut.want_valid_q) assert (out_v_q && dut.want_token_q == out_tok_q);
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (dut.icache_take && respond);
      cover (respond && out_killed_q && !dut.icache_take);
      cover (respond && out_killed_q && icache_dreq_o.req && icache_dreq_o.vaddr == out_vaddr_q);
      cover (accept && respond);
    end
  end

  // --- FTQ liveness pin: a prediction that could not push its target must not
  // arm the control-flow hold, otherwise nothing is ever demanded again (the
  // FTQ was flushed by the same prediction). Only the FTQ path has the hold.
  if (FTQD != 0) begin : gen_ftq_hold_pin
    logic bp_unpushed_q;
    always_ff @(posedge clk_i) begin
      // ... and the hold was down, so the only thing that could raise it is
      // this very prediction.
      bp_unpushed_q <= rst_ni && dut.bp_fire && !dut.ftq_push && !dut.gen_ftq.cf_hold_q;
    end
    always_ff @(posedge clk_i) begin
      if (rst_ni && bp_unpushed_q) assert (!dut.gen_ftq.cf_hold_q);
      if (rst_ni) cover (bp_unpushed_q);
    end
  end
`endif

endmodule
