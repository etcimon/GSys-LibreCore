// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_dcr;
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
  apu_vgpu_ver_t ver;
  apu_vgpu_fsr_t fsr;
  apu_vgpu_vsr_t vsr;
  apu_vgpu_rzr_t rzr;
  apu_vgpu_dbr_t dbr;
  apu_vgpu_bbr_t bbr;
  apu_vgpu_rcr_t rcr;
  logic dcr_req = 0, dcr_rdy, dcr_cpl_v, dcr_cpl_r = 0;
  apu_vgpu_dcr_cpl_t dcr_cpl;
  apu_vgpu_dcr_t dcr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic dck_req = 0, dck_rdy, dck_cpl_v, dck_cpl_r = 0;
  apu_vgpu_dck_cpl_t dck_cpl, off_cpl;
  apu_vgpu_dck_t dck, off_dck;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_handle = 0, bad_state = 0, bad_tail = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] Frag = 32'(APU_VIRGL_SHADER_FRAGMENT);
  localparam logic [31:0] Vstage = 32'(APU_VIRGL_SHADER_VERTEX);

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_dcr #(.Enable(1'b1)) i_dcr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf), .iwr_i(iwr),
    .svr_i(svr), .ssr_i(ssr), .ver_i(ver), .fsr_i(fsr), .vsr_i(vsr), .rzr_i(rzr),
    .dbr_i(dbr), .bbr_i(bbr), .rcr_i(rcr),
    .req_valid_i(dcr_req), .req_ready_o(dcr_rdy),
    .cpl_valid_o(dcr_cpl_v), .cpl_ready_i(dcr_cpl_r), .cpl_o(dcr_cpl), .dcr_o(dcr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_dck #(.Enable(1'b1)) i_dck (
    .clk_i(clk), .rst_ni, .dcr_i(dcr), .rcr_i(rcr), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(dck_req), .req_ready_o(dck_rdy),
    .cpl_valid_o(dck_cpl_v), .cpl_ready_i(dck_cpl_r), .cpl_o(dck_cpl), .dck_o(dck)
  );
  g6lc_apu_vgpu_dck_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .dcr_i(dcr), .rcr_i(rcr), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(dck_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(dck_cpl_r), .cpl_o(off_cpl), .dck_o(off_dck)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu dcr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      // Lanes 0-3 stay 0. They are the blend object tail.
      beat_data[159:128] = bad_hdr ? 32'h0 : APU_VIRGL_DS_HDR;
      beat_data[191:160] = bad_handle ? APU_VIRGL_RZ_HANDLE : APU_VIRGL_DS_HANDLE;
      beat_data[223:192] = bad_state ? 32'd1 : 32'h0;
    end else begin
      beat_data[63:32] = bad_tail ? 32'd1 : 32'h0;
      // Rasterizer object. Not this command.
      beat_data[95:64] = APU_VIRGL_RZ_HDR;
      beat_data[127:96] = APU_VIRGL_RZ_HANDLE;
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
      want = idx == 0 ? APU_VGPU_DCR_ADDR : APU_VGPU_DCR_LAST;
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
        bad_handle <= 1'b0;
        bad_state <= 1'b0;
      end
      if (idx == 1) bad_tail <= 1'b0;
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
    svr.stage = Frag;
    svr.slot = 32'h0;
    svr.handle = APU_VIRGL_SV_HANDLE;
    ssr = '0;
    ssr.valid = 1'b1;
    ssr.stage = Frag;
    ssr.slot = 32'h0;
    ssr.handle = APU_VIRGL_SS_HANDLE;
    ver = '0;
    ver.valid = 1'b1;
    ver.hdr = APU_VIRGL_VEB_HDR;
    ver.handle = APU_VIRGL_VE_HANDLE;
    fsr = '0;
    fsr.valid = 1'b1;
    fsr.handle = APU_VIRGL_FS_HANDLE;
    fsr.stage = Frag;
    vsr = '0;
    vsr.valid = 1'b1;
    vsr.handle = APU_VIRGL_VS_HANDLE;
    vsr.stage = Vstage;
    rzr = '0;
    rzr.valid = 1'b1;
    rzr.hdr = APU_VIRGL_RB_HDR;
    rzr.handle = APU_VIRGL_RZ_HANDLE;
    dbr = '0;
    dbr.valid = 1'b1;
    dbr.hdr = APU_VIRGL_DB_HDR;
    dbr.handle = APU_VIRGL_DS_HANDLE;
    bbr = '0;
    bbr.valid = 1'b1;
    bbr.hdr = APU_VIRGL_BB_HDR;
    bbr.handle = APU_VIRGL_BL_HANDLE;
    rcr = '0;
    rcr.valid = 1'b1;
    rcr.hdr = APU_VIRGL_RZ_HDR;
    rcr.handle = APU_VIRGL_RZ_HANDLE;
  endtask

  function automatic logic ds_ok(input apu_vgpu_dcr_t rec);
    ds_ok = rec.valid && rec.hdr == APU_VIRGL_DS_HDR &&
            rec.handle == APU_VIRGL_DS_HANDLE && rec.hdr != rec.handle &&
            rec.hdr != APU_VIRGL_DB_HDR && rec.handle != APU_VIRGL_RZ_HANDLE;
  endfunction

  task automatic dcr_step(input apu_vgpu_dcr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!dcr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    dcr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dcr_req = 1'b0;
    while (!dcr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), dcr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_dck == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_DCR_OK) begin
      check("depth stencil", ds_ok(dcr));
      check("read count", nread == n0 + 2 && !order_bad &&
            seen_first == APU_VGPU_DCR_ADDR && seen_last == APU_VGPU_DCR_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad handle" ||
                 name == "bad state") begin
      check("one beat", nread == n0 + 1 && !dcr.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !dcr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), dcr_cpl_v);
    dcr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dcr_cpl_r = 1'b0;
    while (dcr_cpl_v) @(negedge clk);
  endtask

  task automatic dck_step(input apu_vgpu_dck_status_e st, input string name);
    @(negedge clk);
    while (!dck_rdy) @(negedge clk);
    cases++;
    dck_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dck_req = 1'b0;
    while (!dck_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), dck_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_dck == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), dck_cpl_v);
    dck_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dck_cpl_r = 1'b0;
    while (dck_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    dcr_req = 1'b0;
    dck_req = 1'b0;
    dcr_cpl_r = 1'b0;
    dck_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
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
    ver = '0;
    fsr = '0;
    vsr = '0;
    rzr = '0;
    dbr = '0;
    bbr = '0;
    rcr = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && dcr == '0 &&
          dck == '0);
    check("profiles keep the depth stencil off",
          !ApuOff.DcrEn && !ApuOff.DckEn &&
          !ApuP1Transport.DcrEn && !ApuP1Transport.DckEn &&
          !ApuHarness.DcrEn && !ApuHarness.DckEn &&
          !ApuSchedBoth.DcrEn && !ApuSchedBoth.DckEn &&
          !ApuBadVirglGrant.DcrEn && !ApuBadVirglGrant.DckEn);
    cfg = ApuP1Transport;
    cfg.DcrEn = 1'b1;
    cfg.DckEn = 1'b1;
    check("depth stencil does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.DcrEn = 1'b1;
    cfg.DckEn = 1'b1;
    check("depth stencil does not legalize virgl", !apu_cfg_legal(cfg));
    check("depth stencil place", APU_VGPU_DCR_BEAT == 6'd15 &&
          APU_VGPU_DCR_ADDR == 64'h8800B1E0 &&
          APU_VGPU_DCR_LAST == 64'h8800B200 &&
          APU_VGPU_DCR_LAST == APU_VGPU_RCR_ADDR &&
          APU_VIRGL_DCR_AT == 32'd496 &&
          APU_VIRGL_DCR_AT + 32'd24 == APU_VIRGL_RCR_AT &&
          APU_VIRGL_DS_HDR == 32'h00050301 &&
          APU_VIRGL_DS_HDR == {16'd5, APU_VIRGL_OBJ_DSA,
                               APU_VIRGL_CREATE_OBJECT} &&
          APU_VIRGL_DS_HANDLE == 32'd8 &&
          APU_VIRGL_RZ_HANDLE == 32'd9 &&
          APU_VIRGL_DB_HDR == 32'h00010302);

    dcr_step(APU_VGPU_DCR_EMPTY, "dcr empty");
    good_in();
    rcr = '0;
    dcr_step(APU_VGPU_DCR_EMPTY, "rasterizer missing");
    good_in();
    fet.beats = 6'd0;
    dcr_step(APU_VGPU_DCR_FAULT, "bad identity");
    good_in();
    rcr.handle = APU_VIRGL_DS_HANDLE;
    dcr_step(APU_VGPU_DCR_FAULT, "bad rasterizer");
    good_in();
    fail_next = 1'b1;
    dcr_step(APU_VGPU_DCR_FAULT, "bad beat");
    bad_hdr = 1'b1;
    dcr_step(APU_VGPU_DCR_FAULT, "bad hdr");
    bad_handle = 1'b1;
    dcr_step(APU_VGPU_DCR_FAULT, "bad handle");
    bad_state = 1'b1;
    dcr_step(APU_VGPU_DCR_FAULT, "bad state");
    bad_tail = 1'b1;
    dcr_step(APU_VGPU_DCR_FAULT, "bad tail");
    dcr_step(APU_VGPU_DCR_OK, "depth stencil");
    dcr_step(APU_VGPU_DCR_FAULT, "depth stencil again");
    check("depth stencil stays", ds_ok(dcr) && rcr.handle == APU_VIRGL_RZ_HANDLE &&
          dcr.handle != rcr.handle);
    dck_step(APU_VGPU_DCK_OK, "keep depth stencil");
    check("depth stencil kept", dck.valid && dck.hdr == APU_VIRGL_DS_HDR &&
          dck.handle == APU_VIRGL_DS_HANDLE && dck.hdr != dck.handle &&
          dck.handle != rcr.handle);
    dck_step(APU_VGPU_DCK_FAULT, "depth stencil keep again");
    check("depth stencil keep stays", dck.hdr == APU_VIRGL_DS_HDR &&
          dck.handle == APU_VIRGL_DS_HANDLE);

    pulse_reset();
    check("reset clears", dcr == '0 && dck == '0);
    zero_in();
    dcr_step(APU_VGPU_DCR_EMPTY, "after reset");
    dck_step(APU_VGPU_DCK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu dcr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_dcr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
