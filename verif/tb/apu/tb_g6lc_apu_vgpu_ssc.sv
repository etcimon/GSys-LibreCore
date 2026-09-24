// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ssc;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_buf_t bufi;
  apu_vgpu_s2d_t s2d;
  apu_vgpu_sxf_t sxfi;
  logic [31:0] mem [0:255];
  logic [APU_VGPU_BUF_ADDRW-1:0] ssc_addr, sfl_addr;
  logic [31:0] ssc_peek, sfl_peek;
  logic ssc_req = 0, ssc_rdy, ssc_cpl_v, ssc_cpl_r = 0;
  apu_vgpu_ssc_cpl_t ssc_cpl;
  apu_vgpu_ssc_t ssc;
  logic sfl_req = 0, sfl_rdy, sfl_cpl_v, sfl_cpl_r = 0;
  apu_vgpu_sfl_cpl_t sfl_cpl;
  apu_vgpu_sfl_t sfl;
  logic [15:0] px, py;
  logic spr_req = 0, spr_rdy, spr_cpl_v, spr_cpl_r = 0;
  apu_vgpu_spr_cpl_t spr_cpl, off_cpl;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam int unsigned FlWord = 12;

  assign ssc_peek = mem[ssc_addr[9:2]];
  assign sfl_peek = mem[sfl_addr[9:2]];

  g6lc_apu_vgpu_ssc #(.Enable(1'b1)) i_ssc (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .s2d_i(s2d),
    .req_valid_i(ssc_req), .req_ready_o(ssc_rdy),
    .cpl_valid_o(ssc_cpl_v), .cpl_ready_i(ssc_cpl_r), .cpl_o(ssc_cpl), .ssc_o(ssc),
    .peek_addr_o(ssc_addr), .peek_word_i(ssc_peek)
  );
  g6lc_apu_vgpu_sfl #(.Enable(1'b1)) i_sfl (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .ssc_i(ssc), .sxf_i(sxfi),
    .req_valid_i(sfl_req), .req_ready_o(sfl_rdy),
    .cpl_valid_o(sfl_cpl_v), .cpl_ready_i(sfl_cpl_r), .cpl_o(sfl_cpl), .sfl_o(sfl),
    .peek_addr_o(sfl_addr), .peek_word_i(sfl_peek)
  );
  g6lc_apu_vgpu_spr #(.Enable(1'b1)) i_spr (
    .clk_i(clk), .rst_ni, .sfl_i(sfl), .sxf_i(sxfi), .x_i(px), .y_i(py),
    .req_valid_i(spr_req), .req_ready_o(spr_rdy),
    .cpl_valid_o(spr_cpl_v), .cpl_ready_i(spr_cpl_r), .cpl_o(spr_cpl)
  );
  g6lc_apu_vgpu_spr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sfl_i(sfl), .sxf_i(sxfi), .x_i(px), .y_i(py),
    .req_valid_i(spr_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(spr_cpl_r), .cpl_o(off_cpl)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu ssc timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic load_cmds;
    integer i;
    for (i = 0; i < 256; i++) mem[i] = '0;
    mem[0] = 32'h0000_0103;
    mem[1] = 32'h0000_0000;
    mem[2] = 32'h0000_0000;
    mem[3] = 32'h0000_0000;
    mem[4] = 32'h0000_0000;
    mem[5] = 32'h0000_0000;
    mem[6] = 32'h0000_0000;
    mem[7] = 32'h0000_0000;
    mem[8] = 32'h0000_0280;
    mem[9] = 32'h0000_01e0;
    mem[10] = 32'h0000_0000;
    mem[11] = 32'h0000_0001;
    mem[12] = 32'h0000_0104;
    mem[13] = 32'h0000_0000;
    mem[14] = 32'h0000_0000;
    mem[15] = 32'h0000_0000;
    mem[16] = 32'h0000_0000;
    mem[17] = 32'h0000_0000;
    mem[18] = 32'h0000_0000;
    mem[19] = 32'h0000_0000;
    mem[20] = 32'h0000_0280;
    mem[21] = 32'h0000_0040;
    mem[22] = 32'h0000_0001;
    mem[23] = 32'h0000_0000;
  endtask

  task automatic good_buf;
    bufi = '0;
    bufi.valid = 1'b1;
    bufi.size = APU_VGPU_SFL_AT + 32'd48;
  endtask

  task automatic good_s2d;
    s2d = '0;
    s2d.valid = 1'b1;
    s2d.resource_id = APU_VIRGL_RES_SCAN;
    s2d.format = APU_VGPU_SCAN_FMT;
    s2d.width = APU_VGPU_SCAN_W;
    s2d.height = APU_VGPU_SCAN_H;
  endtask

  task automatic good_sxf;
    sxfi = '0;
    sxfi.valid = 1'b1;
    sxfi.copied = 1'b0;
    sxfi.width = APU_VGPU_SCAN_W;
    sxfi.height = APU_VGPU_SCAN_BAND;
    sxfi.word = APU_VGPU_CLEAR_WORD;
  endtask

  task automatic ssc_step(input apu_vgpu_ssc_status_e st, input string name);
    @(negedge clk);
    while (!ssc_rdy) @(negedge clk);
    cases++;
    ssc_req = 1;
    @(posedge clk); @(negedge clk); ssc_req = 0;
    while (!ssc_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ssc_cpl.status == st);
    if (st == APU_VGPU_SSC_OK)
      check($sformatf("%s scan", name), ssc.valid && !ssc.shown &&
            ssc.scanout_id == 32'd0 && ssc.resource_id == 32'd1 &&
            ssc.width == 16'd640 && ssc.height == 16'd480);
    @(negedge clk);
    check($sformatf("%s held", name), ssc_cpl_v);
    ssc_cpl_r = 1;
    @(posedge clk); @(negedge clk); ssc_cpl_r = 0;
    while (ssc_cpl_v) @(negedge clk);
  endtask

  task automatic sfl_step(input apu_vgpu_sfl_status_e st, input string name);
    @(negedge clk);
    while (!sfl_rdy) @(negedge clk);
    cases++;
    sfl_req = 1;
    @(posedge clk); @(negedge clk); sfl_req = 0;
    while (!sfl_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sfl_cpl.status == st);
    if (st == APU_VGPU_SFL_OK)
      check($sformatf("%s flush", name), sfl.valid && !sfl.shown &&
            sfl.resource_id == 32'd1 && sfl.width == 16'd640 && sfl.height == 16'd64);
    @(negedge clk);
    check($sformatf("%s held", name), sfl_cpl_v);
    sfl_cpl_r = 1;
    @(posedge clk); @(negedge clk); sfl_cpl_r = 0;
    while (sfl_cpl_v) @(negedge clk);
  endtask

  task automatic spr_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_spr_status_e st,
    input logic [13:0] addr,
    input string name
  );
    @(negedge clk);
    while (!spr_rdy) @(negedge clk);
    cases++;
    px = x;
    py = y;
    spr_req = 1;
    @(posedge clk); @(negedge clk); spr_req = 0;
    while (!spr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), spr_cpl.status == st);
    if (st == APU_VGPU_SPR_OK)
      check($sformatf("%s sample", name), !spr_cpl.shown &&
            spr_cpl.word == 32'hFF1A0D0D && spr_cpl.addr == addr);
    else
      check($sformatf("%s quiet", name), !spr_cpl.shown && spr_cpl.word == 32'h0);
    check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), spr_cpl_v);
    spr_cpl_r = 1;
    @(posedge clk); @(negedge clk); spr_cpl_r = 0;
    while (spr_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    ssc_req = 0;
    sfl_req = 0;
    spr_req = 0;
    ssc_cpl_r = 0;
    sfl_cpl_r = 0;
    spr_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    bufi = '0;
    s2d = '0;
    sxfi = '0;
    px = '0;
    py = '0;
    for (int i = 0; i < 256; i++) mem[i] = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && ssc == '0 && sfl == '0);
    check("profiles keep present off",
          !ApuOff.SscEn && !ApuOff.SflEn && !ApuOff.SprEn &&
          !ApuP1Transport.SscEn && !ApuP1Transport.SflEn && !ApuP1Transport.SprEn &&
          !ApuHarness.SscEn && !ApuHarness.SflEn && !ApuHarness.SprEn &&
          !ApuSchedBoth.SscEn && !ApuSchedBoth.SflEn && !ApuSchedBoth.SprEn &&
          !ApuBadVirglGrant.SscEn && !ApuBadVirglGrant.SflEn && !ApuBadVirglGrant.SprEn);
    cfg = ApuP1Transport;
    cfg.SscEn = 1'b1;
    cfg.SflEn = 1'b1;
    cfg.SprEn = 1'b1;
    check("present does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.SscEn = 1'b1;
    cfg.SflEn = 1'b1;
    cfg.SprEn = 1'b1;
    check("present does not legalize virgl", !apu_cfg_legal(cfg));
    check("present offsets", APU_VGPU_SSC_AT == 32'd0 && APU_VGPU_SFL_AT == 32'd48 &&
          VGPU_CMD_SET_SCANOUT == 32'h00000103 &&
          VGPU_CMD_RESOURCE_FLUSH == 32'h00000104);

    ssc_step(APU_VGPU_SSC_EMPTY, "ssc empty");
    good_buf();
    good_s2d();
    load_cmds();
    check("scan anchor", mem[0] == 32'h00000103 && mem[8] == 32'd640 &&
          mem[9] == 32'd480 && mem[11] == 32'd1);
    check("flush anchor", mem[FlWord] == 32'h00000104 && mem[FlWord + 9] == 32'd64 &&
          mem[FlWord + 10] == 32'd1);
    mem[11] = 32'd4;
    ssc_step(APU_VGPU_SSC_FAULT, "rt resource");
    check("rt keeps", !ssc.valid);
    mem[11] = 32'd1;
    mem[8] = 32'd64;
    mem[9] = 32'd64;
    ssc_step(APU_VGPU_SSC_FAULT, "small box");
    mem[8] = 32'd640;
    mem[9] = 32'd480;
    ssc_step(APU_VGPU_SSC_OK, "scanout");
    check("scan kept", ssc.valid && !ssc.shown && ssc.resource_id == 32'd1);
    ssc_step(APU_VGPU_SSC_FAULT, "scanout again");

    sfl_step(APU_VGPU_SFL_EMPTY, "sfl empty");
    good_sxf();
    sxfi.copied = 1'b1;
    sfl_step(APU_VGPU_SFL_FAULT, "copied");
    check("copied keeps", !sfl.valid);
    good_sxf();
    mem[FlWord + 9] = 32'd480;
    sfl_step(APU_VGPU_SFL_FAULT, "full flush");
    mem[FlWord + 9] = 32'd64;
    mem[FlWord + 10] = 32'd4;
    sfl_step(APU_VGPU_SFL_FAULT, "flush resource");
    mem[FlWord + 10] = 32'd1;
    sfl_step(APU_VGPU_SFL_OK, "flush");
    check("flush kept", sfl.valid && !sfl.shown && sfl.height == 16'd64);
    sfl_step(APU_VGPU_SFL_FAULT, "flush again");

    spr_step(16'd1, 16'd0, APU_VGPU_SPR_OK, 14'd4, "interior");
    spr_step(16'd2, 16'd3, APU_VGPU_SPR_OK, 14'd776, "sample 2,3");
    spr_step(16'd63, 16'd63, APU_VGPU_SPR_OK, APU_VGPU_PIX_XY, "corner");
    spr_step(16'd64, 16'd0, APU_VGPU_SPR_FAULT, 14'd0, "outside");
    spr_step(16'd1, 16'd0, APU_VGPU_SPR_OK, 14'd4, "reread");
    check("still clear", sxfi.word == 32'hFF1A0D0D && !sfl.shown);

    pulse_reset();
    check("reset clears", ssc == '0 && sfl == '0);
    spr_step(16'd1, 16'd0, APU_VGPU_SPR_EMPTY, 14'd0, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu ssc errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ssc cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
