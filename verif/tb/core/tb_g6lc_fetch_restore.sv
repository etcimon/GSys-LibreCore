// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Directed fetch-leaf case for the M3 counterexample: hart-blind frontend
// state must not survive an SMT restore. The live `frontend`
// (core/fetch_B/frontend.sv) is exercised at the g6lc64_smt2_ooo_int uplift
// shape (NrHarts=2, FtqDepth=8, LoopBufEn=1).
//
// Scenario: let fetch run until the loop buffer is armed on a static
// backward-branch loop (a real bp_fire -> capture sequence through the I$
// stub, not a forced internal state), then stall the demand long enough that
// several pre-restore entries sit in the FTQ. Pulse smt_restore_i: the next
// cycle the FTQ must hold nothing pushed before the restore (reseeded to the
// restore PC only) and the loop buffer must be unarmed.
//
// Mutation: -DG6LC_MUT_FETCH_RESTORE_NOFLUSH drops the restore term from the
// hart-blind flush wires (the pre-M3 behaviour); this bench must then fail
// with FETCH_RESTORE_*.
//
// Run (local): verilator --cc --main --exe --timing --assert --threads 1
//   -Wno-fatal --top-module tb_g6lc_fetch_restore <rtl files> tb_g6lc_fetch_restore.sv

