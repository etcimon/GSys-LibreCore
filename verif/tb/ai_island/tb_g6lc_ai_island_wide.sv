// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Live island geometry on the non-default DMA width: AiIslandLatencyDefault
// (256 MAC/cycle) with AxiDataWidth=512, through g6lc_ai_dram_join onto a
// 64-bit channel. One 8x8x8 INT8 GEMM, then a 1-byte row whose load is a
// 64-byte beat. Does not set G6LC_AI_DRAM_ISLAND_PORT.

`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_island_wide;
  import g6lc_ai_desc_pkg::*;
  import g6lc_ai_island_cfg_pkg::*;

  localparam int unsigned AW = 64;
  localparam int unsigned DW = 64;
  localparam int unsigned IW = 4;
  localparam int unsigned UW = 1;
  localparam int unsigned ISW = 512;
  localparam logic [63:0] DRAM = 64'h8000_0000;
  localparam logic [63:0] DESC = DRAM;
  localparam logic [63:0] PA   = DRAM + 64'h100;
  localparam logic [63:0] PB   = DRAM + 64'h200;
  localparam logic [63:0] PC   = DRAM + 64'h300;
  localparam logic [63:0] DONE = DRAM + 64'h400;
  localparam logic [63:0] ONES = 64'h0101_0101_0101_0101;
  localparam logic [63:0] C8   = 64'h0000_0008_0000_0008;
  localparam logic [63:0] SENT = 64'hDEAD_BEEF_DEAD_BEEF;
  localparam logic [63:0] CPL  = 64'h0000_0000_0000_000A;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  typedef logic [AW-1:0]    addr_t;
  typedef logic [IW-1:0]    id_t;
  typedef logic [UW-1:0]    user_t;
  typedef logic [ISW-1:0]   data_t;
  typedef logic [ISW/8-1:0] strb_t;
  `AXI_TYPEDEF_ALL(gwide, addr_t, id_t, data_t, strb_t, user_t)

  gwide_req_t  dma_req, dma_req_g;
  gwide_resp_t dma_rsp, dma_rsp_g;
  assign dma_req_g = rst_n ? dma_req : '0;
  assign dma_rsp_g = rst_n ? dma_rsp : '0;

  logic psel, penable, pwrite, pready, pslverr, irq;
  logic [31:0] paddr, pwdata, prdata;
  logic init_done;
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r, ch_w;
  int unsigned ar_cnt, aw_cnt;
  int unsigned cap_gen = 0;
  logic [63:0] ar_addr_seen;
  logic [2:0]  ar_size_seen;

  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      cl ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(ISW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      isb ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW + 1), .AXI_USER_WIDTH(UW))
      mst ();

  `AXI_ASSIGN_FROM_REQ(isb, dma_req_g)
  `AXI_ASSIGN_TO_RESP(dma_rsp, isb)

  always @(posedge clk) begin
    if (!rst_n) begin
      ar_cnt       <= 0;
      aw_cnt       <= 0;
      ar_addr_seen <= '0;
      ar_size_seen <= '0;
    end else begin
      if (dma_req_g.ar_valid && dma_rsp_g.ar_ready) begin
        ar_cnt <= ar_cnt + 1;
        // First island AR after cap_gen is armed. DRAM addresses are nonzero.
        if (cap_gen != 0 && ar_addr_seen == '0) begin
          ar_addr_seen <= dma_req_g.ar.addr;
          ar_size_seen <= 3'(dma_req_g.ar.size);
        end
      end
      if (dma_req_g.aw_valid && dma_rsp_g.aw_ready)
        aw_cnt <= aw_cnt + 1;
    end
  end

  g6lc_ai_island_apb #(
      .IslandCfg(AiIslandLatencyDefault),
      .EnableDmaFetch(1'b1),
      .AxiDataWidth(ISW),
      .AxiIdWidth(IW),
      .axi_req_t(gwide_req_t),
      .axi_resp_t(gwide_resp_t)
  ) i_island (
      .clk_i(clk),
      .rst_ni(rst_n),
      .testmode_i(1'b0),
      .psel_i(psel),
      .penable_i(penable),
      .pwrite_i(pwrite),
      .paddr_i(paddr),
      .pwdata_i(pwdata),
      .prdata_o(prdata),
      .pready_o(pready),
      .pslverr_o(pslverr),
      .irq_o(irq),
      .sb_enq_valid_i(1'b0),
      .sb_enq_ready_o(),
      .sb_qid_i(8'd0),
      .sb_ticket_i(32'd0),
      .sb_desc_ptr_i(64'd0),
      .sb_last_ticket_o(),
      .sb_last_status_o(),
      .sb_has_completion_o(),
      .sb_retired_valid_o(),
      .sb_retired_ticket_o(), .dma_inval_valid_o(), .dma_inval_addr_o(), .dma_inval_ready_i(1'b0), .dma_inval_done_i(1'b0),
      .axi_dma_req_o(dma_req),
      .axi_dma_resp_i(dma_rsp_g),
      .dram_init_done_i(init_done),
      .ch_r_beats_i(ch_r),
      .ch_w_beats_i(ch_w)
  );

  g6lc_ai_dram_join #(
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW),
      .ISLAND_DATA_WIDTH(ISW), .MAX_AR_OUT(2),
      .DRAM_BASE(DRAM), .DRAM_BYTES(64'h0001_0000), .FATAL_LOCK(1'b1)
  ) i_join (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .init_done_i(init_done),
      .cluster(cl), .island(isb), .master(mst)
  );

  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW + 1), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(2048),
      .NrChannels(1), .ChanShift(6), .MaxAROut(2)
  ) i_mem (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(mst), .init_done_o(init_done),
      .ch_r_beats_o(ch_r), .ch_w_beats_o(ch_w)
  );

  task automatic idle_cl;
    cl.aw_valid = 0; cl.w_valid = 0; cl.b_ready = 0;
    cl.ar_valid = 0; cl.r_ready = 0;
  endtask

  task automatic wr64(input logic [63:0] addr, input logic [63:0] data);
    int guard;
    bit aw_done, w_done;
    @(negedge clk);
    aw_done = 0;
    w_done = 0;
    cl.aw_id = '0; cl.aw_addr = addr; cl.aw_len = 0; cl.aw_size = 3;
    cl.aw_burst = 1; cl.aw_lock = 0; cl.aw_cache = 0; cl.aw_prot = 0;
    cl.aw_qos = 0; cl.aw_region = 0; cl.aw_atop = 0; cl.aw_user = 0;
    cl.aw_valid = 1; cl.b_ready = 1;
    cl.w_data = data; cl.w_strb = '1; cl.w_last = 1; cl.w_user = 0; cl.w_valid = 1;
    guard = 0;
    while (!(aw_done && w_done) && guard < 80) begin
      @(posedge clk);
      if (cl.aw_valid && cl.aw_ready) aw_done = 1;
      if (cl.w_valid && cl.w_ready) w_done = 1;
      guard++;
      @(negedge clk);
      if (aw_done) cl.aw_valid = 0;
      if (w_done) cl.w_valid = 0;
    end
    if (!(aw_done && w_done))
      $fatal(1, "cluster AW/W timeout %h aw %b w %b", addr, aw_done, w_done);
    guard = 0;
    do begin @(posedge clk); guard++; end while (!cl.b_valid && guard < 80);
    if (!cl.b_valid) $fatal(1, "cluster B timeout %h", addr);
    @(negedge clk);
    cl.b_ready = 0;
  endtask

  task automatic rd64(input logic [63:0] addr, output logic [63:0] data);
    int guard;
    @(negedge clk);
    cl.ar_id = 4'h1; cl.ar_addr = addr; cl.ar_len = 0; cl.ar_size = 3;
    cl.ar_burst = 1; cl.ar_lock = 0; cl.ar_cache = 0; cl.ar_prot = 0;
    cl.ar_qos = 0; cl.ar_region = 0; cl.ar_user = 0;
    cl.ar_valid = 1; cl.r_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!cl.ar_ready && guard < 200);
    if (!cl.ar_ready) $fatal(1, "cluster AR timeout %h", addr);
    @(negedge clk);
    cl.ar_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(cl.r_valid && cl.r_last) && guard < 200);
    if (!(cl.r_valid && cl.r_last)) $fatal(1, "cluster R timeout %h", addr);
    data = cl.r_data;
    @(negedge clk);
    cl.r_ready = 0;
  endtask

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
    end while (!pready && guard < ((addr == PMU_OFF_GBPS_X1000 ||
        addr == CAP_OFF_DRAM_MEAS_X1000 || addr == CAP_OFF_DRAM_GBPS) ? 256 : 30));
    if (!pready) $fatal(1, "apb read timeout %h", addr);
    data = prdata;
    psel = 0; penable = 0;
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

  task automatic set_window(input logic [63:0] base, input logic [63:0] limit);
    apb_write(16'h0120, base[31:0]);
    apb_write(16'h0124, base[63:32]);
    apb_write(16'h0128, limit[31:0]);
    apb_write(16'h012C, limit[63:32]);
    apb_write(16'h0130, 32'h3);
  endtask

  task automatic latch_gemm(
      input logic [63:0] pa, input logic [63:0] pb, input logic [63:0] pc);
    desc_t d;
    desc_bits_t bits;
    int unsigned wi;
    d = '0;
    d.version = 16'(ContractVersion);
    d.op = OP_GEMM;
    d.m = 32'd1; d.n = 32'd1; d.k = 32'd1;
    d.ld_ab = {16'd1, 16'd1};
    d.ptr_a = pa; d.ptr_b = pb; d.ptr_c = pc;
    bits = desc_to_bits(d);
    for (wi = 0; wi < 16; wi++)
      apb_write(16'h0140 + 16'(wi << 2), bits[wi*32 +: 32]);
  endtask

  initial begin
    desc_t d;
    desc_bits_t bits;
    logic [63:0] got;
    logic [31:0] sticky, ticket, status;
    int unsigned wsnap, i, polls;
    psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;
    idle_cl();
    rst_n = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);
    if (dma_req_g.ar_valid || dma_req_g.aw_valid)
      $fatal(1, "island DMA not idle after reset");

    d = '0;
    d.version = 16'(ContractVersion);
    d.op      = OP_GEMM;
    d.m = 32'd8; d.n = 32'd8; d.k = 32'd8;
    d.ld_ab = {16'd8, 16'd8};
    d.ptr_a = PA; d.ptr_b = PB; d.ptr_c = PC; d.ptr_done = DONE;
    bits = desc_to_bits(d);
    for (i = 0; i < 8; i++)
      wr64(DESC + (64'(i) << 3), bits[i*64 +: 64]);
    for (i = 0; i < 8; i++) begin
      wr64(PA + (64'(i) << 3), ONES);
      wr64(PB + (64'(i) << 3), ONES);
    end
    for (i = 0; i < 32; i++)
      wr64(PC + (64'(i) << 3), 64'h0);
    wr64(DONE, 64'h0);
    wr64(DONE + 64'd8, SENT);
    wr64(PC - 64'd8, SENT);

    wsnap = ch_w[0];
    apb_write(16'h0100, 32'h3);
    apb_write(16'h0120, 32'(DRAM));
    apb_write(16'h0124, 32'(DRAM >> 32));
    apb_write(16'h0128, 32'(DRAM + 64'h1000));
    apb_write(16'h012C, 32'h0);
    apb_write(16'h0130, 32'h3);
    apb_write(16'h0118, 32'(DESC));
    apb_write(16'h011C, 32'(DESC >> 32));
    apb_write(16'h0108, 32'h8000_0A00);

    sticky = '0; ticket = '0; status = '1;
    polls = 0;
    while (!(sticky & 32'h1) && polls < 4000) begin
      apb_read(16'h010C, sticky);
      polls++;
    end
    if (!(sticky & 32'h1))
      $fatal(1, "GEMM timeout polls=%0d", polls);
    apb_read(16'h0110, ticket);
    apb_read(16'h0114, status);
    if (status[15:0] != ST_OK || ticket != 32'd10)
      $fatal(1, "GEMM status=%h ticket=%0d", status, ticket);

    for (i = 0; i < 32; i++) begin
      rd64(PC + (64'(i) << 3), got);
      if (got !== C8)
        $fatal(1, "C[%0d] exp %h got %h", i, C8, got);
    end
    rd64(PC - 64'd8, got);
    if (got !== SENT) $fatal(1, "C neighbor smashed %h", got);
    rd64(DONE, got);
    if (got !== CPL) $fatal(1, "completion exp %h got %h", CPL, got);
    rd64(DONE + 64'd8, got);
    if (got !== SENT) $fatal(1, "completion neighbor smashed %h", got);
    if (ch_w[0] != wsnap + 33)
      $fatal(1, "channel W beats %0d after preload %0d", ch_w[0], wsnap);

    // 0x18C must bill C stores at 8 bytes. A/B reads stay 512-bit beats.
    // The completion word is outside the GEMM PMU, so W is the 32 C pairs.
    begin
      logic [31:0] pmu_r, pmu_w, pmu_cy, pmu_gbps, exp_gbps, wide_gbps;
      apb_read(16'h0180, pmu_r);
      apb_read(16'h0184, pmu_w);
      apb_read(16'h0188, pmu_cy);
      apb_read(16'h018C, pmu_gbps);
      if (pmu_w != 32 || pmu_r == 0 || pmu_cy == 0)
        $fatal(1, "PMU r=%0d w=%0d cy=%0d", pmu_r, pmu_w, pmu_cy);
      exp_gbps = ((pmu_r * 32'(ISW / 8) + pmu_w * 32'd8) *
                  32'(AiIslandLatencyDefault.ClockKhz)) / pmu_cy / 32'd1000;
      wide_gbps = ((pmu_r + pmu_w) * 32'(ISW / 8) *
                   32'(AiIslandLatencyDefault.ClockKhz)) / pmu_cy / 32'd1000;
      if (pmu_gbps !== exp_gbps)
        $fatal(1, "PMU milli-GB/s exp %0d got %0d (r=%0d w=%0d cy=%0d)",
               exp_gbps, pmu_gbps, pmu_r, pmu_w, pmu_cy);
      if (pmu_gbps == wide_gbps)
        $fatal(1, "PMU billed C stores at the 512-bit beat (%0d)", pmu_gbps);
    end

    // A/B loads on this port are 64-byte beats. A 1-byte row still occupies
    // the whole beat, including bytes before the element.
    retire_cpl();
    begin
      int unsigned ar0, aw0;
      logic [31:0] rsnap, wsnap;
      logic [63:0] got;
      logic [31:0] tk, st;
      ar0 = ar_cnt;
      aw0 = aw_cnt;
      // 63 bytes covers the element and not the last byte of the beat.
      set_window(DRAM + 64'h100, DRAM + 64'h13F);
      latch_gemm(DRAM + 64'h100, DRAM + 64'h100, DRAM + 64'h100);
      apb_write(16'h0108, 32'h0000_0B00);
      wait_cpl(tk, st);
      if (tk != 32'd11 || st[15:0] != ST_BAD_PTR || ar_cnt != ar0 || aw_cnt != aw0)
        $fatal(1, "short beat ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               tk, st, aw_cnt, ar_cnt, aw0, ar0);
      retire_cpl();
      // The element and the beat tail sit in the window. The beat base does not.
      set_window(DRAM + 64'h120, DRAM + 64'h180);
      latch_gemm(DRAM + 64'h120, DRAM + 64'h120, DRAM + 64'h120);
      apb_write(16'h0108, 32'h0000_0C00);
      wait_cpl(tk, st);
      if (tk != 32'd12 || st[15:0] != ST_BAD_PTR || ar_cnt != ar0 || aw_cnt != aw0)
        $fatal(1, "beat prefix ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               tk, st, aw_cnt, ar_cnt, aw0, ar0);
      retire_cpl();
      rsnap = ch_r[0];
      wsnap = ch_w[0];
      cap_gen = 1;
      set_window(DRAM + 64'h100, DRAM + 64'h140);
      latch_gemm(DRAM + 64'h120, DRAM + 64'h100, DRAM + 64'h100);
      apb_write(16'h0108, 32'h0000_0D00);
      wait_cpl(tk, st);
      if (tk != 32'd13 || st[15:0] != ST_OK || ar_cnt != ar0 + 2 || aw_cnt != aw0 + 1)
        $fatal(1, "beat window ticket %0d status %h aw %0d ar %0d (was %0d/%0d)",
               tk, st, aw_cnt, ar_cnt, aw0, ar0);
      if (ar_addr_seen != DRAM + 64'h100 || ar_size_seen != 3'd6)
        $fatal(1, "beat AR addr %h size %0d", ar_addr_seen, ar_size_seen);
      if (ch_r[0] != rsnap + 32'd16)
        $fatal(1, "channel R %0d -> %0d", rsnap, ch_r[0]);
      if (ch_w[0] != wsnap + 32'd1)
        $fatal(1, "channel W %0d -> %0d", wsnap, ch_w[0]);
      rd64(DRAM + 64'h100, got);
      if (got !== 64'h0101_0101_0000_0001)
        $fatal(1, "C beat word %h", got);
    end

    $display("PASS tb_g6lc_ai_island_wide");
    $finish;
  end
endmodule
