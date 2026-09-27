// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Two-channel class-0 island. A descriptor pointer 8 bytes off a 64-byte
// stripe completes with ST_ERR and issues no AR. An aligned pointer is
// fetched (one AR) and a zero descriptor completes ST_BAD_VER. A latched
// PREFETCH whose completion pointer is only 4-byte aligned completes
// ST_ERR and issues no write. The core sideband uses the same fetch check
// as the doorbell. Does not set G6LC_AI_DRAM_ISLAND_PORT.

`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_desc_island;
  import g6lc_ai_desc_pkg::*;
  import g6lc_ai_island_cfg_pkg::*;

  localparam int unsigned AW = 64;
  localparam int unsigned DW = 64;
  localparam int unsigned IW = 4;
  localparam int unsigned UW = 1;
  localparam logic [63:0] DRAM = 64'h8000_0000;
  localparam logic [63:0] CROSS = DRAM + 64'h8;

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
  logic init_done;
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r, ch_w;
  int unsigned ar_cnt, aw_cnt;
  logic        sb_valid = 1'b0;
  logic [7:0]  sb_qid   = '0;
  logic [31:0] sb_ticket = '0;
  logic [63:0] sb_ptr   = '0;
  logic        cap_w = 1'b0;
  logic        cap_seen;
  logic [63:0] cap_aw, cap_wdata;
  logic [7:0]  cap_wstrb;
  logic [2:0]  cap_awsize;

  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      dma ();

  `AXI_ASSIGN_FROM_REQ(dma, dma_req_g)
  `AXI_ASSIGN_TO_RESP(dma_rsp, dma)

  always @(posedge clk) begin
    if (!rst_n) begin
      ar_cnt     <= 0;
      aw_cnt     <= 0;
      cap_seen   <= 0;
      cap_aw     <= '0;
      cap_wdata  <= '0;
      cap_wstrb  <= '0;
      cap_awsize <= '0;
    end else begin
      if (dma_req_g.ar_valid && dma_rsp_g.ar_ready) ar_cnt <= ar_cnt + 1;
      if (dma_req_g.aw_valid && dma_rsp_g.aw_ready) aw_cnt <= aw_cnt + 1;
      if (!cap_w) begin
        cap_seen <= 0;
      end else begin
        if (dma_req_g.aw_valid && dma_rsp_g.aw_ready) begin
          cap_aw     <= dma_req_g.aw.addr;
          cap_awsize <= 3'(dma_req_g.aw.size);
        end
        if (dma_req_g.w_valid && dma_rsp_g.w_ready && !cap_seen) begin
          cap_wdata <= dma_req_g.w.data;
          cap_wstrb <= dma_req_g.w.strb;
          cap_seen  <= 1;
        end
      end
    end
  end

  g6lc_ai_island_apb #(
      .IslandCfg(AiIslandSimChans2),
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
      .sb_enq_valid_i(sb_valid), .sb_qid_i(sb_qid), .sb_ticket_i(sb_ticket),
      .sb_desc_ptr_i(sb_ptr),
      .sb_last_ticket_o(), .sb_last_status_o(), .sb_has_completion_o(),
      .axi_dma_req_o(dma_req), .axi_dma_resp_i(dma_rsp_g),
      .dram_init_done_i(init_done),
      .ch_r_beats_i(ch_r), .ch_w_beats_i(ch_w)
  );

  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(2048),
      .NrChannels(2), .ChanShift(6), .MaxAROut(2)
  ) i_mem (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(dma), .init_done_o(init_done),
      .ch_r_beats_o(ch_r), .ch_w_beats_o(ch_w)
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
    while (!(sticky & 32'h1) && polls < 400) begin
      apb_read(16'h010C, sticky);
      polls++;
    end
    if (!(sticky & 32'h1)) $fatal(1, "completion timeout polls=%0d", polls);
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
    if (sticky & 32'h1) $fatal(1, "completion did not retire");
  endtask

  // Layout jobs finish inside one MMIO round trip. A few status reads let
  // the engine reach idle before the next doorbell.
  task automatic settle_job;
    logic [31:0] st;
    int i;
    st = 32'h1;
    for (i = 0; i < 8; i++) apb_read(16'h0104, st);
    i = 0;
    while ((st & 32'h1) && i < 400) begin
      apb_read(16'h0104, st);
      i++;
    end
    if (st & 32'h1) $fatal(1, "job stayed busy");
  endtask

  // One-cycle core sideband kick. Ticket is the raw value, not the doorbell
  // packing. A non-zero pointer fetches; zero submits the latch.
  task automatic sb_kick(
      input logic [7:0] qid,
      input logic [31:0] ticket,
      input logic [63:0] ptr
  );
    @(negedge clk);
    sb_qid    = qid;
    sb_ticket = ticket;
    sb_ptr    = ptr;
    sb_valid  = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sb_valid = 1'b0;
    sb_ptr   = '0;
  endtask

  task automatic latch_job_ex(
      input logic [15:0] op,
      input logic [31:0] flags, m, n, k,
      input logic [15:0] lda, ldb,
      input logic [63:0] pa, pb, pc, pscale, pdone
  );
    desc_t d;
    desc_bits_t bits;
    int unsigned wi;
    d = '0;
    d.version = 16'(ContractVersion);
    d.op = op;
    d.flags = flags;
    d.m = m; d.n = n; d.k = k;
    d.ld_ab = {ldb, lda};
    d.ptr_a = pa; d.ptr_b = pb; d.ptr_c = pc;
    d.ptr_scale = pscale;
    d.ptr_done = pdone;
    bits = desc_to_bits(d);
    for (wi = 0; wi < 16; wi++)
      apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
  endtask

  task automatic latch_job(
      input logic [63:0] pa, pb, pc, pscale, pdone
  );
    latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 pa, pb, pc, pscale, pdone);
  endtask

  // base_off is 0x0120 for queue 0 and 0x01A0 for queue 1. Perm commits.
  task automatic prog_region(
      input logic [15:0] base_off,
      input logic [63:0] base, limit,
      input logic [31:0] perm
  );
    apb_write(base_off + 16'h0, base[31:0]);
    apb_write(base_off + 16'h4, base[63:32]);
    apb_write(base_off + 16'h8, limit[31:0]);
    apb_write(base_off + 16'hC, limit[63:32]);
    apb_write(base_off + 16'h10, perm);
  endtask

  initial begin
    logic [31:0] ticket, status;
    psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;
    rst_n = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    apb_write(16'h0100, 32'h3);
    // Region before any descriptor fetch. DRAM+8 and DRAM sit inside it.
    apb_write(16'h0120, 32'(DRAM));
    apb_write(16'h0124, 32'(DRAM >> 32));
    apb_write(16'h0128, 32'(DRAM + 64'h1000));
    apb_write(16'h012C, 32'h0);
    apb_write(16'h0130, 32'h3);
    apb_write(16'h0118, 32'(CROSS));
    apb_write(16'h011C, 32'(CROSS >> 32));
    apb_write(16'h0108, 32'h8000_0A00);
    wait_cpl(ticket, status);
    if (ticket != 32'd10 || status[15:0] != ST_ERR || ar_cnt != 0)
      $fatal(1, "cross desc ticket %0d status %h ars %0d", ticket, status, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "completion did not retire");
    end

    apb_write(16'h0118, 32'(DRAM));
    apb_write(16'h011C, 32'(DRAM >> 32));
    apb_write(16'h0108, 32'h8000_0B00);
    wait_cpl(ticket, status);
    if (ticket != 32'd11 || status[15:0] != ST_BAD_VER || ar_cnt != 1)
      $fatal(1, "aligned desc ticket %0d status %h ars %0d", ticket, status, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      desc_t d;
      desc_bits_t bits;
      int unsigned wi;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "second completion did not retire");
      d = '0;
      d.version  = 16'(ContractVersion);
      d.op       = OP_PREFETCH;
      d.ptr_a    = DRAM;
      d.ptr_b    = DRAM;
      d.ptr_c    = DRAM;
      d.ptr_done = DRAM + 64'h4;
      bits = desc_to_bits(d);
      for (wi = 0; wi < 16; wi++)
        apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
      apb_write(16'h0120, 32'(DRAM));
      apb_write(16'h0124, 32'(DRAM >> 32));
      apb_write(16'h0128, 32'(DRAM + 64'h1000));
      apb_write(16'h012C, 32'h0);
      apb_write(16'h0130, 32'h3);
      // Bit 31 clear: submit the latch, do not fetch.
      apb_write(16'h0108, 32'h0000_0C00);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd12 || status[15:0] != ST_BAD_PTR || aw_cnt != 0 || ar_cnt != 1)
      $fatal(1, "misaligned completion ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      desc_t d;
      desc_bits_t bits;
      int unsigned wi;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "third completion did not retire");
      // Even n would store 8-byte pairs. C at +4 is refused before any load.
      d = '0;
      d.version  = 16'(ContractVersion);
      d.op       = OP_GEMM;
      d.m = 32'd1; d.n = 32'd2; d.k = 32'd1;
      d.ld_ab = {16'd1, 16'd1};
      d.ptr_a = DRAM; d.ptr_b = DRAM; d.ptr_c = DRAM + 64'h4;
      bits = desc_to_bits(d);
      for (wi = 0; wi < 16; wi++)
        apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
      apb_write(16'h0108, 32'h0000_0D00);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd13 || status[15:0] != ST_BAD_PTR || aw_cnt != 0 || ar_cnt != 1)
      $fatal(1, "misaligned C ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      desc_t d;
      desc_bits_t bits;
      int unsigned wi;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "fourth completion did not retire");
      // Window covers 16 bytes. 2x4 i32 C is 32 bytes and must be refused
      // before any operand read.
      apb_write(16'h0128, 32'(DRAM + 64'h10));
      apb_write(16'h0130, 32'h3);
      d = '0;
      d.version = 16'(ContractVersion);
      d.op = OP_GEMM;
      d.m = 32'd2; d.n = 32'd4; d.k = 32'd1;
      d.ld_ab = {16'd1, 16'd1};
      d.ptr_a = DRAM; d.ptr_b = DRAM; d.ptr_c = DRAM;
      bits = desc_to_bits(d);
      for (wi = 0; wi < 16; wi++)
        apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
      apb_write(16'h0108, 32'h0000_0E00);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd14 || status[15:0] != ST_BAD_PTR || aw_cnt != 0 || ar_cnt != 1)
      $fatal(1, "oversize C ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      desc_t d;
      desc_bits_t bits;
      int unsigned wi;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "fifth completion did not retire");
      // 1x1x1 C is 4 bytes and fits the same 16-byte window.
      d = '0;
      d.version = 16'(ContractVersion);
      d.op = OP_GEMM;
      d.m = 32'd1; d.n = 32'd1; d.k = 32'd1;
      d.ld_ab = {16'd1, 16'd1};
      d.ptr_a = DRAM; d.ptr_b = DRAM; d.ptr_c = DRAM;
      bits = desc_to_bits(d);
      for (wi = 0; wi < 16; wi++)
        apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
      apb_write(16'h0108, 32'h0000_0F00);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd15 || status[15:0] != ST_OK || aw_cnt != 1 || ar_cnt != 3)
      $fatal(1, "fitting C ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      desc_t d;
      desc_bits_t bits;
      int unsigned wi;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "sixth completion did not retire");
      // One INT8 element is one byte, but the load beat is 8. A 4-byte
      // window holds the element and not the beat.
      apb_write(16'h0128, 32'(DRAM + 64'h4));
      apb_write(16'h0130, 32'h3);
      d = '0;
      d.version = 16'(ContractVersion);
      d.op = OP_GEMM;
      d.m = 32'd1; d.n = 32'd1; d.k = 32'd1;
      d.ld_ab = {16'd1, 16'd1};
      d.ptr_a = DRAM; d.ptr_b = DRAM; d.ptr_c = DRAM;
      bits = desc_to_bits(d);
      for (wi = 0; wi < 16; wi++)
        apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
      apb_write(16'h0108, 32'h0000_1000);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd16 || status[15:0] != ST_BAD_PTR || aw_cnt != 1 || ar_cnt != 3)
      $fatal(1, "short beat window ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "seventh completion did not retire");
      // Eight bytes covers the load beat and the 4-byte result.
      apb_write(16'h0128, 32'(DRAM + 64'h8));
      apb_write(16'h0130, 32'h3);
      apb_write(16'h0108, 32'h0000_1100);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd17 || status[15:0] != ST_OK || aw_cnt != 2 || ar_cnt != 5)
      $fatal(1, "beat window ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "eighth completion did not retire");
      // Wide window again. An odd descriptor pointer is not an 8-byte beat.
      apb_write(16'h0128, 32'(DRAM + 64'h1000));
      apb_write(16'h0130, 32'h3);
      apb_write(16'h0118, 32'(DRAM + 64'h1));
      apb_write(16'h011C, 32'h0);
      apb_write(16'h0108, 32'h8000_1200);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd18 || status[15:0] != ST_BAD_PTR || aw_cnt != 2 || ar_cnt != 5)
      $fatal(1, "odd desc ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "ninth completion did not retire");
      // 64-byte aligned, outside the window.
      apb_write(16'h0118, 32'(DRAM + 64'h2000));
      apb_write(16'h011C, 32'h0);
      apb_write(16'h0108, 32'h8000_1300);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd19 || status[15:0] != ST_BAD_PTR || aw_cnt != 2 || ar_cnt != 5)
      $fatal(1, "outside desc ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "tenth completion did not retire");
      // Read-only. The latched 1x1x1 result needs a write.
      apb_write(16'h0130, 32'h1);
      apb_write(16'h0108, 32'h0000_1400);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd20 || status[15:0] != ST_BAD_PTR || aw_cnt != 2 || ar_cnt != 5)
      $fatal(1, "read-only C ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "eleventh completion did not retire");
      // Write-only. A descriptor fetch needs a read.
      apb_write(16'h0130, 32'h2);
      apb_write(16'h0118, 32'(DRAM));
      apb_write(16'h011C, 32'h0);
      apb_write(16'h0108, 32'h8000_1500);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd21 || status[15:0] != ST_BAD_PTR || aw_cnt != 2 || ar_cnt != 5)
      $fatal(1, "write-only fetch ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "twelfth completion did not retire");
      // Read-only again. The same descriptor address may be fetched.
      apb_write(16'h0130, 32'h1);
      apb_write(16'h0108, 32'h8000_1600);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd22 || status[15:0] != ST_BAD_VER || aw_cnt != 2 || ar_cnt != 6)
      $fatal(1, "read-only fetch ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    apb_write(16'h010C, 32'h1);
    begin
      logic [31:0] sticky;
      int polls;
      sticky = 32'h1;
      polls = 0;
      while ((sticky & 32'h1) && polls < 40) begin
        apb_read(16'h010C, sticky);
        polls++;
      end
      if (sticky & 32'h1) $fatal(1, "thirteenth completion did not retire");
      // Queue 1 was never programmed. Low byte of the doorbell is the queue.
      apb_write(16'h0108, 32'h8000_1701);
    end
    wait_cpl(ticket, status);
    if (ticket != 32'd23 || status[15:0] != ST_BAD_PTR || aw_cnt != 2 || ar_cnt != 6)
      $fatal(1, "qid 1 ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);

    // Sideband. Queue 0 is still read-only. An odd pointer is not fetched.
    retire_cpl();
    sb_kick(8'd0, 32'd24, DRAM + 64'h1);
    wait_cpl(ticket, status);
    if (ticket != 32'd24 || status[15:0] != ST_BAD_PTR || aw_cnt != 2 || ar_cnt != 6)
      $fatal(1, "sb odd ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    // The same read-only window still fetches an aligned descriptor.
    retire_cpl();
    sb_kick(8'd0, 32'd25, DRAM);
    wait_cpl(ticket, status);
    if (ticket != 32'd25 || status[15:0] != ST_BAD_VER || aw_cnt != 2 || ar_cnt != 7)
      $fatal(1, "sb read-only fetch ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    // Write-only refuses the fetch.
    retire_cpl();
    apb_write(16'h0130, 32'h2);
    sb_kick(8'd0, 32'd26, DRAM);
    wait_cpl(ticket, status);
    if (ticket != 32'd26 || status[15:0] != ST_BAD_PTR || aw_cnt != 2 || ar_cnt != 7)
      $fatal(1, "sb write-only ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    // Queue 0 can read again. Queue 1 was never programmed, and the kick
    // carries that queue id.
    retire_cpl();
    apb_write(16'h0130, 32'h1);
    sb_kick(8'd1, 32'd27, DRAM);
    wait_cpl(ticket, status);
    if (ticket != 32'd27 || status[15:0] != ST_BAD_PTR || aw_cnt != 2 || ar_cnt != 7)
      $fatal(1, "sb qid 1 ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    // A zero pointer submits the latch. Rewrite it: the fetch above stored
    // the zero descriptor.
    retire_cpl();
    begin
      desc_t d;
      desc_bits_t bits;
      int unsigned wi;
      apb_write(16'h0130, 32'h3);
      d = '0;
      d.version = 16'(ContractVersion);
      d.op = OP_GEMM;
      d.m = 32'd1; d.n = 32'd1; d.k = 32'd1;
      d.ld_ab = {16'd1, 16'd1};
      d.ptr_a = DRAM; d.ptr_b = DRAM; d.ptr_c = DRAM;
      bits = desc_to_bits(d);
      for (wi = 0; wi < 16; wi++)
        apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
    end
    sb_kick(8'd0, 32'd28, 64'd0);
    wait_cpl(ticket, status);
    if (ticket != 32'd28 || status[15:0] != ST_OK || aw_cnt != 3 || ar_cnt != 9)
      $fatal(1, "sb latched gemm ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);

    // Scale is an 8-byte probe. A pointer past the window is refused
    // before any matrix traffic, and the table itself is not fetched.
    retire_cpl();
    latch_job(DRAM, DRAM, DRAM, DRAM + 64'h2000, 64'd0);
    apb_write(16'h0108, 32'h0000_1D00);
    wait_cpl(ticket, status);
    if (ticket != 32'd29 || status[15:0] != ST_BAD_PTR || aw_cnt != 3 || ar_cnt != 9)
      $fatal(1, "scale outside ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    // Eight bytes of window fit the operand beat and the result. The scale
    // word starts four bytes in, so its 8-byte probe does not.
    retire_cpl();
    prog_region(16'h0120, DRAM, DRAM + 64'h8, 32'h3);
    latch_job(DRAM, DRAM, DRAM, DRAM + 64'h4, 64'd0);
    apb_write(16'h0108, 32'h0000_1E00);
    wait_cpl(ticket, status);
    if (ticket != 32'd30 || status[15:0] != ST_BAD_PTR || aw_cnt != 3 || ar_cnt != 9)
      $fatal(1, "scale short ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    prog_region(16'h0120, DRAM, DRAM + 64'h1000, 32'h3);
    latch_job(DRAM, DRAM, DRAM, DRAM, 64'd0);
    apb_write(16'h0108, 32'h0000_1F00);
    wait_cpl(ticket, status);
    if (ticket != 32'd31 || status[15:0] != ST_OK || aw_cnt != 4 || ar_cnt != 11)
      $fatal(1, "scale inside ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    // Completion pointer is its own 8-byte write. Matrices can fit while it does not.
    retire_cpl();
    latch_job(DRAM, DRAM, DRAM, 64'd0, DRAM + 64'h2000);
    apb_write(16'h0108, 32'h0000_2000);
    wait_cpl(ticket, status);
    if (ticket != 32'd32 || status[15:0] != ST_BAD_PTR || aw_cnt != 4 || ar_cnt != 11)
      $fatal(1, "done outside ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    latch_job(DRAM, DRAM, DRAM, 64'd0, DRAM + 64'h20);
    apb_write(16'h0108, 32'h0000_2100);
    wait_cpl(ticket, status);
    if (ticket != 32'd33 || status[15:0] != ST_OK || aw_cnt != 6 || ar_cnt != 13)
      $fatal(1, "done inside ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);

    // Queue 1 lives at 0x01A0. Queue 0's window does not authorize it, and
    // the reverse is also true. 0x0150 is a descriptor word, not q1's perm.
    retire_cpl();
    prog_region(16'h01A0, DRAM, DRAM + 64'h1000, 32'h3);
    prog_region(16'h0120, DRAM, DRAM + 64'h4, 32'h3);
    latch_job(DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2200);
    wait_cpl(ticket, status);
    if (ticket != 32'd34 || status[15:0] != ST_BAD_PTR || aw_cnt != 6 || ar_cnt != 13)
      $fatal(1, "q0 not q1 ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    apb_write(16'h0108, 32'h0000_2301);
    wait_cpl(ticket, status);
    if (ticket != 32'd35 || status[15:0] != ST_OK || aw_cnt != 7 || ar_cnt != 15)
      $fatal(1, "q1 own window ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    sb_kick(8'd1, 32'd36, DRAM);
    wait_cpl(ticket, status);
    if (ticket != 32'd36 || status[15:0] != ST_BAD_VER || aw_cnt != 7 || ar_cnt != 16)
      $fatal(1, "sb q1 fetch ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    prog_region(16'h0120, DRAM, DRAM + 64'h1000, 32'h3);
    prog_region(16'h01A0, DRAM + 64'h100, DRAM + 64'h180, 32'h3);
    latch_job(DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2501);
    wait_cpl(ticket, status);
    if (ticket != 32'd37 || status[15:0] != ST_BAD_PTR || aw_cnt != 7 || ar_cnt != 16)
      $fatal(1, "q1 not q0 ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    begin
      logic [31:0] perm1, desc_word;
      apb_write(16'h0150, 32'h1111_1111);
      apb_read(16'h0150, desc_word);
      apb_read(16'h01B0, perm1);
      if (desc_word != 32'h1111_1111 || perm1 != 32'h3)
        $fatal(1, "q1 alias desc %h perm %h", desc_word, perm1);
    end

    // Level IRQ follows the completion head. OP_LAYOUT does not run the GEMM.
    retire_cpl();
    latch_job_ex(OP_LAYOUT, 32'h4, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2600);
    wait_cpl(ticket, status);
    if (ticket != 32'd38 || status[15:0] != ST_OK || aw_cnt != 7 || ar_cnt != 16
        || irq !== 1'b1)
      $fatal(1, "irq ticket %0d status %h aw %0d ar %0d irq %b",
             ticket, status, aw_cnt, ar_cnt, irq);
    retire_cpl();
    if (irq !== 1'b0)
      $fatal(1, "irq stayed after claim");
    latch_job_ex(OP_LAYOUT, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2700);
    wait_cpl(ticket, status);
    if (ticket != 32'd39 || status[15:0] != ST_OK || aw_cnt != 7 || ar_cnt != 16
        || irq !== 1'b0)
      $fatal(1, "no-irq ticket %0d status %h aw %0d ar %0d irq %b",
             ticket, status, aw_cnt, ar_cnt, irq);
    // Completion DMA follows wr_cpl_en. The pointer is still checked.
    retire_cpl();
    apb_write(16'h0100, 32'h1);
    latch_job_ex(OP_LAYOUT, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, DRAM + 64'h2000);
    apb_write(16'h0108, 32'h0000_2800);
    wait_cpl(ticket, status);
    if (ticket != 32'd40 || status[15:0] != ST_BAD_PTR || aw_cnt != 7 || ar_cnt != 16)
      $fatal(1, "cpl off bad done ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    latch_job_ex(OP_LAYOUT, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, DRAM + 64'h20);
    apb_write(16'h0108, 32'h0000_2900);
    wait_cpl(ticket, status);
    if (ticket != 32'd41 || status[15:0] != ST_OK || aw_cnt != 7 || ar_cnt != 16)
      $fatal(1, "cpl off ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    apb_write(16'h0100, 32'h3);
    apb_write(16'h0108, 32'h0000_2A00);
    wait_cpl(ticket, status);
    if (ticket != 32'd42 || status[15:0] != ST_OK || aw_cnt != 8 || ar_cnt != 16)
      $fatal(1, "cpl on ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    // Shape belongs to the sequencer. The window holds these tensors.
    retire_cpl();
    latch_job_ex(OP_GEMM, 32'h0, 32'd0, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2B00);
    wait_cpl(ticket, status);
    if (ticket != 32'd43 || status[15:0] != ST_ERR || aw_cnt != 8 || ar_cnt != 16)
      $fatal(1, "m0 ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    // 1025 i32 C words are 4100 bytes, past the 4 KiB window. Widen the
    // region so the refusal is the shape check, then put the window back.
    prog_region(16'h0120, DRAM, DRAM + 64'h2000, 32'h3);
    latch_job_ex(OP_GEMM, 32'h0, 32'd1025, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2C00);
    wait_cpl(ticket, status);
    if (ticket != 32'd44 || status[15:0] != ST_ERR || aw_cnt != 8 || ar_cnt != 16)
      $fatal(1, "m1025 ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    prog_region(16'h0120, DRAM, DRAM + 64'h1000, 32'h3);
    latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd2, 16'd1, 16'd2,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2D00);
    wait_cpl(ticket, status);
    if (ticket != 32'd45 || status[15:0] != ST_ERR || aw_cnt != 8 || ar_cnt != 16)
      $fatal(1, "lda ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);

    // Three layout jobs finish before any claim. The head stays the oldest,
    // and the IRQ follows that head.
    retire_cpl();
    latch_job_ex(OP_LAYOUT, 32'h4, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2E00);
    settle_job();
    latch_job_ex(OP_LAYOUT, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_2F00);
    settle_job();
    latch_job_ex(OP_LAYOUT, 32'h4, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_3000);
    settle_job();
    apb_read(16'h0110, ticket);
    apb_read(16'h0114, status);
    if (ticket != 32'd46 || status[15:0] != ST_OK || irq !== 1'b1)
      $fatal(1, "fifo head ticket %0d status %h irq %b", ticket, status, irq);
    apb_write(16'h010C, 32'h1);
    settle_job();
    apb_read(16'h0110, ticket);
    apb_read(16'h0114, status);
    if (ticket != 32'd47 || status[15:0] != ST_OK || irq !== 1'b0)
      $fatal(1, "fifo mid ticket %0d status %h irq %b", ticket, status, irq);
    apb_write(16'h010C, 32'h1);
    settle_job();
    apb_read(16'h0110, ticket);
    apb_read(16'h0114, status);
    if (ticket != 32'd48 || status[15:0] != ST_OK || irq !== 1'b1)
      $fatal(1, "fifo tail ticket %0d status %h irq %b", ticket, status, irq);
    retire_cpl();
    if (irq !== 1'b0)
      $fatal(1, "irq after last claim");
    if (aw_cnt != 8 || ar_cnt != 16)
      $fatal(1, "fifo traffic aw %0d ar %0d", aw_cnt, ar_cnt);

    // The completion beat is the 8-byte {status, ticket} word on the low lane.
    cap_w = 1'b1;
    latch_job_ex(OP_LAYOUT, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, DRAM + 64'h40);
    apb_write(16'h0108, 32'h0000_3100);
    wait_cpl(ticket, status);
    if (ticket != 32'd49 || status[15:0] != ST_OK || aw_cnt != 9 || ar_cnt != 16)
      $fatal(1, "cpl word ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    if (cap_aw != DRAM + 64'h40 || cap_awsize != 3'd3
        || cap_wdata != 64'h0000_0000_0000_0031 || cap_wstrb != 8'hFF)
      $fatal(1, "cpl beat addr %h size %0d data %h strb %h",
             cap_aw, cap_awsize, cap_wdata, cap_wstrb);
    cap_w = 1'b0;

    retire_cpl();
    latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd0, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_3200);
    wait_cpl(ticket, status);
    if (ticket != 32'd50 || status[15:0] != ST_ERR || aw_cnt != 9 || ar_cnt != 16)
      $fatal(1, "k0 ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd0, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_3300);
    wait_cpl(ticket, status);
    if (ticket != 32'd51 || status[15:0] != ST_ERR || aw_cnt != 9 || ar_cnt != 16)
      $fatal(1, "n0 ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);
    retire_cpl();
    latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd2, 16'd2, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    apb_write(16'h0108, 32'h0000_3400);
    wait_cpl(ticket, status);
    if (ticket != 32'd52 || status[15:0] != ST_ERR || aw_cnt != 9 || ar_cnt != 16)
      $fatal(1, "ldb ticket %0d status %h aw %0d ar %0d",
             ticket, status, aw_cnt, ar_cnt);

    // A second doorbell during a GEMM is held, then run. Both tickets complete.
    retire_cpl();
    begin
      int unsigned aw0, ar0;
      aw0 = aw_cnt;
      ar0 = ar_cnt;
      latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd64, 16'd64, 16'd64,
                   DRAM, DRAM, DRAM, 64'd0, 64'd0);
      apb_write(16'h0108, 32'h0000_3500);
      apb_write(16'h0108, 32'h0000_3600);
      wait_cpl(ticket, status);
      if (ticket != 32'd53 || status[15:0] != ST_OK)
        $fatal(1, "held first ticket %0d status %h", ticket, status);
      retire_cpl();
      wait_cpl(ticket, status);
      if (ticket != 32'd54 || status[15:0] != ST_OK || aw_cnt != aw0 + 2
          || ar_cnt != ar0 + 4)
        $fatal(1, "held second ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               ticket, status, aw_cnt, ar_cnt, aw0, ar0);
    end

    // Sixteen layout jobs fill the completion FIFO. The next doorbell waits
    // for a claim, then lands at the tail.
    retire_cpl();
    latch_job_ex(OP_LAYOUT, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                 DRAM, DRAM, DRAM, 64'd0, 64'd0);
    begin
      int unsigned t;
      int unsigned aw0, ar0;
      aw0 = aw_cnt;
      ar0 = ar_cnt;
      for (t = 60; t < 76; t++) begin
        apb_write(16'h0108, 32'(t) << 8);
        settle_job();
      end
      apb_read(16'h0110, ticket);
      if (ticket != 32'd60)
        $fatal(1, "full head %0d", ticket);
      apb_write(16'h0108, 32'(76) << 8);
      settle_job();
      apb_read(16'h0110, ticket);
      if (ticket != 32'd60)
        $fatal(1, "full head moved to %0d", ticket);
      for (t = 60; t < 76; t++) begin
        apb_read(16'h0110, ticket);
        apb_read(16'h0114, status);
        if (ticket != t || status[15:0] != ST_OK)
          $fatal(1, "drain ticket %0d exp %0d status %h", ticket, t, status);
        apb_write(16'h010C, 32'h1);
        settle_job();
      end
      apb_read(16'h0110, ticket);
      apb_read(16'h0114, status);
      if (ticket != 32'd76 || status[15:0] != ST_OK)
        $fatal(1, "tail ticket %0d status %h", ticket, status);
      retire_cpl();
      if (aw_cnt != aw0 || ar_cnt != ar0)
        $fatal(1, "fifo fill traffic aw %0d ar %0d", aw_cnt, ar_cnt);
    end

    // One hold slot. A newer doorbell replaces the ticket that is waiting.
    begin
      int unsigned aw0, ar0;
      logic [31:0] sticky;
      aw0 = aw_cnt;
      ar0 = ar_cnt;
      latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd64, 16'd64, 16'd64,
                   DRAM, DRAM, DRAM, 64'd0, 64'd0);
      apb_write(16'h0108, 32'h0000_4D00);
      apb_write(16'h0108, 32'h0000_4E00);
      apb_write(16'h0108, 32'h0000_4F00);
      wait_cpl(ticket, status);
      if (ticket != 32'd77 || status[15:0] != ST_OK)
        $fatal(1, "replace running ticket %0d status %h", ticket, status);
      retire_cpl();
      wait_cpl(ticket, status);
      if (ticket != 32'd79 || status[15:0] != ST_OK || aw_cnt != aw0 + 2
          || ar_cnt != ar0 + 4)
        $fatal(1, "replace held ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               ticket, status, aw_cnt, ar_cnt, aw0, ar0);
      retire_cpl();
      apb_read(16'h010C, sticky);
      if (sticky & 32'h1)
        $fatal(1, "replaced ticket 78 still completed");
    end

    // A fetch doorbell clears the held latched job. The odd pointer is refused
    // and the held ticket does not run after the GEMM.
    begin
      int unsigned aw0, ar0;
      logic [31:0] sticky;
      aw0 = aw_cnt;
      ar0 = ar_cnt;
      latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd64, 16'd64, 16'd64,
                   DRAM, DRAM, DRAM, 64'd0, 64'd0);
      apb_write(16'h0118, 32'(DRAM + 64'h1));
      apb_write(16'h011C, 32'h0);
      apb_write(16'h0108, 32'h0000_5000);
      apb_write(16'h0108, 32'h0000_5100);
      apb_write(16'h0108, 32'h8000_5200);
      wait_cpl(ticket, status);
      if (ticket != 32'd82 || status[15:0] != ST_BAD_PTR)
        $fatal(1, "fetch clear ticket %0d status %h", ticket, status);
      retire_cpl();
      wait_cpl(ticket, status);
      if (ticket != 32'd80 || status[15:0] != ST_OK || aw_cnt != aw0 + 1
          || ar_cnt != ar0 + 2)
        $fatal(1, "fetch clear gemm ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               ticket, status, aw_cnt, ar_cnt, aw0, ar0);
      retire_cpl();
      apb_read(16'h010C, sticky);
      if (sticky & 32'h1)
        $fatal(1, "held ticket 81 still completed");
    end

    // Sideband wins the next free slot. The held doorbell still runs after it.
    begin
      int unsigned aw0, ar0;
      logic [31:0] sticky;
      aw0 = aw_cnt;
      ar0 = ar_cnt;
      latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd64, 16'd64, 16'd64,
                   DRAM, DRAM, DRAM, 64'd0, 64'd0);
      apb_write(16'h0108, 32'h0000_5300);
      apb_write(16'h0108, 32'h0000_5400);
      sb_kick(8'd0, 32'd85, 64'd0);
      wait_cpl(ticket, status);
      if (ticket != 32'd83 || status[15:0] != ST_OK)
        $fatal(1, "sb order running ticket %0d status %h", ticket, status);
      retire_cpl();
      wait_cpl(ticket, status);
      if (ticket != 32'd85 || status[15:0] != ST_OK)
        $fatal(1, "sb order sideband ticket %0d status %h", ticket, status);
      retire_cpl();
      wait_cpl(ticket, status);
      if (ticket != 32'd84 || status[15:0] != ST_OK || aw_cnt != aw0 + 3
          || ar_cnt != ar0 + 6)
        $fatal(1, "sb order held ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               ticket, status, aw_cnt, ar_cnt, aw0, ar0);
      retire_cpl();
      apb_read(16'h010C, sticky);
      if (sticky & 32'h1)
        $fatal(1, "sb order extra completion");
    end

    // A descriptor fetch started while a GEMM owns the bus waits, then reads
    // the zero descriptor. It must not consume the GEMM's beats.
    begin
      int unsigned aw0, ar0;
      aw0 = aw_cnt;
      ar0 = ar_cnt;
      latch_job_ex(OP_GEMM, 32'h0, 32'd1, 32'd1, 32'd64, 16'd64, 16'd64,
                   DRAM, DRAM, DRAM, 64'd0, 64'd0);
      apb_write(16'h0108, 32'h0000_5600);
      sb_kick(8'd0, 32'd88, DRAM);
      wait_cpl(ticket, status);
      if (ticket != 32'd86 || status[15:0] != ST_OK)
        $fatal(1, "fetch-behind running ticket %0d status %h", ticket, status);
      retire_cpl();
      wait_cpl(ticket, status);
      if (ticket != 32'd88 || status[15:0] != ST_BAD_VER || aw_cnt != aw0 + 1
          || ar_cnt != ar0 + 3)
        $fatal(1, "fetch-behind desc ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               ticket, status, aw_cnt, ar_cnt, aw0, ar0);
      retire_cpl();
    end

    // Fused requant is refused before any matrix traffic.
    begin
      int unsigned aw0, ar0;
      aw0 = aw_cnt;
      ar0 = ar_cnt;
      latch_job_ex(OP_GEMM, 32'h8, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                   DRAM, DRAM, DRAM, 64'd0, 64'd0);
      apb_write(16'h0108, 32'h0000_5900);
      wait_cpl(ticket, status);
      if (ticket != 32'd89 || status[15:0] != ST_BAD_OP || aw_cnt != aw0
          || ar_cnt != ar0)
        $fatal(1, "requant ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               ticket, status, aw_cnt, ar_cnt, aw0, ar0);
    end

    $display("PASS tb_g6lc_ai_desc_island");
    $finish;
  end

  initial begin
    repeat (400000) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
