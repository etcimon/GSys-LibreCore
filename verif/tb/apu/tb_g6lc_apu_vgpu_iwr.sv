// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_iwr;
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
  logic iwr_req = 0, iwr_rdy, iwr_cpl_v, iwr_cpl_r = 0;
  apu_vgpu_iwr_cpl_t iwr_cpl;
  apu_vgpu_iwr_t iwr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic iwk_req = 0, iwk_rdy, iwk_cpl_v, iwk_cpl_r = 0;
  apu_vgpu_iwk_cpl_t iwk_cpl, off_cpl;
  apu_vgpu_iwk_t iwk, off_iwk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_res = 0, bad_len = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_iwr #(.Enable(1'b1)) i_iwr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf),
    .req_valid_i(iwr_req), .req_ready_o(iwr_rdy),
    .cpl_valid_o(iwr_cpl_v), .cpl_ready_i(iwr_cpl_r), .cpl_o(iwr_cpl), .iwr_o(iwr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_iwk #(.Enable(1'b1)) i_iwk (
    .clk_i(clk), .rst_ni, .iwr_i(iwr), .fet_i(fet), .vbf_i(vbf), .qdr_i(qdr),
    .req_valid_i(iwk_req), .req_ready_o(iwk_rdy),
    .cpl_valid_o(iwk_cpl_v), .cpl_ready_i(iwk_cpl_r), .cpl_o(iwk_cpl), .iwk_o(iwk)
  );
  g6lc_apu_vgpu_iwk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .iwr_i(iwr), .fet_i(fet), .vbf_i(vbf), .qdr_i(qdr),
    .req_valid_i(iwk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(iwk_cpl_r), .cpl_o(off_cpl), .iwk_o(off_iwk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu iwr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      // Sampler-view handle. Not part of the inline write.
      beat_data[63:32] = APU_VIRGL_SV_HANDLE;
      beat_data[95:64] = bad_hdr ? 32'h0 : APU_VIRGL_IW_HDR;
      beat_data[127:96] = bad_res ? 32'h0 : APU_VIRGL_RES_VBO;
    end else begin
      beat_data[127:96] = bad_len ? 32'h0 : APU_VIRGL_VBO_BYTES;
      beat_data[159:128] = 32'd1;
      beat_data[191:160] = 32'd1;
      beat_data[223:192] = APU_VIRGL_F32_NEG_ONE;
      // Second float. Not part of the words this unit checks.
      beat_data[255:224] = APU_VIRGL_F32_NEG_ONE;
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
      want = idx == 0 ? APU_VGPU_IW_ADDR : APU_VGPU_IW_LAST;
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
        bad_res <= 1'b0;
      end
      if (idx == 1) bad_len <= 1'b0;
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
  endtask

  function automatic logic iw_ok(input apu_vgpu_iwr_t rec);
    iw_ok = rec.valid && rec.resource == APU_VIRGL_RES_VBO &&
            rec.nbytes == APU_VIRGL_VBO_BYTES && rec.resource != rec.nbytes;
  endfunction

  task automatic iwr_step(input apu_vgpu_iwr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!iwr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    iwr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    iwr_req = 1'b0;
    while (!iwr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), iwr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_iwk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_IWR_OK) begin
      check("inline write", iw_ok(iwr));
      check("read count", nread == n0 + 2 && !order_bad &&
            seen_first == APU_VGPU_IW_ADDR && seen_last == APU_VGPU_IW_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad res") begin
      check("one beat", nread == n0 + 1 && !iwr.valid);
    end else if (name == "bad len") begin
      check("two beats", nread == n0 + 2 && !iwr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), iwr_cpl_v);
    iwr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    iwr_cpl_r = 1'b0;
    while (iwr_cpl_v) @(negedge clk);
  endtask

  task automatic iwk_step(input apu_vgpu_iwk_status_e st, input string name);
    @(negedge clk);
    while (!iwk_rdy) @(negedge clk);
    cases++;
    iwk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    iwk_req = 1'b0;
    while (!iwk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), iwk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_iwk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), iwk_cpl_v);
    iwk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    iwk_cpl_r = 1'b0;
    while (iwk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    iwr_req = 1'b0;
    iwk_req = 1'b0;
    iwr_cpl_r = 1'b0;
    iwk_cpl_r = 1'b0;
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
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && iwr == '0 &&
          iwk == '0);
    check("profiles keep the inline write off",
          !ApuOff.IwrEn && !ApuOff.IwkEn &&
          !ApuP1Transport.IwrEn && !ApuP1Transport.IwkEn &&
          !ApuHarness.IwrEn && !ApuHarness.IwkEn &&
          !ApuSchedBoth.IwrEn && !ApuSchedBoth.IwkEn &&
          !ApuBadVirglGrant.IwrEn && !ApuBadVirglGrant.IwkEn);
    cfg = ApuP1Transport;
    cfg.IwrEn = 1'b1;
    cfg.IwkEn = 1'b1;
    check("inline write does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.IwrEn = 1'b1;
    cfg.IwkEn = 1'b1;
    check("inline write does not legalize virgl", !apu_cfg_legal(cfg));
    check("iw place", APU_VGPU_IW_BEAT == 6'd20 &&
          APU_VGPU_IW_ADDR == 64'h8800B280 &&
          APU_VGPU_IW_LAST == 64'h8800B2A0 &&
          APU_VGPU_IW_LAST == APU_VGPU_QUAD_ADDR &&
          APU_VIRGL_IW_AT == 32'd648 &&
          APU_VIRGL_IW_HDR == 32'h00230009 &&
          APU_VIRGL_VBO_BYTES == 32'd96 &&
          APU_VIRGL_RES_VBO == 32'd3 &&
          APU_VIRGL_SV_HANDLE == 32'd5);

    iwr_step(APU_VGPU_IWR_EMPTY, "iwr empty");
    good_in();
    vbf = '0;
    iwr_step(APU_VGPU_IWR_EMPTY, "vertex buffer missing");
    good_in();
    fet.beats = 6'd0;
    iwr_step(APU_VGPU_IWR_FAULT, "bad identity");
    good_in();
    fail_next = 1'b1;
    iwr_step(APU_VGPU_IWR_FAULT, "bad beat");
    bad_hdr = 1'b1;
    iwr_step(APU_VGPU_IWR_FAULT, "bad hdr");
    bad_res = 1'b1;
    iwr_step(APU_VGPU_IWR_FAULT, "bad res");
    bad_len = 1'b1;
    iwr_step(APU_VGPU_IWR_FAULT, "bad len");
    iwr_step(APU_VGPU_IWR_OK, "inline write");
    iwr_step(APU_VGPU_IWR_FAULT, "inline write again");
    check("inline write stays", iw_ok(iwr) && vbf.resource == iwr.resource);
    iwk_step(APU_VGPU_IWK_OK, "keep inline write");
    check("inline write kept", iwk.valid && iwk.resource == 32'd3 &&
          iwk.nbytes == 32'd96 && iwk.resource != iwk.nbytes);
    iwk_step(APU_VGPU_IWK_FAULT, "inline write keep again");
    check("inline write keep stays", iwk.resource == 32'd3 && iwk.nbytes == 32'd96);

    pulse_reset();
    check("reset clears", iwr == '0 && iwk == '0);
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr = '0;
    cwr = '0;
    fbr = '0;
    vbf = '0;
    iwr_step(APU_VGPU_IWR_EMPTY, "after reset");
    iwk_step(APU_VGPU_IWK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu iwr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_iwr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
