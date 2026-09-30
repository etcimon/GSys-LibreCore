// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Descriptor flags reach the sequencer when VaTurboEn is set on this
// instance. The live package leaves that bit clear. The tile is the
// panel box in M and N (1024×512) with 8 MAC/cycle, not the live array.
// Bit 23 skips a resident A at m=1024, bit 15 skips a resident B at
// n=512, both bits together issue no operand read, and n=128 does not
// hit a resident 512. A later k=16 B stays resident and the dot is 16;
// the same flag with k=8 reads B again. A different B pointer or
// stride reads that operand again, and the following job with the new
// key skips it. Format is in the key: INT4 on the same bytes is 20,
// and switching back to INT8 reads the operand again and the dot is
// 8712. An A pointer moved by 32 bytes reads A again, and the next
// job with that pointer skips it. C is the dot of the bytes that
// were actually fetched. A SLVERR on a B beat drops the key: the
// next reuse request reads B again, and the job after that skips it.
// A SLVERR on the C store does the same after a hit: the key drops,
// the next request reads B, and the one after skips it.
// Odd n=3 stores single i32s. A later taller M skips B, and the
// tail element C[0][2] stays 1.

`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_desc_reuse;
  // Resident-B directory depth under test (the shipped island keeps 2 panels).
  parameter int unsigned REUSE_SLOTS = 2;
  import g6lc_ai_desc_pkg::*;
  import g6lc_ai_island_cfg_pkg::*;
  import config_pkg::*;

  localparam int unsigned AW = 64;
  localparam int unsigned DW = 64;
  localparam int unsigned IW = 4;
  localparam int unsigned UW = 1;
  localparam int unsigned MEM_WORDS = 4096;
  localparam logic [63:0] BASE = 64'h8000_0000;
  localparam logic [63:0] PA   = BASE;
  localparam logic [63:0] PB   = BASE + 64'h800;
  localparam logic [63:0] PC   = BASE + 64'h1000;
  localparam logic [63:0] PD   = BASE + 64'h5000;
  localparam logic [63:0] WIN  = BASE + 64'h5800;
  localparam logic [63:0] C_ONE = 64'h0000_0001_0000_0001;
  localparam logic [63:0] C_K16 = 64'h0000_0010_0000_0010;
  localparam logic [63:0] C_K8  = 64'h0000_0008_0000_0008;
  // k=8, A ones, B twos: 16. lda=16 row 1 is threes: 48.
  // ldb=16 column 1 is ones: row 0 is {8, 16}, row 1 is {24, 48}.
  localparam logic [63:0] C_LDA1 = 64'h0000_0030_0000_0030;
  localparam logic [63:0] C_LDB0 = 64'h0000_0008_0000_0010;
  localparam logic [63:0] C_LDB1 = 64'h0000_0018_0000_0030;
  // Byte 0x21. INT4 nibbles 1 and 2, k=8: 4 bytes * (1*1+2*2) = 20.
  // INT8: 8 bytes * 33*33 = 8712.
  localparam logic [31:0] FMT_INT4 = 32'h1 << FLAG_NUMFMT_SHIFT;
  localparam logic [63:0] C_I4 = 64'h0000_0014_0000_0014;
  localparam logic [63:0] C_I8 = 64'h0000_2208_0000_2208;
  // A ones at the moved pointer, B still 0x21: 8*1*33 = 264.
  localparam logic [63:0] C_AP = 64'h0000_0108_0000_0108;
  // Completion word is {0, status, ticket}. GEMM commits ST_OK before
  // the completion response can fail.
  localparam logic [63:0] CPL_OK_42 = 64'h0000_0000_0000_002A;
  // A C-store failure is a GEMM error, so the completion word carries it.
  localparam logic [63:0] CPL_ERR_36 = 64'h0000_0001_0000_0024;
  localparam logic [31:0] REUSE_B = 32'h1 << FLAG_REUSE_B_SHIFT;
  localparam logic [31:0] REUSE_A = 32'h1 << FLAG_REUSE_A_SHIFT;

  function automatic ai_island_cfg_t reuse_island();
    reuse_island = AiIslandLatencyDefault;
    reuse_island.MacsPerCycle = 32'd8;
    reuse_island.AccTileM = 32'd1024;
    reuse_island.AccTileN = 32'd512;
    reuse_island.AccTileK = 32'd16;
  endfunction

  localparam ai_island_cfg_t Island = reuse_island();
  localparam ai_cfg_t AiCfgReuse = AiCfgVaTurboTest;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  typedef logic [AW-1:0] addr_t;
  typedef logic [IW-1:0] id_t;
  typedef logic [UW-1:0] user_t;
  typedef logic [DW-1:0] data_t;
  typedef logic [DW/8-1:0] strb_t;
  `AXI_TYPEDEF_ALL(gd, addr_t, id_t, data_t, strb_t, user_t)

  gd_req_t  dma_req, dma_req_g;
  gd_resp_t dma_rsp, dma_rsp_g;
  assign dma_req_g = rst_n ? dma_req : '0;
  assign dma_rsp_g = rst_n ? dma_rsp : '0;

  logic psel, penable, pwrite, pready, pslverr, irq;
  logic [31:0] paddr, pwdata, prdata;
  logic [DW-1:0] mem [0:MEM_WORDS-1];
  int unsigned ar_a, ar_b;
  int unsigned errors;
  logic        poke_we;
  logic        b_slverr;
  logic        c_slverr;
  logic        a_slverr;
  logic        d_slverr;
  logic [63:0] poke_addr, poke_data;

  typedef enum logic [1:0] { RD_IDLE, RD_DATA } rd_e;
  typedef enum logic [1:0] { WR_IDLE, WR_DATA, WR_RESP } wr_e;
  rd_e rd_q;
  wr_e wr_q;
  addr_t ar_addr_q, aw_addr_q;
  logic [7:0] ar_len_q, aw_len_q, rd_beat, wr_beat;
  id_t ar_id_q, aw_id_q;

  function automatic int unsigned widx(input logic [63:0] addr, input int unsigned beat);
    widx = int'(((addr - BASE) >> 3) + beat);
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_q <= RD_IDLE;
      wr_q <= WR_IDLE;
      ar_a <= 0;
      ar_b <= 0;
      rd_beat <= '0;
      wr_beat <= '0;
      // Blocking: Verilator rejects a delayed array assign in a for loop.
      for (int wi = 0; wi < MEM_WORDS; wi++) mem[wi] = '0;
      // 1024 bytes of A and 512 bytes of B, one byte per row at k=1.
      for (int wi = 0; wi < 128; wi++)
        mem[widx(PA, wi)] = 64'h0101_0101_0101_0101;
      for (int wi = 0; wi < 64; wi++)
        mem[widx(PB, wi)] = 64'h0101_0101_0101_0101;
    end else begin
      if (poke_we && widx(poke_addr, 0) < MEM_WORDS)
        mem[widx(poke_addr, 0)] <= poke_data;
      if (rd_q == RD_IDLE && dma_req_g.ar_valid && dma_rsp_g.ar_ready) begin
        rd_q <= RD_DATA;
        ar_addr_q <= dma_req_g.ar.addr;
        ar_len_q <= dma_req_g.ar.len;
        ar_id_q <= dma_req_g.ar.id;
        rd_beat <= '0;
        if (dma_req_g.ar.addr >= PA && dma_req_g.ar.addr < PB)
          ar_a <= ar_a + 1;
        else if (dma_req_g.ar.addr >= PB && dma_req_g.ar.addr < PC)
          ar_b <= ar_b + 1;
      end else if (rd_q == RD_DATA && dma_req_g.r_ready) begin
        if (b_slverr && ar_addr_q >= PB && ar_addr_q < PC)
          b_slverr <= 1'b0;
        if (a_slverr && ar_addr_q >= PA && ar_addr_q < PB)
          a_slverr <= 1'b0;
        if (rd_beat == ar_len_q) rd_q <= RD_IDLE;
        else rd_beat <= rd_beat + 8'd1;
      end

      if (wr_q == WR_IDLE && dma_req_g.aw_valid && dma_rsp_g.aw_ready) begin
        wr_q <= WR_DATA;
        aw_addr_q <= dma_req_g.aw.addr;
        aw_len_q <= dma_req_g.aw.len;
        aw_id_q <= dma_req_g.aw.id;
        wr_beat <= '0;
      end else if (wr_q == WR_DATA && dma_req_g.w_valid && dma_rsp_g.w_ready) begin
        if (widx(aw_addr_q, wr_beat) < MEM_WORDS) begin
          for (int b = 0; b < 8; b++) begin
            if (dma_req_g.w.strb[b])
              mem[widx(aw_addr_q, wr_beat)][8*b +: 8] <= dma_req_g.w.data[8*b +: 8];
          end
        end
        if (dma_req_g.w.last || wr_beat == aw_len_q) wr_q <= WR_RESP;
        else wr_beat <= wr_beat + 8'd1;
      end else if (wr_q == WR_RESP && dma_req_g.b_ready) begin
        if (c_slverr && aw_addr_q >= PC && aw_addr_q < PD)
          c_slverr <= 1'b0;
        if (d_slverr && aw_addr_q >= PD && aw_addr_q < WIN)
          d_slverr <= 1'b0;
        wr_q <= WR_IDLE;
      end
    end
  end

  always_comb begin
    automatic int unsigned ri;
    dma_rsp = '0;
    dma_rsp.aw_ready = (wr_q == WR_IDLE);
    dma_rsp.w_ready = (wr_q == WR_DATA);
    dma_rsp.ar_ready = (rd_q == RD_IDLE);
    dma_rsp.b_valid = (wr_q == WR_RESP);
    dma_rsp.b.id = aw_id_q;
    dma_rsp.r_valid = (rd_q == RD_DATA);
    dma_rsp.r.id = ar_id_q;
    dma_rsp.r.last = (rd_beat == ar_len_q);
    ri = widx(ar_addr_q, rd_beat);
    dma_rsp.r.data = (ri < MEM_WORDS) ? mem[ri] : '0;
    // One B beat returns SLVERR. resp[1] drops the resident key.
    if (b_slverr && ar_addr_q >= PB && ar_addr_q < PC)
      dma_rsp.r.resp = 2'b10;
    if (a_slverr && ar_addr_q >= PA && ar_addr_q < PB)
      dma_rsp.r.resp = 2'b10;
    // One C-store beat returns SLVERR. The completion word is at PD.
    if (c_slverr && wr_q == WR_RESP && aw_addr_q >= PC && aw_addr_q < PD)
      dma_rsp.b.resp = 2'b10;
    // The completion word is at PD, after GEMM has committed the key.
    if (d_slverr && wr_q == WR_RESP && aw_addr_q >= PD && aw_addr_q < WIN)
      dma_rsp.b.resp = 2'b10;
  end

  g6lc_ai_island_apb #(
      .AiCfg(AiCfgReuse),
      .IslandCfg(Island),
      .ReuseBSlots(REUSE_SLOTS),
      .EnableDmaFetch(1'b1),
      .AxiDataWidth(DW),
      .AxiIdWidth(IW),
      .axi_req_t(gd_req_t),
      .axi_resp_t(gd_resp_t)
  ) i_island (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
      .paddr_i(paddr), .pwdata_i(pwdata),
      .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr), .irq_o(irq),
      .sb_enq_valid_i(1'b0), .sb_enq_ready_o(), .sb_qid_i('0), .sb_ticket_i('0), .sb_desc_ptr_i('0),
      .sb_last_ticket_o(), .sb_last_status_o(), .sb_has_completion_o(), .sb_retired_valid_o(), .sb_retired_ticket_o(), .dma_inval_valid_o(), .dma_inval_addr_o(), .dma_inval_ready_i(1'b0), .dma_inval_done_i(1'b0),
      .axi_dma_req_o(dma_req), .axi_dma_resp_i(dma_rsp_g),
      .dram_init_done_i(1'b1),
      .ch_r_beats_i('0), .ch_w_beats_i('0)
  );

  task automatic apb_write(input logic [15:0] addr, input logic [31:0] data);
    int guard;
    @(negedge clk);
    psel = 1; penable = 0; pwrite = 1; paddr = {16'b0, addr}; pwdata = data;
    @(posedge clk);
    @(negedge clk);
    penable = 1;
    guard = 0;
    do begin
      @(posedge clk);
      guard++;
      @(negedge clk);
    end while (!pready && guard < 30);
    if (!pready) $fatal(1, "apb write timeout %h", addr);
    psel = 0; penable = 0; pwrite = 0;
  endtask

  task automatic apb_read(input logic [15:0] addr, output logic [31:0] data);
    int guard;
    @(negedge clk);
    psel = 1; penable = 0; pwrite = 0; paddr = {16'b0, addr}; pwdata = '0;
    @(posedge clk);
    @(negedge clk);
    penable = 1;
    guard = 0;
    do begin
      @(posedge clk);
      guard++;
      @(negedge clk);
    end while (!pready && guard < 30);
    if (!pready) $fatal(1, "apb read timeout %h", addr);
    data = prdata;
    psel = 0; penable = 0;
  endtask

  task automatic wait_cpl(output logic [31:0] ticket, output logic [31:0] status);
    logic [31:0] sticky;
    int polls;
    sticky = '0;
    polls = 0;
    while (!(sticky & 32'h1) && polls < 200000) begin
      apb_read(16'h010C, sticky);
      polls++;
    end
    if (!(sticky & 32'h1)) $fatal(1, "completion timeout");
    apb_read(16'h0110, ticket);
    apb_read(16'h0114, status);
  endtask

  task automatic retire_cpl;
    logic [31:0] sticky;
    int polls;
    apb_write(16'h010C, 32'h1);
    sticky = 32'h1;
    polls = 0;
    while ((sticky & 32'h1) && polls < 40) begin
      apb_read(16'h010C, sticky);
      polls++;
    end
  endtask

  task automatic latch_gemm_at(
      input logic [31:0] flags, m, n, k,
      input logic [63:0] ptr_a, ptr_b,
      input logic [15:0] lda, ldb
  );
    desc_t d;
    desc_bits_t bits;
    int unsigned wi;
    d = '0;
    d.version = 16'(ContractVersion);
    d.op = OP_GEMM;
    d.flags = flags;
    d.m = m; d.n = n; d.k = k;
    d.ld_ab = {ldb, lda};
    d.ptr_a = ptr_a; d.ptr_b = ptr_b; d.ptr_c = PC; d.ptr_done = PD;
    bits = desc_to_bits(d);
    for (wi = 0; wi < 16; wi++)
      apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
  endtask

  task automatic latch_gemm(
      input logic [31:0] flags, m, n, k
  );
    latch_gemm_at(flags, m, n, k, PA, PB, 16'(k), 16'(k));
  endtask

  task automatic poke(input logic [63:0] addr, input logic [63:0] data);
    @(negedge clk);
    poke_addr = addr;
    poke_data = data;
    poke_we = 1'b1;
    @(posedge clk);
    @(negedge clk);
    poke_we = 1'b0;
  endtask

  task automatic expect_w(
      input string tag, input logic [63:0] addr, input logic [63:0] exp
  );
    if (mem[widx(addr, 0)] !== exp) begin
      $error("%s C @%h got %h exp %h", tag, addr, mem[widx(addr, 0)], exp);
      errors++;
    end
  endtask

  task automatic expect_c(input string tag, input logic [63:0] addr);
    expect_w(tag, addr, C_ONE);
  endtask

  initial begin
    logic [31:0] ticket, status;
    int unsigned a0, b0, da, db;
    if (!AiCfgVaTurboTest.VaTurboEn || !AiCfgVaTurboTest.PolicySubcodeEn ||
        !AiCfgVaTurboTest.PolicyBenefitEn || !AiCfgVaTurboTest.PolicyCodecEn ||
        !AiCfgVaTurboTest.IslandFpEn || !AiCfgVaTurboTest.MatrixEn) begin
      $fatal(1, "AiCfgVaTurboTest lost a required gate");
    end
    errors = 0;
    psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;
    poke_we = 1'b0;
    poke_addr = '0;
    poke_data = '0;
    b_slverr = 1'b0;
    c_slverr = 1'b0;
    a_slverr = 1'b0;
    d_slverr = 1'b0;
    rst_n = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    apb_write(16'h0100, 32'h3);
    apb_write(16'h0120, 32'(BASE));
    apb_write(16'h0124, 32'(BASE >> 32));
    apb_write(16'h0128, 32'(WIN));
    apb_write(16'h012C, 32'(WIN >> 32));
    apb_write(16'h0130, 32'h3);

    // Prime A at m=1024, n=2. Both operands are fetched.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'(1023) * 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(32'h0, 32'd1024, 32'd2, 32'd1);
    apb_write(16'h0108, 32'h0000_0100);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd1 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("prime-a t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("prime-a", PC);
    expect_c("prime-a-last", PC + 64'(1023) * 64'd8);
    retire_cpl();

    // Same A, wider N. Bit 23 skips A.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'(1023) * 64'd16, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(REUSE_A, 32'd1024, 32'd4, 32'd1);
    apb_write(16'h0108, 32'h0000_0200);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd2 || status[15:0] != ST_OK || da != 0 || db == 0) begin
      $error("hit-a t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("hit-a", PC);
    expect_c("hit-a-last", PC + 64'(1023) * 64'd16);
    retire_cpl();

    // Prime B at n=512, m=2. M changed, so A is fetched too.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'(510) * 64'd4, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(32'h0, 32'd2, 32'd512, 32'd1);
    apb_write(16'h0108, 32'h0000_0300);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd3 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("prime-b t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("prime-b", PC);
    expect_c("prime-b-last", PC + 64'(510) * 64'd4);
    retire_cpl();

    // Same B, taller M. Bit 15 skips B.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'(7) * 64'(512) * 64'd4, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(REUSE_B, 32'd8, 32'd512, 32'd1);
    apb_write(16'h0108, 32'h0000_0400);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd4 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("hit-b t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("hit-b", PC);
    expect_c("hit-b-last", PC + 64'(7) * 64'(512) * 64'd4);
    retire_cpl();

    // Both keys match. Both flags skip both operand reads.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'(7) * 64'(512) * 64'd4, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(REUSE_A | REUSE_B, 32'd8, 32'd512, 32'd1);
    apb_write(16'h0108, 32'h0000_0500);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd5 || status[15:0] != ST_OK || da != 0 || db != 0) begin
      $error("both t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("both", PC);
    expect_c("both-last", PC + 64'(7) * 64'(512) * 64'd4);
    retire_cpl();

    // N=128 is not the resident 512. B is fetched again.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(REUSE_B, 32'd8, 32'd128, 32'd1);
    apb_write(16'h0108, 32'h0000_0600);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd6 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("miss-n t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("miss-n", PC);
    retire_cpl();

    // k=16 is two MAC steps on 8 lanes. Both operands are fetched.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd48, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(32'h0, 32'd4, 32'd4, 32'd16);
    apb_write(16'h0108, 32'h0000_0700);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd7 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("prime-k t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("prime-k", PC, C_K16);
    expect_w("prime-k-last", PC + 64'd48, C_K16);
    retire_cpl();

    // Same B and k, shorter M. Bit 15 skips B. The dot stays 16.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd16, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(REUSE_B, 32'd2, 32'd4, 32'd16);
    apb_write(16'h0108, 32'h0000_0800);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd8 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("hit-k t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-k", PC, C_K16);
    expect_w("hit-k-last", PC + 64'd16, C_K16);
    retire_cpl();

    // Same N, shorter K. The flag is set and B is still read.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd16, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(REUSE_B, 32'd2, 32'd4, 32'd8);
    apb_write(16'h0108, 32'h0000_0900);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd9 || status[15:0] != ST_OK || db == 0) begin
      $error("miss-k t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-k", PC, C_K8);
    expect_w("miss-k-last", PC + 64'd16, C_K8);
    retire_cpl();

    // The installed k is 8. Bit 23 skips A. A wider N reads B.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(REUSE_A, 32'd2, 32'd2, 32'd8);
    apb_write(16'h0108, 32'h0000_0A00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd10 || status[15:0] != ST_OK || da != 0 || db == 0) begin
      $error("hit-a-k t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-a-k", PC, C_K8);
    expect_w("hit-a-k-last", PC + 64'd8, C_K8);
    retire_cpl();

    // Both keys match at k=8. No operand read, and the dot stays 8.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm(REUSE_A | REUSE_B, 32'd2, 32'd2, 32'd8);
    apb_write(16'h0108, 32'h0000_0B00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd11 || status[15:0] != ST_OK || da != 0 || db != 0) begin
      $error("both-k t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("both-k", PC, C_K8);
    expect_w("both-k-last", PC + 64'd8, C_K8);
    retire_cpl();

    // B moves by 64 bytes and becomes twos. The flag is set, and B is read.
    poke(PB + 64'd64, 64'h0202_0202_0202_0202);
    poke(PB + 64'd72, 64'h0202_0202_0202_0202);
    poke(PB + 64'd80, 64'h0101_0101_0101_0101);
    poke(PA + 64'd16, 64'h0303_0303_0303_0303);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8, PA, PB + 64'd64, 16'd8, 16'd8);
    apb_write(16'h0108, 32'h0000_0C00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd12 || status[15:0] != ST_OK || db == 0) begin
      $error("miss-ptr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-ptr", PC, C_K16);
    expect_w("miss-ptr-last", PC + 64'd8, C_K16);
    retire_cpl();

    // Same new pointer. Bit 15 skips B. The twos stay resident.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8, PA, PB + 64'd64, 16'd8, 16'd8);
    apb_write(16'h0108, 32'h0000_0D00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd13 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("hit-ptr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-ptr", PC, C_K16);
    expect_w("hit-ptr-last", PC + 64'd8, C_K16);
    retire_cpl();

    // lda 8 to 16. Row 1 is threes. The flag is set, and A is read.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8, PA, PB + 64'd64, 16'd16, 16'd8);
    apb_write(16'h0108, 32'h0000_0E00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd14 || status[15:0] != ST_OK || da == 0) begin
      $error("miss-lda t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-lda", PC, C_K16);
    expect_w("miss-lda-last", PC + 64'd8, C_LDA1);
    retire_cpl();

    // Same lda. Bit 23 skips A. Row 1 stays 48.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8, PA, PB + 64'd64, 16'd16, 16'd8);
    apb_write(16'h0108, 32'h0000_0F00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd15 || status[15:0] != ST_OK || da != 0 || db == 0) begin
      $error("hit-lda t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-lda", PC, C_K16);
    expect_w("hit-lda-last", PC + 64'd8, C_LDA1);
    retire_cpl();

    // ldb 8 to 16. Column 1 is ones. The flag is set, and B is read.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8, PA, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1000);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd16 || status[15:0] != ST_OK || db == 0) begin
      $error("miss-ldb t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-ldb", PC, C_LDB0);
    expect_w("miss-ldb-last", PC + 64'd8, C_LDB1);
    retire_cpl();

    // Same ldb. Bit 15 skips B. Column 1 stays ones.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8, PA, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1100);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd17 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("hit-ldb t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-ldb", PC, C_LDB0);
    expect_w("hit-ldb-last", PC + 64'd8, C_LDB1);
    retire_cpl();

    // Same shape, byte 0x21. INT4 does not match the resident INT8 key.
    poke(PA, 64'h2121_2121_2121_2121);
    poke(PA + 64'd8, 64'h2121_2121_2121_2121);
    poke(PA + 64'd16, 64'h2121_2121_2121_2121);
    poke(PA + 64'd24, 64'h2121_2121_2121_2121);
    poke(PB + 64'd64, 64'h2121_2121_2121_2121);
    poke(PB + 64'd72, 64'h2121_2121_2121_2121);
    poke(PB + 64'd80, 64'h2121_2121_2121_2121);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B | FMT_INT4, 32'd2, 32'd2, 32'd8,
                  PA, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1200);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd18 || status[15:0] != ST_OK || db == 0) begin
      $error("miss-fmt t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-fmt", PC, C_I4);
    expect_w("miss-fmt-last", PC + 64'd8, C_I4);
    retire_cpl();

    // Resident INT4 B. The flag skips B and the dot stays 20.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B | FMT_INT4, 32'd2, 32'd2, 32'd8,
                  PA, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1300);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd19 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("hit-fmt t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-fmt", PC, C_I4);
    expect_w("hit-fmt-last", PC + 64'd8, C_I4);
    retire_cpl();

    // Back to INT8. A's key is INT4, so the flag does not skip A.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8, PA, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1400);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd20 || status[15:0] != ST_OK || da == 0) begin
      $error("miss-fmt-a t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-fmt-a", PC, C_I8);
    expect_w("miss-fmt-a-last", PC + 64'd8, C_I8);
    retire_cpl();

    // Resident INT8 A. The flag skips A and the dot stays 8712.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8, PA, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1500);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd21 || status[15:0] != ST_OK || da != 0 || db == 0) begin
      $error("hit-fmt-a t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-fmt-a", PC, C_I8);
    expect_w("hit-fmt-a-last", PC + 64'd8, C_I8);
    retire_cpl();

    // A moves by 32 bytes and is ones. The flag is set, and A is read.
    poke(PA + 64'd32, 64'h0101_0101_0101_0101);
    poke(PA + 64'd48, 64'h0101_0101_0101_0101);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1600);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd22 || status[15:0] != ST_OK || da == 0) begin
      $error("miss-aptr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-aptr", PC, C_AP);
    expect_w("miss-aptr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // Same new A pointer. Bit 23 skips A. The ones stay resident.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1700);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd23 || status[15:0] != ST_OK || da != 0 || db == 0) begin
      $error("hit-aptr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-aptr", PC, C_AP);
    expect_w("hit-aptr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // Same shape, but the B beat is SLVERR. The key must not survive.
    b_slverr = 1'b1;
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1800);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd24 || status[15:0] != ST_ERR || db == 0 || b_slverr) begin
      $error("slverr t=%0d st=%h arA=%0d arB=%0d arm=%0d",
             ticket, status, da, db, b_slverr);
      errors++;
    end
    b_slverr = 1'b0;
    retire_cpl();

    // The flag is set and B is read again. The dot is 264.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1900);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd25 || status[15:0] != ST_OK || db == 0) begin
      $error("miss-slverr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-slverr", PC, C_AP);
    expect_w("miss-slverr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // The reloaded key skips B.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1A00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd26 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("hit-slverr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-slverr", PC, C_AP);
    expect_w("hit-slverr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // B is resident, so this job does not read it. The C store is SLVERR.
    c_slverr = 1'b1;
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1B00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd27 || status[15:0] != ST_ERR || db != 0 || c_slverr) begin
      $error("wslverr t=%0d st=%h arA=%0d arB=%0d arm=%0d",
             ticket, status, da, db, c_slverr);
      errors++;
    end
    c_slverr = 1'b0;
    retire_cpl();

    // The flag is set and B is read again. The dot is 264.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1C00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd28 || status[15:0] != ST_OK || db == 0) begin
      $error("miss-wslverr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-wslverr", PC, C_AP);
    expect_w("miss-wslverr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // The reloaded key skips B.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_1D00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd29 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("hit-wslverr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-wslverr", PC, C_AP);
    expect_w("hit-wslverr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // Odd n. The first row's third element shares a beat with the next row.
    poke(PA, 64'h0101_0101_0101_0101);
    poke(PB, 64'h0101_0101_0101_0101);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd16, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd2, 32'd3, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_1E00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd30 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("odd t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("odd", PC, C_ONE);
    expect_w("odd-tail", PC + 64'd8, C_ONE);
    expect_w("odd-last", PC + 64'd16, C_ONE);
    retire_cpl();

    // Taller M, same odd N. B is not read. The tail stays 1.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd40, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd4, 32'd3, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_1F00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd31 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("odd-hit t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("odd-hit", PC, C_ONE);
    expect_w("odd-hit-tail", PC + 64'd8, C_ONE);
    expect_w("odd-hit-last", PC + 64'd40, C_ONE);
    retire_cpl();

    // Install both keys, then fail the A read while B is skipped.
    poke(PA + 64'd32, 64'h0101_0101_0101_0101);
    poke(PA + 64'd48, 64'h0101_0101_0101_0101);
    poke(PB + 64'd64, 64'h2121_2121_2121_2121);
    poke(PB + 64'd72, 64'h2121_2121_2121_2121);
    poke(PB + 64'd80, 64'h2121_2121_2121_2121);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2000);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd32 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("asl-prime t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("asl-prime", PC, C_AP);
    retire_cpl();

    // The A beat is SLVERR while B was eligible to skip. The error
    // cancels that skip, so B is read too, and neither key may survive.
    a_slverr = 1'b1;
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2100);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd33 || status[15:0] != ST_ERR || da == 0 || db == 0 || a_slverr) begin
      $error("aslverr t=%0d st=%h arA=%0d arB=%0d arm=%0d",
             ticket, status, da, db, a_slverr);
      errors++;
    end
    a_slverr = 1'b0;
    retire_cpl();

    // The failed job does not leave B resident.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2200);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd34 || status[15:0] != ST_OK || db == 0) begin
      $error("miss-aslverr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-aslverr", PC, C_AP);
    expect_w("miss-aslverr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // That reload leaves B resident. The next request skips it.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2300);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd35 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("hit-aslverr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-aslverr", PC, C_AP);
    expect_w("hit-aslverr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // Both operands are resident. The C store is SLVERR and neither
    // key may survive. No operand read is allowed on this job.
    // The completion word is written after that GEMM error.
    c_slverr = 1'b1;
    poke(PD, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A | REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2400);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd36 || status[15:0] != ST_ERR || da != 0 || db != 0 || c_slverr) begin
      $error("wboth t=%0d st=%h arA=%0d arB=%0d arm=%0d",
             ticket, status, da, db, c_slverr);
      errors++;
    end
    expect_w("wboth-word", PD, CPL_ERR_36);
    c_slverr = 1'b0;
    retire_cpl();

    // Both flags are set, and both operands are read again.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A | REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2500);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd37 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("miss-wboth t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-wboth", PC, C_AP);
    expect_w("miss-wboth-last", PC + 64'd8, C_AP);
    retire_cpl();

    // The reload leaves both resident.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A | REUSE_B, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2600);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd38 || status[15:0] != ST_OK || da != 0 || db != 0) begin
      $error("hit-wboth t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-wboth", PC, C_AP);
    expect_w("hit-wboth-last", PC + 64'd8, C_AP);
    retire_cpl();

    // A is already skipped before B is loaded. The B beat is SLVERR.
    // This job must not read A, and it must not leave A resident.
    b_slverr = 1'b1;
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2700);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd39 || status[15:0] != ST_ERR || da != 0 || db == 0 || b_slverr) begin
      $error("bslverr t=%0d st=%h arA=%0d arB=%0d arm=%0d",
             ticket, status, da, db, b_slverr);
      errors++;
    end
    b_slverr = 1'b0;
    retire_cpl();

    // The failed B read dropped A. The next request reads A again.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2800);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd40 || status[15:0] != ST_OK || da == 0) begin
      $error("miss-bslverr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("miss-bslverr", PC, C_AP);
    expect_w("miss-bslverr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // That reload leaves A resident.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2900);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd41 || status[15:0] != ST_OK || da != 0 || db == 0) begin
      $error("hit-bslverr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-bslverr", PC, C_AP);
    expect_w("hit-bslverr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // A is resident. GEMM skips A and writes C. Only the completion
    // word fails, so the key must still be there afterward.
    d_slverr = 1'b1;
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PD, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2A00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd42 || status[15:0] != ST_ERR || da != 0 || db == 0 || d_slverr) begin
      $error("cplerr t=%0d st=%h arA=%0d arB=%0d arm=%0d",
             ticket, status, da, db, d_slverr);
      errors++;
    end
    expect_w("cplerr", PC, C_AP);
    expect_w("cplerr-last", PC + 64'd8, C_AP);
    // Sticky status is ST_ERR. The stored word still says ST_OK.
    expect_w("cplerr-word", PD, CPL_OK_42);
    d_slverr = 1'b0;
    retire_cpl();

    // The completion failure did not drop A.
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd8, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd2, 32'd2, 32'd8,
                  PA + 64'd32, PB + 64'd64, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2B00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd43 || status[15:0] != ST_OK || da != 0 || db == 0) begin
      $error("hit-cplerr t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("hit-cplerr", PC, C_AP);
    expect_w("hit-cplerr-last", PC + 64'd8, C_AP);
    retire_cpl();

    // Host plan_gemm_s8_va_turbo_test on 16x8x8: two 8x8 panels, lda=k=8.
    // The second panel starts at A row 8 and requests resident B.
    for (int wi = 0; wi < 16; wi++) poke(PA + 64'(wi) * 64'd8, 64'h0101_0101_0101_0101);
    for (int wi = 0; wi < 8; wi++) poke(PB + 64'(wi) * 64'd8, 64'h0101_0101_0101_0101);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd248, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd8, 32'd8, 32'd8, PA, PB, 16'd8, 16'd8);
    apb_write(16'h0108, 32'h0000_2C00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd44 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("sched t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("sched", PC, C_K8);
    expect_w("sched-last", PC + 64'd248, C_K8);
    retire_cpl();

    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd248, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd8, 32'd8, 32'd8, PA + 64'd64, PB, 16'd8, 16'd8);
    apb_write(16'h0108, 32'h0000_2D00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd45 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("sched-b t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("sched-b", PC, C_K8);
    expect_w("sched-b-last", PC + 64'd248, C_K8);
    retire_cpl();

    // Host 8x8x16 splits at panel K=8. lda=16. The second panel's
    // pointers move by 8, so it must read B. Repeating that panel skips.
    for (int wi = 0; wi < 16; wi++) begin
      poke(PA + 64'(wi) * 64'd8, 64'h0101_0101_0101_0101);
      poke(PB + 64'(wi) * 64'd8, 64'h0101_0101_0101_0101);
    end
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd248, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd8, 32'd8, 32'd8, PA, PB, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2E00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd46 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("ksplit t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("ksplit", PC, C_K8);
    expect_w("ksplit-last", PC + 64'd248, C_K8);
    retire_cpl();

    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd248, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd8, 32'd8, 32'd8, PA + 64'd8, PB + 64'd8, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_2F00);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd47 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("ksplit-2 t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("ksplit-2", PC, C_K8);
    expect_w("ksplit-2-last", PC + 64'd248, C_K8);
    retire_cpl();

    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd248, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd8, 32'd8, 32'd8, PA + 64'd8, PB + 64'd8, 16'd16, 16'd16);
    apb_write(16'h0108, 32'h0000_3000);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd48 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("ksplit-hit t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("ksplit-hit", PC, C_K8);
    expect_w("ksplit-hit-last", PC + 64'd248, C_K8);
    retire_cpl();

    // Host 8x16x8: two 8x8 panels along N. The second starts at B
    // column 8 and requests resident A.
    for (int wi = 0; wi < 8; wi++) poke(PA + 64'(wi) * 64'd8, 64'h0101_0101_0101_0101);
    for (int wi = 0; wi < 16; wi++) poke(PB + 64'(wi) * 64'd8, 64'h0101_0101_0101_0101);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd248, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd8, 32'd8, 32'd8, PA, PB, 16'd8, 16'd8);
    apb_write(16'h0108, 32'h0000_3100);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd49 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("nsplit t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("nsplit", PC, C_K8);
    expect_w("nsplit-last", PC + 64'd248, C_K8);
    retire_cpl();

    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    poke(PC + 64'd248, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_A, 32'd8, 32'd8, 32'd8, PA, PB + 64'd64, 16'd8, 16'd8);
    apb_write(16'h0108, 32'h0000_3200);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd50 || status[15:0] != ST_OK || da != 0 || db == 0) begin
      $error("nsplit-a t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_w("nsplit-a", PC, C_K8);
    expect_w("nsplit-a-last", PC + 64'd248, C_K8);
    retire_cpl();

    // Epoch register. VaTurboEn forwards it. A new epoch misses,
    // the same epoch hits, and returning to 0 misses again.
    poke(PA, 64'h0101_0101_0101_0101);
    poke(PB, 64'h0101_0101_0101_0101);
    apb_write(REG_OFF_REUSE_EPOCH, 32'h0);
    apb_read(REG_OFF_REUSE_EPOCH, status);
    if (status != 32'h0) begin
      $error("epoch readback %h", status);
      errors++;
    end
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd2, 32'd2, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_3300);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd51 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("epoch-prime t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("epoch-prime", PC);
    retire_cpl();

    apb_write(REG_OFF_REUSE_EPOCH, 32'h1);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_3400);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd52 || status[15:0] != ST_OK || db == 0) begin
      $error("epoch-miss t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("epoch-miss", PC);
    retire_cpl();

    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_3500);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd53 || status[15:0] != ST_OK || da == 0 || db != 0) begin
      $error("epoch-hit t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("epoch-hit", PC);
    retire_cpl();

    apb_write(REG_OFF_REUSE_EPOCH, 32'h0);
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(REUSE_B, 32'd2, 32'd2, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_3600);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    // Epoch semantics are monotonic: the caller advances the epoch after a writer
    // touched B and never legitimately returns to an older one. With ONE slot the
    // epoch-1 fill displaced the epoch-0 panel, so going back misses; with two or
    // more slots the epoch-0 panel is still resident and going back HITS -- the
    // directory keys on (ptr, epoch), and that resident copy is exactly the data
    // epoch 0 named. Both are the correct behaviour of their geometry.
    if (ticket != 32'd54 || status[15:0] != ST_OK ||
        ((REUSE_SLOTS > 1) ? (db != 0) : (db == 0))) begin
      $error("epoch-back t=%0d st=%h arA=%0d arB=%0d slots=%0d", ticket, status, da, db, REUSE_SLOTS);
      errors++;
    end
    expect_c("epoch-back", PC);
    retire_cpl();

    // Level register. [3:0] is the request. [11:8] is applied and stays 0.
    // A stored request does not change the exact product. The PMU copy
    // updates when the next GEMM completes.
    apb_write(REG_OFF_VA_TURBO_LEVEL, 32'hFFFF_FFFF);
    apb_read(REG_OFF_VA_TURBO_LEVEL, status);
    if (status != 32'h0000_000F) begin
      $error("level mask %h", status);
      errors++;
    end
    apb_write(REG_OFF_VA_TURBO_LEVEL, 32'h0000_0109);
    apb_read(REG_OFF_VA_TURBO_LEVEL, status);
    if (status != 32'h0000_0009) begin
      $error("level req %h", status);
      errors++;
    end
    apb_read(PMU_OFF_VA_TURBO_LEVEL, status);
    if (status != 32'h0) begin
      $error("level pmu early %h", status);
      errors++;
    end
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd2, 32'd2, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_3700);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd55 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("level-job t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("level-job", PC);
    retire_cpl();
    apb_read(PMU_OFF_VA_TURBO_LEVEL, status);
    if (status != 32'h0000_0009) begin
      $error("level pmu %h", status);
      errors++;
    end

    // Recipe id [4:0] is {bank, subcode}. [12:8] is the applied id and
    // stays 0. A stored id does not change the exact product.
    apb_write(REG_OFF_VA_TURBO_RECIPE, 32'hFFFF_FFFF);
    apb_read(REG_OFF_VA_TURBO_RECIPE, status);
    if (status != 32'h0000_001F) begin
      $error("recipe mask %h", status);
      errors++;
    end
    apb_write(REG_OFF_VA_TURBO_RECIPE, 32'h0000_0110);
    apb_read(REG_OFF_VA_TURBO_RECIPE, status);
    if (status != 32'h0000_0010) begin
      $error("recipe req %h", status);
      errors++;
    end
    apb_read(PMU_OFF_VA_TURBO_RECIPE, status);
    if (status != 32'h0) begin
      $error("recipe pmu early %h", status);
      errors++;
    end
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd2, 32'd2, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_3800);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd56 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("recipe-job t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("recipe-job", PC);
    retire_cpl();
    apb_read(PMU_OFF_VA_TURBO_RECIPE, status);
    if (status != 32'h0000_0010) begin
      $error("recipe pmu %h", status);
      errors++;
    end

    // A window claim dies when the level, recipe, or epoch is written.
    // The claim does not change the exact product.
    apb_write(REG_OFF_VA_TURBO_WINDOW, 32'h1);
    apb_read(REG_OFF_VA_TURBO_WINDOW, status);
    if (status != 32'h1) begin
      $error("window set %h", status);
      errors++;
    end
    apb_write(REG_OFF_VA_TURBO_LEVEL, 32'h9);
    apb_read(REG_OFF_VA_TURBO_WINDOW, status);
    if (status != 32'h0) begin
      $error("window survived a level write %h", status);
      errors++;
    end
    apb_write(REG_OFF_VA_TURBO_WINDOW, 32'h1);
    apb_read(PMU_OFF_VA_TURBO_WINDOW, status);
    if (status != 32'h0) begin
      $error("window pmu early %h", status);
      errors++;
    end
    poke(PC, 64'hDEAD_BEEF_DEAD_BEEF);
    a0 = ar_a; b0 = ar_b;
    latch_gemm_at(32'h0, 32'd2, 32'd2, 32'd1, PA, PB, 16'd1, 16'd1);
    apb_write(16'h0108, 32'h0000_3900);
    wait_cpl(ticket, status);
    da = ar_a - a0; db = ar_b - b0;
    if (ticket != 32'd57 || status[15:0] != ST_OK || da == 0 || db == 0) begin
      $error("window-job t=%0d st=%h arA=%0d arB=%0d", ticket, status, da, db);
      errors++;
    end
    expect_c("window-job", PC);
    retire_cpl();
    apb_read(PMU_OFF_VA_TURBO_WINDOW, status);
    if (status != 32'h1) begin
      $error("window pmu %h", status);
      errors++;
    end

    if (errors == 0) begin
      $display("DESC reuse m=1024 n=512 k=16 ptr=ab ld=1 fmt=1 err=1 werr=1 odd=1 asl=1 wboth=1 bsl=1 cpl=1 sched=1 ksplit=1 nsplit=1 epoch=1 lvl=1 recipe=1 window=1");
      $display("PASS tb_g6lc_ai_desc_reuse");
      $finish;
    end else begin
      $fatal(1, "FAIL tb_g6lc_ai_desc_reuse errors=%0d", errors);
    end
  end
endmodule
