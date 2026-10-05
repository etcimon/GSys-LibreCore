// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mesa vn_ring_layout walker. Stock head/tail/status/buffer geometry.

`timescale 1ns/1ps

module tb_g6lc_apu_vnring;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic shm_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [6:0] shm_idx = 0;
  logic [31:0] shm_wdata = 0, shm_rdata;
  apu_vnring_cpl_t cpl;
  apu_vnring_t rec;
  logic off_rdy, off_v;
  apu_vnring_cpl_t off_cpl;
  apu_vnring_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vnring #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .shm_we_i(shm_we), .shm_idx_i(shm_idx),
    .shm_wdata_i(shm_wdata), .shm_rdata_o(shm_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vnring_o(rec)
  );
  g6lc_apu_vnring_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .shm_we_i(shm_we), .shm_idx_i(shm_idx),
    .shm_wdata_i(shm_wdata), .shm_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vnring_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vnring timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled vnring active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic poke(input logic [15:0] byte_off, input logic [31:0] w);
    @(negedge clk);
    shm_we = 1'b1;
    shm_idx = 7'(byte_off >> 2);
    shm_wdata = w;
    @(posedge clk);
    @(negedge clk);
    shm_we = 1'b0;
  endtask

  task automatic peek(input logic [15:0] byte_off, output logic [31:0] w);
    shm_idx = 7'(byte_off >> 2);
    @(negedge clk);
    w = shm_rdata;
  endtask

  task automatic fire;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
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

  task automatic do_reset;
    shm_we = 1'b0; req_v = 1'b0; cpl_r = 1'b0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] t;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vnring off",
          !ApuOff.VnringEn && !ApuP1Transport.VnringEn && !ApuHarness.VnringEn);
    cfg = ApuP1Transport;
    cfg.VnringEn = 1'b1;
    check("vnring does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VnringEn = 1'b1;
    check("vnring does not legalize virgl", !apu_cfg_legal(cfg));
    check("mesa offsets", APU_VNRING_HEAD_OFF == 16'd0 &&
          APU_VNRING_TAIL_OFF == 16'd64 && APU_VNRING_STATUS_OFF == 16'd128 &&
          APU_VNRING_BUF_OFF == 16'd192 && APU_VNRING_BUF_BYTES == 256);

    cases++;
    poke(APU_VNRING_BUF_OFF, 32'hA5A5_0001);
    poke(APU_VNRING_HEAD_OFF, 32'd4);
    poke(APU_VNRING_TAIL_OFF, 32'd0);
    fire();
    check("consume 4", cpl.status == APU_VNRING_OK && rec.valid &&
          rec.bytes == 32'd4 && rec.first_word == 32'hA5A5_0001);
    peek(APU_VNRING_TAIL_OFF, t);
    check("tail advanced", t == 32'd4);
    peek(APU_VNRING_STATUS_OFF, t);
    check("status idle", t == APU_VNRING_STATUS_IDLE);
    ack();

    cases++;
    poke(APU_VNRING_BUF_OFF + 16'd252, 32'h1122_3344);
    poke(APU_VNRING_TAIL_OFF, 32'd252);
    poke(APU_VNRING_HEAD_OFF, 32'd260);
    fire();
    check("wrap consume", cpl.status == APU_VNRING_OK && rec.valid &&
          rec.bytes == 32'd8 && rec.first_word == 32'h1122_3344 &&
          rec.tail == 32'd252 && rec.head == 32'd260);
    peek(APU_VNRING_TAIL_OFF, t);
    check("wrap tail", t == 32'd260);
    ack();

    cases++;
    poke(APU_VNRING_HEAD_OFF, 32'd1);
    poke(APU_VNRING_TAIL_OFF, 32'd0);
    fire();
    check("unaligned faults", cpl.status == APU_VNRING_FAULT);
    ack();

    cases++;
    poke(APU_VNRING_HEAD_OFF, 32'd8);
    poke(APU_VNRING_TAIL_OFF, 32'd8);
    fire();
    check("empty ok", cpl.status == APU_VNRING_OK && !rec.valid && rec.bytes == 32'd0);
    ack();

    cases++;
    poke(APU_VNRING_HEAD_OFF, 32'd512);
    poke(APU_VNRING_TAIL_OFF, 32'd0);
    fire();
    check("oversize faults", cpl.status == APU_VNRING_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU vnring errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vnring cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
