// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ctl;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_buf_t bufi;
  logic [31:0] mem [0:255];
  logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr, ctx_peek, c3d_peek, att_peek;
  logic [31:0] peek_word;
  logic use_ctx = 0, use_c3d = 0, use_att = 0;

  logic ctx_req = 0, ctx_rdy, ctx_cpl_v, ctx_cpl_r = 0;
  apu_vgpu_ctx_cpl_t ctx_cpl;
  apu_vgpu_ctx_t ctx;
  logic c3d_req = 0, c3d_rdy, c3d_cpl_v, c3d_cpl_r = 0;
  apu_vgpu_c3d_cpl_t c3d_cpl;
  apu_vgpu_c3d_t c3d;
  logic att_req = 0, att_rdy, att_cpl_v, att_cpl_r = 0;
  apu_vgpu_att_cpl_t att_cpl;
  apu_vgpu_att_t att;
  logic rsp_req = 0, rsp_rdy, rsp_cpl_v, rsp_cpl_r = 0;
  apu_vgpu_rsp_cpl_t rsp_cpl, off_cpl;
  apu_vgpu_rsp_t rsp, off_rsp;
  apu_vgpu_sub_t sub;
  apu_vgpu_drw_t drw;
  logic off_rdy, off_v, off_wr, off_wr_rdy;
  logic wr_v, wr_rdy = 0, wr_rsp_rdy, wr_rsp_v = 0, wr_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = '0, off_addr;
  logic [191:0] wr_data, off_data;
  logic [31:0] wr_len, off_len;
  int errors = 0, checks = 0, cycles = 0, cases = 0, writes = 0;

  localparam logic [191:0] RspBits = {32'h0, APU_VGPU_CTX_ID, APU_VGPU_SCENE_FENCE,
                                      VGPU_FLAG_FENCE, VGPU_RESP_OK_NODATA};

  assign peek_addr = use_att ? att_peek : use_c3d ? c3d_peek : ctx_peek;
  assign peek_word = mem[peek_addr[9:2]];

  g6lc_apu_vgpu_ctx #(.Enable(1'b1)) i_ctx (
    .clk_i(clk), .rst_ni, .buf_i(bufi),
    .req_valid_i(ctx_req), .req_ready_o(ctx_rdy),
    .cpl_valid_o(ctx_cpl_v), .cpl_ready_i(ctx_cpl_r), .cpl_o(ctx_cpl), .ctx_o(ctx),
    .peek_addr_o(ctx_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_c3d #(.Enable(1'b1)) i_c3d (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .ctx_i(ctx),
    .req_valid_i(c3d_req), .req_ready_o(c3d_rdy),
    .cpl_valid_o(c3d_cpl_v), .cpl_ready_i(c3d_cpl_r), .cpl_o(c3d_cpl), .c3d_o(c3d),
    .peek_addr_o(c3d_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_att #(.Enable(1'b1)) i_att (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .c3d_i(c3d),
    .req_valid_i(att_req), .req_ready_o(att_rdy),
    .cpl_valid_o(att_cpl_v), .cpl_ready_i(att_cpl_r), .cpl_o(att_cpl), .att_o(att),
    .peek_addr_o(att_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_rsp #(.Enable(1'b1)) i_rsp (
    .clk_i(clk), .rst_ni, .att_i(att), .sub_i(sub), .drw_i(drw),
    .req_valid_i(rsp_req), .req_ready_o(rsp_rdy),
    .cpl_valid_o(rsp_cpl_v), .cpl_ready_i(rsp_cpl_r), .cpl_o(rsp_cpl), .rsp_o(rsp),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_data_o(wr_data),
    .wr_len_o(wr_len), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rsp_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .att_i(att), .sub_i(sub), .drw_i(drw),
    .req_valid_i(rsp_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rsp_cpl_r), .cpl_o(off_cpl), .rsp_o(off_rsp),
    .wr_valid_o(off_wr), .wr_ready_i(wr_rdy), .wr_addr_o(off_addr), .wr_data_o(off_data),
    .wr_len_o(off_len), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(off_wr_rdy),
    .wr_rsp_ok_i(wr_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && wr_v && wr_rdy) writes++;
  end
  initial begin #1000000; $fatal(1, "APU vgpu ctl timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  function automatic logic [31:0] good_word(input int unsigned w);
    int unsigned rel;
    good_word = 32'h0;
    if (w < 24) begin
      if (w == 0) good_word = VGPU_CMD_CTX_CREATE;
      else if (w == 4) good_word = APU_VGPU_CTX_ID;
      else if (w == 6) good_word = APU_VGPU_CTX_NLEN;
      else if (w == 8) good_word = APU_VGPU_CTX_NAME0;
    end else if (w < 42) begin
      rel = w - 24;
      if (rel == 0) good_word = VGPU_CMD_RESOURCE_CREATE_3D;
      else if (rel == 4) good_word = APU_VGPU_CTX_ID;
      else if (rel == 6) good_word = APU_VGPU_RES_RT;
      else if (rel == 7) good_word = APU_VGPU_PIPE_TEX_2D;
      else if (rel == 8) good_word = APU_VIRGL_FMT_B8G8R8X8;
      else if (rel == 9) good_word = APU_VGPU_BIND_RT;
      else if (rel == 10) good_word = APU_VGPU_RT_W;
      else if (rel == 11) good_word = APU_VGPU_RT_H;
      else if (rel == 12 || rel == 13) good_word = 32'd1;
      else if (rel == 16) good_word = APU_VGPU_Y0_TOP;
    end else if (w < 60) begin
      rel = w - 42;
      if (rel == 0) good_word = VGPU_CMD_RESOURCE_CREATE_3D;
      else if (rel == 4) good_word = APU_VGPU_CTX_ID;
      else if (rel == 6) good_word = APU_VGPU_RES_VBO;
      else if (rel == 9) good_word = APU_VGPU_BIND_VBO;
      else if (rel == 10) good_word = APU_VIRGL_VBO_BYTES;
      else if (rel == 11 || rel == 12 || rel == 13) good_word = 32'd1;
    end else if (w < 68) begin
      rel = w - 60;
      if (rel == 0) good_word = VGPU_CMD_CTX_ATTACH_RESOURCE;
      else if (rel == 4) good_word = APU_VGPU_CTX_ID;
      else if (rel == 6) good_word = APU_VGPU_RES_RT;
    end else if (w < 76) begin
      rel = w - 68;
      if (rel == 0) good_word = VGPU_CMD_CTX_ATTACH_RESOURCE;
      else if (rel == 4) good_word = APU_VGPU_CTX_ID;
      else if (rel == 6) good_word = APU_VGPU_RES_VBO;
    end else if (w < 84) begin
      rel = w - 76;
      if (rel == 0) good_word = VGPU_CMD_CTX_ATTACH_RESOURCE;
      else if (rel == 4) good_word = APU_VGPU_CTX_ID;
      else if (rel == 6) good_word = APU_VGPU_RES_SCAN;
    end
  endfunction

  task automatic load_good;
    for (int i = 0; i < 84; i++) mem[i] = good_word(i);
  endtask

  task automatic set_buf(input logic valid, input logic [31:0] size);
    bufi = '0;
    bufi.valid = valid;
    bufi.ctx_id = APU_VGPU_CTX_ID;
    bufi.size = size;
    bufi.buf_addr = 64'h1;
  endtask

  task automatic scene_sub;
    sub = '0;
    sub.valid = 1'b1;
    sub.ctx_id = APU_VGPU_CTX_ID;
    sub.size = APU_VGPU_SCENE_BYTES;
    sub.buf_addr = APU_VGPU_EXEC_ADDR;
    sub.rsp_addr = APU_VGPU_RSP_ADDR;
  endtask

  task automatic scene_drw;
    drw = '0;
    drw.valid = 1'b1;
    drw.count = APU_VIRGL_VERT_COUNT;
    drw.prim = APU_VIRGL_PRIM_STRIP;
    drw.next = APU_VGPU_SCENE_BYTES;
  endtask

  task automatic ctx_step(input apu_vgpu_ctx_status_e st, input string name);
    @(negedge clk);
    while (!ctx_rdy) @(negedge clk);
    cases++;
    use_ctx = 1'b1;
    use_c3d = 1'b0;
    use_att = 1'b0;
    ctx_req = 1;
    @(posedge clk); @(negedge clk); ctx_req = 0;
    while (!ctx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ctx_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), ctx_cpl_v);
    ctx_cpl_r = 1;
    @(posedge clk); @(negedge clk); ctx_cpl_r = 0;
    while (ctx_cpl_v) @(negedge clk);
    use_ctx = 1'b0;
  endtask

  task automatic c3d_step(input apu_vgpu_c3d_status_e st, input string name);
    @(negedge clk);
    while (!c3d_rdy) @(negedge clk);
    cases++;
    use_c3d = 1'b1;
    use_ctx = 1'b0;
    use_att = 1'b0;
    c3d_req = 1;
    @(posedge clk); @(negedge clk); c3d_req = 0;
    while (!c3d_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), c3d_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), c3d_cpl_v);
    c3d_cpl_r = 1;
    @(posedge clk); @(negedge clk); c3d_cpl_r = 0;
    while (c3d_cpl_v) @(negedge clk);
    use_c3d = 1'b0;
  endtask

  task automatic att_step(input apu_vgpu_att_status_e st, input string name);
    @(negedge clk);
    while (!att_rdy) @(negedge clk);
    cases++;
    use_att = 1'b1;
    use_ctx = 1'b0;
    use_c3d = 1'b0;
    att_req = 1;
    @(posedge clk); @(negedge clk); att_req = 0;
    while (!att_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), att_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), att_cpl_v);
    att_cpl_r = 1;
    @(posedge clk); @(negedge clk); att_cpl_r = 0;
    while (att_cpl_v) @(negedge clk);
    use_att = 1'b0;
  endtask

  task automatic rsp_step(
    input apu_vgpu_rsp_status_e st,
    input logic do_write,
    input logic bus_bad,
    input string name
  );
    @(negedge clk);
    while (!rsp_rdy) @(negedge clk);
    cases++;
    rsp_req = 1;
    @(posedge clk); @(negedge clk); rsp_req = 0;
    if (do_write) begin
      while (!wr_v) @(negedge clk);
      check($sformatf("%s addr", name), wr_addr == APU_VGPU_RSP_ADDR && wr_len == VGPU_RESP_HDR_BYTES);
      check($sformatf("%s bytes", name), wr_data == RspBits);
      check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_wr == 0);
      wr_rdy = 1;
      @(posedge clk); @(negedge clk); wr_rdy = 0;
      wr_ok = !bus_bad;
      wr_rsp_addr = APU_VGPU_RSP_ADDR;
      wr_rsp_v = 1;
      @(posedge clk); @(negedge clk); wr_rsp_v = 0;
    end
    while (!rsp_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rsp_cpl.status == st);
    if (!do_write)
      check($sformatf("%s no store", name), wr_v == 1'b0);
    @(negedge clk);
    check($sformatf("%s held", name), rsp_cpl_v);
    rsp_cpl_r = 1;
    @(posedge clk); @(negedge clk); rsp_cpl_r = 0;
    while (rsp_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    ctx_req = 0;
    c3d_req = 0;
    att_req = 0;
    rsp_req = 0;
    ctx_cpl_r = 0;
    c3d_cpl_r = 0;
    att_cpl_r = 0;
    rsp_cpl_r = 0;
    wr_rdy = 0;
    wr_rsp_v = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    bufi = '0;
    sub = '0;
    drw = '0;
    for (int i = 0; i < 256; i++) mem[i] = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && off_wr == 0 && rsp == '0);
    check("profiles keep ctl off",
          !ApuOff.CtxEn && !ApuOff.C3dEn && !ApuOff.AttEn && !ApuOff.RspEn &&
          !ApuP1Transport.CtxEn && !ApuP1Transport.C3dEn && !ApuP1Transport.AttEn &&
          !ApuP1Transport.RspEn &&
          !ApuHarness.CtxEn && !ApuHarness.C3dEn && !ApuHarness.AttEn && !ApuHarness.RspEn &&
          !ApuSchedBoth.CtxEn && !ApuSchedBoth.C3dEn && !ApuSchedBoth.AttEn &&
          !ApuSchedBoth.RspEn &&
          !ApuBadVirglGrant.CtxEn && !ApuBadVirglGrant.C3dEn &&
          !ApuBadVirglGrant.AttEn && !ApuBadVirglGrant.RspEn);
    cfg = ApuP1Transport;
    cfg.CtxEn = 1'b1;
    cfg.C3dEn = 1'b1;
    cfg.AttEn = 1'b1;
    cfg.RspEn = 1'b1;
    check("ctl does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.CtxEn = 1'b1;
    cfg.C3dEn = 1'b1;
    cfg.AttEn = 1'b1;
    cfg.RspEn = 1'b1;
    check("ctl does not legalize virgl", !apu_cfg_legal(cfg));

    set_buf(1'b0, 32'd0);
    ctx_step(APU_VGPU_CTX_EMPTY, "empty");
    set_buf(1'b1, 32'd32);
    ctx_step(APU_VGPU_CTX_FAULT, "short");
    check("short keeps", ctx == '0);
    load_good();
    set_buf(1'b1, APU_VGPU_CTL_END);
    mem[8] = 32'h0;
    ctx_step(APU_VGPU_CTX_FAULT, "name");
    check("name keeps", !ctx.valid);
    mem[8] = good_word(8);
    ctx_step(APU_VGPU_CTX_OK, "ctx");
    check("ctx record", ctx.valid && ctx.ctx_id == APU_VGPU_CTX_ID &&
          ctx.next == APU_VGPU_CTX_BYTES);
    ctx_step(APU_VGPU_CTX_FAULT, "ctx again");
    check("ctx kept", ctx.valid && ctx.ctx_id == APU_VGPU_CTX_ID);

    pulse_reset();
    check("reset clears ctx", ctx == '0 && c3d == '0 && att == '0 && rsp == '0);
    set_buf(1'b1, APU_VGPU_CTL_END);
    load_good();
    c3d_step(APU_VGPU_C3D_EMPTY, "c3d empty");
    ctx_step(APU_VGPU_CTX_OK, "ctx for rt");
    mem[34] = 32'd64;
    c3d_step(APU_VGPU_C3D_FAULT, "rt width");
    check("rt kept clear", !c3d.rt_valid && !c3d.vbo_valid);
    mem[34] = good_word(34);
    c3d_step(APU_VGPU_C3D_OK, "rt");
    check("rt record", c3d.rt_valid && c3d.rt_w == APU_VGPU_RT_W &&
          c3d.rt_h == APU_VGPU_RT_H && c3d.next == APU_VGPU_CTX_BYTES + APU_VGPU_C3D_BYTES);
    mem[48] = APU_VGPU_RES_RT;
    c3d_step(APU_VGPU_C3D_FAULT, "vbo id");
    check("vbo kept clear", c3d.rt_valid && !c3d.vbo_valid && c3d.rt_w == APU_VGPU_RT_W);
    mem[48] = good_word(48);
    c3d_step(APU_VGPU_C3D_OK, "vbo");
    check("vbo record", c3d.vbo_valid && c3d.vbo_bytes == APU_VIRGL_VBO_BYTES &&
          c3d.next == APU_VGPU_CTX_BYTES + (APU_VGPU_C3D_BYTES << 1));
    c3d_step(APU_VGPU_C3D_FAULT, "c3d again");
    check("c3d kept", c3d.rt_valid && c3d.vbo_valid);

    pulse_reset();
    load_good();
    set_buf(1'b1, APU_VGPU_CTL_END);
    ctx_step(APU_VGPU_CTX_OK, "ctx for one");
    c3d_step(APU_VGPU_C3D_OK, "rt only");
    att_step(APU_VGPU_ATT_EMPTY, "att early");
    c3d_step(APU_VGPU_C3D_OK, "vbo for att");
    mem[66] = 32'd9;
    att_step(APU_VGPU_ATT_FAULT, "att id");
    check("att kept clear", !att.rt && !att.vbo && !att.scan);
    mem[66] = good_word(66);
    att_step(APU_VGPU_ATT_OK, "att rt");
    check("att rt", att.rt && !att.vbo && att.next == c3d.next + APU_VGPU_ATT_BYTES);
    att_step(APU_VGPU_ATT_OK, "att vbo");
    att_step(APU_VGPU_ATT_OK, "att scan");
    check("att done", att.rt && att.vbo && att.scan && att.next == APU_VGPU_CTL_END);
    att_step(APU_VGPU_ATT_FAULT, "att again");
    check("att kept", att.scan && att.next == APU_VGPU_CTL_END);

    sub = '0;
    drw = '0;
    rsp_step(APU_VGPU_RSP_EMPTY, 1'b0, 1'b0, "rsp empty");
    scene_sub();
    drw = '0;
    drw.valid = 1'b1;
    drw.count = APU_VIRGL_VERT_COUNT;
    drw.prim = 32'h0;
    drw.next = APU_VGPU_SCENE_BYTES;
    rsp_step(APU_VGPU_RSP_FAULT, 1'b0, 1'b0, "bad prim");
    check("prim keeps", !rsp.valid);
    scene_drw();
    sub.size = 32'd32;
    rsp_step(APU_VGPU_RSP_FAULT, 1'b0, 1'b0, "bad size");
    scene_sub();
    rsp_step(APU_VGPU_RSP_BUS, 1'b1, 1'b1, "bus");
    check("bus keeps", !rsp.valid);
    rsp_step(APU_VGPU_RSP_OK, 1'b1, 1'b0, "rsp");
    check("rsp record", rsp.valid && rsp.addr == APU_VGPU_RSP_ADDR &&
          rsp.ctx_id == APU_VGPU_CTX_ID && rsp.fence == APU_VGPU_SCENE_FENCE);
    check("one kept store", writes == 2);
    rsp_step(APU_VGPU_RSP_FAULT, 1'b0, 1'b0, "rsp again");
    check("rsp kept", rsp.valid && rsp.fence == APU_VGPU_SCENE_FENCE);

    pulse_reset();
    check("reset clears rsp", rsp == '0 && att == '0);
    if (errors != 0) $fatal(1, "APU vgpu ctl errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ctl cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