module tb_g6lc_fetch_restore;
  import ariane_pkg::*;
  parameter int unsigned NH   = 2;
  parameter int unsigned NI   = 2;
  parameter int unsigned FTQD = 8;
  parameter int unsigned LBE  = 8;
  parameter int unsigned VLEN = 64;
  localparam int unsigned HW   = NH > 1 ? $clog2(NH) : 1;
  localparam int unsigned FW   = 64;
  localparam int unsigned TOKW = 2;

  // Backward-loop geometry: beq x0,x0,-32 at 0x80 targets 0x60. The loop
  // buffer arms (span 0x20 <= 8 fetch blocks) and captures fills
  // 0x60..0x80.
  localparam logic [VLEN-1:0] BRANCH_PC  = 64'h80;
  localparam logic [VLEN-1:0] RESTORE_PC = 64'h100;

  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN                 = 64;
    c.VLEN                 = VLEN;
    c.GPLEN                = VLEN;
    c.FETCH_WIDTH          = FW;
    c.FETCH_ALIGN_BITS     = 3;
    c.FETCH_USER_WIDTH     = 1;
    c.INSTR_PER_FETCH      = FW / 16;
    c.LOG2_INSTR_PER_FETCH = $clog2(FW / 16);
    c.RVC                  = 1'b1;
    c.NrHarts              = NH;
    c.NrIssuePorts         = NI;
    c.FtqDepth             = FTQD;
    c.LoopBufEn            = 1'b1;
    c.LoopBufEntries       = LBE;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C = cfg();

  typedef struct packed {
    logic [63:0] cause, tval, tval2;
    logic [31:0] tinst;
    logic        gva, valid;
  } exc_t;
  typedef struct packed {
    cf_t             cf;
    logic [VLEN-1:0] predict_address;
    logic            ckpt_v;    // T21
    logic [7:0]      ckpt_idx;  // T21
    logic            is_call;   // T21
  } bp_t;
  typedef struct packed {
    logic [VLEN-1:0]  address;
    logic [31:0]      instruction;
    bp_t              branch_predict;
    exc_t             ex;
    logic [HW-1:0]    hart_id;
  } entry_t;
  typedef struct packed {
    logic             valid;
    logic [VLEN-1:0]  pc;
    logic [VLEN-1:0]  target_address;
    logic             is_mispredict;
    logic             is_taken;
    cf_t              cf_type;
    logic [HW-1:0]    hart_id;
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
    logic            user;
    logic [TOKW-1:0] token;
    logic [VLEN-1:0] vaddr;
    exc_t            ex;
  } idrsp_t;

  logic clk = 0, rst_n = 0;
  logic smt_restore = 0;
  logic [VLEN-1:0] smt_npc = RESTORE_PC;
  logic [HW-1:0] smt_hart = HW'(0);
  logic i_ready = 1;
  bpr_t   rb = '0;
  idreq_t req;
  idrsp_t rsp;
  logic [NI-1:0] fev;

  // Compressed NOP stream; the block at 0x80 carries beq x0,x0,-32 at byte 0
  // (chunks 0-1), which the static predictor takes backward to 0x60. Once the
  // loop buffer has armed once, the beq retires to NOPs: the restore must be
  // checked in a window with no coincident bp_fire, otherwise the bp_fire's
  // own flush term masks the missing restore term (the pre-M3 behaviour).
  bit armed_seen = 0;
  function automatic logic [FW-1:0] data_for(input logic [VLEN-1:0] a);
    if (a == BRANCH_PC && !armed_seen) return 64'h0001_0001_FE00_00E3;
    return 64'h0001_0001_0001_0001;
  endfunction

  frontend #(.CVA6Cfg(C), .bp_resolve_t(bpr_t), .fetch_entry_t(entry_t),
             .icache_dreq_t(idreq_t), .icache_drsp_t(idrsp_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .boot_addr_i(64'h0),
    .flush_bp_i(1'b0), .flush_i(1'b0), .halt_i(1'b0), .halt_frontend_i(1'b0),
    .set_pc_commit_i(1'b0), .commit_hart_i('0), .pc_commit_i('0),
    .mem_replay_pc_i(1'b0), .ex_valid_i(1'b0), .resolved_branch_i(rb),
    .eret_i(1'b0), .epc_i('0), .trap_vector_base_i('0),
    .set_debug_pc_i(1'b0), .debug_mode_i(1'b0),
    .smt_hart_i(smt_hart), .smt_restore_i(smt_restore),
    .smt_npc_restore_i(smt_npc),
    .peer_restart_valid_i(1'b0), .peer_restart_pc_i('0),
    .npc_q_o(), .fetch_frontier_pc_o(),
    .queue_oldest_valid_o(), .queue_oldest_pc_o(), .smt_trap_hold_o(),
    .icache_dreq_o(req), .icache_dreq_i(rsp),
    .fetch_entry_o(), .fetch_entry_valid_o(fev), .fetch_entry_ready_i({NI{1'b1}})
  );

  // ---- one-outstanding I$ stub ---------------------------------------------
  // ready is a stimulus input (the stall below drops it); the stub answers the
  // last accepted request one cycle later and drops a killed request like a
  // well-behaved I$.
  logic             rsp_v_q = 0;
  logic [VLEN-1:0]  rsp_a_q = '0;
  logic [FW-1:0]    rsp_d_q = '0;
  logic [TOKW-1:0]  rsp_t_q = '0;
  wire accept = req.req & rsp.ready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_v_q <= 0;
    end else if (req.kill_s1 || req.kill_s2) begin
      rsp_v_q <= 0;
    end else begin
      rsp_v_q <= accept;
      if (accept) begin
        rsp_a_q <= req.vaddr; rsp_d_q <= data_for(req.vaddr); rsp_t_q <= req.token;
      end
    end
  end
  assign rsp = '{ready: i_ready, valid: rsp_v_q, data: rsp_d_q, user: 1'b0,
                token: rsp_t_q, vaddr: rsp_a_q, ex: exc_t'('0)};

  task automatic tick; clk = 1; #2; clk = 0; #2; endtask

  // ---- posedge request monitor (phase 4) -----------------------------------
  // Combinational sampling from the initial block races the eval queue, so
  // accepted requests are counted here on the edge the I$ stub registers them.
  bit mon_en = 0;
  int rst_reqs = 0;
  always_ff @(posedge clk) begin
    if (mon_en && req.req && rsp.ready) begin
      if (req.vaddr == RESTORE_PC) rst_reqs <= rst_reqs + 1;
      else if (req.vaddr < RESTORE_PC)
        $fatal(1, "FETCH_RESTORE_BACKWARD_REQ vaddr=%h", req.vaddr);
    end
  end

  initial begin
    int cycles, settle;
`ifdef G6LC_MUT_FETCH_RESTORE_NOFLUSH
    $display("FETCH_RESTORE_MUTANT noflush");
`endif
    tick(); tick(); rst_n = 1;
    // ---- phases 1+2: run fetch until the loop buffer is armed AND the FTQ --
    // holds a pre-restore entry, then restore on the very next cycle. The loop
    // buffer re-captures every iteration (armed_q only holds between the
    // capture close and the next back-edge prediction), and the queue drains
    // to ~1 entry, so the restore must be timed to the detected state, not to
    // a fixed delay.
    // The loop's beq re-predicts every iteration; each prediction sets the
    // speculative fetch attribute until something resolves the branch, and
    // speculative fills do not feed the loop buffer. Resolve the beq (taken,
    // as predicted) in the cycle the loop-entry response is consumed.
    cycles = 0; settle = 0;
    while (!(settle > 16 &&
             dut.gen_ftq.gen_lbuf.i_lbuf.armed_q &&
             dut.gen_ftq.i_ftq.count_q != '0 &&
             dut.gen_ftq.i_ftq.mem_q[dut.gen_ftq.i_ftq.head_q].vaddr != RESTORE_PC)
           && cycles < 800) begin
      rb = '0;
      if (rsp_v_q && rsp_a_q == 64'h60)
        rb = '{valid: 1'b1, pc: BRANCH_PC, target_address: 64'h60,
               is_mispredict: 1'b0, is_taken: 1'b1,
               cf_type: ariane_pkg::Branch, hart_id: HW'(0),
               ckpt_restore: 1'b0, ckpt_v: 1'b0, ckpt_idx: 8'd0, is_call: 1'b0, next_pc: '0};
      if (dut.gen_ftq.gen_lbuf.i_lbuf.armed_q) armed_seen = 1;
      if (armed_seen) settle++;
      tick(); cycles++;
    end
    if (!dut.gen_ftq.gen_lbuf.i_lbuf.armed_q || dut.gen_ftq.i_ftq.count_q == '0)
      $fatal(1, "FETCH_RESTORE_NO_STALE_STATE armed=%b count=%0d",
             dut.gen_ftq.gen_lbuf.i_lbuf.armed_q, dut.gen_ftq.i_ftq.count_q);
    $display("FETCH_RESTORE_INFO stale head=%h count=%0d armed=%b",
             dut.gen_ftq.i_ftq.mem_q[dut.gen_ftq.i_ftq.head_q].vaddr,
             dut.gen_ftq.i_ftq.count_q, dut.gen_ftq.gen_lbuf.i_lbuf.armed_q);
    // ---- phase 3: restore ----------------------------------------------------
    smt_hart = HW'(1);   // the switch restores hart 1's stream
    rb = '0;             // no resolve may coincide with the restore
    smt_restore = 1; tick(); smt_restore = 0;
    $display("FETCH_RESTORE_POST count=%0d m0v=%b m0a=%h head=%h armed=%b",
             dut.gen_ftq.i_ftq.count_q, dut.gen_ftq.i_ftq.mem_q[0].valid,
             dut.gen_ftq.i_ftq.mem_q[0].vaddr,
             dut.gen_ftq.i_ftq.mem_q[dut.gen_ftq.i_ftq.head_q].vaddr,
             dut.gen_ftq.gen_lbuf.i_lbuf.armed_q);
    // next cycle: nothing pushed before the restore may remain
    if (dut.gen_ftq.i_ftq.count_q != 1 ||
        !dut.gen_ftq.i_ftq.mem_q[0].valid ||
        dut.gen_ftq.i_ftq.mem_q[0].vaddr != RESTORE_PC)
      $fatal(1, "FETCH_RESTORE_STALE count=%0d head=%h",
             dut.gen_ftq.i_ftq.count_q, dut.gen_ftq.i_ftq.mem_q[0].vaddr);
    if (dut.gen_ftq.gen_lbuf.i_lbuf.armed_q)
      $fatal(1, "FETCH_RESTORE_LBUF_ARMED");
    // The in-flight request and the queue parcels of the old stream must be
    // dead too: a late response would be stamped with the incoming hart, and
    // a surviving parcel would deliver its instructions a second time.
    if (dut.want_valid_q || dut.inflight_q || dut.icache_valid_q)
      $fatal(1, "FETCH_RESTORE_INFLIGHT want=%b inflight=%b take=%b",
             dut.want_valid_q, dut.inflight_q, dut.icache_valid_q);
    if (|fev)
      $fatal(1, "FETCH_RESTORE_PARCEL");
    // ---- phase 4: the restore window must be fetched exactly once ------------
    // M3 double-commit: SRC_RESTORE left npc_q on the reseeded pc, so the
    // first sequential if_ready re-pushed the same window into the FTQ and a
    // second demand fetch re-delivered parcels that had already committed.
    // Demand the restore window once; the stream must then continue at
    // RESTORE_PC + window, never re-request RESTORE_PC.
    // ---- phase 4: the restore window must be fetched exactly once ------------
    // M3 double-commit: SRC_RESTORE left npc_q on the reseeded pc, so the
    // first sequential if_ready re-pushed the same window into the FTQ and a
    // second demand fetch re-delivered parcels that had already committed.
    // Demand the restore window once; the stream must then continue at
    // RESTORE_PC + window, never re-request RESTORE_PC.
    mon_en = 1;
    repeat (40) tick();
    mon_en = 0;
    if (rst_reqs != 1)
      $fatal(1, "FETCH_RESTORE_DUPWIN reqs=%0d", rst_reqs);
    $display("RTL_REVIEW_PASS fetch_restore"); $finish;
  end
endmodule
