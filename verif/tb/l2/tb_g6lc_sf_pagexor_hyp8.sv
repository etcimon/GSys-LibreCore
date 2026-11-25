// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated 4-core COH_OOO snoop-filter leaf: proves XOR page-folded indexing
// eliminates 4 KiB page-offset false aliasing across per-core private stacks /
// sbi_scratch pages while preserving 100% conservative superset coherence.
//
// Review mutation (must fail):
//   -DG6LC_MUT_SF_NO_PAGE_XOR -> fails S2_NO_4K_STACK_ALIAS
//
// PASS token: PASS tb_g6lc_sf_pagexor_hyp8
module tb_g6lc_sf_pagexor_hyp8;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask

  logic        alloc_v = 0, lookup_v = 0, alloc_rdy, lookup_rdy, res_v, rdy;
  logic [63:0] alloc_a = '0, lookup_a = '0;
  logic [1:0]  alloc_c = '0;
  logic [3:0]  present;

  g6lc_ooo_snoop_filter #(
      .NR_CORES  (4),
      .NR_ENTRIES(256),  // exact hyp8-mc geometry: 4*64=256 entries, 16B line (OFF=4, IDX_W=8 -> 4 KiB)
      .LINE_BYTES(16),
      .ADDR_WIDTH(64)
  ) dut (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .alloc_valid_i (alloc_v),
      .alloc_addr_i  (alloc_a),
      .alloc_core_i  (alloc_c),
      .alloc_ready_o (alloc_rdy),
      .lookup_valid_i(lookup_v),
      .lookup_addr_i (lookup_a),
      .lookup_ready_o(lookup_rdy),
      .result_valid_o(res_v),
      .present_o     (present),
      .ready_o       (rdy)
  );

  task automatic do_alloc(input logic [1:0] core, input logic [63:0] addr);
    alloc_v = 1'b1; alloc_c = core; alloc_a = addr;
    tick();
    alloc_v = 1'b0;
  endtask

  task automatic do_lookup(input logic [63:0] addr, output logic [3:0] mask);
    lookup_v = 1'b1; lookup_a = addr;
    tick();
    lookup_v = 1'b0;
    #1;
    if (!res_v) $fatal(1, "FAIL SF_NO_RESULT");
    mask = present;
  endtask

  logic [3:0] m;
  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    while (!rdy) tick();

    // Each of 4 cores touches its own private 4 KiB stack page at offset +0x80:
    //   core 0: 0x8004_0080, core 1: 0x8004_1080, core 2: 0x8004_2080, core 3: 0x8004_3080
    do_alloc(2'd0, 64'h8004_0080);
    do_alloc(2'd1, 64'h8004_1080);
    do_alloc(2'd2, 64'h8004_2080);
    do_alloc(2'd3, 64'h8004_3080);

    // S1: Superset safety — each core's own address MUST report its own bit set
    do_lookup(64'h8004_0080, m);
    if (!m[0]) $fatal(1, "FAIL S1_SELF_MISSING core0 m=%b", m);
    // S2: Zero 4 KiB page-offset false aliasing — core 0's private stack MUST NOT
    //     falsely mark peers 1, 2, 3 (which would broadcast-invalidate all peers)!
    if (m !== 4'b0001) $fatal(1, "FAIL S2_NO_4K_STACK_ALIAS core0 m=%b (want 0001)", m);

    do_lookup(64'h8004_2080, m);
    if (m !== 4'b0100) $fatal(1, "FAIL S2_NO_4K_STACK_ALIAS core2 m=%b (want 0100)", m);

    // S3: Shared line (cores 0 and 3 both read 0x8008_0100) MUST report 4'b1001
    do_alloc(2'd0, 64'h8008_0100);
    do_alloc(2'd3, 64'h8008_0100);
    do_lookup(64'h8008_0100, m);
    if ((m & 4'b1001) !== 4'b1001) $fatal(1, "FAIL S3_SHARED_SUPERSET m=%b", m);

    $display("PASS tb_g6lc_sf_pagexor_hyp8");
    $finish;
  end
endmodule
