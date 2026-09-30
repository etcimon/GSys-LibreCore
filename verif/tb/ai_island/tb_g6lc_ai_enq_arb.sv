// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Leaf for g6lc_ai_enq_arb: three cores hold ai.enq kicks against an island whose
// ready toggles; every kick is accepted exactly once with its own {qid, ptr},
// never two grants in a cycle, and no core starves while its neighbours kick
// continuously (round-robin). Mutation +define+G6LC_MUT_ENQ_ARB_FIXED (fixed
// priority) must fail the starvation check; +oracle_negative flips the verdict.
module tb_g6lc_ai_enq_arb;
  localparam int unsigned NC = 3;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [NC-1:0]        valid, gnt;
  logic [NC-1:0][7:0]   qid;
  logic [NC-1:0][31:0]  ticket;
  logic [NC-1:0][63:0]  ptr;
  logic                 v_o, ready;
  logic [7:0]           qid_o;
  logic [31:0]          ticket_o;
  logic [63:0]          ptr_o;

  g6lc_ai_enq_arb #(.NC(NC), .QidW(8), .AddrW(64)) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .valid_i(valid), .qid_i(qid), .ticket_i(ticket), .ptr_i(ptr), .gnt_o(gnt),
      .valid_o(v_o), .qid_o(qid_o), .ticket_o(ticket_o), .ptr_o(ptr_o), .ready_i(ready)
  );

  // Producer model: core c keeps kicking (new ptr per kick) while enabled[c];
  // a kick is complete when gnt[c] && ready at a posedge.
  bit enabled [NC];
  int unsigned accepted [NC];
  int unsigned kicks    [NC];
  int unsigned checks = 0;
  bit negative;

  always @(posedge clk) if (rst_n) begin
    // oracle on the offered kick
    if (v_o) begin
      int unsigned c; c = 0;
      for (int i = 0; i < NC; i++) if (gnt[i]) c = i;
      if (!valid[c]) $fatal(1, "GRANT_TO_IDLE core=%0d", c);
      if (qid_o !== qid[c] || ptr_o !== ptr[c] || ticket_o !== ticket[c]) $fatal(1, "MUX_MISMATCH core=%0d", c);
      checks++;
    end
    if ($countones(gnt) > 1) $fatal(1, "TWO_GRANTS");
    for (int i = 0; i < NC; i++) begin
      if (valid[i] && gnt[i] && ready) begin
        accepted[i]++;
        // next kick (or stop)
        if (enabled[i]) begin ptr[i] <= ptr[i] + 64; kicks[i]++; end
        else valid[i] <= 1'b0;
      end
    end
  end

  // island ready pattern: 2 on, 1 off
  int unsigned rc = 0;
  always @(posedge clk) begin rc <= rc + 1; ready <= (rc % 3) != 2; end

  task automatic tick; @(posedge clk); #1; endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    for (int i = 0; i < NC; i++) begin
      valid[i] = 0; qid[i] = 8'(i + 1); ticket[i] = 32'(100 * i); ptr[i] = 64'h8000_0000 + 64'h1000 * i;
      enabled[i] = 0; accepted[i] = 0; kicks[i] = 0;
    end
    ready = 1;
    repeat (2) tick(); rst_n = 1; repeat (2) tick();

    // S1: single producer -> wire-like service, one accept per ready cycle.
    enabled[1] = 1; valid[1] = 1; kicks[1] = 1;
    repeat (30) tick();
    enabled[1] = 0; while (valid[1]) tick();
    if (accepted[1] != kicks[1]) $fatal(1, "S1 accepted=%0d kicks=%0d", accepted[1], kicks[1]);
    if (accepted[1] < 15) $fatal(1, "S1 too few accepts %0d", accepted[1]);

    // S2: all three kick continuously for 300 cycles: fairness within 1 kick per
    // round and no starvation (each core gets >= 1/NC of accepts minus slack).
    for (int i = 0; i < NC; i++) begin accepted[i] = 0; kicks[i] = 1; enabled[i] = 1; valid[i] = 1; end
    repeat (300) tick();
    for (int i = 0; i < NC; i++) enabled[i] = 0;
    while (|valid) tick();
    begin
      int unsigned tot = 0, mn = 1 << 30, mx = 0;
      for (int i = 0; i < NC; i++) begin
        tot += accepted[i];
        if (accepted[i] < mn) mn = accepted[i];
        if (accepted[i] > mx) mx = accepted[i];
        if (accepted[i] != kicks[i]) $fatal(1, "S2 core %0d accepted=%0d kicks=%0d", i, accepted[i], kicks[i]);
      end
      if (mn == 0) $fatal(1, "STARVED core (min accepts 0 of %0d)", tot);
      if (mx - mn > 2) $fatal(1, "UNFAIR max=%0d min=%0d", mx, mn);
      $display("S2 accepts per core: %0d %0d %0d (total %0d)", accepted[0], accepted[1], accepted[2], tot);
    end

    // S3: cores 0 and 2 kick; core 1 idle -> never granted, others alternate.
    for (int i = 0; i < NC; i++) begin accepted[i] = 0; kicks[i] = 0; end
    enabled[0] = 1; enabled[2] = 1; valid[0] = 1; valid[2] = 1; kicks[0] = 1; kicks[2] = 1;
    repeat (60) tick();
    enabled[0] = 0; enabled[2] = 0; while (|valid) tick();
    if (accepted[1] != 0) $fatal(1, "S3 idle core granted");
    if (accepted[0] == 0 || accepted[2] == 0) $fatal(1, "S3 starvation");

    if (negative) $fatal(1, "ORACLE_NEGATIVE: forced failure to prove the verdict path");
    $display("PASS tb_g6lc_ai_enq_arb checks=%0d", checks);
    $finish;
  end
  initial begin repeat (5000) @(posedge clk); $fatal(1, "timeout"); end
endmodule
