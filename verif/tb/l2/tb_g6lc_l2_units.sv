// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Leaf coverage for g6lc_l2_mshr (full/merge/waiter) and g6lc_l2_data bank
// conflict. The serialized L2 top never reaches these; zero top-level counts
// are not passes. This bench instantiates the leaves directly.

`timescale 1ns/1ps

module tb_g6lc_l2_units;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  localparam int unsigned DEPTH = 4;
  localparam int unsigned NW    = 2;
  localparam int unsigned AW    = 64;
  localparam int unsigned IDW   = 4;

  logic alloc, alloc_ready, alloc_merged, flush;
  logic [AW-1:0] alloc_line;
  logic [IDW-1:0] alloc_id;
  logic [$clog2(DEPTH)-1:0] alloc_idx;
  logic complete, waiter_valid, waiter_pop, empty, full, merge_full;
  logic [IDW-1:0] complete_id, waiter_id;
  logic [$clog2(DEPTH)-1:0] complete_idx;
  logic [$clog2(DEPTH+1)-1:0] count;
  logic lookup_hit_nc;
  logic [$clog2(DEPTH)-1:0] lookup_idx_nc;

  g6lc_l2_mshr #(
      .DEPTH(DEPTH), .ADDR_WIDTH(AW), .ID_WIDTH(IDW), .MAX_WAITERS(NW)
  ) i_mshr (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .alloc_i(alloc), .alloc_line_addr_i(alloc_line), .alloc_id_i(alloc_id),
      .alloc_is_write_i(1'b0), .alloc_ready_o(alloc_ready),
      .alloc_merged_o(alloc_merged), .alloc_idx_o(alloc_idx),
      .lookup_line_addr_i(alloc_line), .lookup_hit_o(lookup_hit_nc),
      .lookup_idx_o(lookup_idx_nc),
      .complete_i(complete), .complete_idx_i(complete_idx),
      .complete_id_o(complete_id),
      .waiter_valid_o(waiter_valid), .waiter_id_o(waiter_id),
      .waiter_pop_i(waiter_pop),
      .empty_o(empty), .full_o(full), .merge_full_o(merge_full), .count_o(count)
  );

  localparam int unsigned SETS = 8;
  localparam int unsigned WAYS = 4;
  localparam int unsigned BANKS = 2;
  localparam int unsigned LW = 64;
  logic a_req, b_req, conflict;
  logic [2:0] a_idx, b_idx;
  logic [1:0] a_way, b_way;
  logic [LW-1:0] a_rdata_nc, b_rdata_nc;

  g6lc_l2_data #(
      .NUM_SETS(SETS), .SET_ASSOC(WAYS), .LINE_WIDTH(LW),
      .NUM_BANKS(BANKS), .IDX_WIDTH(3)
  ) i_data (
      .clk_i(clk), .rst_ni(rst_n),
      .a_req_i(a_req), .a_we_i(1'b0), .a_index_i(a_idx), .a_way_i(a_way),
      .a_wdata_i('0), .a_be_i('0), .a_rdata_o(a_rdata_nc),
      .b_req_i(b_req), .b_we_i(1'b1), .b_index_i(b_idx), .b_way_i(b_way),
      .b_wdata_i('1), .b_be_i('1), .b_rdata_o(b_rdata_nc),
      .bank_conflict_o(conflict)
  );

  // Same handshake as tb_g6lc_l2 axi_read: drive at negedge, sample comb #1
  // later, then wait the next negedge so the capturing posedge has passed.
  task automatic do_alloc(input logic [AW-1:0] line, input logic [IDW-1:0] id,
                          input bit expect_merge, input bit expect_ready);
    @(negedge clk);
    alloc = 1; alloc_line = line; alloc_id = id;
    #1;
    if (alloc_ready !== expect_ready)
      $fatal(1, "alloc_ready line=%h ready=%b exp=%b nwait0=%0d count=%0d",
             line, alloc_ready, expect_ready, i_mshr.mem_q[0].nwait, count);
    if (expect_ready && alloc_merged !== expect_merge)
      $fatal(1, "merge mismatch line=%h got=%b exp=%b nwait0=%0d mf=%b",
             line, alloc_merged, expect_merge, i_mshr.mem_q[0].nwait, merge_full);
    @(negedge clk);
    alloc = 0;
  endtask

  bit seen_full, seen_merge, seen_merge_full, seen_waiter, seen_conflict, seen_noconflict;

  initial begin
    alloc = 0; flush = 0; complete = 0; waiter_pop = 0; complete_idx = '0;
    a_req = 0; b_req = 0; a_idx = 0; b_idx = 0; a_way = 0; b_way = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    if (!empty || full || count != 0) $fatal(1, "reset occupancy");

    do_alloc(64'h100, 4'h1, 0, 1);
    if (count != 1) $fatal(1, "primary did not occupy a slot");
    do_alloc(64'h100, 4'h2, 1, 1);
    if (count != 1) $fatal(1, "merge consumed a slot");
    seen_merge = 1;
    do_alloc(64'h100, 4'h3, 1, 1);
    #1;
    if (!merge_full || count != 1)
      $fatal(1, "waiter slots not exhausted mf=%b count=%0d nwait0=%0d",
             merge_full, count, i_mshr.mem_q[0].nwait);
    seen_merge_full = 1;

    do_alloc(64'h200, 4'h5, 0, 1);
    do_alloc(64'h300, 4'h6, 0, 1);
    do_alloc(64'h400, 4'h7, 0, 1);
    if (!full || count != DEPTH) $fatal(1, "MSHR not full after DEPTH distinct lines");
    seen_full = 1;
    do_alloc(64'h500, 4'h8, 0, 0);
    if (count != DEPTH) $fatal(1, "alloc while full took a slot");

    complete_idx = 0;
    #1;
    if (!waiter_valid) $fatal(1, "waiters not visible after merge");
    @(negedge clk); waiter_pop = 1; @(negedge clk); waiter_pop = 0;
    @(negedge clk); waiter_pop = 1; @(negedge clk); waiter_pop = 0;
    @(negedge clk); complete = 1; @(negedge clk); complete = 0;
    #1;
    if (full || count != DEPTH - 1) $fatal(1, "complete did not free the merged line count=%0d", count);
    seen_waiter = 1;

    @(negedge clk); flush = 1; @(negedge clk); flush = 0;
    #1;
    if (!empty || count != 0) $fatal(1, "flush occupancy");

    // Banks: word = set*ways+way; banks=2 so way 0 and way 2 share a bank.
    @(negedge clk);
    a_req = 1; b_req = 1; a_idx = 0; a_way = 0; b_idx = 0; b_way = 2;
    #1;
    if (!conflict) $fatal(1, "same-bank A/B must conflict");
    seen_conflict = 1;
    b_way = 1;
    #1;
    if (conflict) $fatal(1, "different-bank A/B must not conflict");
    seen_noconflict = 1;
    a_req = 0; b_req = 0;

    if (!seen_full || !seen_merge || !seen_merge_full || !seen_waiter ||
        !seen_conflict || !seen_noconflict)
      $fatal(1, "incomplete unit coverage");
    $display("[L2UNIT] mshr_full=1 merge=1 merge_full=1 waiter=1 bank_conflict=1 bank_ok=1");
    $display("[L2UNIT] RESULT pass");
    $finish;
  end

  initial begin
    #1ms;
    $display("[L2UNIT] RESULT fail watchdog");
    $fatal(1);
  end
endmodule
