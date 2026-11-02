// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_snoop_filter — sharer-set soundness for g6lc_snoop_filter.
//
// The filter's whole safety argument is that `present_o` may over-report but
// must never UNDER-report: the hub computes a write's invalidation targets as
// `sf_present & ~(1 << writer)`, so a core missing from that set keeps a stale
// line. The module header states the intent ("over-approx on capacity miss ...
// so correctness is preserved (extra snoops only)").
//
// This bench holds the filter to that contract. The oracle is an independent
// model of what each core actually holds, built from the allocations the bench
// itself issued — never from the DUT's arrays. `clear_valid_i` is left tied off
// exactly as the hub wires it, so a core never withdraws presence and the model
// is a pure accumulation.

`timescale 1ns/1ps

module tb_g6lc_snoop_filter;
  parameter int unsigned NR_CORES   = 2;
  parameter int unsigned NR_ENTRIES = 4;
  parameter int unsigned LINE_BYTES = 64;
  parameter int unsigned ADDR_WIDTH = 64;

  localparam int unsigned CID_W = (NR_CORES <= 1) ? 1 : $clog2(NR_CORES);
  localparam int unsigned IDX_W = $clog2(NR_ENTRIES);
  // Addresses this far apart land in the same filter set with a different tag.
  localparam longint unsigned SET_STRIDE = LINE_BYTES * NR_ENTRIES;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic alloc_valid = 1'b0, lookup_valid = 1'b0;
  // Delivered-invalidation clears (the hub drives these from the handshake).
  logic [NR_CORES-1:0] inv_clear_valid = '0, inv_clear_all = '0;
  logic [NR_CORES-1:0][ADDR_WIDTH-1:0] inv_clear_addr = '0;
  logic [ADDR_WIDTH-1:0] alloc_addr = '0, lookup_addr = '0;
  logic [CID_W-1:0] alloc_core = '0;
  logic [NR_CORES-1:0] present;
  logic lookup_hit, overapprox;

  int unsigned errors = 0;
  bit negative;
  int scenario;

  // Independent model: which cores hold which line, from this bench's own
  // allocations. Presence is never withdrawn because the hub never clears.
  bit held[longint unsigned][NR_CORES];

  g6lc_snoop_filter #(
      .Enable(1'b1), .NR_CORES(NR_CORES), .NR_ENTRIES(NR_ENTRIES),
      .LINE_BYTES(LINE_BYTES), .ADDR_WIDTH(ADDR_WIDTH)
  ) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .alloc_valid_i(alloc_valid), .alloc_addr_i(alloc_addr), .alloc_core_i(alloc_core),
      .clear_valid_i(1'b0), .clear_addr_i('0), .clear_core_i('0), .clear_all_i(1'b0),
      .inv_clear_valid_i(inv_clear_valid), .inv_clear_all_i(inv_clear_all),
      .inv_clear_addr_i(inv_clear_addr),
      .lookup_valid_i(lookup_valid), .lookup_addr_i(lookup_addr),
      .present_o(present), .lookup_hit_o(lookup_hit), .overapprox_o(overapprox)
  );

  task automatic fetch(input int unsigned core, input longint unsigned addr);
    alloc_valid = 1'b1; alloc_addr = addr; alloc_core = CID_W'(core);
    held[addr / LINE_BYTES][core] = 1'b1;
    @(negedge clk);
    alloc_valid = 1'b0;
  endtask

  // A delivered invalidation: the core drops the line (all of them for an
  // all_ways one), in the model and on the DUT's clear port. With
  // `with_fetch` the same core refetches the line in the same cycle.
  task automatic deliver(input int unsigned core, input longint unsigned addr,
                         input bit all = 1'b0, input bit with_fetch = 1'b0);
    inv_clear_valid[core] = 1'b1; inv_clear_all[core] = all; inv_clear_addr[core] = addr;
    if (all) begin
      foreach (held[l]) held[l][core] = 1'b0;
    end else begin
      held[addr / LINE_BYTES][core] = 1'b0;
    end
    if (with_fetch) begin
      alloc_valid = 1'b1; alloc_addr = addr; alloc_core = CID_W'(core);
      held[addr / LINE_BYTES][core] = 1'b1;
    end
    @(negedge clk);
    inv_clear_valid = '0; inv_clear_all = '0; alloc_valid = 1'b0;
  endtask

  // Precision: after the clears, a write by `writer` must target exactly
  // `expect_targets` (the bench knows nobody else holds the line).
  task automatic check_precise(input int unsigned writer, input longint unsigned addr,
                               input logic [NR_CORES-1:0] expect_targets);
    lookup_valid = 1'b1; lookup_addr = addr;
    #1;
    if ((present & ~(NR_CORES'(1) << writer)) !== expect_targets) begin
      errors = errors + 1;
      $display("SF_IMPRECISE addr=%h writer=%0d targets=%b expected=%b",
               addr, writer, present & ~(NR_CORES'(1) << writer), expect_targets);
    end
    @(negedge clk);
    lookup_valid = 1'b0;
  endtask

  // A write to `addr` must snoop every core that holds the line, except the
  // writer. Under-reporting is the failure; over-reporting is allowed.
  task automatic check_write(input int unsigned writer, input longint unsigned addr);
    logic [NR_CORES-1:0] must, targets;
    lookup_valid = 1'b1; lookup_addr = addr;
    #1;
    must = '0;
    for (int unsigned c = 0; c < NR_CORES; c++)
      if (held[addr / LINE_BYTES][c] && c != writer) must[c] = 1'b1;
    targets = present & ~(NR_CORES'(1) << writer);
    // Injected-error control: perturb the OBSERVED target set so exactly the
    // required cores go missing. This is the same shape as the L2 bench's
    // +oracle_negative (perturb what was observed, not what is expected), and it
    // fires for any nonempty requirement — unlike inflating the oracle, which a
    // correctly over-approximating filter would satisfy anyway.
    if (negative) targets = targets & ~must;
    if ((must & ~targets) != 0) begin
      errors = errors + 1;
      $display("SF_SHARER_LOST addr=%h writer=%0d must=%b targets=%b hit=%0b over=%0b",
               addr, writer, must, targets, lookup_hit, overapprox);
    end
    @(negedge clk);
    lookup_valid = 1'b0;
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    scenario = 0;
    void'($value$plusargs("scenario=%d", scenario));
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    case (scenario)
      // A set conflict displaces a shared line's entry; re-installing that line
      // from ONE core must not claim it is the only holder.
      0: begin
        fetch(0, 64'h4000);                 // core 0 holds L
        fetch(1, 64'h4000);                 // both hold L
        check_write(1, 64'h4000);           // baseline: core 0 must be snooped
        fetch(1, 64'h4000 + SET_STRIDE);    // conflicting line displaces L's entry
        check_write(1, 64'h4000);           // displaced: must over-approximate
        fetch(1, 64'h4000);                 // L re-installed by core 1 alone
        check_write(1, 64'h4000);           // core 0 still holds L
      end
      // Same shape with the roles swapped.
      1: begin
        fetch(1, 64'h9000);
        fetch(0, 64'h9000);
        fetch(0, 64'h9000 + SET_STRIDE * 2);
        fetch(0, 64'h9000);
        check_write(0, 64'h9000);
      end
      // Non-conflicting traffic must stay precise, so a fix cannot simply
      // report everyone always: a line only core 0 ever fetched needs no snoop
      // when core 0 writes it.
      2: begin
        fetch(0, 64'h1000);
        lookup_valid = 1'b1; lookup_addr = 64'h1000;
        #1;
        if ((present & ~(NR_CORES'(1) << 0)) != 0) begin
          errors = errors + 1;
          $display("SF_IMPRECISE present=%b for a single-owner line", present);
        end
        @(negedge clk);
        lookup_valid = 1'b0;
      end
      // Delivered invalidation removes the sharer: precision recovers.
      3: begin
        fetch(0, 64'h2000);
        fetch(1, 64'h2000);
        deliver(0, 64'h2000);
        check_write(1, 64'h2000);
        check_precise(1, 64'h2000, '0);
      end
      // Same-cycle clear and refetch by the same core: the refetch wins.
      4: begin
        fetch(0, 64'h3000);
        fetch(1, 64'h3000);
        deliver(0, 64'h3000, 1'b0, 1'b1);
        check_write(1, 64'h3000);
      end
      // A displaced index whose sharers were all cleared must stay
      // displaced-safe: the forgotten line L comes back from one core but
      // another core still holds it.
      5: begin
        fetch(0, 64'h5000);
        fetch(1, 64'h5000);                  // L held by 0 and 1
        fetch(1, 64'h5000 + SET_STRIDE);     // M displaces L's entry
        deliver(1, 64'h5000 + SET_STRIDE);   // M's only sharer leaves
        fetch(1, 64'h5000);                  // L re-installed from core 1
        check_write(1, 64'h5000);            // core 0 still holds L
      end
      // An all_ways invalidation clears the core from every entry.
      6: begin
        fetch(0, 64'h6000);
        fetch(0, 64'h6040);
        fetch(1, 64'h6000);
        deliver(0, 64'h0, 1'b1);
        check_write(1, 64'h6000);
        check_precise(1, 64'h6000, '0);
        check_precise(1, 64'h6040, '0);
      end
      default: $fatal(1, "SF_SCENARIO");
    endcase

    if (negative) begin
      // Expected-failure convention, as in the L2/mux reviews: a negative trial
      // must FAIL with a distinct token. Exiting successfully here would make the
      // control depend on the simulator's $finish exit status, which is not the
      // property under test.
      if (errors == 0) $fatal(1, "SF_NEGATIVE_NOT_DETECTED");
      $fatal(1, "SF_NEGATIVE_CAUGHT %0d", errors);
    end
    if (errors != 0) $fatal(1, "SF_ERRORS %0d", errors);
    $display("SF_METRICS scenario=%0d", scenario);
    $display("RTL_REVIEW_PASS sf scenario=%0d", scenario);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "SF_TIMEOUT");
  end

endmodule
