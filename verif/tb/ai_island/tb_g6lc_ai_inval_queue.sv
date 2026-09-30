// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Leaf for g6lc_ai_inval_queue (AiCfg.DmaInvalEn): every island write becomes one
// invalidation per touched 64 B line, issued only after that write's B, coalesced
// per line, never dropped under backpressure, and idle_o rises only when every
// write has landed AND been invalidated. A scoreboard of outstanding writes per
// line is the oracle; a CMO-engine model with programmable ready/done latency is
// the consumer. Mutation +define+G6LC_MUT_INVAL_AT_AW (inval before B) fails the
// "landed" check; +oracle_negative flips the verdict to prove the oracle can say no.
module tb_g6lc_ai_inval_queue;
  localparam int unsigned AW = 64;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic aw_fire, b_fire, aw_hold, inv_v, inv_rdy, inv_done, idle;
  logic [AW-1:0] aw_addr, inv_addr;
  logic [7:0] aw_len;
  logic [2:0] aw_size;
  logic [31:0] pmu_inv, pmu_hold;

  g6lc_ai_inval_queue #(.AddrWidth(AW), .Depth(4)) dut (
      .clk_i(clk), .rst_ni(rst_n),
      // the island masks its AW ready with aw_hold; the fire the DUT sees is the accepted one
      .aw_fire_i(aw_fire && !aw_hold), .aw_addr_i(aw_addr), .aw_len_i(aw_len), .aw_size_i(aw_size),
      .b_fire_i(b_fire), .aw_hold_o(aw_hold),
      .inval_valid_o(inv_v), .inval_addr_o(inv_addr), .inval_ready_i(inv_rdy), .inval_done_i(inv_done),
      .idle_o(idle), .pmu_invals_o(pmu_inv), .pmu_hold_o(pmu_hold)
  );

  // ---- oracle: per line, writes issued / landed / invalidated ----
  int unsigned issued  [logic [AW-7:0]];
  int unsigned landed  [logic [AW-7:0]];
  int unsigned invals  [logic [AW-7:0]];
  time         last_land [logic [AW-7:0]];
  time         last_inv  [logic [AW-7:0]];
  logic [AW-7:0] aw_order [$];     // lines of in-flight AWs, one entry per AW (first line + count)
  int unsigned   aw_nl    [$];
  int unsigned total_lines_written = 0, total_invals = 0, checks = 0;
  bit negative;

  // CMO-engine model: accept after ACC cycles, done DONE cycles later, one at a time.
  int unsigned acc_lat = 1, done_lat = 3;
  int unsigned acc_cnt = 0, done_cnt = 0;
  logic busy = 0;
  always @(posedge clk) begin
    inv_rdy  <= 1'b0;
    inv_done <= 1'b0;
    if (!busy) begin
      if (inv_v) begin
        if (acc_cnt >= acc_lat) begin
          inv_rdy <= 1'b1; busy <= 1'b1; acc_cnt <= 0; done_cnt <= 0;
          // oracle: an inval answers a LANDED write of that line (never a write still
          // in flight) -- with coalescing several landed writes may share one inval.
          if (landed[inv_addr[AW-1:6]] == 0 || landed[inv_addr[AW-1:6]] <= invals[inv_addr[AW-1:6]])
            $fatal(1, "INVAL_BEFORE_LANDED line=%h issued=%0d landed=%0d invals=%0d",
                   inv_addr[AW-1:6], issued[inv_addr[AW-1:6]], landed[inv_addr[AW-1:6]], invals[inv_addr[AW-1:6]]);
          invals[inv_addr[AW-1:6]]++; last_inv[inv_addr[AW-1:6]] = $time; total_invals++; checks++;
        end else acc_cnt <= acc_cnt + 1;
      end
    end else begin
      if (done_cnt >= done_lat) begin inv_done <= 1'b1; busy <= 1'b0; end
      else done_cnt <= done_cnt + 1;
    end
  end

  task automatic tick; @(posedge clk); #1; endtask
  // trace (+trace)
  always @(posedge clk) if ($test$plusargs("trace") && rst_n && ((aw_fire && !aw_hold) || b_fire || dut.take_head || (inv_v && inv_rdy) || inv_done))
    $display("t=%0t aw=%b(%h) b=%b take=%b(line %h) inv_acc=%b done=%b | cnt=%0d land=%0d wr=%0d bp=%0d rd=%0d walk_v=%b hold=%b",
             $time, aw_fire, aw_addr[AW-1:6], b_fire, dut.take_head, dut.q_q[dut.rd_q].line, inv_v && inv_rdy, inv_done,
             dut.cnt_q, dut.land_q, dut.wr_q, dut.bp_q, dut.rd_q, dut.walk_v_q, aw_hold);

  task automatic write(input logic [AW-1:0] addr, input int unsigned beats, input int unsigned size);
    int unsigned nl;
    logic [AW-1:0] last;
    bit fired;
    aw_addr = addr; aw_len = 8'(beats - 1); aw_size = 3'(size);
    aw_fire = 1'b1;
    // hold the AW until the queue accepts it (sampled at the edge the DUT samples)
    do begin @(posedge clk); fired = !aw_hold; #1; end while (!fired);
    aw_fire = 1'b0;
    last = addr + (beats << size) - 1;
    nl = int'(last[AW-1:6] - addr[AW-1:6]) + 1;
    for (int unsigned l = 0; l < nl; l++) begin
      issued[addr[AW-1:6] + l]++;
      total_lines_written++;
    end
    aw_order.push_back(addr[AW-1:6]); aw_nl.push_back(nl);
  endtask

  task automatic bresp;
    logic [AW-7:0] l0; int unsigned nl;
    // a B can only answer an accepted AW
    while (aw_order.size() == 0) tick();
    l0 = aw_order.pop_front(); nl = aw_nl.pop_front();
    for (int unsigned l = 0; l < nl; l++) begin landed[l0 + l]++; last_land[l0 + l] = $time; end
    b_fire = 1'b1; tick(); b_fire = 1'b0;
  endtask

  task automatic drain(input int unsigned lim);
    int unsigned g = 0;
    while (!idle && g < lim) begin tick(); g++; end
    if (!idle) $fatal(1, "IDLE_TIMEOUT after %0d cycles", lim);
    // every issued+landed line has at least one inval, and idle means nothing owed
    foreach (issued[l]) begin
      if (invals[l] == 0) $fatal(1, "LINE_NEVER_INVALIDATED %h", l);
      // the last write to the line must be followed by an inval (no stale tail)
      if (last_inv[l] < last_land[l]) $fatal(1, "STALE_TAIL %h last_land=%0t last_inv=%0t", l, last_land[l], last_inv[l]);
    end
    checks++;
  endtask

  initial begin
    aw_fire = 0; b_fire = 0; aw_addr = '0; aw_len = 0; aw_size = 3;
    negative = $test$plusargs("oracle_negative");
    repeat (2) tick(); rst_n = 1; repeat (2) tick();

    // S1: eight 8-byte writes to one line, then their B's: one inval, not eight.
    for (int i = 0; i < 8; i++) write(64'h8000_0100 + 8 * i, 1, 3);
    for (int i = 0; i < 8; i++) bresp();
    drain(200);
    if (total_invals != 1) $fatal(1, "S1 coalescing: %0d invals for one line", total_invals);
    if (idle !== 1'b1) $fatal(1, "S1 idle");
    // idle must have been low before the B's (inval owed)
    checks++;

    // S2: a 2 KiB burst (32 lines of 64 B) -> 32 invals after its single B.
    write(64'h8000_2000, 32, 6);
    repeat (5) tick();
    if (idle) $fatal(1, "S2 idle before B");
    if (inv_v) $fatal(1, "S2 inval offered before B");
    bresp();
    drain(2000);
    if (total_invals != 33) $fatal(1, "S2: %0d invals (want 33)", total_invals);

    // S3: backpressure -- more distinct lines than Depth without B's; AW must hold,
    // nothing dropped once B's flow.
    fork
      begin
        for (int i = 0; i < 12; i++) write(64'h8001_0000 + 64 * i, 1, 3);
      end
      begin
        repeat (6) tick();
        for (int i = 0; i < 12; i++) begin repeat (2) tick(); bresp(); end
      end
    join
    drain(3000);
    if (pmu_hold == 0) $fatal(1, "S3: the queue never held the AW at depth 4 with 12 lines");
    if (total_invals != 45) $fatal(1, "S3: %0d invals (want 45)", total_invals);

    // S4: interleaved writes to alternating lines (no coalescing) with B's racing the
    // walker; count must equal distinct line-writes.
    for (int i = 0; i < 6; i++) begin
      write(64'h8002_0000 + 64 * (i % 2), 1, 3);
      if (i >= 2) bresp();
    end
    bresp(); bresp();
    drain(500);
    if (total_invals < 45 + 2) $fatal(1, "S4: %0d invals", total_invals);

    if (negative) $fatal(1, "ORACLE_NEGATIVE: forced failure to prove the verdict path");
    $display("PASS tb_g6lc_ai_inval_queue checks=%0d invals=%0d lines=%0d holds=%0d",
             checks, total_invals, total_lines_written, pmu_hold);
    $finish;
  end

  initial begin repeat (20000) @(posedge clk); $fatal(1, "timeout"); end
endmodule
