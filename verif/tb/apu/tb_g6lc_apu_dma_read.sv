// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module g6lc_apu_dma_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1,
  parameter bit HighAddress = 0,
  parameter int unsigned BurstBeats = 16
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, cancel_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input apu_dma_read_req_t req_i,
  input apu_dma_mapping_t mapping_i,
  output logic data_valid_o,
  input logic data_ready_i,
  output apu_dma_read_data_t data_o,
  output logic cpl_valid_o,
  input logic cpl_ready_i,
  output apu_dma_read_cpl_t cpl_o,
  output logic idle_o, bus_fault_o,
  output apu_dma_axi_req_t axi_req_o,
  input apu_dma_axi_resp_t axi_rsp_i
);
  function automatic apu_cfg_t test_cfg();
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = Enable;
    cfg.DmaReadEn = Enable;
    cfg.DmaWindowBase = 64'h8000_0000 + (HighAddress ? 64'h2_0000_0000 : 64'h0);
    cfg.DmaWindowBytes = 64'h1000_0000;
    cfg.DmaReadBurstBeats = BurstBeats;
    cfg.FirmwareRamBase = cfg.DmaWindowBase + cfg.DmaWindowBytes;
    cfg.FirmwareRamBytes = 64'h40000;
    cfg.FirmwareHart = 1;
    return cfg;
  endfunction
  g6lc_apu_dma_read #(.ApuCfg(test_cfg())) i_dut (.*);
endmodule

