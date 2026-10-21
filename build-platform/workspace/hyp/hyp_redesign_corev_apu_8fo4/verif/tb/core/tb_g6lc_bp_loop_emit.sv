// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Package-compatible leaf top for paired synthesis / matched-state equivalence
// of the loop predictor: the production source against the sv-timing emitted
// `row-local` form of the same file. The module under test is selected by
// filelist order (the emitted copy renames nothing), so one wrapper serves
// both variants. Geometry matches the shipped predictor instance.
module g6lc_loop_timing
  import g6lc_core_pkg::*;
#(
  parameter int unsigned SLOTS = 4,
  parameter int unsigned ENTRIES = 16,
  parameter bit RVC = 1
) (
  input logic clk_i, rst_ni, flush_i,
  input logic [63:0] vpc_i, update_pc_i,
  input logic update_valid_i, update_taken_i,
  input bht_prediction_t [SLOTS-1:0] pred_i,
  output bht_prediction_t [SLOTS-1:0] pred_o
);
  function automatic config_pkg::g6lc_cfg_t cfg();
    cfg = config_pkg::g6lc_cfg_empty;
    cfg.XLEN = 64; cfg.VLEN = 64; cfg.RVC = RVC;
    cfg.INSTR_PER_FETCH = SLOTS;
  endfunction
  typedef struct packed {logic valid; logic [63:0] pc; logic taken;} update_t;
  update_t update;
  assign update = '{valid: update_valid_i, pc: update_pc_i, taken: update_taken_i};
  g6lc_bp_loop #(.G6LCCfg(cfg()), .bht_update_t(update_t), .NR_ENTRIES(ENTRIES)) dut (
    .clk_i, .rst_ni, .flush_i, .vpc_i, .bht_update_i(update), .pred_i, .pred_o);
endmodule

// Independent reference model of the loop predictor on random streams. The
// witness compares the DUT's override decision with a per-row model of the
// tag / trip / iteration / confidence rules every cycle, including flush.
module tb_g6lc_bp_loop;
  import g6lc_core_pkg::*;
  parameter int unsigned SLOTS = 4;
  parameter int unsigned ENTRIES = 16;
  localparam int unsigned IDXB = $clog2(ENTRIES);
  localparam int unsigned OFFSET = 1;
  logic clk = 0, rst_n = 0, flush = 0;
  logic [63:0] pc, upc;
  logic uvalid, utaken;
  bht_prediction_t [SLOTS-1:0] pred_i, pred_o;
  g6lc_loop_timing #(.SLOTS(SLOTS), .ENTRIES(ENTRIES)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .vpc_i(pc), .update_pc_i(upc),
    .update_valid_i(uvalid), .update_taken_i(utaken), .pred_i(pred_i), .pred_o(pred_o));
  typedef struct {bit valid; logic [63:0] tag; int unsigned trip, cnt, conf;} entry_t;
  entry_t model[ENTRIES];
  int unsigned checks = 0, overrides = 0, allocs = 0, exits = 0, flushes = 0, seed = 1;
  bit negative = 0;
  always #1 clk = ~clk;
  function automatic int unsigned row(input logic [63:0] a);
    return int'(a[OFFSET+:IDXB]);
  endfunction
  task automatic check();
    bht_prediction_t exp[SLOTS];
    int unsigned r = row(pc);
    for (int s = 0; s < SLOTS; s++) exp[s] = pred_i[s];
    if (model[r].valid && model[r].tag == pc && model[r].conf >= 2) begin
      exp[0].valid = 1'b1;
      exp[0].taken = model[r].cnt < model[r].trip;
      overrides++;
    end
    if (negative) begin exp[0].taken = !exp[0].taken; negative = 0; end
    for (int s = 0; s < SLOTS; s++) begin
      if (pred_o[s] !== exp[s])
        $fatal(1, "LOOP_MISMATCH check=%0d slot=%0d pc=%h row=%0d exp=%b got=%b", checks, s, pc, r, exp[s], pred_o[s]);
      checks++;
    end
  endtask
  function automatic void train();
    int unsigned r = row(upc);
    if (!uvalid) return;
    if (model[r].valid && model[r].tag == upc) begin
      if (utaken) model[r].cnt++;
      else begin
        exits++;
        if (model[r].cnt == model[r].trip) begin
          if (model[r].conf != 3) model[r].conf++;
        end else begin
          model[r].trip = model[r].cnt;
          if (model[r].conf != 0) model[r].conf--;
        end
        model[r].cnt = 0;
      end
    end else if (utaken) begin
      model[r] = '{valid: 1, tag: upc, trip: 1, cnt: 1, conf: 1};
      allocs++;
    end
    model[r].cnt &= 255; model[r].trip &= 255;
  endfunction
  initial begin
    logic [63:0] pcs[8];
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    negative = $test$plusargs("oracle_negative");
    void'($urandom(seed));
    foreach (model[i]) model[i] = '{default: 0};
    for (int i = 0; i < 8; i++) pcs[i] = 64'h8000_0000 + (($urandom % 512) << 1);
    uvalid = 0; utaken = 0; upc = pcs[0]; pc = pcs[0]; pred_i = '0;
    #5 rst_n = 1;
    for (int cyc = 0; cyc < 60000; cyc++) begin
      @(negedge clk);
      // Mostly revisit a small PC set so rows are tagged, trained and exited;
      // sometimes alias a row with a different tag to exercise replacement.
      pc = ($urandom % 16 == 0) ? pcs[$urandom % 8] + 64'(ENTRIES << OFFSET) : pcs[$urandom % 8];
      upc = ($urandom % 4 == 0) ? pc : pcs[$urandom % 8];
      uvalid = $urandom % 3 != 0;
      utaken = $urandom % 5 != 0;
      flush = $urandom % 2000 == 0;
      for (int s = 0; s < SLOTS; s++) begin
        pred_i[s].valid = $urandom % 2; pred_i[s].taken = $urandom % 2;
      end
      #0.2 check();
      @(posedge clk);
      #0.2;
      if (flush) begin
        flushes++;
        foreach (model[i]) begin model[i].valid = 0; model[i].cnt = 0; end
      end else train();
    end
    if (!overrides || !allocs || !exits || !flushes)
      $fatal(1, "LOOP_COVERAGE overrides=%0d allocs=%0d exits=%0d flushes=%0d", overrides, allocs, exits, flushes);
    $display("LOOP_PASS checks=%0d overrides=%0d allocs=%0d exits=%0d flushes=%0d", checks, overrides, allocs, exits, flushes);
    $finish;
  end
endmodule
