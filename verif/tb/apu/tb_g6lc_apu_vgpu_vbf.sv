// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_vbf;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fet_t fet;
  apu_vgpu_drd_t drd;
  apu_vgpu_qdr_t qdr;
  apu_vgpu_vwx_t vwx;
  apu_vgpu_cxr_t cxr;
  apu_vgpu_cwr_t cwr;
  apu_vgpu_fbr_t fbr;
  logic vbf_req = 0, vbf_rdy, vbf_cpl_v, vbf_cpl_r = 0;
  apu_vgpu_vbf_cpl_t vbf_cpl;
  apu_vgpu_vbf_t vbf;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic vbk_req = 0, vbk_rdy, vbk_cpl_v, vbk_cpl_r = 0;
  apu_vgpu_vbk_cpl_t vbk_cpl, off_cpl;
  apu_vgpu_vbk_t vbk, off_vbk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_stride = 0, bad_off = 0, bad_res = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_vbf #(.Enable(1'b1)) i_vbf (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr),
    .req_valid_i(vbf_req), .req_ready_o(vbf_rdy),
    .cpl_valid_o(vbf_cpl_v), .cpl_ready_i(vbf_cpl_r), .cpl_o(vbf_cpl), .vbf_o(vbf),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_vbk #(.Enable(1'b1)) i_vbk (
    .clk_i(clk), .rst_ni, .vbf_i(vbf), .fet_i(fet), .qdr_i(qdr),
    .req_valid_i(vbk_req), .req_ready_o(vbk_rdy),
    .cpl_valid_o(vbk_cpl_v), .cpl_ready_i(vbk_cpl_r), .cpl_o(vbk_cpl), .vbk_o(vbk)
  );
  g6lc_apu_vgpu_vbk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .vbf_i(vbf), .fet_i(fet), .qdr_i(qdr),
    .req_valid_i(vbk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(vbk_cpl_r), .cpl_o(off_cpl), .vbk_o(off_vbk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu vbf timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      // Last quad float. Not part of the vertex-buffer command.
      beat_data[191:160] = APU_VIRGL_F32_ONE;
      beat_data[223:192] = bad_hdr ? 32'h0 : APU_VIRGL_VB_HDR;
      beat_data[255:224] = bad_stride ? 32'h0 : APU_VIRGL_VERT_STRIDE;
    end else begin
      beat_data[31:0] = bad_off ? 32'd1 : 32'h0;
      beat_data[63:32] = bad_res ? 32'h0 : APU_VIRGL_RES_VBO;
      // Scissor header follows the vertex-buffer set and is not part of it.
      beat_data[95:64] = APU_VIRGL_SCI_HDR;
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
      want = idx == 0 ? APU_VGPU_VB_ADDR : APU_VGPU_VB_LAST;
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
        bad_stride <= 1'b0;
      end
      if (idx == 1) begin
        bad_off <= 1'b0;
        bad_res <= 1'b0;
      end
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
    cwr.word = APU_VGPU_CLEAR_WORD;
    fbr = '0;
    fbr.valid = 1'b1;
    fbr.nr_cbufs = 32'd1;
    fbr.surface = APU_VIRGL_SURFACE_HANDLE;
    fbr.word = APU_VGPU_CLEAR_WORD;
  endtask

  function automatic logic vb_ok(input apu_vgpu_vbf_t rec);
    vb_ok = rec.valid && rec.stride == APU_VIRGL_VERT_STRIDE &&
            rec.offset == 32'h0 && rec.resource == APU_VIRGL_RES_VBO &&
            rec.stride != rec.resource;
  endfunction

  task automatic vbf_step(input apu_vgpu_vbf_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!vbf_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    vbf_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vbf_req = 1'b0;
    while (!vbf_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vbf_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vbk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_VBF_OK) begin
      check("vertex buffer", vb_ok(vbf));
      check("read count", nread == n0 + 2 && !order_bad &&
            seen_first == APU_VGPU_VB_ADDR && seen_last == APU_VGPU_VB_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad stride") begin
      check("one beat", nread == n0 + 1 && !vbf.valid);
    end else if (name == "bad off" || name == "bad res") begin
      check("two beats", nread == n0 + 2 && !vbf.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), vbf_cpl_v);
    vbf_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vbf_cpl_r = 1'b0;
    while (vbf_cpl_v) @(negedge clk);
  endtask

  task automatic vbk_step(input apu_vgpu_vbk_status_e st, input string name);
    @(negedge clk);
    while (!vbk_rdy) @(negedge clk);
    cases++;
    vbk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vbk_req = 1'b0;
    while (!vbk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vbk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vbk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), vbk_cpl_v);
    vbk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vbk_cpl_r = 1'b0;
    while (vbk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    vbf_req = 1'b0;
    vbk_req = 1'b0;
    vbf_cpl_r = 1'b0;
    vbk_cpl_r = 1'b0;
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
    fbr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && vbf == '0 &&
          vbk == '0);
    check("profiles keep the vertex buffer off",
          !ApuOff.VbfEn && !ApuOff.VbkEn &&
          !ApuP1Transport.VbfEn && !ApuP1Transport.VbkEn &&
          !ApuHarness.VbfEn && !ApuHarness.VbkEn &&
          !ApuSchedBoth.VbfEn && !ApuSchedBoth.VbkEn &&
          !ApuBadVirglGrant.VbfEn && !ApuBadVirglGrant.VbkEn);
    cfg = ApuP1Transport;
    cfg.VbfEn = 1'b1;
    cfg.VbkEn = 1'b1;
    check("vertex buffer does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VbfEn = 1'b1;
    cfg.VbkEn = 1'b1;
    check("vertex buffer does not legalize virgl", !apu_cfg_legal(cfg));
    check("vb place", APU_VGPU_VB_BEAT == 6'd24 &&
          APU_VGPU_VB_ADDR == 64'h8800B300 &&
          APU_VGPU_VB_ADDR == APU_VGPU_QUAD_LAST &&
          APU_VGPU_VB_LAST == 64'h8800B320 &&
          APU_VGPU_VB_LAST == APU_VGPU_VIEW_ADDR &&
          APU_VIRGL_VB_AT == 32'd792 &&
          APU_VIRGL_VB_HDR == 32'h00030006 &&
          APU_VIRGL_VERT_STRIDE == 32'd24 &&
          APU_VIRGL_RES_VBO == 32'd3);

    vbf_step(APU_VGPU_VBF_EMPTY, "vbf empty");
    good_in();
    fbr = '0;
    vbf_step(APU_VGPU_VBF_EMPTY, "framebuffer missing");
    good_in();
    fet.beats = 6'd0;
    vbf_step(APU_VGPU_VBF_FAULT, "bad identity");
    good_in();
    fail_next = 1'b1;
    vbf_step(APU_VGPU_VBF_FAULT, "bad beat");
    bad_hdr = 1'b1;
    vbf_step(APU_VGPU_VBF_FAULT, "bad hdr");
    bad_stride = 1'b1;
    vbf_step(APU_VGPU_VBF_FAULT, "bad stride");
    bad_off = 1'b1;
    vbf_step(APU_VGPU_VBF_FAULT, "bad off");
    bad_res = 1'b1;
    vbf_step(APU_VGPU_VBF_FAULT, "bad res");
    vbf_step(APU_VGPU_VBF_OK, "vertex buffer");
    vbf_step(APU_VGPU_VBF_FAULT, "vertex buffer again");
    check("vertex buffer stays", vb_ok(vbf));
    vbk_step(APU_VGPU_VBK_OK, "keep vertex buffer");
    check("vertex buffer kept", vbk.valid && vbk.stride == 32'd24 &&
          vbk.offset == 32'h0 && vbk.resource == 32'd3 &&
          vbk.stride != vbk.resource);
    vbk_step(APU_VGPU_VBK_FAULT, "vertex buffer keep again");
    check("vertex buffer keep stays", vbk.stride == 32'd24 && vbk.resource == 32'd3);

    pulse_reset();
    check("reset clears", vbf == '0 && vbk == '0);
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr = '0;
    cwr = '0;
    fbr = '0;
    vbf_step(APU_VGPU_VBF_EMPTY, "after reset");
    vbk_step(APU_VGPU_VBK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu vbf errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_vbf cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
