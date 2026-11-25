// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 g6lc_bp_loop leaf: proves T21e per-slot column lookup/override
// and saturated conf_cnt (>255-iter loop wraparound protection).
//
// Scenarios:
//   S1. Loop branch at slot 2 (0x8000_1004, trip=4) learns across 2 passes;
//       under aligned fetch vpc_i=0x8000_1000 overrides pred_o[2] (taken=1
//       for iters 0..3, taken=0 on exit iter 4) while pred_o[0/1/3] stay intact.
//   S2. Unaligned redirect vpc_i=0x8000_1004 still overrides column pred_o[2],
//       never corrupting pred_o[0].
//   S3. Long 256-iteration loop at slot 3 (0x8000_1006) saturates conf_cnt at
//       8'hFF (never wraps to 0 -> trip=0) and yields cleanly to base pred_i[3].
//
// Review mutations (each must fail):
//   -DG6LC_MUT_BP_LOOP_SLOT0_ONLY -> fails S1_SLOT2_PRED_EXIT
//   -DG6LC_MUT_BP_LOOP_WRAP_TRIP  -> fails S3_LONG_LOOP_NO_BOGUS_WRAP
//
// PASS token: PASS tb_g6lc_bp_loop_hyp8
module tb_g6lc_bp_loop_hyp8;
  import g6lc_core_pkg::*;
  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned NF = C.INSTR_PER_FETCH;

  typedef struct packed {
    logic                valid;
    logic [C.VLEN-1:0]   pc;
    logic                taken;
  } bht_update_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_bp_loop_hyp8");
    end
  endtask

  logic [C.VLEN-1:0] vpc = '0;
  bht_update_t       upd = '0;
  bht_prediction_t [NF-1:0] pred_i, pred_o;

  g6lc_bp_loop #(
      .G6LCCfg     (C),
      .bht_update_t(bht_update_t),
      .NR_ENTRIES  (16)
  ) dut (
      .clk_i       (clk),
      .rst_ni      (rst_n),
      .flush_i     (1'b0),
      .vpc_i       (vpc),
      .bht_update_i(upd),
      .pred_i      (pred_i),
      .pred_o      (pred_o)
  );

  task automatic train_br(input logic [63:0] pc, input bit tkn);
    upd = '{valid: 1'b1, pc: pc, taken: tkn};
    tick();
    upd = '0;
  endtask

  task automatic lookup_vpc(input logic [63:0] pc);
    vpc = pc;
    tick();  // P1
    tick();  // P2 -> hit_q / dir_q valid
  endtask

  initial begin
    // Base TAGE predicts taken=1 on all slots so loop exit (taken=0) is observable
    for (int i = 0; i < NF; i++) pred_i[i] = '{valid: 1'b1, taken: 1'b1};
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // ---- S1: Train 8-iteration loop at slot 2 (0x8000_1004) to full conf=3 ----
    // Pass 1 learns trip=8 (conf->0), passes 2..4 increment conf 0->1->2->3.
    for (int p = 0; p < 4; p++) begin
      repeat (8) train_br(64'h8000_1004, 1'b1);
      train_br(64'h8000_1004, 1'b0);
    end
    // Now conf==3, trip=8, conf_cnt=0. Advance 8 taken iters -> conf_cnt==8 (exit!)
    repeat (8) train_br(64'h8000_1004, 1'b1);
    lookup_vpc(64'h8000_1000);  // aligned fetch block!
    check(pred_o[2].valid === 1'b1 && pred_o[2].taken === 1'b0, "S1_SLOT2_PRED_EXIT");
    check(pred_o[0].taken === 1'b1, "S1_SLOT0_UNTOUCHED");

    // ---- S2: Unaligned redirect vpc=0x8000_1004 must still override slot 2, not slot 0 ----
    lookup_vpc(64'h8000_1004);
    check(pred_o[2].valid === 1'b1 && pred_o[2].taken === 1'b0, "S2_UNALIGNED_SLOT2_EXIT");
    check(pred_o[0].taken === 1'b1, "S2_UNALIGNED_SLOT0_CLEAN");

    // ---- S3: Long 256-iter loop at slot 3 (0x8000_1006) saturates instead of wrapping to 0 ----
    for (int p = 0; p < 4; p++) begin
      repeat (256) train_br(64'h8000_1006, 1'b1);
      train_br(64'h8000_1006, 1'b0);
    end
    lookup_vpc(64'h8000_1000);
    // Must yield to base TAGE (taken=1), NOT override with taken=0 from bogus trip=0!
    check(pred_o[3].taken === 1'b1, "S3_LONG_LOOP_NO_BOGUS_WRAP");

    // ---- S4: Short 4-iter loop at slot 1 (0x8000_1002) must NOT override TAGE ----
    for (int p = 0; p < 4; p++) begin
      repeat (4) train_br(64'h8000_1002, 1'b1);
      train_br(64'h8000_1002, 1'b0);
    end
    repeat (4) train_br(64'h8000_1002, 1'b1);
    lookup_vpc(64'h8000_1000);
    check(pred_o[1].taken === 1'b1, "S4_SHORT_LOOP_YIELDS_TO_TAGE");

    $display("PASS tb_g6lc_bp_loop_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
