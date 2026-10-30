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
  logic [DEPTH-1:0] id_match_nc;
  logic waiter_meta_nc;

  g6lc_l2_mshr #(
      .DEPTH(DEPTH), .ADDR_WIDTH(AW), .ID_WIDTH(IDW), .MAX_WAITERS(NW)
  ) i_mshr (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .alloc_i(alloc), .alloc_line_addr_i(alloc_line), .alloc_id_i(alloc_id),
      .alloc_is_write_i(1'b0), .alloc_ready_o(alloc_ready),
      .merge_block_i('0), .alloc_meta_i('0),
      .alloc_merged_o(alloc_merged), .alloc_idx_o(alloc_idx),
      .lookup_line_addr_i(alloc_line), .lookup_hit_o(lookup_hit_nc),
      .lookup_idx_o(lookup_idx_nc), .id_match_o(id_match_nc),
      .complete_i(complete), .complete_idx_i(complete_idx),
      .complete_id_o(complete_id),
      .waiter_valid_o(waiter_valid), .waiter_id_o(waiter_id),
      .waiter_meta_o(waiter_meta_nc), .waiter_pop_i(waiter_pop),
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

// ---------------- r98 MSHR miter: candidate vs frozen reference -------------
module tb_g6lc_hyp8_mshr_case #(
    parameter int unsigned D   = 4,
    parameter int unsigned NWP = 1
);
  localparam int unsigned AW   = 64;
  localparam int unsigned IDW  = 4;
  localparam int unsigned META = 17;
  localparam int unsigned IDX  = (D <= 1) ? 1 : $clog2(D);
  localparam int unsigned CW   = $clog2(D + 1);

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int checked = 0;
  int unsigned cyc = 0;
  task check(input logic ok, input string tag);
    checked++;
    if (ok !== 1'b1) begin
      $display("FAIL %s D=%0d NW=%0d cyc=%0d", tag, D, NWP, cyc);
      $display("  stim a=%b al=%h id=%h m=%h w=%b mb=%b ll=%h c=%b ix=%0d p=%b f=%b",
               alloc, alloc_line, alloc_id, alloc_meta, alloc_w, mblock,
               lookup_line, complete, cidx, pop, flush);
      $display("  d rd=%b mg=%b ax=%0d hit=%b lx=%0d idm=%b wv=%b f=%b mf=%b c=%0d",
               d_ready,d_merged,d_aidx,d_hit,d_lidx,d_idm,d_wv,
               d_full,d_mfull,int'(d_cnt));
      $display("  r rd=%b mg=%b ax=%0d hit=%b lx=%0d idm=%b wv=%b f=%b mf=%b c=%0d",
               r_ready,r_merged,r_aidx,r_hit,r_lidx,r_idm,r_wv,
               r_full,r_mfull,int'(r_cnt));
      $display("  dut.mem_q=%h ref.mem_q=%h", dut.mem_q, reference.mem_q);
      $fatal(1, "tb_g6lc_hyp8_mshr");
    end
  endtask

  logic                    flush, alloc, complete, pop;
  logic [AW-1:0]           alloc_line, lookup_line;
  logic [IDW-1:0]         alloc_id;
  logic [META-1:0]        alloc_meta;
  logic                   alloc_w;
  logic [D-1:0]           mblock;
  logic [IDX-1:0]         cidx;

  logic d_ready, d_merged, d_hit, d_wv, d_empty, d_full, d_mfull;
  logic [IDX-1:0] d_aidx, d_lidx;
  logic [IDW-1:0] d_cid, d_wid;
  logic [META-1:0] d_wmeta;
  logic [D-1:0] d_idm;
  logic [CW-1:0] d_cnt;
  logic r_ready, r_merged, r_hit, r_wv, r_empty, r_full, r_mfull;
  logic [IDX-1:0] r_aidx, r_lidx;
  logic [IDW-1:0] r_cid, r_wid;
  logic [META-1:0] r_wmeta;
  logic [D-1:0] r_idm;
  logic [CW-1:0] r_cnt;

  g6lc_l2_mshr #(.DEPTH(D), .MAX_WAITERS(NWP), .ADDR_WIDTH(AW),
    .ID_WIDTH(IDW), .META_WIDTH(META)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .alloc_i(alloc), .alloc_line_addr_i(alloc_line),
    .alloc_id_i(alloc_id), .alloc_meta_i(alloc_meta),
    .alloc_is_write_i(alloc_w), .merge_block_i(mblock),
    .alloc_ready_o(d_ready), .alloc_merged_o(d_merged), .alloc_idx_o(d_aidx),
    .lookup_line_addr_i(lookup_line), .lookup_hit_o(d_hit),
    .lookup_idx_o(d_lidx), .id_match_o(d_idm),
    .complete_i(complete), .complete_idx_i(cidx), .complete_id_o(d_cid),
    .waiter_valid_o(d_wv), .waiter_id_o(d_wid), .waiter_meta_o(d_wmeta),
    .waiter_pop_i(pop),
    .empty_o(d_empty), .full_o(d_full), .merge_full_o(d_mfull),
    .count_o(d_cnt));

  g6lc_l2_mshr_reference #(.DEPTH(D), .MAX_WAITERS(NWP), .ADDR_WIDTH(AW),
    .ID_WIDTH(IDW), .META_WIDTH(META)) reference (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .alloc_i(alloc), .alloc_line_addr_i(alloc_line),
    .alloc_id_i(alloc_id), .alloc_meta_i(alloc_meta),
    .alloc_is_write_i(alloc_w), .merge_block_i(mblock),
    .alloc_ready_o(r_ready), .alloc_merged_o(r_merged), .alloc_idx_o(r_aidx),
    .lookup_line_addr_i(lookup_line), .lookup_hit_o(r_hit),
    .lookup_idx_o(r_lidx), .id_match_o(r_idm),
    .complete_i(complete), .complete_idx_i(cidx), .complete_id_o(r_cid),
    .waiter_valid_o(r_wv), .waiter_id_o(r_wid), .waiter_meta_o(r_wmeta),
    .waiter_pop_i(pop),
    .empty_o(r_empty), .full_o(r_full), .merge_full_o(r_mfull),
    .count_o(r_cnt));

  logic [D-1:0] entry_eq, entry_valid;
  logic [CW:0]  vc_sum;
  for (genvar e = 0; e < D; e++) begin : gen_miter
    assign entry_eq[e]    = (dut.mem_q[e] === reference.mem_q[e]);
    assign entry_valid[e] = dut.mem_q[e].valid;
  end
  always_comb begin
    vc_sum = '0;
    for (int e = 0; e < D; e++)
      vc_sum = vc_sum + (CW+1)'(entry_valid[e]);
  end

  typedef struct packed {
    logic alloc; logic [AW-1:0] aline; logic [IDW-1:0] aid;
    logic [META-1:0] ameta; logic aw; logic [D-1:0] mblk;
    logic [AW-1:0] lline; logic cpl; logic [IDX-1:0] cix; logic pp; logic fl;
  } stim_t;

  task step(input stim_t s);
    @(negedge clk);
    flush = s.fl; alloc = s.alloc; alloc_line = s.aline; alloc_id = s.aid;
    alloc_meta = s.ameta; alloc_w = s.aw; mblock = s.mblk;
    lookup_line = s.lline; complete = s.cpl; cidx = s.cix; pop = s.pp;
    #1;
    check(d_ready === r_ready && d_merged === r_merged && d_aidx === r_aidx &&
          d_hit === r_hit && d_lidx === r_lidx && d_idm === r_idm &&
          d_cid === r_cid && d_wv === r_wv && d_wid === r_wid &&
          d_wmeta === r_wmeta && d_empty === r_empty && d_full === r_full &&
          d_mfull === r_mfull && d_cnt === r_cnt, "comb_outputs");
    pre_ready = d_ready; pre_merged = d_merged; pre_full = d_full;
    pre_aidx  = d_aidx;
    @(posedge clk); #1;
    check(&entry_eq, "mem_q");
    check(dut.count_q === reference.count_q, "count_q");
    // independent invariants (constant-index field reads)
    check(int'(dut.count_q) == int'(vc_sum), "count_eq_valid");
    for (int e = 0; e < D; e++)
      if (entry_valid[e])
        check(int'(d_nw[e]) <= int'(NWP), "nwait_bound");
    cyc++;
  endtask

  task stim(input logic a, input logic [AW-1:0] al, input logic [IDW-1:0] i,
            input logic [META-1:0] m, input logic w, input logic [D-1:0] mb,
            input logic [AW-1:0] ll, input logic c, input logic [IDX-1:0] x,
            input logic p, input logic f);
    stim_t s;
    s = '{alloc:a, aline:al, aid:i, ameta:m, aw:w, mblk:mb,
          lline:ll, cpl:c, cix:x, pp:p, fl:f};
    step(s);
  endtask

  logic [D-1:0] d_val; logic [D-1:0][IDW-1:0] d_id;
  logic [D-1:0][$bits(dut.mem_q[0].nwait)-1:0] d_nw;
  for (genvar e = 0; e < D; e++) begin : gen_shadow
    assign d_val[e] = dut.mem_q[e].valid;
    assign d_id[e]  = dut.mem_q[e].id;
    assign d_nw[e]  = dut.mem_q[e].nwait;
  end
  logic pre_ready, pre_merged, pre_full;
  logic [IDX-1:0] pre_aidx;
  logic done = 1'b0;
  initial begin
    int unsigned seed = 32'h1984A5C3 ^ 32'(D*16 + NWP);
    logic [AW-1:0] line;
    flush = 0; alloc = 0; alloc_line = '0; alloc_id = '0; alloc_meta = '0;
    alloc_w = 0; mblock = '0; lookup_line = '0; complete = 0; cidx = '0; pop = 0;
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    // 1: alloc + attach waiters
    stim(1, 64'h100, 4'd1, '0, 0, '0, '0, 0, '0, 0, 0);
    check(d_cnt == 1 && d_id[0] == 4'd1, "alloc_primary");
    for (int w = 1; w <= NWP; w++) begin
      stim(1, 64'h100, IDW'(1+w), META'(17'h100 + 17'(w)), 0, '0, '0, 0, '0, 0, 0);
      check(d_id[0] == 4'd1 && int'(d_cnt) == 1 &&
            int'(d_nw[0]) == w, "attach_nwait");
      check(dut.mem_q[0].waiters[w-1] == IDW'(1+w) &&
            dut.mem_q[0].wmeta[w-1] == META'(17'h100) + META'(w), "attach_fifo");
    end
    // 2: full queue rejects another attach
    stim(1, 64'h100, 4'd9, '0, 0, '0, '0, 0, '0, 0, 0);
    check(!d_ready && d_mfull, "merge_full");
    // 3: pop + attach concurrently
    stim(1, 64'h100, 4'd14, 17'h12345, 0, '0, '0, 0, IDX'(0), 1, 0);
    check(int'(dut.mem_q[0].nwait) == NWP, "popattach_nwait");
    check(dut.mem_q[0].waiters[NWP-1] == 4'd14 &&
          dut.mem_q[0].wmeta[NWP-1] == 17'h12345, "popattach_tail");
    if (NWP > 1)
      check(dut.mem_q[0].waiters[0] == 4'd3 &&
            dut.mem_q[0].wmeta[0] == 17'h102, "popattach_head");
    else
      check(dut.mem_q[0].waiters[0] == 4'd14 &&
            dut.mem_q[0].wmeta[0] == 17'h12345, "popattach_head");
    // 4: drain to one waiter, then pop+attach+complete
    for (int w = NWP; w > 1; w--)
      stim(0, '0, '0, '0, 0, '0, '0, 0, IDX'(0), 1, 0);
    stim(1, 64'h100, 4'd15, 17'h1ABCD, 0, '0, '0, 1, IDX'(0), 1, 0);
    check(d_val[0] && d_cnt == 1 &&
          dut.mem_q[0].waiters[0] == 4'd15 &&
          dut.mem_q[0].wmeta[0] == 17'h1ABCD &&
          d_id[0] == 4'd1 && d_nw[0] == 1, "pattachcpl");
    // 5: pop+complete -> free
    stim(0, '0, '0, '0, 0, '0, '0, 1, IDX'(0), 1, 0);
    check(!d_val[0] && d_cnt == 0, "free_entry");
    // 6: alloc+complete idx on invalid row stays allocated
    stim(1, 64'h100, 4'd1, '0, 0, '0, '0, 1, IDX'(0), 0, 0);
    check(d_val[0] && d_cnt == 1, "alloc_no_free");
    // 7: alloc B while completing occupied row0
    stim(1, 64'h200, 4'd2, '0, 0, '0, '0, 1, IDX'(0), 0, 0);
    check(pre_ready && !pre_merged && pre_aidx == IDX'(1), "alloc_no_credit");
    check(!d_val[0] && d_val[1] && d_cnt == 1, "cpl_alloc");
    // 8: fill all entries; distinct-line alloc rejected while completing
    for (int e = 0; e < D-1; e++)
      stim(1, AW'(64'h300 + 64'(e*64)), IDW'(3+e), '0, 0, '0, '0, 0, '0, 0, 0);
    check(d_full && int'(d_cnt) == D, "filled");
    stim(1, 64'h900, 4'd9, '0, 0, '0, '0, 1, IDX'(0), 0, 0);
    check(pre_full && !pre_ready, "full_reject");
    check(int'(d_cnt) == D-1 && !d_val[0], "full_drain");
    stim(1, 64'h900, 4'd9, '0, 0, '0, '0, 0, '0, 0, 0);
    check(pre_ready && !pre_merged && pre_aidx == IDX'(0), "freed_alloc");
    check(d_val[0] && d_id[0] == 4'd9 && int'(d_cnt) == D, "new_primary");
    // 9: flush; alloc; block + alloc -> new row; unblock+attach; block-both lookup
    stim(0, '0, '0, '0, 0, '0, '0, 0, '0, 0, 1);
    stim(1, 64'h100, 4'd1, '0, 0, '0, '0, 0, '0, 0, 0);
    mblock = D'(1);
    stim(1, 64'h100, 4'd2, '0, 0, D'(1), '0, 0, '0, 0, 0);
    check(d_val[1] && d_id[1] == 4'd2, "blocked_newrow");
    stim(1, 64'h100, 4'd8, '0, 0, '0, 64'h100, 0, '0, 0, 0);
    check(d_hit && d_lidx == IDX'(1) && d_nw[1] == 1 && d_nw[0] == 0,
          "attach_row1");
    stim(0, '0, 4'd2, '0, 0, D'(3), 64'h100, 0, '0, 0, 0);
    check(!d_hit && d_idm[1], "blocked_lookup");
    stim(0, '0, '0, '0, 0, D'(3), '0, 1, IDX'(1), 1, 0);
    check(!d_val[1] && d_val[0] && int'(d_cnt) == 1, "blocked_drain");
    // 10: flush concurrent + async reset while occupied
    stim(1, 64'h400, 4'd4, '0, 0, '0, '0, 1, IDX'(0), 1, 1);
    check(int'(d_cnt) == 0 && ~(|d_val), "flush_clear");
    for (int e = 0; e < D; e++) check(d_nw[e] == '0, "flush_nwait");
    stim(1, 64'h500, 4'd5, '0, 0, '0, '0, 0, '0, 0, 0);
    @(negedge clk); rst_n = 0;
    flush = 0; alloc = 0; alloc_line = '0; alloc_id = '0; alloc_meta = '0;
    alloc_w = 0; mblock = '0; lookup_line = '0; complete = 0; cidx = '0;
    pop = 0;
    #1;
    check(dut.mem_q === '0 && reference.mem_q === '0 &&
          dut.count_q == 0 && reference.count_q == 0, "async_reset");
    @(negedge clk); rst_n = 1; repeat (2) @(posedge clk);
    // 11: 2048 xorshift cycles
    for (int t = 0; t < 2048; t++) begin
      stim_t s;
      seed = seed ^ (seed << 13); seed = seed ^ (seed >> 17); seed = seed ^ (seed << 5);
      s.alloc  = seed[0]; s.aline = AW'(64'h100 + 64'((64'(seed)>>8 & 3) * 64));
      s.aid    = IDW'(seed >> 4 & 'hF); s.ameta = META'(seed >> 12 & 'h1FFFF);
      s.aw     = seed[3]; s.mblk  = D'(seed >> 20);
      s.lline  = AW'(64'h100 + 64'((64'(seed)>>6 & 3) * 64));
      s.cpl    = seed[1]; s.cix   = IDX'(seed >> 16 & (D > 1 ? 32'(D-1) : 32'(0)));
      s.pp     = seed[2]; s.fl    = (t % 397) == 200;
      step(s);
    end
    done = 1'b1;
    $display("HYP8_MSHR_CASE_PASS D=%0d NW=%0d checked=%0d", D, NWP, checked);
  end
endmodule

module tb_g6lc_hyp8_mshr;
  tb_g6lc_hyp8_mshr_case #(.D(2), .NWP(1)) c21();
  tb_g6lc_hyp8_mshr_case #(.D(2), .NWP(4)) c24();
  tb_g6lc_hyp8_mshr_case #(.D(4), .NWP(1)) c41();
  tb_g6lc_hyp8_mshr_case #(.D(4), .NWP(4)) c44();
  initial begin
    wait (c21.done && c24.done && c41.done && c44.done);
    $display("HYP8_MSHR_PASS");
    $finish;
  end
  initial begin
    #1000000;
    $display("FAIL tb_g6lc_hyp8_mshr TIMEOUT"); $fatal(1);
  end
endmodule
