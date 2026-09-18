// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Unit bench for g6lc_inval_retain — the external-invalidation retention on the
// HPDCACHE read-response seam.
//
// This exists because the overflow path is UNREACHABLE from software. Every
// full-core test reported `backpressured=0`, including one written specifically to
// provoke it (an observer streaming misses to keep the response channel busy while
// the other hart wrote four lines back-to-back). The upstream inval bus buffers per
// core, so the retention only ever sees a drip. An end-to-end pass therefore cannot
// distinguish a retention that fills and drains correctly from one that never
// fills — which is exactly the kind of untested path that fails first in silicon.
//
// Here the producer and the response channel are driven directly, so the slot can
// be held full for as long as we like.
//
// Scenarios:
//   0  overflow + conservation: offer an invalidation every cycle while the
//      response channel is busy, then drain. Every accepted invalidation must come
//      out exactly once, in order, and `backpressured` must be non-zero — if it is
//      zero the bench itself failed to create the condition and says so.
//   1  a real response always wins: hold resp_valid high throughout; inject must
//      never assert (contract 3 — piggybacking would drop a refill downstream).
//   2  drain under intermittent readiness: resp_ready toggles, so injection has to
//      wait for the consumer without losing or duplicating an entry.
//
// +oracle_negative perturbs the OBSERVED stream (drops one accepted invalidation
// from the expectation) so the conservation checker must fire; a control that
// merely asks for a non-existent error proves nothing.

`timescale 1ns/1ps

module tb_g6lc_inval_retain;

  //  Overridable (-GDEPTH=N) so the depth the design actually SHIPS can be
  //  qualified, not just a friendlier one: cva6_hpdcache_subsystem instantiates
  //  DEPTH=1, while DEPTH=2 additionally exercises the pointer wrap and ordering.
  parameter int unsigned DEPTH = 2;
  typedef logic [15:0] nline_t;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic   inval_valid, inval_ready;
  nline_t inval_nline;
  logic   resp_valid, resp_ready;
  logic   inject;
  nline_t inject_nline;
  logic   evt_injected, evt_backpressured;

  int unsigned errors = 0;
  int unsigned accepted = 0, emitted = 0, bp_cycles = 0;
  bit negative;
  int scenario;

  //  Expected order of accepted invalidations.
  nline_t expect_q[$];

  g6lc_inval_retain #(
      .nline_t(nline_t),
      .DEPTH  (DEPTH)
  ) dut (
      .clk_i (clk),
      .rst_ni(rst_n),
      .inval_valid_i(inval_valid),
      .inval_nline_i(inval_nline),
      .inval_ready_o(inval_ready),
      .resp_valid_i (resp_valid),
      .resp_ready_i (resp_ready),
      .inject_o     (inject),
      .inject_nline_o(inject_nline),
      .evt_injected_o     (evt_injected),
      .evt_backpressured_o(evt_backpressured)
  );

  //  Contract 1 (conservation + order) and contract 3 (real response wins).
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (inval_valid && inval_ready) begin
        accepted++;
        //  The negative control drops the FIRST accepted entry from the expectation,
        //  so the checker below must notice the surplus emission. It has to be the
        //  first and not the second: at DEPTH=1 -- the depth the design actually
        //  ships -- only one entry is ever accepted in this scenario, so perturbing
        //  the second left the control inert exactly where it matters most
        //  (measured: negative_caught=0 at DEPTH=1, 1 at DEPTH=2 and 4).
        if (!(negative && accepted == 1)) expect_q.push_back(inval_nline);
      end
      if (evt_backpressured) bp_cycles++;
      if (inject && resp_valid) begin
        errors++;
        $display("RETAIN_INJECT_OVER_RESP");
      end
      if (evt_injected) begin
        emitted++;
        if (expect_q.size() == 0) begin
          errors++;
          $display("RETAIN_SURPLUS nline=%h", inject_nline);
        end else begin
          nline_t want;
          want = expect_q.pop_front();
          if (inject_nline !== want) begin
            errors++;
            $display("RETAIN_ORDER got=%h want=%h", inject_nline, want);
          end
        end
      end
    end
  end

  task automatic reset;
    rst_n = 0;
    inval_valid = 0;
    inval_nline = '0;
    resp_valid = 0;
    resp_ready = 1;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    scenario = 0;
    void'($value$plusargs("scenario=%d", scenario));
    reset();

    case (scenario)
      //  Overflow + conservation.
      0: begin
        //  Fill: offer every cycle with the channel busy so nothing can drain.
        resp_valid = 1;
        resp_ready = 1;
        for (int i = 0; i < 12; i++) begin
          inval_valid = 1;
          inval_nline = nline_t'(16'h1000 + i);
          @(posedge clk);
        end
        inval_valid = 0;
        //  Drain: free the channel.
        resp_valid = 0;
        repeat (40) @(posedge clk);

        if (bp_cycles == 0) begin
          errors++;
          $display("RETAIN_NO_BACKPRESSURE bench failed to fill the slot");
        end
        if (emitted != accepted) begin
          errors++;
          $display("RETAIN_LOSS accepted=%0d emitted=%0d", accepted, emitted);
        end
        if (accepted != DEPTH) begin
          errors++;
          $display("RETAIN_ACCEPT_COUNT accepted=%0d depth=%0d", accepted, DEPTH);
        end
      end

      //  A real response always wins the channel.
      1: begin
        resp_valid = 1;
        resp_ready = 1;
        for (int i = 0; i < 6; i++) begin
          inval_valid = 1;
          inval_nline = nline_t'(16'h2000 + i);
          @(posedge clk);
        end
        inval_valid = 0;
        repeat (20) @(posedge clk);
        if (emitted != 0) begin
          errors++;
          $display("RETAIN_INJECTED_WHILE_BUSY emitted=%0d", emitted);
        end
      end

      //  Drain under intermittent consumer readiness.
      2: begin
        resp_valid = 0;
        resp_ready = 0;
        for (int i = 0; i < 8; i++) begin
          inval_valid = 1;
          inval_nline = nline_t'(16'h3000 + i);
          @(posedge clk);
          resp_ready = ~resp_ready;
        end
        inval_valid = 0;
        resp_ready = 1;
        repeat (40) @(posedge clk);
        if (emitted != accepted) begin
          errors++;
          $display("RETAIN_LOSS_INTERMITTENT accepted=%0d emitted=%0d", accepted, emitted);
        end
      end
      default: $fatal(1, "RETAIN_SCENARIO");
    endcase

    if (negative) begin
      if (errors == 0) $fatal(1, "RETAIN_NEGATIVE_NOT_DETECTED");
      $fatal(1, "RETAIN_NEGATIVE_CAUGHT %0d", errors);
    end
    if (errors != 0) $fatal(1, "RETAIN_ERRORS %0d", errors);
    $display("RETAIN_METRICS scenario=%0d accepted=%0d emitted=%0d backpressured=%0d",
             scenario, accepted, emitted, bp_cycles);
    $display("RTL_REVIEW_PASS retain scenario=%0d", scenario);
    $finish;
  end

endmodule
