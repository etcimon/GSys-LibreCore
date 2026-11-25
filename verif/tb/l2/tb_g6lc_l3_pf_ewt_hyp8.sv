// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 non-inclusive eWT L3 warm-set prefetching leaf:
// Instantiates g6lc_l3_top with hyp8-mc eWT L3 settings
// (SET_ASSOC=16, RR_EN=1, TAG_SRAM=1, WRITE_UPDATE=1, POSTED_WRITES=1,
//  PF_EN=1, PF_EVICT_OK=1, MSHR_DEPTH=4, PF_MSHR_RESERVE=1, PF_DISTANCE=2,
//  PF_MAX_OUT=2, PF_QUIET=2).
//
// Scenario:
//   1. Warm ALL sets of the 16-way L3 (fill every way -> 100% valid sets).
//   2. Stream 32 consecutive 64B lines on a fresh page (stride +1) with
//      20-cycle compute spacing between reads:
//      - Fixed (PF_EVICT_OK=1): L3 prefetcher trains after 2 deltas and
//        prefetches ahead into warm sets -> >= 24/32 (75%+, steady-state >90%)
//        L3 hits on the warm stream, l3_pf_issue >= 24, l3_pf_useful >= 24!
//      - Mutant (-DG6LC_MUT_L3_PF_NO_WARM_EVICT): every warm-set candidate is
//        dropped -> l3_pf_issue == 0, l3_pf_useful == 0, 0/32 hits -> FAILS!
//
// PASS token: PASS tb_g6lc_l3_pf_ewt_hyp8
module tb_g6lc_l3_pf_ewt_hyp8;
  import g6lc_l3_pkg::*;

  localparam int unsigned AW = 64;
  localparam int unsigned DW = 64;
  localparam int unsigned IDW = 4;
  localparam int unsigned SET_ASSOC = 16;
  localparam int unsigned NUM_SETS  = 8;  // 8 KiB, 16-way, 64 B lines -> set_stride = 512 B
  localparam int unsigned BYTE_SIZE = NUM_SETS * SET_ASSOC * 64;

  typedef struct packed {
    logic [IDW-1:0] id; logic [AW-1:0] addr; logic [7:0] len; logic [2:0] size;
    axi_pkg::burst_t burst; logic lock; axi_pkg::cache_t cache; axi_pkg::prot_t prot;
    axi_pkg::qos_t qos; axi_pkg::region_t region; axi_pkg::atop_t atop; logic user;
  } aw_t;
  typedef struct packed {
    logic [DW-1:0] data; logic [DW/8-1:0] strb; logic last; logic user;
  } w_t;
  typedef struct packed {
    logic [IDW-1:0] id; axi_pkg::resp_t resp; logic user;
  } b_t;
  typedef struct packed {
    logic [IDW-1:0] id; logic [AW-1:0] addr; logic [7:0] len; logic [2:0] size;
    axi_pkg::burst_t burst; logic lock; axi_pkg::cache_t cache; axi_pkg::prot_t prot;
    axi_pkg::qos_t qos; axi_pkg::region_t region; logic user;
  } ar_t;
  typedef struct packed {
    logic [IDW-1:0] id; logic [DW-1:0] data; axi_pkg::resp_t resp; logic last; logic user;
  } r_t;
  typedef struct packed {
    aw_t aw; logic aw_valid; w_t w; logic w_valid; logic b_ready;
    ar_t ar; logic ar_valid; logic r_ready;
  } req_t;
  typedef struct packed {
    logic aw_ready; logic w_ready; b_t b; logic b_valid;
    logic ar_ready; r_t r; logic r_valid;
  } resp_t;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask

  req_t  slv_req = '0, mst_req;
  resp_t slv_resp, mst_resp = '0;
  logic  l3_hit, l3_miss, pf_iss, pf_use, pf_drp;

  g6lc_l3_top #(
      .Enable         (1'b1),
      .RR_EN          (1'b1),
      .TAG_SRAM       (1'b1),
      .WRITE_UPDATE   (1'b1),
      .POSTED_WRITES  (1'b1),
      .WTRK_DEPTH     (4),
      .RDTRK_DEPTH    (4),
      .PF_EN          (1'b1),
      .PF_STREAMS     (4),
      .PF_DISTANCE    (2),
      .PF_STRIDE      (1'b1),
      .PF_MSHR_RESERVE(1),
      .PF_MAX_OUT     (2),
      .PF_QUIET       (2),
      .PF_EVICT_OK    (1'b1),
      .BYTE_SIZE      (BYTE_SIZE),
      .SET_ASSOC      (SET_ASSOC),
      .LINE_WIDTH     (512),
      .MSHR_DEPTH     (4),
      .DATA_BANKS     (4),
      .AXI_ADDR_WIDTH (AW),
      .AXI_DATA_WIDTH (DW),
      .AXI_ID_WIDTH   (IDW),
      .axi_req_t      (req_t),
      .axi_resp_t     (resp_t)
  ) dut (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .slv_req_i            (slv_req),
      .slv_resp_o           (slv_resp),
      .mst_req_o            (mst_req),
      .mst_resp_i           (mst_resp),
      .l3_hit_o             (l3_hit),
      .l3_miss_o            (l3_miss),
      .l3_bypass_o          (),
      .l3_selfinv_hit_o     (),
      .l3_wupdate_o         (),
      .l3_wtrk_full_o       (),
      .l3_wtrk_line_hold_o  (),
      .l3_pf_issue_o        (pf_iss),
      .l3_pf_useful_o       (pf_use),
      .l3_pf_drop_o         (pf_drp),
      .l3_hold_r1_o         (),
      .l3_hold_r1_wu_o      (),
      .l3_hold_r2_o         (),
      .l3_posted_o          (),
      .l3_rdtrk_o           (),
      .l3_posted_hold_o     (),
      .l3_evict_valid_o     (),
      .l3_evict_addr_o      (),
      .l3_evict_ready_i     (1'b1),
      .l3_write_idle_o      (),
      .l3_back_inval_valid_i(1'b0),
      .l3_back_inval_addr_i ('0),
      .l3_back_inval_ready_o(),
      .l3_quiesce_i         (1'b0),
      .l3_block_slv_i       (1'b0),
      .l3_idle_o            (),
      .l3_inval_all_i       (1'b0),
      .l3_inval_all_done_o  ()
  );

  logic r_act = 0;
  logic [IDW-1:0] r_id = '0;
  logic [AW-1:0]  r_addr = '0;
  logic [7:0]     r_cnt = '0, r_len = '0;

  always_comb begin
    mst_resp          = '0;
    mst_resp.ar_ready = !r_act;
    mst_resp.aw_ready = 1'b1;
    mst_resp.w_ready  = 1'b1;
    mst_resp.r_valid  = r_act;
    mst_resp.r.id     = r_id;
    mst_resp.r.resp   = axi_pkg::RESP_OKAY;
    mst_resp.r.last   = (r_cnt == r_len);
    mst_resp.r.data   = 64'hC300_0000_0000_0000 | (r_addr + {53'd0, r_cnt, 3'd0});
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) r_act <= 0;
    else if (!r_act && mst_req.ar_valid) begin
      r_act <= 1; r_id <= mst_req.ar.id; r_addr <= mst_req.ar.addr;
      r_len <= mst_req.ar.len; r_cnt <= '0;
    end else if (r_act && mst_req.r_ready) begin
      if (r_cnt == r_len) r_act <= 0;
      else r_cnt <= r_cnt + 1;
    end
  end

  int unsigned hits = 0, iss_n = 0, use_n = 0, drp_n = 0;
  always @(posedge clk) if (rst_n) begin
    if (l3_hit) hits  <= hits + 1;
    if (pf_iss) iss_n <= iss_n + 1;
    if (pf_use) use_n <= use_n + 1;
    if (pf_drp) drp_n <= drp_n + 1;
  end

  task automatic do_read(input logic [63:0] addr, output logic [63:0] rdata, output bit was_hit);
    int unsigned h0;
    h0 = hits;
    slv_req = '0;
    slv_req.ar_valid = 1'b1;
    slv_req.ar.id    = 4'd1;
    slv_req.ar.addr  = addr;
    slv_req.ar.len   = 8'd0;
    slv_req.ar.size  = 3'd3;
    slv_req.ar.burst = axi_pkg::BURST_INCR;
    slv_req.ar.cache = 4'b1111;
    slv_req.r_ready  = 1'b1;
    slv_req.b_ready  = 1'b1;
    while (!slv_resp.ar_ready) tick();
    tick();
    slv_req.ar_valid = 1'b0;
    while (!slv_resp.r_valid) tick();
    rdata   = slv_resp.r.data;
    was_hit = (hits > h0);
    tick();
  endtask

  logic [63:0] d;
  bit h;
  int unsigned stream_hits = 0, iss0, use0, drp0;
  initial begin
    slv_req.r_ready = 1'b1; slv_req.b_ready = 1'b1;
    repeat (4) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    // 1. Warm EVERY set/way of the 16-way L3 (8 sets x 16 ways = 128 lines)
    //    Use separate 4KiB pages per line (stride 4096+64) so warmup fills all
    //    sets/ways completely without creating a false page stream.
    for (int s = 0; s < NUM_SETS; s++) begin
      for (int w = 0; w < SET_ASSOC; w++) begin
        do_read(64'h8000_0000 + (64'(w) << 12) + (64'(s) << 6), d, h);
      end
    end
    repeat (30) tick();
    iss0 = iss_n; use0 = use_n; drp0 = drp_n;

    // 2. Stream 32 consecutive lines on a brand-new 4 KiB page (0x8010_0000)
    //    while ALL 16 ways of every L3 set are valid!
    for (int k = 0; k < 32; k++) begin
      do_read(64'h8010_0000 + (64'(k) << 6), d, h);
      if (d !== (64'hC300_0000_8010_0000 + (64'(k) << 6)))
        $fatal(1, "FAIL L3_PF_DATA k=%0d d=%h", k, d);
      if (h) stream_hits++;
      repeat (20) tick();  // compute spacing -> lets quiet window lapse & PF fill land
    end

    $display("L3_WARM_STREAM hits=%0d/32 (%.1f%%) pf_iss=%0d pf_use=%0d pf_drp=%0d",
             stream_hits, (100.0 * stream_hits) / 32.0,
             iss_n - iss0, use_n - use0, drp_n - drp0);
    if ((iss_n - iss0) == 0)
      $fatal(1, "FAIL L3_WARM_PF_ISSUED iss=0 (warm-set candidates dropped!)");
    // Warm-set L3 eWT streaming hit rate MUST exceed 80% (>=26/32) with
    // PF_EVICT_OK + PF-hit re-training AND zero redundant duplicate drops!
    if (stream_hits < 26 || (use_n - use0) < 26)
      $fatal(1, "FAIL L3_WARM_HIT_GT80 hits=%0d/32 use=%0d (want >=26)",
             stream_hits, use_n - use0);
    if ((drp_n - drp0) > 2)
      $fatal(1, "FAIL L3_PF_REDUNDANT_DROPS drp=%0d (want <=2)", drp_n - drp0);

    $display("PASS tb_g6lc_l3_pf_ewt_hyp8 hits=%0d/32 pf_iss=%0d pf_use=%0d",
             stream_hits, iss_n - iss0, use_n - use0);
    $finish;
  end
endmodule