module tb_g6lc_apu_dma_read;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  parameter bit HighAddress = 0;
  parameter int unsigned BurstBeats = 16;
  localparam logic [63:0] WindowBase = 64'h8000_0000 + (HighAddress ? 64'h2_0000_0000 : 0);

  logic clk = 0, rst_ni = 0;
  logic enable, cancel, req_valid, req_ready, data_valid, data_ready, cpl_valid, cpl_ready;
  logic idle, bus_fault;
  apu_dma_read_req_t req, expected_req;
  apu_dma_mapping_t mapping;
  apu_dma_read_data_t data;
  apu_dma_read_cpl_t cpl;
  apu_dma_axi_req_t axi_req;
  apu_dma_axi_resp_t axi_rsp;
  logic off_req_ready, off_data_valid, off_cpl_valid, off_idle, off_fault;
  apu_dma_read_data_t off_data;
  apu_dma_read_cpl_t off_cpl;
  apu_dma_axi_req_t off_axi;
  logic allow_ar, allow_r, allow_data, stray_r;
  logic model_active, model_rvalid, injected;
  apu_dma_axi_r_chan_t model_r;
  logic [63:0] model_addr, expected_begin, next_ar;
  int unsigned model_left, model_step;
  int injection;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int ar_count, r_count, delivered;
  logic [31:0] byte_count;

  g6lc_apu_dma_fixture #(.HighAddress(HighAddress), .BurstBeats(BurstBeats)) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req), .mapping_i(mapping),
    .data_valid_o(data_valid), .data_ready_i(data_ready), .data_o(data),
    .cpl_valid_o(cpl_valid), .cpl_ready_i(cpl_ready), .cpl_o(cpl),
    .idle_o(idle), .bus_fault_o(bus_fault), .axi_req_o(axi_req), .axi_rsp_i(axi_rsp)
  );
  g6lc_apu_dma_fixture #(.Enable(0), .HighAddress(HighAddress), .BurstBeats(BurstBeats)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .req_valid_i(req_valid), .req_ready_o(off_req_ready), .req_i(req), .mapping_i(mapping),
    .data_valid_o(off_data_valid), .data_ready_i(data_ready), .data_o(off_data),
    .cpl_valid_o(off_cpl_valid), .cpl_ready_i(cpl_ready), .cpl_o(off_cpl),
    .idle_o(off_idle), .bus_fault_o(off_fault), .axi_req_o(off_axi), .axi_rsp_i(axi_rsp)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin
    #5000000;
    $fatal(1, "APU DMA timeout cases=%0d ar=%0d r=%0d", cases, ar_count, r_count);
  end
  task automatic check(input string name, input logic condition);
    checks++;
    if (condition !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  function automatic logic [7:0] memory_byte(input logic [63:0] addr);
    return 8'(addr ^ (addr >> 8) ^ (addr >> 32) ^ 64'h5a);
  endfunction
  function automatic logic [63:0] memory_word(input logic [63:0] addr);
    logic [63:0] word;
    for (int b = 0; b < 8; b++) word[8*b +: 8] = memory_byte((addr & ~64'd7) + 64'(b));
    return word;
  endfunction
  function automatic apu_dma_mapping_t good_mapping();
    return '{valid: 1'b1, permissions: 2'b01, resource_id: 32'h8000_0001,
             context_id: 32'hf000_0002, epoch: 32'h1234_5678,
             base: WindowBase + 64'h10000, bytes: 64'h20000};
  endfunction
  function automatic apu_dma_read_req_t job(input logic [63:0] offset,
                                           input logic [31:0] bytes);
    return '{resource_id: 32'h8000_0001, context_id: 32'hf000_0002,
             epoch: 32'h1234_5678, offset: offset, bytes: bytes,
             tag: 64'hfedc_ba98_0000_0000 | 64'(cases)};
  endfunction

  assign data_ready = allow_data && cycles % 5 != 0;
  always_comb begin
    axi_rsp = '0;
    axi_rsp.ar_ready = allow_ar && !model_active && !model_rvalid && cycles % 4 != 0;
    axi_rsp.r_valid = model_rvalid || stray_r;
    axi_rsp.r = stray_r ? apu_dma_axi_r_chan_t'{id: '0, data: '0, resp: 2'b00,
                                              last: 1'b1, user: '0} : model_r;
  end
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      model_active <= 0;
      model_rvalid <= 0;
      model_addr <= 0;
      model_left <= 0;
      model_step <= 0;
      model_r <= '0;
    end else begin
      if (axi_req.ar_valid && axi_rsp.ar_ready) begin
        model_active <= 1;
        model_addr <= axi_req.ar.addr;
        model_left <= 32'(axi_req.ar.len) + 1 + 32'(injection == 3 && !injected);
        model_step <= 1 << axi_req.ar.size;
      end
      if (model_active && !model_rvalid && allow_r && cycles % 3 != 0) begin
        model_rvalid <= 1;
        model_r <= '{id: '0, data: memory_word(model_addr), resp: 2'b00,
                     last: model_left == 1, user: '0};
        if (!injected) begin
          if (injection == 1) model_r.resp <= axi_pkg::RESP_SLVERR;
          if (injection == 6) model_r.resp <= axi_pkg::RESP_DECERR;
          if (injection == 2) model_r.last <= 1;
          if (injection == 4) model_r.id <= 1;
        end
        if (injection == 5 && r_count == 1) model_r.resp <= axi_pkg::RESP_SLVERR;
      end
      if (model_rvalid && axi_req.r_ready) begin
        model_rvalid <= 0;
        model_addr <= model_addr + 64'(model_step);
        model_left <= model_left - 1;
        if (model_r.last) model_active <= 0;
      end
    end
  end
  always @(posedge clk) begin
    if (rst_ni) begin
      check("read master never writes", !axi_req.aw_valid && !axi_req.w_valid && !axi_req.b_ready);
      if (axi_req.ar_valid && axi_rsp.ar_ready) begin
        logic [63:0] span, last;
        span = (64'(axi_req.ar.len) + 1) << axi_req.ar.size;
        last = axi_req.ar.addr + span - 1;
        ar_count++;
        check("one outstanding burst", !model_active && !model_rvalid);
        check("AXI read attributes", axi_req.ar.burst == axi_pkg::BURST_INCR &&
              axi_req.ar.id == 0 && axi_req.ar.cache == 0 && axi_req.ar.prot == 0);
        check("burst length limit", 32'(axi_req.ar.len) + 1 <= BurstBeats);
        check("narrow access alignment", axi_req.ar.size <= 3 &&
              (axi_req.ar.addr % (64'd1 << axi_req.ar.size)) == 0);
        check("4 KiB boundary", axi_req.ar.addr[63:12] == last[63:12]);
        check("no request overread", last >= axi_req.ar.addr && axi_req.ar.addr >= expected_begin &&
              last - expected_begin < 64'(byte_count));
        check("monotonic contiguous burst addresses", axi_req.ar.addr == next_ar);
        next_ar = last + 1;
      end
      if (axi_rsp.r_valid && axi_req.r_ready && !stray_r) begin
        r_count++;
        if (injection != 0) injected = 1;
      end
      if (data_valid && data_ready) begin
        int n;
        n = $countones(data.keep);
        check("nonempty contiguous keep", n > 0 && n <= 8 && data.keep == 8'((1 << n) - 1));
        check("stream offset", data.offset == 32'(delivered));
        for (int b = 0; b < 8; b++) begin
          if (b < n)
            check("byte exact data", data.data[8*b +: 8] == memory_byte(expected_begin + 64'(delivered + b)));
          else check("unused lanes zero", data.data[8*b +: 8] == 0);
        end
        delivered += n;
        check("no excess output", delivered <= int'(byte_count));
        check("stream last", data.last == (delivered == int'(byte_count)));
      end
    end
  end
  always @(negedge clk) begin
    #1;
    if ({off_req_ready, off_data_valid, off_data, off_cpl_valid, off_cpl, off_fault, off_axi} !== '0 ||
        off_idle !== 1'b1) $fatal(1, "disabled DMA active");
  end

  task automatic reset_bus;
    @(negedge clk);
    req_valid = 0;
    rst_ni = 0;
    stray_r = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    enable = 1;
    cancel = 0;
    allow_ar = 1;
    allow_r = 1;
    allow_data = 1;
    cpl_ready = 0;
  endtask
  task automatic issue(input apu_dma_read_req_t request,
                       input apu_dma_mapping_t region, input int mode = 0);
    @(negedge clk);
    while (!req_ready) @(negedge clk);
    cases++;
    ar_count = 0;
    r_count = 0;
    delivered = 0;
    injection = mode;
    injected = 0;
    expected_begin = region.base + request.offset;
    next_ar = expected_begin;
    byte_count = request.bytes;
    expected_req = request;
    req = request;
    mapping = region;
    req_valid = 1;
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    @(negedge clk);
    req_valid = 0;
    req = '0;
    mapping = '0;
  endtask
  task automatic finish(input apu_dma_status_e expected, input bit no_ar = 0);
    apu_dma_read_cpl_t saved;
    @(negedge clk);
    while (!cpl_valid) @(negedge clk);
    saved = cpl;
    if (cpl.status != expected)
      $display("DMA status got=%0d expected=%0d", cpl.status, expected);
    check("completion status", cpl.status == expected);
    check("completion metadata", cpl.tag == expected_req.tag && cpl.resource_id == expected_req.resource_id &&
          cpl.context_id == expected_req.context_id && cpl.epoch == expected_req.epoch);
    check("completion byte count", cpl.bytes == 32'(delivered));
    if (expected == APU_DMA_OK) check("complete payload", delivered == int'(byte_count));
    if (no_ar) check("refusal issued no AXI", ar_count == 0 && delivered == 0);
    if (expected != APU_DMA_PROTOCOL) check("completion after bus drain", !model_active && !model_rvalid);
    repeat (5) begin
      @(negedge clk);
      check("held completion", cpl_valid && cpl === saved && !req_ready && !idle);
    end
    cpl_ready = 1;
    @(posedge clk);
    @(negedge clk);
    cpl_ready = 0;
    cancel = 0;
    enable = 1;
    if (expected == APU_DMA_PROTOCOL) begin
      repeat (5) begin
        @(negedge clk);
        check("protocol fault quarantines master", bus_fault && !idle && !req_ready && !axi_req.ar_valid);
      end
      reset_bus();
    end else begin
      check("reader reusable after completion", idle && !bus_fault);
    end
  endtask

  initial begin
    apu_dma_mapping_t region;
    apu_dma_read_req_t request;
    apu_dma_read_data_t held_data;
    apu_dma_axi_ar_chan_t held_ar;
    req = '0;
    mapping = '0;
    req_valid = 0;
    enable = 1;
    cancel = 0;
    cpl_ready = 0;
    allow_ar = 1;
    allow_r = 1;
    allow_data = 1;
    stray_r = 0;
    injection = 0;
    injected = 0;
    ar_count = 0;
    r_count = 0;
    delivered = 0;
    expected_begin = 0;
    next_ar = 0;
    byte_count = 0;
    reset_bus();

    begin
      apu_cfg_t cfg;
      cfg = ApuP1Transport;
      cfg.DmaReadEn = 1;
      check("DMA enable requires a physical window", !apu_cfg_legal(cfg));
      cfg.DmaWindowBase = WindowBase;
      cfg.DmaWindowBytes = 64'h1000_0000;
      check("bounded DMA configuration legal", apu_cfg_legal(cfg));
      for (int beats = 0; beats <= 257; beats++) begin
        cfg.DmaReadBurstBeats = beats;
        check("burst configuration bounds", apu_cfg_legal(cfg) == (beats >= 1 && beats <= 256));
      end
      cfg.DmaReadBurstBeats = 16;
      cfg.DmaCoherent = 1;
      check("coherency cannot be over-granted", !apu_cfg_legal(cfg));
      cfg.DmaCoherent = 0;
      cfg.DmaReadMaxBytes = 0;
      check("zero request limit refused", !apu_cfg_legal(cfg));
      cfg.DmaReadMaxBytes = 1048577;
      check("excessive request limit refused", !apu_cfg_legal(cfg));
      cfg.DmaReadMaxBytes = 65536;
      cfg.DmaWindowBase += 1;
      check("unaligned root window refused", !apu_cfg_legal(cfg));
      cfg.DmaWindowBase = 64'h4000_0000;
      check("MMIO cannot be DMA backing", !apu_cfg_legal(cfg));
      cfg.DmaWindowBase = WindowBase;
      cfg.FirmwareHart = 1;
      cfg.FirmwareRamBase = WindowBase + 64'h40000;
      cfg.FirmwareRamBytes = 64'h40000;
      check("firmware RAM cannot be DMA backing", !apu_cfg_legal(cfg));
    end

    for (int off = 0; off < 8; off++) begin
      for (int len = 1; len <= 33; len++) begin
        issue(job(64'hff0 + 64'(off), 32'(len)), good_mapping());
        finish(APU_DMA_OK);
      end
    end
    issue(job(0, 65536), good_mapping()); finish(APU_DMA_OK);
    issue(job(64'h1ffff, 1), good_mapping()); finish(APU_DMA_OK);
    issue(job(0, 0), good_mapping()); finish(APU_DMA_LIMIT, 1);
    issue(job(0, 65537), good_mapping()); finish(APU_DMA_LIMIT, 1);
    issue(job(64'h20000, 1), good_mapping()); finish(APU_DMA_BOUNDS, 1);
    issue(job(64'h1ffff, 2), good_mapping()); finish(APU_DMA_BOUNDS, 1);
    issue(job(64'hffff_ffff_ffff_fffc, 8), good_mapping()); finish(APU_DMA_BOUNDS, 1);
    region = good_mapping(); region.valid = 0;
    issue(job(0, 8), region); finish(APU_DMA_BAD_RESOURCE, 1);
    region = good_mapping(); region.resource_id = 0;
    issue(job(0, 8), region); finish(APU_DMA_BAD_RESOURCE, 1);
    region = good_mapping(); region.permissions = 2;
    issue(job(0, 8), region); finish(APU_DMA_PERMISSION, 1);
    region = good_mapping(); region.context_id ^= 32'h8000_0000;
    issue(job(0, 8), region); finish(APU_DMA_PERMISSION, 1);
    request = job(0, 8); request.epoch ^= 32'h8000_0000;
    issue(request, good_mapping()); finish(APU_DMA_STALE, 1);
    request = job(0, 8); request.resource_id ^= 1;
    issue(request, good_mapping()); finish(APU_DMA_BAD_RESOURCE, 1);
    region = good_mapping(); region.base = WindowBase - 1;
    issue(job(0, 8), region); finish(APU_DMA_BOUNDS, 1);
    region = good_mapping(); region.base = WindowBase + 64'h1000_0000 - 4;
    issue(job(0, 8), region); finish(APU_DMA_BOUNDS, 1);
    region = good_mapping(); region.base = 64'hffff_ffff_ffff_fff8; region.bytes = 16;
    issue(job(0, 8), region); finish(APU_DMA_BOUNDS, 1);
    region = good_mapping(); region.bytes = 64'hffff_ffff_ffff_ffff;
    issue(job(0, 8), region); finish(APU_DMA_BOUNDS, 1);
    region = good_mapping(); region.bytes = 0;
    issue(job(0, 8), region); finish(APU_DMA_BOUNDS, 1);

    issue(job(0, 128), good_mapping());
    cancel = 1;
    finish(APU_DMA_CANCELLED, 1);
    allow_ar = 0;
    issue(job(0, 128), good_mapping());
    while (!axi_req.ar_valid) @(negedge clk);
    held_ar = axi_req.ar;
    cancel = 1;
    repeat (8) begin
      @(negedge clk);
      check("cancel cannot withdraw stalled AR", axi_req.ar_valid && axi_req.ar === held_ar && !idle && !cpl_valid);
    end
    allow_ar = 1;
    finish(APU_DMA_CANCELLED);
    check("cancel issues only the advertised burst", ar_count == 1);

    if (BurstBeats > 2) begin
      issue(job(0, 512), good_mapping());
      while (r_count == 0) @(negedge clk);
      allow_r = 0;
      cancel = 1;
      repeat (8) begin
        @(negedge clk);
        check("missing response cannot complete reset", !idle && !cpl_valid);
      end
      allow_r = 1;
      finish(APU_DMA_CANCELLED);
    end
    allow_data = 0;
    issue(job(0, 128), good_mapping());
    while (!data_valid) @(negedge clk);
    held_data = data;
    cancel = 1;
    repeat (8) begin
      @(negedge clk);
      check("cancel preserves stalled stream beat", data_valid && data === held_data && !cpl_valid);
    end
    allow_data = 1;
    finish(APU_DMA_CANCELLED);

    allow_ar = 0;
    issue(job(0, 128), good_mapping());
    while (!axi_req.ar_valid) @(negedge clk);
    enable = 0;
    repeat (3) @(negedge clk);
    allow_ar = 1;
    finish(APU_DMA_CANCELLED);
    issue(job(0, 8), good_mapping());
    while (!cpl_valid) @(negedge clk);
    cancel = 1;
    finish(APU_DMA_OK);

    issue(job(0, 512), good_mapping(), 1); finish(APU_DMA_BUS_ERROR);
    check("bus error stops further bursts", ar_count == 1);
    issue(job(0, 512), good_mapping(), 6); finish(APU_DMA_BUS_ERROR);
    check("decode error stops further bursts", ar_count == 1);
    issue(job(0, 512), good_mapping(), 5); finish(APU_DMA_BUS_ERROR);
    check("partial error retains exact delivered count", delivered == 8);
    check("partial error stops new bursts", ar_count == (BurstBeats == 1 ? 2 : 1));
    if (BurstBeats > 1) begin
      issue(job(0, 128), good_mapping(), 2); finish(APU_DMA_PROTOCOL);
    end
    issue(job(0, 128), good_mapping(), 3); finish(APU_DMA_PROTOCOL);
    issue(job(0, 128), good_mapping(), 4); finish(APU_DMA_PROTOCOL);
    @(negedge clk);
    stray_r = 1;
    #1;
    check("unsolicited response blocks request admission", !req_ready && !idle);
    repeat (3) @(negedge clk);
    stray_r = 0;
    check("unsolicited response quarantined", bus_fault && !idle && !cpl_valid);
    reset_bus();
    issue(job(3, 27), good_mapping()); finish(APU_DMA_OK);

    if (errors != 0) $fatal(1, "APU DMA errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_dma_read high=%0d burst=%0d cases=%0d checks=%0d cycles=%0d errors=0",
               HighAddress, BurstBeats, cases, checks, cycles);
      $finish;
    end
  end
endmodule
