// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_ooo_snoop_filter;
  parameter int NC = 3;
  parameter int NE = 8;
  localparam int CW = NC <= 1 ? 1 : $clog2(NC);
  logic clk = 0, rst_n = 0;
  logic alloc_valid = 0, lookup_valid = 0;
  logic [63:0] alloc_addr = 0, lookup_addr = 0;
  logic [CW-1:0] alloc_core = 0;
  logic alloc_ready, lookup_ready, result_valid, ready;
  logic [NC-1:0] present;
  logic [NC-1:0] held[4*NE];
  bit negative;

  g6lc_ooo_snoop_filter #(.NR_CORES(NC), .NR_ENTRIES(NE), .LINE_BYTES(16)) dut (
    .clk_i(clk), .rst_ni(rst_n), .alloc_valid_i(alloc_valid),
    .alloc_addr_i(alloc_addr), .alloc_core_i(alloc_core), .alloc_ready_o(alloc_ready),
    .lookup_valid_i(lookup_valid), .lookup_addr_i(lookup_addr),
    .lookup_ready_o(lookup_ready), .result_valid_o(result_valid),
    .present_o(present), .ready_o(ready)
  );

  task automatic tick;
    #2; clk = 1; #2; clk = 0; #2;
  endtask

  task automatic acquire(input int core, input int line_id);
    alloc_valid = 1;
    alloc_addr = 64'h1000 + 64'(line_id) * 16;
    alloc_core = CW'(core);
    #1;
    if (!alloc_ready) $fatal(1, "SIG_ALLOC_READY");
    tick();
    held[line_id][core] = 1;
    alloc_valid = 0;
  endtask

  task automatic query(input int line_id, input bit exact = 0);
    logic [NC-1:0] observed;
    lookup_valid = 1;
    lookup_addr = 64'h1000 + 64'(line_id) * 16;
    #1;
    if (!lookup_ready) $fatal(1, "SIG_LOOKUP_READY");
    tick();
    observed = negative ? '0 : present;
    if (!result_valid || (held[line_id] & ~observed) != '0)
      $fatal(1, "SIG_SHARER_LOST line=%0d expected=%b got=%b", line_id, held[line_id], observed);
    if (exact && observed != held[line_id]) $fatal(1, "SIG_PRECISION");
    lookup_valid = 0;
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    for (int pass = 0; pass < 2; pass++) begin
      rst_n = 0;
      alloc_valid = 0;
      lookup_valid = 0;
      foreach (held[i]) held[i] = '0;
      tick();
      rst_n = 1;
      for (int n = 0; n < NE; n++) begin
        #1;
        if (ready || alloc_ready || lookup_ready) $fatal(1, "SIG_INIT_EARLY");
        tick();
      end
      if (!ready) $fatal(1, "SIG_INIT_BOUND");
      query(0, 1);
      acquire(0, 0);
      query(0, 1);
      query(1, 1);
      acquire(0, NE);
      query(0, 1);
      query(NE, 1);
      alloc_valid = 1;
      alloc_addr = 64'h1010;
      alloc_core = CW'(NC-1);
      lookup_valid = 1;
      lookup_addr = 64'h1000;
      #1;
      if (alloc_ready || !lookup_ready) $fatal(1, "SIG_PORT_ARBITRATION");
      tick();
      lookup_valid = 0;
      #1;
      if (!alloc_ready) $fatal(1, "SIG_RETRY_READY");
      tick();
      held[1][NC-1] = 1;
      alloc_valid = 0;
      query(1, 1);
      for (int n = 0; n < 192; n++) begin
        acquire(n % NC, (n * 13 + 3) % (4 * NE));
        for (int line_id = 0; line_id < 4 * NE; line_id++) query(line_id);
      end
    end
    $display("RTL_REVIEW_PASS signature cores=%0d entries=%0d", NC, NE);
    $finish;
  end
endmodule
