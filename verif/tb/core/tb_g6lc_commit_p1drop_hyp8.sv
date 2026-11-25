// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 commit_stage leaf: dual-port wrong-path squash & FP dirty_fs
// speculation-leak check.
//
// Proves:
//   S1. 6 cancelled wrong-path slots (incomplete ALU, STORE, faulting LOAD,
//       FPU, CSR, incomplete STORE) drain in 3 cycles (2 drops/cycle via
//       Port 0 + Port 1) with ZERO we_gpr, we_fpr, commit_lsu, commit_csr, or
//       dirty_fp_state_o side effects.
//   S2. Mispredicting branch retiring on Port 0 + cancelled incomplete slot on
//       Port 1 retire/drop in the SAME cycle (Port 0 writes GPR, Port 1 writes
//       nothing and drops).
//   S3. Replay-marked slot on Port 1 (commit_replay_i[1]=1) is NOT dropped on
//       Port 1; it advances to Port 0 and pulses replay_o + flush_commit_o.
//   S4. Cancelled FPU instruction dropped on Port 0/1 never asserts
//       dirty_fp_state_o (whereas a real retiring FPU instruction DOES).
//
// Review mutations (must fail):
//   -DG6LC_MUT_CMT_NO_P1_DROP     -> S1 stalls to 1/cycle (fails CMT_P1_DROP_BOTH)
//   -DG6LC_MUT_CMT_DROP_DIRTY_FS  -> S4 leaks dirty_fp_state_o=1 on drop
//
// PASS token: PASS tb_g6lc_commit_p1drop_hyp8
`include "g6lc_core_types.svh"

module tb_g6lc_commit_p1drop_hyp8;
  import g6lc_core_pkg::*;

  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;

  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C)         exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C)  sbe_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_commit_p1drop_hyp8");
    end
  endtask

  sbe_t [C.NrCommitPorts-1:0]                   cmt_instr = '{default: '0};
  logic [C.NrCommitPorts-1:0]                   cmt_drop = '0, cmt_replay = '0;
  logic [C.NrCommitPorts-1:0]                   cmt_bvalid = '0;
  logic [C.NrCommitPorts-1:0]                   cmt_ack, cmt_mack;
  logic [C.NrCommitPorts-1:0][4:0]              waddr;
  logic [C.NrCommitPorts-1:0][C.XLEN-1:0]       wdata;
  logic [C.NrCommitPorts-1:0]                   we_gpr, we_fpr;
  logic                                         commit_lsu, commit_csr, dirty_fp;
  logic                                         flush_commit, replay_o;
  exception_t                                   ex_o;
  amo_resp_t                                    amo_resp = '0;

  commit_stage #(
      .G6LCCfg           (C),
      .HypCfg            (H),
      .exception_t       (exception_t),
      .scoreboard_entry_t(sbe_t)
  ) dut (
      .clk_i                 (clk),
      .rst_ni                (rst_n),
      .halt_i                (1'b0),
      .flush_dcache_i        (1'b0),
      .flush_i               (1'b0),
      .exception_o           (ex_o),
      .dirty_fp_state_o      (dirty_fp),
      .single_step_i         (1'b0),
      .step_hart_i           ('0),
      .commit_instr_i        (cmt_instr),
      .commit_drop_i         (cmt_drop),
      .commit_replay_i       (cmt_replay),
      .commit_bundle_valid_i (cmt_bvalid),
      .commit_ack_o          (cmt_ack),
      .commit_macro_ack_o    (cmt_mack),
      .waddr_o               (waddr),
      .wdata_o               (wdata),
      .we_gpr_o              (we_gpr),
      .we_fpr_o              (we_fpr),
      .amo_resp_i            (amo_resp),
      .pc_o                  (),
      .csr_op_o              (),
      .csr_wdata_o           (),
      .csr_rdata_i           ('0),
      .csr_rdata_valid_i     (1'b1),
      .csr_write_fflags_o    (),
      .csr_exception_i       ('0),
      .commit_lsu_o          (commit_lsu),
      .commit_lsu_ready_i    (1'b0),
      .commit_tran_id_o      (),
      .amo_valid_commit_o    (),
      .no_st_pending_i       (1'b1),
      .shared_tlb_flush_busy_i(1'b0),
      .commit_csr_o          (commit_csr),
      .fence_i_o             (),
      .fence_o               (),
      .flush_commit_o        (flush_commit),
      .replay_o              (replay_o),
      .sfence_vma_o          (),
      .hfence_vvma_o         (),
      .hfence_gvma_o         (),
      .break_from_trigger_i  (1'b0)
  );

  function automatic sbe_t mk(input fu_t fu, input fu_op op, input logic valid,
                              input logic exv, input logic [4:0] rd,
                              input logic [C.TRANS_ID_BITS-1:0] tid);
    sbe_t s = '0;
    s.fu       = fu;
    s.op       = op;
    s.valid    = valid;
    s.ex.valid = exv;
    s.rd       = rd;
    s.trans_id = tid;
    s.pc       = 64'h8000_1000 + {56'd0, tid, 2'b00};
    return s;
  endfunction

  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // ---- S1: Dual-port wrong-path drops across diverse incomplete/STORE/CSR/ex/FPU pairs ----
    // Pair A: Port 0 = cancelled incomplete ALU, Port 1 = cancelled incomplete STORE
    cmt_instr[0] = mk(ALU, ADD, 1'b0, 1'b0, 5'd1, 'd1);
    cmt_instr[1] = mk(STORE, SD, 1'b0, 1'b0, 5'd0, 'd2);
    cmt_drop     = 2'b11;
    cmt_replay   = 2'b00;
    cmt_bvalid   = 2'b11;
    #1;
    check(cmt_ack === 2'b11, "S1A_CMT_P1_DROP_BOTH");
    check(we_gpr === 2'b00 && we_fpr === 2'b00, "S1A_NO_WE");
    check(commit_lsu === 1'b0 && commit_csr === 1'b0, "S1A_NO_SIDE_EFFECT");
    tick();

    // Pair B: Port 0 = cancelled CSR, Port 1 = cancelled faulting LOAD
    cmt_instr[0] = mk(CSR, CSR_WRITE, 1'b1, 1'b0, 5'd2, 'd3);
    cmt_instr[1] = mk(LOAD, LD, 1'b1, 1'b1, 5'd3, 'd4);
    cmt_drop     = 2'b11;
    cmt_replay   = 2'b00;
    cmt_bvalid   = 2'b11;
    #1;
    check(cmt_ack === 2'b11, "S1B_CSR_EX_DROP_BOTH");
    check(we_gpr === 2'b00 && commit_csr === 1'b0 && !ex_o.valid, "S1B_NO_SIDE_EFFECT");
    tick();

    // ---- S2: Mispredicting branch retires on Port 0 + cancelled STORE drops on Port 1 ----
    cmt_instr[0] = mk(CTRL_FLOW, JALR, 1'b1, 1'b0, 5'd1, 'd5);
    cmt_instr[1] = mk(STORE, SD, 1'b0, 1'b0, 5'd0, 'd6);
    cmt_drop     = 2'b10;
    cmt_replay   = 2'b00;
    cmt_bvalid   = 2'b11;
    #1;
    check(cmt_ack === 2'b11, "S2_BR_AND_P1_DROP");
    check(we_gpr === 2'b01, "S2_ONLY_P0_WE");
    check(commit_lsu === 1'b0, "S2_NO_LSU");
    tick();

    // ---- S3: Replay-marked slot on Port 1 MUST NOT drop on Port 1 ----
    cmt_instr[0] = mk(ALU, ADD, 1'b1, 1'b0, 5'd4, 'd7);
    cmt_instr[1] = mk(LOAD, LD, 1'b1, 1'b0, 5'd5, 'd8);
    cmt_drop     = 2'b10;
    cmt_replay   = 2'b10;
    cmt_bvalid   = 2'b11;
    #1;
    check(cmt_ack === 2'b01, "S3_REPLAY_HELD_FROM_P1");
    check(replay_o === 1'b0 && flush_commit === 1'b0, "S3_NO_EARLY_REPLAY");
    tick();
    // Advance replay slot to Port 0 -> fires replay_o + flush_commit_o
    cmt_instr[0] = mk(LOAD, LD, 1'b1, 1'b0, 5'd5, 'd8);
    cmt_drop     = 2'b01;
    cmt_replay   = 2'b01;
    cmt_bvalid   = 2'b01;
    #1;
    check(cmt_ack === 2'b01 && replay_o === 1'b1 && flush_commit === 1'b1, "S3_REPLAY_AT_P0");
    tick();

    // ---- S4: Cancelled FP instruction dropped on Port 0/1 must NOT dirty mstatus.FS ----
    cmt_instr[0] = mk(FPU, FADD, 1'b1, 1'b0, 5'd1, 'd9);
    cmt_instr[1] = mk(FPU, FMUL, 1'b1, 1'b0, 5'd2, 'd10);
    cmt_drop     = 2'b11;
    cmt_replay   = 2'b00;
    cmt_bvalid   = 2'b11;
    #1;
    check(cmt_ack === 2'b11, "S4_FP_DROP_BOTH");
    check(we_fpr === 2'b00, "S4_NO_FPR_WE");
    check(dirty_fp === 1'b0, "S4_CMT_DROP_NO_DIRTY_FS");
    tick();

    // Real retiring FPU instruction on Port 0 MUST still assert dirty_fp_state_o!
    cmt_drop     = 2'b00;
    cmt_bvalid   = 2'b01;
    #1;
    check(cmt_ack === 2'b01 && dirty_fp === 1'b1, "S4_REAL_FP_DIRTIES_FS");
    tick();

    // ---- S5: CSR_READ must NOT arm post-commit csr_hold_q, whereas CSR_WRITE MUST ----
    // Phase 1: present CSR_READ (two-phase CsrReadStages==2 -> seen_q arms, retires next cycle)
    cmt_instr[0] = mk(CSR, CSR_READ, 1'b1, 1'b0, 5'd6, 'd11);
    cmt_drop     = 2'b00;
    cmt_replay   = 2'b00;
    cmt_bvalid   = 2'b01;
    tick();  // csr_seen_q arms for tid=11
    #1;
    check(cmt_ack === 2'b01 && commit_csr === 1'b1, "S5_CSR_READ_RETIRES");
    tick();  // next cycle: ALU behind CSR_READ must commit immediately (no csr_hold_q bubble!)
    cmt_instr[0] = mk(ALU, ADD, 1'b1, 1'b0, 5'd7, 'd12);
    #1;
    check(cmt_ack === 2'b01, "S5_NO_HOLD_AFTER_CSR_READ");
    tick();

    // Phase 2: CSR_WRITE MUST still arm csr_hold_q for 1 cycle (preserves r59 hyp8_csr_flush_skip!)
    cmt_instr[0] = mk(CSR, CSR_WRITE, 1'b1, 1'b0, 5'd8, 'd13);
    tick();  // csr_seen_q arms for tid=13
    #1;
    check(cmt_ack === 2'b01 && commit_csr === 1'b1, "S5_CSR_WRITE_RETIRES");
    tick();  // next cycle: ALU behind CSR_WRITE MUST be suppressed by csr_hold_q!
    cmt_instr[0] = mk(ALU, ADD, 1'b1, 1'b0, 5'd9, 'd14);
    #1;
    check(cmt_ack === 2'b00, "S5_HOLD_AFTER_CSR_WRITE");
    tick();  // cycle after hold: ALU retires cleanly
    #1;
    check(cmt_ack === 2'b01, "S5_RESUME_AFTER_CSR_WRITE");
    tick();

    // ---- S6: CSR_READ + ALU dual-commits on Port 0 & Port 1; CSR_READ + FPU & CSR_WRITE + ALU serialize ----
    cmt_instr[0] = mk(CSR, CSR_READ, 1'b1, 1'b0, 5'd10, 'd15);
    cmt_instr[1] = mk(ALU, ADD,      1'b1, 1'b0, 5'd11, 'd16);
    cmt_drop     = 2'b00;
    cmt_replay   = 2'b00;
    cmt_bvalid   = 2'b11;
    tick();  // csr_seen_q arms for tid=15
    #1;
    check(cmt_ack === 2'b11 && we_gpr === 2'b11 && commit_csr === 1'b1, "S6_CSR_READ_DUAL_ALU");
    tick();

    // CSR_READ + FPU must NOT dual-commit (protects csr_wdata_dec / fflags)
    cmt_instr[0] = mk(CSR, CSR_READ, 1'b1, 1'b0, 5'd12, 'd17);
    cmt_instr[1] = mk(FPU, FADD,     1'b1, 1'b0, 5'd13, 'd18);
    tick();  // csr_seen_q arms for tid=17
    #1;
    check(cmt_ack === 2'b01 && commit_csr === 1'b1, "S6_CSR_READ_BLOCKS_FPU_P1");
    tick();

    // CSR_WRITE + ALU must still serialize (Port 0 only)
    cmt_instr[0] = mk(CSR, CSR_WRITE, 1'b1, 1'b0, 5'd14, 'd19);
    cmt_instr[1] = mk(ALU, ADD,       1'b1, 1'b0, 5'd15, 'd20);
    tick();  // csr_seen_q arms for tid=19
    #1;
    check(cmt_ack === 2'b01 && commit_csr === 1'b1, "S6_CSR_WRITE_SERIALIZES_P1");

    $display("PASS tb_g6lc_commit_p1drop_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
