// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_wfr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_vak_t vak;
  apu_vgpu_gpk_t gpk;
  apu_vgpu_cwr_t cwr;
  apu_vgpu_cxr_t cxr;
  apu_vgpu_ols_t ols;
  logic wfr_req = 0, wfr_rdy, wfr_cpl_v, wfr_cpl_r = 0;
  apu_vgpu_wfr_cpl_t wfr_cpl;
  apu_vgpu_wfr_t wfr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen0 = 0, seen_last = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic wfk_req = 0, wfk_rdy, wfk_cpl_v, wfk_cpl_r = 0;
  apu_vgpu_wfk_cpl_t wfk_cpl;
  apu_vgpu_wfk_t wfk;
  logic [6:0] px = 0, py = 0;
  logic wfx_req = 0, wfx_rdy, wfx_cpl_v, wfx_cpl_r = 0;
  apu_vgpu_wfx_cpl_t wfx_cpl, off_cpl;
  apu_vgpu_wfx_t wfx, off_wfx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_mid = 0, bad_last = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nread = 0, rd_base = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_wfr #(.Enable(1'b1)) i_wfr (
    .clk_i(clk), .rst_ni, .vak_i(vak), .gpk_i(gpk), .cwr_i(cwr), .cxr_i(cxr),
    .ols_i(ols),
    .req_valid_i(wfr_req), .req_ready_o(wfr_rdy),
    .cpl_valid_o(wfr_cpl_v), .cpl_ready_i(wfr_cpl_r), .cpl_o(wfr_cpl), .wfr_o(wfr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_wfk #(.Enable(1'b1)) i_wfk (
    .clk_i(clk), .rst_ni, .wfr_i(wfr), .vak_i(vak), .gpk_i(gpk), .cwr_i(cwr),
    .req_valid_i(wfk_req), .req_ready_o(wfk_rdy),
    .cpl_valid_o(wfk_cpl_v), .cpl_ready_i(wfk_cpl_r), .cpl_o(wfk_cpl), .wfk_o(wfk)
  );
  g6lc_apu_vgpu_wfx #(.Enable(1'b1)) i_wfx (
    .clk_i(clk), .rst_ni, .wfr_i(wfr), .x_i(px), .y_i(py),
    .req_valid_i(wfx_req), .req_ready_o(wfx_rdy),
    .cpl_valid_o(wfx_cpl_v), .cpl_ready_i(wfx_cpl_r), .cpl_o(wfx_cpl), .wfx_o(wfx)
  );
  g6lc_apu_vgpu_wfx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .wfr_i(wfr), .x_i(px), .y_i(py),
    .req_valid_i(wfx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(wfx_cpl_r), .cpl_o(off_cpl), .wfx_o(off_wfx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu wfr timeout case=%0d r=%0d", cases, nread); end

  function automatic logic [255:0] rd_pat(input int idx);
    rd_pat = Pat;
    if (idx == 1 && bad_mid) rd_pat[31:0] = 32'h0;
    if (idx == 511 && bad_last) rd_pat[31:0] = 32'h0;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nread - rd_base;
      want = APU_VGPU_GPW_ADDR + (64'(idx) << 5);
      if (rd_addr != want || rd_len != 32'(APU_VGPU_BEAT_BYTES)) order_bad <= 1'b1;
      if (idx == 0) seen0 <= rd_addr;
      seen_last <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= rd_pat(idx);
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 1) bad_mid <= 1'b0;
      if (idx == 511) bad_last <= 1'b0;
      nread <= nread + 1;
      rd_rsp_v <= 1'b1;
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
    vak = '0;
    vak.valid = 1'b1;
    vak.ack = APU_VGPU_VIW_REASON;
    vak.remain = APU_VGPU_VAW_CLEAR;
    vak.used_idx = 16'd1;
    gpk = '0;
    gpk.valid = 1'b1;
    gpk.word = APU_VGPU_CLEAR_WORD;
    gpk.first = APU_VGPU_GPW_ADDR;
    gpk.last = APU_VGPU_GPW_TAIL;
    cwr = '0;
    cwr.valid = 1'b1;
    cwr.word = APU_VGPU_CLEAR_WORD;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    ols = '0;
    ols.valid = 1'b1;
    ols.count = 32'h0;
    ols.capset_id = 32'h0;
    ols.resp = VGPU_RESP_OK_NODATA;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_wfx == '0 &&
          off_cpl == '0);
  endtask

  task automatic wfr_step(input apu_vgpu_wfr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!wfr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    wfr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wfr_req = 1'b0;
    while (!wfr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), wfr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_WFR_OK) begin
      check("scan", wfr.valid && wfr.beats == 16'd512 &&
            wfr.word == APU_VGPU_CLEAR_WORD && wfr.pix10 == wfr.word &&
            wfr.pix63 == wfr.word && wfr.base == APU_VGPU_GPW_ADDR &&
            wfr.tail == APU_VGPU_GPW_TAIL);
      check("read count", nread == n0 + 512 && !order_bad &&
            seen0 == APU_VGPU_GPW_ADDR && seen_last == APU_VGPU_GPW_TAIL);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !wfr.valid);
    end else if (name == "bad middle") begin
      check("two beats", nread == n0 + 2 && !wfr.valid);
    end else if (name == "bad last") begin
      check("full walk", nread == n0 + 512 && !wfr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), wfr_cpl_v);
    wfr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wfr_cpl_r = 1'b0;
    while (wfr_cpl_v) @(negedge clk);
  endtask

  task automatic wfk_step(input apu_vgpu_wfk_status_e st, input string name);
    @(negedge clk);
    while (!wfk_rdy) @(negedge clk);
    cases++;
    wfk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wfk_req = 1'b0;
    while (!wfk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), wfk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), wfk_cpl_v);
    wfk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wfk_cpl_r = 1'b0;
    while (wfk_cpl_v) @(negedge clk);
  endtask

  task automatic wfx_step(input apu_vgpu_wfx_status_e st, input string name);
    @(negedge clk);
    while (!wfx_rdy) @(negedge clk);
    cases++;
    wfx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wfx_req = 1'b0;
    while (!wfx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), wfx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), wfx_cpl_v);
    wfx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wfx_cpl_r = 1'b0;
    while (wfx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    wfr_req = 1'b0;
    wfk_req = 1'b0;
    wfx_req = 1'b0;
    wfr_cpl_r = 1'b0;
    wfk_cpl_r = 1'b0;
    wfx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    vak = '0;
    gpk = '0;
    cwr = '0;
    cxr = '0;
    ols = '0;
    px = '0;
    py = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          wfr == '0 && wfk == '0 && wfx == '0);
    check("profiles keep the scan off",
          !ApuOff.WfrEn && !ApuOff.WfkEn && !ApuOff.WfxEn &&
          !ApuP1Transport.WfrEn && !ApuP1Transport.WfkEn && !ApuP1Transport.WfxEn &&
          !ApuHarness.WfrEn && !ApuHarness.WfkEn && !ApuHarness.WfxEn &&
          !ApuSchedBoth.WfrEn && !ApuSchedBoth.WfkEn && !ApuSchedBoth.WfxEn &&
          !ApuBadVirglGrant.WfrEn && !ApuBadVirglGrant.WfkEn &&
          !ApuBadVirglGrant.WfxEn);
    cfg = ApuP1Transport;
    cfg.WfrEn = 1'b1;
    cfg.WfkEn = 1'b1;
    cfg.WfxEn = 1'b1;
    check("scan does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.WfrEn = 1'b1;
    cfg.WfkEn = 1'b1;
    cfg.WfxEn = 1'b1;
    check("scan does not legalize virgl", !apu_cfg_legal(cfg));
    check("scan places",
          APU_VGPU_GPW_ADDR == 64'h88020000 &&
          APU_VGPU_GPW_BEATS == 16'd512 &&
          APU_VGPU_GPW_LAST == 9'd511 &&
          APU_VGPU_GPW_TAIL == 64'h88023FE0 &&
          APU_VGPU_CLEAR_WORD == 32'hFF1A0D0D);

    wfr_step(APU_VGPU_WFR_EMPTY, "scan empty");
    wfk_step(APU_VGPU_WFK_EMPTY, "keep empty");
    wfx_step(APU_VGPU_WFX_EMPTY, "point empty");
    good_in();
    gpk = '0;
    wfr_step(APU_VGPU_WFR_EMPTY, "window missing");
    good_in();
    cxr.height = 16'd64;
    wfr_step(APU_VGPU_WFR_FAULT, "bad scissor");
    good_in();
    vak.remain = 32'h1;
    wfr_step(APU_VGPU_WFR_FAULT, "status still set");
    good_in();
    fail_rd = 1'b1;
    wfr_step(APU_VGPU_WFR_FAULT, "bad beat");
    bad_mid = 1'b1;
    wfr_step(APU_VGPU_WFR_FAULT, "bad middle");
    bad_last = 1'b1;
    wfr_step(APU_VGPU_WFR_FAULT, "bad last");
    wfr_step(APU_VGPU_WFR_OK, "scan");
    wfr_step(APU_VGPU_WFR_FAULT, "scan again");
    check("scan stays", wfr.valid && wfr.word == APU_VGPU_CLEAR_WORD &&
          wfr.pix10 == wfr.word && wfr.pix63 == wfr.word &&
          wfr.beats == 16'd512);
    px = 7'd64;
    py = 7'd0;
    wfx_step(APU_VGPU_WFX_FAULT, "x past");
    px = 7'd0;
    py = 7'd64;
    wfx_step(APU_VGPU_WFX_FAULT, "y past");
    px = 7'd0;
    py = 7'd0;
    wfx_step(APU_VGPU_WFX_OK, "origin");
    check("origin kept", wfx.valid && wfx.word == APU_VGPU_CLEAR_WORD &&
          wfx.x == 7'd0 && wfx.y == 7'd0);
    px = 7'd1;
    wfx_step(APU_VGPU_WFX_FAULT, "origin again");
    check("point stays", wfx.word == APU_VGPU_CLEAR_WORD && wfx.x == 7'd0);
    gpk.word = 32'h0;
    wfk_step(APU_VGPU_WFK_FAULT, "keep bad word");
    check("keep rejected", !wfk.valid);
    gpk.word = APU_VGPU_CLEAR_WORD;
    wfk_step(APU_VGPU_WFK_OK, "keep scan");
    check("scan kept", wfk.valid && wfk.word == APU_VGPU_CLEAR_WORD &&
          wfk.pix10 == wfk.word && wfk.pix63 == wfk.word &&
          wfk.beats == 16'd512);
    wfk_step(APU_VGPU_WFK_FAULT, "keep again");
    check("keep stays", wfk.word == wfr.word && wfk.pix10 == wfr.pix10 &&
          wfk.pix63 == wfr.pix63);

    pulse_reset();
    check("reset clears", wfr == '0 && wfk == '0 && wfx == '0);
    zero_in();
    wfr_step(APU_VGPU_WFR_EMPTY, "after reset");
    wfk_step(APU_VGPU_WFK_EMPTY, "keep after reset");
    wfx_step(APU_VGPU_WFX_EMPTY, "point after reset");

    if (errors != 0) $fatal(1, "APU vgpu wfr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_wfr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
