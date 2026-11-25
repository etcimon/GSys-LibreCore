// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Isolated mutation-checked leaf TB for hyp8 `g6lc_zicclsm` (OoO TID-matched
// completion passthrough, hold_v_q arbitration, beat-1 exception propagation,
// and cancel propagation).
//
// Reproduces the OpenWrt boot wedge (hyp8-witness-* @cyc=14505435, core0 hart0):
//   tid=51 (wrong-path misaligned LD @0x00ff) enters B0_ACTIVE and stalls on
//   non-idempotent speculation while older aligned load tid=48 (ld s2,32(sp)
//   @0x80053e20) returns from load_unit. Without tid-matching, g6lc_zicclsm
//   swallowed tid=48's ld_valid_fu_i (dropping its writeback permanently) and
//   hijacked tid=51 into B1_ACTIVE with tid=48's data.
//
// Gates (AGENTS-isolated-tests.md):
//   1. positive: PASS tb_g6lc_zicclsm_hyp8
//   2. +oracle_negative: fails ZICCLSM_OOO_TID_SWALLOW
//   3. -DG6LC_MUT_ZICCLSM_TID_SWALLOW: fails ZICCLSM_OOO_TID_SWALLOW
`timescale 1ns / 1ps

module tb_g6lc_zicclsm_hyp8
  import g6lc_core_pkg::*;
;
  localparam config_pkg::g6lc_cfg_t CFG = build_config_pkg::build_config(
      g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned TID_W = CFG.TRANS_ID_BITS;

  typedef struct packed {
    logic [63:0] cause;
    logic [63:0] tval;
    logic [40:0] tval2;
    logic [31:0] tinst;
    logic        gva;
    logic        valid;
  } exception_t;

  typedef struct packed {
    logic [2:0]          data_prot;
    logic                valid;
    logic [CFG.VLEN-1:0] vaddr;
    logic [31:0]         tinst;
    logic                hs_ld_st_inst;
    logic                hlvx_inst;
    logic                overflow;
    logic                g_overflow;
    logic [CFG.XLEN-1:0] data;
    logic [CFG.XLEN-1:0] data_cmp;
    logic [CFG.XLEN-1:0] data_hi;
    logic [CFG.XLEN-1:0] data_cmp_hi;
    logic [7:0]          be;
    fu_t                 fu;
    fu_op                operation;
    logic [TID_W-1:0]    trans_id;
    logic                hart;
    logic                is_speculative_load;
    logic                is_speculative_load_miss;
  } lsu_ctrl_t;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic              rst_n;
  logic              flush;
  lsu_ctrl_t         ctrl_i, ctrl_o;
  logic              pop_ld_fu, pop_st_fu;
  logic              pop_ld_byp, pop_st_byp;
  logic              ld_valid_fu, ld_valid_o;
  logic [63:0]       ld_result_fu, ld_result_o;
  exception_t        ld_ex_fu, ld_ex_o;
  logic [TID_W-1:0]  ld_tid_fu, ld_tid_o;
  logic              st_valid_fu, st_valid_o;
  logic [63:0]       st_result_fu, st_result_o;
  exception_t        st_ex_fu, st_ex_o;
  logic [TID_W-1:0]  st_tid_fu, st_tid_o;
  logic              ld_head_checked;
  logic              lu_replay_fu;
  logic              ld_replay_o;
  logic [TID_W-1:0]  ld_replay_id_o;

  g6lc_zicclsm #(
      .G6LCCfg    (CFG),
      .lsu_ctrl_t (lsu_ctrl_t),
      .exception_t(exception_t)
  ) dut (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .flush_i       (flush),
      .ctrl_i        (ctrl_i),
      .ctrl_o        (ctrl_o),
      .pop_ld_fu_i   (pop_ld_fu),
      .pop_st_fu_i   (pop_st_fu),
      .pop_ld_byp_o  (pop_ld_byp),
      .pop_st_byp_o  (pop_st_byp),
      .ld_valid_fu_i (ld_valid_fu),
      .ld_result_fu_i(ld_result_fu),
      .ld_ex_fu_i    (ld_ex_fu),
      .ld_tid_fu_i   (ld_tid_fu),
      .ld_valid_o    (ld_valid_o),
      .ld_result_o   (ld_result_o),
      .ld_ex_o       (ld_ex_o),
      .ld_tid_o      (ld_tid_o),
      .st_valid_fu_i (st_valid_fu),
      .st_result_fu_i(st_result_fu),
      .st_ex_fu_i    (st_ex_fu),
      .st_tid_fu_i   (st_tid_fu),
      .st_valid_o    (st_valid_o),
      .st_result_o   (st_result_o),
      .st_ex_o       (st_ex_o),
      .st_tid_o      (st_tid_o),
      .ld_head_checked_i(ld_head_checked),
      .lu_replay_fu_i   (lu_replay_fu),
      .ld_replay_o      (ld_replay_o),
      .ld_replay_id_o   (ld_replay_id_o)
  );

  int unsigned pass_ld_cnt = 0;
  int unsigned pass_st_cnt = 0;
  bit          oracle_neg;

  task automatic clear_fu();
    pop_ld_fu       = 1'b0;
    pop_st_fu       = 1'b0;
    ld_valid_fu     = 1'b0;
    ld_result_fu    = '0;
    ld_ex_fu        = '0;
    ld_tid_fu       = '0;
    st_valid_fu     = 1'b0;
    st_result_fu    = '0;
    st_ex_fu        = '0;
    st_tid_fu       = '0;
    ld_head_checked = 1'b1;
    lu_replay_fu    = 1'b0;
  endtask

  task automatic drive_ctrl(
      input fu_t              f,
      input fu_op             op,
      input logic [63:0]      va,
      input logic [TID_W-1:0] tid,
      input logic [63:0]      wdata = '0,
      input logic             miss  = 1'b0
  );
    ctrl_i                          = '0;
    ctrl_i.valid                    = 1'b1;
    ctrl_i.fu                       = f;
    ctrl_i.operation                = op;
    ctrl_i.vaddr                    = va;
    ctrl_i.trans_id                 = tid;
    ctrl_i.data                     = wdata;
    ctrl_i.is_speculative_load_miss = miss;
  endtask

  initial begin
    oracle_neg = $test$plusargs("oracle_negative");
    rst_n = 1'b0;
    flush = 1'b0;
    ctrl_i = '0;
    clear_fu();
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk); #1;

    // =========================================================================
    // S1: Exact OpenWrt c=14505435 wedge reproduction.
    //   tid=51 (misaligned LD @0x00ff) enters B0_ACTIVE and stalls (pop_ld_fu=0).
    //   Older in-flight load tid=48 completes on ld_valid_fu_i.
    //   MUST pass through ld_valid_o=1/tid=48 AND NOT advance tid=51 to beat1.
    // =========================================================================
    drive_ctrl(LOAD, LD, 64'h0000_0000_0000_00ff, TID_W'(51));
    #1;
    if (ctrl_o.vaddr !== 64'h0000_0000_0000_00f8 || pop_ld_byp !== 1'b0)
      $fatal(1, "ZICCLSM_S1_BEAT0 bad beat0 va=%h pop=%b", ctrl_o.vaddr, pop_ld_byp);
    @(posedge clk); #1; // now in B0_ACTIVE (tid=51 stalled)

    // Inject unrelated older load tid=48 completion while tid=51 is in B0_ACTIVE
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(48);
    ld_result_fu = 64'h8005_3e20_dead_beef;
    #1;
    if (!ld_valid_o || ld_tid_o !== TID_W'(48) || ld_result_o !== 64'h8005_3e20_dead_beef)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S1 B0_ACTIVE swallowed tid=48: v=%b tid=%0d res=%h",
             ld_valid_o, ld_tid_o, ld_result_o);
    pass_ld_cnt++;
    @(posedge clk); #1;
    clear_fu();
    #1;
    // tid=51 MUST still be on beat0 (0xf8), NOT hijacked to beat1 (0x100)!
    if (ctrl_o.vaddr !== 64'h0000_0000_0000_00f8)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S1 B0_ACTIVE hijacked to beat1 va=%h", ctrl_o.vaddr);

    // Also test unrelated older store completing while load tid=51 is in B0_ACTIVE
    st_valid_fu  = 1'b1;
    st_tid_fu    = TID_W'(45);
    st_result_fu = 64'h1234_5678_9abc_def0;
    #1;
    if (!st_valid_o || st_tid_o !== TID_W'(45) || st_result_o !== 64'h1234_5678_9abc_def0)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S1 B0_ACTIVE swallowed store tid=45: v=%b tid=%0d",
             st_valid_o, st_tid_o);
    pass_st_cnt++;
    @(posedge clk); #1;
    clear_fu();

    // Cancel tid=51 in B0_ACTIVE (like c=14505439 mispredict): ctrl_o must reflect miss!
    ctrl_i.is_speculative_load_miss = 1'b1;
    #1;
    if (ctrl_o.is_speculative_load_miss !== 1'b1)
      $fatal(1, "ZICCLSM_S1_CANCEL_PROP B0_ACTIVE hid is_speculative_load_miss");
    pop_ld_fu = 1'b1; // load_unit drops cancelled beat0
    @(posedge clk); #1; // now in B0_WAIT
    clear_fu();
    // Same cycle B0_WAIT aborts cancelled tid=51, unrelated load tid=49 completes!
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(49);
    ld_result_fu = 64'hcafe_babe_0000_0049;
    #1;
    if (!pop_ld_byp)
      $fatal(1, "ZICCLSM_S1_CANCEL_POP B0_WAIT did not pop cancelled head");
    if (!ld_valid_o || ld_tid_o !== TID_W'(49) || ld_result_o !== 64'hcafe_babe_0000_0049)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S1 B0_WAIT cancel swallowed tid=49: v=%b tid=%0d",
             ld_valid_o, ld_tid_o);
    pass_ld_cnt++;
    @(posedge clk); #1; // back in IDLE
    clear_fu();
    ctrl_i = '0;
    @(posedge clk); #1;

    // =========================================================================
    // S2: Full split LD (tid=10 @0x1005) with unrelated loads injected in
    //     B0_WAIT, B1_ACTIVE, B1_WAIT, AND during hold_v_q (collision)!
    //   Mem[0x1000..0x1007] = 64'h0706050403020100
    //   Mem[0x1008..0x100f] = 64'h0f0e0d0c0b0a0908
    //   LD @0x1005 -> bytes 05,06,07,08,09,0a,0b,0c = 64'h0c0b0a0908070605
    // =========================================================================
    drive_ctrl(LOAD, LD, 64'h0000_0000_0000_1005, TID_W'(10));
    pop_ld_fu = 1'b1; // beat0 accepted in IDLE -> B0_WAIT
    @(posedge clk); #1;
    clear_fu();

    // B0_WAIT: unrelated load tid=2 completes
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(2);
    ld_result_fu = 64'h2222_2222_2222_2222;
    #1;
    if (!ld_valid_o || ld_tid_o !== TID_W'(2) || ld_result_o !== 64'h2222_2222_2222_2222)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S2 B0_WAIT swallowed tid=2: v=%b tid=%0d",
             ld_valid_o, ld_tid_o);
    pass_ld_cnt++;
    @(posedge clk); #1;

    // B0_WAIT: beat0 of tid=10 returns
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(10);
    ld_result_fu = 64'h0706_0504_0302_0100;
    #1;
    if (ld_valid_o !== 1'b0)
      $fatal(1, "ZICCLSM_S2_B0_LEAK beat0 of tid=10 leaked ld_valid_o=1");
    @(posedge clk); #1; // now in B1_ACTIVE
    clear_fu();
    #1;
    if (ctrl_o.vaddr !== 64'h0000_0000_0000_1008)
      $fatal(1, "ZICCLSM_S2_BEAT1 bad beat1 va=%h", ctrl_o.vaddr);

    // B1_ACTIVE: unrelated load tid=3 completes with exception -> must pass through & NOT abort tid=10!
    ld_valid_fu    = 1'b1;
    ld_tid_fu      = TID_W'(3);
    ld_ex_fu.valid = 1'b1;
    ld_ex_fu.cause = 64'd5;
    #1;
    if (!ld_valid_o || ld_tid_o !== TID_W'(3) || !ld_ex_o.valid || pop_ld_byp)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S2 B1_ACTIVE mishandled tid=3 ex: v=%b tid=%0d ex=%b pop=%b",
             ld_valid_o, ld_tid_o, ld_ex_o.valid, pop_ld_byp);
    pass_ld_cnt++;
    @(posedge clk); #1;
    clear_fu();
    #1;
    if (ctrl_o.vaddr !== 64'h0000_0000_0000_1008)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S2 B1_ACTIVE aborted by unrelated ex");

    // Accept beat1 -> B1_WAIT
    pop_ld_fu = 1'b1;
    @(posedge clk); #1;
    clear_fu();

    // B1_WAIT: unrelated load tid=4 completes
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(4);
    ld_result_fu = 64'h4444_4444_4444_4444;
    #1;
    if (!ld_valid_o || ld_tid_o !== TID_W'(4) || pop_ld_byp)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S2 B1_WAIT swallowed tid=4: v=%b tid=%0d pop=%b",
             ld_valid_o, ld_tid_o, pop_ld_byp);
    pass_ld_cnt++;
    @(posedge clk); #1;

    // B1_WAIT: beat1 of tid=10 returns -> captures hold_v_q, pops bypass
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(10);
    ld_result_fu = 64'h0f0e_0d0c_0b0a_0908;
    #1;
    if (ld_valid_o !== 1'b0 || pop_ld_byp !== 1'b1)
      $fatal(1, "ZICCLSM_S2_B1_CAP bad capture v=%b pop=%b", ld_valid_o, pop_ld_byp);
    @(posedge clk); #1; // IDLE with hold_v_q=1!

    // S2b (hold_v_q collision!): unrelated load tid=7 arrives on the exact cycle hold_v_q=1!
    // Next bypass entry is waiting on ctrl_i (aligned load tid=20)
    drive_ctrl(LOAD, LD, 64'h0000_0000_0000_2000, TID_W'(20));
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(7);
    ld_result_fu = 64'h7777_7777_7777_7777;
    #1;
    if (!ld_valid_o || ld_tid_o !== TID_W'(7) || ld_result_o !== 64'h7777_7777_7777_7777)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S2b hold_v_q overwrote tid=7: v=%b tid=%0d res=%h",
             ld_valid_o, ld_tid_o, ld_result_o);
    if (ctrl_o.valid !== 1'b0)
      $fatal(1, "ZICCLSM_S2b_STALL ctrl_o.valid must stay 0 while hold_v_q drains");
    pass_ld_cnt++;
    @(posedge clk); #1; // hold_v_q still 1, now ld_valid_fu=0 -> tid=10 emits!
    clear_fu();
    #1;
    if (!ld_valid_o || ld_tid_o !== TID_W'(10) || ld_result_o !== 64'h0c0b_0a09_0807_0605)
      $fatal(1, "ZICCLSM_S2b_HOLD_EMIT tid=10 lost or wrong after hold collision: v=%b tid=%0d res=%h",
             ld_valid_o, ld_tid_o, ld_result_o);
    @(posedge clk); #1; // hold_v_q drained; ctrl_o now presents tid=20!
    if (ctrl_o.valid !== 1'b1 || ctrl_o.trans_id !== TID_W'(20))
      $fatal(1, "ZICCLSM_S2b_RESUME next head tid=20 stuck: v=%b tid=%0d", ctrl_o.valid, ctrl_o.trans_id);
    ctrl_i = '0;
    @(posedge clk); #1;

    // =========================================================================
    // S3: Store split (SD @0x2003, tid=12) with unrelated load + load fault
    //     completing across B0_ACTIVE, B0_WAIT, B1_ACTIVE, B1_WAIT.
    // =========================================================================
    drive_ctrl(STORE, SD, 64'h0000_0000_0000_2003, TID_W'(12), 64'h1122_3344_5566_7788);
    @(posedge clk); #1; // B0_ACTIVE

    // Unrelated load tid=6 completes during store split B0_ACTIVE
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(6);
    ld_result_fu = 64'h6666_6666_6666_6666;
    pop_st_fu    = 1'b1; // beat0 accepted -> B0_WAIT
    #1;
    if (!ld_valid_o || ld_tid_o !== TID_W'(6))
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S3 store B0_ACTIVE swallowed load tid=6");
    pass_ld_cnt++;
    @(posedge clk); #1; // B0_WAIT
    clear_fu();

    // Unrelated store tid=1 completes during store split B0_WAIT
    st_valid_fu  = 1'b1;
    st_tid_fu    = TID_W'(1);
    st_result_fu = 64'h1111_1111_1111_1111;
    #1;
    if (!st_valid_o || st_tid_o !== TID_W'(1))
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S3 store B0_WAIT swallowed store tid=1");
    pass_st_cnt++;
    @(posedge clk); #1;

    // beat0 of store tid=12 completes -> B1_ACTIVE
    st_valid_fu = 1'b1;
    st_tid_fu   = TID_W'(12);
    #1;
    if (st_valid_o !== 1'b0)
      $fatal(1, "ZICCLSM_S3_B0_LEAK store beat0 leaked st_valid_o=1");
    @(posedge clk); #1; // B1_ACTIVE
    clear_fu();

    // Unrelated load fault tid=9 during store B1_ACTIVE -> must NOT pop store!
    ld_valid_fu    = 1'b1;
    ld_tid_fu      = TID_W'(9);
    ld_ex_fu.valid = 1'b1;
    ld_ex_fu.cause = 64'd13;
    pop_st_fu      = 1'b1; // beat1 accepted -> B1_WAIT
    #1;
    if (!ld_valid_o || ld_tid_o !== TID_W'(9) || !ld_ex_o.valid || pop_ld_byp || pop_st_byp)
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW S3 store B1_ACTIVE mishandled load ex tid=9");
    pass_ld_cnt++;
    @(posedge clk); #1; // B1_WAIT
    clear_fu();

    // beat1 of store tid=12 completes -> st_valid_o=1, pop_st_byp=1, IDLE
    st_valid_fu = 1'b1;
    st_tid_fu   = TID_W'(12);
    #1;
    if (!st_valid_o || st_tid_o !== TID_W'(12) || st_result_o !== 64'h1122_3344_5566_7788 || !pop_st_byp)
      $fatal(1, "ZICCLSM_S3_B1_DONE store tid=12 failed: v=%b tid=%0d pop=%b",
             st_valid_o, st_tid_o, pop_st_byp);
    @(posedge clk); #1;
    clear_fu();
    ctrl_i = '0;
    @(posedge clk); #1;

    // =========================================================================
    // S4: Beat-1 page fault in B1_WAIT must propagate ld_ex_o.valid=1!
    // =========================================================================
    drive_ctrl(LOAD, LD, 64'h0000_0000_0000_0ffc, TID_W'(14));
    pop_ld_fu = 1'b1;
    @(posedge clk); #1; // B0_WAIT
    clear_fu();
    ld_valid_fu  = 1'b1;
    ld_tid_fu    = TID_W'(14);
    ld_result_fu = 64'hdead_beef_0000_0000;
    @(posedge clk); #1; // B1_ACTIVE
    clear_fu();
    pop_ld_fu = 1'b1;
    @(posedge clk); #1; // B1_WAIT
    clear_fu();
    ld_valid_fu    = 1'b1;
    ld_tid_fu      = TID_W'(14);
    ld_ex_fu.valid = 1'b1;
    ld_ex_fu.cause = 64'd13; // LOAD_PAGE_FAULT
    #1;
    if (!ld_valid_o || !ld_ex_o.valid || ld_ex_o.cause !== 64'd13 ||
        ld_tid_o !== TID_W'(14) || !pop_ld_byp)
      $fatal(1, "ZICCLSM_S4_B1_EX beat1 exception lost: v=%b ex=%b cause=%0d tid=%0d pop=%b",
             ld_valid_o, ld_ex_o.valid, ld_ex_o.cause, ld_tid_o, pop_ld_byp);
    @(posedge clk); #1;
    clear_fu();
    ctrl_i = '0;
    @(posedge clk); #1;

    // =========================================================================
    // S5 (RC6a): Unchecked wrapping load (!ld_head_checked_i) must replay &
    //            pop bypass immediately instead of pinning lsu_bypass in B0!
    // =========================================================================
    drive_ctrl(LOAD, LD, 64'h0000_0000_8000_1045, TID_W'(25));
    ld_head_checked = 1'b0;
    #1;
    if (!ld_replay_o || ld_replay_id_o !== TID_W'(25) || !pop_ld_byp || ctrl_o.valid)
      $fatal(1, "ZICCLSM_UNCHECKED_DEADLOCK S5 did not replay unchecked split load: rep=%b id=%0d pop=%b v=%b",
             ld_replay_o, ld_replay_id_o, pop_ld_byp, ctrl_o.valid);
    @(posedge clk); #1;
    clear_fu();
    ctrl_i = '0;
    @(posedge clk); #1;

    // =========================================================================
    // S6 (RC6b): load_unit lu_replay_fu_i firing in B0_ACTIVE must abort split
    //            and pop bypass back to IDLE (not hang in B0_WAIT!).
    // =========================================================================
    drive_ctrl(LOAD, LD, 64'h0000_0000_8000_1045, TID_W'(26));
    @(posedge clk); #1; // B0_ACTIVE
    lu_replay_fu = 1'b1;
    pop_ld_fu    = 1'b1;
    #1;
    if (!pop_ld_byp)
      $fatal(1, "ZICCLSM_REPLAY_HANG S6 B0_ACTIVE did not pop bypass on lu_replay_fu");
    @(posedge clk); #1; // must be back in IDLE
    clear_fu();
    drive_ctrl(LOAD, LD, 64'h0000_0000_8000_2000, TID_W'(27));
    #1;
    if (!ctrl_o.valid || ctrl_o.trans_id !== TID_W'(27))
      $fatal(1, "ZICCLSM_REPLAY_HANG S6 stuck after lu_replay_fu: v=%b tid=%0d", ctrl_o.valid, ctrl_o.trans_id);
    ctrl_i = '0;
    @(posedge clk); #1;

    // Oracle negative gate: raise required passthrough floor beyond injected count
    if (oracle_neg && (pass_ld_cnt < 99))
      $fatal(1, "ZICCLSM_OOO_TID_SWALLOW oracle_negative floor pass_ld=%0d pass_st=%0d",
             pass_ld_cnt, pass_st_cnt);

    $display("PASS tb_g6lc_zicclsm_hyp8 pass_ld=%0d pass_st=%0d", pass_ld_cnt, pass_st_cnt);
    $finish;
  end
endmodule
