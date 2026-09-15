// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module g6lc_apu_dma_write_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1, parameter bit HighAddress = 0) (
  input logic clk_i, rst_ni, testmode_i, enable_i, cancel_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input apu_dma_write_req_t req_i,
  input apu_dma_mapping_t mapping_i,
  input logic data_valid_i,
  output logic data_ready_o,
  input apu_dma_write_data_t data_i,
  output logic cpl_valid_o,
  input logic cpl_ready_i,
  output apu_dma_write_cpl_t cpl_o,
  output logic idle_o, bus_fault_o,
  output apu_dma_axi_req_t axi_req_o,
  input apu_dma_axi_resp_t axi_rsp_i
);
  function automatic apu_cfg_t test_cfg();
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = Enable;
    cfg.DmaWriteEn = Enable;
    cfg.DmaWindowBase = 64'h8000_0000 + (HighAddress ? 64'h2_0000_0000 : 0);
    cfg.DmaWindowBytes = 64'h1000_0000;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = cfg.DmaWindowBase + cfg.DmaWindowBytes;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  g6lc_apu_dma_write #(.ApuCfg(test_cfg())) i_dut (.*);
endmodule

module tb_g6lc_apu_dma_write;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  parameter bit HighAddress = 0;
  parameter int PacketBytes = 8;
  localparam logic [63:0] WindowBase = 64'h8000_0000 + (HighAddress ? 64'h2_0000_0000 : 0);
  logic clk = 0, rst_ni = 0;
  logic enable, cancel, req_valid, req_ready, data_valid, data_ready, cpl_valid, cpl_ready;
  logic idle, bus_fault;
  apu_dma_write_req_t req, expected_req;
  apu_dma_mapping_t mapping;
  apu_dma_write_data_t data;
  apu_dma_write_cpl_t cpl;
  apu_dma_axi_req_t axi_req;
  apu_dma_axi_resp_t axi_rsp;
  logic off_req_ready, off_data_ready, off_cpl_valid, off_idle, off_fault;
  apu_dma_write_cpl_t off_cpl;
  apu_dma_axi_req_t off_axi;
  logic allow_aw, allow_w, allow_b, allow_source, source_run, data_taken, stray_b;
  logic aw_seen, w_seen, executed, model_bvalid;
  apu_dma_axi_aw_chan_t model_aw;
  apu_dma_axi_w_chan_t model_w;
  apu_dma_axi_b_chan_t model_b;
  logic [7:0] memory [0:65551];
  logic [63:0] expected_begin, next_aw;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int aw_count, w_count, b_count, strobed, memory_written, source_sent, memory_len;
  int bus_mode, stream_mode, fail_at;

  g6lc_apu_dma_write_fixture #(.HighAddress(HighAddress)) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req), .mapping_i(mapping),
    .data_valid_i(data_valid), .data_ready_o(data_ready), .data_i(data),
    .cpl_valid_o(cpl_valid), .cpl_ready_i(cpl_ready), .cpl_o(cpl),
    .idle_o(idle), .bus_fault_o(bus_fault), .axi_req_o(axi_req), .axi_rsp_i(axi_rsp)
  );
  g6lc_apu_dma_write_fixture #(.Enable(0), .HighAddress(HighAddress)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .req_valid_i(req_valid), .req_ready_o(off_req_ready), .req_i(req), .mapping_i(mapping),
    .data_valid_i(data_valid), .data_ready_o(off_data_ready), .data_i(data),
    .cpl_valid_o(off_cpl_valid), .cpl_ready_i(cpl_ready), .cpl_o(off_cpl),
    .idle_o(off_idle), .bus_fault_o(off_fault), .axi_req_o(off_axi), .axi_rsp_i(axi_rsp)
  );
  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin
    #10000000;
    $fatal(1, "DMA write timeout case=%0d AW=%0d W=%0d B=%0d", cases, aw_count, w_count, b_count);
  end
  task automatic check(input string name, input logic condition);
    checks++;
    if (condition !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  function automatic logic [7:0] pattern(input logic [63:0] addr);
    return 8'(addr ^ (addr >> 8) ^ (addr >> 32) ^ 64'h39);
  endfunction
  function automatic apu_dma_mapping_t good_mapping();
    return '{valid: 1'b1, permissions: 2'b10, resource_id: 32'h8000_0001,
      context_id: 32'hf000_0002, epoch: 32'h1234_5678,
      base: WindowBase + 64'h10000, bytes: 64'h20000};
  endfunction
  function automatic apu_dma_write_req_t job(input logic [63:0] offset, input logic [31:0] bytes);
    return '{resource_id: 32'h8000_0001, context_id: 32'hf000_0002, epoch: 32'h1234_5678,
      offset: offset, bytes: bytes, tag: 64'hfedc_ba98_0000_0000 | 64'(cases)};
  endfunction

  always_comb begin
    axi_rsp = '0;
    axi_rsp.aw_ready = allow_aw && !aw_seen && !executed && !model_bvalid &&
                       (axi_req.w_valid || w_seen) && cycles % 4 != 0;
    axi_rsp.w_ready = allow_w && !w_seen && !executed &&
                      (!model_bvalid || bus_mode == 3) && cycles % 3 != 0;
    axi_rsp.b_valid = model_bvalid || stray_b;
    axi_rsp.b = stray_b ? apu_dma_axi_b_chan_t'{id: 1, resp: 2'b00, user: 0} : model_b;
  end
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_seen <= 0;
      w_seen <= 0;
      executed <= 0;
      model_bvalid <= 0;
      model_aw <= '0;
      model_w <= '0;
      model_b <= '0;
    end else begin
      if (axi_req.aw_valid && axi_rsp.aw_ready) begin
        aw_seen <= 1;
        model_aw <= axi_req.aw;
      end
      if (axi_req.w_valid && axi_rsp.w_ready) begin
        w_seen <= 1;
        model_w <= axi_req.w;
      end
      if (aw_seen && w_seen && !executed) executed <= 1;
      if (!model_bvalid && allow_b &&
          ((executed && cycles % 4 != 0) || (bus_mode == 3 && aw_seen && !w_seen))) begin
        model_bvalid <= 1;
        model_b <= '{id: 1, resp: 2'b00, user: 0};
        if (b_count == fail_at) begin
          if (bus_mode == 1) model_b.resp <= axi_pkg::RESP_SLVERR;
          if (bus_mode == 2) model_b.id <= 0;
          if (bus_mode == 4) model_b.resp <= axi_pkg::RESP_DECERR;
        end
      end
      if (model_bvalid && axi_req.b_ready && !stray_b) begin
        model_bvalid <= 0;
        aw_seen <= 0;
        w_seen <= 0;
        executed <= 0;
      end
    end
  end
  always @(posedge clk) begin
    data_taken = 0;
    if (rst_ni) begin
      check("write master never reads", !axi_req.ar_valid && !axi_req.r_ready);
      if (data_valid && data_ready) begin
        source_sent += $countones(data.keep);
        data_taken = 1;
      end
      if (axi_req.aw_valid && axi_rsp.aw_ready) begin
        logic [63:0] span, last;
        aw_count++;
        span = 64'd1 << axi_req.aw.size;
        last = axi_req.aw.addr + span - 1;
        check("single outstanding write", !aw_seen && !executed && !model_bvalid);
        check("write attributes", axi_req.aw.len == 0 && axi_req.aw.id == 1 &&
              axi_req.aw.burst == axi_pkg::BURST_INCR && axi_req.aw.cache == 0 &&
              axi_req.aw.prot == 0 && axi_req.aw.atop == 0 && !axi_req.aw.lock);
        check("natural write alignment", axi_req.aw.size <= 3 && axi_req.aw.addr % span == 0);
        check("write 4 KiB boundary", axi_req.aw.addr[63:12] == last[63:12]);
        check("write extent within request", axi_req.aw.addr >= expected_begin &&
              last >= axi_req.aw.addr && last - expected_begin < 64'(expected_req.bytes));
        check("ordered write addresses", axi_req.aw.addr == next_aw);
        next_aw = last + 1;
      end
      if (axi_req.w_valid && axi_rsp.w_ready) begin
        w_count++;
        strobed += $countones(axi_req.w.strb);
        check("single W beat", !w_seen && axi_req.w.last);
      end
      if (aw_seen && w_seen && !executed) begin
        int n;
        n = 1 << model_aw.size;
        check("exact byte strobes", model_w.strb == (8'((1 << n) - 1) << model_aw.addr[2:0]));
        for (int lane = 0; lane < 8; lane++) begin
          logic [63:0] byte_addr;
          byte_addr = (model_aw.addr & ~64'd7) + 64'(lane);
          if (model_w.strb[lane]) begin
            check("strobed address authorized", byte_addr >= expected_begin &&
                  byte_addr - expected_begin < 64'(expected_req.bytes));
            check("write data exact", model_w.data[8*lane +: 8] == pattern(byte_addr));
            if (byte_addr >= expected_begin && byte_addr - expected_begin < 65536)
              memory[int'(byte_addr - expected_begin) + 8] = model_w.data[8*lane +: 8];
            memory_written++;
          end else check("unstrobed lanes zero", model_w.data[8*lane +: 8] == 0);
        end
      end
      if (axi_rsp.b_valid && axi_req.b_ready && !stray_b) b_count++;
    end
  end
  always @(negedge clk) begin
    if (!rst_ni || !source_run) data_valid = 0;
    else begin
      if (data_taken) data_valid = 0;
      if (!data_valid && allow_source && source_sent < int'(expected_req.bytes) && cycles % 3 != 0) begin
        int n;
        n = int'(expected_req.bytes) - source_sent;
        if (n > PacketBytes) n = PacketBytes;
        data = '0;
        data.offset = 32'(source_sent);
        data.keep = 8'((1 << n) - 1);
        data.last = source_sent + n == int'(expected_req.bytes);
        for (int b = 0; b < 8; b++) data.data[8*b +: 8] = pattern(expected_begin + 64'(source_sent + b));
        if (stream_mode == 1) data.keep = 0;
        if (stream_mode == 2) data.keep = 8'h5;
        if (stream_mode == 3 || (stream_mode == 7 && source_sent != 0)) data.offset += 1;
        if (stream_mode == 4) data.last = 1;
        if (stream_mode == 5) data.last = 0;
        if (stream_mode == 6) data.keep = 8'hff;
        data_valid = 1;
      end
    end
    #1;
    if ({off_req_ready, off_data_ready, off_cpl_valid, off_cpl, off_fault, off_axi} !== '0 ||
        off_idle !== 1'b1) $fatal(1, "disabled DMA writer active");
  end

  task automatic reset_bus;
    @(negedge clk);
    rst_ni = 0;
    req_valid = 0;
    source_run = 0;
    stray_b = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    enable = 1;
    cancel = 0;
    allow_aw = 1;
    allow_w = 1;
    allow_b = 1;
    allow_source = 1;
    cpl_ready = 0;
  endtask
  task automatic issue(input apu_dma_write_req_t request, input apu_dma_mapping_t region,
                       input int bus_error = 0, input int bad_stream = 0, input int error_after = 0);
    @(negedge clk);
    while (!req_ready) @(negedge clk);
    cases++;
    aw_count = 0; w_count = 0; b_count = 0;
    strobed = 0; memory_written = 0; source_sent = 0;
    bus_mode = bus_error; stream_mode = bad_stream; fail_at = error_after;
    expected_req = request;
    expected_begin = region.base + request.offset;
    next_aw = expected_begin;
    memory_len = (request.bytes < 65536 ? int'(request.bytes) : 65536) + 16;
    for (int i = 0; i < memory_len; i++) memory[i] = 8'ha5;
    req = request; mapping = region;
    source_run = 1;
    req_valid = 1;
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    @(negedge clk);
    req_valid = 0;
    req = '0; mapping = '0;
  endtask
  task automatic finish(input apu_dma_status_e expected, input bit no_bus = 0);
    apu_dma_write_cpl_t saved;
    @(negedge clk);
    while (!cpl_valid) @(negedge clk);
    source_run = 0;
    saved = cpl;
    if (cpl.status != expected) $display("write status got=%0d expected=%0d", cpl.status, expected);
    check("write completion status", cpl.status == expected);
    check("write completion metadata", cpl.tag == expected_req.tag && cpl.resource_id == expected_req.resource_id &&
          cpl.context_id == expected_req.context_id && cpl.epoch == expected_req.epoch);
    check("strobed byte accounting", cpl.bytes == 32'(strobed));
    check("completion follows AW/W/B", aw_count == w_count && w_count == b_count &&
          !aw_seen && !w_seen && !model_bvalid && !executed);
    if (expected == APU_DMA_OK) check("whole request written", strobed == int'(expected_req.bytes));
    if (no_bus) check("refusal has no writes", aw_count == 0 && w_count == 0 && memory_written == 0);
    for (int i = 0; i < memory_len; i++) begin
      if (i >= 8 && i - 8 < memory_written)
        check("memory contents", memory[i] == pattern(expected_begin + 64'(i - 8)));
      else check("destination guards untouched", memory[i] == 8'ha5);
    end
    repeat (5) begin
      @(negedge clk);
      check("write completion held", cpl_valid && cpl === saved && !req_ready && !idle);
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
        check("writer quarantined", bus_fault && !idle && !req_ready && !axi_req.aw_valid && !axi_req.w_valid);
      end
      reset_bus();
    end else check("writer reusable", idle && !bus_fault);
  endtask

  initial begin
    apu_dma_mapping_t region;
    apu_dma_write_req_t request;
    apu_dma_axi_aw_chan_t held_aw;
    apu_dma_axi_w_chan_t held_w;
    req = '0; mapping = '0; data = '0; expected_req = '0;
    req_valid = 0; data_valid = 0; source_run = 0; data_taken = 0;
    enable = 1; cancel = 0; cpl_ready = 0;
    allow_aw = 1; allow_w = 1; allow_b = 1; allow_source = 1; stray_b = 0;
    aw_count = 0; w_count = 0; b_count = 0; strobed = 0; memory_written = 0; source_sent = 0;
    bus_mode = 0; stream_mode = 0; fail_at = 0;
    expected_begin = 0; next_aw = 0; memory_len = 0;
    reset_bus();
    begin
      apu_cfg_t cfg;
      cfg = ApuP1Transport;
      cfg.DmaWriteEn = 1;
      check("write enable requires root window", !apu_cfg_legal(cfg));
      cfg.DmaWindowBase = WindowBase; cfg.DmaWindowBytes = 64'h1000_0000;
      check("write-only configuration legal", apu_cfg_legal(cfg));
      cfg.DmaReadMaxBytes = 0; cfg.DmaReadBurstBeats = 0;
      check("write does not require read resources", apu_cfg_legal(cfg));
      cfg.DmaWindowBase += 1;
      check("write window alignment enforced", !apu_cfg_legal(cfg));
      cfg.DmaWindowBase = WindowBase;
      cfg.DmaWriteMaxBytes = 0; check("zero write limit illegal", !apu_cfg_legal(cfg));
      cfg.DmaWriteMaxBytes = 1048577; check("excess write limit illegal", !apu_cfg_legal(cfg));
      cfg.DmaWriteMaxBytes = 65536; cfg.DmaCoherent = 1;
      check("write coherency over-grant illegal", !apu_cfg_legal(cfg));
      cfg.DmaCoherent = 0; cfg.DmaWindowBase = 64'h4000_0000;
      check("write window cannot cover MMIO", !apu_cfg_legal(cfg));
      cfg.DmaWindowBase = WindowBase; cfg.FirmwareHart = 1;
      cfg.FirmwareRamBase = WindowBase + 64'h40000; cfg.FirmwareRamBytes = 64'h40000;
      check("write window cannot cover firmware", !apu_cfg_legal(cfg));
    end
    for (int offset = 0; offset < 8; offset++) begin
      for (int len = 1; len <= 33; len++) begin
        issue(job(64'hff0 + 64'(offset), 32'(len)), good_mapping());
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
    region = good_mapping(); region.permissions = 1;
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
    for (int mode = 1; mode <= 4; mode++) begin
      issue(job(1, 64), good_mapping(), 0, mode); finish(APU_DMA_STREAM, 1);
    end
    issue(job(0, 1), good_mapping(), 0, 5); finish(APU_DMA_STREAM, 1);
    issue(job(0, 1), good_mapping(), 0, 6); finish(APU_DMA_STREAM, 1);
    issue(job(1, 64), good_mapping(), 0, 7); finish(APU_DMA_STREAM);
    check("malformed later packet leaves only valid prefix", memory_written == PacketBytes);

    issue(job(0, 64), good_mapping()); cancel = 1; finish(APU_DMA_CANCELLED, 1);
    allow_source = 0;
    issue(job(0, 64), good_mapping());
    repeat (8) @(negedge clk);
    check("source starvation does not complete", !cpl_valid && !idle && aw_count == 0);
    cancel = 1; finish(APU_DMA_CANCELLED, 1); allow_source = 1;

    allow_aw = 0;
    issue(job(1, 64), good_mapping());
    while (w_count == 0) @(negedge clk);
    held_aw = axi_req.aw; cancel = 1;
    repeat (8) begin
      @(negedge clk);
      check("AW held after W-first cancellation", axi_req.aw_valid && axi_req.aw === held_aw && !cpl_valid && !idle);
    end
    allow_aw = 1; finish(APU_DMA_CANCELLED);
    check("W-first cancelled remainder not written", aw_count == 1 && strobed == 1);

    allow_w = 0;
    issue(job(1, 64), good_mapping());
    while (aw_count == 0) @(negedge clk);
    held_w = axi_req.w; cancel = 1;
    repeat (8) begin
      @(negedge clk);
      check("W held after AW-first cancellation", axi_req.w_valid && axi_req.w === held_w && !cpl_valid && !idle);
    end
    allow_w = 1; finish(APU_DMA_CANCELLED);

    allow_aw = 0; allow_w = 0;
    issue(job(1, 64), good_mapping());
    while (!axi_req.aw_valid || !axi_req.w_valid) @(negedge clk);
    held_aw = axi_req.aw; held_w = axi_req.w; enable = 0;
    repeat (6) begin
      @(negedge clk);
      check("runtime disable preserves offered write", axi_req.aw_valid && axi_req.w_valid &&
            axi_req.aw === held_aw && axi_req.w === held_w && !cpl_valid);
    end
    allow_aw = 1; allow_w = 1; finish(APU_DMA_CANCELLED);

    allow_b = 0;
    issue(job(1, 64), good_mapping());
    while (!executed) @(negedge clk);
    cancel = 1;
    repeat (8) begin
      @(negedge clk);
      check("missing B prevents completion and drain", !cpl_valid && !idle && b_count == 0);
    end
    allow_b = 1; finish(APU_DMA_CANCELLED);
    issue(job(0, 1), good_mapping());
    while (!cpl_valid) @(negedge clk);
    cancel = 1; finish(APU_DMA_OK);

    issue(job(1, 64), good_mapping(), 1); finish(APU_DMA_BUS_ERROR);
    check("SLVERR stops later stores", aw_count == 1);
    issue(job(1, 64), good_mapping(), 4, 0, 1); finish(APU_DMA_BUS_ERROR);
    check("DECERR preserves partial progress", aw_count == 2 && memory_written > 0);
    issue(job(1, 64), good_mapping(), 2); finish(APU_DMA_PROTOCOL);
    allow_w = 0;
    issue(job(1, 64), good_mapping(), 3);
    while (!model_bvalid) @(negedge clk);
    repeat (5) @(negedge clk);
    check("early B flagged without dropping W", bus_fault && axi_req.w_valid && !cpl_valid);
    allow_w = 1; finish(APU_DMA_PROTOCOL);
    @(negedge clk);
    stray_b = 1;
    #1;
    check("stray B blocks admission", !req_ready && !idle);
    repeat (3) @(negedge clk);
    stray_b = 0;
    check("stray B quarantines writer", bus_fault && !idle && !cpl_valid);
    reset_bus();
    issue(job(3, 27), good_mapping()); finish(APU_DMA_OK);
    if (errors != 0) $fatal(1, "APU DMA write errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_dma_write high=%0d packet=%0d cases=%0d checks=%0d cycles=%0d errors=0",
               HighAddress, PacketBytes, cases, checks, cycles);
      $finish;
    end
  end
endmodule
