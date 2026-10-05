// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_grd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rpw_t rpw;
  apu_vgpu_rpx_t rpx;
  logic [15:0] want_w = 0, want_h = 0;
  logic grd_req = 0, grd_rdy, grd_cpl_v, grd_cpl_r = 0;
  apu_vgpu_grd_cpl_t grd_cpl;
  apu_vgpu_grd_t grd;
  logic [6:0] px = 0, py = 0;
  logic grl_req = 0, grl_rdy, grl_cpl_v, grl_cpl_r = 0;
  apu_vgpu_grl_cpl_t grl_cpl;
  apu_vgpu_grl_t grl;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic grx_req = 0, grx_rdy, grx_cpl_v, grx_cpl_r = 0;
  apu_vgpu_grx_cpl_t grx_cpl, off_cpl;
  apu_vgpu_grx_t grx, off_grx;
  logic off_rdy, off_v;
  logic fail_rd = 0, clear_lane = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;
  localparam logic [255:0] Beat0 = {192'b0, Neighbor, Origin};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_grd #(.Enable(1'b1)) i_grd (
    .clk_i(clk), .rst_ni, .rpw_i(rpw), .rpx_i(rpx),
    .want_w_i(want_w), .want_h_i(want_h),
    .req_valid_i(grd_req), .req_ready_o(grd_rdy),
    .cpl_valid_o(grd_cpl_v), .cpl_ready_i(grd_cpl_r), .cpl_o(grd_cpl), .grd_o(grd)
  );
  g6lc_apu_vgpu_grl #(.Enable(1'b1)) i_grl (
    .clk_i(clk), .rst_ni, .grd_i(grd), .rpx_i(rpx), .x_i(px), .y_i(py),
    .req_valid_i(grl_req), .req_ready_o(grl_rdy),
    .cpl_valid_o(grl_cpl_v), .cpl_ready_i(grl_cpl_r), .cpl_o(grl_cpl), .grl_o(grl),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_grx #(.Enable(1'b1)) i_grx (
    .clk_i(clk), .rst_ni, .grl_i(grl), .grd_i(grd), .b0_i(b0),
    .req_valid_i(grx_req), .req_ready_o(grx_rdy),
    .cpl_valid_o(grx_cpl_v), .cpl_ready_i(grx_cpl_r), .cpl_o(grx_cpl), .grx_o(grx)
  );
  g6lc_apu_vgpu_grx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .grl_i(grl), .grd_i(grd), .b0_i(b0),
    .req_valid_i(grx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(grx_cpl_r), .cpl_o(off_cpl), .grx_o(off_grx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu grd timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Beat0;
      if (clear_lane) beat[63:32] = APU_VGPU_CLEAR_WORD;
      if (rd_addr != APU_VGPU_RPW_DST || rd_len != 32'(APU_VGPU_BEAT_BYTES))
        order_bad <= 1'b1;
      seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      clear_lane <= 1'b0;
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
    rpw = '0;
    rpw.valid = 1'b1;
    rpw.origin = Origin;
    rpw.neighbor = Neighbor;
    rpw.beats = APU_VGPU_GPW_BEATS;
    rpw.src = APU_VGPU_CSW_DST;
    rpw.dst = APU_VGPU_RPW_DST;
    rpw.cmd = VGPU_CMD_TRANSFER_FROM_HOST_3D;
    rpw.resource_id = APU_VIRGL_RES_RT;
    rpx = '0;
    rpx.valid = 1'b1;
    rpx.b0 = Neighbor[7:0];
    rpx.off0 = APU_VGPU_ACW_AT0;
    rpx.off1 = APU_VGPU_ACW_AT1;
    rpx.x0 = 7'd0;
    rpx.x1 = 7'd1;
    rpx.origin = Origin;
    rpx.neighbor = Neighbor;
    want_w = APU_VGPU_GBD_W;
    want_h = APU_VGPU_GBD_H;
    px = 7'd1;
    py = 7'd0;
    b0 = Neighbor[7:0];
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_grx == '0 &&
          off_cpl == '0);
  endtask

  task automatic grd_step(input apu_vgpu_grd_status_e st, input string name);
    @(negedge clk);
    while (!grd_rdy) @(negedge clk);
    cases++;
    grd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    grd_req = 1'b0;
    while (!grd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), grd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GRD_OK) begin
      check("rect", grd.valid && grd.width == 16'd64 && grd.height == 16'd64 &&
            grd.stride == 16'd256 && grd.bytes == 32'd16384 &&
            grd.format == APU_VIRGL_FMT_B8G8R8X8 &&
            grd.base == APU_VGPU_RPW_DST && grd.base != APU_VGPU_CSW_DST &&
            grd.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D &&
            grd.origin == Origin && grd.neighbor == Neighbor);
    end
    @(negedge clk);
    check($sformatf("%s held", name), grd_cpl_v);
    grd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    grd_cpl_r = 1'b0;
    while (grd_cpl_v) @(negedge clk);
  endtask

  task automatic grl_step(input apu_vgpu_grl_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!grl_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    grl_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    grl_req = 1'b0;
    while (!grl_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), grl_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GRL_OK) begin
      check("lane", grl.valid && grl.x == 7'd1 && grl.y == 7'd0 &&
            grl.word == Neighbor && grl.word != APU_VGPU_CLEAR_WORD &&
            grl.addr == APU_VGPU_RPW_DST && grl.addr != APU_VGPU_CSW_DST);
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_RPW_DST);
    end else if (name == "bad beat" || name == "clear lane") begin
      check("one read failed", nread == n0 + 1 && !grl.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), grl_cpl_v);
    grl_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    grl_cpl_r = 1'b0;
    while (grl_cpl_v) @(negedge clk);
  endtask

  task automatic grx_step(input apu_vgpu_grx_status_e st, input string name);
    @(negedge clk);
    while (!grx_rdy) @(negedge clk);
    cases++;
    grx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    grx_req = 1'b0;
    while (!grx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), grx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), grx_cpl_v);
    grx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    grx_cpl_r = 1'b0;
    while (grx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    grd_req = 1'b0;
    grl_req = 1'b0;
    grx_req = 1'b0;
    grd_cpl_r = 1'b0;
    grl_cpl_r = 1'b0;
    grx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rpw = '0;
    rpx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          grd == '0 && grl == '0 && grx == '0);
    check("profiles keep the rectangle off",
          !ApuOff.GrdEn && !ApuOff.GrlEn && !ApuOff.GrxEn &&
          !ApuP1Transport.GrdEn && !ApuP1Transport.GrlEn &&
          !ApuP1Transport.GrxEn &&
          !ApuHarness.GrdEn && !ApuHarness.GrlEn && !ApuHarness.GrxEn &&
          !ApuSchedBoth.GrdEn && !ApuSchedBoth.GrlEn && !ApuSchedBoth.GrxEn &&
          !ApuBadVirglGrant.GrdEn && !ApuBadVirglGrant.GrlEn &&
          !ApuBadVirglGrant.GrxEn);
    cfg = ApuP1Transport;
    cfg.GrdEn = 1'b1;
    cfg.GrlEn = 1'b1;
    cfg.GrxEn = 1'b1;
    check("rect does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GrdEn = 1'b1;
    cfg.GrlEn = 1'b1;
    cfg.GrxEn = 1'b1;
    check("rect does not legalize virgl", !apu_cfg_legal(cfg));
    check("rect places",
          APU_VGPU_RPW_DST == 64'h0000_0000_8807_0000 &&
          APU_VGPU_RPW_DST != APU_VGPU_CSW_DST &&
          APU_VGPU_GBD_W == 16'd64 && APU_VGPU_GBD_H == 16'd64 &&
          VGPU_CMD_TRANSFER_FROM_HOST_3D == 32'h0000_0206 &&
          Neighbor != APU_VGPU_CLEAR_WORD &&
          Neighbor[7:0] != APU_VGPU_CLEAR_R);

    grd_step(APU_VGPU_GRD_EMPTY, "rect empty");
    grl_step(APU_VGPU_GRL_EMPTY, "lane empty");
    grx_step(APU_VGPU_GRX_EMPTY, "order empty");
    good_in();
    want_w = 16'd640;
    want_h = 16'd480;
    grd_step(APU_VGPU_GRD_FAULT, "full surface");
    good_in();
    rpw.dst = APU_VGPU_CSW_DST;
    grd_step(APU_VGPU_GRD_FAULT, "color window");
    good_in();
    rpx.neighbor = APU_VGPU_CLEAR_WORD;
    grd_step(APU_VGPU_GRD_FAULT, "clear sample");
    good_in();
    rpw.cmd = 32'h0;
    grd_step(APU_VGPU_GRD_FAULT, "wrong cmd");
    good_in();
    grd_step(APU_VGPU_GRD_OK, "rect");
    grd_step(APU_VGPU_GRD_FAULT, "rect again");
    check("rect stays", grd.base == APU_VGPU_RPW_DST &&
          grd.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D &&
          grd.neighbor == Neighbor && grd.width == 16'd64);
    px = 7'd0;
    py = 7'd0;
    grl_step(APU_VGPU_GRL_FAULT, "origin point");
    check("origin rejected", !grl.valid);
    px = 7'd1;
    py = 7'd1;
    grl_step(APU_VGPU_GRL_FAULT, "next row");
    px = 7'd1;
    py = 7'd0;
    fail_rd = 1'b1;
    grl_step(APU_VGPU_GRL_FAULT, "bad beat");
    clear_lane = 1'b1;
    grl_step(APU_VGPU_GRL_FAULT, "clear lane");
    grl_step(APU_VGPU_GRL_OK, "sample lane");
    grl_step(APU_VGPU_GRL_FAULT, "lane again");
    check("lane stays", grl.word == Neighbor && grl.x == 7'd1 &&
          grl.addr == APU_VGPU_RPW_DST);
    b0 = APU_VGPU_CLEAR_R;
    grx_step(APU_VGPU_GRX_FAULT, "clear red first");
    check("clear red rejected", !grx.valid);
    b0 = APU_VGPU_CLEAR_B;
    grx_step(APU_VGPU_GRX_FAULT, "blue first");
    check("blue rejected", !grx.valid);
    b0 = APU_VGPU_CLEAR_A;
    grx_step(APU_VGPU_GRX_FAULT, "high byte first");
    check("high byte rejected", !grx.valid);
    b0 = Neighbor[7:0];
    grx_step(APU_VGPU_GRX_OK, "sample red first");
    check("sample red", grx.valid && grx.b0 == 8'h00 && grx.x == 7'd1 &&
          grx.word == Neighbor);
    grx_step(APU_VGPU_GRX_FAULT, "order again");
    check("order stays", grx.b0 == 8'h00 && grx.word == Neighbor);

    pulse_reset();
    check("reset clears", grd == '0 && grl == '0 && grx == '0);
    rpw = '0;
    rpx = '0;
    want_w = 16'd0;
    want_h = 16'd0;
    grd_step(APU_VGPU_GRD_EMPTY, "after reset");
    grl_step(APU_VGPU_GRL_EMPTY, "lane after reset");
    grx_step(APU_VGPU_GRX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu grd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_grd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
