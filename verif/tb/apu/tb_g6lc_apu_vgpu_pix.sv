// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_pix;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_clr_t clr;
  apu_vgpu_sci_t sci;
  apu_vgpu_fbo_t fbo;
  apu_vgpu_drw_t drw;
  logic u8_req = 0, u8_rdy, u8_cpl_v, u8_cpl_r = 0;
  apu_vgpu_u8_cpl_t u8_cpl;
  apu_vgpu_u8_t u8b;
  logic pix_req = 0, pix_rdy, pix_cpl_v, pix_cpl_r = 0;
  apu_vgpu_pix_cpl_t pix_cpl;
  apu_vgpu_pix_t pix;
  logic [15:0] px, py;
  logic pxr_req = 0, pxr_rdy, pxr_cpl_v, pxr_cpl_r = 0;
  apu_vgpu_pxr_cpl_t pxr_cpl, off_cpl;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_u8 #(.Enable(1'b1)) i_u8 (
    .clk_i(clk), .rst_ni, .clr_i(clr),
    .req_valid_i(u8_req), .req_ready_o(u8_rdy),
    .cpl_valid_o(u8_cpl_v), .cpl_ready_i(u8_cpl_r), .cpl_o(u8_cpl), .u8_o(u8b)
  );
  g6lc_apu_vgpu_pix #(.Enable(1'b1)) i_pix (
    .clk_i(clk), .rst_ni, .u8_i(u8b), .sci_i(sci), .fbo_i(fbo), .drw_i(drw),
    .req_valid_i(pix_req), .req_ready_o(pix_rdy),
    .cpl_valid_o(pix_cpl_v), .cpl_ready_i(pix_cpl_r), .cpl_o(pix_cpl), .pix_o(pix)
  );
  g6lc_apu_vgpu_pxr #(.Enable(1'b1)) i_pxr (
    .clk_i(clk), .rst_ni, .pix_i(pix), .x_i(px), .y_i(py),
    .req_valid_i(pxr_req), .req_ready_o(pxr_rdy),
    .cpl_valid_o(pxr_cpl_v), .cpl_ready_i(pxr_cpl_r), .cpl_o(pxr_cpl)
  );
  g6lc_apu_vgpu_pxr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .pix_i(pix), .x_i(px), .y_i(py),
    .req_valid_i(pxr_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(pxr_cpl_r), .cpl_o(off_cpl)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu pix timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_clr;
    clr = '0;
    clr.valid = 1'b1;
    clr.buffers = APU_VIRGL_CLEAR_COLOR;
    clr.red = APU_VIRGL_F32_P05;
    clr.green = APU_VIRGL_F32_P05;
    clr.blue = APU_VIRGL_F32_P10;
    clr.alpha = APU_VIRGL_F32_ONE;
    clr.next = 32'd908;
  endtask

  task automatic good_place;
    sci = '0;
    sci.valid = 1'b1;
    sci.width = 16'd640;
    sci.height = 16'd480;
    sci.next = 32'd824;
    fbo = '0;
    fbo.valid = 1'b1;
    fbo.nr_cbufs = 32'd1;
    fbo.surface = APU_VIRGL_SURFACE_HANDLE;
    fbo.next = 32'd872;
    drw = '0;
    drw.valid = 1'b1;
    drw.count = APU_VIRGL_VERT_COUNT;
    drw.prim = APU_VIRGL_PRIM_STRIP;
    drw.next = APU_VGPU_SCENE_BYTES;
  endtask

  task automatic u8_step(input apu_vgpu_u8_status_e st, input string name);
    @(negedge clk);
    while (!u8_rdy) @(negedge clk);
    cases++;
    u8_req = 1;
    @(posedge clk); @(negedge clk); u8_req = 0;
    while (!u8_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), u8_cpl.status == st);
    if (st == APU_VGPU_U8_OK)
      check($sformatf("%s word", name), u8b.word == APU_VGPU_CLEAR_WORD &&
            u8b.red == APU_VGPU_CLEAR_R && u8b.blue == APU_VGPU_CLEAR_B &&
            u8b.alpha == APU_VGPU_CLEAR_A);
    @(negedge clk);
    check($sformatf("%s held", name), u8_cpl_v);
    u8_cpl_r = 1;
    @(posedge clk); @(negedge clk); u8_cpl_r = 0;
    while (u8_cpl_v) @(negedge clk);
  endtask

  task automatic pix_step(input apu_vgpu_pix_status_e st, input string name);
    @(negedge clk);
    while (!pix_rdy) @(negedge clk);
    cases++;
    pix_req = 1;
    @(posedge clk); @(negedge clk); pix_req = 0;
    while (!pix_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), pix_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), pix_cpl_v);
    pix_cpl_r = 1;
    @(posedge clk); @(negedge clk); pix_cpl_r = 0;
    while (pix_cpl_v) @(negedge clk);
  endtask

  task automatic pxr_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_pxr_status_e st,
    input logic [13:0] addr,
    input string name
  );
    @(negedge clk);
    while (!pxr_rdy) @(negedge clk);
    cases++;
    px = x;
    py = y;
    pxr_req = 1;
    @(posedge clk); @(negedge clk); pxr_req = 0;
    while (!pxr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), pxr_cpl.status == st);
    if (st == APU_VGPU_PXR_OK)
      check($sformatf("%s sample", name), pxr_cpl.word == APU_VGPU_CLEAR_WORD && pxr_cpl.addr == addr);
    else
      check($sformatf("%s quiet", name), pxr_cpl.word == 32'h0);
    check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), pxr_cpl_v);
    pxr_cpl_r = 1;
    @(posedge clk); @(negedge clk); pxr_cpl_r = 0;
    while (pxr_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    u8_req = 0;
    pix_req = 0;
    pxr_req = 0;
    u8_cpl_r = 0;
    pix_cpl_r = 0;
    pxr_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    clr = '0;
    sci = '0;
    fbo = '0;
    drw = '0;
    px = '0;
    py = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && u8b == '0 && pix == '0);
    check("profiles keep pix off",
          !ApuOff.U8En && !ApuOff.PixEn && !ApuOff.PxrEn &&
          !ApuP1Transport.U8En && !ApuP1Transport.PixEn && !ApuP1Transport.PxrEn &&
          !ApuHarness.U8En && !ApuHarness.PixEn && !ApuHarness.PxrEn &&
          !ApuSchedBoth.U8En && !ApuSchedBoth.PixEn && !ApuSchedBoth.PxrEn &&
          !ApuBadVirglGrant.U8En && !ApuBadVirglGrant.PixEn && !ApuBadVirglGrant.PxrEn);
    cfg = ApuP1Transport;
    cfg.U8En = 1'b1;
    cfg.PixEn = 1'b1;
    cfg.PxrEn = 1'b1;
    check("pix does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.U8En = 1'b1;
    cfg.PixEn = 1'b1;
    cfg.PxrEn = 1'b1;
    check("pix does not legalize virgl", !apu_cfg_legal(cfg));

    u8_step(APU_VGPU_U8_EMPTY, "u8 empty");
    good_clr();
    clr.red = 32'h0;
    u8_step(APU_VGPU_U8_FAULT, "u8 red");
    check("red keeps", !u8b.valid);
    good_clr();
    u8_step(APU_VGPU_U8_OK, "u8");
    check("bytes", u8b.valid && u8b.word == 32'hFF1A_0D0D && u8b.word[7:0] == 8'h0D &&
          u8b.word[15:8] == 8'h0D && u8b.word[23:16] == 8'h1A && u8b.word[31:24] == 8'hFF);
    u8_step(APU_VGPU_U8_FAULT, "u8 again");
    check("u8 kept", u8b.valid && u8b.word == APU_VGPU_CLEAR_WORD);

    pix_step(APU_VGPU_PIX_EMPTY, "pix empty");
    good_place();
    drw.prim = 32'h0;
    pix_step(APU_VGPU_PIX_FAULT, "bad prim");
    check("prim keeps", !pix.valid);
    good_place();
    pix_step(APU_VGPU_PIX_OK, "corners");
    check("corner addrs", pix.valid && pix.word == APU_VGPU_CLEAR_WORD &&
          pix.a00 == APU_VGPU_PIX_00 && pix.ax == APU_VGPU_PIX_X &&
          pix.ay == APU_VGPU_PIX_Y && pix.axy == APU_VGPU_PIX_XY);
    pix_step(APU_VGPU_PIX_FAULT, "pix again");
    check("pix kept", pix.valid && pix.axy == APU_VGPU_PIX_XY);

    pxr_step(16'd0, 16'd0, APU_VGPU_PXR_OK, APU_VGPU_PIX_00, "p00");
    pxr_step(16'd63, 16'd0, APU_VGPU_PXR_OK, APU_VGPU_PIX_X, "px");
    pxr_step(16'd0, 16'd63, APU_VGPU_PXR_OK, APU_VGPU_PIX_Y, "py");
    pxr_step(16'd63, 16'd63, APU_VGPU_PXR_OK, APU_VGPU_PIX_XY, "pxy");
    pxr_step(16'd1, 16'd0, APU_VGPU_PXR_MISS, 14'd0, "interior");
    pxr_step(16'd64, 16'd0, APU_VGPU_PXR_FAULT, 14'd0, "outside");
    pxr_step(16'd0, 16'd0, APU_VGPU_PXR_OK, APU_VGPU_PIX_00, "reread");

    pulse_reset();
    check("reset clears", u8b == '0 && pix == '0);
    pxr_step(16'd0, 16'd0, APU_VGPU_PXR_EMPTY, 14'd0, "pxr empty");

    if (errors != 0) $fatal(1, "APU vgpu pix errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_pix cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
