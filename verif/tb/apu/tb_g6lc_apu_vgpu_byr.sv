// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_byr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_gbk_t gbk;
  apu_vgpu_gbz_t gbz;
  apu_vgpu_cxr_t cxr;
  logic byr_req = 0, byr_rdy, byr_cpl_v, byr_cpl_r = 0;
  apu_vgpu_byr_cpl_t byr_cpl;
  apu_vgpu_byr_t byr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen0 = 0, seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic byk_req = 0, byk_rdy, byk_cpl_v, byk_cpl_r = 0;
  apu_vgpu_byk_cpl_t byk_cpl;
  apu_vgpu_byk_t byk;
  logic [7:0] b0 = 0;
  logic byx_req = 0, byx_rdy, byx_cpl_v, byx_cpl_r = 0;
  apu_vgpu_byx_cpl_t byx_cpl, off_cpl;
  apu_vgpu_byx_t byx, off_byx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_b0 = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, rd_base = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_byr #(.Enable(1'b1)) i_byr (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .gbk_i(gbk), .gbz_i(gbz), .cxr_i(cxr),
    .req_valid_i(byr_req), .req_ready_o(byr_rdy),
    .cpl_valid_o(byr_cpl_v), .cpl_ready_i(byr_cpl_r), .cpl_o(byr_cpl), .byr_o(byr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_byk #(.Enable(1'b1)) i_byk (
    .clk_i(clk), .rst_ni, .byr_i(byr), .gbd_i(gbd),
    .req_valid_i(byk_req), .req_ready_o(byk_rdy),
    .cpl_valid_o(byk_cpl_v), .cpl_ready_i(byk_cpl_r), .cpl_o(byk_cpl), .byk_o(byk)
  );
  g6lc_apu_vgpu_byx #(.Enable(1'b1)) i_byx (
    .clk_i(clk), .rst_ni, .byk_i(byk), .b0_i(b0),
    .req_valid_i(byx_req), .req_ready_o(byx_rdy),
    .cpl_valid_o(byx_cpl_v), .cpl_ready_i(byx_cpl_r), .cpl_o(byx_cpl), .byx_o(byx)
  );
  g6lc_apu_vgpu_byx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .byk_i(byk), .b0_i(b0),
    .req_valid_i(byx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(byx_cpl_r), .cpl_o(off_cpl), .byx_o(off_byx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu byr timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      logic [255:0] beat;
      idx = nread - rd_base;
      want = idx == 0 ? APU_VGPU_GBW_ADDR : APU_VGPU_GBW_TAIL;
      beat = Pat;
      if (idx == 0 && bad_b0) beat[7:0] = 8'hFF;
      if (rd_addr != want || rd_len != 32'(APU_VGPU_BEAT_BYTES)) order_bad <= 1'b1;
      if (idx == 0) seen0 <= rd_addr;
      else seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 0) bad_b0 <= 1'b0;
      nread <= nread + 1;
      rd_rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_in;
    gbd = '0;
    gbd.valid = 1'b1;
    gbd.width = APU_VGPU_GBD_W;
    gbd.height = APU_VGPU_GBD_H;
    gbd.stride = APU_VGPU_GBD_STRIDE;
    gbd.bytes = APU_VGPU_GBD_BYTES;
    gbd.format = APU_VIRGL_FMT_B8G8R8X8;
    gbd.base = APU_VGPU_GBW_ADDR;
    gbk = '0;
    gbk.valid = 1'b1;
    gbk.word = APU_VGPU_CLEAR_WORD;
    gbk.beats = APU_VGPU_GPW_BEATS;
    gbk.src = APU_VGPU_GPW_ADDR;
    gbk.dst = APU_VGPU_GBW_ADDR;
    gbz = '0;
    gbz.valid = 1'b1;
    gbz.word = APU_VGPU_CLEAR_WORD;
    gbz.offset = APU_VGPU_GOF_AT10;
    gbz.bytes = APU_VGPU_GBD_BYTES;
    gbz.x = 7'd1;
    gbz.y = 7'd0;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_byx == '0 &&
          off_cpl == '0);
  endtask

  task automatic byr_step(input apu_vgpu_byr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!byr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    byr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    byr_req = 1'b0;
    while (!byr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), byr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_BYR_OK) begin
      check("channels", byr.valid && byr.r == 8'h0D && byr.g == 8'h0D &&
            byr.b == 8'h1A && byr.a == 8'hFF);
      check("two beats", nread == n0 + 2 && !order_bad &&
            seen0 == APU_VGPU_GBW_ADDR && seen1 == APU_VGPU_GBW_TAIL);
    end else if (name == "bad beat" || name == "bad byte") begin
      check("one beat", nread == n0 + 1 && !byr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), byr_cpl_v);
    byr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    byr_cpl_r = 1'b0;
    while (byr_cpl_v) @(negedge clk);
  endtask

  task automatic byk_step(input apu_vgpu_byk_status_e st, input string name);
    @(negedge clk);
    while (!byk_rdy) @(negedge clk);
    cases++;
    byk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    byk_req = 1'b0;
    while (!byk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), byk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), byk_cpl_v);
    byk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    byk_cpl_r = 1'b0;
    while (byk_cpl_v) @(negedge clk);
  endtask

  task automatic byx_step(input apu_vgpu_byx_status_e st, input string name);
    @(negedge clk);
    while (!byx_rdy) @(negedge clk);
    cases++;
    byx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    byx_req = 1'b0;
    while (!byx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), byx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), byx_cpl_v);
    byx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    byx_cpl_r = 1'b0;
    while (byx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    byr_req = 1'b0;
    byk_req = 1'b0;
    byx_req = 1'b0;
    byr_cpl_r = 1'b0;
    byk_cpl_r = 1'b0;
    byx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    gbk = '0;
    gbz = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          byr == '0 && byk == '0 && byx == '0);
    check("profiles keep the channels off",
          !ApuOff.ByrEn && !ApuOff.BykEn && !ApuOff.ByxEn &&
          !ApuP1Transport.ByrEn && !ApuP1Transport.BykEn && !ApuP1Transport.ByxEn &&
          !ApuHarness.ByrEn && !ApuHarness.BykEn && !ApuHarness.ByxEn &&
          !ApuSchedBoth.ByrEn && !ApuSchedBoth.BykEn && !ApuSchedBoth.ByxEn &&
          !ApuBadVirglGrant.ByrEn && !ApuBadVirglGrant.BykEn &&
          !ApuBadVirglGrant.ByxEn);
    cfg = ApuP1Transport;
    cfg.ByrEn = 1'b1;
    cfg.BykEn = 1'b1;
    cfg.ByxEn = 1'b1;
    check("channels do not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.ByrEn = 1'b1;
    cfg.BykEn = 1'b1;
    cfg.ByxEn = 1'b1;
    check("channels do not legalize virgl", !apu_cfg_legal(cfg));
    check("byte order",
          APU_VGPU_CLEAR_R == 8'h0D && APU_VGPU_CLEAR_G == 8'h0D &&
          APU_VGPU_CLEAR_B == 8'h1A && APU_VGPU_CLEAR_A == 8'hFF &&
          APU_VGPU_CLEAR_WORD == {APU_VGPU_CLEAR_A, APU_VGPU_CLEAR_B,
                                  APU_VGPU_CLEAR_G, APU_VGPU_CLEAR_R});

    byr_step(APU_VGPU_BYR_EMPTY, "bytes empty");
    byk_step(APU_VGPU_BYK_EMPTY, "keep empty");
    byx_step(APU_VGPU_BYX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    byr_step(APU_VGPU_BYR_FAULT, "bad scissor");
    good_in();
    fail_rd = 1'b1;
    byr_step(APU_VGPU_BYR_FAULT, "bad beat");
    bad_b0 = 1'b1;
    byr_step(APU_VGPU_BYR_FAULT, "bad byte");
    byr_step(APU_VGPU_BYR_OK, "bytes");
    byr_step(APU_VGPU_BYR_FAULT, "bytes again");
    check("bytes stay", byr.r == 8'h0D && byr.g == 8'h0D &&
          byr.b == 8'h1A && byr.a == 8'hFF);
    gbd.bytes = 32'd0;
    byk_step(APU_VGPU_BYK_FAULT, "keep bad bytes");
    check("keep rejected", !byk.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    byk_step(APU_VGPU_BYK_OK, "keep channels");
    check("channels kept", byk.valid && byk.r == 8'h0D && byk.a == 8'hFF &&
          {byk.a, byk.b, byk.g, byk.r} == APU_VGPU_CLEAR_WORD);
    byk_step(APU_VGPU_BYK_FAULT, "keep again");
    b0 = 8'hFF;
    byx_step(APU_VGPU_BYX_FAULT, "high byte first");
    check("order rejected", !byx.valid);
    b0 = 8'h0D;
    byx_step(APU_VGPU_BYX_OK, "red first");
    check("red first", byx.valid && byx.b0 == 8'h0D && byx.b0 != 8'hFF &&
          byx.r == 8'h0D && byx.g == 8'h0D && byx.b == 8'h1A && byx.a == 8'hFF);
    byx_step(APU_VGPU_BYX_FAULT, "order again");
    check("order stays", byx.b0 == 8'h0D && byx.a == 8'hFF);

    pulse_reset();
    check("reset clears", byr == '0 && byk == '0 && byx == '0);
    gbd = '0;
    byr_step(APU_VGPU_BYR_EMPTY, "after reset");
    byk_step(APU_VGPU_BYK_EMPTY, "keep after reset");
    byx_step(APU_VGPU_BYX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu byr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_byr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
