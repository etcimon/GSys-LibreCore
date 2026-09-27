// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_l2_tag_miter — bounded flop-vs-SRAM miter for g6lc_l2_tag.
//
// The same stimulus drives a flop-array instance (TAG_SRAM=0, reference) and
// a tc_sram-backed instance (TAG_SRAM=1, trial). Stimulus follows the
// launched-read protocol (the lookup index is always the index launched the
// previous cycle). inval_match traffic is driven at a low rate: the SRAM
// path commits the match clear one cycle later than the flop array (a
// permitted timing difference), so equality checks are suppressed only for
// the cycle following each inval_match — from the second cycle on both
// arrays must show identical way-valid contents, which is where the
// deferred-clear corner (same-cycle install into a stale-tag way) bites.
// Cycle-identical agreement is required on hit_o / way_o / way_valid_o /
// probe_tag_o / probe_valid_o whenever row_valid_o is 1; the flop-visible
// outputs must agree in every non-suppressed cycle regardless.
//
// +miter_negative inverts the SRAM instance's hit_o — the mutation control.
// Prints L2TAG_MITER_PASS on success.

module tb_g6lc_l2_tag_miter;

  // WRITE_UPDATE exercises the same-edge install-vs-match guard added for
  // merged-line self-invalidation; the default keeps the Phase-4 netlist.
  parameter bit WRITE_UPDATE = 1'b0;

  localparam int unsigned NUM_SETS  = 16;
  localparam int unsigned SET_ASSOC = 4;
  localparam int unsigned TAG_WIDTH = 8;
  localparam int unsigned IDX_WIDTH = 4;
  localparam int unsigned WAY_W     = 2;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                    launch, lookup;
  logic [IDX_WIDTH-1:0]    launch_index, index;
  logic [TAG_WIDTH-1:0]    tag;
  logic [WAY_W-1:0]        probe_way;
  logic                    write, write_valid;
  logic [IDX_WIDTH-1:0]    write_index;
  logic [WAY_W-1:0]        write_way;
  logic [TAG_WIDTH-1:0]    write_tag;
  logic                    inval;
  logic [IDX_WIDTH-1:0]    inval_index;
  logic [TAG_WIDTH-1:0]    inval_tag;

  logic                    hit_g, hit_s, hit_s_raw;
  logic [WAY_W-1:0]        way_g, way_s;
  logic [SET_ASSOC-1:0]    wv_g, wv_s;
  logic                    rv_g, rv_s;
  logic [TAG_WIDTH-1:0]    pt_g, pt_s;
  logic                    pv_g, pv_s;
  logic                    imh_g, imh_s, imh_g_d = 1'b0;

  bit negative;
  assign hit_s = hit_s_raw ^ negative;

  g6lc_l2_tag #(
      .NUM_SETS(NUM_SETS), .SET_ASSOC(SET_ASSOC), .TAG_WIDTH(TAG_WIDTH),
      .IDX_WIDTH(IDX_WIDTH), .TAG_SRAM(1'b0), .WRITE_UPDATE(WRITE_UPDATE)
  ) i_gold (
      .clk_i(clk), .rst_ni(rst_n),
      .launch_i(launch), .launch_index_i(launch_index),
      .lookup_i(lookup), .index_i(index), .tag_i(tag),
      .hit_o(hit_g), .way_o(way_g), .way_valid_o(wv_g), .row_valid_o(rv_g),
      .probe_way_i(probe_way), .probe_tag_o(pt_g), .probe_valid_o(pv_g),
      .write_i(write), .write_index_i(write_index), .write_way_i(write_way),
      .write_tag_i(write_tag), .write_valid_i(write_valid),
      .inval_i(1'b0), .inval_index_i('0), .inval_way_i('0),
      .inval_match_i(inval), .inval_match_index_i(inval_index),
      .inval_match_tag_i(inval_tag), .inval_match_hit_o(imh_g)
  );

  g6lc_l2_tag #(
      .NUM_SETS(NUM_SETS), .SET_ASSOC(SET_ASSOC), .TAG_WIDTH(TAG_WIDTH),
      .IDX_WIDTH(IDX_WIDTH), .TAG_SRAM(1'b1), .WRITE_UPDATE(WRITE_UPDATE)
  ) i_trial (
      .clk_i(clk), .rst_ni(rst_n),
      .launch_i(launch), .launch_index_i(launch_index),
      .lookup_i(lookup), .index_i(index), .tag_i(tag),
      .hit_o(hit_s_raw), .way_o(way_s), .way_valid_o(wv_s), .row_valid_o(rv_s),
      .probe_way_i(probe_way), .probe_tag_o(pt_s), .probe_valid_o(pv_s),
      .write_i(write), .write_index_i(write_index), .write_way_i(write_way),
      .write_tag_i(write_tag), .write_valid_i(write_valid),
      .inval_i(1'b0), .inval_index_i('0), .inval_way_i('0),
      .inval_match_i(inval), .inval_match_index_i(inval_index),
      .inval_match_tag_i(inval_tag), .inval_match_hit_o(imh_s)
  );

  // Drive just after posedge, check at the following negedge: stimulus lives
  // for exactly one cycle, the row launched this cycle is presented next
  // cycle, and a compare may only use the index it launched (the internal
  // L2TAG row-index contract mirrors the parent's protocol).
  int unsigned checks = 0;
  logic              prev_vld = 1'b0;
  logic [IDX_WIDTH-1:0] prev_idx = '0;

  // Equality checks are suppressed in the cycle after an inval_match: the
  // flop array commits the clear at that edge while the SRAM path's deferred
  // compare is still in flight (its row read took the port). From two cycles
  // on, both arrays must agree again — a stale-tag corner there is a bug.
  bit suppress = 1'b0;

  initial begin
    negative = $test$plusargs("miter_negative");
    launch = 0; lookup = 0; write = 0; write_valid = 1'b1;
    index = '0; tag = '0; probe_way = '0;
    launch_index = '0; write_index = '0; write_way = '0; write_tag = '0;
    inval = 0; inval_index = '0; inval_tag = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    for (int unsigned i = 0; i < 6000; i++) begin
      @(posedge clk); #1;
      launch       = ($urandom_range(0, 3) != 0);
      launch_index = IDX_WIDTH'($urandom_range(0, NUM_SETS - 1));
      write        = ($urandom_range(0, 3) == 0);
      write_index  = IDX_WIDTH'($urandom_range(0, NUM_SETS - 1));
      write_way    = WAY_W'($urandom_range(0, SET_ASSOC - 1));
      write_tag    = TAG_WIDTH'($urandom_range(0, 255));
      // Inval-match at a low rate, biased toward sets/ways recently written
      // so the stale-tag coincidence actually occurs.
      inval       = ($urandom_range(0, 15) == 0);
      inval_index = write ? write_index : IDX_WIDTH'($urandom_range(0, NUM_SETS - 1));
      inval_tag   = write ? write_tag : TAG_WIDTH'($urandom_range(0, 255));
      // Bias the compare tag toward values being written so hits occur.
      tag = write && (write_index == (prev_vld ? prev_idx : index))
            ? write_tag : TAG_WIDTH'($urandom_range(0, 255));
      lookup    = prev_vld ? ($urandom_range(0, 3) != 0)
                           : 1'b0;
      index     = prev_vld ? prev_idx
                           : IDX_WIDTH'($urandom_range(0, NUM_SETS - 1));
      probe_way = WAY_W'($urandom_range(0, SET_ASSOC - 1));
      @(negedge clk);
      if (rv_g !== 1'b1) $fatal(1, "L2TAG_MITER_CONST flop row_valid_o");
      // Deferred-pulse parity: the SRAM path reports a match-clear exactly
      // one cycle after the flop path reports the same clear — every cycle,
      // including inside the suppress window (the pulse is the deferred
      // compare's own verdict, not a live-valid observation).
      if (imh_s !== imh_g_d)
        $fatal(1, "L2TAG_MITER_SELFINV i=%0d gold_d=%0b sram=%0b", i, imh_g_d, imh_s);
      imh_g_d = imh_g;
      if (!suppress) begin
        if (rv_s === 1'b1) begin
          if (!prev_vld) $fatal(1, "L2TAG_MITER_ROW_UNSOLICITED");
          if (hit_g !== hit_s || way_g !== way_s || wv_g !== wv_s ||
              pt_g !== pt_s || pv_g !== pv_s)
            $fatal(1, "L2TAG_MITER i=%0d gold={h%0b w%0d v%b pt%h pv%0b} sram={h%0b w%0d v%b pt%h pv%0b}",
                   i, hit_g, way_g, wv_g, pt_g, pv_g,
                   hit_s, way_s, wv_s, pt_s, pv_s);
          checks++;
        end else begin
          // No row presented: the flop-visible outputs must still agree.
          if (wv_g !== wv_s || pv_g !== pv_s)
            $fatal(1, "L2TAG_MITER_VALID i=%0d gold_v=%b gold_pv=%0b sram_v=%b sram_pv=%0b",
                   i, wv_g, pv_g, wv_s, pv_s);
        end
      end
      suppress  = inval;
      prev_vld  = launch;
      prev_idx  = launch_index;
    end

    // Directed corner: same-cycle install + inval-match into a way whose
    // stale row entry still holds the match tag. The flop array samples the
    // way's valid bit before the write (0 -> no clear); a deferred compare
    // against live valids would drop the freshly installed line.
    launch = 0; lookup = 0; write = 0; inval = 0;
    @(posedge clk); #1;
    write = 1'b1; write_index = IDX_WIDTH'(7); write_way = WAY_W'(3);
    write_tag = 8'h5A; write_valid = 1'b1;                       // install T=5A
    @(posedge clk); #1;
    write = 1'b0;
    inval = 1'b1; inval_index = IDX_WIDTH'(7); inval_tag = 8'h5A; // inv clears w3
    @(posedge clk); #1;
    inval = 1'b0;
    repeat (4) @(posedge clk);                                   // deferral settles
    #1;
    write = 1'b1; write_index = IDX_WIDTH'(7); write_way = WAY_W'(3);
    write_tag = 8'hA5; write_valid = 1'b1;                       // install T2=A5
    inval = 1'b1; inval_index = IDX_WIDTH'(7); inval_tag = 8'h5A; // + match on stale T
    @(posedge clk); #1;
    write = 1'b0; inval = 1'b0;
    repeat (4) @(posedge clk);                                   // deferred compare lands
    #1;
    launch = 1'b1; launch_index = IDX_WIDTH'(7);
    @(posedge clk); #1;
    launch = 1'b0;
    lookup = 1'b1; index = IDX_WIDTH'(7); tag = 8'hA5;
    @(negedge clk);
    if (hit_g !== 1'b1) $fatal(1, "L2TAG_MITER_CORNER_GOLD");
    if (hit_s !== 1'b1 || way_s !== way_g || wv_s !== wv_g)
      $fatal(1, "L2TAG_MITER_CORNER sram hit=%0b way=%0d wv=%b gold h=1 way=%0d wv=%b",
             hit_s, way_s, wv_s, way_g, wv_g);
    checks++;

    // Directed corner 2: back-to-back inval-match on the same set/tag, with
    // an install racing the SECOND read. inv1's deferred clear is still in
    // flight when inv2 snapshots the valid row — the snapshot must fold the
    // pending clear in (the flop array already committed it), else inv2's
    // compare matches the stale row and kills the fresh C2 install.
    launch = 0; lookup = 0; write = 0; inval = 0;
    @(posedge clk); #1;
    write = 1'b1; write_index = IDX_WIDTH'(9); write_way = WAY_W'(1);
    write_tag = 8'hC1;                                          // install C1
    @(posedge clk); #1;
    write = 1'b0;
    inval = 1'b1; inval_index = IDX_WIDTH'(9); inval_tag = 8'hC1; // inv1: kills w1
    @(posedge clk); #1;
    write = 1'b1; write_index = IDX_WIDTH'(9); write_way = WAY_W'(1);
    write_tag = 8'hC2;                                          // install C2 ...
    inval = 1'b1; inval_index = IDX_WIDTH'(9); inval_tag = 8'hC1; // ... under inv2
    @(posedge clk); #1;
    write = 1'b0; inval = 1'b0;
    repeat (4) @(posedge clk);                                  // both deferrals retire
    #1;
    launch = 1'b1; launch_index = IDX_WIDTH'(9);
    @(posedge clk); #1;
    launch = 1'b0;
    lookup = 1'b1; index = IDX_WIDTH'(9); tag = 8'hC2;
    @(negedge clk);
    if (hit_g !== 1'b1) $fatal(1, "L2TAG_MITER_CORNER2_GOLD");
    if (hit_s !== 1'b1 || wv_s !== wv_g)
      $fatal(1, "L2TAG_MITER_CORNER2 sram hit=%0b wv=%b gold h=1 wv=%b",
             hit_s, wv_s, wv_g);
    checks++;

    if (checks < 500) $fatal(1, "L2TAG_MITER_THIN checks=%0d", checks);
    $display("L2TAG_MITER_PASS checks=%0d", checks);
    $finish;
  end

  initial begin
    #2ms;
    $fatal(1, "L2TAG_MITER_WATCHDOG");
  end

endmodule
