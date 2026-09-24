// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_rsurf;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v;
  logic [31:0] peek_px, off_px;
  logic [15:0] peek_x = 0, peek_y = 0, peek_s = 16'd16;
  apu_rsurf_req_t sreq;
  apu_frag_cpl_t cpl, off_cpl, snap;
  apu_vgpu_res_t slot0, slot1;
  apu_vgpu_back_t back0, back1;
  apu_vgpu_img_t img0, img1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  logic v_v = 0, v_rdy, v_cplv, v_cplr = 0;
  logic [319:0] vcmd;
  apu_vgpu_cpl_t vcpl;
  logic b_v = 0, b_rdy, b_cplv, b_cplr = 0;
  logic [383:0] bcmd;
  apu_vgpu_cpl_t bcpl;
  logic x_v = 0, x_rdy, x_cplv, x_cplr = 0;
  logic [447:0] xcmd;
  apu_vgpu_cpl_t xcpl;
  logic rd_valid, rd_ready = 0, rd_rsp_ready;
  logic [63:0] rd_addr;
  logic [31:0] rd_len;
  logic rsp_v = 0, rsp_ok = 0;
  logic [63:0] rsp_addr = '0;
  logic [31:0] rsp_len = '0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = '0;
  logic xpeek_slot = 0;
  logic [APU_FRAG_ADDR_BITS-1:0] xpeek_addr = '0;
  logic [31:0] xpeek_word;
  logic img_we = 0;
  logic [APU_FRAG_ADDR_BITS-1:0] img_wa = '0;
  logic [31:0] img_wd = '0;

  localparam logic [63:0] Fence = 64'h1122_3344_5566_7788;
  localparam logic [63:0] BackAddr = 64'h0000_0000_8800_1000;
  localparam logic [31:0] BackLen = 32'd32;

  g6lc_apu_vgpu_cmd #(.Enable(1'b1)) i_cmd (
    .clk_i(clk), .rst_ni, .req_valid_i(v_v), .req_ready_o(v_rdy), .cmd_i(vcmd),
    .cpl_valid_o(v_cplv), .cpl_ready_i(v_cplr), .cpl_o(vcpl),
    .slot0_o(slot0), .slot1_o(slot1)
  );
  g6lc_apu_vgpu_back #(.Enable(1'b1)) i_back (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .req_valid_i(b_v), .req_ready_o(b_rdy), .cmd_i(bcmd),
    .cpl_valid_o(b_cplv), .cpl_ready_i(b_cplr), .cpl_o(bcpl),
    .back0_o(back0), .back1_o(back1)
  );
  g6lc_apu_vgpu_xfer #(.Enable(1'b1)) i_xfer (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .back0_i(back0), .back1_i(back1),
    .req_valid_i(x_v), .req_ready_o(x_rdy), .cmd_i(xcmd),
    .cpl_valid_o(x_cplv), .cpl_ready_i(x_cplr), .cpl_o(xcpl),
    .img0_o(img0), .img1_o(img1),
    .peek_slot_i(xpeek_slot), .peek_addr_i(xpeek_addr), .peek_word_o(xpeek_word),
    .rd_valid_o(rd_valid), .rd_ready_i(rd_ready), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rd_rsp_ready), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_rsurf #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .img_i(img0),
    .img_we_i(img_we), .img_wa_i(img_wa), .img_wd_i(img_wd),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(sreq),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .peek_x_i(peek_x), .peek_y_i(peek_y), .peek_stride_i(peek_s), .peek_px_o(peek_px)
  );
  g6lc_apu_rsurf_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .img_i(img0),
    .img_we_i(img_we), .img_wa_i(img_wa), .img_wd_i(img_wd),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(sreq),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .peek_x_i(peek_x), .peek_y_i(peek_y), .peek_stride_i(peek_s), .peek_px_o(off_px)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "rsurf timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_px !== 0)
      $fatal(1, "disabled resource surface active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] ramp();
    ramp = '0;
    for (int i = 0; i < 32; i++)
      ramp[i*8 +: 8] = 8'hA0 + i[7:0];
  endfunction

  function automatic logic [447:0] xfer_cmd();
    xfer_cmd = {32'h0, 32'd7, 64'h0, 32'd2, 32'd4, 32'h0, 32'h0, 32'h0, 32'd3,
                Fence, VGPU_FLAG_FENCE, VGPU_CMD_TRANSFER_TO_HOST_2D};
  endfunction

  task automatic create_res;
    @(negedge clk);
    while (!v_rdy) @(negedge clk);
    vcmd = {32'd2, 32'd4, VGPU_FORMAT_R8G8B8A8_UNORM, 32'd7, 32'h0, 32'd3,
            Fence, VGPU_FLAG_FENCE, VGPU_CMD_RESOURCE_CREATE_2D};
    v_v = 1;
    @(posedge clk); @(negedge clk); v_v = 0;
    while (!v_cplv) @(negedge clk);
    check("create ok", vcpl.resp_type == VGPU_RESP_OK_NODATA && vcpl.resource_id == 32'd7);
    @(negedge clk);
    v_cplr = 1;
    @(posedge clk); @(negedge clk); v_cplr = 0;
    while (v_cplv) @(negedge clk);
  endtask

  task automatic attach_res;
    @(negedge clk);
    while (!b_rdy) @(negedge clk);
    bcmd = {32'h0, BackLen, BackAddr, 32'd1, 32'd7, 32'h0, 32'd3,
            Fence, VGPU_FLAG_FENCE, VGPU_CMD_RESOURCE_ATTACH_BACKING};
    b_v = 1;
    @(posedge clk); @(negedge clk); b_v = 0;
    while (!b_cplv) @(negedge clk);
    check("attach ok", bcpl.resp_type == VGPU_RESP_OK_NODATA);
    @(negedge clk);
    b_cplr = 1;
    @(posedge clk); @(negedge clk); b_cplr = 0;
    while (b_cplv) @(negedge clk);
  endtask

  task automatic read_image(input logic [APU_VGPU_BEAT_BYTES*8-1:0] pixels);
    @(negedge clk);
    while (!x_rdy) @(negedge clk);
    xcmd = xfer_cmd();
    x_v = 1;
    @(posedge clk); @(negedge clk); x_v = 0;
    while (!rd_valid) @(negedge clk);
    check("read addr", rd_addr == BackAddr && rd_len == BackLen);
    rd_ready = 1;
    @(posedge clk); @(negedge clk); rd_ready = 0;
    if (rd_rsp_ready !== 1'b1) $fatal(1, "image response not accepted");
    rsp_ok = 1;
    rsp_addr = BackAddr;
    rsp_len = BackLen;
    rsp_data = pixels;
    rsp_v = 1;
    @(posedge clk); @(negedge clk); rsp_v = 0;
    while (!x_cplv) @(negedge clk);
    check("xfer ok", xcpl.resp_type == VGPU_RESP_OK_NODATA);
    @(negedge clk);
    x_cplr = 1;
    @(posedge clk); @(negedge clk); x_cplr = 0;
    while (x_cplv) @(negedge clk);
  endtask

  task automatic paint(
    input logic covered,
    input logic signed [15:0] x, y,
    input logic [15:0] stride, width, height,
    input apu_frag_status_e st,
    input logic [31:0] col,
    input string name
  );
    apu_frag_cpl_t seen;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    sreq = '0;
    sreq.covered = covered;
    sreq.x = x;
    sreq.y = y;
    sreq.stride = stride;
    sreq.width = width;
    sreq.height = height;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    seen = cpl;
    snap = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    check($sformatf("%s color", name), cpl.color == col);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
  endtask

  task automatic look(
    input logic [15:0] x, y,
    input logic [31:0] exp,
    input string name
  );
    peek_x = x;
    peek_y = y;
    peek_s = 16'd16;
    @(posedge clk);
    check(name, peek_px == exp);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    v_v = 0;
    v_cplr = 0;
    b_v = 0;
    b_cplr = 0;
    x_v = 0;
    x_cplr = 0;
    rd_ready = 0;
    rsp_v = 0;
    img_we = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  task automatic copy_image(input logic [APU_VGPU_BEAT_BYTES*8-1:0] exp);
    logic [31:0] got;
    for (int i = 0; i < 8; i++) begin
      @(negedge clk);
      xpeek_slot = 1'b0;
      xpeek_addr = APU_FRAG_ADDR_BITS'(i * 4);
      @(posedge clk);
      got = xpeek_word;
      check($sformatf("xfer word %0d", i), got == exp[i*32 +: 32]);
      @(negedge clk);
      img_wa = APU_FRAG_ADDR_BITS'(i * 4);
      img_wd = got;
      img_we = 1'b1;
      @(posedge clk);
    end
    @(negedge clk);
    img_we = 1'b0;
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] pixels;
    logic [31:0] at_10;
    pixels = ramp();
    at_10 = pixels[63:32];
    sreq = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 && peek_px == 0);
    check("profiles keep surf off",
          !ApuOff.SurfEn && !ApuP1Transport.SurfEn && !ApuHarness.SurfEn &&
          !ApuSchedBoth.SurfEn && !ApuBadVirglGrant.SurfEn);
    cfg = ApuP1Transport;
    cfg.SurfEn = 1'b1;
    check("surf does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.SurfEn = 1'b1;
    check("surf does not legalize virgl", !apu_cfg_legal(cfg));

    paint(1'b1, 16'sd1, 16'sd0, 16'd16, 16'd4, 16'd2, APU_FRAG_FAULT, 32'h0, "no image");

    create_res();
    attach_res();
    read_image(pixels);
    check("image", img0.valid && img0.resource_id == 32'd7 && img0.length == BackLen &&
          img1 == '0);
    copy_image(pixels);

    paint(1'b1, 16'sd1, 16'sd0, 16'd16, 16'd4, 16'd2, APU_FRAG_OK, at_10, "sample");
    check("sample color", snap.color == at_10 && snap.status == APU_FRAG_OK);
    look(16'd1, 16'd0, at_10, "peek 1,0");
    look(16'd0, 16'd0, 32'h0, "peek 0,0");
    look(16'd2, 16'd0, 32'h0, "peek 2,0");

    paint(1'b0, 16'sd0, 16'sd0, 16'd16, 16'd4, 16'd2, APU_FRAG_MISS, 32'h0, "miss");
    look(16'd1, 16'd0, at_10, "miss keeps");
    look(16'd0, 16'd0, 32'h0, "miss writes nothing");

    paint(1'b1, -16'sd1, 16'sd0, 16'd16, 16'd4, 16'd2, APU_FRAG_FAULT, 32'h0, "neg");
    paint(1'b1, 16'sd4, 16'sd0, 16'd16, 16'd4, 16'd2, APU_FRAG_FAULT, 32'h0, "outside");
    paint(1'b1, 16'sd1, 16'sd0, 16'd8, 16'd4, 16'd2, APU_FRAG_FAULT, 32'h0, "stride");
    look(16'd1, 16'd0, at_10, "faults keep");

    pulse_reset();
    check("reset clears", img0 == '0 && peek_px == 0);
    paint(1'b1, 16'sd1, 16'sd0, 16'd16, 16'd4, 16'd2, APU_FRAG_FAULT, 32'h0, "after reset");

    if (errors != 0) $fatal(1, "APU rsurf errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_rsurf cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
