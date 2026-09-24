// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ver;
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
  apu_vgpu_vbf_t vbf;
  apu_vgpu_iwr_t iwr;
  apu_vgpu_svr_t svr;
  apu_vgpu_ssr_t ssr;
  logic ver_req = 0, ver_rdy, ver_cpl_v, ver_cpl_r = 0;
  apu_vgpu_ver_cpl_t ver_cpl;
  apu_vgpu_ver_t ver;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic vek_req = 0, vek_rdy, vek_cpl_v, vek_cpl_r = 0;
  apu_vgpu_vek_cpl_t vek_cpl, off_cpl;
  apu_vgpu_vek_t vek, off_vek;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_handle = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] Stage = 32'(APU_VIRGL_SHADER_FRAGMENT);

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_ver #(.Enable(1'b1)) i_ver (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf), .iwr_i(iwr),
    .svr_i(svr), .ssr_i(ssr),
    .req_valid_i(ver_req), .req_ready_o(ver_rdy),
    .cpl_valid_o(ver_cpl_v), .cpl_ready_i(ver_cpl_r), .cpl_o(ver_cpl), .ver_o(ver),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_vek #(.Enable(1'b1)) i_vek (
    .clk_i(clk), .rst_ni, .ver_i(ver), .ssr_i(ssr), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(vek_req), .req_ready_o(vek_rdy),
    .cpl_valid_o(vek_cpl_v), .cpl_ready_i(vek_cpl_r), .cpl_o(vek_cpl), .vek_o(vek)
  );
  g6lc_apu_vgpu_vek_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .ver_i(ver), .ssr_i(ssr), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(vek_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(vek_cpl_r), .cpl_o(off_cpl), .vek_o(off_vek)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu ver timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data;
    beat_data = '0;
    beat_data[31:0] = bad_hdr ? 32'h0 : APU_VIRGL_VEB_HDR;
    beat_data[63:32] = bad_handle ? 32'h0 : APU_VIRGL_VE_HANDLE;
    // Sampler state and sampler view. Not this command.
    beat_data[95:64] = APU_VIRGL_SSB_HDR;
    beat_data[127:96] = Stage;
    beat_data[191:160] = APU_VIRGL_SS_HANDLE;
    beat_data[223:192] = APU_VIRGL_SVB_HDR;
    beat_data[255:224] = Stage;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      if (rd_addr != APU_VGPU_VEB_ADDR) order_bad <= 1'b1;
      seen <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data();
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      bad_hdr <= 1'b0;
      bad_handle <= 1'b0;
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
    fbr.surface = APU_VIRGL_SURFACE_HANDLE;
    fbr.word = APU_VGPU_CLEAR_WORD;
    vbf = '0;
    vbf.valid = 1'b1;
    vbf.stride = APU_VIRGL_VERT_STRIDE;
    vbf.offset = 32'h0;
    vbf.resource = APU_VIRGL_RES_VBO;
    iwr = '0;
    iwr.valid = 1'b1;
    iwr.resource = APU_VIRGL_RES_VBO;
    iwr.nbytes = APU_VIRGL_VBO_BYTES;
    svr = '0;
    svr.valid = 1'b1;
    svr.stage = Stage;
    svr.slot = 32'h0;
    svr.handle = APU_VIRGL_SV_HANDLE;
    ssr = '0;
    ssr.valid = 1'b1;
    ssr.stage = Stage;
    ssr.slot = 32'h0;
    ssr.handle = APU_VIRGL_SS_HANDLE;
  endtask

  function automatic logic ve_ok(input apu_vgpu_ver_t rec);
    ve_ok = rec.valid && rec.hdr == APU_VIRGL_VEB_HDR &&
            rec.handle == APU_VIRGL_VE_HANDLE && rec.hdr != rec.handle &&
            rec.handle != APU_VIRGL_SS_HANDLE;
  endfunction

  task automatic ver_step(input apu_vgpu_ver_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!ver_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    ver_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ver_req = 1'b0;
    while (!ver_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ver_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vek == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_VER_OK) begin
      check("vertex elements", ve_ok(ver));
      check("read count", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_VEB_ADDR);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad handle") begin
      check("one beat", nread == n0 + 1 && !ver.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), ver_cpl_v);
    ver_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ver_cpl_r = 1'b0;
    while (ver_cpl_v) @(negedge clk);
  endtask

  task automatic vek_step(input apu_vgpu_vek_status_e st, input string name);
    @(negedge clk);
    while (!vek_rdy) @(negedge clk);
    cases++;
    vek_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vek_req = 1'b0;
    while (!vek_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vek_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vek == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), vek_cpl_v);
    vek_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vek_cpl_r = 1'b0;
    while (vek_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    ver_req = 1'b0;
    vek_req = 1'b0;
    ver_cpl_r = 1'b0;
    vek_cpl_r = 1'b0;
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
    vbf = '0;
    iwr = '0;
    svr = '0;
    ssr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && ver == '0 &&
          vek == '0);
    check("profiles keep the vertex elements off",
          !ApuOff.VerEn && !ApuOff.VekEn &&
          !ApuP1Transport.VerEn && !ApuP1Transport.VekEn &&
          !ApuHarness.VerEn && !ApuHarness.VekEn &&
          !ApuSchedBoth.VerEn && !ApuSchedBoth.VekEn &&
          !ApuBadVirglGrant.VerEn && !ApuBadVirglGrant.VekEn);
    cfg = ApuP1Transport;
    cfg.VerEn = 1'b1;
    cfg.VekEn = 1'b1;
    check("vertex elements do not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VerEn = 1'b1;
    cfg.VekEn = 1'b1;
    check("vertex elements do not legalize virgl", !apu_cfg_legal(cfg));
    check("ve place", APU_VGPU_VEB_ADDR == 64'h8800B260 &&
          APU_VGPU_VEB_ADDR == APU_VGPU_SSB_ADDR &&
          APU_VIRGL_VEB_AT == 32'd608 &&
          APU_VIRGL_VEB_AT + 32'd8 == APU_VIRGL_SSB_AT &&
          APU_VIRGL_VEB_HDR == 32'h00010502 &&
          APU_VIRGL_VEB_HDR == {16'd1, APU_VIRGL_OBJ_VERTEX_ELEMENTS,
                                APU_VIRGL_BIND_OBJECT} &&
          APU_VIRGL_VE_HANDLE == 32'd4 &&
          APU_VIRGL_SS_HANDLE == 32'd6);

    ver_step(APU_VGPU_VER_EMPTY, "ver empty");
    good_in();
    ssr = '0;
    ver_step(APU_VGPU_VER_EMPTY, "sampler state missing");
    good_in();
    fet.beats = 6'd0;
    ver_step(APU_VGPU_VER_FAULT, "bad identity");
    good_in();
    ssr.handle = APU_VIRGL_VE_HANDLE;
    ver_step(APU_VGPU_VER_FAULT, "bad state");
    good_in();
    fail_next = 1'b1;
    ver_step(APU_VGPU_VER_FAULT, "bad beat");
    bad_hdr = 1'b1;
    ver_step(APU_VGPU_VER_FAULT, "bad hdr");
    bad_handle = 1'b1;
    ver_step(APU_VGPU_VER_FAULT, "bad handle");
    ver_step(APU_VGPU_VER_OK, "vertex elements");
    ver_step(APU_VGPU_VER_FAULT, "vertex elements again");
    check("vertex elements stay", ve_ok(ver) && ssr.handle == APU_VIRGL_SS_HANDLE &&
          ver.handle != ssr.handle);
    vek_step(APU_VGPU_VEK_OK, "keep vertex elements");
    check("vertex elements kept", vek.valid && vek.hdr == APU_VIRGL_VEB_HDR &&
          vek.handle == APU_VIRGL_VE_HANDLE && vek.hdr != vek.handle &&
          vek.handle != ssr.handle);
    vek_step(APU_VGPU_VEK_FAULT, "vertex elements keep again");
    check("vertex elements keep stays", vek.hdr == APU_VIRGL_VEB_HDR &&
          vek.handle == APU_VIRGL_VE_HANDLE);

    pulse_reset();
    check("reset clears", ver == '0 && vek == '0);
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr = '0;
    cwr = '0;
    fbr = '0;
    vbf = '0;
    iwr = '0;
    svr = '0;
    ssr = '0;
    ver_step(APU_VGPU_VER_EMPTY, "after reset");
    vek_step(APU_VGPU_VEK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu ver errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ver cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
