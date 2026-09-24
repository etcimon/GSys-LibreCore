// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_fbr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fet_t fet;
  apu_vgpu_drd_t drd;
  apu_vgpu_qdr_t qdr;
  apu_vgpu_vwx_t vwx;
  apu_vgpu_cxr_t cxr;
  apu_vgpu_cwr_t cwr;
  logic fbr_req = 0, fbr_rdy, fbr_cpl_v, fbr_cpl_r = 0;
  apu_vgpu_fbr_cpl_t fbr_cpl;
  apu_vgpu_fbr_t fbr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic fbk_req = 0, fbk_rdy, fbk_cpl_v, fbk_cpl_r = 0;
  apu_vgpu_fbk_cpl_t fbk_cpl, off_cpl;
  apu_vgpu_fbk_t fbk, off_fbk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_nr = 0, bad_surf = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_fbr #(.Enable(1'b1)) i_fbr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr),
    .req_valid_i(fbr_req), .req_ready_o(fbr_rdy),
    .cpl_valid_o(fbr_cpl_v), .cpl_ready_i(fbr_cpl_r), .cpl_o(fbr_cpl), .fbr_o(fbr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_fbk #(.Enable(1'b1)) i_fbk (
    .clk_i(clk), .rst_ni, .fbr_i(fbr), .fet_i(fet), .cwr_i(cwr),
    .req_valid_i(fbk_req), .req_ready_o(fbk_rdy),
    .cpl_valid_o(fbk_cpl_v), .cpl_ready_i(fbk_cpl_r), .cpl_o(fbk_cpl), .fbk_o(fbk)
  );
  g6lc_apu_vgpu_fbk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .fbr_i(fbr), .fet_i(fet), .cwr_i(cwr),
    .req_valid_i(fbk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(fbk_cpl_r), .cpl_o(off_cpl), .fbk_o(off_fbk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu fbr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      // Viewport scale. Not part of the framebuffer command.
      beat_data[31:0] = APU_VIRGL_F32_HALF_W;
      beat_data[223:192] = bad_hdr ? 32'h0 : APU_VIRGL_FBO_HDR;
      beat_data[255:224] = bad_nr ? 32'h0 : 32'd1;
    end else begin
      beat_data[63:32] = bad_surf ? 32'h0 : APU_VIRGL_SURFACE_HANDLE;
      // Clear header follows the framebuffer and is not part of it.
      beat_data[95:64] = APU_VIRGL_CLR_HDR;
    end
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nread - run_base;
      want = idx == 0 ? APU_VGPU_FBO_ADDR : APU_VGPU_FBO_LAST;
      if (rd_addr != want) order_bad <= 1'b1;
      if (idx == 0) seen_first <= rd_addr;
      seen_last <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data(idx);
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      if (idx == 0) begin
        bad_hdr <= 1'b0;
        bad_nr <= 1'b0;
      end
      if (idx == 1) bad_surf <= 1'b0;
      nread <= nread + 1;
      rsp_v <= 1'b1;
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
    fet = '0;
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
    drd = '0;
    drd.valid = 1'b1;
    drd.count = APU_VIRGL_VERT_COUNT;
    drd.prim = APU_VIRGL_PRIM_STRIP;
    qdr = '0;
    qdr.valid = 1'b1;
    qdr.x0 = APU_VIRGL_F32_NEG_ONE;
    qdr.last = APU_VIRGL_F32_ONE;
    vwx = '0;
    vwx.valid = 1'b1;
    vwx.x_neg = 16'd0;
    vwx.y_neg = 16'd0;
    vwx.x_pos = 16'd640;
    vwx.y_pos = 16'd480;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    cwr = '0;
    cwr.valid = 1'b1;
    cwr.red = APU_VIRGL_F32_P05;
    cwr.blue = APU_VIRGL_F32_P10;
    cwr.word = APU_VGPU_CLEAR_WORD;
  endtask

  function automatic logic fb_ok(input apu_vgpu_fbr_t rec);
    fb_ok = rec.valid && rec.nr_cbufs == 32'd1 &&
            rec.surface == APU_VIRGL_SURFACE_HANDLE &&
            rec.word == APU_VGPU_CLEAR_WORD && rec.word != rec.surface;
  endfunction

  task automatic fbr_step(input apu_vgpu_fbr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!fbr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    fbr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fbr_req = 1'b0;
    while (!fbr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), fbr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_fbk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_FBR_OK) begin
      check("framebuffer", fb_ok(fbr));
      check("read count", nread == n0 + 2 && !order_bad &&
            seen_first == APU_VGPU_FBO_ADDR && seen_last == APU_VGPU_FBO_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad nr") begin
      check("one beat", nread == n0 + 1 && !fbr.valid);
    end else if (name == "bad surf") begin
      check("two beats", nread == n0 + 2 && !fbr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), fbr_cpl_v);
    fbr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fbr_cpl_r = 1'b0;
    while (fbr_cpl_v) @(negedge clk);
  endtask

  task automatic fbk_step(input apu_vgpu_fbk_status_e st, input string name);
    @(negedge clk);
    while (!fbk_rdy) @(negedge clk);
    cases++;
    fbk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fbk_req = 1'b0;
    while (!fbk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), fbk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_fbk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), fbk_cpl_v);
    fbk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fbk_cpl_r = 1'b0;
    while (fbk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    fbr_req = 1'b0;
    fbk_req = 1'b0;
    fbr_cpl_r = 1'b0;
    fbk_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr = '0;
    cwr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && fbr == '0 &&
          fbk == '0);
    check("profiles keep the framebuffer off",
          !ApuOff.FbrEn && !ApuOff.FbkEn &&
          !ApuP1Transport.FbrEn && !ApuP1Transport.FbkEn &&
          !ApuHarness.FbrEn && !ApuHarness.FbkEn &&
          !ApuSchedBoth.FbrEn && !ApuSchedBoth.FbkEn &&
          !ApuBadVirglGrant.FbrEn && !ApuBadVirglGrant.FbkEn);
    cfg = ApuP1Transport;
    cfg.FbrEn = 1'b1;
    cfg.FbkEn = 1'b1;
    check("framebuffer does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.FbrEn = 1'b1;
    cfg.FbkEn = 1'b1;
    check("framebuffer does not legalize virgl", !apu_cfg_legal(cfg));
    check("fbo place", APU_VGPU_FBO_BEAT == 6'd26 &&
          APU_VGPU_FBO_ADDR == 64'h8800B340 &&
          APU_VGPU_FBO_ADDR == APU_VGPU_VIEW_LAST &&
          APU_VGPU_FBO_LAST == 64'h8800B360 &&
          APU_VGPU_FBO_LAST == APU_VGPU_CLR_ADDR &&
          APU_VIRGL_FBO_AT == 32'd856 &&
          APU_VIRGL_FBO_HDR == 32'h00030005 &&
          APU_VIRGL_SURFACE_HANDLE == 32'd1 &&
          APU_VGPU_CLEAR_WORD == 32'hFF1A0D0D);

    fbr_step(APU_VGPU_FBR_EMPTY, "fbr empty");
    good_in();
    cwr = '0;
    fbr_step(APU_VGPU_FBR_EMPTY, "clear missing");
    good_in();
    fet.beats = 6'd0;
    fbr_step(APU_VGPU_FBR_FAULT, "bad identity");
    good_in();
    fail_next = 1'b1;
    fbr_step(APU_VGPU_FBR_FAULT, "bad beat");
    bad_hdr = 1'b1;
    fbr_step(APU_VGPU_FBR_FAULT, "bad hdr");
    bad_nr = 1'b1;
    fbr_step(APU_VGPU_FBR_FAULT, "bad nr");
    bad_surf = 1'b1;
    fbr_step(APU_VGPU_FBR_FAULT, "bad surf");
    fbr_step(APU_VGPU_FBR_OK, "framebuffer");
    fbr_step(APU_VGPU_FBR_FAULT, "framebuffer again");
    check("framebuffer stays", fb_ok(fbr));
    fbk_step(APU_VGPU_FBK_OK, "keep framebuffer");
    check("framebuffer kept", fbk.valid && fbk.nr_cbufs == 32'd1 &&
          fbk.surface == 32'd1 && fbk.word == APU_VGPU_CLEAR_WORD);
    fbk_step(APU_VGPU_FBK_FAULT, "framebuffer keep again");
    check("framebuffer keep stays", fbk.word == APU_VGPU_CLEAR_WORD &&
          fbk.surface == 32'd1);

    pulse_reset();
    check("reset clears", fbr == '0 && fbk == '0);
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr = '0;
    cwr = '0;
    fbr_step(APU_VGPU_FBR_EMPTY, "after reset");
    fbk_step(APU_VGPU_FBK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu fbr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_fbr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
