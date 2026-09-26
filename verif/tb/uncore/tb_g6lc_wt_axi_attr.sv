// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Phase 1 leaf: wt_axi_adapter AxCACHE emission under WtAxiAllocEn.
// ALLOC=0 must reproduce today's modifiable-only stream bit-for-bit;
// ALLOC=1 emits BUFFERABLE|MODIFIABLE|RD_ALLOC|WR_ALLOC (4'hf) only for
// cacheable requests — nc loads/fills, all stores with nc=1, and every
// atomic (LR/SC/arithmetic) stay modifiable-only.
module tb_g6lc_wt_axi_attr;
  import ariane_pkg::*;
  import wt_cache_pkg::*;
  parameter bit ALLOC = 0;
  // Copy the pushed package config and toggle the single new field, then run
  // the same build_config every production module sees.
  function automatic config_pkg::cva6_cfg_t attr_cfg(input bit alloc);
    config_pkg::cva6_user_cfg_t u;
    u = cva6_config_pkg::cva6_cfg;
    u.WtAxiAllocEn = alloc;
    return build_config_pkg::build_config(u);
  endfunction
  localparam config_pkg::cva6_cfg_t CVA6Cfg = attr_cfg(ALLOC);
  `include "wt-types.svh"
  typedef logic [63:0] addr_t;
  typedef logic [CVA6Cfg.PLEN-1:0] paddr_t;
  localparam type icache_req_t = struct packed {
    logic [CVA6Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] way;
    logic [CVA6Cfg.PLEN-1:0] paddr;
    logic nc;
    logic [CVA6Cfg.MEM_TID_WIDTH-1:0] tid;
  };
  localparam type icache_rtrn_t = struct packed {
    wt_cache_pkg::icache_in_t rtype;
    logic [CVA6Cfg.ICACHE_LINE_WIDTH-1:0] data;
    logic [CVA6Cfg.ICACHE_USER_LINE_WIDTH-1:0] user;
    struct packed {
      logic vld;
      logic all;
      logic [CVA6Cfg.ICACHE_INDEX_WIDTH-1:0] idx;
      logic [CVA6Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] way;
    } inv;
    logic [CVA6Cfg.MEM_TID_WIDTH-1:0] tid;
  };
  localparam addr_t P = 64'h8000_4000;
  localparam logic [3:0] ATTR_ALLOC = 4'hf;
  localparam logic [3:0] ATTR_MOD   = 4'h2;
  logic clk = 0, rst_n = 0;
  dcache_req_t dreq = '0;
  logic dreq_vld = 0, dreq_ack;
  dcache_rtrn_t drtrn;
  logic drtrn_vld;
  icache_req_t ireq = '0;
  logic ireq_vld = 0, ireq_ack;
  icache_rtrn_t irtrn;
  ariane_axi::req_t areq;
  ariane_axi::resp_t arsp;
  bit negative;
  int scenario, cycle = 0;
  int ar_seen = 0, aw_seen = 0;
  logic [3:0] ar_cache, aw_cache;
  logic [7:0] ar_len;
  logic [2:0] ar_size;
  logic ar_lock, aw_lock;
  logic [5:0] aw_atop;
  addr_t ar_addr, aw_addr;

  wt_axi_adapter #(.CVA6Cfg(CVA6Cfg),
      .axi_req_t(ariane_axi::req_t), .axi_rsp_t(ariane_axi::resp_t),
      .dcache_req_t(dcache_req_t), .dcache_rtrn_t(dcache_rtrn_t),
      .dcache_inval_t(dcache_inval_t), .icache_req_t(icache_req_t),
      .icache_rtrn_t(icache_rtrn_t)) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .icache_data_req_i(ireq_vld), .icache_data_ack_o(ireq_ack), .icache_data_i(ireq),
      .icache_rtrn_vld_o(), .icache_rtrn_o(irtrn),
      .dcache_data_req_i(dreq_vld), .dcache_data_ack_o(dreq_ack),
      .dcache_data_i(dreq),
      .dcache_rtrn_vld_o(drtrn_vld), .dcache_rtrn_o(drtrn),
      .axi_req_o(areq), .axi_resp_i(arsp), .mbe_i(1'b0),
      .inval_addr_i('0), .inval_valid_i(1'b0),
      .inval_ready_o(), .inval_apply_valid_o(), .inval_apply_addr_o());

  function automatic ariane_axi::data_t mem_word(input ariane_axi::addr_t a);
    return {a[31:0], ~a[31:0]} ^ 64'h5a5a_a5a5_1234_9876;
  endfunction

  // Same permissive DRAM model as tb_g6lc_wt_amo_apply: AW/W/AR accepted
  // unconditionally; ATOP loads earn one R beat, locked ARs EXOKAY.
  typedef struct packed {ariane_axi::id_t id; ariane_axi::data_t data;
    axi_pkg::resp_t resp;} rjob_t;
  typedef struct packed {ariane_axi::id_t id; axi_pkg::resp_t resp;} bjob_t;
  rjob_t rq[8];
  bjob_t bq[8];
  int rq_h = 0, rq_n = 0, bq_h = 0, bq_n = 0;
  always_comb begin
    arsp = '0;
    arsp.aw_ready = 1; arsp.w_ready = 1; arsp.ar_ready = 1;
    arsp.r_valid = rq_n > 0;
    arsp.r = '{id:rq[rq_h].id, data:rq[rq_h].data, resp:rq[rq_h].resp, last:1, user:0};
    arsp.b_valid = bq_n > 0;
    arsp.b = '{id:bq[bq_h].id, resp:bq[bq_h].resp, user:0};
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rq_h <= 0; rq_n <= 0; bq_h <= 0; bq_n <= 0;
    end else begin
      int rtail;
      rtail = rq_h + rq_n;
      if (areq.aw_valid && arsp.aw_ready) begin
        aw_seen++;
        aw_cache = areq.aw.cache; aw_lock = areq.aw.lock;
        aw_atop = areq.aw.atop; aw_addr = areq.aw.addr;
        bq[(bq_h+bq_n)%8] <= '{id:areq.aw.id, resp:axi_pkg::RESP_OKAY};
        bq_n <= bq_n + 1;
        if (areq.aw.atop[axi_pkg::ATOP_R_RESP]) begin
          rq[rtail%8] <= '{id:areq.aw.id, data:mem_word(areq.aw.addr),
            resp:axi_pkg::RESP_OKAY};
          rtail = rtail + 1; rq_n <= rq_n + 1;
        end
      end
      if (areq.ar_valid && arsp.ar_ready) begin
        ar_seen++;
        ar_cache = areq.ar.cache; ar_len = areq.ar.len;
        ar_size = areq.ar.size; ar_lock = areq.ar.lock; ar_addr = areq.ar.addr;
        rq[rtail%8] <= '{id:areq.ar.id, data:mem_word(areq.ar.addr),
          resp:areq.ar.lock ? axi_pkg::RESP_EXOKAY : axi_pkg::RESP_OKAY};
        rtail = rtail + 1; rq_n <= rq_n + 1;
      end
      if (arsp.r_valid && areq.r_ready) begin rq_h <= (rq_h+1)%8; rq_n <= rq_n-1; end
      if (arsp.b_valid && areq.b_ready) begin bq_h <= (bq_h+1)%8; bq_n <= bq_n-1; end
    end
  end

  always @(posedge clk) if (rst_n) cycle++;

  task automatic tick; #2; clk = 1; #2; clk = 0; #2; endtask

  // Expected attribute for a channel: `alloc` says whether this request class
  // is eligible for the allocate encoding. Under ALLOC=0 every request keeps
  // the modifiable-only stream (whole-stream identity check).
  function automatic logic [3:0] expected_cache(input bit alloc);
    logic [3:0] exp;
    exp = (alloc && ALLOC) ? ATTR_ALLOC : ATTR_MOD;
    return exp ^ (negative ? 4'h1 : 4'h0);  // oracle arm flips the expectation
  endfunction

  task automatic wait_ar(input logic [8*32-1:0] tag, input bit alloc,
                         input int blen = -1, input int size = -1);
    for (int n = 0; n < 200 && ar_seen == 0; n++) tick();
    if (ar_seen != 1) $fatal(1, "%s AR_TIMEOUT seen=%0d", tag, ar_seen);
    if (ar_cache != expected_cache(alloc))
      $fatal(1, "%s ar.cache=%h exp=%h", tag, ar_cache, expected_cache(alloc));
    if (blen >= 0 && ar_len != blen[7:0])
      $fatal(1, "%s ar.len=%0d exp=%0d", tag, ar_len, blen);
    if (size >= 0 && ar_size != size[2:0])
      $fatal(1, "%s ar.size=%0d exp=%0d", tag, ar_size, size);
    ar_seen = 0;
  endtask

  task automatic wait_aw(input logic [8*32-1:0] tag, input bit alloc);
    for (int n = 0; n < 200 && aw_seen == 0; n++) tick();
    if (aw_seen != 1) $fatal(1, "%s AW_TIMEOUT seen=%0d", tag, aw_seen);
    if (aw_cache != expected_cache(alloc))
      $fatal(1, "%s aw.cache=%h exp=%h", tag, aw_cache, expected_cache(alloc));
    aw_seen = 0;
  endtask

  task automatic send_ifill(input bit nc);
    ireq = '0; ireq.paddr = paddr_t'(P); ireq.nc = nc; ireq.tid = '0;
    ireq_vld = 1;
    for (int n = 0; n < 200; n++) begin
      #1;
      if (ireq_ack) begin tick(); ireq_vld = 0; return; end
      tick();
    end
    $fatal(1, "WT_ATTR_IFILL_REQ_TIMEOUT");
  endtask

  task automatic send_dreq(input wt_cache_pkg::dcache_out_t rtype, input bit nc,
                           input addr_t addr, input logic [2:0] size,
                           input ariane_pkg::amo_t op = AMO_NONE);
    dreq = '0;
    dreq.rtype = rtype; dreq.amo_op = op; dreq.paddr = paddr_t'(addr);
    dreq.size = size; dreq.data = 64'hdead_beef_c0ff_ee11; dreq.nc = nc; dreq.tid = '0;
    dreq_vld = 1;
    for (int n = 0; n < 200; n++) begin
      #1;
      if (dreq_ack) begin tick(); dreq_vld = 0; return; end
      tick();
    end
    $fatal(1, "WT_ATTR_REQ_TIMEOUT");
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    if (!$value$plusargs("scenario=%d", scenario)) scenario = 0;
    repeat (3) tick(); rst_n = 1; repeat (20) tick();
    case (scenario)
      // I$ fill, cacheable.
      0: begin
        send_ifill(1'b0); wait_ar("WT_ATTR_IFILL", 1);
      end
      // I$ fill, noncacheable.
      1: begin
        send_ifill(1'b1); wait_ar("WT_ATTR_NC", 0);
      end
      // D$ line fills (size[2]=1 → 16 B line, 2 beats) at each 16 B offset of
      // the 64 B L2 line: allocate attribute, blen/size unchanged.
      2: begin
        for (int off = 0; off < 64; off += 16) begin
          send_dreq(DCACHE_LOAD_REQ, 1'b0, P + off, 3'b111);
          wait_ar("WT_ATTR_DFILL", 1, 1, 3);
        end
      end
      // D$ load, noncacheable.
      3: begin
        send_dreq(DCACHE_LOAD_REQ, 1'b1, P, 3'b011); wait_ar("WT_ATTR_NC", 0);
      end
      // Store, cacheable → write-allocate attribute.
      4: begin
        send_dreq(DCACHE_STORE_REQ, 1'b0, P, 3'b011); wait_aw("WT_ATTR_STORE", 1);
      end
      // Store, noncacheable.
      5: begin
        send_dreq(DCACHE_STORE_REQ, 1'b1, P, 3'b011); wait_aw("WT_ATTR_SNC", 0);
      end
      // AMOs arrive nc=1 from the miss unit: the AW keeps the modifiable-only
      // stream and the ATOP encoding is untouched.
      6: begin
        send_dreq(DCACHE_ATOMIC_REQ, 1'b1, P, 3'b011, AMO_ADD); wait_aw("WT_ATTR_AMO", 0);
        if (aw_atop != {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_ADD})
          $fatal(1, "WT_ATTR_AMO atop=%h", aw_atop);
      end
      // LR goes out on AR with lock held.
      7: begin
        send_dreq(DCACHE_ATOMIC_REQ, 1'b1, P, 3'b011, AMO_LR); wait_ar("WT_ATTR_LR", 0);
        if (!ar_lock) $fatal(1, "WT_ATTR_LR lock=%b", ar_lock);
      end
      // SC goes out on AW with lock held.
      8: begin
        send_dreq(DCACHE_ATOMIC_REQ, 1'b1, P, 3'b011, AMO_SC); wait_aw("WT_ATTR_SC", 0);
        if (!aw_lock) $fatal(1, "WT_ATTR_SC lock=%b", aw_lock);
      end
      default: $fatal(1, "WT_ATTR_SCENARIO");
    endcase
    repeat (8) tick();
    $display("WT_ATTR_PASS scenario=%0d alloc=%0d", scenario, ALLOC);
    $finish;
  end
endmodule
