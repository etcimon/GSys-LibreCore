// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AvailUsed then virtio used-buffer ISR. Ack of bit 0 lowers the pin.

`timescale 1ns/1ps

module tb_g6lc_apu_uir;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq, ack_v = 0;
  logic [31:0] isr, ack_w = 0;
  apu_avu_req_t req;
  apu_uir_cpl_t cpl;
  apu_uir_t rec;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, wr_addr;
  logic [31:0] rd_len, rsp_len = 0, wr_len;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0, wr_data;
  logic off_rdy, off_v, off_rd, off_wr, off_irq, off_rr, off_wr_r;
  logic [31:0] off_isr;
  apu_uir_cpl_t off_cpl;
  apu_uir_t off_rec;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [63:0] Avail1 = 64'h0000_0000_0000_0200;
  localparam logic [63:0] BaseA  = 64'h0000_0000_0000_1000;
  localparam logic [63:0] UsedA  = 64'h0000_0000_0000_0600;
  localparam logic [63:0] BaseI  = 64'h0000_0000_0000_5000;
  localparam logic [63:0] Pay0   = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay1   = 64'h0000_0000_8800_A000;
  localparam logic [63:0] Pay2   = 64'h0000_0000_8800_A800;
  localparam logic [31:0] Len0   = 32'd32;
  localparam logic [31:0] Len1   = 32'd960;
  localparam logic [31:0] Len2   = 32'd24;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;

  g6lc_apu_uir #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .uir_o(rec),
    .irq_o(irq), .isr_o(isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok)
  );
  g6lc_apu_uir_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .uir_o(off_rec),
    .irq_o(off_irq), .isr_o(off_isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(off_rd), .rd_ready_i(rd_rdy), .rd_addr_o(), .rd_len_o(),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rr), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(off_wr), .wr_ready_i(wr_rdy), .wr_addr_o(), .wr_len_o(),
    .wr_data_o(), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(off_wr_r),
    .wr_rsp_ok_i(wr_ok)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "uir timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 || off_wr !== 1'b0 ||
        off_irq !== 1'b0 || off_isr !== '0 || off_rec !== '0)
      $fatal(1, "disabled uir active");
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
      wr_rsp_v <= 1'b0;
    end else begin
      if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
      else if (rd_v && rd_rdy) begin
        rsp_addr <= rd_addr;
        rsp_len <= rd_len;
        rsp_data <= lookup(rd_addr);
        rsp_ok <= (rd_len == 32'd4) || (rd_len == 32'(APU_CHAIN_DESC_BYTES));
        rsp_v <= 1'b1;
      end
      if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
      else if (wr_v && wr_rdy) begin
        wr_ok <= 1'b1;
        wr_rsp_v <= 1'b1;
      end
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic do_reset;
    req_v = 1'b0; cpl_r = 1'b0; ack_v = 1'b0; ack_w = '0; req = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic fire(input apu_avu_req_t r);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r;
    req_v = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  task automatic ack_cpl;
    @(negedge clk);
    cpl_r = 1'b1;
    @(posedge clk);
    while (cpl_v) @(posedge clk);
    @(negedge clk);
    cpl_r = 1'b0;
  endtask

  task automatic ack_irq;
    @(negedge clk);
    ack_v = 1'b1;
    ack_w = APU_UIR_ISR_VRING;
    @(posedge clk);
    @(negedge clk);
    ack_v = 1'b0;
    ack_w = '0;
    @(posedge clk);
  endtask

  initial begin
    apu_avu_req_t r;
    apu_cfg_t cfg;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_irq == 1'b0 && off_isr == 32'd0 &&
          req_rdy == 1'b1 && irq == 1'b0);
    check("profiles keep uir off",
          !ApuOff.UirEn && !ApuP1Transport.UirEn && !ApuHarness.UirEn);
    cfg = ApuP1Transport;
    cfg.UirEn = 1'b1;
    check("uir does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.UirEn = 1'b1;
    check("uir does not legalize virgl", !apu_cfg_legal(cfg));
    check("vring isr bit", APU_UIR_ISR_VRING == 32'd1);

    cases++;
    r = '0;
    r.avail_base = Avail1;
    r.desc_base = BaseA;
    r.used_base = UsedA;
    r.queue_size = 8'd4;
    r.device_idx = 16'd0;
    r.used_idx = 16'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("irq after used", cpl.status == APU_UIR_OK && rec.valid && rec.irq &&
          irq && isr == APU_UIR_ISR_VRING && rec.used_idx == 16'd1);
    ack_cpl();
    ack_irq();
    check("ack lowers", !irq && isr == 32'd0);

    cases++;
    r.device_idx = 16'd1;
    r.used_idx = 16'd1;
    fire(r);
    check("empty no irq", cpl.status == APU_UIR_EMPTY && !rec.valid && !irq);
    ack_cpl();

    cases++;
    do_reset;
    r.desc_base = BaseI;
    r.device_idx = 16'd0;
    r.used_idx = 16'd0;
    fire(r);
    check("indirect no irq", cpl.status == APU_UIR_FAULT && !irq && isr == 32'd0);
    ack_cpl();

    if (errors != 0) $fatal(1, "APU uir errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_uir cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
