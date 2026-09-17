// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_bp_statcor;
  import ariane_pkg::*;
  parameter int unsigned SLOTS = 2;
  parameter int unsigned ENTRIES = 64;
  parameter bit RVC = 1;
  localparam int unsigned SHIFT = RVC ? 1 : 2;
  localparam logic [63:0] PC0 = 64'h80000140;

  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.RVC = RVC;
    c.INSTR_PER_FETCH = SLOTS;
    return c;
  endfunction

  typedef struct packed {
    logic valid;
    logic [63:0] pc;
    logic taken;
  } update_t;

  logic clk = 0, rst_n = 0, flush = 0;
  logic [63:0] pc;
  update_t update;
  bht_prediction_t [SLOTS-1:0] prediction, result;
  int unsigned weights[ENTRIES];
  int unsigned checks = 0, low = 0, high = 0, neutral = 0, invalid = 0;
  int unsigned resets = 0, flushes = 0, aliases = 0, concurrent = 0;
  bit negative;

  g6lc_bp_statcor #(.CVA6Cfg(cfg()), .bht_update_t(update_t), .NR_ENTRIES(ENTRIES)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .vpc_i(pc),
    .bht_update_i(update), .pred_i(prediction), .pred_o(result)
  );

  function automatic int unsigned row(input logic [63:0] address);
    return int'((address >> SHIFT) % ENTRIES);
  endfunction

  task automatic check_result;
    bht_prediction_t expected, actual;
    for (int p = 0; p < SLOTS; p++) begin
      expected = prediction[p];
      if (prediction[p].valid) begin
        if (weights[row(pc)] <= 1) begin
          expected.taken = 0;
          low++;
        end else if (weights[row(pc)] >= 6) begin
          expected.taken = 1;
          high++;
        end else neutral++;
      end else invalid++;
      actual = result[p];
      if (negative) begin
        actual.taken = !actual.taken;
        negative = 0;
      end
      if (actual !== expected)
        $fatal(1, "STATCOR_MISMATCH check=%0d slot=%0d pc=%h counter=%0d incoming=%b expected=%b actual=%b", checks, p, pc, weights[row(pc)], prediction[p], expected, actual);
      checks++;
    end
  endtask

  task automatic step(input logic [63:0] lookup,
                      input bit train = 0,
                      input logic [63:0] train_pc = PC0,
                      input bit taken = 0,
                      input bit squash = 0,
                      input bit reset = 0,
                      input int unsigned pattern = 0);
    pc = lookup;
    update = '{valid: train, pc: train_pc, taken: taken};
    flush = squash;
    rst_n = !reset;
    for (int p = 0; p < SLOTS; p++) begin
      prediction[p].valid = ((pattern + p) % 3) != 2;
      prediction[p].taken = ((pattern + p) % 2) != 0;
    end
    #2;
    if (!reset) check_result();
    if (reset || squash) begin
      foreach (weights[i]) weights[i] = 4;
      if (reset) resets++;
      else flushes++;
    end else if (train) begin
      if (taken && weights[row(train_pc)] < 7) weights[row(train_pc)] = weights[row(train_pc)] + 1;
      if (!taken && weights[row(train_pc)] > 0) weights[row(train_pc)] = weights[row(train_pc)] - 1;
      if (lookup != train_pc && row(lookup) == row(train_pc)) aliases++;
      if (row(lookup) != row(train_pc)) concurrent++;
    end
    clk = 1;
    #2;
    check_result();
    clk = 0;
    #1;
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    foreach (weights[i]) weights[i] = 4;
    step(PC0, 0, PC0, 0, 0, 1);
    for (int n = 0; n < 12; n++) step(PC0, 1, PC0, 0, 0, 0, n);
    for (int n = 0; n < 12; n++) step(PC0, 1, PC0, 1, 0, 0, n);
    for (int n = 0; n < 48; n++) step(PC0, 1, PC0, n % 2, 0, 0, n);
    for (int n = 0; n < 48; n++) step(PC0, 1, PC0, (n % 8) < 6, 0, 0, n);
    step(PC0, 1, PC0, 0, 1);
    for (int n = 0; n < 12; n++) step(PC0, 1, PC0, 0, 0, 0, n);
    for (int n = 0; n < 12; n++)
      step(PC0, 1, PC0 + (64'(ENTRIES) << SHIFT), 1, 0, 0, n);
    for (int n = 0; n < 12; n++)
      step(PC0, 1, PC0 + (64'd1 << SHIFT), 0, 0, 0, n);
    for (int n = 0; n < 6; n++) step(PC0 + (64'd1 << SHIFT), 0, PC0, 0, 0, 0, n);
    step(PC0, 1, PC0, 1, 0, 1);
    for (int n = 0; n < 160; n++) begin
      step(PC0 + (64'(n % ENTRIES) << SHIFT), 1,
           PC0 + (64'((n * 3) % ENTRIES) << SHIFT), (n % 7) < 3,
           n % 31 == 30, 0, n);
    end
    if (!checks || !low || !high || !neutral || !invalid || resets < 2 || !flushes || !aliases || !concurrent)
      $fatal(1, "STATCOR_COVERAGE checks=%0d low=%0d high=%0d neutral=%0d invalid=%0d resets=%0d flushes=%0d aliases=%0d concurrent=%0d", checks, low, high, neutral, invalid, resets, flushes, aliases, concurrent);
    $display("STATCOR_PASS checks=%0d low=%0d high=%0d neutral=%0d invalid=%0d resets=%0d flushes=%0d aliases=%0d concurrent=%0d", checks, low, high, neutral, invalid, resets, flushes, aliases, concurrent);
    $finish;
  end
endmodule
