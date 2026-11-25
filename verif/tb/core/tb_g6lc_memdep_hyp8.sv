// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 g6lc_memdep leaf: proves learned memory-dependence wait entries
// survive violation replay flushes & branch mispredicts while transient query
// stages still squash on flush_i and periodic epoch clear prevents saturation.
//
// Scenarios:
//   S1. Violation learned -> commit-time replay flush_i -> re-dispatched load
//       at the same PC predicts stall_o=1 / predict_o=1 (unrelated PC stays 0).
//   S2. Same-cycle violation + flush_i still trains ld_wait_q.
//   S3. In-flight query squashed cleanly when flush_i asserts.
//   S4. Periodic epoch clear (CLEAR_BITS=6 -> 64 cycles) decays stale entries.
//
// Review mutation (must fail):
//   -DG6LC_MUT_MEMDEP_FLUSH_WIPE -> S1 fails S1_LEARNED_SURVIVES_REPLAY_FLUSH
//
// PASS token: PASS tb_g6lc_memdep_hyp8
module tb_g6lc_memdep_hyp8;
  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned NP = C.NrIssuePorts;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_memdep_hyp8");
    end
  endtask

  logic                   flush = 0, store_pend = 1'b1, train_v = 0;
  logic [C.VLEN-1:0]      train_pc = '0;
  logic [NP-1:0]          st_v = '0, ld_q = '0, stall_o, predict_o;
  logic [NP-1:0][C.VLEN-1:0] st_pc = '0, ld_pc = '0;

  g6lc_memdep #(
      .G6LCCfg   (C),
      .NR_SETS   (64),
      .NR_TRAIN  (NP),
      .NR_QUERY  (NP),
      .CLEAR_BITS(6)  // 64-cycle periodic clear for fast S4 verification
  ) dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .flush_i        (flush),
      .enable_i       (1'b1),
      .st_valid_i     (st_v),
      .st_pc_i        (st_pc),
      .ld_query_i     (ld_q),
      .ld_pc_i        (ld_pc),
      .train_valid_i  (train_v),
      .train_pc_i     (train_pc),
      .store_pending_i(store_pend),
      .stall_o        (stall_o),
      .predict_o      (predict_o)
  );

  task automatic query_pc(input logic [C.VLEN-1:0] pc);
    ld_q     = '0;
    ld_q[0]  = 1'b1;
    ld_pc[0] = pc;
    tick();  // stage 1: ld_query_q captures
    ld_q     = '0;
    tick();  // stage 2: predict_q / stall_q valid
  endtask

  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // ---- S1: Cold load bypasses -> violates -> replay flush -> re-dispatched load stalls ----
    query_pc(64'h0000_0000_8000_2040);
    check(predict_o[0] === 1'b0 && stall_o[0] === 1'b0, "S1_COLD_BYPASS");

    // LSQ reports violation for 0x8000_2040
    train_v  = 1'b1;
    train_pc = 64'h0000_0000_8000_2040;
    tick();
    train_v  = 1'b0;
    tick();  // train_valid_q commits into ld_wait_q

    // Commit-time replay flush fires to re-execute the violating load!
    flush = 1'b1;
    tick();
    flush = 1'b0;

    // Re-dispatch the violating load -> predictor MUST remember it!
    query_pc(64'h0000_0000_8000_2040);
    check(predict_o[0] === 1'b1 && stall_o[0] === 1'b1, "S1_LEARNED_SURVIVES_REPLAY_FLUSH");

    // Unrelated load PC must still bypass cleanly
    query_pc(64'h0000_0000_8000_2100);
    check(predict_o[0] === 1'b0 && stall_o[0] === 1'b0, "S1_UNRELATED_BYPASSES");

    // ---- S2: Same-cycle violation + flush_i still trains ld_wait_q ----
    train_v  = 1'b1;
    train_pc = 64'h0000_0000_8000_2080;
    flush    = 1'b1;
    tick();
    train_v  = 1'b0;
    flush    = 1'b0;
    tick();  // train_valid_q commits into ld_wait_q
    query_pc(64'h0000_0000_8000_2080);
    check(predict_o[0] === 1'b1 && stall_o[0] === 1'b1, "S2_SAME_CYC_FLUSH_TRAINS");

    // ---- S3: In-flight query still squashed on flush_i ----
    ld_q     = '0;
    ld_q[0]  = 1'b1;
    ld_pc[0] = 64'h0000_0000_8000_2040;
    tick();
    ld_q  = '0;
    flush = 1'b1;
    tick();
    flush = 1'b0;
    check(predict_o[0] === 1'b0 && stall_o[0] === 1'b0, "S3_INFLIGHT_QUERY_SQUASHED");

    // ---- S4: Periodic epoch clear (64 cycles) decays stale entries ----
    repeat (64) tick();
    query_pc(64'h0000_0000_8000_2040);
    check(predict_o[0] === 1'b0 && stall_o[0] === 1'b0, "S4_PERIODIC_DECAY_CLEARS");

    $display("PASS tb_g6lc_memdep_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
