// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Fast isolated hyp8 L2/L3 eWT Hit-Protected RR + Same-Set Bypass leaf:
// Instantiates g6lc_l2_top with exact hyp8-mc eWT parameters
// (SET_ASSOC=8, RR_EN=1, TAG_SRAM=1, WRITE_UPDATE=1, POSTED_WRITES=1).
//
// Scenarios:
//   S1 (hot_scan, 8-way set 0, 24 rotating scan rounds):
//      Install 1 hot line (tag 1) + 7 initial scan lines (tags 2..8), then
//      run 24 rounds of {read hot line; read fresh cold scan line}.
//      - Hit-Protected RR: hot line hits 24/24 rounds (100% hot retention;
//        0 hot evictions!) -> total hits = 24, misses = 32 (8 cold + 24 scan).
//      - Blind RR mutant (-DG6LC_MUT_L2_RR_NO_HIT_PROTECT): hot line gets
//        evicted every 8 rounds -> hits drop from 24 to 21, misses rise +3!
//   S2 (eWT write-update + read-back on hot line):
//      Write-through store to hot line merges in place (l2_wupdate_o=1,
//      l2_selfinv_hit_o=0), subsequent read hits L2 and returns updated bytes.
//
// PASS token: PASS tb_g6lc_l2_hitprot_hyp8
module tb_g6lc_l2_hitprot_hyp8;
  import g6lc_l2_pkg::*;

  localparam int unsigned AW = 64;
  localparam int unsigned DW = 64;
  localparam int unsigned IDW = 4;
  localparam int unsigned SET_ASSOC = 8;
  localparam int unsigned NUM_SETS  = 16; // 8 KiB, 8-way, 64 B lines -> set_stride = 1024 B
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
  logic  l2_hit, l2_miss, l2_wupd, l2_sinv;

  g6lc_l2_top #(
      .Enable        (1'b1),
      .BYTE_SIZE     (BYTE_SIZE),
      .SET_ASSOC     (SET_ASSOC),
      .LINE_WIDTH    (512),
      .MSHR_DEPTH    (2),
      .DATA_BANKS    (4),
      .RR_EN         (1'b1),
      .TAG_SRAM      (1'b1),
      .WRITE_UPDATE  (1'b1),
      .POSTED_WRITES (1'b1),
      .WTRK_DEPTH    (4),
      .RDTRK_DEPTH   (4),
      .AXI_ADDR_WIDTH(AW),
      .AXI_DATA_WIDTH(DW),
      .AXI_ID_WIDTH  (IDW),
      .axi_req_t     (req_t),
      .axi_resp_t    (resp_t)
  ) dut (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .slv_req_i            (slv_req),
      .slv_resp_o           (slv_resp),
      .mst_req_o            (mst_req),
      .mst_resp_i           (mst_resp),
      .l2_hit_o             (l2_hit),
      .l2_miss_o            (l2_miss),
      .l2_bypass_o          (),
      .l2_mshr_full_o       (),
      .l2_bank_conflict_o   (),
      .l2_selfinv_hit_o     (l2_sinv),
      .l2_wupdate_o         (l2_wupd),
      .l2_pf_issue_o        (),
      .l2_pf_useful_o       (),
      .l2_pf_drop_o         (),
      .l2_wtrk_full_o       (),
      .l2_wtrk_line_hold_o  (),
      .l2_hold_r1_o         (),
      .l2_hold_r1_wu_o      (),
      .l2_hold_r2_o         (),
      .l2_posted_o          (),
      .l2_rdtrk_o           (),
      .l2_posted_hold_o     (),
      .l2_evict_valid_o     (),
      .l2_evict_addr_o      (),
      .l2_evict_ready_i     (1'b1),
      .l2_back_inval_valid_i(1'b0),
      .l2_back_inval_addr_i ('0),
      .l2_back_inval_ready_o(),
      .l2_write_idle_o      (),
      .l2_quiesce_i         (1'b0),
      .l2_block_slv_i       (1'b0),
      .l2_idle_o            (),
      .l2_inval_all_i       (1'b0),
      .l2_inval_all_done_o  ()
  );

  // Tiny deterministic AXI memory responder (1-cycle R burst, 1-cycle B)
  logic [63:0] mem_override_addr = '0, mem_override_data = '0;
  logic        mem_override_v = 1'b0;
  logic        r_act = 0;
  logic [IDW-1:0] r_id = '0;
  logic [AW-1:0]  r_addr = '0;
  logic [7:0]     r_cnt = '0, r_len = '0;
  logic        b_act = 0;
  logic [IDW-1:0] b_id = '0;
  logic [AW-1:0]  w_addr = '0;
  logic        w_act = 0;

  always_comb begin
    mst_resp          = '0;
    mst_resp.ar_ready = !r_act;
    mst_resp.aw_ready = !w_act && !b_act;
    mst_resp.w_ready  = w_act;
    mst_resp.r_valid  = r_act;
    mst_resp.r.id     = r_id;
    mst_resp.r.resp   = axi_pkg::RESP_OKAY;
    mst_resp.r.last   = (r_cnt == r_len);
    mst_resp.r.data   = (mem_override_v && (r_addr + {53'd0, r_cnt, 3'd0} == mem_override_addr))
                        ? mem_override_data
                        : (64'hA500_0000_0000_0000 | (r_addr + {53'd0, r_cnt, 3'd0}));
    mst_resp.b_valid  = b_act;
    mst_resp.b.id     = b_id;
    mst_resp.b.resp   = axi_pkg::RESP_OKAY;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_act <= 0; b_act <= 0; w_act <= 0; mem_override_v <= 0;
    end else begin
      if (!r_act && mst_req.ar_valid) begin
        r_act <= 1; r_id <= mst_req.ar.id; r_addr <= mst_req.ar.addr;
        r_len <= mst_req.ar.len; r_cnt <= '0;
      end else if (r_act && mst_req.r_ready) begin
        if (r_cnt == r_len) r_act <= 0;
        else r_cnt <= r_cnt + 1;
      end
      if (!w_act && !b_act && mst_req.aw_valid) begin
        w_act <= 1; b_id <= mst_req.aw.id; w_addr <= mst_req.aw.addr;
      end else if (w_act && mst_req.w_valid && mst_req.w.last) begin
        w_act <= 0; b_act <= 1;
        mem_override_v <= 1; mem_override_addr <= w_addr; mem_override_data <= mst_req.w.data;
      end else if (b_act && mst_req.b_ready) begin
        b_act <= 0;
      end
    end
  end

  int unsigned hits = 0, misses = 0, wupds = 0, sinvs = 0;
  always @(posedge clk) if (rst_n) begin
    if (l2_hit)  hits <= hits + 1;
    if (l2_miss) misses <= misses + 1;
    if (l2_wupd) wupds <= wupds + 1;
    if (l2_sinv) sinvs <= sinvs + 1;
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

  task automatic do_write(input logic [63:0] addr, input logic [63:0] wdata);
    slv_req = '0;
    slv_req.aw_valid = 1'b1;
    slv_req.aw.id    = 4'd2;
    slv_req.aw.addr  = addr;
    slv_req.aw.len   = 8'd0;
    slv_req.aw.size  = 3'd3;
    slv_req.aw.burst = axi_pkg::BURST_INCR;
    slv_req.aw.cache = 4'b1111;
    slv_req.r_ready  = 1'b1;
    slv_req.b_ready  = 1'b1;
    while (!slv_resp.aw_ready) tick();
    tick();
    slv_req.aw_valid = 1'b0;
    slv_req.w_valid  = 1'b1;
    slv_req.w.data   = wdata;
    slv_req.w.strb   = 8'hff;
    slv_req.w.last   = 1'b1;
    while (!slv_resp.w_ready) tick();
    tick();
    slv_req.w_valid  = 1'b0;
    while (!slv_resp.b_valid) tick();
    tick();
  endtask

  logic [63:0] d;
  bit          h;
  int unsigned hot_hits = 0;
  initial begin
    slv_req.r_ready = 1'b1; slv_req.b_ready = 1'b1;
    repeat (4) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    // S1: Set 0 hot line (tag 1 = 0x8000_0400) + 7 initial cold lines (tags 2..8)
    for (int k = 1; k <= 8; k++) begin
      do_read(64'h8000_0000 + (64'(k) << 10), d, h);
      if (d !== (64'hA500_0000_0000_0000 | (64'h8000_0000 + (64'(k) << 10))))
        $fatal(1, "FAIL S1_INIT_DATA k=%0d d=%h", k, d);
    end
    // 24 rotating scan rounds: re-read hot line (tag 1) + 1 fresh cold line
    for (int r = 0; r < 24; r++) begin
      do_read(64'h8000_0400, d, h);
      if (d !== 64'hA500_0000_8000_0400) $fatal(1, "FAIL S1_HOT_DATA r=%0d d=%h", r, d);
      if (h) hot_hits++;
      do_read(64'h8000_0000 + (64'(20 + r) << 10), d, h);
    end
    $display("HOT_SCAN hot_hits=%0d/24 total_hits=%0d", hot_hits, hits);
    // Hit-protected RR MUST keep hot line resident all 24/24 rounds (hot_hits==24)!
    if (hot_hits != 24)
      $fatal(1, "FAIL S1_HOT_LINE_EVICTED hot_hits=%0d/24", hot_hits);

    // S2: eWT write-update on resident hot line (0x8000_0400) -> 0 self-inval,
    //     1 wupd, subsequent read HITS L2 with updated data!
    do_write(64'h8000_0400, 64'hCAFE_BABE_1234_5678);
    do_read(64'h8000_0400, d, h);
    if (d !== 64'hCAFE_BABE_1234_5678) $fatal(1, "FAIL S2_WUPD_DATA d=%h", d);
    if (wupds != 1 || sinvs != 0 || !h)
      $fatal(1, "FAIL S2_EWT_WUPD wupds=%0d sinvs=%0d hit=%b", wupds, sinvs, h);

    $display("PASS tb_g6lc_l2_hitprot_hyp8 hot_hits=%0d/24 wupds=%0d sinvs=%0d",
             hot_hits, wupds, sinvs);
    $finish;
  end
endmodule
