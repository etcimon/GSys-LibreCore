// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ssr;
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
  logic ssr_req = 0, ssr_rdy, ssr_cpl_v, ssr_cpl_r = 0;
  apu_vgpu_ssr_cpl_t ssr_cpl;
  apu_vgpu_ssr_t ssr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic ssk_req = 0, ssk_rdy, ssk_cpl_v, ssk_cpl_r = 0;
  apu_vgpu_ssk_cpl_t ssk_cpl, off_cpl;
  apu_vgpu_ssk_t ssk, off_ssk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_stage = 0, bad_slot = 0, bad_handle = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] VebHdr = {16'd1, APU_VIRGL_OBJ_VERTEX_ELEMENTS,
                                    APU_VIRGL_BIND_OBJECT};
  localparam logic [31:0] Stage = 32'(APU_VIRGL_SHADER_FRAGMENT);

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_ssr #(.Enable(1'b1)) i_ssr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf), .iwr_i(iwr), .svr_i(svr),
    .req_valid_i(ssr_req), .req_ready_o(ssr_rdy),
    .cpl_valid_o(ssr_cpl_v), .cpl_ready_i(ssr_cpl_r), .cpl_o(ssr_cpl), .ssr_o(ssr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_ssk #(.Enable(1'b1)) i_ssk (
    .clk_i(clk), .rst_ni, .ssr_i(ssr), .svr_i(svr), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(ssk_req), .req_ready_o(ssk_rdy),
    .cpl_valid_o(ssk_cpl_v), .cpl_ready_i(ssk_cpl_r), .cpl_o(ssk_cpl), .ssk_o(ssk)
  );
  g6lc_apu_vgpu_ssk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .ssr_i(ssr), .svr_i(svr), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(ssk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(ssk_cpl_r), .cpl_o(off_cpl), .ssk_o(off_ssk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu ssr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data;
    beat_data = '0;
    // Vertex-element bind. Not this command.
    beat_data[31:0] = VebHdr;
    beat_data[63:32] = APU_VIRGL_VE_HANDLE;
    beat_data[95:64] = bad_hdr ? 32'h0 : APU_VIRGL_SSB_HDR;
    beat_data[127:96] = bad_stage ? 32'h0 : Stage;
    beat_data[159:128] = bad_slot ? 32'd1 : 32'h0;
    beat_data[191:160] = bad_handle ? 32'h0 : APU_VIRGL_SS_HANDLE;
    // Sampler-view header and stage. Not this command.
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
      if (rd_addr != APU_VGPU_SSB_ADDR) order_bad <= 1'b1;
      seen <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data();
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      bad_hdr <= 1'b0;
      bad_stage <= 1'b0;
      bad_slot <= 1'b0;
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
  endtask

  function automatic logic ss_ok(input apu_vgpu_ssr_t rec);
    ss_ok = rec.valid && rec.stage == Stage && rec.slot == 32'h0 &&
            rec.handle == APU_VIRGL_SS_HANDLE && rec.stage != rec.slot &&
            rec.handle != rec.stage && rec.handle != APU_VIRGL_SV_HANDLE;
  endfunction

  task automatic ssr_step(input apu_vgpu_ssr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!ssr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    ssr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ssr_req = 1'b0;
    while (!ssr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ssr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_ssk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_SSR_OK) begin
      check("sampler state", ss_ok(ssr));
      check("read count", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_SSB_ADDR);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad stage" ||
                 name == "bad slot" || name == "bad handle") begin
      check("one beat", nread == n0 + 1 && !ssr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), ssr_cpl_v);
    ssr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ssr_cpl_r = 1'b0;
    while (ssr_cpl_v) @(negedge clk);
  endtask

  task automatic ssk_step(input apu_vgpu_ssk_status_e st, input string name);
    @(negedge clk);
    while (!ssk_rdy) @(negedge clk);
    cases++;
    ssk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ssk_req = 1'b0;
    while (!ssk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ssk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_ssk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), ssk_cpl_v);
    ssk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ssk_cpl_r = 1'b0;
    while (ssk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    ssr_req = 1'b0;
    ssk_req = 1'b0;
    ssr_cpl_r = 1'b0;
    ssk_cpl_r = 1'b0;
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
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && ssr == '0 &&
          ssk == '0);
    check("profiles keep the sampler state off",
          !ApuOff.SsrEn && !ApuOff.SskEn &&
          !ApuP1Transport.SsrEn && !ApuP1Transport.SskEn &&
          !ApuHarness.SsrEn && !ApuHarness.SskEn &&
          !ApuSchedBoth.SsrEn && !ApuSchedBoth.SskEn &&
          !ApuBadVirglGrant.SsrEn && !ApuBadVirglGrant.SskEn);
    cfg = ApuP1Transport;
    cfg.SsrEn = 1'b1;
    cfg.SskEn = 1'b1;
    check("sampler state does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.SsrEn = 1'b1;
    cfg.SskEn = 1'b1;
    check("sampler state does not legalize virgl", !apu_cfg_legal(cfg));
    check("ss place", APU_VGPU_SSB_ADDR == 64'h8800B260 &&
          APU_VGPU_SSB_ADDR == APU_VGPU_SVB_ADDR &&
          APU_VIRGL_SSB_AT == 32'd616 &&
          APU_VIRGL_SSB_AT + 32'd16 == APU_VIRGL_SSB_NEXT &&
          APU_VIRGL_SSB_NEXT == APU_VIRGL_SVB_AT &&
          APU_VIRGL_SSB_HDR == 32'h00030012 &&
          APU_VIRGL_SSB_HDR == {16'd3, 8'd0, APU_VIRGL_BIND_SAMPLER_STATES} &&
          APU_VIRGL_SS_HANDLE == 32'd6 &&
          APU_VIRGL_SV_HANDLE == 32'd5);

    ssr_step(APU_VGPU_SSR_EMPTY, "ssr empty");
    good_in();
    svr = '0;
    ssr_step(APU_VGPU_SSR_EMPTY, "sampler view missing");
    good_in();
    fet.beats = 6'd0;
    ssr_step(APU_VGPU_SSR_FAULT, "bad identity");
    good_in();
    svr.handle = APU_VIRGL_SS_HANDLE;
    ssr_step(APU_VGPU_SSR_FAULT, "bad view");
    good_in();
    fail_next = 1'b1;
    ssr_step(APU_VGPU_SSR_FAULT, "bad beat");
    bad_hdr = 1'b1;
    ssr_step(APU_VGPU_SSR_FAULT, "bad hdr");
    bad_stage = 1'b1;
    ssr_step(APU_VGPU_SSR_FAULT, "bad stage");
    bad_slot = 1'b1;
    ssr_step(APU_VGPU_SSR_FAULT, "bad slot");
    bad_handle = 1'b1;
    ssr_step(APU_VGPU_SSR_FAULT, "bad handle");
    ssr_step(APU_VGPU_SSR_OK, "sampler state");
    ssr_step(APU_VGPU_SSR_FAULT, "sampler state again");
    check("sampler state stays", ss_ok(ssr) && svr.handle == APU_VIRGL_SV_HANDLE &&
          ssr.handle != svr.handle);
    ssk_step(APU_VGPU_SSK_OK, "keep sampler state");
    check("sampler state kept", ssk.valid && ssk.stage == Stage &&
          ssk.slot == 32'h0 && ssk.handle == APU_VIRGL_SS_HANDLE &&
          ssk.stage != ssk.slot && ssk.handle != ssk.stage &&
          ssk.handle != svr.handle);
    ssk_step(APU_VGPU_SSK_FAULT, "sampler state keep again");
    check("sampler state keep stays", ssk.stage == Stage && ssk.slot == 32'h0 &&
          ssk.handle == APU_VIRGL_SS_HANDLE);

    pulse_reset();
    check("reset clears", ssr == '0 && ssk == '0);
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
    ssr_step(APU_VGPU_SSR_EMPTY, "after reset");
    ssk_step(APU_VGPU_SSK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu ssr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ssr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
