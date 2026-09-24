// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_fil;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_pix_t pix;
  apu_vgpu_sci_t sci;
  logic fil_req = 0, fil_rdy, fil_cpl_v, fil_cpl_r = 0;
  apu_vgpu_fil_cpl_t fil_cpl;
  apu_vgpu_fil_t fil;
  logic [15:0] fx, fy;
  logic frd_req = 0, frd_rdy, frd_cpl_v, frd_cpl_r = 0;
  apu_vgpu_frd_cpl_t frd_cpl, off_cpl;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [13:0] Addr10 = 14'd4;
  localparam logic [13:0] Addr23 = 14'd776;

  g6lc_apu_vgpu_fil #(.Enable(1'b1)) i_fil (
    .clk_i(clk), .rst_ni, .pix_i(pix), .sci_i(sci),
    .req_valid_i(fil_req), .req_ready_o(fil_rdy),
    .cpl_valid_o(fil_cpl_v), .cpl_ready_i(fil_cpl_r), .cpl_o(fil_cpl), .fil_o(fil)
  );
  g6lc_apu_vgpu_frd #(.Enable(1'b1)) i_frd (
    .clk_i(clk), .rst_ni, .fil_i(fil), .x_i(fx), .y_i(fy),
    .req_valid_i(frd_req), .req_ready_o(frd_rdy),
    .cpl_valid_o(frd_cpl_v), .cpl_ready_i(frd_cpl_r), .cpl_o(frd_cpl)
  );
  g6lc_apu_vgpu_frd_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .fil_i(fil), .x_i(fx), .y_i(fy),
    .req_valid_i(frd_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(frd_cpl_r), .cpl_o(off_cpl)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu fil timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_pix;
    pix = '0;
    pix.valid = 1'b1;
    pix.word = APU_VGPU_CLEAR_WORD;
    pix.a00 = APU_VGPU_PIX_00;
    pix.ax = APU_VGPU_PIX_X;
    pix.ay = APU_VGPU_PIX_Y;
    pix.axy = APU_VGPU_PIX_XY;
    sci = '0;
    sci.valid = 1'b1;
    sci.width = 16'd640;
    sci.height = 16'd480;
  endtask

  task automatic fil_step(input apu_vgpu_fil_status_e st, input string name);
    @(negedge clk);
    while (!fil_rdy) @(negedge clk);
    cases++;
    fil_req = 1;
    @(posedge clk); @(negedge clk); fil_req = 0;
    while (!fil_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), fil_cpl.status == st);
    if (st == APU_VGPU_FIL_OK)
      check($sformatf("%s fill", name), fil.valid && fil.word == APU_VGPU_CLEAR_WORD &&
            fil.samples == APU_VGPU_FILL_N);
    @(negedge clk);
    check($sformatf("%s held", name), fil_cpl_v);
    fil_cpl_r = 1;
    @(posedge clk); @(negedge clk); fil_cpl_r = 0;
    while (fil_cpl_v) @(negedge clk);
  endtask

  task automatic frd_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_frd_status_e st,
    input logic [13:0] addr,
    input string name
  );
    @(negedge clk);
    while (!frd_rdy) @(negedge clk);
    cases++;
    fx = x;
    fy = y;
    frd_req = 1;
    @(posedge clk); @(negedge clk); frd_req = 0;
    while (!frd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), frd_cpl.status == st);
    if (st == APU_VGPU_FRD_OK)
      check($sformatf("%s sample", name), frd_cpl.word == APU_VGPU_CLEAR_WORD && frd_cpl.addr == addr);
    else
      check($sformatf("%s quiet", name), frd_cpl.word == 32'h0);
    check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), frd_cpl_v);
    frd_cpl_r = 1;
    @(posedge clk); @(negedge clk); frd_cpl_r = 0;
    while (frd_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    fil_req = 0;
    frd_req = 0;
    fil_cpl_r = 0;
    frd_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    pix = '0;
    sci = '0;
    fx = '0;
    fy = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && fil == '0);
    check("profiles keep fill off",
          !ApuOff.FilEn && !ApuOff.FrdEn &&
          !ApuP1Transport.FilEn && !ApuP1Transport.FrdEn &&
          !ApuHarness.FilEn && !ApuHarness.FrdEn &&
          !ApuSchedBoth.FilEn && !ApuSchedBoth.FrdEn &&
          !ApuBadVirglGrant.FilEn && !ApuBadVirglGrant.FrdEn);
    cfg = ApuP1Transport;
    cfg.FilEn = 1'b1;
    cfg.FrdEn = 1'b1;
    check("fill does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.FilEn = 1'b1;
    cfg.FrdEn = 1'b1;
    check("fill does not legalize virgl", !apu_cfg_legal(cfg));

    fil_step(APU_VGPU_FIL_EMPTY, "empty");
    frd_step(16'd1, 16'd0, APU_VGPU_FRD_EMPTY, 14'd0, "read early");
    good_pix();
    sci.height = 16'd64;
    fil_step(APU_VGPU_FIL_FAULT, "short scissor");
    check("short keeps", !fil.valid);
    good_pix();
    pix.word = 32'h0;
    fil_step(APU_VGPU_FIL_FAULT, "bad word");
    check("word keeps", !fil.valid);
    good_pix();
    fil_step(APU_VGPU_FIL_OK, "fill");
    check("4096", fil.valid && fil.samples == 32'd4096 && fil.word == 32'hFF1A_0D0D);
    fil_step(APU_VGPU_FIL_FAULT, "fill again");
    check("fill kept", fil.valid && fil.samples == APU_VGPU_FILL_N);

    frd_step(16'd0, 16'd0, APU_VGPU_FRD_OK, APU_VGPU_PIX_00, "origin");
    frd_step(16'd1, 16'd0, APU_VGPU_FRD_OK, Addr10, "interior");
    frd_step(16'd2, 16'd3, APU_VGPU_FRD_OK, Addr23, "sample 2,3");
    frd_step(16'd63, 16'd63, APU_VGPU_FRD_OK, APU_VGPU_PIX_XY, "far corner");
    frd_step(16'd64, 16'd0, APU_VGPU_FRD_FAULT, 14'd0, "x outside");
    frd_step(16'd0, 16'd64, APU_VGPU_FRD_FAULT, 14'd0, "y outside");
    frd_step(16'd1, 16'd0, APU_VGPU_FRD_OK, Addr10, "reread");

    pulse_reset();
    check("reset clears", fil == '0);
    frd_step(16'd1, 16'd0, APU_VGPU_FRD_EMPTY, 14'd0, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu fil errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_fil cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
