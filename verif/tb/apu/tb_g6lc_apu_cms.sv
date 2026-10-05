// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AvailNext first-payload snapshot survives guest mutation of the source.

`timescale 1ns/1ps

module tb_g6lc_apu_cms;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, mutate = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [2:0] snap_idx = 0;
  logic [31:0] snap_word;
  apu_avn_req_t req;
  apu_cms_cpl_t cpl;
  apu_cms_t rec;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0;
  logic off_rdy, off_v, off_rd, off_rr;
  apu_cms_cpl_t off_cpl;
  apu_cms_t off_rec;
  logic [31:0] off_word;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [63:0] Avail1 = 64'h0000_0000_0000_0200;
  localparam logic [63:0] BaseA  = 64'h0000_0000_0000_1000;
  localparam logic [63:0] Pay0   = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay1   = 64'h0000_0000_8800_A000;
  localparam logic [63:0] Pay2   = 64'h0000_0000_8800_A800;
  localparam logic [31:0] Len0   = 32'd32;
  localparam logic [31:0] Len1   = 32'd960;
  localparam logic [31:0] Len2   = 32'd24;
  localparam logic [31:0] Word0  = 32'hC0DE_0000;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_cms #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .cms_o(rec),
    .snap_idx_i(snap_idx), .snap_word_o(snap_word),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_cms_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .cms_o(off_rec),
    .snap_idx_i(snap_idx), .snap_word_o(off_word),
    .rd_valid_o(off_rd), .rd_ready_i(rd_rdy), .rd_addr_o(), .rd_len_o(),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rr), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "cms timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 || off_rec !== '0)
      $fatal(1, "disabled cms active");
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

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_word(input logic [31:0] w);
    pack_word = '0;
    pack_word[31:0] = w;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_pay(input logic mutated);
    int unsigned i;
    pack_pay = '0;
    for (i = 0; i < APU_CMS_WORDS; i++)
      pack_pay[32*i +: 32] = (mutated ? 32'hDEAD_0000 : Word0) + 32'(i);
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] lookup(input logic [63:0] addr);
    lookup = '0;
    if (addr == Avail1)
      lookup = pack_word(32'h0001_0000);
    else if (addr == Avail1 + 64'd4)
      lookup = pack_word(32'h0000_0000);
    else if (addr == BaseA + 64'd0)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'd16)
      lookup = pack_desc(Pay1, Len1, VIRTQ_DESC_F_NEXT, 16'd2);
    else if (addr == BaseA + 64'd32)
      lookup = pack_desc(Pay2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr == Pay0)
      lookup = pack_pay(mutate);
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
      rsp_ok <= (rd_len == 32'd4) || (rd_len == 32'(APU_CHAIN_DESC_BYTES)) ||
                (rd_len == 32'(APU_CMS_BYTES));
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
    req_v = 1'b0; cpl_r = 1'b0; mutate = 1'b0; req = '0; snap_idx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic fire(input apu_avn_req_t r);
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
    apu_avn_req_t r;
    apu_cfg_t cfg;
    logic [31:0] w;
    int unsigned n0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rd == 1'b0 &&
          req_rdy == 1'b1);
    check("profiles keep cms off",
          !ApuOff.CmsEn && !ApuP1Transport.CmsEn && !ApuHarness.CmsEn);
    cfg = ApuP1Transport;
    cfg.CmsEn = 1'b1;
    check("cms does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.CmsEn = 1'b1;
    check("cms does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    n0 = nread;
    r = '0;
    r.avail_base = Avail1;
    r.desc_base = BaseA;
    r.queue_size = 8'd4;
    r.device_idx = 16'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("snap ok", cpl.status == APU_CMS_OK && rec.valid && rec.locked &&
          rec.word0 == Word0 && rec.bytes == Len0 && rec.addr == Pay0);
    snap_idx = 3'd1;
    @(negedge clk);
    w = snap_word;
    check("word1", w == Word0 + 32'd1);
    check("pay read", (nread - n0) == 6);
    ack();

    cases++;
    mutate = 1'b1;
    snap_idx = 3'd0;
    @(negedge clk);
    check("survives mutation", snap_word == Word0 && rec.word0 == Word0);
    fire(r);
    check("second snap faults", cpl.status == APU_CMS_FAULT && rec.valid);
    ack();

    cases++;
    do_reset;
    r.device_idx = 16'd1;
    fire(r);
    check("empty", cpl.status == APU_CMS_EMPTY && !rec.valid);
    ack();

    if (errors != 0) $fatal(1, "APU cms errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_cms cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
