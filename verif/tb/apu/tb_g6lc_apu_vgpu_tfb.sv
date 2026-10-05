// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tfb;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rpw_t rpw;
  apu_vgpu_rox_t rox;
  apu_vgpu_grd_t grd;
  apu_vgpu_c3d_t c3d;
  logic [15:0] want_x = 0, want_y = 0, want_w = 0, want_h = 0;
  logic [31:0] res_w = 0, res_h = 0;
  logic tfb_req = 0, tfb_rdy, tfb_cpl_v, tfb_cpl_r = 0;
  apu_vgpu_tfb_cpl_t tfb_cpl;
  apu_vgpu_tfb_t tfb;
  logic tfr_req = 0, tfr_rdy, tfr_cpl_v, tfr_cpl_r = 0;
  apu_vgpu_tfr_cpl_t tfr_cpl;
  apu_vgpu_tfr_t tfr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen0 = 0, seen1 = 0, seen2 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic tfx_req = 0, tfx_rdy, tfx_cpl_v, tfx_cpl_r = 0;
  apu_vgpu_tfx_cpl_t tfx_cpl, off_cpl;
  apu_vgpu_tfx_t tfx, off_tfx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_xy = 0, bad_wide = 0, bad_rid = 0, bad_stride = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_tfb #(.Enable(1'b1)) i_tfb (
    .clk_i(clk), .rst_ni, .rpw_i(rpw), .rox_i(rox), .grd_i(grd), .c3d_i(c3d),
    .want_x_i(want_x), .want_y_i(want_y), .want_w_i(want_w), .want_h_i(want_h),
    .res_w_i(res_w), .res_h_i(res_h),
    .req_valid_i(tfb_req), .req_ready_o(tfb_rdy),
    .cpl_valid_o(tfb_cpl_v), .cpl_ready_i(tfb_cpl_r), .cpl_o(tfb_cpl), .tfb_o(tfb)
  );
  g6lc_apu_vgpu_tfr #(.Enable(1'b1)) i_tfr (
    .clk_i(clk), .rst_ni, .tfb_i(tfb), .rox_i(rox),
    .req_valid_i(tfr_req), .req_ready_o(tfr_rdy),
    .cpl_valid_o(tfr_cpl_v), .cpl_ready_i(tfr_cpl_r), .cpl_o(tfr_cpl), .tfr_o(tfr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_tfx #(.Enable(1'b1)) i_tfx (
    .clk_i(clk), .rst_ni, .tfr_i(tfr), .tfb_i(tfb), .rox_i(rox),
    .req_valid_i(tfx_req), .req_ready_o(tfx_rdy),
    .cpl_valid_o(tfx_cpl_v), .cpl_ready_i(tfx_cpl_r), .cpl_o(tfx_cpl), .tfx_o(tfx)
  );
  g6lc_apu_vgpu_tfx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .tfr_i(tfr), .tfb_i(tfb), .rox_i(rox),
    .req_valid_i(tfx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(tfx_cpl_r), .cpl_o(off_cpl), .tfx_o(off_tfx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu tfb timeout case=%0d", cases); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      beat_data[31:0] = VGPU_CMD_TRANSFER_FROM_HOST_3D;
      beat_data[159:128] = APU_VGPU_CTX_ID;
      beat_data[223:192] = bad_xy ? 32'd8 : 32'h0;
    end else if (idx == 1) begin
      beat_data[63:32] = bad_wide ? APU_VGPU_RT_W : 32'(APU_VGPU_GBD_W);
      beat_data[95:64] = bad_wide ? APU_VGPU_RT_H : 32'(APU_VGPU_GBD_H);
      beat_data[127:96] = 32'h1;
      beat_data[223:192] = bad_rid ? APU_VIRGL_RES_SCAN : APU_VIRGL_RES_RT;
    end else begin
      beat_data[31:0] = bad_stride ? APU_VGPU_TFB_ROW : APU_VGPU_TFB_STRIDE;
    end
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nread - run_base;
      want = idx == 0 ? APU_VGPU_TFB_CMD :
             idx == 1 ? APU_VGPU_TFB_B1 : APU_VGPU_TFB_B2;
      if (rd_addr != want || rd_len != 32'(APU_VGPU_BEAT_BYTES))
        order_bad <= 1'b1;
      if (idx == 0) seen0 <= rd_addr;
      if (idx == 1) seen1 <= rd_addr;
      seen2 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat_data(idx);
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 0) bad_xy <= 1'b0;
      if (idx == 1) begin
        bad_wide <= 1'b0;
        bad_rid <= 1'b0;
      end
      if (idx == 2) bad_stride <= 1'b0;
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
    rox = '0;
    rox.valid = 1'b1;
    rox.b0 = Origin[7:0];
    rox.word = Origin;
    rox.offset = 16'd0;
    rox.x = 7'd0;
    rox.y = 7'd0;
    grd = '0;
    grd.valid = 1'b1;
    grd.width = APU_VGPU_GBD_W;
    grd.height = APU_VGPU_GBD_H;
    grd.stride = APU_VGPU_GBD_STRIDE;
    grd.bytes = APU_VGPU_GBD_BYTES;
    grd.format = APU_VIRGL_FMT_B8G8R8X8;
    grd.base = APU_VGPU_RPW_DST;
    grd.origin = Origin;
    grd.neighbor = Neighbor;
    grd.cmd = VGPU_CMD_TRANSFER_FROM_HOST_3D;
    c3d = '0;
    c3d.rt_valid = 1'b1;
    c3d.rt_w = APU_VGPU_RT_W;
    c3d.rt_h = APU_VGPU_RT_H;
    want_x = 16'd0;
    want_y = 16'd0;
    want_w = APU_VGPU_GBD_W;
    want_h = APU_VGPU_GBD_H;
    res_w = APU_VGPU_RT_W;
    res_h = APU_VGPU_RT_H;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_tfx == '0 &&
          off_cpl == '0);
  endtask

  task automatic tfb_step(input apu_vgpu_tfb_status_e st, input string name);
    @(negedge clk);
    while (!tfb_rdy) @(negedge clk);
    cases++;
    tfb_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tfb_req = 1'b0;
    while (!tfb_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tfb_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TFB_OK) begin
      check("box", tfb.valid && tfb.x == 16'd0 && tfb.y == 16'd0 &&
            tfb.width == APU_VGPU_GBD_W && tfb.height == APU_VGPU_GBD_H &&
            tfb.res_w == APU_VGPU_RT_W && tfb.res_h == APU_VGPU_RT_H &&
            tfb.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D &&
            tfb.resource_id == APU_VIRGL_RES_RT);
    end
    @(negedge clk);
    check($sformatf("%s held", name), tfb_cpl_v);
    tfb_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tfb_cpl_r = 1'b0;
    while (tfb_cpl_v) @(negedge clk);
  endtask

  task automatic tfr_step(input apu_vgpu_tfr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!tfr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    tfr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tfr_req = 1'b0;
    while (!tfr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tfr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TFR_OK) begin
      check("command", tfr.valid && tfr.x == 16'd0 && tfr.y == 16'd0 &&
            tfr.width == APU_VGPU_GBD_W && tfr.height == APU_VGPU_GBD_H &&
            tfr.stride == APU_VGPU_TFB_STRIDE &&
            tfr.stride != APU_VGPU_TFB_ROW &&
            tfr.resource_id == APU_VIRGL_RES_RT &&
            tfr.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D &&
            tfr.addr == APU_VGPU_TFB_CMD);
      check("three reads", nread == n0 + 3 && !order_bad &&
            seen0 == APU_VGPU_TFB_CMD && seen1 == APU_VGPU_TFB_B1 &&
            seen2 == APU_VGPU_TFB_B2);
    end else if (name == "bad beat" || name == "shifted origin") begin
      check("one beat", nread == n0 + 1 && !tfr.valid);
    end else if (name == "wide box" || name == "scan resource") begin
      check("two beats", nread == n0 + 2 && !tfr.valid);
    end else if (name == "wide stride") begin
      check("three beats", nread == n0 + 3 && !tfr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), tfr_cpl_v);
    tfr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tfr_cpl_r = 1'b0;
    while (tfr_cpl_v) @(negedge clk);
  endtask

  task automatic tfx_step(input apu_vgpu_tfx_status_e st, input string name);
    @(negedge clk);
    while (!tfx_rdy) @(negedge clk);
    cases++;
    tfx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tfx_req = 1'b0;
    while (!tfx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tfx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tfx_cpl_v);
    tfx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tfx_cpl_r = 1'b0;
    while (tfx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    tfb_req = 1'b0;
    tfr_req = 1'b0;
    tfx_req = 1'b0;
    tfb_cpl_r = 1'b0;
    tfr_cpl_r = 1'b0;
    tfx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rpw = '0;
    rox = '0;
    grd = '0;
    c3d = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          tfb == '0 && tfr == '0 && tfx == '0);
    check("profiles keep the box off",
          !ApuOff.TfbEn && !ApuOff.TfrEn && !ApuOff.TfxEn &&
          !ApuP1Transport.TfbEn && !ApuP1Transport.TfrEn &&
          !ApuP1Transport.TfxEn &&
          !ApuHarness.TfbEn && !ApuHarness.TfrEn && !ApuHarness.TfxEn &&
          !ApuSchedBoth.TfbEn && !ApuSchedBoth.TfrEn && !ApuSchedBoth.TfxEn &&
          !ApuBadVirglGrant.TfbEn && !ApuBadVirglGrant.TfrEn &&
          !ApuBadVirglGrant.TfxEn);
    cfg = ApuP1Transport;
    cfg.TfbEn = 1'b1;
    cfg.TfrEn = 1'b1;
    cfg.TfxEn = 1'b1;
    check("box does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TfbEn = 1'b1;
    cfg.TfrEn = 1'b1;
    cfg.TfxEn = 1'b1;
    check("box does not legalize virgl", !apu_cfg_legal(cfg));
    check("known box",
          APU_VGPU_TFB_B1 == APU_VGPU_TFB_CMD + 64'd32 &&
          APU_VGPU_TFB_B2 == APU_VGPU_TFB_CMD + 64'd64 &&
          APU_VGPU_TFB_STRIDE == 32'(APU_VGPU_GBD_STRIDE) &&
          APU_VGPU_TFB_ROW == APU_VGPU_RT_W * 32'd4 &&
          APU_VGPU_TFB_CMD != APU_VGPU_RPW_DST &&
          Origin != Neighbor && Origin[7:0] != APU_VGPU_CLEAR_R);

    tfb_step(APU_VGPU_TFB_EMPTY, "box empty");
    tfr_step(APU_VGPU_TFR_EMPTY, "command empty");
    tfx_step(APU_VGPU_TFX_EMPTY, "stride empty");
    good_in();
    want_w = 16'd640;
    want_h = 16'd480;
    tfb_step(APU_VGPU_TFB_FAULT, "whole surface");
    want_w = APU_VGPU_GBD_W;
    want_h = APU_VGPU_GBD_H;
    res_w = 32'(APU_VGPU_GBD_W);
    res_h = 32'(APU_VGPU_GBD_H);
    tfb_step(APU_VGPU_TFB_FAULT, "probe resource");
    res_w = APU_VGPU_RT_W;
    res_h = APU_VGPU_RT_H;
    want_x = 16'd8;
    tfb_step(APU_VGPU_TFB_FAULT, "shifted x");
    want_x = 16'd0;
    want_y = 16'd8;
    tfb_step(APU_VGPU_TFB_FAULT, "shifted y");
    want_y = 16'd0;
    tfb_step(APU_VGPU_TFB_OK, "readpixels box");
    tfb_step(APU_VGPU_TFB_FAULT, "box again");
    fail_rd = 1'b1;
    tfr_step(APU_VGPU_TFR_FAULT, "bad beat");
    bad_xy = 1'b1;
    tfr_step(APU_VGPU_TFR_FAULT, "shifted origin");
    bad_wide = 1'b1;
    tfr_step(APU_VGPU_TFR_FAULT, "wide box");
    bad_rid = 1'b1;
    tfr_step(APU_VGPU_TFR_FAULT, "scan resource");
    bad_stride = 1'b1;
    tfr_step(APU_VGPU_TFR_FAULT, "wide stride");
    tfr_step(APU_VGPU_TFR_OK, "guest command");
    tfr_step(APU_VGPU_TFR_FAULT, "command again");
    tfx_step(APU_VGPU_TFX_OK, "packed stride");
    check("packed stride", tfx.valid && tfx.stride == APU_VGPU_TFB_STRIDE &&
          tfx.stride != APU_VGPU_TFB_ROW && tfx.x == 16'd0 &&
          tfx.res_w == APU_VGPU_RT_W);
    tfx_step(APU_VGPU_TFX_FAULT, "stride again");
    check("stride stays", tfx.stride == APU_VGPU_TFB_STRIDE);

    pulse_reset();
    check("reset clears", tfb == '0 && tfr == '0 && tfx == '0);
    rpw = '0;
    rox = '0;
    grd = '0;
    c3d = '0;
    tfb_step(APU_VGPU_TFB_EMPTY, "after reset");
    good_in();
    tfb_step(APU_VGPU_TFB_OK, "box after reset");

    if (errors != 0) $fatal(1, "APU vgpu tfb errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tfb cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
