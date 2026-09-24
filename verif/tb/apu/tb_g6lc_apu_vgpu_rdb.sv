// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rdb;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v, off_wr_v, off_rsp_rdy;
  logic [1:0] wrote, off_wrote;
  logic [575:0] rcmd;
  logic [63:0] wr_addr, off_addr;
  logic [31:0] wr_len, off_len;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data, off_data;
  logic frag_we = 0;
  logic [APU_FRAG_ADDR_BITS-1:0] frag_wa = '0;
  logic [31:0] frag_wd = '0;
  logic img_we = 0;
  logic [APU_FRAG_ADDR_BITS-1:0] img_wa = '0;
  logic [31:0] img_wd = '0;
  logic [255:0] shot;
  logic wr_valid, wr_ready = 0, wr_rsp_ready;
  logic rsp_v = 0, rsp_ok = 0;
  logic [63:0] rsp_addr = '0;
  logic [31:0] rsp_len = '0;
  apu_vgpu_res_t slot0, slot1;
  apu_vgpu_back_t back0, back1;
  apu_vgpu_img_t surf, frag_img;
  apu_vgpu_cpl_t cpl, off_cpl, snap;
  int errors = 0, checks = 0, cycles = 0, cases = 0, writes = 0;

  logic v_v = 0, v_rdy, v_cplv, v_cplr = 0;
  logic [319:0] vcmd;
  apu_vgpu_cpl_t vcpl, vsnap;
  logic b_v = 0, b_rdy, b_cplv, b_cplr = 0;
  logic [383:0] bcmd;
  apu_vgpu_cpl_t bcpl, bsnap;

  logic f_v = 0, f_rdy, f_cplv, f_cplr = 0;
  apu_frag_req_t freq;
  apu_frag_cpl_t fcpl, fsnap;
  logic [15:0] peek_x, peek_y, peek_stride;
  logic [31:0] peek_px;

  localparam logic [63:0] Fence = 64'h1122_3344_5566_7788;
  localparam logic [31:0] Solid = 32'hFF00_00FF;
  localparam logic [31:0] Texel = 32'hFF80_FF40;
  localparam logic [31:0] Gray = 32'hFF80_8080;
  localparam logic [63:0] Addr7 = 64'h0000_0000_8800_5000;
  localparam logic [31:0] Len7 = 32'd32;
  localparam logic [63:0] Addr8 = 64'h0000_0000_8800_2000;
  localparam logic [31:0] Len8 = 32'd4;
  localparam logic [15:0] STRIDE = 16'd16;
  localparam logic [15:0] W = 16'd4;
  localparam logic [15:0] H = 16'd2;

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
  g6lc_apu_frag #(.Enable(1'b1)) i_frag (
    .clk_i(clk), .rst_ni, .img_i(frag_img),
    .img_we_i(frag_we), .img_wa_i(frag_wa), .img_wd_i(frag_wd),
    .req_valid_i(f_v), .req_ready_o(f_rdy), .req_i(freq),
    .cpl_valid_o(f_cplv), .cpl_ready_i(f_cplr), .cpl_o(fcpl),
    .peek_x_i(peek_x), .peek_y_i(peek_y), .peek_stride_i(peek_stride),
    .peek_px_o(peek_px)
  );
  g6lc_apu_vgpu_rdb #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .back0_i(back0), .back1_i(back1), .surf_i(surf),
    .img_we_i(img_we), .img_wa_i(img_wa), .img_wd_i(img_wd),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .cmd_i(rcmd),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .wrote_o(wrote),
    .wr_valid_o(wr_valid), .wr_ready_i(wr_ready),
    .wr_addr_o(wr_addr), .wr_len_o(wr_len), .wr_data_o(wr_data),
    .wr_rsp_valid_i(rsp_v), .wr_rsp_ready_o(wr_rsp_ready), .wr_rsp_ok_i(rsp_ok),
    .wr_rsp_addr_i(rsp_addr), .wr_rsp_len_i(rsp_len)
  );
  g6lc_apu_vgpu_rdb_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .back0_i(back0), .back1_i(back1), .surf_i(surf),
    .img_we_i(img_we), .img_wa_i(img_wa), .img_wd_i(img_wd),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .cmd_i(rcmd),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .wrote_o(off_wrote),
    .wr_valid_o(off_wr_v), .wr_ready_i(wr_ready),
    .wr_addr_o(off_addr), .wr_len_o(off_len), .wr_data_o(off_data),
    .wr_rsp_valid_i(rsp_v), .wr_rsp_ready_o(off_rsp_rdy), .wr_rsp_ok_i(rsp_ok),
    .wr_rsp_addr_i(rsp_addr), .wr_rsp_len_i(rsp_len)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && wr_valid && wr_ready) writes++;
  end
  initial begin #2000000; $fatal(1, "vgpu rdb timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_wrote !== 0 ||
        off_wr_v !== 0 || off_rsp_rdy !== 0 || off_addr !== 0 ||
        off_len !== 0 || off_data !== 0)
      $fatal(1, "disabled vgpu rdb active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [575:0] rdb_cmd(
    input logic [31:0] cmd_type,
    input logic [31:0] flags,
    input logic [63:0] fence,
    input logic [31:0] hdr_pad,
    input logic [31:0] x,
    input logic [31:0] y,
    input logic [31:0] z,
    input logic [31:0] w,
    input logic [31:0] h,
    input logic [31:0] d,
    input logic [63:0] offset,
    input logic [31:0] rid,
    input logic [31:0] level,
    input logic [31:0] stride,
    input logic [31:0] layer_stride
  );
    rdb_cmd = {layer_stride, stride, level, rid, offset, d, h, w, z, y, x,
               hdr_pad, 32'd3, fence, flags, cmd_type};
  endfunction

  function automatic logic [575:0] legal(
    input logic [31:0] rid,
    input logic [31:0] w,
    input logic [31:0] h,
    input logic [31:0] stride,
    input logic [31:0] layer_stride
  );
    legal = rdb_cmd(VGPU_CMD_TRANSFER_FROM_HOST_3D, VGPU_FLAG_FENCE, Fence,
                    32'h0, 32'h0, 32'h0, 32'h0, w, h, 32'd1, 64'h0, rid,
                    32'h0, stride, layer_stride);
  endfunction

  function automatic logic [383:0] attach_cmd(
    input logic [31:0] rid,
    input logic [63:0] addr,
    input logic [31:0] len
  );
    attach_cmd = {32'h0, len, addr, 32'd1, rid, 32'h0, 32'd3, Fence,
                  VGPU_FLAG_FENCE, VGPU_CMD_RESOURCE_ATTACH_BACKING};
  endfunction

  function automatic apu_frag_req_t mk(
    input apu_cover_frag_t frag,
    input logic [31:0] c0, c1, c2,
    input logic signed [15:0] x, y
  );
    mk = '0;
    mk.frag = frag;
    mk.c0 = c0;
    mk.c1 = c1;
    mk.c2 = c2;
    mk.x = x;
    mk.y = y;
    mk.stride = STRIDE;
    mk.width = W;
    mk.height = H;
  endfunction

  task automatic shade(
    input apu_frag_req_t r,
    input apu_frag_status_e st,
    input logic [31:0] col,
    input string name
  );
    @(negedge clk);
    while (!f_rdy) @(negedge clk);
    cases++;
    freq = r;
    f_v = 1;
    @(posedge clk); @(negedge clk); f_v = 0;
    while (!f_cplv) @(negedge clk);
    fsnap = fcpl;
    check($sformatf("%s status", name), fcpl.status == st);
    check($sformatf("%s color", name), fcpl.color == col);
    @(negedge clk);
    check($sformatf("%s held", name), f_cplv && !f_rdy && fcpl == fsnap);
    f_cplr = 1;
    @(posedge clk); @(negedge clk); f_cplr = 0;
    while (f_cplv) @(negedge clk);
  endtask

  task automatic take_surf;
    shot = '0;
    surf = '0;
    surf.valid = 1'b1;
    surf.resource_id = 32'd7;
    surf.length = Len7;
    for (int y = 0; y < 2; y++) begin
      for (int x = 0; x < 4; x++) begin
        @(negedge clk);
        peek_x = x[15:0];
        peek_y = y[15:0];
        peek_stride = STRIDE;
        @(posedge clk);
        shot[((y * 16) + (x * 4)) * 8 +: 32] = peek_px;
      end
    end
  endtask

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] beat_of(
    input logic [APU_VGPU_IMG_BYTES*8-1:0] img,
    input logic [31:0] off,
    input logic [31:0] total
  );
    logic [31:0] n;
    logic [31:0] bit_i;
    beat_of = '0;
    n = total - off;
    if (n > APU_VGPU_BEAT_BYTES)
      n = APU_VGPU_BEAT_BYTES;
    for (int k = 0; k < APU_VGPU_BEAT_BYTES; k++) begin
      if (32'(k) < n) begin
        bit_i = (off + 32'(k)) * 32'd8;
        beat_of[k*8 +: 8] = img[bit_i +: 8];
      end
    end
  endfunction

  task automatic load_img(
    input logic [APU_VGPU_IMG_BYTES*8-1:0] img,
    input logic [31:0] nbytes
  );
    int nwords;
    nwords = int'(nbytes >> 2);
    for (int i = 0; i < nwords; i++) begin
      @(negedge clk);
      img_wa = APU_FRAG_ADDR_BITS'(i * 4);
      img_wd = img[i*32 +: 32];
      img_we = 1'b1;
      @(posedge clk);
    end
    @(negedge clk);
    img_we = 1'b0;
  endtask

  task automatic create_res(
    input logic [31:0] rid,
    input logic [31:0] w,
    input logic [31:0] h,
    input string name
  );
    @(negedge clk);
    while (!v_rdy) @(negedge clk);
    vcmd = {h, w, VGPU_FORMAT_R8G8B8A8_UNORM, rid, 32'h0, 32'd3,
            Fence, VGPU_FLAG_FENCE, VGPU_CMD_RESOURCE_CREATE_2D};
    v_v = 1;
    @(posedge clk); @(negedge clk); v_v = 0;
    while (!v_cplv) @(negedge clk);
    vsnap = vcpl;
    @(negedge clk);
    check($sformatf("%s held", name), v_cplv && !v_rdy && vcpl == vsnap);
    check($sformatf("%s ok", name), vsnap.resp_type == VGPU_RESP_OK_NODATA &&
          vsnap.resource_id == rid && vsnap.width == w && vsnap.height == h);
    v_cplr = 1;
    @(posedge clk); @(negedge clk); v_cplr = 0;
    while (v_cplv) @(negedge clk);
  endtask

  task automatic attach_res(
    input logic [31:0] rid,
    input logic [63:0] addr,
    input logic [31:0] len,
    input string name
  );
    @(negedge clk);
    while (!b_rdy) @(negedge clk);
    bcmd = attach_cmd(rid, addr, len);
    b_v = 1;
    @(posedge clk); @(negedge clk); b_v = 0;
    while (!b_cplv) @(negedge clk);
    bsnap = bcpl;
    @(negedge clk);
    check($sformatf("%s held", name), b_cplv && !b_rdy && bcpl == bsnap);
    check($sformatf("%s ok", name), bsnap.resp_type == VGPU_RESP_OK_NODATA);
    b_cplr = 1;
    @(posedge clk); @(negedge clk); b_cplr = 0;
    while (b_cplv) @(negedge clk);
  endtask

  task automatic rdb_step(
    input logic [575:0] word,
    input logic [31:0] resp,
    input logic do_write,
    input logic [63:0] exp_addr,
    input logic [31:0] exp_len,
    input logic [APU_VGPU_IMG_BYTES*8-1:0] exp_data,
    input logic rsp_ok_v,
    input logic [63:0] rsp_addr_v,
    input logic [31:0] rsp_len_v,
    input logic [1:0] exp_wrote,
    input string name
  );
    apu_vgpu_cpl_t seen;
    int was_writes, nbeats;
    logic bad_rsp;
    logic [31:0] beat_n;
    logic [63:0] beat_addr;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] exp_beat;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was_writes = writes;
    nbeats = 0;
    if (do_write)
      load_img(exp_data, exp_len);
    rcmd = word;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    if (do_write) begin
      bad_rsp = !rsp_ok_v || rsp_addr_v != exp_addr || rsp_len_v != exp_len;
      nbeats = bad_rsp ? 1 : int'((exp_len + 32'd31) >> 5);
      for (int b = 0; b < nbeats; b++) begin
        while (!wr_valid) @(negedge clk);
        beat_n = exp_len - (32'(b) * 32'd32);
        if (beat_n > APU_VGPU_BEAT_BYTES)
          beat_n = APU_VGPU_BEAT_BYTES;
        beat_addr = exp_addr + (64'(b) * 64'd32);
        exp_beat = beat_of(exp_data, 32'(b) * 32'd32, exp_len);
        check($sformatf("%s beat %0d", name, b),
              wr_addr == beat_addr && wr_len == beat_n && wr_data == exp_beat);
        wr_ready = 1;
        @(posedge clk); @(negedge clk); wr_ready = 0;
        if (wr_rsp_ready !== 1'b1) $fatal(1, "%s response not accepted", name);
        if (bad_rsp) begin
          rsp_ok = rsp_ok_v;
          rsp_addr = rsp_addr_v;
          rsp_len = rsp_len_v;
        end else begin
          rsp_ok = 1'b1;
          rsp_addr = beat_addr;
          rsp_len = beat_n;
        end
        rsp_v = 1;
        @(posedge clk); @(negedge clk); rsp_v = 0;
      end
    end
    while (!cpl_v) @(negedge clk);
    if (!do_write)
      check($sformatf("%s no write", name), wr_valid == 1'b0 && writes == was_writes);
    seen = cpl;
    snap = cpl;
    check($sformatf("%s resp", name), cpl.resp_type == resp);
    check($sformatf("%s fence", name), cpl.flags == VGPU_FLAG_FENCE &&
          cpl.fence_id == Fence && cpl.ctx_id == 32'd3);
    check($sformatf("%s quiet ids", name), cpl.resource_id == 32'h0 &&
          cpl.format == 32'h0 && cpl.width == 32'h0 && cpl.height == 32'h0);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (do_write)
      check($sformatf("%s beats", name), writes == was_writes + nbeats);
    check($sformatf("%s wrote", name), wrote == exp_wrote);
  endtask

  initial begin
    apu_cfg_t cfg;
    apu_cover_frag_t painted;
    apu_frag_req_t tr;
    logic [APU_VGPU_IMG_BYTES*8-1:0] mem7;
    rcmd = '0;
    vcmd = '0;
    bcmd = '0;
    freq = '0;
    surf = '0;
    frag_img = '0;
    peek_x = '0;
    peek_y = '0;
    peek_stride = STRIDE;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 &&
          wrote == 2'b00 && wr_valid == 1'b0);
    check("profiles keep rdb off",
          !ApuOff.RdbEn && !ApuP1Transport.RdbEn && !ApuHarness.RdbEn &&
          !ApuSchedBoth.RdbEn && !ApuBadVirglGrant.RdbEn);
    cfg = ApuP1Transport;
    cfg.RdbEn = 1'b1;
    check("rdb does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.RdbEn = 1'b1;
    check("rdb does not legalize virgl", !apu_cfg_legal(cfg));

    painted = '0;
    painted.covered = 1'b1;
    painted.area = 48'sd16;
    painted.w0 = 48'sd16;
    shade(mk(painted, Solid, Solid, Solid, 16'sd0, 16'sd0),
          APU_FRAG_OK, Solid, "solid");
    tr = '0;
    tr.texel_write = 1'b1;
    tr.texel = Texel;
    shade(tr, APU_FRAG_OK, Texel, "texel store");
    tr = mk(painted, 32'h0, 32'h0, 32'h0, 16'sd2, 16'sd0);
    tr.use_texel = 1'b1;
    shade(tr, APU_FRAG_OK, Texel, "texel pixel");
    tr = mk(painted, 32'h0, 32'h0, 32'h0, 16'sd1, 16'sd0);
    tr.use_prog = 1'b1;
    tr.prog0 = APU_EX_LDC_R4_WORD;
    tr.prog1 = APU_EX_F32_HALF;
    shade(tr, APU_FRAG_OK, Gray, "prog half");
    take_surf();
    check("frag 0,0", shot[31:0] == Solid);
    check("frag 1,0", shot[63:32] == Gray);
    check("frag 2,0", shot[95:64] == Texel);
    check("frag rest", shot[255:96] == '0);
    mem7 = shot;

    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_RESOURCE_ID, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "unknown");
    create_res(32'd7, 32'd4, 32'd2, "create 7");
    create_res(32'd8, 32'd1, 32'd1, "create 8");
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "no backing");
    attach_res(32'd7, Addr7, Len7, "attach 7");
    attach_res(32'd8, Addr8, Len8, "attach 8");

    rdb_step(rdb_cmd(VGPU_CMD_SUBMIT_3D, VGPU_FLAG_FENCE, Fence, 32'h0,
                     32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 32'd1, 64'h0, 32'd7,
                     32'h0, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "submit");
    rdb_step(rdb_cmd(VGPU_CMD_TRANSFER_FROM_HOST_3D, VGPU_FLAG_FENCE, Fence,
                     32'h0, 32'd1, 32'h0, 32'h0, 32'd4, 32'd2, 32'd1, 64'h0,
                     32'd7, 32'h0, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad x");
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd8, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad stride");
    rdb_step(rdb_cmd(VGPU_CMD_TRANSFER_FROM_HOST_3D, VGPU_FLAG_FENCE, Fence,
                     32'h0, 32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 32'd2, 64'h0,
                     32'd7, 32'h0, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad depth");
    rdb_step(rdb_cmd(VGPU_CMD_TRANSFER_FROM_HOST_3D, VGPU_FLAG_FENCE, Fence,
                     32'h0, 32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 32'd1, 64'h0,
                     32'd7, 32'd1, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad level");
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'd1),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad layer");
    rdb_step(rdb_cmd(VGPU_CMD_TRANSFER_FROM_HOST_3D, VGPU_FLAG_FENCE, Fence,
                     32'h0, 32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 32'd1, 64'd4,
                     32'd7, 32'h0, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad offset");
    rdb_step(rdb_cmd(VGPU_CMD_TRANSFER_FROM_HOST_3D, 32'h3, Fence, 32'h0,
                     32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 32'd1, 64'h0, 32'd7,
                     32'h0, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad flags");
    rdb_step(rdb_cmd(VGPU_CMD_TRANSFER_FROM_HOST_3D, VGPU_FLAG_FENCE, Fence,
                     32'd1, 32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 32'd1, 64'h0,
                     32'd7, 32'h0, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad pad");
    surf.valid = 1'b0;
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "surf absent");
    surf.valid = 1'b1;
    surf.length = 32'd16;
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "surf short");
    surf.length = Len7;
    surf.resource_id = 32'd99;
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "surf rid");
    surf.resource_id = 32'd7;
    rdb_step(legal(32'd7, 32'd4, 32'd1, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_PARAMETER, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "bad height");

    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_UNSPEC, 1'b1, Addr7, Len7, mem7,
             1'b0, Addr7, Len7, 2'b00, "bus");
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_UNSPEC, 1'b1, Addr7, Len7, mem7,
             1'b1, Addr7 + 64'd8, Len7, 2'b00, "bad rsp addr");
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_UNSPEC, 1'b1, Addr7, Len7, mem7,
             1'b1, Addr7, 32'd16, 2'b00, "bad rsp len");
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_OK_NODATA, 1'b1, Addr7, Len7, mem7,
             1'b1, Addr7, Len7, 2'b01, "readback");
    check("gray byte", mem7[39:32] == 8'h80 && mem7[7:0] == 8'hFF &&
          mem7[71:64] == 8'h40);
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_UNSPEC, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b01, "second");

    begin
      logic [255:0] pad;
      pad = {{7{32'hDEADBEEF}}, 32'hA1B2_C3D4};
      load_img(pad, 32'd32);
    end
    surf = '0;
    surf.valid = 1'b1;
    surf.resource_id = 32'd8;
    surf.length = Len8;
    rdb_step(legal(32'd8, 32'd1, 32'd1, 32'h0, 32'd4),
             VGPU_RESP_OK_NODATA, 1'b1, Addr8, Len8, {224'h0, 32'hA1B2_C3D4},
             1'b1, Addr8, Len8, 2'b11, "readback 8");
    rdb_step(legal(32'd8, 32'd1, 32'd1, 32'h0, 32'd4),
             VGPU_RESP_ERR_UNSPEC, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b11, "second 8");
    check("four by two stays", wrote == 2'b11);
    rdb_step(legal(32'd9, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_RESOURCE_ID, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b11, "unknown 9");

    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    f_v = 0;
    f_cplr = 0;
    v_v = 0;
    v_cplr = 0;
    b_v = 0;
    b_cplr = 0;
    wr_ready = 0;
    rsp_v = 0;
    img_we = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("reset clears wrote", wrote == 2'b00 && wr_valid == 1'b0);
    surf.valid = 1'b1;
    surf.resource_id = 32'd7;
    surf.length = Len7;
    rdb_step(legal(32'd7, 32'd4, 32'd2, 32'd16, 32'h0),
             VGPU_RESP_ERR_INVALID_RESOURCE_ID, 1'b0, 64'h0, 32'h0, '0,
             1'b0, 64'h0, 32'h0, 2'b00, "reset unknown");

    begin
      apu_frag_req_t gr;
      logic [APU_VGPU_IMG_BYTES*8-1:0] grown;
      localparam logic [63:0] AddrG = 64'h0000_0000_8800_6000;
      localparam logic [31:0] LenG = 32'd128;
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
      shade(gr, APU_FRAG_OK, Gray, "grow col");
      gr.use_prog = 1'b0;
      gr.texel_write = 1'b1;
      gr.texel = Texel;
      shade(gr, APU_FRAG_OK, Texel, "grow texel");
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
      peek_x = 16'd4;
      peek_y = 16'd0;
      peek_stride = 16'd32;
      @(posedge clk);
      check("peek grown col", peek_px == Gray);
      grown = '0;
      grown[159:128] = peek_px;
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd2;
      peek_stride = 16'd32;
      @(posedge clk);
      check("peek grown row", peek_px == Texel);
      grown[543:512] = peek_px;
      create_res(32'd7, 32'd8, 32'd4, "create grown");
      attach_res(32'd7, AddrG, LenG, "attach grown");
      surf = '0;
      surf.valid = 1'b1;
      surf.resource_id = 32'd7;
      surf.length = LenG;
      rdb_step(legal(32'd7, 32'd8, 32'd4, 32'd32, 32'h0),
               VGPU_RESP_OK_NODATA, 1'b1, AddrG, LenG, grown,
               1'b1, AddrG, LenG, 2'b01, "grown readback");
      check("grown gray", grown[159:128] == Gray && grown[543:512] == Texel);
      rdb_step(legal(32'd7, 32'd8, 32'd4, 32'd32, 32'h0),
               VGPU_RESP_ERR_UNSPEC, 1'b0, 64'h0, 32'h0, '0,
               1'b0, 64'h0, 32'h0, 2'b01, "grown second");
    end

    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    f_v = 0;
    f_cplr = 0;
    v_v = 0;
    v_cplr = 0;
    b_v = 0;
    b_cplr = 0;
    wr_ready = 0;
    rsp_v = 0;
    img_we = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    begin
      apu_frag_req_t wr;
      logic [APU_VGPU_IMG_BYTES*8-1:0] wide;
      localparam logic [63:0] AddrW = 64'h0000_0000_8800_7000;
      localparam logic [31:0] LenW = 32'd512;
      wr = '0;
      wr.frag.covered = 1'b1;
      wr.use_prog = 1'b1;
      wr.prog0 = APU_EX_LDC_R4_WORD;
      wr.prog1 = APU_EX_F32_HALF;
      wr.x = 16'sd8;
      wr.y = 16'sd0;
      wr.stride = 16'd64;
      wr.width = 16'd16;
      wr.height = 16'd8;
      shade(wr, APU_FRAG_OK, Gray, "wide col");
      wr.use_prog = 1'b0;
      wr.texel_write = 1'b1;
      wr.texel = Texel;
      shade(wr, APU_FRAG_OK, Texel, "wide texel");
      wr = '0;
      wr.frag.covered = 1'b1;
      wr.use_texel = 1'b1;
      wr.x = 16'sd0;
      wr.y = 16'sd4;
      wr.stride = 16'd64;
      wr.width = 16'd16;
      wr.height = 16'd8;
      shade(wr, APU_FRAG_OK, Texel, "wide row");
      @(negedge clk);
      peek_x = 16'd8;
      peek_y = 16'd0;
      peek_stride = 16'd64;
      @(posedge clk);
      check("peek wide col", peek_px == Gray);
      wide = '0;
      wide[287:256] = peek_px;
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd4;
      peek_stride = 16'd64;
      @(posedge clk);
      check("peek wide row", peek_px == Texel);
      wide[2079:2048] = peek_px;
      create_res(32'd7, 32'd16, 32'd8, "create wide");
      attach_res(32'd7, AddrW, LenW, "attach wide");
      surf = '0;
      surf.valid = 1'b1;
      surf.resource_id = 32'd7;
      surf.length = LenW;
      rdb_step(legal(32'd7, 32'd16, 32'd8, 32'd64, 32'h0),
               VGPU_RESP_OK_NODATA, 1'b1, AddrW, LenW, wide,
               1'b1, AddrW, LenW, 2'b01, "wide readback");
      check("wide pixels", wide[287:256] == Gray && wide[2079:2048] == Texel);
      rdb_step(legal(32'd7, 32'd16, 32'd8, 32'd64, 32'h0),
               VGPU_RESP_ERR_UNSPEC, 1'b0, 64'h0, 32'h0, '0,
               1'b0, 64'h0, 32'h0, 2'b01, "wide second");
    end

    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    f_v = 0;
    f_cplr = 0;
    v_v = 0;
    v_cplr = 0;
    b_v = 0;
    b_cplr = 0;
    wr_ready = 0;
    rsp_v = 0;
    img_we = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    begin
      apu_frag_req_t cr;
      logic [APU_VGPU_IMG_BYTES*8-1:0] ceil_px;
      localparam logic [63:0] AddrC = 64'h0000_0000_8800_8000;
      localparam logic [31:0] LenC = 32'd2048;
      cr = '0;
      cr.frag.covered = 1'b1;
      cr.use_prog = 1'b1;
      cr.prog0 = APU_EX_LDC_R4_WORD;
      cr.prog1 = APU_EX_F32_HALF;
      cr.x = 16'sd16;
      cr.y = 16'sd0;
      cr.stride = 16'd128;
      cr.width = 16'd32;
      cr.height = 16'd16;
      shade(cr, APU_FRAG_OK, Gray, "ceiling col");
      cr.use_prog = 1'b0;
      cr.texel_write = 1'b1;
      cr.texel = Texel;
      shade(cr, APU_FRAG_OK, Texel, "ceiling texel");
      cr = '0;
      cr.frag.covered = 1'b1;
      cr.use_texel = 1'b1;
      cr.x = 16'sd0;
      cr.y = 16'sd8;
      cr.stride = 16'd128;
      cr.width = 16'd32;
      cr.height = 16'd16;
      shade(cr, APU_FRAG_OK, Texel, "ceiling row");
      @(negedge clk);
      peek_x = 16'd16;
      peek_y = 16'd0;
      peek_stride = 16'd128;
      @(posedge clk);
      check("peek ceiling col", peek_px == Gray);
      ceil_px = '0;
      ceil_px[543:512] = peek_px;
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd8;
      peek_stride = 16'd128;
      @(posedge clk);
      check("peek ceiling row", peek_px == Texel);
      ceil_px[8223:8192] = peek_px;
      create_res(32'd7, 32'd32, 32'd16, "create ceiling");
      attach_res(32'd7, AddrC, LenC, "attach ceiling");
      surf = '0;
      surf.valid = 1'b1;
      surf.resource_id = 32'd7;
      surf.length = LenC;
      rdb_step(legal(32'd7, 32'd32, 32'd16, 32'd128, 32'h0),
               VGPU_RESP_OK_NODATA, 1'b1, AddrC, LenC, ceil_px,
               1'b1, AddrC, LenC, 2'b01, "ceiling readback");
      check("ceiling pixels", ceil_px[543:512] == Gray && ceil_px[8223:8192] == Texel);
      rdb_step(legal(32'd7, 32'd32, 32'd16, 32'd128, 32'h0),
               VGPU_RESP_ERR_UNSPEC, 1'b0, 64'h0, 32'h0, '0,
               1'b0, 64'h0, 32'h0, 2'b01, "ceiling second");
    end

    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    f_v = 0;
    f_cplr = 0;
    v_v = 0;
    v_cplr = 0;
    b_v = 0;
    b_cplr = 0;
    wr_ready = 0;
    rsp_v = 0;
    img_we = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    begin
      apu_frag_req_t sr;
      logic [APU_VGPU_IMG_BYTES*8-1:0] scene_px;
      localparam logic [63:0] AddrS = 64'h0000_0000_8800_9000;
      localparam logic [31:0] LenS = 32'd8192;
      sr = '0;
      sr.frag.covered = 1'b1;
      sr.use_prog = 1'b1;
      sr.prog0 = APU_EX_LDC_R4_WORD;
      sr.prog1 = APU_EX_F32_HALF;
      sr.x = 16'sd32;
      sr.y = 16'sd0;
      sr.stride = 16'd256;
      sr.width = 16'd64;
      sr.height = 16'd32;
      shade(sr, APU_FRAG_OK, Gray, "scene col");
      sr.use_prog = 1'b0;
      sr.texel_write = 1'b1;
      sr.texel = Texel;
      shade(sr, APU_FRAG_OK, Texel, "scene texel");
      sr = '0;
      sr.frag.covered = 1'b1;
      sr.use_texel = 1'b1;
      sr.x = 16'sd0;
      sr.y = 16'sd16;
      sr.stride = 16'd256;
      sr.width = 16'd64;
      sr.height = 16'd32;
      shade(sr, APU_FRAG_OK, Texel, "scene row");
      @(negedge clk);
      peek_x = 16'd32;
      peek_y = 16'd0;
      peek_stride = 16'd256;
      @(posedge clk);
      check("peek scene col", peek_px == Gray);
      scene_px = '0;
      scene_px[1055:1024] = peek_px;
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd16;
      peek_stride = 16'd256;
      @(posedge clk);
      check("peek scene row", peek_px == Texel);
      scene_px[32799:32768] = peek_px;
      create_res(32'd7, 32'd64, 32'd32, "create scene");
      attach_res(32'd7, AddrS, LenS, "attach scene");
      surf = '0;
      surf.valid = 1'b1;
      surf.resource_id = 32'd7;
      surf.length = LenS;
      rdb_step(legal(32'd7, 32'd64, 32'd32, 32'd256, 32'h0),
               VGPU_RESP_OK_NODATA, 1'b1, AddrS, LenS, scene_px,
               1'b1, AddrS, LenS, 2'b01, "scene readback");
      check("scene pixels", scene_px[1055:1024] == Gray &&
            scene_px[32799:32768] == Texel);
      rdb_step(legal(32'd7, 32'd64, 32'd32, 32'd256, 32'h0),
               VGPU_RESP_ERR_UNSPEC, 1'b0, 64'h0, 32'h0, '0,
               1'b0, 64'h0, 32'h0, 2'b01, "scene second");
    end

    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    f_v = 0;
    f_cplr = 0;
    v_v = 0;
    v_cplr = 0;
    b_v = 0;
    b_cplr = 0;
    wr_ready = 0;
    rsp_v = 0;
    img_we = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    begin
      apu_frag_req_t fr;
      logic [APU_VGPU_IMG_BYTES*8-1:0] full_px;
      localparam logic [63:0] AddrF = 64'h0000_0000_8800_C000;
      localparam logic [31:0] LenF = 32'd16384;
      fr = '0;
      fr.frag.covered = 1'b1;
      fr.use_prog = 1'b1;
      fr.prog0 = APU_EX_LDC_R4_WORD;
      fr.prog1 = APU_EX_F32_HALF;
      fr.x = 16'sd0;
      fr.y = 16'sd32;
      fr.stride = 16'd256;
      fr.width = 16'd64;
      fr.height = 16'd64;
      shade(fr, APU_FRAG_OK, Gray, "full row");
      fr.prog1 = APU_EX_F32_ONE;
      fr.x = 16'sd63;
      fr.y = 16'sd63;
      shade(fr, APU_FRAG_OK, 32'hFFFF_FFFF, "full corner");
      @(negedge clk);
      peek_x = 16'd0;
      peek_y = 16'd32;
      peek_stride = 16'd256;
      @(posedge clk);
      check("peek full row", peek_px == Gray);
      full_px = '0;
      full_px[65567:65536] = peek_px;
      @(negedge clk);
      peek_x = 16'd63;
      peek_y = 16'd63;
      peek_stride = 16'd256;
      @(posedge clk);
      check("peek full corner", peek_px == 32'hFFFF_FFFF);
      full_px[131071:131040] = peek_px;
      create_res(32'd7, 32'd64, 32'd64, "create full");
      attach_res(32'd7, AddrF, LenF, "attach full");
      surf = '0;
      surf.valid = 1'b1;
      surf.resource_id = 32'd7;
      surf.length = LenF;
      rdb_step(legal(32'd7, 32'd64, 32'd64, 32'd256, 32'h0),
               VGPU_RESP_OK_NODATA, 1'b1, AddrF, LenF, full_px,
               1'b1, AddrF, LenF, 2'b01, "full readback");
      check("full pixels", full_px[65567:65536] == Gray &&
            full_px[131071:131040] == 32'hFFFF_FFFF);
      rdb_step(legal(32'd7, 32'd64, 32'd64, 32'd256, 32'h0),
               VGPU_RESP_ERR_UNSPEC, 1'b0, 64'h0, 32'h0, '0,
               1'b0, 64'h0, 32'h0, 2'b01, "full second");
    end

    if (errors != 0) $fatal(1, "APU rdb errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rdb cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
