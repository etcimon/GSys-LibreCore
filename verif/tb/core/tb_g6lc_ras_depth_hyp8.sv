// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 ras leaf verifying Bug #5 (general DEPTH=8 circular-ring RAS
// was previously undriven whenever DEPTH != 2).
//
// Review mutation (must fail):
//   -DG6LC_MUT_RAS_NO_GENERAL_DEPTH -> fails S1_PUSH_VALID
//
// PASS token: PASS tb_g6lc_ras_depth_hyp8
module tb_g6lc_ras_depth_hyp8;
  import g6lc_core_pkg::*;
  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned D = 8;
  localparam int unsigned PW = $clog2(D);
  localparam int unsigned CW = $clog2(D + 1);
  typedef struct packed {
    logic                valid;
    logic [C.VLEN-1:0]   ra;
  } ras_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_ras_depth_hyp8");
    end
  endtask

  logic push_i = 0, pop_i = 0, flush_bp = 0;
  logic [C.VLEN-1:0] data_i = '0;
  ras_t data_o;
  logic [PW-1:0] snap_tos, res_tos = '0;
  logic [CW-1:0] snap_cnt, res_cnt = '0;
  logic [C.VLEN-1:0] snap_top, res_top = '0, res_push_ra = '0;
  logic res_i = 0, res_pop = 0, res_push = 0;

  ras #(
      .G6LCCfg(C),
      .ras_t  (ras_t),
      .DEPTH  (D)
  ) dut (
      .clk_i            (clk),
      .rst_ni           (rst_n),
      .flush_bp_i       (flush_bp),
      .hart_i           ('0),
      .restore_hart_i   ('0),
      .epoch_i          ('0),
      .spec_epoch_i     ('0),
      .push_i           (push_i),
      .pop_i            (pop_i),
      .data_i           (data_i),
      .data_o           (data_o),
      .snap_tos_o       (snap_tos),
      .snap_cnt_o       (snap_cnt),
      .snap_top_o       (snap_top),
      .restore_i        (res_i),
      .restore_tos_i    (res_tos),
      .restore_cnt_i    (res_cnt),
      .restore_top_i    (res_top),
      .restore_pop_i    (res_pop),
      .restore_push_i   (res_push),
      .restore_push_ra_i(res_push_ra),
      .restore_epoch_i  ('0)
  );

  logic [PW-1:0] saved_tos;
  logic [CW-1:0] saved_cnt;
  logic [C.VLEN-1:0] saved_top;

  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // S1: Push 4 nested calls into DEPTH=8 RAS and verify LIFO pop order
    for (int k = 1; k <= 4; k++) begin
      push_i = 1'b1; data_i = 64'h8000_0004 + (64'(k) << 12);
      tick();
    end
    push_i = 1'b0;
    check(data_o.valid === 1'b1, "S1_PUSH_VALID");
    check(data_o.ra === 64'h8000_4004, "S1_TOP4_RA");
    saved_tos = snap_tos; saved_cnt = snap_cnt; saved_top = snap_top;

    // Pop 4 -> 3 -> 2 -> 1 -> empty
    pop_i = 1'b1; tick(); check(data_o.ra === 64'h8000_3004, "S1_POP_TO_3");
    pop_i = 1'b1; tick(); check(data_o.ra === 64'h8000_2004, "S1_POP_TO_2");
    pop_i = 1'b1; tick(); check(data_o.ra === 64'h8000_1004, "S1_POP_TO_1");
    pop_i = 1'b1; tick(); pop_i = 1'b0;
    check(data_o.valid === 1'b0 && data_o.ra === 64'h0, "S1_EMPTY_ZERO");

    // S2: Checkpoint restore with restore_push re-applies call onto saved depth 4
    res_i = 1'b1; res_tos = saved_tos; res_cnt = saved_cnt; res_top = saved_top;
    res_push = 1'b1; res_push_ra = 64'h8000_5004;
    tick();
    res_i = 1'b0; res_push = 1'b0;
    tick(); // registered restore lands
    check(data_o.valid === 1'b1 && data_o.ra === 64'h8000_5004, "S2_RESTORE_PUSH_RA");
    check(snap_cnt === CW'(5), "S2_RESTORE_CNT5");

    $display("PASS tb_g6lc_ras_depth_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
