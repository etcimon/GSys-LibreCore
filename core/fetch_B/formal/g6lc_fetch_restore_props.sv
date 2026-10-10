// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: hart-blind frontend state vs SMT restore, against the LIVE
// `frontend` (core/fetch_B/frontend.sv).
//
// The FTQ, FDIP prefetcher and loop buffer are hart-blind: they hold fetch
// state produced by whichever hart stream was active when it was pushed.
// `smt_restore_i` (SRC_RESTORE) switches the stream to the peer hart and
// reseeds the PC; any entry pushed before the restore belongs to the old
// stream. The loop buffer is keyed by virtual address and the two harts run
// different address spaces, so a stale `armed_q`/`hit_o` across a switch is a
// correctness bug, not a tuning issue.
//
// Property (the step-1 gate for enabling FtqDepth/FdipEn/LoopBufEn on a
// two-hart package): when a restore is accepted (`arch_src == SRC_RESTORE`),
// the next cycle the FTQ holds no entry pushed before the restore (empty, or
// exactly the reseeded restore PC) and the loop buffer is unarmed (no hit is
// possible).
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_restore.sby

module g6lc_fetch_restore_props #(
    parameter int unsigned FW   = 64,
    parameter int unsigned AB   = 3,
    parameter int unsigned NH   = 2,
    parameter int unsigned NI   = 2,
    parameter int unsigned FTQD = 8,
    parameter int unsigned LBE  = 8,
    parameter int unsigned VLEN  = 32,
    parameter int unsigned XLEN  = 32,
    parameter int unsigned GPLEN = 32,
    parameter int unsigned FUW   = 1,
    parameter int unsigned TOKW  = 2,
    parameter int unsigned HARTW = (NH > 1) ? $clog2(NH) : 1
) (
    input logic clk_i,
    // Stimulus enters through ports so every use sees one coherent free
    // value per cycle; an undriven internal logic is split into independent
    // free variables by the slang frontend and the property cannot be trusted.
    input logic flush_i,
    input logic flush_bp_i,
    input logic halt_i,
    input logic halt_frontend_i,
    input logic set_pc_commit_i,
    input logic mem_replay_pc_i,
    input logic set_debug_pc_i,
    input logic debug_mode_i,
    input logic eret_i,
    input logic ex_valid_i,
    input logic peer_restart_valid_i,
    input logic [HARTW-1:0] commit_hart_i,
    input logic [HARTW-1:0] smt_hart_i,
    input logic smt_restore_i,
    input logic [VLEN-1:0] smt_npc_restore_i,
    input logic [VLEN-1:0] peer_restart_pc_i,
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
    c.LoopBufEn            = 1'b1;
    c.LoopBufEntries       = LBE;
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
    logic            ckpt_v;    // T21
    logic [7:0]      ckpt_idx;  // T21
    logic            is_call;   // T21
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
    logic             ckpt_v;    // T21
    logic [7:0]       ckpt_idx;  // T21
    logic             is_call;   // T21
    logic [VLEN-1:0]  next_pc;   // T21
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
                               ckpt_restore: rb_ckpt_restore_i,
                               ckpt_v: 1'b0, ckpt_idx: 8'd0, is_call: 1'b0, next_pc: '0};
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
      .flush_bp_i,
      .flush_i,
      .halt_i,
      .halt_frontend_i,
      .set_pc_commit_i,
      .commit_hart_i,
      .pc_commit_i,
      .mem_replay_pc_i,
      .ex_valid_i,
      .resolved_branch_i,
      .eret_i,
      .epc_i,
      .trap_vector_base_i,
      .set_debug_pc_i,
      .debug_mode_i,
      .smt_hart_i,
      .smt_restore_i,
      .smt_npc_restore_i,
      .peer_restart_valid_i,
      .peer_restart_pc_i,
      .npc_q_o              (),
      .fetch_frontier_pc_o  (),
      .queue_oldest_valid_o (),
      .queue_oldest_pc_o    (),
      .smt_trap_hold_o      (),
      .icache_dreq_i,
      .icache_dreq_o,
      .fetch_entry_o,
      .fetch_entry_valid_o,
      .fetch_entry_ready_i
  );

  // --- restore bookkeeping ---------------------------------------------------
  // A restore is "accepted" when it wins the arch_src encode; the same cycle
  // arch_reseed pushes the restore PC into the FTQ.
  logic restore_accept;
  assign restore_accept = dut.arch_valid &&
      (dut.arch_src == g6lc_fetch_pkg::SRC_RESTORE);

  logic             restore_q;
  logic             restore_misp_q;
  logic [VLEN-1:0]  restore_pc_q;
  always_ff @(posedge clk_i) begin
    restore_q      <= rst_ni && restore_accept;
    restore_misp_q <= dut.is_mispredict;
    restore_pc_q   <= smt_npc_restore_i;
  end

  // --- the property ----------------------------------------------------------
  // Next cycle after an accepted restore the FTQ must hold nothing pushed
  // before the restore: empty, or exactly the reseeded restore PC; and the
  // loop buffer must be unarmed (no stale hit is possible).
  always_ff @(posedge clk_i) begin
    if (rst_ni && restore_q) begin
      assert (dut.gen_ftq.i_ftq.count_q == '0 ||
              (dut.gen_ftq.i_ftq.count_q == 1 &&
               dut.gen_ftq.i_ftq.mem_q[0].vaddr == restore_pc_q));
      assert (!dut.gen_ftq.gen_lbuf.i_lbuf.armed_q);
      // The old stream's in-flight request is killed: its token is forgotten,
      // so a late response is dropped by identity instead of being stamped
      // with the incoming hart. No taken block or stale mid-stream state may
      // be presented either.
      assert (!dut.want_valid_q);
      assert (!dut.inflight_q);
      assert (!dut.icache_valid_q);
      // Queue parcels of the old stream are dropped: restart_frontier banks
      // the oldest undelivered PC and the refetched stream covers them —
      // leaving them queued would deliver each instruction twice.
      assert (!(|dut.fetch_entry_valid_o));
      // The pending-prediction filter is cleared unless a real mispredict
      // fired on the restore cycle (it re-arms for the resolve target).
      assert (!dut.bp_pend_q || restore_misp_q);
    end
  end

  // --- witnesses -------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // restore that actually drops/reseeds queued state
      cover (restore_accept && dut.gen_ftq.i_ftq.count_q != '0);
      // restore while the loop buffer was armed for the old stream
      cover (restore_accept && dut.gen_ftq.gen_lbuf.i_lbuf.armed_q);
      // restore with an I$ request still in flight (the pre-M3d hole: the
      // response would return stamped with the incoming hart)
      cover (restore_accept && dut.want_valid_q);
      cover (restore_accept);
    end
  end
`endif

endmodule
