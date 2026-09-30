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

module tb_g6lc_ai_desc_island #(parameter bit SmallGeometry = 1'b0, parameter bit QueuedTest = 1'b0,
                                parameter bit AccumulateEn = 1'b1);
  import g6lc_ai_desc_pkg::*;
  import g6lc_ai_island_cfg_pkg::*;

  localparam int unsigned AW = 64;
  localparam int unsigned DW = 64;
  localparam int unsigned IW = 4;
  localparam int unsigned UW = 1;
  localparam logic [63:0] DRAM = 64'h8000_0000;
  localparam logic [63:0] CROSS = DRAM + 64'h8;

  function automatic ai_island_cfg_t test_cfg();
    ai_island_cfg_t cfg = AiIslandSimChans2;
    cfg.CommandDepth = QueuedTest ? 2 : 0;
    if (SmallGeometry) begin
      cfg.MacsPerCycle = 8;
      cfg.AccTileM = 16;
      cfg.AccTileN = 16;
      cfg.AccTileK = 64;
    end
    return cfg;
  endfunction
  localparam ai_island_cfg_t TestCfg = test_cfg();

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  typedef logic [AW-1:0] addr_t;
  typedef logic [IW-1:0] id_t;
  typedef logic [UW-1:0] user_t;
  typedef logic [DW-1:0] data_t;
  typedef logic [DW/8-1:0] strb_t;
  `AXI_TYPEDEF_ALL(gd, addr_t, id_t, data_t, strb_t, user_t)

  gd_req_t  dma_req /*verilator split_var*/, dma_req_g /*verilator split_var*/;
  gd_resp_t dma_rsp /*verilator split_var*/, dma_rsp_g /*verilator split_var*/;
  logic hold_dma_r = 1'b0;
  always_comb begin
    dma_req_g = rst_n ? dma_req : '0;
    dma_rsp_g = rst_n ? dma_rsp : '0;
    if (hold_dma_r) begin
      dma_req_g.r_ready = 1'b0;
      dma_rsp_g.r_valid = 1'b0;
    end
  end

  logic psel, penable, pwrite, pready, pslverr, irq;
  logic [31:0] paddr, pwdata, prdata;
  logic init_done;
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r, ch_w;
  int unsigned ar_cnt, aw_cnt, last_apb_read_cycles;
  logic        sb_valid = 1'b0;
  logic        sb_ready;
  logic [7:0]  sb_qid   = '0;
  logic [31:0] sb_ticket = '0;
  logic [63:0] sb_ptr   = '0;
  logic        cap_w = 1'b0;
  logic        cap_seen;
  logic [63:0] cap_aw, cap_wdata;
  logic [7:0]  cap_wstrb;
  logic [2:0]  cap_awsize;
  localparam int unsigned RateClocks[4] = '{2_000_000, 1_500_000, 500_000, 0};
  localparam int unsigned RateReadBytes[4] = '{8, 8, 64, 8};
  logic rate_start = 1'b0;
  logic [31:0] rate_reads, rate_writes, rate_cycles;
  logic [3:0] rate_ready, rate_valid;
  logic [3:0][31:0] rate_values;
  for (genvar i = 0; i < 4; i++) begin : gen_rate_math
    g6lc_ai_pmu_rate #(.ReadBytes(RateReadBytes[i]), .WriteBytes(8), .ClockKhz(RateClocks[i])) rate_dut (
        .clk_i(clk), .rst_ni(rst_n), .start_i(rate_start),
        .reads_i(rate_reads), .writes_i(rate_writes), .cycles_i(rate_cycles),
        .ready_o(rate_ready[i]), .valid_o(rate_valid[i]), .rate_o(rate_values[i])
    );
  end

  task automatic queued_memory_word(input logic [63:0] address, input logic write_word,
                                    input logic [63:0] value, output logic [63:0] observed);
    logic [63:0] offset, local_address;
    int index;
    offset = address - DRAM;
    local_address = ((offset >> (TestCfg.DramChanShift + 1)) << TestCfg.DramChanShift) |
                    (offset & ((64'd1 << TestCfg.DramChanShift) - 1));
    index = int'(local_address >> 3);
    @(negedge clk);
    if (offset[TestCfg.DramChanShift]) begin
      if (write_word) i_mem.gen_sim_stripe.gen_ch[1].i_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[index] = value;
      observed = i_mem.gen_sim_stripe.gen_ch[1].i_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[index];
    end else begin
      if (write_word) i_mem.gen_sim_stripe.gen_ch[0].i_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[index] = value;
      observed = i_mem.gen_sim_stripe.gen_ch[0].i_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[index];
    end
  endtask

  task automatic check_rate(input logic [31:0] reads, writes, elapsed);
    logic [3:0] seen;
    logic [127:0] reference_rate;
    logic [31:0] expected_rate;
    @(negedge clk);
    if (rate_ready != 4'hf) $fatal(1, "RATE_MATH not idle");
    rate_reads = reads;
    rate_writes = writes;
    rate_cycles = elapsed;
    rate_start = 1;
    @(negedge clk);
    rate_start = 0;
    rate_reads = ~reads;
    rate_writes = ~writes;
    rate_cycles = ~elapsed;
    seen = '0;
    for (int guard = 0; guard < 256 && seen != 4'hf; guard++) begin
      for (int i = 0; i < 4; i++) begin
        if (rate_valid[i] && !seen[i]) begin
          reference_rate = elapsed == 0 ? 128'd0 :
              ((128'(reads) * 128'(RateReadBytes[i]) + 128'(writes) * 128'd8) *
               128'(RateClocks[i])) / 128'(elapsed) / 128'd1000;
          expected_rate = reference_rate > 128'hffff_ffff ? 32'hffff_ffff : 32'(reference_rate);
          if (rate_values[i] !== expected_rate)
            $fatal(1, "RATE_MATH i=%0d r=%0d w=%0d cy=%0d got=%0d expected=%0d", i, reads, writes, elapsed, rate_values[i], expected_rate);
          seen[i] = 1;
        end
      end
      @(negedge clk);
    end
    if (seen != 4'hf) $fatal(1, "RATE_MATH timeout seen=%h", seen);
    repeat (2) @(negedge clk);
  endtask

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
      .IslandCfg(TestCfg),
      .EnableDmaFetch(1'b1),
      .AccumulateEn(AccumulateEn),
      .AxiDataWidth(DW),
      .AxiIdWidth(IW),
      .axi_req_t(gd_req_t),
      .axi_resp_t(gd_resp_t)
  ) i_island (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
      .paddr_i(paddr), .pwdata_i(pwdata),
      .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr), .irq_o(irq),
      .sb_enq_valid_i(sb_valid), .sb_enq_ready_o(sb_ready), .sb_qid_i(sb_qid), .sb_ticket_i(sb_ticket),
      .sb_desc_ptr_i(sb_ptr),
      .sb_last_ticket_o(), .sb_last_status_o(), .sb_has_completion_o(), .sb_retired_valid_o(), .sb_retired_ticket_o(), .dma_inval_valid_o(), .dma_inval_addr_o(), .dma_inval_ready_i(1'b0), .dma_inval_done_i(1'b0),
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

  task automatic apb_write(input logic [15:0] addr, input logic [31:0] data, input bit expected_error = 0);
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
    if (pslverr !== expected_error) $fatal(1, "apb write error %h got=%b expected=%b", addr, pslverr, expected_error);
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
    end while (!pready && guard < ((addr == PMU_OFF_GBPS_X1000 ||
        addr == CAP_OFF_DRAM_MEAS_X1000 || addr == CAP_OFF_DRAM_GBPS) ? 256 : 30));
    if (!pready) $fatal(1, "apb read timeout %h", addr);
    last_apb_read_cycles = guard;
    data = prdata;
    psel = 0; penable = 0;
  endtask

  task automatic wait_cpl(output logic [31:0] ticket, output logic [31:0] status);
    logic [31:0] sticky;
    int polls;
    sticky = '0;
    polls = 0;
    while (!(sticky & 32'h1) && polls < 4000) begin
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

    retire_cpl();
    if ($test$plusargs("review_qid")) begin
      int unsigned aw0, ar0;
      aw0 = aw_cnt;
      ar0 = ar_cnt;
      for (int q = 0; q < 2; q++) begin
        automatic logic [7:0] bad_qid = q == 0 ? 8'd2 : 8'd255;
        apb_write(16'h0118, 32'(DRAM));
        apb_write(16'h011C, 32'h0);
        apb_write(16'h0108, 32'h8000_6400 | 32'(bad_qid));
        wait_cpl(ticket, status);
        if (ticket != 100 || status[15:0] != ST_BAD_QID || ar_cnt != ar0 || aw_cnt != aw0)
          $fatal(1, "DMA_QID doorbell q=%0d ticket=%0d status=%h ar=%0d aw=%0d",
                 bad_qid, ticket, status, ar_cnt, aw_cnt);
        retire_cpl();
        sb_kick(bad_qid, 32'd101, DRAM);
        wait_cpl(ticket, status);
        if (ticket != 101 || status[15:0] != ST_BAD_QID || ar_cnt != ar0 || aw_cnt != aw0)
          $fatal(1, "DMA_QID sideband q=%0d ticket=%0d status=%h ar=%0d aw=%0d",
                 bad_qid, ticket, status, ar_cnt, aw_cnt);
        retire_cpl();
      end
      $display("PASS DMA_QID checks=4");
    end
    if ($test$plusargs("review_refuse_capacity") || $test$plusargs("review_fetch_capacity")) begin
      int unsigned ar0, aw0, first;
      bit fetch_error_case;
      fetch_error_case = $test$plusargs("review_fetch_capacity");
      first = fetch_error_case ? 300 : 200;
      ar0 = ar_cnt;
      aw0 = aw_cnt;
      latch_job_ex(OP_LAYOUT, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                   DRAM, DRAM, DRAM, 64'd0, 64'd0);
      for (int unsigned t = first; t < first + 16; t++) begin
        apb_write(16'h0108, 32'(t) << 8);
        settle_job();
      end
      apb_write(16'h0118, 32'(fetch_error_case ? CROSS : DRAM));
      apb_write(16'h011C, 32'h0);
      apb_write(16'h0108, 32'h8000_0000 | ((first + 16) << 8) | (fetch_error_case ? 32'd0 : 32'd2));
      settle_job();
      apb_write(16'h0140, 32'h0001_0063);
      apb_write(16'h0108, (first + 17) << 8);
      for (int unsigned t = first; t < first + 16; t++) begin
        wait_cpl(ticket, status);
        if (ticket != t || status[15:0] != ST_OK)
          $fatal(1, "REFUSE_CAPACITY old ticket=%0d expected=%0d status=%h", ticket, t, status);
        apb_write(16'h010C, 32'h1);
        settle_job();
      end
      wait_cpl(ticket, status);
      if (ticket != first + 16 || status[15:0] != (fetch_error_case ? ST_ERR : ST_BAD_QID))
        $fatal(1, "REFUSE_CAPACITY error ticket=%0d status=%h", ticket, status);
      apb_write(16'h010C, 32'h1);
      settle_job();
      wait_cpl(ticket, status);
      if (ticket != first + 17 || status[15:0] != ST_BAD_VER || ar_cnt != ar0 || aw_cnt != aw0)
        $fatal(1, "REFUSE_CAPACITY next ticket=%0d status=%h ar=%0d aw=%0d", ticket, status, ar_cnt, aw_cnt);
      retire_cpl();
      if (fetch_error_case) $display("PASS FETCH_CAPACITY checks=18");
      else $display("PASS REFUSE_CAPACITY checks=18");
    end
    if ($test$plusargs("review_fetch_identity")) begin
      int ar0, aw0, seen_fetch, seen_latch;
      ar0 = ar_cnt;
      aw0 = aw_cnt;
      seen_fetch = 0;
      seen_latch = 0;
      latch_job_ex(OP_LAYOUT, 32'h0, 32'd1, 32'd1, 32'd1, 16'd1, 16'd1,
                   DRAM, DRAM, DRAM, 64'd0, 64'd0);
      hold_dma_r = 1'b1;
      apb_write(16'h0118, 32'(DRAM));
      apb_write(16'h011C, 32'h0);
      apb_write(16'h0108, 32'h8001_9000);
      for (int cycles = 0; cycles < 100 && ar_cnt == ar0; cycles++) @(negedge clk);
      if (ar_cnt != ar0 + 1) $fatal(1, "FETCH_IDENTITY missing in-flight AR witness");
      apb_write(16'h0108, 32'h0001_9100);
      repeat (8) @(negedge clk);
      hold_dma_r = 1'b0;
      for (int c = 0; c < 2; c++) begin
        wait_cpl(ticket, status);
        if (ticket == 400 && status[15:0] == ST_BAD_VER) seen_fetch++;
        else if (ticket == 401 && status[15:0] == ST_OK) seen_latch++;
        else $fatal(1, "FETCH_IDENTITY unexpected ticket=%0d status=%h", ticket, status);
        apb_write(16'h010C, 32'h1);
      end
      settle_job();
      if (seen_fetch != 1 || seen_latch != 1 || ar_cnt != ar0 + 1 || aw_cnt != aw0)
        $fatal(1, "FETCH_IDENTITY conservation fetch=%0d latch=%0d ar=%0d aw=%0d", seen_fetch, seen_latch, ar_cnt, aw_cnt);
      apb_read(16'h010C, status);
      if (status[0]) $fatal(1, "FETCH_IDENTITY extra completion");
      $display("PASS FETCH_IDENTITY checks=2");
    end
    if ($test$plusargs("review_pmu") || $test$plusargs("review_iterative_pmu")) begin
      logic [31:0] reads, writes, elapsed, rate, alias_rate;
      longint unsigned expected;
      latch_job_ex(OP_GEMM, 32'h0, 32'd16, 32'd16, 32'd64, 16'd64, 16'd64,
                   DRAM + 64'h100, DRAM + 64'h500, DRAM + 64'h900, 64'd0, 64'd0);
      apb_write(16'h0108, 32'h0000_6600);
      wait_cpl(ticket, status);
      if (ticket != 102 || status[15:0] != ST_OK) $fatal(1, "PMU_GEMM failed");
      apb_read(PMU_OFF_R_BEATS, reads);
      apb_read(PMU_OFF_W_BEATS, writes);
      apb_read(PMU_OFF_CYCLES, elapsed);
      apb_read(PMU_OFF_GBPS_X1000, rate);
      if ($test$plusargs("review_iterative_pmu")) begin
        if (last_apb_read_cycles <= 4) $fatal(1, "PMU_STILL_COMBINATIONAL cycles=%0d", last_apb_read_cycles);
        $display("PASS ITERATIVE_PMU wait=%0d", last_apb_read_cycles);
      end
      if (reads != 256 || writes != 128 || elapsed == 0)
        $fatal(1, "PMU_COUNTS r=%0d w=%0d cy=%0d", reads, writes, elapsed);
      expected = ((64'(reads) + 64'(writes)) * 64'd8 * 64'(TestCfg.ClockKhz)) / elapsed / 1000;
      if (64'(rate) != expected) $fatal(1, "PMU_RATE got=%0d expected=%0d", rate, expected);
      apb_read(CAP_OFF_DRAM_MEAS_X1000, alias_rate);
      if (alias_rate != rate) $fatal(1, "PMU_RATE full capability alias");
      apb_read(CAP_OFF_DRAM_GBPS, alias_rate);
      if (alias_rate[15:0] != 16'(TestCfg.DramGBps) ||
          alias_rate[31:16] != (rate > 32'hffff ? 16'hffff : rate[15:0]))
        $fatal(1, "PMU_RATE packed capability alias");
      retire_cpl();
      $display("PASS PMU_RATE reads=%0d writes=%0d cycles=%0d rate=%0d", reads, writes, elapsed, rate);
    end
    if ($test$plusargs("review_queued")) begin
      logic [31:0] value;
      int ar0, aw0;
      if (!QueuedTest) $fatal(1, "QUEUED_TEST missing configuration");
      apb_read(CAP_OFF_COMMAND_QUEUE, value);
      if (value != {16'd2, COMMAND_QUEUE_VERSION, COMMAND_QUEUE_FLAGS})
        $fatal(1, "QUEUED_CAP got=%h", value);
      ar0 = ar_cnt;
      aw0 = aw_cnt;
      apb_write(REG_OFF_CMD_MODE, 1);
      apb_read(REG_OFF_CMD_MODE, value);
      if (value != 1) $fatal(1, "QUEUED_MODE enable");
      for (int t = 500; t < 519; t++) begin
        apb_write(REG_OFF_CMD_PTR_LO, 32'(DRAM));
        apb_write(REG_OFF_CMD_PTR_HI, 0);
        apb_write(REG_OFF_CMD_TICKET, 32'(t));
        apb_write(REG_OFF_CMD_QID, 255);
        apb_write(REG_OFF_CMD_SUBMIT, 1);
        apb_read(REG_OFF_CMD_RECEIPT_TICKET, value);
        if (value != 32'(t)) $fatal(1, "QUEUED_RECEIPT ticket=%0d expected=%0d", value, t);
        apb_read(REG_OFF_CMD_RECEIPT_CODE, value);
        if (value != (t < 518 ? CMD_ACCEPTED : CMD_FULL))
          $fatal(1, "QUEUED_RECEIPT status=%0d ticket=%0d", value, t);
      end
      apb_read(REG_OFF_CMD_CREDITS, value);
      if (value != 0) $fatal(1, "QUEUED_CREDITS full=%0d", value);
      @(negedge clk);
      sb_qid = 255;
      sb_ticket = 900;
      sb_ptr = DRAM;
      sb_valid = 1;
      repeat (8) begin
        @(negedge clk);
        if (sb_ready) $fatal(1, "QUEUED_SIDEBAND accepted while full");
      end
      apb_write(REG_OFF_CMD_MODE, 0, 1);
      apb_write(REG_OFF_CTL, 0, 1);
      apb_write(REG_OFF_QUEUE + 16'h10, 0, 1);
      apb_write(REG_OFF_DOORBELL, 32'h0002_0000, 1);
      apb_read(REG_OFF_QUEUE + 16'h10, value);
      if (value != 3) $fatal(1, "QUEUED_PROTECTION changed");
      fork
        begin
          int guard;
          guard = 0;
          do begin
            @(posedge clk);
            guard++;
          end while (!sb_ready && guard < 2000);
          if (!sb_ready) $fatal(1, "QUEUED_SIDEBAND timeout");
          @(negedge clk);
          sb_valid = 0;
        end
        begin
          for (int t = 500; t < 518; t++) begin
            wait_cpl(ticket, status);
            if (ticket != 32'(t) || status[15:0] != ST_BAD_QID)
              $fatal(1, "QUEUED_COMPLETION ticket=%0d expected=%0d status=%h", ticket, t, status);
            apb_write(REG_OFF_CPL, 1);
          end
        end
      join
      wait_cpl(ticket, status);
      if (ticket != 900 || status[15:0] != ST_BAD_QID) $fatal(1, "QUEUED_SIDEBAND identity");
      apb_write(REG_OFF_CPL, 1);
      settle_job();
      apb_read(REG_OFF_CMD_ACCEPTED, value);
      if (value != 18) $fatal(1, "QUEUED_ACCEPTED count=%0d", value);
      apb_read(REG_OFF_CMD_REJECTED, value);
      if (value != 1) $fatal(1, "QUEUED_REJECTED count=%0d", value);
      apb_read(REG_OFF_CMD_CREDITS, value);
      if (value != 2 || ar_cnt != ar0 || aw_cnt != aw0) $fatal(1, "QUEUED_DRAIN traffic or credits");
      apb_write(REG_OFF_CMD_MODE, 0);
      apb_read(REG_OFF_CMD_MODE, value);
      if (value != 0) $fatal(1, "QUEUED_MODE disable");
      begin
        desc_t d;
        desc_bits_t bits;
        logic [63:0] observed;
        d = '0;
        d.version = ContractVersion;
        d.op = OP_GEMM;
        d.m = 2; d.n = 2; d.k = 2;
        d.ld_ab = {16'd2, 16'd2};
        d.ptr_a = DRAM + 64'h800;
        d.ptr_b = DRAM + 64'h880;
        queued_memory_word(d.ptr_a, 1, 64'h0403_0201, observed);
        queued_memory_word(d.ptr_b, 1, 64'h0806_0705, observed);
        for (int job = 0; job < 2; job++) begin
          d.ptr_c = DRAM + 64'ha00 + 64'(job * 64);
          bits = desc_to_bits(d);
          for (int wi = 0; wi < 8; wi++)
            queued_memory_word(DRAM + 64'h400 + 64'(job * 64 + wi * 8), 1, bits[wi*64 +: 64], observed);
          queued_memory_word(d.ptr_c, 1, 64'ha5a5_a5a5_a5a5_a5a5, observed);
          queued_memory_word(d.ptr_c + 8, 1, 64'ha5a5_a5a5_a5a5_a5a5, observed);
        end
        apb_write(REG_OFF_CMD_MODE, 1);
        for (int job = 0; job < 2; job++) begin
          apb_write(REG_OFF_CMD_PTR_LO, 32'(DRAM + 64'h400 + 64'(job * 64)));
          apb_write(REG_OFF_CMD_PTR_HI, 0);
          apb_write(REG_OFF_CMD_TICKET, 32'hf000_0001 + 32'(job));
          apb_write(REG_OFF_CMD_QID, 0);
          apb_write(REG_OFF_CMD_SUBMIT, 1);
          apb_read(REG_OFF_CMD_RECEIPT_CODE, value);
          if (value != CMD_ACCEPTED) $fatal(1, "QUEUED_GEMM admission");
        end
        for (int job = 0; job < 2; job++) begin
          wait_cpl(ticket, status);
          if (ticket != 32'hf000_0001 + 32'(job) || status[15:0] != ST_OK)
            $fatal(1, "QUEUED_GEMM completion ticket=%h status=%h", ticket, status);
          queued_memory_word(DRAM + 64'ha00 + 64'(job * 64), 0, 0, observed);
          if (observed != 64'h0000_0016_0000_0013) $fatal(1, "QUEUED_GEMM C row0=%h", observed);
          queued_memory_word(DRAM + 64'ha08 + 64'(job * 64), 0, 0, observed);
          if (observed != 64'h0000_0032_0000_002b) $fatal(1, "QUEUED_GEMM C row1=%h", observed);
          apb_write(REG_OFF_CPL, 1);
        end
        settle_job();
        apb_write(REG_OFF_CMD_MODE, 0);
      end
      $display("PASS QUEUED checks=21");
    end
    // accmode 01 through the descriptor engine and the queued path: the second
    // submission of the same 2x2x2 job seeds from C and doubles it in place; the
    // reserved accmode 10 is refused with ST_BAD_FMT and leaves C untouched.
    if ($test$plusargs("review_accumulate")) begin
      logic [31:0] value;
      desc_t d;
      desc_bits_t bits;
      logic [63:0] observed;
      int checks;
      checks = 0;
      if (!QueuedTest) $fatal(1, "ACCUMULATE_TEST needs the queued configuration");
      apb_read(CAP_OFF_ACCMODE, value);
      if (value != 32'(AccumulateEn)) $fatal(1, "ACCUMULATE_CAP got=%h", value);
      checks++;
      // Operand bank capacity words (flat panel mapping): A and B banks of this
      // configuration, in bytes, as g6lc_ai_gemm_seq sizes them.
      apb_read(CAP_OFF_BANK_A_BYTES, value);
      if (value != ai_operand_bank_bytes(TestCfg.AccTileM, TestCfg.AccTileK, TestCfg.MacsPerCycle, 1))
        $fatal(1, "BANK_A_BYTES got=%0d", value);
      apb_read(CAP_OFF_BANK_B_BYTES, value);
      if (value != ai_operand_bank_bytes(TestCfg.AccTileN, TestCfg.AccTileK, TestCfg.MacsPerCycle, 1))
        $fatal(1, "BANK_B_BYTES got=%0d", value);
      checks += 2;
      d = '0;
      d.version = ContractVersion;
      d.op = OP_GEMM;
      d.m = 2; d.n = 2; d.k = 2;
      d.ld_ab = {16'd2, 16'd2};
      d.ptr_a = DRAM + 64'h800;
      d.ptr_b = DRAM + 64'h880;
      d.ptr_c = DRAM + 64'hb00;
      queued_memory_word(d.ptr_a, 1, 64'h0403_0201, observed);
      queued_memory_word(d.ptr_b, 1, 64'h0806_0705, observed);
      queued_memory_word(d.ptr_c, 1, 64'ha5a5_a5a5_a5a5_a5a5, observed);
      queued_memory_word(d.ptr_c + 8, 1, 64'ha5a5_a5a5_a5a5_a5a5, observed);
      apb_write(REG_OFF_CMD_MODE, 1);
      // job 0: overwrite; job 1: accumulate (01); job 2: reserved (10).
      for (int job = 0; job < 3; job++) begin
        d.flags = 32'(job) << FLAG_ACCMODE_SHIFT;
        bits = desc_to_bits(d);
        for (int wi = 0; wi < 8; wi++)
          queued_memory_word(DRAM + 64'h600 + 64'(wi * 8), 1, bits[wi*64 +: 64], observed);
        apb_write(REG_OFF_CMD_PTR_LO, 32'(DRAM + 64'h600));
        apb_write(REG_OFF_CMD_PTR_HI, 0);
        apb_write(REG_OFF_CMD_TICKET, 32'hacc0_0000 + 32'(job));
        apb_write(REG_OFF_CMD_QID, 0);
        apb_write(REG_OFF_CMD_SUBMIT, 1);
        apb_read(REG_OFF_CMD_RECEIPT_CODE, value);
        if (value != CMD_ACCEPTED) $fatal(1, "ACCUMULATE admission job=%0d", job);
        wait_cpl(ticket, status);
        if (ticket != 32'hacc0_0000 + 32'(job)) $fatal(1, "ACCUMULATE ticket=%h job=%0d", ticket, job);
        if (status[15:0] != ((job == 2) ? ST_BAD_FMT : ST_OK))
          $fatal(1, "ACCUMULATE status=%h job=%0d", status, job);
        apb_write(REG_OFF_CPL, 1);
        queued_memory_word(d.ptr_c, 0, 0, observed);
        if (observed != ((job == 0) ? 64'h0000_0016_0000_0013 : 64'h0000_002c_0000_0026))
          $fatal(1, "ACCUMULATE C row0=%h job=%0d", observed, job);
        queued_memory_word(d.ptr_c + 8, 0, 0, observed);
        if (observed != ((job == 0) ? 64'h0000_0032_0000_002b : 64'h0000_0064_0000_0056))
          $fatal(1, "ACCUMULATE C row1=%h job=%0d", observed, job);
        checks += 3;
      end
      settle_job();
      apb_write(REG_OFF_CMD_MODE, 0);
      $display("PASS ACCUMULATE_ISLAND checks=%0d", checks);
    end
    // Standalone replay of the SoC ELF ai_gemm_tile_2x2_smoke: four latched-doorbell
    // 16x16x32 all-ones GEMM tiles (tickets 31..34) with a claim between them, then the
    // whole packed C checked. The SoC run completes the second job with the first ticket
    // in some code layouts; if this island-only replay passes, the defect is outside the
    // island (bridge/core path), if it fails it is reproducible here with a waveform.
    if ($test$plusargs("review_tile_seq")) begin
      logic [31:0] value;
      desc_t d;
      desc_bits_t bits;
      logic [63:0] observed, base_a, base_b, base_c;
      int checks, tile;
      checks = 0;
      base_a = DRAM + 64'h0800; base_b = DRAM + 64'h0c00; base_c = DRAM + 64'h1000;
      apb_write(16'h0100, 32'h1);
      apb_write(16'h0120, 32'(DRAM)); apb_write(16'h0124, 32'(DRAM >> 32));
      apb_write(16'h0128, 32'(DRAM + 64'h4000)); apb_write(16'h012C, 32'((DRAM + 64'h4000) >> 32));
      apb_write(16'h0130, 32'h3);
      for (int w = 0; w < 128; w++) begin
        queued_memory_word(base_a + 64'(w * 8), 1, 64'h0101_0101_0101_0101, observed);
        queued_memory_word(base_b + 64'(w * 8), 1, 64'h0101_0101_0101_0101, observed);
      end
      for (int w = 0; w < 512; w++) queued_memory_word(base_c + 64'(w * 8), 1, 64'h0, observed);
      for (tile = 0; tile < 4; tile++) begin
        d = '0;
        d.version = ContractVersion;
        d.op = OP_GEMM;
        d.m = 16; d.n = 16; d.k = 32;
        d.ld_ab = {16'd32, 16'd32};
        d.ptr_a = base_a + 64'((tile / 2) * 512);
        d.ptr_b = base_b + 64'((tile % 2) * 512);
        d.ptr_c = base_c + 64'(tile * 1024);
        bits = desc_to_bits(d);
        for (int wi = 0; wi < 16; wi++) apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
        apb_read(16'h0100, value);
        apb_write(16'h0108, 32'(31 + tile) << 8);
        wait_cpl(ticket, status);
        if (status[15:0] != ST_OK) $fatal(1, "TILE_SEQ status=%h tile=%0d", status, tile);
        if (ticket != 32'(31 + tile)) $fatal(1, "TILE_SEQ ticket=%0d expected=%0d tile=%0d", ticket, 31 + tile, tile);
        checks += 2;
        apb_write(16'h010C, 32'h1);
        apb_read(16'h010C, value);
        if (value & 32'h1) $fatal(1, "TILE_SEQ sticky after claim tile=%0d", tile);
        checks++;
      end
      for (int w = 0; w < 512; w++) begin
        queued_memory_word(base_c + 64'(w * 8), 0, 0, observed);
        if (observed != 64'h0000_0020_0000_0020) $fatal(1, "TILE_SEQ C word %0d = %h", w, observed);
      end
      checks++;
      $display("PASS TILE_SEQ checks=%0d", checks);
    end
    if ($test$plusargs("review_rate_math")) begin
      logic [31:0] seed;
      seed = 32'h6ac0_2026;
      check_rate(0, 0, 0);
      check_rate(512, 0, 1024);
      check_rate(32'hffff_ffff, 32'hffff_ffff, 1);
      check_rate(32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff);
      for (int i = 0; i < 64; i++) begin
        seed = seed * 32'd1664525 + 32'd1013904223;
        check_rate(seed, {seed[15:0], seed[31:16]}, (i % 4 == 0) ? seed & 32'h3ff : seed ^ 32'ha5a5_5a5a);
      end
      $display("PASS RATE_MATH checks=272");
    end
    if ($test$plusargs("oracle_negative")) $fatal(1, "FAIL oracle negative control");
    $display("PASS tb_g6lc_ai_desc_island");
    $finish;
  end

  initial begin
    repeat (400000) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
