// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Two INT8 GEMMs through g6lc_ai_dram_join at island widths 128 and 512.
// The channel stays 64 bits. The even job is 2x4x16 and stores 8-byte pairs.
// The odd job is 2x3x8 and stores one 4-byte word per element. Both must
// land on the address lane, and the bytes just outside the result must stay
// put. Does not define G6LC_AI_DRAM_ISLAND_PORT and does not elaborate the
// 256-MAC island.

`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_gemm_wide;
  localparam int unsigned AW  = 64;
  localparam int unsigned DW  = 64;
  localparam int unsigned IW  = 4;
  localparam int unsigned UW  = 1;
  localparam logic [63:0] DRAM = 64'h8000_0000;
  localparam logic [63:0] PA   = DRAM;
  localparam logic [63:0] PB   = DRAM + 64'h80;
  localparam logic [63:0] PC   = DRAM + 64'h100;
  localparam logic [63:0] PAO  = DRAM + 64'h200;
  localparam logic [63:0] PBO  = DRAM + 64'h280;
  localparam logic [63:0] PCO  = DRAM + 64'h300;
  localparam logic [63:0] PAH  = DRAM + 64'h400;
  localparam logic [63:0] PBH  = DRAM + 64'h480;
  localparam logic [63:0] PCH  = DRAM + 64'h500;
  localparam logic [63:0] ONES = 64'h0101_0101_0101_0101;
  localparam logic [63:0] C16  = 64'h0000_0010_0000_0010;
  localparam logic [63:0] C8   = 64'h0000_0008_0000_0008;
  localparam logic [63:0] SENT = 64'hDEAD_BEEF_DEAD_BEEF;
  localparam int unsigned NWORDS = 1024;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  typedef logic [AW-1:0]   addr_t;
  typedef logic [IW-1:0]   id_t;
  typedef logic [UW-1:0]   user_t;
  typedef logic [127:0]    data128_t;
  typedef logic [15:0]     strb128_t;
  typedef logic [511:0]    data512_t;
  typedef logic [63:0]     strb512_t;
  `AXI_TYPEDEF_ALL(g128, addr_t, id_t, data128_t, strb128_t, user_t)
  `AXI_TYPEDEF_ALL(g512, addr_t, id_t, data512_t, strb512_t, user_t)

  logic start0, start1, ready0, ready1, done0, done1, err0, err1;
  logic [31:0] m0, n0, k0, m1, n1, k1;
  logic [15:0] lda0, ldb0, lda1, ldb1;
  logic [2:0]  nf0, nf1;
  logic [63:0] pa0, pb0, pc0, pa1, pb1, pc1;
  g128_req_t req0_q, req0;
  g128_resp_t rsp0;
  g512_req_t req1_q, req1;
  g512_resp_t rsp1;
  // GEMM flops are X until reset. Keep the island port idle so the join
  // does not accept an X address.
  assign req0 = rst_n ? req0_q : '0;
  assign req1 = rst_n ? req1_q : '0;
  logic init0, init1;
  logic [7:0][31:0] ch_r0, ch_w0, ch_r1, ch_w1;

  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      cl0 (), cl1 ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(128), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      is0 ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(512), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      is1 ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW + 1), .AXI_USER_WIDTH(UW))
      mst0 (), mst1 ();

  `AXI_ASSIGN_FROM_REQ(is0, req0)
  `AXI_ASSIGN_TO_RESP(rsp0, is0)
  `AXI_ASSIGN_FROM_REQ(is1, req1)
  `AXI_ASSIGN_TO_RESP(rsp1, is1)

  g6lc_ai_dram_join #(
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW),
      .ISLAND_DATA_WIDTH(128), .MAX_AR_OUT(2),
      .DRAM_BASE(DRAM), .DRAM_BYTES(64'h0000_1000), .FATAL_LOCK(1'b1)
  ) i_join0 (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .init_done_i(init0),
      .cluster(cl0), .island(is0), .master(mst0)
  );
  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW + 1), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(NWORDS),
      .NrChannels(1), .ChanShift(6), .MaxAROut(2)
  ) i_mem0 (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(mst0), .init_done_o(init0), .ch_r_beats_o(ch_r0), .ch_w_beats_o(ch_w0)
  );
  g6lc_ai_gemm_seq #(
      .AddrWidth(AW), .DataWidth(128), .IdWidth(IW), .MaxDim(16), .PeLanes(16),
      .MaxAROut(2), .NrChannels(1), .ChanShift(6),
      .axi_req_t(g128_req_t), .axi_resp_t(g128_resp_t)
  ) i_gemm0 (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .start_i(start0), .m_i(m0), .n_i(n0), .k_i(k0),
      .lda_i(lda0), .ldb_i(ldb0), .numfmt_i(nf0), .ar_max_i(4'd0),
      .ptr_a_i(pa0), .ptr_b_i(pb0), .ptr_c_i(pc0),
      .ready_o(ready0), .done_o(done0), .err_o(err0),
      .pmu_r_beats_o(), .pmu_w_beats_o(), .pmu_cycles_o(),
      .reuse_b_i(1'b0), .reuse_b_epoch_i(32'd0), .reuse_b_invalidate_i(1'b1),
      .pmu_reuse_b_hit_o(),
      .reuse_a_i(1'b0), .reuse_a_epoch_i(32'd0), .reuse_a_invalidate_i(1'b1),
      .pmu_reuse_a_hit_o(),
      .axi_req_o(req0_q), .axi_resp_i(rsp0)
  );

  g6lc_ai_dram_join #(
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW),
      .ISLAND_DATA_WIDTH(512), .MAX_AR_OUT(2),
      .DRAM_BASE(DRAM), .DRAM_BYTES(64'h0000_1000), .FATAL_LOCK(1'b1)
  ) i_join1 (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .init_done_i(init1),
      .cluster(cl1), .island(is1), .master(mst1)
  );
  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW + 1), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(NWORDS),
      .NrChannels(1), .ChanShift(6), .MaxAROut(2)
  ) i_mem1 (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(mst1), .init_done_o(init1), .ch_r_beats_o(ch_r1), .ch_w_beats_o(ch_w1)
  );
  g6lc_ai_gemm_seq #(
      .AddrWidth(AW), .DataWidth(512), .IdWidth(IW), .MaxDim(16), .PeLanes(64),
      .MaxAROut(2), .NrChannels(1), .ChanShift(6),
      .axi_req_t(g512_req_t), .axi_resp_t(g512_resp_t)
  ) i_gemm1 (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .start_i(start1), .m_i(m1), .n_i(n1), .k_i(k1),
      .lda_i(lda1), .ldb_i(ldb1), .numfmt_i(nf1), .ar_max_i(4'd0),
      .ptr_a_i(pa1), .ptr_b_i(pb1), .ptr_c_i(pc1),
      .ready_o(ready1), .done_o(done1), .err_o(err1),
      .pmu_r_beats_o(), .pmu_w_beats_o(), .pmu_cycles_o(),
      .reuse_b_i(1'b0), .reuse_b_epoch_i(32'd0), .reuse_b_invalidate_i(1'b1),
      .pmu_reuse_b_hit_o(),
      .reuse_a_i(1'b0), .reuse_a_epoch_i(32'd0), .reuse_a_invalidate_i(1'b1),
      .pmu_reuse_a_hit_o(),
      .axi_req_o(req1_q), .axi_resp_i(rsp1)
  );

  task automatic idle_cl(input int which);
    if (which == 0) begin
      cl0.aw_valid = 0; cl0.w_valid = 0; cl0.b_ready = 0;
      cl0.ar_valid = 0; cl0.r_ready = 0;
    end else begin
      cl1.aw_valid = 0; cl1.w_valid = 0; cl1.b_ready = 0;
      cl1.ar_valid = 0; cl1.r_ready = 0;
    end
  endtask

  task automatic wr64(input int which, input logic [63:0] addr, input logic [63:0] data);
    int guard;
    bit aw_done, w_done;
    @(negedge clk);
    aw_done = 0;
    w_done = 0;
    if (which == 0) begin
      cl0.aw_id = '0; cl0.aw_addr = addr; cl0.aw_len = 0; cl0.aw_size = 3;
      cl0.aw_burst = 1; cl0.aw_lock = 0; cl0.aw_cache = 0; cl0.aw_prot = 0;
      cl0.aw_qos = 0; cl0.aw_region = 0; cl0.aw_atop = 0; cl0.aw_user = 0;
      cl0.aw_valid = 1; cl0.b_ready = 1;
      cl0.w_data = data; cl0.w_strb = '1; cl0.w_last = 1; cl0.w_user = 0; cl0.w_valid = 1;
      guard = 0;
      while (!(aw_done && w_done) && guard < 80) begin
        @(posedge clk);
        if (cl0.aw_valid && cl0.aw_ready) aw_done = 1;
        if (cl0.w_valid && cl0.w_ready) w_done = 1;
        guard++;
        @(negedge clk);
        if (aw_done) cl0.aw_valid = 0;
        if (w_done) cl0.w_valid = 0;
      end
      if (!(aw_done && w_done)) $fatal(1, "cluster AW/W timeout %h aw %b w %b", addr, aw_done, w_done);
      guard = 0;
      do begin @(posedge clk); guard++; end while (!cl0.b_valid && guard < 80);
      if (!cl0.b_valid) $fatal(1, "cluster B timeout %h", addr);
      @(negedge clk); cl0.b_ready = 0;
    end else begin
      cl1.aw_id = '0; cl1.aw_addr = addr; cl1.aw_len = 0; cl1.aw_size = 3;
      cl1.aw_burst = 1; cl1.aw_lock = 0; cl1.aw_cache = 0; cl1.aw_prot = 0;
      cl1.aw_qos = 0; cl1.aw_region = 0; cl1.aw_atop = 0; cl1.aw_user = 0;
      cl1.aw_valid = 1; cl1.b_ready = 1;
      cl1.w_data = data; cl1.w_strb = '1; cl1.w_last = 1; cl1.w_user = 0; cl1.w_valid = 1;
      guard = 0;
      while (!(aw_done && w_done) && guard < 80) begin
        @(posedge clk);
        if (cl1.aw_valid && cl1.aw_ready) aw_done = 1;
        if (cl1.w_valid && cl1.w_ready) w_done = 1;
        guard++;
        @(negedge clk);
        if (aw_done) cl1.aw_valid = 0;
        if (w_done) cl1.w_valid = 0;
      end
      if (!(aw_done && w_done)) $fatal(1, "cluster AW/W timeout %h aw %b w %b", addr, aw_done, w_done);
      guard = 0;
      do begin @(posedge clk); guard++; end while (!cl1.b_valid && guard < 80);
      if (!cl1.b_valid) $fatal(1, "cluster B timeout %h", addr);
      @(negedge clk); cl1.b_ready = 0;
    end
  endtask

  task automatic rd64(input int which, input logic [63:0] addr, output logic [63:0] data);
    int guard;
    @(negedge clk);
    if (which == 0) begin
      cl0.ar_id = 4'h1; cl0.ar_addr = addr; cl0.ar_len = 0; cl0.ar_size = 3;
      cl0.ar_burst = 1; cl0.ar_lock = 0; cl0.ar_cache = 0; cl0.ar_prot = 0;
      cl0.ar_qos = 0; cl0.ar_region = 0; cl0.ar_user = 0;
      cl0.ar_valid = 1; cl0.r_ready = 1;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!cl0.ar_ready && guard < 80);
      if (!cl0.ar_ready) $fatal(1, "cluster AR timeout %h", addr);
      @(negedge clk); cl0.ar_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!(cl0.r_valid && cl0.r_last) && guard < 80);
      if (!(cl0.r_valid && cl0.r_last)) $fatal(1, "cluster R timeout %h", addr);
      data = cl0.r_data;
      @(negedge clk); cl0.r_ready = 0;
    end else begin
      cl1.ar_id = 4'h1; cl1.ar_addr = addr; cl1.ar_len = 0; cl1.ar_size = 3;
      cl1.ar_burst = 1; cl1.ar_lock = 0; cl1.ar_cache = 0; cl1.ar_prot = 0;
      cl1.ar_qos = 0; cl1.ar_region = 0; cl1.ar_user = 0;
      cl1.ar_valid = 1; cl1.r_ready = 1;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!cl1.ar_ready && guard < 80);
      if (!cl1.ar_ready) $fatal(1, "cluster AR timeout %h", addr);
      @(negedge clk); cl1.ar_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!(cl1.r_valid && cl1.r_last) && guard < 80);
      if (!(cl1.r_valid && cl1.r_last)) $fatal(1, "cluster R timeout %h", addr);
      data = cl1.r_data;
      @(negedge clk); cl1.r_ready = 0;
    end
  endtask

  task automatic preload(input int which);
    int r, c;
    for (r = 0; r < 2; r++) begin
      wr64(which, PA + (64'(r) * 64'd16), ONES);
      wr64(which, PA + (64'(r) * 64'd16) + 64'd8, ONES);
    end
    for (c = 0; c < 4; c++) begin
      wr64(which, PB + (64'(c) * 64'd16), ONES);
      wr64(which, PB + (64'(c) * 64'd16) + 64'd8, ONES);
    end
    for (r = 0; r < 4; r++)
      wr64(which, PC + (64'(r) * 64'd8), 64'h0);
    wr64(which, PC - 64'd8, SENT);
    wr64(which, PC + 64'd32, SENT);
  endtask

  task automatic check_c(input int which, input int unsigned w_before);
    logic [63:0] got;
    int unsigned w_now, i;
    for (i = 0; i < 4; i++) begin
      rd64(which, PC + (64'(i) * 64'd8), got);
      if (got !== C16)
        $fatal(1, "width job %0d C[%0d] exp %h got %h", which, i, C16, got);
    end
    rd64(which, PC - 64'd8, got);
    if (got !== SENT)
      $fatal(1, "width job %0d sentinel before smashed %h", which, got);
    rd64(which, PC + 64'd32, got);
    if (got !== SENT)
      $fatal(1, "width job %0d sentinel after smashed %h", which, got);
    w_now = (which == 0) ? ch_w0[0] : ch_w1[0];
    if (w_now != w_before + 4)
      $fatal(1, "width job %0d C channel beats %0d (before %0d)", which, w_now, w_before);
  endtask

  // m=2 n=3 k=8, all ones. Odd n is one 4-byte W per element (6 beats),
  // not 8-byte pairs. The 24-byte result is three channel words of C=8.
  task automatic preload_odd(input int which);
    int unsigned i;
    wr64(which, PAO, ONES);
    wr64(which, PAO + 64'd8, ONES);
    for (i = 0; i < 3; i++)
      wr64(which, PBO + (64'(i) * 64'd8), ONES);
    for (i = 0; i < 3; i++)
      wr64(which, PCO + (64'(i) * 64'd8), 64'h0);
    wr64(which, PCO - 64'd8, SENT);
    wr64(which, PCO + 64'd24, SENT);
  endtask

  task automatic check_odd(input int which, input int unsigned w_before);
    logic [63:0] got;
    int unsigned w_now, i;
    for (i = 0; i < 3; i++) begin
      rd64(which, PCO + (64'(i) * 64'd8), got);
      if (got !== C8)
        $fatal(1, "odd job %0d C word %0d exp %h got %h", which, i, C8, got);
    end
    rd64(which, PCO - 64'd8, got);
    if (got !== SENT)
      $fatal(1, "odd job %0d sentinel before smashed %h", which, got);
    rd64(which, PCO + 64'd24, got);
    if (got !== SENT)
      $fatal(1, "odd job %0d sentinel after smashed %h", which, got);
    w_now = (which == 0) ? ch_w0[0] : ch_w1[0];
    if (w_now != w_before + 6)
      $fatal(1, "odd job %0d C channel beats %0d (before %0d)", which, w_now, w_before);
  endtask

  // n=1 is a 4-byte store. C at PCH+4 is legal and must leave the
  // low half of that channel word untouched.
  localparam logic [63:0] CHI = 64'h0000_0008_DEAD_BEEF;

  task automatic preload_half(input int which);
    wr64(which, PAH, ONES);
    wr64(which, PBH, ONES);
    wr64(which, PCH, SENT);
    wr64(which, PCH + 64'd8, SENT);
  endtask

  task automatic check_half(input int which, input int unsigned w_before);
    logic [63:0] got;
    int unsigned w_now;
    rd64(which, PCH, got);
    if (got !== CHI)
      $fatal(1, "half job %0d C exp %h got %h", which, CHI, got);
    rd64(which, PCH + 64'd8, got);
    if (got !== SENT)
      $fatal(1, "half job %0d neighbor smashed %h", which, got);
    w_now = (which == 0) ? ch_w0[0] : ch_w1[0];
    if (w_now != w_before + 1)
      $fatal(1, "half job %0d C channel beats %0d (before %0d)", which, w_now, w_before);
  endtask

  // FP16 element is 2 bytes. An odd A pointer is refused before any beat.
  task automatic arm_fp16_odd(input int which);
    if (which == 0) begin
      nf0 = 3'd5;
      m0 = 32'd1; n0 = 32'd1; k0 = 32'd2;
      lda0 = 16'd2; ldb0 = 16'd2;
      pa0 = PAH + 64'h1; pb0 = PBH; pc0 = PCH;
    end else begin
      nf1 = 3'd5;
      m1 = 32'd1; n1 = 32'd1; k1 = 32'd2;
      lda1 = 16'd2; ldb1 = 16'd2;
      pa1 = PAH + 64'h1; pb1 = PBH; pc1 = PCH;
    end
  endtask

  task automatic arm_half(input int which);
    if (which == 0) begin
      nf0 = 3'd0;
      m0 = 32'd1; n0 = 32'd1; k0 = 32'd8;
      lda0 = 16'd8; ldb0 = 16'd8;
      pa0 = PAH; pb0 = PBH; pc0 = PCH + 64'h4;
    end else begin
      nf1 = 3'd0;
      m1 = 32'd1; n1 = 32'd1; k1 = 32'd8;
      lda1 = 16'd8; ldb1 = 16'd8;
      pa1 = PAH; pb1 = PBH; pc1 = PCH + 64'h4;
    end
  endtask

  task automatic arm_odd(input int which);
    if (which == 0) begin
      nf0 = 3'd0;
      m0 = 32'd2; n0 = 32'd3; k0 = 32'd8;
      lda0 = 16'd8; ldb0 = 16'd8;
      pa0 = PAO; pb0 = PBO; pc0 = PCO;
    end else begin
      nf1 = 3'd0;
      m1 = 32'd2; n1 = 32'd3; k1 = 32'd8;
      lda1 = 16'd8; ldb1 = 16'd8;
      pa1 = PAO; pb1 = PBO; pc1 = PCO;
    end
  endtask

  initial begin
    int guard;
    int unsigned wsnap;
    nf0 = 3'd0; nf1 = 3'd0;
    m0 = 32'd2; n0 = 32'd4; k0 = 32'd16; lda0 = 16'd16; ldb0 = 16'd16;
    pa0 = PA; pb0 = PB; pc0 = PC;
    m1 = 32'd2; n1 = 32'd4; k1 = 32'd16; lda1 = 16'd16; ldb1 = 16'd16;
    pa1 = PA; pb1 = PB; pc1 = PC;
    start0 = 0;
    start1 = 0;
    idle_cl(0);
    idle_cl(1);
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    preload(0);
    guard = 0;
    do begin @(posedge clk); guard++; end while (!ready0 && guard < 100);
    if (!ready0) $fatal(1, "128-bit gemm not ready");
    wsnap = ch_w0[0];
    @(negedge clk); start0 = 1;
    @(negedge clk); start0 = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!done0 && guard < 20000);
    if (!done0) $fatal(1, "128-bit gemm timeout");
    if (err0) $fatal(1, "128-bit gemm err");
    check_c(0, wsnap);

    preload(1);
    guard = 0;
    do begin @(posedge clk); guard++; end while (!ready1 && guard < 100);
    if (!ready1) $fatal(1, "512-bit gemm not ready");
    wsnap = ch_w1[0];
    @(negedge clk); start1 = 1;
    @(negedge clk); start1 = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!done1 && guard < 20000);
    if (!done1) $fatal(1, "512-bit gemm timeout");
    if (err1) $fatal(1, "512-bit gemm err");
    check_c(1, wsnap);

    arm_odd(0);
    preload_odd(0);
    guard = 0;
    do begin @(posedge clk); guard++; end while (!ready0 && guard < 100);
    if (!ready0) $fatal(1, "128-bit gemm not ready for odd n");
    wsnap = ch_w0[0];
    @(negedge clk); start0 = 1;
    @(negedge clk); start0 = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!done0 && guard < 20000);
    if (!done0) $fatal(1, "128-bit odd gemm timeout");
    if (err0) $fatal(1, "128-bit odd gemm err");
    check_odd(0, wsnap);

    arm_odd(1);
    preload_odd(1);
    guard = 0;
    do begin @(posedge clk); guard++; end while (!ready1 && guard < 100);
    if (!ready1) $fatal(1, "512-bit gemm not ready for odd n");
    wsnap = ch_w1[0];
    @(negedge clk); start1 = 1;
    @(negedge clk); start1 = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!done1 && guard < 20000);
    if (!done1) $fatal(1, "512-bit odd gemm timeout");
    if (err1) $fatal(1, "512-bit odd gemm err");
    check_odd(1, wsnap);

    arm_half(0);
    preload_half(0);
    guard = 0;
    do begin @(posedge clk); guard++; end while (!ready0 && guard < 100);
    if (!ready0) $fatal(1, "128-bit gemm not ready for half C");
    wsnap = ch_w0[0];
    @(negedge clk); start0 = 1;
    @(negedge clk); start0 = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!done0 && guard < 20000);
    if (!done0) $fatal(1, "128-bit half gemm timeout");
    if (err0) $fatal(1, "128-bit half gemm err");
    check_half(0, wsnap);

    arm_half(1);
    preload_half(1);
    guard = 0;
    do begin @(posedge clk); guard++; end while (!ready1 && guard < 100);
    if (!ready1) $fatal(1, "512-bit gemm not ready for half C");
    wsnap = ch_w1[0];
    @(negedge clk); start1 = 1;
    @(negedge clk); start1 = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!done1 && guard < 20000);
    if (!done1) $fatal(1, "512-bit half gemm timeout");
    if (err1) $fatal(1, "512-bit half gemm err");
    check_half(1, wsnap);

    begin
      int unsigned rsnap;
      arm_fp16_odd(0);
      guard = 0;
      do begin @(posedge clk); guard++; end while (!ready0 && guard < 100);
      if (!ready0) $fatal(1, "128-bit gemm not ready for odd FP16");
      wsnap = ch_w0[0];
      rsnap = ch_r0[0];
      @(negedge clk); start0 = 1;
      @(negedge clk); start0 = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!done0 && guard < 200);
      if (!done0) $fatal(1, "128-bit odd FP16 timeout");
      if (!err0 || ch_w0[0] != wsnap || ch_r0[0] != rsnap)
        $fatal(1, "128-bit odd FP16 err %b w %0d r %0d", err0, ch_w0[0], ch_r0[0]);

      arm_fp16_odd(1);
      guard = 0;
      do begin @(posedge clk); guard++; end while (!ready1 && guard < 100);
      if (!ready1) $fatal(1, "512-bit gemm not ready for odd FP16");
      wsnap = ch_w1[0];
      rsnap = ch_r1[0];
      @(negedge clk); start1 = 1;
      @(negedge clk); start1 = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!done1 && guard < 200);
      if (!done1) $fatal(1, "512-bit odd FP16 timeout");
      if (!err1 || ch_w1[0] != wsnap || ch_r1[0] != rsnap)
        $fatal(1, "512-bit odd FP16 err %b w %0d r %0d", err1, ch_w1[0], ch_r1[0]);
    end

    $display("PASS tb_g6lc_ai_gemm_wide");
    $finish;
  end
endmodule
