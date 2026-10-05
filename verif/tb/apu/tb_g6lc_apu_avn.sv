// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// virtq_avail names a descriptor head; NextChain follows NEXT.
// Does not edit g6lc_apu_vgpu_avail.

`timescale 1ns/1ps

module tb_g6lc_apu_avn;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_avn_req_t req;
  apu_avn_cpl_t cpl;
  apu_avn_t rec;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0;
  logic off_rdy, off_v, off_rd, off_rr;
  apu_avn_cpl_t off_cpl;
  apu_avn_t off_rec;
  logic [63:0] off_addr;
  logic [31:0] off_len;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [63:0] Avail1 = 64'h0000_0000_0000_0200;
  localparam logic [63:0] Avail2 = 64'h0000_0000_0000_0300;
  localparam logic [63:0] Avail0 = 64'h0000_0000_0000_0400;
  localparam logic [63:0] BaseA  = 64'h0000_0000_0000_1000;
  localparam logic [63:0] BaseI  = 64'h0000_0000_0000_5000;
  localparam logic [63:0] Pay0   = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay1   = 64'h0000_0000_8800_A000;
  localparam logic [63:0] Pay2   = 64'h0000_0000_8800_A800;
  localparam logic [31:0] Len0   = 32'd32;
  localparam logic [31:0] Len1   = 32'd960;
  localparam logic [31:0] Len2   = 32'd24;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_avn #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .avn_o(rec),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_avn_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .avn_o(off_rec),
    .rd_valid_o(off_rd), .rd_ready_i(rd_rdy), .rd_addr_o(off_addr), .rd_len_o(off_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rr), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "avn timeout case=%0d n=%0d", cases, nread); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 ||
        off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled avn active");
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

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] lookup(input logic [63:0] addr);
    lookup = '0;
    if (addr == Avail1)
      lookup = pack_word(32'h0001_0000);
    else if (addr == Avail1 + 64'd4)
      lookup = pack_word(32'h0000_0000);
    else if (addr == Avail2)
      lookup = pack_word(32'h0002_0000);
    else if (addr == Avail2 + 64'd4)
      lookup = pack_word(32'h0000_0000);
    else if (addr == Avail0)
      lookup = pack_word(32'h0000_0000);
    else if (addr == Avail0 + 64'd8)
      lookup = pack_word(32'h0000_0000);
    else if (addr == BaseA + 64'd0)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'd16)
      lookup = pack_desc(Pay1, Len1, VIRTQ_DESC_F_NEXT, 16'd2);
    else if (addr == BaseA + 64'd32)
      lookup = pack_desc(Pay2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr == BaseI + 64'd0)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_INDIRECT, 16'd1);
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
      rsp_ok <= (rd_len == 32'd4) || (rd_len == 32'(APU_CHAIN_DESC_BYTES));
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
    int unsigned n0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rd == 1'b0 &&
          req_rdy == 1'b1 && !cpl_v);
    check("profiles keep avn off",
          !ApuOff.AvnEn && !ApuP1Transport.AvnEn && !ApuHarness.AvnEn);
    cfg = ApuP1Transport;
    cfg.AvnEn = 1'b1;
    check("avn does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.AvnEn = 1'b1;
    check("avn does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    n0 = nread;
    r = '0;
    r.avail_base = Avail1;
    r.desc_base = BaseA;
    r.queue_size = 8'd4;
    r.device_idx = 16'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("next ok", cpl.status == APU_AVN_OK && rec.valid && rec.count == 4'd3 &&
          rec.desc_id == 16'd0 && rec.device_idx == 16'd1 &&
          rec.first_addr == Pay0 && rec.last_addr == Pay2 &&
          rec.last_flags == VIRTQ_DESC_F_WRITE);
    check("next reads", (nread - n0) == 5);
    ack();

    cases++;
    n0 = nread;
    r.device_idx = 16'd1;
    fire(r);
    check("empty", cpl.status == APU_AVN_EMPTY && !rec.valid);
    check("empty idx only", (nread - n0) == 1);
    ack();

    cases++;
    n0 = nread;
    r.avail_base = Avail2;
    r.device_idx = 16'd0;
    fire(r);
    check("batch 0", cpl.status == APU_AVN_OK && rec.device_idx == 16'd1);
    ack();
    r.device_idx = 16'd1;
    fire(r);
    check("batch 1", cpl.status == APU_AVN_OK && rec.device_idx == 16'd2 &&
          rec.count == 4'd3);
    ack();

    cases++;
    n0 = nread;
    r = '0;
    r.avail_base = Avail0;
    r.desc_base = BaseA;
    r.queue_size = 8'd4;
    r.device_idx = 16'hFFFF;
    r.max_chain = 4'd8;
    fire(r);
    check("wrap", cpl.status == APU_AVN_OK && rec.valid && rec.desc_id == 16'd0 &&
          rec.device_idx == 16'd0 && rec.count == 4'd3);
    ack();

    cases++;
    r.avail_base = Avail1;
    r.desc_base = BaseI;
    r.device_idx = 16'd0;
    fire(r);
    check("indirect faults", cpl.status == APU_AVN_FAULT);
    ack();

    cases++;
    r.avail_base = Avail1 + 64'd2;
    r.desc_base = BaseA;
    fire(r);
    check("unaligned faults", cpl.status == APU_AVN_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU avn errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_avn cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
