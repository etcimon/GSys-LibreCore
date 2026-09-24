// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_gbd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbk_t gbk;
  logic [15:0] want_w = 0, want_h = 0;
  logic gbd_req = 0, gbd_rdy, gbd_cpl_v, gbd_cpl_r = 0;
  apu_vgpu_gbd_cpl_t gbd_cpl;
  apu_vgpu_gbd_t gbd;
  logic [6:0] px = 0, py = 0;
  logic gbl_req = 0, gbl_rdy, gbl_cpl_v, gbl_cpl_r = 0;
  apu_vgpu_gbl_cpl_t gbl_cpl;
  apu_vgpu_gbl_t gbl;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic gbx_req = 0, gbx_rdy, gbx_cpl_v, gbx_cpl_r = 0;
  apu_vgpu_gbx_cpl_t gbx_cpl, off_cpl;
  apu_vgpu_gbx_t gbx, off_gbx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_lane = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_gbd #(.Enable(1'b1)) i_gbd (
    .clk_i(clk), .rst_ni, .gbk_i(gbk), .want_w_i(want_w), .want_h_i(want_h),
    .req_valid_i(gbd_req), .req_ready_o(gbd_rdy),
    .cpl_valid_o(gbd_cpl_v), .cpl_ready_i(gbd_cpl_r), .cpl_o(gbd_cpl), .gbd_o(gbd)
  );
  g6lc_apu_vgpu_gbl #(.Enable(1'b1)) i_gbl (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .gbk_i(gbk), .x_i(px), .y_i(py),
    .req_valid_i(gbl_req), .req_ready_o(gbl_rdy),
    .cpl_valid_o(gbl_cpl_v), .cpl_ready_i(gbl_cpl_r), .cpl_o(gbl_cpl), .gbl_o(gbl),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_gbx #(.Enable(1'b1)) i_gbx (
    .clk_i(clk), .rst_ni, .gbl_i(gbl), .gbd_i(gbd), .gbk_i(gbk),
    .req_valid_i(gbx_req), .req_ready_o(gbx_rdy),
    .cpl_valid_o(gbx_cpl_v), .cpl_ready_i(gbx_cpl_r), .cpl_o(gbx_cpl), .gbx_o(gbx)
  );
  g6lc_apu_vgpu_gbx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .gbl_i(gbl), .gbd_i(gbd), .gbk_i(gbk),
    .req_valid_i(gbx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(gbx_cpl_r), .cpl_o(off_cpl), .gbx_o(off_gbx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu gbd timeout case=%0d", cases); end

  function automatic logic [63:0] expect_addr(input logic [6:0] x, input logic [6:0] y);
    logic [8:0] beat;
    beat = {y[5:0], x[5:3]};
    expect_addr = APU_VGPU_GBW_ADDR + (64'(beat) << 5);
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_lane) beat[63:32] = 32'h0;
      if (rd_addr != expect_addr(px, py) || rd_len != 32'(APU_VGPU_BEAT_BYTES))
        order_bad <= 1'b1;
      seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_lane <= 1'b0;
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

  task automatic good_gbk;
    gbk = '0;
    gbk.valid = 1'b1;
    gbk.word = APU_VGPU_CLEAR_WORD;
    gbk.beats = APU_VGPU_GPW_BEATS;
    gbk.src = APU_VGPU_GPW_ADDR;
    gbk.dst = APU_VGPU_GBW_ADDR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_gbx == '0 &&
          off_cpl == '0);
  endtask

  task automatic gbd_step(input apu_vgpu_gbd_status_e st, input string name);
    @(negedge clk);
    while (!gbd_rdy) @(negedge clk);
    cases++;
    gbd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbd_req = 1'b0;
    while (!gbd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gbd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GBD_OK) begin
      check("rectangle", gbd.valid && gbd.width == 16'd64 && gbd.height == 16'd64 &&
            gbd.stride == 16'd256 && gbd.bytes == 32'd16384 &&
            gbd.format == APU_VIRGL_FMT_B8G8R8X8 && gbd.base == APU_VGPU_GBW_ADDR);
    end
    @(negedge clk);
    check($sformatf("%s held", name), gbd_cpl_v);
    gbd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbd_cpl_r = 1'b0;
    while (gbd_cpl_v) @(negedge clk);
  endtask

  task automatic gbl_step(input apu_vgpu_gbl_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gbl_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    gbl_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbl_req = 1'b0;
    while (!gbl_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gbl_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GBL_OK) begin
      check("lane", gbl.valid && gbl.word == APU_VGPU_CLEAR_WORD &&
            gbl.x == px && gbl.y == py && gbl.addr == expect_addr(px, py) &&
            seen == gbl.addr && !order_bad);
      check("one read", nread == n0 + 1);
    end else if (name == "bad beat" || name == "bad lane") begin
      check("one read", nread == n0 + 1 && !gbl.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), gbl_cpl_v);
    gbl_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbl_cpl_r = 1'b0;
    while (gbl_cpl_v) @(negedge clk);
  endtask

  task automatic gbx_step(input apu_vgpu_gbx_status_e st, input string name);
    @(negedge clk);
    while (!gbx_rdy) @(negedge clk);
    cases++;
    gbx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbx_req = 1'b0;
    while (!gbx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gbx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gbx_cpl_v);
    gbx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbx_cpl_r = 1'b0;
    while (gbx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    gbd_req = 1'b0;
    gbl_req = 1'b0;
    gbx_req = 1'b0;
    gbd_cpl_r = 1'b0;
    gbl_cpl_r = 1'b0;
    gbx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbk = '0;
    want_w = '0;
    want_h = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          gbd == '0 && gbl == '0 && gbx == '0);
    check("profiles keep the rectangle off",
          !ApuOff.GbdEn && !ApuOff.GblEn && !ApuOff.GbxEn &&
          !ApuP1Transport.GbdEn && !ApuP1Transport.GblEn && !ApuP1Transport.GbxEn &&
          !ApuHarness.GbdEn && !ApuHarness.GblEn && !ApuHarness.GbxEn &&
          !ApuSchedBoth.GbdEn && !ApuSchedBoth.GblEn && !ApuSchedBoth.GbxEn &&
          !ApuBadVirglGrant.GbdEn && !ApuBadVirglGrant.GblEn &&
          !ApuBadVirglGrant.GbxEn);
    cfg = ApuP1Transport;
    cfg.GbdEn = 1'b1;
    cfg.GblEn = 1'b1;
    cfg.GbxEn = 1'b1;
    check("rectangle does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GbdEn = 1'b1;
    cfg.GblEn = 1'b1;
    cfg.GbxEn = 1'b1;
    check("rectangle does not legalize virgl", !apu_cfg_legal(cfg));
    check("rectangle places",
          APU_VGPU_GBD_W == 16'd64 && APU_VGPU_GBD_H == 16'd64 &&
          APU_VGPU_GBD_STRIDE == 16'd256 && APU_VGPU_GBD_BYTES == 32'd16384 &&
          APU_VIRGL_FMT_B8G8R8X8 == 32'd2 &&
          expect_addr(7'd1, 7'd0) == APU_VGPU_GBW_ADDR &&
          expect_addr(7'd63, 7'd63) == APU_VGPU_GBW_TAIL);

    gbl_step(APU_VGPU_GBL_EMPTY, "lane empty");
    gbd_step(APU_VGPU_GBD_EMPTY, "rectangle empty");
    gbx_step(APU_VGPU_GBX_EMPTY, "keep empty");
    good_gbk();
    want_w = 16'd640;
    want_h = 16'd480;
    gbd_step(APU_VGPU_GBD_FAULT, "scene size");
    want_w = 16'd64;
    want_h = 16'd64;
    gbd_step(APU_VGPU_GBD_OK, "rectangle");
    gbd_step(APU_VGPU_GBD_FAULT, "rectangle again");
    check("rectangle stays", gbd.width == 16'd64 && gbd.bytes == 32'd16384 &&
          gbd.base == APU_VGPU_GBW_ADDR);
    px = 7'd64;
    py = 7'd0;
    gbl_step(APU_VGPU_GBL_FAULT, "x past");
    px = 7'd0;
    py = 7'd64;
    gbl_step(APU_VGPU_GBL_FAULT, "y past");
    px = 7'd1;
    py = 7'd0;
    fail_rd = 1'b1;
    gbl_step(APU_VGPU_GBL_FAULT, "bad beat");
    bad_lane = 1'b1;
    gbl_step(APU_VGPU_GBL_FAULT, "bad lane");
    gbl_step(APU_VGPU_GBL_OK, "pixel 1 0");
    gbl_step(APU_VGPU_GBL_FAULT, "pixel again");
    check("lane stays", gbl.word == APU_VGPU_CLEAR_WORD && gbl.x == 7'd1 &&
          gbl.y == 7'd0 && gbl.addr == APU_VGPU_GBW_ADDR);
    gbk.word = 32'h0;
    gbx_step(APU_VGPU_GBX_FAULT, "keep bad word");
    check("keep rejected", !gbx.valid);
    gbk.word = APU_VGPU_CLEAR_WORD;
    gbx_step(APU_VGPU_GBX_OK, "keep lane");
    check("lane kept", gbx.valid && gbx.width == 16'd64 && gbx.height == 16'd64 &&
          gbx.bytes == 32'd16384 && gbx.word == APU_VGPU_CLEAR_WORD &&
          gbx.x == 7'd1 && gbx.y == 7'd0);
    gbx_step(APU_VGPU_GBX_FAULT, "keep again");
    check("keep stays", gbx.word == gbl.word && gbx.x == gbl.x);

    pulse_reset();
    check("reset clears", gbd == '0 && gbl == '0 && gbx == '0);
    gbk = '0;
    gbd_step(APU_VGPU_GBD_EMPTY, "after reset");
    good_gbk();
    want_w = 16'd64;
    want_h = 16'd64;
    gbd_step(APU_VGPU_GBD_OK, "rectangle after reset");
    px = 7'd63;
    py = 7'd63;
    gbl_step(APU_VGPU_GBL_OK, "pixel 63 63");
    check("corner", gbl.addr == APU_VGPU_GBW_TAIL && gbl.word == APU_VGPU_CLEAR_WORD &&
          gbl.x == 7'd63 && gbl.y == 7'd63);

    if (errors != 0) $fatal(1, "APU vgpu gbd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_gbd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
