// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Reusable virtq_desc NEXT walker. Programmed table base and head.
// Not g6lc_apu_vgpu_gnw and not a stock virtqueue.

`timescale 1ns/1ps

module tb_g6lc_apu_chain;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_chain_req_t req;
  apu_chain_cpl_t cpl;
  apu_chain_t chain;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0;
  logic off_rdy, off_v, off_rd, off_rr;
  apu_chain_cpl_t off_cpl;
  apu_chain_t off_chain;
  logic [63:0] off_addr;
  logic [31:0] off_len;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [63:0] BaseA = 64'h0000_0000_0000_1000;
  localparam logic [63:0] BaseB = 64'h0000_0000_0000_2000;
  localparam logic [63:0] BaseC = 64'h0000_0000_0000_3000;
  localparam logic [63:0] Pay0  = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay1  = 64'h0000_0000_8800_A000;
  localparam logic [63:0] Pay2  = 64'h0000_0000_8800_A800;
  localparam logic [63:0] PayB0 = 64'h0000_0000_9000_0000;
  localparam logic [63:0] PayB1 = 64'h0000_0000_9000_1000;
  localparam logic [63:0] PayB2 = 64'h0000_0000_9000_2000;
  localparam logic [31:0] Len0  = 32'd32;
  localparam logic [31:0] Len1  = 32'd960;
  localparam logic [31:0] Len2  = 32'd24;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_chain #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .chain_o(chain),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_chain_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .chain_o(off_chain),
    .rd_valid_o(off_rd), .rd_ready_i(rd_rdy), .rd_addr_o(off_addr), .rd_len_o(off_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rr), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "chain timeout case=%0d n=%0d", cases, nread); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 ||
        off_chain !== '0 || off_cpl !== '0)
      $fatal(1, "disabled chain active");
  end

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_desc(
      input logic [63:0] addr, input logic [31:0] len,
      input logic [15:0] flags, input logic [15:0] nxt);
    pack_desc = '0;
    pack_desc[63:0] = addr;
    pack_desc[95:64] = len;
    pack_desc[111:96] = flags;
    pack_desc[127:112] = nxt;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] lookup(input logic [63:0] addr);
    lookup = '0;
    if (addr == BaseA + 64'd0)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'd16)
      lookup = pack_desc(Pay1, Len1, VIRTQ_DESC_F_NEXT, 16'd2);
    else if (addr == BaseA + 64'd32)
      lookup = pack_desc(Pay2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr == BaseB + 64'd0)
      lookup = pack_desc(PayB0, Len0, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseB + 64'd16)
      lookup = pack_desc(PayB1, Len1, VIRTQ_DESC_F_NEXT, 16'd2);
    else if (addr == BaseB + 64'd32)
      lookup = pack_desc(PayB2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr == BaseC + 64'd32)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd3);
    else if (addr == BaseC + 64'd48)
      lookup = pack_desc(Pay2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr == BaseA + 64'h100)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_INDIRECT, 16'd1);
    else if (addr == BaseA + 64'h200)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd0);
    else if (addr == BaseA + 64'h300)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd7);
    else if (addr == BaseA + 64'h400)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'h410)
      lookup = pack_desc(Pay1, Len1, VIRTQ_DESC_F_NEXT, 16'd2);
    else if (addr == BaseA + 64'h420)
      lookup = pack_desc(Pay2, Len2, VIRTQ_DESC_F_NEXT, 16'd3);
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= lookup(rd_addr);
      rsp_ok <= (rd_len == 32'(APU_CHAIN_DESC_BYTES));
      nread <= nread + 1;
      rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d nread=%0d", name, cases, cycles, nread);
    end
  endtask

  task automatic do_reset;
    req_v = 1'b0;
    cpl_r = 1'b0;
    req = '0;
    @(negedge clk);
    rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
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
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rd == 1'b0 &&
          req_rdy == 1'b1 && !cpl_v);
    check("profiles keep chain off",
          !ApuOff.ChainEn && !ApuP1Transport.ChainEn && !ApuHarness.ChainEn &&
          !ApuSchedBoth.ChainEn && !ApuBadVirglGrant.ChainEn);
    cfg = ApuP1Transport;
    cfg.ChainEn = 1'b1;
    check("chain does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.ChainEn = 1'b1;
    check("chain does not legalize virgl", !apu_cfg_legal(cfg) &&
          !apu_cfg_legal(ApuBadVirglGrant));
    check("desc is 16 bytes", APU_CHAIN_DESC_BYTES == 16 && APU_CHAIN_MAX == 8 &&
          APU_CHAIN_QMAX == 16);

    cases++;
    r = '0;
    r.desc_base = BaseA;
    r.queue_size = 8'd4;
    r.head = 8'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("walk A status", cpl.status == APU_CHAIN_OK && chain.valid);
    check("walk A count", chain.count == 4'd3 && chain.head == 8'd0 &&
          chain.last_idx == 8'd2);
    check("walk A first", chain.first_addr == Pay0 && chain.first_len == Len0);
    check("walk A last", chain.last_addr == Pay2 && chain.last_len == Len2 &&
          chain.last_flags == VIRTQ_DESC_F_WRITE);
    check("walk A reads", nread == 3);
    ack();

    cases++;
    n0 = nread;
    r.desc_base = BaseB;
    fire(r);
    check("reloc status", cpl.status == APU_CHAIN_OK && chain.valid);
    check("reloc first", chain.first_addr == PayB0 && chain.last_addr == PayB2 &&
          chain.count == 4'd3);
    check("reloc reads", (nread - n0) == 3);
    ack();

    cases++;
    n0 = nread;
    r.desc_base = BaseC;
    r.queue_size = 8'd8;
    r.head = 8'd2;
    fire(r);
    check("head2 status", cpl.status == APU_CHAIN_OK && chain.valid);
    check("head2 span", chain.head == 8'd2 && chain.last_idx == 8'd3 &&
          chain.count == 4'd2 && chain.first_addr == Pay0 &&
          chain.last_addr == Pay2);
    check("head2 reads", (nread - n0) == 2);
    ack();

    cases++;
    n0 = nread;
    r = '0;
    r.desc_base = BaseA + 64'h100;
    r.queue_size = 8'd4;
    r.head = 8'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("indirect faults", cpl.status == APU_CHAIN_FAULT && !chain.valid);
    check("indirect one read", (nread - n0) == 1 && !rd_v);
    repeat (4) @(posedge clk);
    check("indirect no stray", (nread - n0) == 1 && !rd_v);
    ack();

    cases++;
    n0 = nread;
    r.desc_base = BaseA + 64'h200;
    fire(r);
    check("loop faults", cpl.status == APU_CHAIN_FAULT);
    check("loop one read", (nread - n0) == 1 && !rd_v);
    ack();

    cases++;
    n0 = nread;
    r.desc_base = BaseA + 64'h300;
    fire(r);
    check("oob next faults", cpl.status == APU_CHAIN_FAULT);
    check("oob one read", (nread - n0) == 1 && !rd_v);
    ack();

    cases++;
    n0 = nread;
    r.desc_base = BaseA + 64'h400;
    r.max_chain = 4'd2;
    fire(r);
    check("overlong faults", cpl.status == APU_CHAIN_FAULT);
    check("overlong two reads", (nread - n0) == 2 && !rd_v);
    ack();

    cases++;
    n0 = nread;
    r = '0;
    r.desc_base = 64'h1;
    r.queue_size = 8'd4;
    r.head = 8'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("misaligned faults", cpl.status == APU_CHAIN_FAULT);
    check("misaligned no dma", (nread - n0) == 0 && !rd_v);
    ack();

    if (errors != 0) $fatal(1, "APU chain errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_chain cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
