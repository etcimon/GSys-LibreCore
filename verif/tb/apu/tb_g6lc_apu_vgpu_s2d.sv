// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_s2d;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_buf_t bufi;
  apu_vgpu_den_t deni;
  logic [31:0] mem [0:255];
  logic [APU_VGPU_BUF_ADDRW-1:0] s2d_addr, sbk_addr, sxf_addr;
  logic [31:0] s2d_peek, sbk_peek, sxf_peek;
  logic s2d_req = 0, s2d_rdy, s2d_cpl_v, s2d_cpl_r = 0;
  apu_vgpu_s2d_cpl_t s2d_cpl;
  apu_vgpu_s2d_t s2d;
  logic sbk_req = 0, sbk_rdy, sbk_cpl_v, sbk_cpl_r = 0;
  apu_vgpu_sbk_cpl_t sbk_cpl;
  apu_vgpu_sbk_t sbk;
  logic sxf_req = 0, sxf_rdy, sxf_cpl_v, sxf_cpl_r = 0;
  apu_vgpu_sxf_cpl_t sxf_cpl, off_cpl;
  apu_vgpu_sxf_t sxf, off_sxf;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam int unsigned BkWord = 10;
  localparam int unsigned XfWord = 22;
  localparam logic [31:0] StandIn = 32'h8800_F000;

  assign s2d_peek = mem[s2d_addr[9:2]];
  assign sbk_peek = mem[sbk_addr[9:2]];
  assign sxf_peek = mem[sxf_addr[9:2]];

  g6lc_apu_vgpu_s2d #(.Enable(1'b1)) i_s2d (
    .clk_i(clk), .rst_ni, .buf_i(bufi),
    .req_valid_i(s2d_req), .req_ready_o(s2d_rdy),
    .cpl_valid_o(s2d_cpl_v), .cpl_ready_i(s2d_cpl_r), .cpl_o(s2d_cpl), .s2d_o(s2d),
    .peek_addr_o(s2d_addr), .peek_word_i(s2d_peek)
  );
  g6lc_apu_vgpu_sbk #(.Enable(1'b1)) i_sbk (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .s2d_i(s2d),
    .req_valid_i(sbk_req), .req_ready_o(sbk_rdy),
    .cpl_valid_o(sbk_cpl_v), .cpl_ready_i(sbk_cpl_r), .cpl_o(sbk_cpl), .sbk_o(sbk),
    .peek_addr_o(sbk_addr), .peek_word_i(sbk_peek)
  );
  g6lc_apu_vgpu_sxf #(.Enable(1'b1)) i_sxf (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .s2d_i(s2d), .sbk_i(sbk), .den_i(deni),
    .req_valid_i(sxf_req), .req_ready_o(sxf_rdy),
    .cpl_valid_o(sxf_cpl_v), .cpl_ready_i(sxf_cpl_r), .cpl_o(sxf_cpl), .sxf_o(sxf),
    .peek_addr_o(sxf_addr), .peek_word_i(sxf_peek)
  );
  g6lc_apu_vgpu_sxf_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .s2d_i(s2d), .sbk_i(sbk), .den_i(deni),
    .req_valid_i(sxf_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sxf_cpl_r), .cpl_o(off_cpl), .sxf_o(off_sxf),
    .peek_addr_o(), .peek_word_i(sxf_peek)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu s2d timeout case=%0d", cases); end

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
    mem[0] = 32'h0000_0101;
    mem[1] = 32'h0000_0000;
    mem[2] = 32'h0000_0000;
    mem[3] = 32'h0000_0000;
    mem[4] = 32'h0000_0000;
    mem[5] = 32'h0000_0000;
    mem[6] = 32'h0000_0001;
    mem[7] = 32'h0000_0002;
    mem[8] = 32'h0000_0280;
    mem[9] = 32'h0000_01e0;
    mem[10] = 32'h0000_0106;
    mem[11] = 32'h0000_0000;
    mem[12] = 32'h0000_0000;
    mem[13] = 32'h0000_0000;
    mem[14] = 32'h0000_0000;
    mem[15] = 32'h0000_0000;
    mem[16] = 32'h0000_0001;
    mem[17] = 32'h0000_0001;
    mem[18] = 32'h0000_0000;
    mem[19] = 32'h0000_0000;
    mem[20] = 32'h0012_c000;
    mem[21] = 32'h0000_0000;
    mem[22] = 32'h0000_0105;
    mem[23] = 32'h0000_0000;
    mem[24] = 32'h0000_0000;
    mem[25] = 32'h0000_0000;
    mem[26] = 32'h0000_0000;
    mem[27] = 32'h0000_0000;
    mem[28] = 32'h0000_0000;
    mem[29] = 32'h0000_0000;
    mem[30] = 32'h0000_0280;
    mem[31] = 32'h0000_0040;
    mem[32] = 32'h0000_0000;
    mem[33] = 32'h0000_0000;
    mem[34] = 32'h0000_0001;
    mem[35] = 32'h0000_0000;
    mem[BkWord + 8] = StandIn;
  endtask

  task automatic good_buf;
    bufi = '0;
    bufi.valid = 1'b1;
    bufi.size = APU_VGPU_SCAN_XF_AT + 32'd56;
  endtask

  task automatic good_den;
    deni = '0;
    deni.valid = 1'b1;
    deni.refused = 1'b1;
    deni.resource_id = APU_VIRGL_RES_SCAN;
    deni.word = APU_VGPU_CLEAR_WORD;
    deni.samples = APU_VGPU_FILL_N;
  endtask

  task automatic s2d_step(input apu_vgpu_s2d_status_e st, input string name);
    @(negedge clk);
    while (!s2d_rdy) @(negedge clk);
    cases++;
    s2d_req = 1;
    @(posedge clk); @(negedge clk); s2d_req = 0;
    while (!s2d_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), s2d_cpl.status == st);
    if (st == APU_VGPU_S2D_OK)
      check($sformatf("%s shape", name), s2d.valid &&
            s2d.resource_id == 32'd1 && s2d.format == 32'd2 &&
            s2d.width == 16'd640 && s2d.height == 16'd480);
    @(negedge clk);
    check($sformatf("%s held", name), s2d_cpl_v);
    s2d_cpl_r = 1;
    @(posedge clk); @(negedge clk); s2d_cpl_r = 0;
    while (s2d_cpl_v) @(negedge clk);
  endtask

  task automatic sbk_step(input apu_vgpu_sbk_status_e st, input string name);
    @(negedge clk);
    while (!sbk_rdy) @(negedge clk);
    cases++;
    sbk_req = 1;
    @(posedge clk); @(negedge clk); sbk_req = 0;
    while (!sbk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sbk_cpl.status == st);
    if (st == APU_VGPU_SBK_OK)
      check($sformatf("%s entry", name), sbk.valid && sbk.addr == StandIn &&
            sbk.length == 32'd1228800);
    @(negedge clk);
    check($sformatf("%s held", name), sbk_cpl_v);
    sbk_cpl_r = 1;
    @(posedge clk); @(negedge clk); sbk_cpl_r = 0;
    while (sbk_cpl_v) @(negedge clk);
  endtask

  task automatic sxf_step(input apu_vgpu_sxf_status_e st, input string name);
    @(negedge clk);
    while (!sxf_rdy) @(negedge clk);
    cases++;
    sxf_req = 1;
    @(posedge clk); @(negedge clk); sxf_req = 0;
    while (!sxf_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sxf_cpl.status == st);
    if (st == APU_VGPU_SXF_OK)
      check($sformatf("%s band", name), sxf.valid && !sxf.copied &&
            sxf.width == 16'd640 && sxf.height == 16'd64 &&
            sxf.word == 32'hFF1A0D0D);
    check("off quiet", off_rdy == 0 && off_v == 0 && off_sxf == '0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), sxf_cpl_v);
    sxf_cpl_r = 1;
    @(posedge clk); @(negedge clk); sxf_cpl_r = 0;
    while (sxf_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    s2d_req = 0;
    sbk_req = 0;
    sxf_req = 0;
    s2d_cpl_r = 0;
    sbk_cpl_r = 0;
    sxf_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    bufi = '0;
    deni = '0;
    for (int i = 0; i < 256; i++) mem[i] = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && s2d == '0 && sbk == '0 && sxf == '0);
    check("profiles keep scan off",
          !ApuOff.S2dEn && !ApuOff.SbkEn && !ApuOff.SxfEn &&
          !ApuP1Transport.S2dEn && !ApuP1Transport.SbkEn && !ApuP1Transport.SxfEn &&
          !ApuHarness.S2dEn && !ApuHarness.SbkEn && !ApuHarness.SxfEn &&
          !ApuSchedBoth.S2dEn && !ApuSchedBoth.SbkEn && !ApuSchedBoth.SxfEn &&
          !ApuBadVirglGrant.S2dEn && !ApuBadVirglGrant.SbkEn && !ApuBadVirglGrant.SxfEn);
    cfg = ApuP1Transport;
    cfg.S2dEn = 1'b1;
    cfg.SbkEn = 1'b1;
    cfg.SxfEn = 1'b1;
    check("scan does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.S2dEn = 1'b1;
    cfg.SbkEn = 1'b1;
    cfg.SxfEn = 1'b1;
    check("scan does not legalize virgl", !apu_cfg_legal(cfg));
    check("scan shape", APU_VGPU_SCAN_W == 16'd640 && APU_VGPU_SCAN_H == 16'd480 &&
          APU_VGPU_SCAN_BAND == 16'd64 && APU_VGPU_SCAN_FMT == 32'd2 &&
          APU_VGPU_SCAN_BYTES == 32'd1228800 &&
          APU_VGPU_SCAN_C2_AT == 32'd0 && APU_VGPU_SCAN_BK_AT == 32'd40 &&
          APU_VGPU_SCAN_XF_AT == 32'd88);

    s2d_step(APU_VGPU_S2D_EMPTY, "s2d empty");
    good_buf();
    load_cmds();
    check("create anchor", mem[0] == 32'h00000101 && mem[7] == 32'd2 &&
          mem[8] == 32'd640 && mem[9] == 32'd480);
    check("band anchor", mem[XfWord + 8] == 32'd640 && mem[XfWord + 9] == 32'd64);
    mem[7] = 32'd67;
    s2d_step(APU_VGPU_S2D_FAULT, "lab format");
    check("format keeps", !s2d.valid);
    mem[7] = 32'd2;
    mem[8] = 32'd64;
    s2d_step(APU_VGPU_S2D_FAULT, "lab width");
    mem[8] = 32'd640;
    s2d_step(APU_VGPU_S2D_OK, "create");
    check("create kept", s2d.width == 16'd640 && s2d.height == 16'd480);
    s2d_step(APU_VGPU_S2D_FAULT, "create again");

    mem[BkWord + 8] = 32'h0;
    sbk_step(APU_VGPU_SBK_FAULT, "zero addr");
    check("zero keeps", !sbk.valid);
    mem[BkWord + 8] = 32'h8800_1000;
    sbk_step(APU_VGPU_SBK_FAULT, "lab addr");
    mem[BkWord + 8] = StandIn;
    sbk_step(APU_VGPU_SBK_OK, "backing");
    check("backing kept", sbk.addr == StandIn && sbk.length == 32'd1228800);
    sbk_step(APU_VGPU_SBK_FAULT, "backing again");

    sxf_step(APU_VGPU_SXF_EMPTY, "sxf empty");
    good_den();
    deni.word = 32'h0;
    sxf_step(APU_VGPU_SXF_FAULT, "bad color");
    check("color keeps", !sxf.valid);
    good_den();
    mem[XfWord + 9] = 32'd480;
    sxf_step(APU_VGPU_SXF_FAULT, "full height");
    mem[XfWord + 9] = 32'd64;
    sxf_step(APU_VGPU_SXF_OK, "band");
    check("nothing copied", sxf.valid && !sxf.copied && sxf.word == 32'hFF1A0D0D);
    sxf_step(APU_VGPU_SXF_FAULT, "band again");
    check("band stays", sxf.height == 16'd64 && !sxf.copied);

    pulse_reset();
    check("reset clears", s2d == '0 && sbk == '0 && sxf == '0);
    sxf_step(APU_VGPU_SXF_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu s2d errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_s2d cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
