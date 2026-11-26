// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 non-inclusive eWT L3 cross-page prefetching leaf:
// Instantiates g6lc_l3_top with hyp8-mc eWT L3 settings
// (SET_ASSOC=16, RR_EN=1, TAG_SRAM=1, WRITE_UPDATE=1, POSTED_WRITES=1,
//  PF_EN=1, PF_EVICT_OK=1, MSHR_DEPTH=4, PF_MSHR_RESERVE=1, PF_DISTANCE=4,
//  PF_MAX_OUT=4, PF_QUIET=2 by default; all five are macro-overridable).
//
// Scenario:
//   1. Warm ALL sets/ways of the 16-way L3 using one line in each of 128
//      distinct pages, so warmup cannot train the page-keyed prefetcher.
//   2. Stream 96 consecutive 64B lines beginning halfway down a fresh 4 KiB
//      page. The stream crosses exactly one page boundary after 32 demand
//      lines and stops at the next boundary.
//      - Fixed RTL carries confirmed stride-1 confidence into the physically
//        adjacent page after the first successor-page demand miss, so early
//        successor-page prefetches install before demand.
//      - Mutant (-DG6LC_MUT_PF_NO_XPAGE_CONTINUE) loses confidence at the
//        boundary and leaves the early successor-page lines demand/merge-only.
//
// PASS token: PASS tb_g6lc_l3_pf_xpage_hyp8
module tb_g6lc_l3_pf_xpage_hyp8;
  import g6lc_l3_pkg::*;

