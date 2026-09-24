// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_dbr;
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
  logic dbr_req = 0, dbr_rdy, dbr_cpl_v, dbr_cpl_r = 0;
  apu_vgpu_dbr_cpl_t dbr_cpl;
  apu_vgpu_dbr_t dbr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic dbk_req = 0, dbk_rdy, dbk_cpl_v, dbk_cpl_r = 0;
  apu_vgpu_dbk_cpl_t dbk_cpl, off_cpl;
  apu_vgpu_dbk_t dbk, off_dbk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_handle = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] Frag = 32'(APU_VIRGL_SHADER_FRAGMENT);
  localparam logic [31:0] Vstage = 32'(APU_VIRGL_SHADER_VERTEX);
  localparam logic [31:0] BbHdr = {16'd1, APU_VIRGL_OBJ_BLEND, APU_VIRGL_BIND_OBJECT};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_dbr #(.Enable(1'b1)) i_dbr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf), .iwr_i(iwr),
    .svr_i(svr), .ssr_i(ssr), .ver_i(ver), .fsr_i(fsr), .vsr_i(vsr), .rzr_i(rzr),
    .req_valid_i(dbr_req), .req_ready_o(dbr_rdy),
    .cpl_valid_o(dbr_cpl_v), .cpl_ready_i(dbr_cpl_r), .cpl_o(dbr_cpl), .dbr_o(dbr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_dbk #(.Enable(1'b1)) i_dbk (
    .clk_i(clk), .rst_ni, .dbr_i(dbr), .rzr_i(rzr), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(dbk_req), .req_ready_o(dbk_rdy),
    .cpl_valid_o(dbk_cpl_v), .cpl_ready_i(dbk_cpl_r), .cpl_o(dbk_cpl), .dbk_o(dbk)
  );
  g6lc_apu_vgpu_dbk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .dbr_i(dbr), .rzr_i(rzr), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(dbk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(dbk_cpl_r), .cpl_o(off_cpl), .dbk_o(off_dbk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu dbr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data;
    beat_data = '0;
    // Blend bind. Not this command.
    beat_data[159:128] = BbHdr;
    beat_data[191:160] = APU_VIRGL_BL_HANDLE;
    beat_data[223:192] = bad_hdr ? 32'h0 : APU_VIRGL_DB_HDR;
    beat_data[255:224] = bad_handle ? APU_VIRGL_RZ_HANDLE : APU_VIRGL_DS_HANDLE;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      if (rd_addr != APU_VGPU_DB_ADDR) order_bad <= 1'b1;
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
  endtask

  function automatic logic ds_ok(input apu_vgpu_dbr_t rec);
    ds_ok = rec.valid && rec.hdr == APU_VIRGL_DB_HDR &&
            rec.handle == APU_VIRGL_DS_HANDLE && rec.hdr != rec.handle &&
            rec.handle != APU_VIRGL_RZ_HANDLE &&
            rec.handle != APU_VIRGL_BL_HANDLE;
  endfunction

  task automatic dbr_step(input apu_vgpu_dbr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!dbr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    dbr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dbr_req = 1'b0;
    while (!dbr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), dbr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_dbk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_DBR_OK) begin
      check("depth stencil", ds_ok(dbr));
      check("read count", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_DB_ADDR);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad handle") begin
      check("one beat", nread == n0 + 1 && !dbr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), dbr_cpl_v);
    dbr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dbr_cpl_r = 1'b0;
    while (dbr_cpl_v) @(negedge clk);
  endtask

  task automatic dbk_step(input apu_vgpu_dbk_status_e st, input string name);
    @(negedge clk);
    while (!dbk_rdy) @(negedge clk);
    cases++;
    dbk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dbk_req = 1'b0;
    while (!dbk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), dbk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_dbk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), dbk_cpl_v);
    dbk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dbk_cpl_r = 1'b0;
    while (dbk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    dbr_req = 1'b0;
    dbk_req = 1'b0;
    dbr_cpl_r = 1'b0;
    dbk_cpl_r = 1'b0;
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
    ver = '0;
    fsr = '0;
    vsr = '0;
    rzr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && dbr == '0 &&
          dbk == '0);
    check("profiles keep the depth stencil off",
          !ApuOff.DbrEn && !ApuOff.DbkEn &&
          !ApuP1Transport.DbrEn && !ApuP1Transport.DbkEn &&
          !ApuHarness.DbrEn && !ApuHarness.DbkEn &&
          !ApuSchedBoth.DbrEn && !ApuSchedBoth.DbkEn &&
          !ApuBadVirglGrant.DbrEn && !ApuBadVirglGrant.DbkEn);
    cfg = ApuP1Transport;
    cfg.DbrEn = 1'b1;
    cfg.DbkEn = 1'b1;
    check("depth stencil does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.DbrEn = 1'b1;
    cfg.DbkEn = 1'b1;
    check("depth stencil does not legalize virgl", !apu_cfg_legal(cfg));
    check("ds place", APU_VGPU_DB_BEAT == 6'd17 &&
          APU_VGPU_DB_ADDR == 64'h8800B220 &&
          APU_VIRGL_DB_AT == 32'd568 &&
          APU_VIRGL_DB_AT + 32'd8 == APU_VIRGL_RB_AT &&
          APU_VIRGL_DB_HDR == 32'h00010302 &&
          APU_VIRGL_DB_HDR == {16'd1, APU_VIRGL_OBJ_DSA, APU_VIRGL_BIND_OBJECT} &&
          APU_VIRGL_DS_HANDLE == 32'd8 &&
          APU_VIRGL_RZ_HANDLE == 32'd9 &&
          APU_VIRGL_BL_HANDLE == 32'd7);

    dbr_step(APU_VGPU_DBR_EMPTY, "dbr empty");
    good_in();
    rzr = '0;
    dbr_step(APU_VGPU_DBR_EMPTY, "rasterizer missing");
    good_in();
    fet.beats = 6'd0;
    dbr_step(APU_VGPU_DBR_FAULT, "bad identity");
    good_in();
    rzr.handle = APU_VIRGL_DS_HANDLE;
    dbr_step(APU_VGPU_DBR_FAULT, "bad rasterizer");
    good_in();
    fail_next = 1'b1;
    dbr_step(APU_VGPU_DBR_FAULT, "bad beat");
    bad_hdr = 1'b1;
    dbr_step(APU_VGPU_DBR_FAULT, "bad hdr");
    bad_handle = 1'b1;
    dbr_step(APU_VGPU_DBR_FAULT, "bad handle");
    dbr_step(APU_VGPU_DBR_OK, "depth stencil");
    dbr_step(APU_VGPU_DBR_FAULT, "depth stencil again");
    check("depth stencil stays", ds_ok(dbr) && rzr.handle == APU_VIRGL_RZ_HANDLE &&
          dbr.handle != rzr.handle);
    dbk_step(APU_VGPU_DBK_OK, "keep depth stencil");
    check("depth stencil kept", dbk.valid && dbk.hdr == APU_VIRGL_DB_HDR &&
          dbk.handle == APU_VIRGL_DS_HANDLE && dbk.hdr != dbk.handle &&
          dbk.handle != rzr.handle);
    dbk_step(APU_VGPU_DBK_FAULT, "depth stencil keep again");
    check("depth stencil keep stays", dbk.hdr == APU_VIRGL_DB_HDR &&
          dbk.handle == APU_VIRGL_DS_HANDLE);

    pulse_reset();
    check("reset clears", dbr == '0 && dbk == '0);
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
    dbr_step(APU_VGPU_DBR_EMPTY, "after reset");
    dbk_step(APU_VGPU_DBK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu dbr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_dbr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
