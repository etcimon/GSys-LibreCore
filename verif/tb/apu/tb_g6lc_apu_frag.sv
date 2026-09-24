// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_frag;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v;
  logic c_v = 0, c_rdy, c_fv, c_fr = 0;
  apu_frag_req_t req;
  apu_frag_cpl_t cpl, off_cpl, snap;
  apu_vgpu_img_t img;
  logic img_we = 0;
  logic [APU_FRAG_ADDR_BITS-1:0] img_wa = '0;
  logic [31:0] img_wd = '0;
  apu_cover_req_t creq;
  apu_cover_frag_t cfrag, got;
  logic [15:0] peek_x = 0, peek_y = 0, peek_stride = 16'd16;
  logic [31:0] peek_px, off_peek;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  localparam logic [15:0] W = 16'd4;
  localparam logic [15:0] H = 16'd2;
  localparam logic [15:0] STRIDE = 16'd16;
  localparam logic [31:0] Blend = 32'hFF40_4080;
  localparam logic [31:0] Solid = 32'hFF00_00FF;
  localparam logic [31:0] Texel = 32'hFF80_FF40;

  g6lc_apu_cover #(.Enable(1'b1)) i_cover (
    .clk_i(clk), .rst_ni, .req_valid_i(c_v), .req_ready_o(c_rdy), .req_i(creq),
    .frag_valid_o(c_fv), .frag_ready_i(c_fr), .frag_o(cfrag)
  );
  g6lc_apu_frag #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .img_i(img),
    .img_we_i(img_we), .img_wa_i(img_wa), .img_wd_i(img_wd),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .peek_x_i(peek_x), .peek_y_i(peek_y), .peek_stride_i(peek_stride),
    .peek_px_o(peek_px)
  );
  g6lc_apu_frag_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .img_i(img),
    .img_we_i(img_we), .img_wa_i(img_wa), .img_wd_i(img_wd),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .peek_x_i(peek_x), .peek_y_i(peek_y), .peek_stride_i(peek_stride),
    .peek_px_o(off_peek)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "frag timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_cpl !== '0 || off_peek !== '0)
      $fatal(1, "disabled frag active");
  end

  task automatic load_img(input logic [255:0] pixels);
    for (int i = 0; i < 8; i++) begin
      @(negedge clk);
      img_wa = APU_FRAG_ADDR_BITS'(i * 4);
      img_wd = pixels[i*32 +: 32];
      img_we = 1'b1;
      @(posedge clk);
    end
    @(negedge clk);
    img_we = 1'b0;
  endtask

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic cover_sample(
    input logic signed [15:0] x0, y0, x1, y1, x2, y2, px, py
  );
    @(negedge clk);
    while (!c_rdy) @(negedge clk);
    creq = '0;
    creq.v0.x = x0; creq.v0.y = y0;
    creq.v1.x = x1; creq.v1.y = y1;
    creq.v2.x = x2; creq.v2.y = y2;
    creq.sample.x = px; creq.sample.y = py;
    creq.color = 32'hDEAD_BEEF;
    c_v = 1;
    @(posedge clk); @(negedge clk); c_v = 0;
    while (!c_fv) @(negedge clk);
    got = cfrag;
    c_fr = 1;
    @(posedge clk); @(negedge clk); c_fr = 0;
  endtask

  function automatic apu_frag_req_t mk(
    input apu_cover_frag_t frag,
    input logic [31:0] c0, c1, c2,
    input logic signed [15:0] x, y,
    input logic [15:0] stride, width, height
  );
    mk = '0;
    mk.frag = frag;
    mk.c0 = c0;
    mk.c1 = c1;
    mk.c2 = c2;
    mk.x = x;
    mk.y = y;
    mk.stride = stride;
    mk.width = width;
    mk.height = height;
  endfunction

  task automatic shade(
    input apu_frag_req_t r,
    input apu_frag_status_e st,
    input logic [31:0] col,
    input string name
  );
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    req = r;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    snap = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    check($sformatf("%s color", name), cpl.color == col);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == snap);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
  endtask

  task automatic look(
    input logic [15:0] x, y,
    input logic [31:0] want,
    input string name
  );
    @(negedge clk);
    peek_x = x;
    peek_y = y;
    peek_stride = STRIDE;
    @(posedge clk);
    check(name, peek_px == want);
  endtask

  initial begin
    apu_cfg_t cfg;
    apu_cover_frag_t painted, missed, bad;
    req = '0;
    creq = '0;
    img = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep frag off", !ApuOff.FragEn && !ApuHarness.FragEn &&
          !ApuP1Transport.FragEn && !ApuOff.TexelEn && !ApuHarness.TexelEn);
    cfg = ApuP1Transport;
    cfg.FragEn = 1'b1;
    cfg.TexelEn = 1'b1;
    check("frag does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.FragEn = 1'b1;
    check("frag does not legalize virgl", !apu_cfg_legal(cfg));

    cover_sample(16'sd0, 16'sd0, 16'sd4, 16'sd0, 16'sd0, 16'sd4, 16'sd1, 16'sd1);
    check("cover weights", got.covered && got.w0 == 48'sd8 && got.area == 48'sd16);
    painted = got;
    painted.color = 32'hDEAD_BEEF;
    shade(mk(painted, 32'hFF00_00FF, 32'hFF00_FF00, 32'hFFFF_0000,
             16'sd1, 16'sd0, STRIDE, W, H), APU_FRAG_OK, Blend, "blend");

    missed = painted;
    missed.covered = 1'b0;
    shade(mk(missed, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF,
             16'sd1, 16'sd0, STRIDE, W, H), APU_FRAG_MISS, 32'h0, "miss");
    look(16'd1, 16'd0, Blend, "miss keeps pixel");

    shade(mk(painted, 32'hFF00_00FF, 32'hFF00_FF00, 32'hFFFF_0000,
             16'sd4, 16'sd0, STRIDE, W, H), APU_FRAG_FAULT, 32'h0, "oob");
    look(16'd1, 16'd0, Blend, "oob keeps pixel");

    shade(mk(painted, 32'hFF00_00FF, 32'hFF00_FF00, 32'hFFFF_0000,
             16'sd0, 16'sd0, 16'd8, W, H), APU_FRAG_FAULT, 32'h0, "short stride");
    look(16'd1, 16'd0, Blend, "stride keeps pixel");

    bad = painted;
    bad.area = 48'sd0;
    shade(mk(bad, 32'hFF00_00FF, 32'hFF00_FF00, 32'hFFFF_0000,
             16'sd0, 16'sd0, STRIDE, W, H), APU_FRAG_FAULT, 32'h0, "zero area");
    bad = painted;
    bad.w2 = 48'sd0;
    shade(mk(bad, 32'hFF00_00FF, 32'hFF00_FF00, 32'hFFFF_0000,
             16'sd0, 16'sd0, STRIDE, W, H), APU_FRAG_FAULT, 32'h0, "bad sum");
    bad = painted;
    bad.area = 48'sd40000;
    bad.w0 = 48'sd40000;
    bad.w1 = '0;
    bad.w2 = '0;
    shade(mk(bad, 32'hFF00_00FF, 32'hFF00_FF00, 32'hFFFF_0000,
             16'sd0, 16'sd0, STRIDE, W, H), APU_FRAG_FAULT, 32'h0, "wide weight");
    look(16'd1, 16'd0, Blend, "faults keep pixel");

    shade(mk(painted, Solid, Solid, Solid, 16'sd0, 16'sd0, STRIDE, W, H),
          APU_FRAG_OK, Solid, "solid");

    look(16'd0, 16'd0, Solid, "image 0,0");
    look(16'd1, 16'd0, Blend, "image 1,0");
    look(16'd2, 16'd0, 32'h0, "image 2,0");
    look(16'd3, 16'd0, 32'h0, "image 3,0");
    look(16'd0, 16'd1, 32'h0, "image 0,1");
    look(16'd1, 16'd1, 32'h0, "image 1,1");
    look(16'd2, 16'd1, 32'h0, "image 2,1");
    look(16'd3, 16'd1, 32'h0, "image 3,1");

    begin
      apu_frag_req_t tr;
      tr = '0;
      tr.texel_write = 1'b1;
      tr.texel = Texel;
      shade(tr, APU_FRAG_OK, Texel, "texel store");
      look(16'd1, 16'd0, Blend, "store leaves pixel");
      tr = mk(painted, 32'h0, 32'h0, 32'h0, 16'sd2, 16'sd0, STRIDE, W, H);
      tr.use_texel = 1'b1;
      shade(tr, APU_FRAG_OK, Texel, "texel pixel");
      look(16'd2, 16'd0, Texel, "image 2,0 texel");
      look(16'd1, 16'd0, Blend, "texel leaves blend");
      tr.tu = 16'd1;
      shade(tr, APU_FRAG_FAULT, 32'h0, "texel miss coord");
      look(16'd2, 16'd0, Texel, "bad coord keeps texel");
      tr = mk(missed, 32'h0, 32'h0, 32'h0, 16'sd2, 16'sd0, STRIDE, W, H);
      tr.use_texel = 1'b1;
      shade(tr, APU_FRAG_MISS, 32'h0, "texel coverage miss");
      look(16'd2, 16'd0, Texel, "coverage miss keeps texel");
    end

    begin
      apu_frag_req_t ir;
      logic [255:0] pixels;
      logic [31:0] at_10;
      pixels = '0;
      for (int i = 0; i < 32; i++)
        pixels[i*8 +: 8] = 8'hA0 + i[7:0];
      at_10 = pixels[63:32];
      img = '0;
      ir = mk(painted, 32'h0, 32'h0, 32'h0, 16'sd1, 16'sd0, STRIDE, W, H);
      ir.use_image = 1'b1;
      shade(ir, APU_FRAG_FAULT, 32'h0, "image absent");
      look(16'd1, 16'd0, Blend, "absent keeps blend");
      img.valid = 1'b1;
      img.resource_id = 32'd7;
      img.length = 32'd32;
      load_img(pixels);
      shade(ir, APU_FRAG_OK, at_10, "image pixel");
      look(16'd1, 16'd0, at_10, "frag sees image");
      look(16'd0, 16'd0, Solid, "image leaves solid");
      look(16'd2, 16'd0, Texel, "image leaves texel");
      ir = mk(missed, 32'h0, 32'h0, 32'h0, 16'sd1, 16'sd0, STRIDE, W, H);
      ir.use_image = 1'b1;
      shade(ir, APU_FRAG_MISS, 32'h0, "image miss");
      look(16'd1, 16'd0, at_10, "image miss keeps");
      ir = mk(painted, 32'h0, 32'h0, 32'h0, -16'sd1, 16'sd0, STRIDE, W, H);
      ir.use_image = 1'b1;
      shade(ir, APU_FRAG_FAULT, 32'h0, "image neg");
      ir.use_texel = 1'b1;
      ir.x = 16'sd1;
      shade(ir, APU_FRAG_FAULT, 32'h0, "image and texel");
      look(16'd1, 16'd0, at_10, "image faults keep");
    end

    begin
      apu_frag_req_t pr;
      pr = mk(painted, 32'h0, 32'h0, 32'h0, 16'sd1, 16'sd0, STRIDE, W, H);
      pr.use_prog = 1'b1;
      pr.prog0 = APU_EX_LDC_R4_WORD;
      pr.prog1 = APU_EX_F32_ONE;
      shade(pr, APU_FRAG_OK, 32'hFFFF_FFFF, "prog one");
      look(16'd1, 16'd0, 32'hFFFF_FFFF, "prog one pixel");
      pr.prog1 = APU_EX_F32_HALF;
      shade(pr, APU_FRAG_OK, 32'hFF80_8080, "prog half");
      look(16'd1, 16'd0, 32'hFF80_8080, "prog half pixel");
      look(16'd0, 16'd0, Solid, "prog leaves solid");
      pr.prog1 = 32'h4000_0000;
      shade(pr, APU_FRAG_FAULT, 32'h0, "prog two");
      look(16'd1, 16'd0, 32'hFF80_8080, "prog two keeps");
      pr.prog0 = 32'h1800_0000;
      pr.prog1 = APU_EX_F32_ONE;
      shade(pr, APU_FRAG_FAULT, 32'h0, "prog mov");
      pr = mk(missed, 32'h0, 32'h0, 32'h0, 16'sd1, 16'sd0, STRIDE, W, H);
      pr.use_prog = 1'b1;
      pr.prog0 = APU_EX_LDC_R4_WORD;
      pr.prog1 = APU_EX_F32_ONE;
      shade(pr, APU_FRAG_MISS, 32'h0, "prog miss");
      look(16'd1, 16'd0, 32'hFF80_8080, "prog miss keeps");
      pr = mk(painted, 32'h0, 32'h0, 32'h0, 16'sd1, 16'sd0, STRIDE, W, H);
      pr.use_prog = 1'b1;
      pr.use_image = 1'b1;
      pr.prog0 = APU_EX_LDC_R4_WORD;
      pr.prog1 = APU_EX_F32_ONE;
      shade(pr, APU_FRAG_FAULT, 32'h0, "prog and image");
      look(16'd1, 16'd0, 32'hFF80_8080, "prog conflict keeps");
    end

    begin
      apu_frag_req_t gr;
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_prog = 1'b1;
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_HALF;
      gr.x = 16'sd4;
      gr.y = 16'sd0;
      gr.stride = 16'd32;
      gr.width = 16'd8;
      gr.height = 16'd4;
      shade(gr, APU_FRAG_OK, 32'hFF80_8080, "grow col");
      @(negedge clk);
      peek_x = 16'd4;
      peek_y = 16'd0;
      peek_stride = 16'd32;
      @(posedge clk);
      check("grow col pixel", peek_px == 32'hFF80_8080);
      look(16'd1, 16'd0, 32'hFF80_8080, "grow leaves old gray");
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_texel = 1'b1;
      gr.x = 16'sd0;
      gr.y = 16'sd2;
      gr.stride = 16'd32;
      gr.width = 16'd8;
      gr.height = 16'd4;
      shade(gr, APU_FRAG_OK, Texel, "grow row");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd2;
      peek_stride = 16'd32;
      @(posedge clk);
      check("grow row pixel", peek_px == Texel);
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_ONE;
      gr.use_prog = 1'b1;
      gr.use_texel = 1'b0;
      gr.x = 16'sd7;
      gr.y = 16'sd3;
      shade(gr, APU_FRAG_OK, 32'hFFFF_FFFF, "grow corner");
      @(negedge clk);
      peek_x = 16'd7;
      peek_y = 16'd3;
      peek_stride = 16'd32;
      @(posedge clk);
      check("grow corner pixel", peek_px == 32'hFFFF_FFFF);
      gr.x = 16'sd8;
      gr.y = 16'sd0;
      gr.prog1 = APU_EX_F32_HALF;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past width");
      @(negedge clk);
      peek_x = 16'd4;
      peek_y = 16'd0;
      peek_stride = 16'd32;
      @(posedge clk);
      check("past width keeps", peek_px == 32'hFF80_8080);
      gr.x = 16'sd0;
      gr.y = 16'sd4;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past height");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd2;
      peek_stride = 16'd32;
      @(posedge clk);
      check("past height keeps", peek_px == Texel);
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_prog = 1'b1;
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_HALF;
      gr.x = 16'sd8;
      gr.y = 16'sd0;
      gr.stride = 16'd64;
      gr.width = 16'd16;
      gr.height = 16'd8;
      shade(gr, APU_FRAG_OK, 32'hFF80_8080, "wider col");
      @(negedge clk);
      peek_x = 16'd8;
      peek_y = 16'd0;
      peek_stride = 16'd64;
      @(posedge clk);
      check("wider col pixel", peek_px == 32'hFF80_8080);
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_texel = 1'b1;
      gr.x = 16'sd0;
      gr.y = 16'sd4;
      gr.stride = 16'd64;
      gr.width = 16'd16;
      gr.height = 16'd8;
      shade(gr, APU_FRAG_OK, Texel, "wider row");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd4;
      peek_stride = 16'd64;
      @(posedge clk);
      check("wider row pixel", peek_px == Texel);
      gr.use_texel = 1'b0;
      gr.use_prog = 1'b1;
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_ONE;
      gr.x = 16'sd15;
      gr.y = 16'sd7;
      shade(gr, APU_FRAG_OK, 32'hFFFF_FFFF, "wider corner");
      @(negedge clk);
      peek_x = 16'd15;
      peek_y = 16'd7;
      peek_stride = 16'd64;
      @(posedge clk);
      check("wider corner pixel", peek_px == 32'hFFFF_FFFF);
      gr.x = 16'sd16;
      gr.y = 16'sd0;
      gr.prog1 = APU_EX_F32_HALF;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past wider");
      @(negedge clk);
      peek_x = 16'd8;
      peek_y = 16'd0;
      peek_stride = 16'd64;
      @(posedge clk);
      check("past wider keeps", peek_px == 32'hFF80_8080);
      gr.x = 16'sd0;
      gr.y = 16'sd8;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past taller");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd4;
      peek_stride = 16'd64;
      @(posedge clk);
      check("past taller keeps", peek_px == Texel);
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_prog = 1'b1;
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_HALF;
      gr.x = 16'sd16;
      gr.y = 16'sd0;
      gr.stride = 16'd128;
      gr.width = 16'd32;
      gr.height = 16'd16;
      shade(gr, APU_FRAG_OK, 32'hFF80_8080, "ceiling col");
      @(negedge clk);
      peek_x = 16'd16;
      peek_y = 16'd0;
      peek_stride = 16'd128;
      @(posedge clk);
      check("ceiling col pixel", peek_px == 32'hFF80_8080);
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_texel = 1'b1;
      gr.x = 16'sd0;
      gr.y = 16'sd8;
      gr.stride = 16'd128;
      gr.width = 16'd32;
      gr.height = 16'd16;
      shade(gr, APU_FRAG_OK, Texel, "ceiling row");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd8;
      peek_stride = 16'd128;
      @(posedge clk);
      check("ceiling row pixel", peek_px == Texel);
      gr.use_texel = 1'b0;
      gr.use_prog = 1'b1;
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_ONE;
      gr.x = 16'sd31;
      gr.y = 16'sd15;
      shade(gr, APU_FRAG_OK, 32'hFFFF_FFFF, "ceiling corner");
      @(negedge clk);
      peek_x = 16'd31;
      peek_y = 16'd15;
      peek_stride = 16'd128;
      @(posedge clk);
      check("ceiling corner pixel", peek_px == 32'hFFFF_FFFF);
      gr.x = 16'sd32;
      gr.y = 16'sd0;
      gr.prog1 = APU_EX_F32_HALF;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past ceiling");
      @(negedge clk);
      peek_x = 16'd16;
      peek_y = 16'd0;
      peek_stride = 16'd128;
      @(posedge clk);
      check("past ceiling keeps", peek_px == 32'hFF80_8080);
      gr.x = 16'sd0;
      gr.y = 16'sd16;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past ceiling height");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd8;
      peek_stride = 16'd128;
      @(posedge clk);
      check("past ceiling height keeps", peek_px == Texel);
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_prog = 1'b1;
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_HALF;
      gr.x = 16'sd32;
      gr.y = 16'sd0;
      gr.stride = 16'd256;
      gr.width = 16'd64;
      gr.height = 16'd32;
      shade(gr, APU_FRAG_OK, 32'hFF80_8080, "scene col");
      @(negedge clk);
      peek_x = 16'd32;
      peek_y = 16'd0;
      peek_stride = 16'd256;
      @(posedge clk);
      check("scene col pixel", peek_px == 32'hFF80_8080);
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_texel = 1'b1;
      gr.x = 16'sd0;
      gr.y = 16'sd16;
      gr.stride = 16'd256;
      gr.width = 16'd64;
      gr.height = 16'd32;
      shade(gr, APU_FRAG_OK, Texel, "scene row");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd16;
      peek_stride = 16'd256;
      @(posedge clk);
      check("scene row pixel", peek_px == Texel);
      gr.use_texel = 1'b0;
      gr.use_prog = 1'b1;
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_ONE;
      gr.x = 16'sd63;
      gr.y = 16'sd31;
      shade(gr, APU_FRAG_OK, 32'hFFFF_FFFF, "scene corner");
      @(negedge clk);
      peek_x = 16'd63;
      peek_y = 16'd31;
      peek_stride = 16'd256;
      @(posedge clk);
      check("scene corner pixel", peek_px == 32'hFFFF_FFFF);
      gr.x = 16'sd64;
      gr.y = 16'sd0;
      gr.prog1 = APU_EX_F32_HALF;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past scene width");
      @(negedge clk);
      peek_x = 16'd32;
      peek_y = 16'd0;
      peek_stride = 16'd256;
      @(posedge clk);
      check("past scene width keeps", peek_px == 32'hFF80_8080);
      gr.x = 16'sd0;
      gr.y = 16'sd32;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past scene height");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd16;
      peek_stride = 16'd256;
      @(posedge clk);
      check("past scene height keeps", peek_px == Texel);
      gr = '0;
      gr.frag.covered = 1'b1;
      gr.use_prog = 1'b1;
      gr.prog0 = APU_EX_LDC_R4_WORD;
      gr.prog1 = APU_EX_F32_HALF;
      gr.x = 16'sd0;
      gr.y = 16'sd32;
      gr.stride = 16'd256;
      gr.width = 16'd64;
      gr.height = 16'd64;
      shade(gr, APU_FRAG_OK, 32'hFF80_8080, "full row");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd32;
      peek_stride = 16'd256;
      @(posedge clk);
      check("full row pixel", peek_px == 32'hFF80_8080);
      gr.use_prog = 1'b1;
      gr.prog1 = APU_EX_F32_ONE;
      gr.x = 16'sd63;
      gr.y = 16'sd63;
      shade(gr, APU_FRAG_OK, 32'hFFFF_FFFF, "full corner");
      @(negedge clk);
      peek_x = 16'd63;
      peek_y = 16'd63;
      peek_stride = 16'd256;
      @(posedge clk);
      check("full corner pixel", peek_px == 32'hFFFF_FFFF);
      gr.x = 16'sd0;
      gr.y = 16'sd64;
      gr.prog1 = APU_EX_F32_HALF;
      shade(gr, APU_FRAG_FAULT, 32'h0, "past full height");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd32;
      peek_stride = 16'd256;
      @(posedge clk);
      check("past full height keeps", peek_px == 32'hFF80_8080);
    end

    if (errors != 0) $fatal(1, "APU frag errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_frag cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
