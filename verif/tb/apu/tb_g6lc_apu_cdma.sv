// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// NextChain through checked DmaRead. Programmed table in the DMA window.

`timescale 1ns/1ps

module tb_g6lc_apu_cdma;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_chain_req_t req;
  apu_chain_cpl_t cpl;
  apu_chain_t chain;
  apu_dma_mapping_t mapping;
  logic idle, bus_fault;
  apu_dma_axi_req_t axi_req;
  apu_dma_axi_resp_t axi_rsp;
  logic off_rdy, off_v, off_idle, off_fault;
  apu_chain_cpl_t off_cpl;
  apu_chain_t off_chain;
  apu_dma_axi_req_t off_axi;
  logic model_active, model_rvalid;
  logic [63:0] model_addr;
  int unsigned model_left, model_step;
  apu_dma_axi_r_chan_t model_r;
  int errors = 0, checks = 0, cycles = 0, cases = 0, ar_count = 0;

  localparam logic [63:0] MapBase = 64'h0000_0000_8000_1000;
  localparam logic [63:0] MapBytes = 64'h0000_0000_0000_1000;
  localparam logic [63:0] BaseA = MapBase;
  localparam logic [63:0] BaseB = MapBase + 64'h100;
  localparam logic [63:0] BaseC = MapBase + 64'h200;
  localparam logic [63:0] BaseInd = MapBase + 64'h300;
  localparam logic [63:0] BaseOob = MapBase + 64'h2000;
  localparam logic [63:0] Pay0 = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay1 = 64'h0000_0000_8800_A000;
  localparam logic [63:0] Pay2 = 64'h0000_0000_8800_A800;
  localparam logic [63:0] PayB0 = 64'h0000_0000_9000_0000;
  localparam logic [63:0] PayB1 = 64'h0000_0000_9000_1000;
  localparam logic [63:0] PayB2 = 64'h0000_0000_9000_2000;
  localparam logic [31:0] Len0 = 32'd32;
  localparam logic [31:0] Len1 = 32'd960;
  localparam logic [31:0] Len2 = 32'd24;

  g6lc_apu_cdma #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .mapping_i(mapping), .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .chain_o(chain), .idle_o(idle), .bus_fault_o(bus_fault),
    .axi_req_o(axi_req), .axi_rsp_i(axi_rsp)
  );
  g6lc_apu_cdma_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .mapping_i(mapping), .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .chain_o(off_chain), .idle_o(off_idle), .bus_fault_o(off_fault),
    .axi_req_o(off_axi), .axi_rsp_i(axi_rsp)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #500000; $fatal(1, "cdma timeout case=%0d ar=%0d", cases, ar_count); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_idle !== 1'b1 ||
        off_fault !== 1'b0 || off_chain !== '0 || off_cpl !== '0 || off_axi !== '0)
      $fatal(1, "disabled cdma active");
  end

  function automatic logic [127:0] pack_desc(
      input logic [63:0] addr, input logic [31:0] len,
      input logic [15:0] flags, input logic [15:0] nxt);
    pack_desc = '0;
    pack_desc[63:0] = addr;
    pack_desc[95:64] = len;
    pack_desc[111:96] = flags;
    pack_desc[127:112] = nxt;
  endfunction

  function automatic logic [127:0] lookup_desc(input logic [63:0] base);
    lookup_desc = '0;
    if (base == BaseA + 64'd0)
      lookup_desc = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (base == BaseA + 64'd16)
      lookup_desc = pack_desc(Pay1, Len1, VIRTQ_DESC_F_NEXT, 16'd2);
    else if (base == BaseA + 64'd32)
      lookup_desc = pack_desc(Pay2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (base == BaseB + 64'd0)
      lookup_desc = pack_desc(PayB0, Len0, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (base == BaseB + 64'd16)
      lookup_desc = pack_desc(PayB1, Len1, VIRTQ_DESC_F_NEXT, 16'd2);
    else if (base == BaseB + 64'd32)
      lookup_desc = pack_desc(PayB2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (base == BaseC + 64'd32)
      lookup_desc = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd3);
    else if (base == BaseC + 64'd48)
      lookup_desc = pack_desc(Pay2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (base == BaseInd)
      lookup_desc = pack_desc(Pay0, Len0, VIRTQ_DESC_F_INDIRECT, 16'd1);
  endfunction

  function automatic logic [63:0] mem64(input logic [63:0] addr);
    logic [127:0] d;
    d = lookup_desc(addr & ~64'hF);
    mem64 = addr[3] ? d[127:64] : d[63:0];
  endfunction

  function automatic apu_dma_mapping_t good_map();
    return '{valid: 1'b1, permissions: 2'b01, resource_id: 32'h8000_0001,
             context_id: 32'hf000_0002, epoch: 32'h1234_5678,
             base: MapBase, bytes: MapBytes};
  endfunction

  always_comb begin
    axi_rsp = '0;
    axi_rsp.ar_ready = rst_ni && !model_active && !model_rvalid;
    axi_rsp.r_valid = model_rvalid;
    axi_rsp.r = model_r;
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      model_active <= 1'b0;
      model_rvalid <= 1'b0;
      model_addr <= '0;
      model_left <= 0;
      model_step <= 0;
      model_r <= '0;
    end else begin
      if (axi_req.ar_valid && axi_rsp.ar_ready) begin
        model_active <= 1'b1;
        model_addr <= axi_req.ar.addr;
        model_left <= 32'(axi_req.ar.len) + 1;
        model_step <= 1 << axi_req.ar.size;
        ar_count <= ar_count + 1;
      end
      if (model_active && !model_rvalid) begin
        model_rvalid <= 1'b1;
        model_r <= '{id: '0, data: mem64(model_addr), resp: axi_pkg::RESP_OKAY,
                     last: model_left == 1, user: '0};
      end
      if (model_rvalid && axi_req.r_ready) begin
        model_rvalid <= 1'b0;
        model_addr <= model_addr + 64'(model_step);
        model_left <= model_left - 1;
        if (model_r.last) model_active <= 1'b0;
      end
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d ar=%0d", name, cases, cycles, ar_count);
    end
  endtask

  task automatic do_reset;
    req_v = 1'b0;
    cpl_r = 1'b0;
    req = '0;
    mapping = good_map();
    @(negedge clk);
    rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    ar_count = 0;
    @(posedge clk);
  endtask

  task automatic fire(input apu_chain_req_t r);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r;
    req_v = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  task automatic ack;
    @(negedge clk);
    cpl_r = 1'b1;
    @(posedge clk);
    while (cpl_v) @(posedge clk);
    @(negedge clk);
    cpl_r = 1'b0;
  endtask

  initial begin
    apu_chain_req_t r;
    apu_cfg_t cfg;
    int unsigned n0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_idle == 1'b1 &&
          req_rdy == 1'b1 && !cpl_v);
    check("profiles keep cdma off",
          !ApuOff.CdmaEn && !ApuP1Transport.CdmaEn && !ApuHarness.CdmaEn &&
          !ApuSchedBoth.CdmaEn && !ApuBadVirglGrant.CdmaEn);
    cfg = ApuP1Transport;
    cfg.CdmaEn = 1'b1;
    check("cdma does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.CdmaEn = 1'b1;
    check("cdma does not legalize virgl", !apu_cfg_legal(cfg));
    check("window pin", APU_CDMA_WIN_BASE == 64'h8000_0000 &&
          APU_CDMA_WIN_BYTES == 64'h0100_0000);

    cases++;
    r = '0;
    r.desc_base = BaseA;
    r.queue_size = 8'd4;
    r.head = 8'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("walk A status", cpl.status == APU_CHAIN_OK && chain.valid);
    check("walk A count", chain.count == 4'd3 && chain.last_idx == 8'd2);
    check("walk A windows", chain.first_addr == Pay0 && chain.last_addr == Pay2);
    check("walk A ar", ar_count == 3);
    ack();

    cases++;
    n0 = ar_count;
    r.desc_base = BaseB;
    fire(r);
    check("reloc status", cpl.status == APU_CHAIN_OK && chain.first_addr == PayB0 &&
          chain.last_addr == PayB2);
    check("reloc ar", (ar_count - n0) == 3);
    ack();

    cases++;
    n0 = ar_count;
    r.desc_base = BaseC;
    r.queue_size = 8'd8;
    r.head = 8'd2;
    fire(r);
    check("head2 status", cpl.status == APU_CHAIN_OK && chain.head == 8'd2 &&
          chain.count == 4'd2 && chain.last_addr == Pay2);
    check("head2 ar", (ar_count - n0) == 2);
    ack();

    cases++;
    n0 = ar_count;
    r = '0;
    r.desc_base = BaseInd;
    r.queue_size = 8'd4;
    r.head = 8'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("indirect faults", cpl.status == APU_CHAIN_FAULT);
    check("indirect one ar", (ar_count - n0) == 1);
    repeat (8) @(posedge clk);
    check("indirect no stray", (ar_count - n0) == 1 && !axi_req.ar_valid);
    ack();

    cases++;
    n0 = ar_count;
    r.desc_base = BaseOob;
    fire(r);
    check("oob map faults", cpl.status == APU_CHAIN_FAULT);
    check("oob no dma", (ar_count - n0) == 0 && !axi_req.ar_valid);
    ack();

    cases++;
    n0 = ar_count;
    mapping.valid = 1'b0;
    r.desc_base = BaseA;
    fire(r);
    check("bad map faults", cpl.status == APU_CHAIN_FAULT);
    check("bad map no dma", (ar_count - n0) == 0);
    ack();

    if (errors != 0) $fatal(1, "APU cdma errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_cdma cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
