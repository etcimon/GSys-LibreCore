// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_cxr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fet_t fet;
  apu_vgpu_drd_t drd;
  apu_vgpu_qdr_t qdr;
  apu_vgpu_vwx_t vwx;
  logic cxr_req = 0, cxr_rdy, cxr_cpl_v, cxr_cpl_r = 0;
  apu_vgpu_cxr_cpl_t cxr_cpl;
  apu_vgpu_cxr_t cxr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic cxk_req = 0, cxk_rdy, cxk_cpl_v, cxk_cpl_r = 0;
  apu_vgpu_cxk_cpl_t cxk_cpl, off_cpl;
  apu_vgpu_cxk_t cxk, off_cxk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_box = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_cxr #(.Enable(1'b1)) i_cxr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .req_valid_i(cxr_req), .req_ready_o(cxr_rdy),
    .cpl_valid_o(cxr_cpl_v), .cpl_ready_i(cxr_cpl_r), .cpl_o(cxr_cpl), .cxr_o(cxr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_cxk #(.Enable(1'b1)) i_cxk (
    .clk_i(clk), .rst_ni, .cxr_i(cxr), .fet_i(fet), .drd_i(drd), .qdr_i(qdr),
    .vwx_i(vwx),
    .req_valid_i(cxk_req), .req_ready_o(cxk_rdy),
    .cpl_valid_o(cxk_cpl_v), .cpl_ready_i(cxk_cpl_r), .cpl_o(cxk_cpl), .cxk_o(cxk)
  );
  g6lc_apu_vgpu_cxk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cxr_i(cxr), .fet_i(fet), .drd_i(drd), .qdr_i(qdr),
    .vwx_i(vwx),
    .req_valid_i(cxk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cxk_cpl_r), .cpl_o(off_cpl), .cxk_o(off_cxk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu cxr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data;
    beat_data = '0;
    // Vertex-buffer resource and the viewport header share the beat.
    beat_data[63:32] = APU_VIRGL_RES_VBO;
    beat_data[95:64] = bad_hdr ? 32'h0 : APU_VIRGL_SCI_HDR;
    beat_data[191:160] = bad_box ? 32'h0 : APU_VIRGL_SCISSOR_BOX;
    beat_data[223:192] = APU_VIRGL_VIEW_HDR;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      if (rd_addr != APU_VGPU_SCI_ADDR) order_bad <= 1'b1;
      seen_addr <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data();
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      bad_hdr <= 1'b0;
      bad_box <= 1'b0;
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
    vwx.scale_x = APU_VIRGL_F32_HALF_W;
    vwx.scale_y = APU_VIRGL_F32_HALF_H;
    vwx.x_neg = 16'd0;
    vwx.y_neg = 16'd0;
    vwx.x_pos = 16'd640;
    vwx.y_pos = 16'd480;
  endtask

  function automatic logic box_ok(input apu_vgpu_cxr_t rec);
    box_ok = rec.valid && rec.width == 16'd640 && rec.height == 16'd480 &&
             rec.width != rec.height;
  endfunction

  task automatic cxr_step(input apu_vgpu_cxr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!cxr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    cxr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cxr_req = 1'b0;
    while (!cxr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cxr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_cxk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_CXR_OK) begin
      check("scissor", box_ok(cxr));
      check("read count", nread == n0 + 1 && !order_bad &&
            seen_addr == APU_VGPU_SCI_ADDR);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad box") begin
      check("one beat", nread == n0 + 1 && !cxr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), cxr_cpl_v);
    cxr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cxr_cpl_r = 1'b0;
    while (cxr_cpl_v) @(negedge clk);
  endtask

  task automatic cxk_step(input apu_vgpu_cxk_status_e st, input string name);
    @(negedge clk);
    while (!cxk_rdy) @(negedge clk);
    cases++;
    cxk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cxk_req = 1'b0;
    while (!cxk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cxk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_cxk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), cxk_cpl_v);
    cxk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cxk_cpl_r = 1'b0;
    while (cxk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    cxr_req = 1'b0;
    cxk_req = 1'b0;
    cxr_cpl_r = 1'b0;
    cxk_cpl_r = 1'b0;
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
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && cxr == '0 &&
          cxk == '0);
    check("profiles keep the scissor off",
          !ApuOff.CxrEn && !ApuOff.CxkEn &&
          !ApuP1Transport.CxrEn && !ApuP1Transport.CxkEn &&
          !ApuHarness.CxrEn && !ApuHarness.CxkEn &&
          !ApuSchedBoth.CxrEn && !ApuSchedBoth.CxkEn &&
          !ApuBadVirglGrant.CxrEn && !ApuBadVirglGrant.CxkEn);
    cfg = ApuP1Transport;
    cfg.CxrEn = 1'b1;
    cfg.CxkEn = 1'b1;
    check("scissor does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.CxrEn = 1'b1;
    cfg.CxkEn = 1'b1;
    check("scissor does not legalize virgl", !apu_cfg_legal(cfg));
    check("sci place", APU_VGPU_SCI_ADDR == 64'h8800B320 &&
          APU_VGPU_SCI_ADDR == APU_VGPU_VIEW_ADDR &&
          APU_VIRGL_SCI_AT == 32'd808 &&
          APU_VIRGL_SCI_HDR == 32'h0003000F &&
          APU_VIRGL_SCISSOR_BOX == 32'h01E00280 &&
          APU_VGPU_RT_W == 32'd640 && APU_VGPU_RT_H == 32'd480);

    cxr_step(APU_VGPU_CXR_EMPTY, "cxr empty");
    good_in();
    vwx = '0;
    cxr_step(APU_VGPU_CXR_EMPTY, "window missing");
    good_in();
    vwx.x_pos = 16'd0;
    cxr_step(APU_VGPU_CXR_FAULT, "bad window");
    good_in();
    fet.beats = 6'd0;
    cxr_step(APU_VGPU_CXR_FAULT, "bad identity");
    good_in();
    fail_next = 1'b1;
    cxr_step(APU_VGPU_CXR_FAULT, "bad beat");
    bad_hdr = 1'b1;
    cxr_step(APU_VGPU_CXR_FAULT, "bad hdr");
    bad_box = 1'b1;
    cxr_step(APU_VGPU_CXR_FAULT, "bad box");
    cxr_step(APU_VGPU_CXR_OK, "scissor");
    cxr_step(APU_VGPU_CXR_FAULT, "scissor again");
    check("scissor stays", box_ok(cxr) && vwx.x_pos == cxr.width &&
          vwx.y_pos == cxr.height);
    cxk_step(APU_VGPU_CXK_OK, "keep scissor");
    check("scissor kept", cxk.valid && cxk.width == 16'd640 &&
          cxk.height == 16'd480 && cxk.width != cxk.height);
    cxk_step(APU_VGPU_CXK_FAULT, "scissor keep again");
    check("scissor keep stays", cxk.width == 16'd640 && cxk.height == 16'd480);

    pulse_reset();
    check("reset clears", cxr == '0 && cxk == '0);
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr_step(APU_VGPU_CXR_EMPTY, "after reset");
    cxk_step(APU_VGPU_CXK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu cxr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_cxr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
