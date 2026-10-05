// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qsv;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qay_t qay;
  apu_vgpu_qnx_t qnx;
  logic qsv_req = 0, qsv_rdy, qsv_cpl_v, qsv_cpl_r = 0;
  apu_vgpu_qsv_cpl_t qsv_cpl;
  apu_vgpu_qsv_t qsv;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qsk_req = 0, qsk_rdy, qsk_cpl_v, qsk_cpl_r = 0;
  apu_vgpu_qsk_cpl_t qsk_cpl;
  apu_vgpu_qsk_t qsk;
  logic qsx_req = 0, qsx_rdy, qsx_cpl_v, qsx_cpl_r = 0;
  apu_vgpu_qsx_cpl_t qsx_cpl, off_cpl;
  apu_vgpu_qsx_t qsx, off_qsx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_idx = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QSV_WORD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qsv #(.Enable(1'b1)) i_qsv (
    .clk_i(clk), .rst_ni, .qay_i(qay), .qnx_i(qnx),
    .req_valid_i(qsv_req), .req_ready_o(qsv_rdy),
    .cpl_valid_o(qsv_cpl_v), .cpl_ready_i(qsv_cpl_r), .cpl_o(qsv_cpl), .qsv_o(qsv),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qsk #(.Enable(1'b1)) i_qsk (
    .clk_i(clk), .rst_ni, .qsv_i(qsv), .qay_i(qay), .qnx_i(qnx),
    .req_valid_i(qsk_req), .req_ready_o(qsk_rdy),
    .cpl_valid_o(qsk_cpl_v), .cpl_ready_i(qsk_cpl_r), .cpl_o(qsk_cpl), .qsk_o(qsk)
  );
  g6lc_apu_vgpu_qsx #(.Enable(1'b1)) i_qsx (
    .clk_i(clk), .rst_ni, .qsk_i(qsk), .qsv_i(qsv), .qay_i(qay), .qnx_i(qnx),
    .req_valid_i(qsx_req), .req_ready_o(qsx_rdy),
    .cpl_valid_o(qsx_cpl_v), .cpl_ready_i(qsx_cpl_r), .cpl_o(qsx_cpl), .qsx_o(qsx)
  );
  g6lc_apu_vgpu_qsx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qsk_i(qsk), .qsv_i(qsv), .qay_i(qay), .qnx_i(qnx),
    .req_valid_i(qsx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qsx_cpl_r), .cpl_o(off_cpl), .qsx_o(off_qsx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qsv timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_idx) beat[31:0] = APU_VGPU_QAV_WORD;
      if (rd_addr != APU_VGPU_QSV_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_idx <= 1'b0;
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
    qay = '0;
    qay.valid = 1'b1;
    qay.ack = APU_VGPU_TIW_REASON;
    qay.remain = APU_VGPU_VAW_CLEAR;
    qay.used_idx = APU_VGPU_TUW_IDXV;
    qnx = '0;
    qnx.valid = 1'b1;
    qnx.qid = APU_VGPU_QNT_QUEUE;
    qnx.avail_idx = APU_VGPU_TUW_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qsx == '0 &&
          off_cpl == '0);
  endtask

  task automatic qsv_step(input apu_vgpu_qsv_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qsv_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qsv_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsv_req = 1'b0;
    while (!qsv_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsv_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QSV_OK) begin
      check("avail idx", qsv.valid && qsv.avail_idx == 16'd1 &&
            qsv.avail_idx != 16'd2 &&
            qsv.addr == APU_VGPU_QSV_ADDR &&
            qsv.addr != APU_VGPU_QAV_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QSV_ADDR && rd_seen != APU_VGPU_QAV_ADDR);
    end else if (name == "bad beat" || name == "xfer word") begin
      check("one read failed", nread == n0 + 1 && !qsv.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qsv_cpl_v);
    qsv_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsv_cpl_r = 1'b0;
    while (qsv_cpl_v) @(negedge clk);
  endtask

  task automatic qsk_step(input apu_vgpu_qsk_status_e st, input string name);
    @(negedge clk);
    while (!qsk_rdy) @(negedge clk);
    cases++;
    qsk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsk_req = 1'b0;
    while (!qsk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qsk_cpl_v);
    qsk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsk_cpl_r = 1'b0;
    while (qsk_cpl_v) @(negedge clk);
  endtask

  task automatic qsx_step(input apu_vgpu_qsx_status_e st, input string name);
    @(negedge clk);
    while (!qsx_rdy) @(negedge clk);
    cases++;
    qsx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsx_req = 1'b0;
    while (!qsx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qsx_cpl_v);
    qsx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsx_cpl_r = 1'b0;
    while (qsx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qsv_req = 1'b0;
    qsk_req = 1'b0;
    qsx_req = 1'b0;
    qsv_cpl_r = 1'b0;
    qsk_cpl_r = 1'b0;
    qsx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qay = '0;
    qnx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qsv == '0 && qsk == '0 && qsx == '0);
    check("profiles keep the scene avail peek off",
          !ApuOff.QsvEn && !ApuOff.QskEn && !ApuOff.QsxEn &&
          !ApuP1Transport.QsvEn && !ApuP1Transport.QskEn &&
          !ApuP1Transport.QsxEn &&
          !ApuHarness.QsvEn && !ApuHarness.QskEn && !ApuHarness.QsxEn &&
          !ApuSchedBoth.QsvEn && !ApuSchedBoth.QskEn && !ApuSchedBoth.QsxEn &&
          !ApuBadVirglGrant.QsvEn && !ApuBadVirglGrant.QskEn &&
          !ApuBadVirglGrant.QsxEn);
    cfg = ApuP1Transport;
    cfg.QsvEn = 1'b1;
    cfg.QskEn = 1'b1;
    cfg.QsxEn = 1'b1;
    check("scene avail does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QsvEn = 1'b1;
    cfg.QskEn = 1'b1;
    cfg.QsxEn = 1'b1;
    check("scene avail does not legalize virgl", !apu_cfg_legal(cfg));
    check("scene avail places",
          APU_VGPU_QSV_ADDR == 64'h8800E200 &&
          APU_VGPU_QSV_ADDR == APU_VGPU_NXC_AVAIL &&
          APU_VGPU_QSV_ADDR != APU_VGPU_QAV_ADDR &&
          APU_VGPU_QSV_WORD == 32'h00010000 &&
          APU_VGPU_QSV_IDXV == 16'd1 &&
          APU_VGPU_QAV_WORD == 32'h00020000);

    qsv_step(APU_VGPU_QSV_EMPTY, "read empty");
    qsk_step(APU_VGPU_QSK_EMPTY, "keep empty");
    qsx_step(APU_VGPU_QSX_EMPTY, "check empty");
    good_in();
    qnx.qid = APU_VGPU_QNT_CURSOR;
    qsv_step(APU_VGPU_QSV_FAULT, "cursor queue");
    qnx.qid = APU_VGPU_QNT_QUEUE;
    qay.used_idx = 16'd1;
    qsv_step(APU_VGPU_QSV_FAULT, "scene used");
    good_in();
    fail_rd = 1'b1;
    qsv_step(APU_VGPU_QSV_FAULT, "bad beat");
    bad_idx = 1'b1;
    qsv_step(APU_VGPU_QSV_FAULT, "xfer word");
    qsv_step(APU_VGPU_QSV_OK, "avail idx");
    qsv_step(APU_VGPU_QSV_FAULT, "avail again");
    check("avail stays", qsv.valid && qsv.avail_idx == 16'd1 &&
          qsv.addr == APU_VGPU_QSV_ADDR);
    qnx.avail_idx = 16'd1;
    qsk_step(APU_VGPU_QSK_FAULT, "keep transfer notify");
    check("keep rejected", !qsk.valid);
    good_in();
    qsk_step(APU_VGPU_QSK_OK, "keep idx");
    check("idx kept", qsk.valid && qsk.avail_idx == 16'd1 &&
          qsk.addr == APU_VGPU_QSV_ADDR);
    qsk_step(APU_VGPU_QSK_FAULT, "keep again");
    qnx.qid = APU_VGPU_QNT_CURSOR;
    qsx_step(APU_VGPU_QSX_FAULT, "check cursor");
    check("check rejected", !qsx.valid);
    good_in();
    qsx_step(APU_VGPU_QSX_OK, "check idx");
    check("idx checked", qsx.valid && qsx.avail_idx == 16'd1);
    qsx_step(APU_VGPU_QSX_FAULT, "check again");
    check("check stays", qsx.avail_idx == qsv.avail_idx);

    pulse_reset();
    check("reset clears", qsv == '0 && qsk == '0 && qsx == '0);
    qay = '0;
    qnx = '0;
    qsv_step(APU_VGPU_QSV_EMPTY, "after reset");
    good_in();
    qsv_step(APU_VGPU_QSV_OK, "avail after reset");

    if (errors != 0) $fatal(1, "APU vgpu qsv errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qsv cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