`ifndef PF_QUIET_VAL
`define PF_QUIET_VAL 2
`endif
`ifndef PF_DISTANCE_VAL
`define PF_DISTANCE_VAL 4
`endif
`ifndef PF_MAX_OUT_VAL
`define PF_MAX_OUT_VAL 4
`endif
`ifndef PF_MSHR_DEPTH_VAL
`define PF_MSHR_DEPTH_VAL 4
`endif
`ifndef PF_MSHR_RESERVE_VAL
`define PF_MSHR_RESERVE_VAL 1
`endif

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
      .PF_DISTANCE    (`PF_DISTANCE_VAL),
      .PF_STRIDE      (1'b1),
      .PF_MSHR_RESERVE(`PF_MSHR_RESERVE_VAL),
      .PF_MAX_OUT     (`PF_MAX_OUT_VAL),
      .PF_QUIET       (`PF_QUIET_VAL),
      .PF_EVICT_OK    (1'b1),
      .BYTE_SIZE      (BYTE_SIZE),
      .SET_ASSOC      (SET_ASSOC),
      .LINE_WIDTH     (512),
      .MSHR_DEPTH     (`PF_MSHR_DEPTH_VAL),
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
  int unsigned ar_fire_n = 0, r_fire_n = 0;
  logic [63:0] last_rdata = '0;
  int unsigned free_cyc = 0, stream_c0 = 0, stream_cyc = 0;
  int unsigned use_unique = 0, use_hit_cyc = 0, use_maxcnt = 0;
  logic [63:0] use_line [0:127];
  int unsigned use_cnt [0:127];
  always @(posedge clk) if (rst_n) begin
    free_cyc <= free_cyc + 1;
    if (l3_hit) hits  <= hits + 1;
    if (pf_iss) iss_n <= iss_n + 1;
    if (pf_use && stream_active) $display("L3PF_USE_TRACE cyc=%0d line=%h hit=%b state=%0d mhit=%b midx=%0d", free_cyc, {dut.i_l3_as_l2.gen_l2.addr_q[63:6],6'b0}, l3_hit, dut.i_l3_as_l2.gen_l2.state_q, dut.i_l3_as_l2.gen_l2.mshr_lookup_hit, dut.i_l3_as_l2.gen_l2.mshr_lookup_idx);
    if (pf_use) begin
      use_n <= use_n + 1;
      if (l3_hit) use_hit_cyc <= use_hit_cyc + 1;
      begin
        logic [63:0] ua;
        bit found;
        int unsigned fi;
        ua = {dut.i_l3_as_l2.gen_l2.addr_q[63:6], 6'b0};
        found = 0; fi = 0;
        for (int u = 0; u < 128; u++) begin
          if (!found && u < use_unique && use_line[u] == ua) begin
            found = 1; fi = u;
          end
        end
        if (!found && use_unique < 128) begin
          fi = use_unique;
          use_line[use_unique] <= ua;
          use_cnt[use_unique] <= 1;
          use_unique <= use_unique + 1;
          if (use_maxcnt < 1) use_maxcnt <= 1;
        end else if (found) begin
          use_cnt[fi] <= use_cnt[fi] + 1;
          if (use_maxcnt < use_cnt[fi] + 1) use_maxcnt <= use_cnt[fi] + 1;
        end
      end
    end
    if (pf_drp) drp_n <= drp_n + 1;
    if (slv_req.ar_valid && slv_resp.ar_ready) ar_fire_n <= ar_fire_n + 1;
    if (slv_resp.r_valid && slv_req.r_ready) begin
      r_fire_n <= r_fire_n + 1;
      last_rdata <= slv_resp.r.data;
    end
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
    begin
      int unsigned af0, rf0;
      af0 = ar_fire_n; rf0 = r_fire_n;
      while (ar_fire_n == af0) tick();
      slv_req.ar_valid = 1'b0;
      while (r_fire_n == rf0) tick();
      rdata   = last_rdata;
      was_hit = (hits > h0);
      tick();
    end
  endtask

  logic [63:0] d;
  bit h;
  int unsigned stream_hits = 0, xpage_early_hits = 0, iss0, use0, drp0;
  bit stream_active = 0;
  int unsigned spacing = 20;
  initial begin
    slv_req.r_ready = 1'b1; slv_req.b_ready = 1'b1;
    if (!$value$plusargs("pf_spacing=%d", spacing)) spacing = 20;
    repeat (4) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    // 1. Warm EVERY set/way of the 16-way L3 (8 sets x 16 ways = 128 lines).
    //    Use one line in each of 128 distinct 4 KiB pages so warmup cannot
    //    train the page-keyed stride prefetcher; choose the in-page offset to
    //    cover all 8 sets and the page number to provide 16 distinct ways.
    for (int s = 0; s < NUM_SETS; s++) begin
      for (int w = 0; w < SET_ASSOC; w++) begin
        do_read(64'h8000_0000 + (64'(w * NUM_SETS + s) << 12) + (64'(s) << 6), d, h);
      end
    end
    repeat (30) tick();
    iss0 = iss_n; use0 = use_n; drp0 = drp_n;
    use_unique = 0; use_hit_cyc = 0; use_maxcnt = 0;
    for (int uz = 0; uz < 128; uz++) begin use_cnt[uz] = 0; use_line[uz] = '0; end

    // 2. Stream 96 consecutive lines beginning halfway down a fresh 4 KiB page.
    //    The stream crosses exactly one page boundary after 32 demand lines and
    //    stops at the next boundary, isolating cross-page retraining cost while
    //    ALL 16 ways of every L3 set are valid!
    stream_c0 = free_cyc;
    stream_active = 1;
    for (int k = 0; k < 96; k++) begin
      automatic logic [63:0] aa = 64'h8010_0800 + (64'(k) << 6);
      do_read(aa, d, h);
      if (d !== (64'hC300_0000_0000_0000 | aa))
        $fatal(1, "FAIL L3_PF_DATA k=%0d d=%h aa=%h", k, d, aa);
      if (h) begin
        stream_hits++;
        if ((k >= 33) && (k <= 39)) xpage_early_hits++;
      end
      repeat (spacing) tick();  // runtime compute spacing diagnostic
    end

    $display("L3_WARM_STREAM hits=%0d/96 (%.1f%%) pf_iss=%0d pf_use=%0d pf_drp=%0d",
             stream_hits, (100.0 * stream_hits) / 96.0,
             iss_n - iss0, use_n - use0, drp_n - drp0);
    stream_active = 0;
    stream_cyc = free_cyc - stream_c0;
    $display("L3PF_SPACING_RES mshr=%0d res=%0d dist=%0d maxout=%0d quiet=%0d spacing=%0d hits=%0d/96 cyc=%0d pf_iss=%0d pf_use=%0d useuniq=%0d usemax=%0d usehit=%0d arf=%0d rf=%0d pf_drp=%0d",
             `PF_MSHR_DEPTH_VAL, `PF_MSHR_RESERVE_VAL, `PF_DISTANCE_VAL, `PF_MAX_OUT_VAL, `PF_QUIET_VAL, spacing, stream_hits, stream_cyc, iss_n - iss0, use_n - use0, use_unique, use_maxcnt, use_hit_cyc, ar_fire_n, r_fire_n, drp_n - drp0);
    // Oracle: without cross-page continuation lines 1..7 of the successor
    // page are all demand/merge misses (0 installed hits). The confirmed
    // stride-1 continuation rearms immediately on the first successor-page
    // miss and installs lines 4..7 in this deterministic leaf (4 hits). Keep
    // one hit of margin for timing parameters.
    if (xpage_early_hits < 3)
      $fatal(1, "FAIL L3_PF_XPAGE_EARLY_HITS got=%0d want>=3", xpage_early_hits);
    if ((iss_n - iss0) < 70)
      $fatal(1, "FAIL L3_PF_XPAGE_ISSUE iss=%0d want>=70", iss_n - iss0);
    $display("PASS tb_g6lc_l3_pf_xpage_hyp8 hits=%0d/96 early=%0d/7 pf_iss=%0d pf_use=%0d",
             stream_hits, xpage_early_hits, iss_n - iss0, use_n - use0);
    $finish;
  end
endmodule
