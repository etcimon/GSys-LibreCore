// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_vwx;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fet_t fet;
  apu_vgpu_drd_t drd;
  apu_vgpu_qdr_t qdr;
  logic vwx_req = 0, vwx_rdy, vwx_cpl_v, vwx_cpl_r = 0;
  apu_vgpu_vwx_cpl_t vwx_cpl;
  apu_vgpu_vwx_t vwx;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic vwk_req = 0, vwk_rdy, vwk_cpl_v, vwk_cpl_r = 0;
  apu_vgpu_vwk_cpl_t vwk_cpl, off_cpl;
  apu_vgpu_vwk_t vwk, off_vwk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_scale = 0, bad_off = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] SciHdr = {16'd3, 8'd0, APU_VIRGL_SET_SCISSOR};
  localparam logic [31:0] FboHdr = {16'd3, 8'd0, APU_VIRGL_SET_FRAMEBUFFER};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_vwx #(.Enable(1'b1)) i_vwx (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr),
    .req_valid_i(vwx_req), .req_ready_o(vwx_rdy),
    .cpl_valid_o(vwx_cpl_v), .cpl_ready_i(vwx_cpl_r), .cpl_o(vwx_cpl), .vwx_o(vwx),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_vwk #(.Enable(1'b1)) i_vwk (
    .clk_i(clk), .rst_ni, .vwx_i(vwx), .fet_i(fet), .drd_i(drd), .qdr_i(qdr),
    .req_valid_i(vwk_req), .req_ready_o(vwk_rdy),
    .cpl_valid_o(vwk_cpl_v), .cpl_ready_i(vwk_cpl_r), .cpl_o(vwk_cpl), .vwk_o(vwk)
  );
  g6lc_apu_vgpu_vwk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .vwx_i(vwx), .fet_i(fet), .drd_i(drd), .qdr_i(qdr),
    .req_valid_i(vwk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(vwk_cpl_r), .cpl_o(off_cpl), .vwk_o(off_vwk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu vwx timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      // Vertex-buffer tail and the scissor. Not part of the viewport.
      beat_data[63:32] = APU_VIRGL_RES_VBO;
      beat_data[95:64] = SciHdr;
      beat_data[191:160] = APU_VIRGL_SCISSOR_BOX;
      beat_data[223:192] = bad_hdr ? 32'h0 : APU_VIRGL_VIEW_HDR;
    end else begin
      beat_data[31:0] = bad_scale ? 32'h0 : APU_VIRGL_F32_HALF_W;
      beat_data[63:32] = APU_VIRGL_F32_HALF_H;
      beat_data[95:64] = APU_VIRGL_F32_ONE;
      beat_data[127:96] = bad_off ? 32'h0 : APU_VIRGL_F32_HALF_W;
      beat_data[159:128] = APU_VIRGL_F32_HALF_H;
      // Framebuffer command follows the viewport and is not part of it.
      beat_data[223:192] = FboHdr;
      beat_data[255:224] = 32'd1;
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
      want = idx == 0 ? APU_VGPU_VIEW_ADDR : APU_VGPU_VIEW_LAST;
      if (rd_addr != want) order_bad <= 1'b1;
      if (idx == 0) seen_first <= rd_addr;
      seen_last <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data(idx);
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      if (idx == 0) bad_hdr <= 1'b0;
      if (idx == 1) begin
        bad_scale <= 1'b0;
        bad_off <= 1'b0;
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
  endtask

  function automatic logic window_ok(input apu_vgpu_vwx_t rec);
    window_ok = rec.valid && rec.scale_x == APU_VIRGL_F32_HALF_W &&
                rec.scale_y == APU_VIRGL_F32_HALF_H &&
                rec.x_neg == 16'd0 && rec.y_neg == 16'd0 &&
                rec.x_pos == 16'd640 && rec.y_pos == 16'd480 &&
                rec.x_pos != rec.y_pos;
  endfunction

  task automatic vwx_step(input apu_vgpu_vwx_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!vwx_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    vwx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vwx_req = 1'b0;
    while (!vwx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vwx_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vwk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_VWX_OK) begin
      check("window", window_ok(vwx));
      check("read count", nread == n0 + 2 && !order_bad &&
            seen_first == APU_VGPU_VIEW_ADDR && seen_last == APU_VGPU_VIEW_LAST);
    end else if (name == "bad beat" || name == "bad hdr") begin
      check("one beat", nread == n0 + 1 && !vwx.valid);
    end else if (name == "bad scale" || name == "bad off") begin
      check("two beats", nread == n0 + 2 && !vwx.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), vwx_cpl_v);
    vwx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vwx_cpl_r = 1'b0;
    while (vwx_cpl_v) @(negedge clk);
  endtask

  task automatic vwk_step(input apu_vgpu_vwk_status_e st, input string name);
    @(negedge clk);
    while (!vwk_rdy) @(negedge clk);
    cases++;
    vwk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vwk_req = 1'b0;
    while (!vwk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vwk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vwk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), vwk_cpl_v);
    vwk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vwk_cpl_r = 1'b0;
    while (vwk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    vwx_req = 1'b0;
    vwk_req = 1'b0;
    vwx_cpl_r = 1'b0;
    vwk_cpl_r = 1'b0;
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
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && vwx == '0 &&
          vwk == '0);
    check("profiles keep the viewport off",
          !ApuOff.VwxEn && !ApuOff.VwkEn &&
          !ApuP1Transport.VwxEn && !ApuP1Transport.VwkEn &&
          !ApuHarness.VwxEn && !ApuHarness.VwkEn &&
          !ApuSchedBoth.VwxEn && !ApuSchedBoth.VwkEn &&
          !ApuBadVirglGrant.VwxEn && !ApuBadVirglGrant.VwkEn);
    cfg = ApuP1Transport;
    cfg.VwxEn = 1'b1;
    cfg.VwkEn = 1'b1;
    check("viewport does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VwxEn = 1'b1;
    cfg.VwkEn = 1'b1;
    check("viewport does not legalize virgl", !apu_cfg_legal(cfg));
    check("view place", APU_VGPU_VIEW_BEAT == 6'd25 &&
          APU_VGPU_VIEW_ADDR == 64'h8800B320 &&
          APU_VGPU_VIEW_LAST == 64'h8800B340 &&
          APU_VIRGL_VIEW_AT == 32'd824 &&
          APU_VIRGL_VIEW_HDR == 32'h00070004 &&
          APU_VIRGL_F32_HALF_W == 32'h43a00000 &&
          APU_VIRGL_F32_HALF_H == 32'h43700000 &&
          APU_VGPU_RT_W == 32'd640 && APU_VGPU_RT_H == 32'd480 &&
          SciHdr == 32'h0003000F && FboHdr == 32'h00030005 &&
          APU_VIRGL_SCISSOR_BOX == 32'h01E00280);

    vwx_step(APU_VGPU_VWX_EMPTY, "vwx empty");
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
    drd.valid = 1'b1;
    drd.count = APU_VIRGL_VERT_COUNT;
    drd.prim = APU_VIRGL_PRIM_STRIP;
    vwx_step(APU_VGPU_VWX_EMPTY, "quad missing");
    good_in();
    fet.beats = 6'd0;
    vwx_step(APU_VGPU_VWX_FAULT, "bad identity");
    good_in();
    fail_next = 1'b1;
    vwx_step(APU_VGPU_VWX_FAULT, "bad beat");
    bad_hdr = 1'b1;
    vwx_step(APU_VGPU_VWX_FAULT, "bad hdr");
    bad_scale = 1'b1;
    vwx_step(APU_VGPU_VWX_FAULT, "bad scale");
    bad_off = 1'b1;
    vwx_step(APU_VGPU_VWX_FAULT, "bad off");
    vwx_step(APU_VGPU_VWX_OK, "window");
    vwx_step(APU_VGPU_VWX_FAULT, "window again");
    check("window stays", window_ok(vwx));
    vwk_step(APU_VGPU_VWK_OK, "keep window");
    check("window kept", vwk.valid && vwk.x_neg == 16'd0 && vwk.y_neg == 16'd0 &&
          vwk.x_pos == 16'd640 && vwk.y_pos == 16'd480 &&
          vwk.scale_x == APU_VIRGL_F32_HALF_W && vwk.scale_y == APU_VIRGL_F32_HALF_H);
    vwk_step(APU_VGPU_VWK_FAULT, "window keep again");
    check("window keep stays", vwk.x_pos == 16'd640 && vwk.y_pos == 16'd480);

    pulse_reset();
    check("reset clears", vwx == '0 && vwk == '0);
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx_step(APU_VGPU_VWX_EMPTY, "after reset");
    vwk_step(APU_VGPU_VWK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu vwx errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_vwx cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
