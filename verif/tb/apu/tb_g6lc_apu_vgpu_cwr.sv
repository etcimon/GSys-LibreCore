// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_cwr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fet_t fet;
  apu_vgpu_drd_t drd;
  apu_vgpu_qdr_t qdr;
  apu_vgpu_vwx_t vwx;
  apu_vgpu_cxr_t cxr;
  logic cwr_req = 0, cwr_rdy, cwr_cpl_v, cwr_cpl_r = 0;
  apu_vgpu_cwr_cpl_t cwr_cpl;
  apu_vgpu_cwr_t cwr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic cwk_req = 0, cwk_rdy, cwk_cpl_v, cwk_cpl_r = 0;
  apu_vgpu_cwk_cpl_t cwk_cpl, off_cpl;
  apu_vgpu_cwk_t cwk, off_cwk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_red = 0, bad_depth = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_cwr #(.Enable(1'b1)) i_cwr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr),
    .req_valid_i(cwr_req), .req_ready_o(cwr_rdy),
    .cpl_valid_o(cwr_cpl_v), .cpl_ready_i(cwr_cpl_r), .cpl_o(cwr_cpl), .cwr_o(cwr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_cwk #(.Enable(1'b1)) i_cwk (
    .clk_i(clk), .rst_ni, .cwr_i(cwr), .fet_i(fet), .cxr_i(cxr),
    .req_valid_i(cwk_req), .req_ready_o(cwk_rdy),
    .cpl_valid_o(cwk_cpl_v), .cpl_ready_i(cwk_cpl_r), .cpl_o(cwk_cpl), .cwk_o(cwk)
  );
  g6lc_apu_vgpu_cwk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cwr_i(cwr), .fet_i(fet), .cxr_i(cxr),
    .req_valid_i(cwk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cwk_cpl_r), .cpl_o(off_cpl), .cwk_o(off_cwk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu cwr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      // Framebuffer surface handle. Not part of the clear.
      beat_data[63:32] = APU_VIRGL_SURFACE_HANDLE;
      beat_data[95:64] = bad_hdr ? 32'h0 : APU_VIRGL_CLR_HDR;
      beat_data[127:96] = APU_VIRGL_CLEAR_COLOR;
      beat_data[159:128] = bad_red ? 32'h0 : APU_VIRGL_F32_P05;
      beat_data[191:160] = APU_VIRGL_F32_P05;
      beat_data[223:192] = APU_VIRGL_F32_P10;
      beat_data[255:224] = APU_VIRGL_F32_ONE;
    end else begin
      beat_data[63:32] = bad_depth ? 32'h0 : APU_VIRGL_DEPTH_HI;
      // Draw header follows the clear and is not part of it.
      beat_data[127:96] = APU_VIRGL_DRAW_HDR;
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
      want = idx == 0 ? APU_VGPU_CLR_ADDR : APU_VGPU_CLR_LAST;
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
        bad_red <= 1'b0;
      end
      if (idx == 1) bad_depth <= 1'b0;
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
  endtask

  function automatic logic color_ok(input apu_vgpu_cwr_t rec);
    color_ok = rec.valid && rec.red == APU_VIRGL_F32_P05 &&
               rec.blue == APU_VIRGL_F32_P10 && rec.word == APU_VGPU_CLEAR_WORD &&
               rec.red != rec.blue && rec.word != rec.red;
  endfunction

  task automatic cwr_step(input apu_vgpu_cwr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!cwr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    cwr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cwr_req = 1'b0;
    while (!cwr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cwr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_cwk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_CWR_OK) begin
      check("clear", color_ok(cwr));
      check("read count", nread == n0 + 2 && !order_bad &&
            seen_first == APU_VGPU_CLR_ADDR && seen_last == APU_VGPU_CLR_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad red") begin
      check("one beat", nread == n0 + 1 && !cwr.valid);
    end else if (name == "bad depth") begin
      check("two beats", nread == n0 + 2 && !cwr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), cwr_cpl_v);
    cwr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cwr_cpl_r = 1'b0;
    while (cwr_cpl_v) @(negedge clk);
  endtask

  task automatic cwk_step(input apu_vgpu_cwk_status_e st, input string name);
    @(negedge clk);
    while (!cwk_rdy) @(negedge clk);
    cases++;
    cwk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cwk_req = 1'b0;
    while (!cwk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cwk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_cwk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), cwk_cpl_v);
    cwk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cwk_cpl_r = 1'b0;
    while (cwk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    cwr_req = 1'b0;
    cwk_req = 1'b0;
    cwr_cpl_r = 1'b0;
    cwk_cpl_r = 1'b0;
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
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && cwr == '0 &&
          cwk == '0);
    check("profiles keep the clear off",
          !ApuOff.CwrEn && !ApuOff.CwkEn &&
          !ApuP1Transport.CwrEn && !ApuP1Transport.CwkEn &&
          !ApuHarness.CwrEn && !ApuHarness.CwkEn &&
          !ApuSchedBoth.CwrEn && !ApuSchedBoth.CwkEn &&
          !ApuBadVirglGrant.CwrEn && !ApuBadVirglGrant.CwkEn);
    cfg = ApuP1Transport;
    cfg.CwrEn = 1'b1;
    cfg.CwkEn = 1'b1;
    check("clear does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.CwrEn = 1'b1;
    cfg.CwkEn = 1'b1;
    check("clear does not legalize virgl", !apu_cfg_legal(cfg));
    check("clear place", APU_VGPU_CLR_BEAT == 6'd27 &&
          APU_VGPU_CLR_ADDR == 64'h8800B360 &&
          APU_VGPU_CLR_LAST == 64'h8800B380 &&
          APU_VGPU_CLR_LAST == APU_VGPU_DRAW_ADDR &&
          APU_VIRGL_CLR_AT == 32'd872 &&
          APU_VIRGL_CLR_HDR == 32'h00080007 &&
          APU_VIRGL_F32_P05 == 32'h3d4ccccd &&
          APU_VIRGL_F32_P10 == 32'h3dcccccd &&
          APU_VIRGL_DEPTH_HI == 32'h3ff00000 &&
          APU_VGPU_CLEAR_WORD == 32'hFF1A0D0D &&
          APU_VIRGL_SURFACE_HANDLE == 32'd1);

    cwr_step(APU_VGPU_CWR_EMPTY, "cwr empty");
    good_in();
    cxr = '0;
    cwr_step(APU_VGPU_CWR_EMPTY, "scissor missing");
    good_in();
    fet.beats = 6'd0;
    cwr_step(APU_VGPU_CWR_FAULT, "bad identity");
    good_in();
    fail_next = 1'b1;
    cwr_step(APU_VGPU_CWR_FAULT, "bad beat");
    bad_hdr = 1'b1;
    cwr_step(APU_VGPU_CWR_FAULT, "bad hdr");
    bad_red = 1'b1;
    cwr_step(APU_VGPU_CWR_FAULT, "bad red");
    bad_depth = 1'b1;
    cwr_step(APU_VGPU_CWR_FAULT, "bad depth");
    cwr_step(APU_VGPU_CWR_OK, "clear");
    cwr_step(APU_VGPU_CWR_FAULT, "clear again");
    check("clear stays", color_ok(cwr));
    cwk_step(APU_VGPU_CWK_OK, "keep clear");
    check("clear kept", cwk.valid && cwk.red == APU_VIRGL_F32_P05 &&
          cwk.blue == APU_VIRGL_F32_P10 && cwk.word == APU_VGPU_CLEAR_WORD);
    cwk_step(APU_VGPU_CWK_FAULT, "clear keep again");
    check("clear keep stays", cwk.word == APU_VGPU_CLEAR_WORD &&
          cwk.red != cwk.blue);

    pulse_reset();
    check("reset clears", cwr == '0 && cwk == '0);
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr = '0;
    cwr_step(APU_VGPU_CWR_EMPTY, "after reset");
    cwk_step(APU_VGPU_CWK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu cwr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_cwr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
