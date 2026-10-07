// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Leaf for core/frontend/g6lc_bp_statcor.sv. The reference model owns one
// 3-bit counter per table row and, since T18, indexes it PER SLOT: slot p of
// the fetch window at vpc owns row ((vpc >> SHIFT) with its low ROW bits
// replaced by p) % ENTRIES, ROW = $clog2(SLOTS) - the same bits the resolving
// branch trains with (its own pc >> SHIFT). Before T18 the DUT read one
// window-base row for every slot, so a hot taken branch at pc X forced
// "taken" onto every branch of every window whose base aliased X.

module tb_g6lc_bp_statcor;
  import ariane_pkg::*;
  parameter int unsigned SLOTS = 2;
  parameter int unsigned ENTRIES = 64;
  parameter bit RVC = 1;
  localparam int unsigned SHIFT = RVC ? 1 : 2;
  localparam int unsigned ROW = (SLOTS > 1) ? $clog2(SLOTS) : 0;
  localparam logic [63:0] PC0 = 64'h80000140;
  // Window / slot geometry helpers (SLOTS and ENTRIES are powers of two).
  localparam logic [63:0] SLOT_STRIDE = 64'd1 << SHIFT;
  localparam logic [63:0] WINDOW_STRIDE = 64'(SLOTS) << SHIFT;
  localparam logic [63:0] TABLE_STRIDE = 64'(ENTRIES) << SHIFT;

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
  int unsigned slot_split = 0, directed = 0;
  string scenario = "init";
  bit negative;

  g6lc_bp_statcor #(.CVA6Cfg(cfg()), .bht_update_t(update_t), .NR_ENTRIES(ENTRIES)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .vpc_i(pc),
    .bht_update_i(update), .pred_i(prediction), .pred_o(result)
  );

  // Row read by slot `slot` of the window fetched at `address`: the address
  // bits above the slot field select the window, the slot number fills the
  // low ROW bits (slot i sits at {address[..], i}, as the BHT rows do).
  function automatic int unsigned row(input logic [63:0] address, input int unsigned slot);
    logic [63:0] r = address >> SHIFT;
    r = (r & ~64'(SLOTS - 1)) | 64'(slot);
    return int'(r % ENTRIES);
  endfunction

  // Row trained by the resolving branch at `address` (its own slot bits).
  function automatic int unsigned urow(input logic [63:0] address);
    return int'((address >> SHIFT) % ENTRIES);
  endfunction

  // Pre-T18 lookup row: the window base for every slot.
  function automatic int unsigned base_row(input logic [63:0] address);
    return urow(address);
  endfunction

  task automatic check_result;
    bht_prediction_t expected, actual;
    for (int p = 0; p < SLOTS; p++) begin
      expected = prediction[p];
      if (prediction[p].valid) begin
        if (weights[row(pc, p)] <= 1) begin
          expected.taken = 0;
          low++;
        end else if (weights[row(pc, p)] >= 6) begin
          expected.taken = 1;
          high++;
        end else neutral++;
        // A check that only a per-slot model gets right: this slot's row is
        // not the window base row and the two counters disagree on the override.
        if (row(pc, p) != base_row(pc) &&
            ((weights[row(pc, p)] <= 1) != (weights[base_row(pc)] <= 1) ||
             (weights[row(pc, p)] >= 6) != (weights[base_row(pc)] >= 6)))
          slot_split++;
      end else invalid++;
      actual = result[p];
      if (negative) begin
        actual.taken = !actual.taken;
        negative = 0;
      end
      if (actual !== expected)
        $fatal(1, "STATCOR_MISMATCH scenario=%s check=%0d slot=%0d pc=%h row=%0d counter=%0d base_row=%0d base_counter=%0d incoming=%b expected=%b actual=%b",
               scenario, checks, p, pc, row(pc, p), weights[row(pc, p)], base_row(pc), weights[base_row(pc)], prediction[p], expected, actual);
      checks++;
    end
  endtask

  // Reference-model training on a resolved branch.
  function automatic void train(input logic [63:0] train_pc, input bit taken);
    if (taken && weights[urow(train_pc)] < 7) weights[urow(train_pc)] = weights[urow(train_pc)] + 1;
    if (!taken && weights[urow(train_pc)] > 0) weights[urow(train_pc)] = weights[urow(train_pc)] - 1;
  endfunction

  task automatic step(input logic [63:0] lookup,
                      input bit train_en = 0,
                      input logic [63:0] train_pc = PC0,
                      input bit taken = 0,
                      input bit squash = 0,
                      input bit reset = 0,
                      input int unsigned pattern = 0);
    bit hit;
    pc = lookup;
    update = '{valid: train_en, pc: train_pc, taken: taken};
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
    end else if (train_en) begin
      train(train_pc, taken);
      hit = 0;
      for (int p = 0; p < SLOTS; p++) if (row(lookup, p) == urow(train_pc)) hit = 1;
      if (lookup != train_pc && hit) aliases++;
      if (!hit) concurrent++;
    end
    clk = 1;
    #2;
    check_result();
    clk = 0;
    #1;
  endtask

  // Directed cycle: exactly one valid incoming prediction (slot `slot`,
  // direction `incoming`) on the fetch at `vpc`, optionally training
  // `train_pc`/`taken` in the same cycle. The directed expectation `want`
  // is asserted on the corrected direction first (with the `why` label), then
  // the generic per-slot model check runs as in step().
  task automatic slot_cycle(input string why, input logic [63:0] vpc, input int unsigned slot,
                            input bit incoming, input bit want,
                            input bit train_en = 0, input logic [63:0] train_pc = PC0,
                            input bit taken = 0);
    pc = vpc;
    update = '{valid: train_en, pc: train_pc, taken: taken};
    flush = 0;
    rst_n = 1;
    for (int p = 0; p < SLOTS; p++) begin
      prediction[p].valid = (p == slot);
      prediction[p].taken = incoming;
    end
    #2;
    if (result[slot].taken !== want)
      $fatal(1, "STATCOR_T18_ALIAS scenario=%s %s: fetch=%h slot=%0d incoming=%0d expected=%0d actual=%0d (slot row %0d=%0d, window-base row %0d=%0d)",
             scenario, why, vpc, slot, incoming, want, result[slot].taken,
             row(vpc, slot), weights[row(vpc, slot)], base_row(vpc), weights[base_row(vpc)]);
    check_result();
    if (train_en) begin
      train(train_pc, taken);
      if (vpc != train_pc && row(vpc, slot) == urow(train_pc)) aliases++;
    end
    clk = 1;
    #2;
    check_result();
    clk = 0;
    #1;
  endtask

  // Directed T18 aliasing shape. Trainer A (slot `slot_a` of window `w1`) is
  // saturated taken. Victim B is slot `slot_b` of the fetch at `w2`, where
  // base_row(w2) == urow(A) (the pre-T18 lookup row of every slot of that
  // fetch) but row(w2, slot_b) != urow(A): B shares nothing with A but the old
  // window-base index. B must not be forced taken; and B's not-taken training
  // (to 0) must leave A forced taken. Only the branch's own slot carries a
  // valid prediction while it trains, so the first thing the pre-T18 DUT can
  // fail is the victim lookup itself.
  task automatic t18_alias(input string name, input logic [63:0] w1, input int unsigned slot_a,
                           input logic [63:0] w2, input int unsigned slot_b);
    logic [63:0] a_pc, b_pc;
    a_pc = (w1 & ~(WINDOW_STRIDE - 1)) | (64'(slot_a) << SHIFT);
    b_pc = (w2 & ~(WINDOW_STRIDE - 1)) | (64'(slot_b) << SHIFT);
    scenario = name;
    if (base_row(w2) != urow(a_pc) || row(w2, slot_b) == urow(a_pc) || urow(b_pc) != row(w2, slot_b) ||
        row(w1, slot_a) != urow(a_pc))
      $fatal(1, "STATCOR_T18_SETUP %s: w1=%h A=%h urow(A)=%0d w2=%h base_row(w2)=%0d B=%h row(w2,%0d)=%0d",
             name, w1, a_pc, urow(a_pc), w2, base_row(w2), b_pc, slot_b, row(w2, slot_b));
    // A resolves taken 12 times (counter 4 -> 7) while its own window is
    // fetched; from the 3rd update on its incoming not-taken is overridden.
    for (int n = 0; n < 12; n++)
      slot_cycle("trainer-saturating", w1, slot_a, 0, weights[urow(a_pc)] >= 6, 1, a_pc, 1);
    if (weights[urow(a_pc)] != 7) $fatal(1, "STATCOR_T18_SETUP %s: A counter %0d", name, weights[urow(a_pc)]);
    // B's base predictor says not-taken; the corrector must leave it alone
    // (B's own counter is neutral) even though the window base aliases A.
    slot_cycle("victim-forced-taken-by-window-base-alias", w2, slot_b, 0, 0);
    slot_cycle("victim-incoming-taken-flipped", w2, slot_b, 1, 1);
    // Converse: B resolves not-taken until its own counter is 0 (its
    // incoming taken is overridden from the 3rd update on); A must still be
    // forced taken on its own window and B forced not-taken.
    for (int n = 0; n < 12; n++)
      slot_cycle("victim-training", w2, slot_b, 1, weights[urow(b_pc)] > 1, 1, b_pc, 0);
    if (weights[urow(b_pc)] != 0 || weights[urow(a_pc)] != 7)
      $fatal(1, "STATCOR_T18_SETUP %s: B counter %0d A counter %0d", name, weights[urow(b_pc)], weights[urow(a_pc)]);
    slot_cycle("trainer-lost-override-after-victim-training", w1, slot_a, 0, 1);
    slot_cycle("victim-not-forced-by-own-counter", w2, slot_b, 1, 0);
    // The other slots of both windows are untouched (neutral), except a slot
    // of w2 that legitimately owns A's row.
    for (int p = 0; p < SLOTS; p++) begin
      if (p != slot_a) slot_cycle("trainer-window-neighbour", w1, p, 0, weights[row(w1, p)] >= 6);
      if (p != slot_b) slot_cycle("victim-window-neighbour", w2, p, 0, weights[row(w2, p)] >= 6);
    end
    directed++;
    $display("STATCOR_T18_ALIAS_OK %s A=%h(row %0d) B=%h(row %0d) fetch=%h base_row=%0d", name, a_pc, urow(a_pc), b_pc, urow(b_pc), w2, base_row(w2));
  endtask

  initial begin
    string shape = "both";
    int unsigned want_directed = 0;
    negative = $test$plusargs("oracle_negative");
    // +t18_shape=window|redirect runs a single directed shape (attribution
    // runs against a pre-T18 DUT); default is both.
    void'($value$plusargs("t18_shape=%s", shape));
    foreach (weights[i]) weights[i] = 4;
    step(PC0, 0, PC0, 0, 0, 1);
    if (SLOTS > 1 && shape != "redirect") begin
      // T18 firmware shape (fdt_offset_ptr+0x6c): trainer at slot 0 of its
      // window, victim at the last slot of an aligned window one table span
      // away, whose base row is the trainer's row.
      t18_alias("t18-window-base", PC0 + 3 * WINDOW_STRIDE, 0,
                PC0 + 3 * WINDOW_STRIDE + TABLE_STRIDE, SLOTS - 1);
      step(PC0, 0, PC0, 0, 0, 1);
      want_directed++;
    end
    if (SLOTS > 1 && shape != "window") begin
      // Redirect-target shape (T18 probe F8): trainer at slot 1 of W1; the
      // victim's fetch starts at the slot-1 address of a window one table
      // span away (base row == trainer row), victim at slot 0 of that fetch.
      t18_alias("t18-redirect-base", PC0 + 5 * WINDOW_STRIDE, 1,
                PC0 + 5 * WINDOW_STRIDE + TABLE_STRIDE + SLOT_STRIDE, 0);
      step(PC0, 0, PC0, 0, 0, 1);
      want_directed++;
    end
    scenario = "train-down";
    for (int n = 0; n < 12; n++) step(PC0, 1, PC0, 0, 0, 0, n);
    scenario = "train-up";
    for (int n = 0; n < 12; n++) step(PC0, 1, PC0, 1, 0, 0, n);
    scenario = "alternate";
    for (int n = 0; n < 48; n++) step(PC0, 1, PC0, n % 2, 0, 0, n);
    scenario = "biased";
    for (int n = 0; n < 48; n++) step(PC0, 1, PC0, (n % 8) < 6, 0, 0, n);
    scenario = "flush";
    step(PC0, 1, PC0, 0, 1);
    for (int n = 0; n < 12; n++) step(PC0, 1, PC0, 0, 0, 0, n);
    scenario = "table-alias";
    for (int n = 0; n < 12; n++)
      step(PC0, 1, PC0 + TABLE_STRIDE, 1, 0, 0, n);
    scenario = "neighbour";
    for (int n = 0; n < 12; n++)
      step(PC0, 1, PC0 + SLOT_STRIDE, 0, 0, 0, n);
    for (int n = 0; n < 6; n++) step(PC0 + SLOT_STRIDE, 0, PC0, 0, 0, 0, n);
    scenario = "reset";
    step(PC0, 1, PC0, 1, 0, 1);
    scenario = "random";
    for (int n = 0; n < 160; n++) begin
      step(PC0 + (64'(n % ENTRIES) << SHIFT), 1,
           PC0 + (64'((n * 3) % ENTRIES) << SHIFT), (n % 7) < 3,
           n % 31 == 30, 0, n);
    end
    if (!checks || !low || !high || !neutral || !invalid || resets < 2 || !flushes || !aliases || !concurrent ||
        directed != want_directed || (SLOTS > 1 && !slot_split))
      $fatal(1, "STATCOR_COVERAGE checks=%0d low=%0d high=%0d neutral=%0d invalid=%0d resets=%0d flushes=%0d aliases=%0d concurrent=%0d directed=%0d slot_split=%0d",
             checks, low, high, neutral, invalid, resets, flushes, aliases, concurrent, directed, slot_split);
    $display("STATCOR_PASS checks=%0d low=%0d high=%0d neutral=%0d invalid=%0d resets=%0d flushes=%0d aliases=%0d concurrent=%0d directed=%0d slot_split=%0d",
             checks, low, high, neutral, invalid, resets, flushes, aliases, concurrent, directed, slot_split);
    $finish;
  end
endmodule
