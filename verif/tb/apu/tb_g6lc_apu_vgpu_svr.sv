// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_svr;
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
  logic svr_req = 0, svr_rdy, svr_cpl_v, svr_cpl_r = 0;
  apu_vgpu_svr_cpl_t svr_cpl;
  apu_vgpu_svr_t svr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic svk_req = 0, svk_rdy, svk_cpl_v, svk_cpl_r = 0;
  apu_vgpu_svk_cpl_t svk_cpl, off_cpl;
  apu_vgpu_svk_t svk, off_svk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_stage = 0, bad_slot = 0, bad_handle = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] VebHdr = {16'd1, APU_VIRGL_OBJ_VERTEX_ELEMENTS,
                                    APU_VIRGL_BIND_OBJECT};
  localparam logic [31:0] SsbHdr = {16'd3, 8'd0, APU_VIRGL_BIND_SAMPLER_STATES};
  localparam logic [31:0] Stage = 32'(APU_VIRGL_SHADER_FRAGMENT);

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_svr #(.Enable(1'b1)) i_svr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf), .iwr_i(iwr),
    .req_valid_i(svr_req), .req_ready_o(svr_rdy),
    .cpl_valid_o(svr_cpl_v), .cpl_ready_i(svr_cpl_r), .cpl_o(svr_cpl), .svr_o(svr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_svk #(.Enable(1'b1)) i_svk (
    .clk_i(clk), .rst_ni, .svr_i(svr), .iwr_i(iwr), .fet_i(fet), .qdr_i(qdr),
    .req_valid_i(svk_req), .req_ready_o(svk_rdy),
    .cpl_valid_o(svk_cpl_v), .cpl_ready_i(svk_cpl_r), .cpl_o(svk_cpl), .svk_o(svk)
  );
  g6lc_apu_vgpu_svk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .svr_i(svr), .iwr_i(iwr), .fet_i(fet), .qdr_i(qdr),
    .req_valid_i(svk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(svk_cpl_r), .cpl_o(off_cpl), .svk_o(off_svk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu svr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      // Vertex-element bind and sampler-state tail. Not this command.
      beat_data[31:0] = VebHdr;
      beat_data[63:32] = APU_VIRGL_VE_HANDLE;
      beat_data[95:64] = SsbHdr;
      beat_data[127:96] = Stage;
      beat_data[191:160] = APU_VIRGL_SS_HANDLE;
      beat_data[223:192] = bad_hdr ? 32'h0 : APU_VIRGL_SVB_HDR;
      beat_data[255:224] = bad_stage ? 32'h0 : Stage;
    end else begin
      beat_data[31:0] = bad_slot ? 32'd1 : 32'h0;
      beat_data[63:32] = bad_handle ? 32'h0 : APU_VIRGL_SV_HANDLE;
      // Inline-write header and resource. Not part of this command.
      beat_data[95:64] = APU_VIRGL_IW_HDR;
      beat_data[127:96] = APU_VIRGL_RES_VBO;
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
      want = idx == 0 ? APU_VGPU_SVB_ADDR : APU_VGPU_SVB_LAST;
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
        bad_stage <= 1'b0;
      end
      if (idx == 1) begin
        bad_slot <= 1'b0;
        bad_handle <= 1'b0;
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
  endtask

  function automatic logic sv_ok(input apu_vgpu_svr_t rec);
    sv_ok = rec.valid && rec.stage == Stage && rec.slot == 32'h0 &&
            rec.handle == APU_VIRGL_SV_HANDLE && rec.stage != rec.slot &&
            rec.handle != rec.stage && rec.handle != APU_VIRGL_SS_HANDLE;
  endfunction

  task automatic svr_step(input apu_vgpu_svr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!svr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    svr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    svr_req = 1'b0;
    while (!svr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), svr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_svk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_SVR_OK) begin
      check("sampler view", sv_ok(svr));
      check("read count", nread == n0 + 2 && !order_bad &&
            seen_first == APU_VGPU_SVB_ADDR && seen_last == APU_VGPU_SVB_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad stage") begin
      check("one beat", nread == n0 + 1 && !svr.valid);
    end else if (name == "bad slot" || name == "bad handle") begin
      check("two beats", nread == n0 + 2 && !svr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), svr_cpl_v);
    svr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    svr_cpl_r = 1'b0;
    while (svr_cpl_v) @(negedge clk);
  endtask

  task automatic svk_step(input apu_vgpu_svk_status_e st, input string name);
    @(negedge clk);
    while (!svk_rdy) @(negedge clk);
    cases++;
    svk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    svk_req = 1'b0;
    while (!svk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), svk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_svk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), svk_cpl_v);
    svk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    svk_cpl_r = 1'b0;
    while (svk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    svr_req = 1'b0;
    svk_req = 1'b0;
    svr_cpl_r = 1'b0;
    svk_cpl_r = 1'b0;
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
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && svr == '0 &&
          svk == '0);
    check("profiles keep the sampler view off",
          !ApuOff.SvrEn && !ApuOff.SvkEn &&
          !ApuP1Transport.SvrEn && !ApuP1Transport.SvkEn &&
          !ApuHarness.SvrEn && !ApuHarness.SvkEn &&
          !ApuSchedBoth.SvrEn && !ApuSchedBoth.SvkEn &&
          !ApuBadVirglGrant.SvrEn && !ApuBadVirglGrant.SvkEn);
    cfg = ApuP1Transport;
    cfg.SvrEn = 1'b1;
    cfg.SvkEn = 1'b1;
    check("sampler view does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.SvrEn = 1'b1;
    cfg.SvkEn = 1'b1;
    check("sampler view does not legalize virgl", !apu_cfg_legal(cfg));
    check("sv place", APU_VGPU_SVB_BEAT == 6'd19 &&
          APU_VGPU_SVB_ADDR == 64'h8800B260 &&
          APU_VGPU_SVB_LAST == 64'h8800B280 &&
          APU_VGPU_SVB_LAST == APU_VGPU_IW_ADDR &&
          APU_VIRGL_SVB_AT == 32'd632 &&
          APU_VIRGL_SVB_AT == APU_VIRGL_SSB_NEXT &&
          APU_VIRGL_SVB_AT + 32'd16 == APU_VIRGL_SVB_NEXT &&
          APU_VIRGL_SVB_HDR == 32'h0003000A &&
          APU_VIRGL_SVB_HDR == {16'd3, 8'd0, APU_VIRGL_SET_SAMPLER_VIEWS} &&
          APU_VIRGL_SV_HANDLE == 32'd5 &&
          APU_VIRGL_SS_HANDLE == 32'd6);

    svr_step(APU_VGPU_SVR_EMPTY, "svr empty");
    good_in();
    iwr = '0;
    svr_step(APU_VGPU_SVR_EMPTY, "inline write missing");
    good_in();
    fet.beats = 6'd0;
    svr_step(APU_VGPU_SVR_FAULT, "bad identity");
    good_in();
    iwr.nbytes = 32'h0;
    svr_step(APU_VGPU_SVR_FAULT, "bad inline");
    good_in();
    fail_next = 1'b1;
    svr_step(APU_VGPU_SVR_FAULT, "bad beat");
    bad_hdr = 1'b1;
    svr_step(APU_VGPU_SVR_FAULT, "bad hdr");
    bad_stage = 1'b1;
    svr_step(APU_VGPU_SVR_FAULT, "bad stage");
    bad_slot = 1'b1;
    svr_step(APU_VGPU_SVR_FAULT, "bad slot");
    bad_handle = 1'b1;
    svr_step(APU_VGPU_SVR_FAULT, "bad handle");
    svr_step(APU_VGPU_SVR_OK, "sampler view");
    svr_step(APU_VGPU_SVR_FAULT, "sampler view again");
    check("sampler view stays", sv_ok(svr) && iwr.resource == APU_VIRGL_RES_VBO &&
          iwr.nbytes == APU_VIRGL_VBO_BYTES);
    svk_step(APU_VGPU_SVK_OK, "keep sampler view");
    check("sampler view kept", svk.valid && svk.stage == Stage &&
          svk.slot == 32'h0 && svk.handle == APU_VIRGL_SV_HANDLE &&
          svk.stage != svk.slot && svk.handle != svk.stage);
    svk_step(APU_VGPU_SVK_FAULT, "sampler view keep again");
    check("sampler view keep stays", svk.stage == Stage && svk.slot == 32'h0 &&
          svk.handle == APU_VIRGL_SV_HANDLE);

    pulse_reset();
    check("reset clears", svr == '0 && svk == '0);
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr = '0;
    cwr = '0;
    fbr = '0;
    vbf = '0;
    iwr = '0;
    svr_step(APU_VGPU_SVR_EMPTY, "after reset");
    svk_step(APU_VGPU_SVK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu svr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_svr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
