// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qwd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qfx_t qfx;
  logic qwd_req = 0, qwd_rdy, qwd_cpl_v, qwd_cpl_r = 0;
  apu_vgpu_qwd_cpl_t qwd_cpl;
  apu_vgpu_qwd_t qwd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qwk_req = 0, qwk_rdy, qwk_cpl_v, qwk_cpl_r = 0;
  apu_vgpu_qwk_cpl_t qwk_cpl;
  apu_vgpu_qwk_t qwk;
  logic qwx_req = 0, qwx_rdy, qwx_cpl_v, qwx_cpl_r = 0;
  apu_vgpu_qwx_cpl_t qwx_cpl, off_cpl;
  apu_vgpu_qwx_t qwx, off_qwx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QWD_META,
                                  APU_VGPU_QWD_LEN, APU_VGPU_RFW_ADDR};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qwd #(.Enable(1'b1)) i_qwd (
    .clk_i(clk), .rst_ni, .qfx_i(qfx),
    .req_valid_i(qwd_req), .req_ready_o(qwd_rdy),
    .cpl_valid_o(qwd_cpl_v), .cpl_ready_i(qwd_cpl_r), .cpl_o(qwd_cpl), .qwd_o(qwd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qwk #(.Enable(1'b1)) i_qwk (
    .clk_i(clk), .rst_ni, .qwd_i(qwd), .qfx_i(qfx),
    .req_valid_i(qwk_req), .req_ready_o(qwk_rdy),
    .cpl_valid_o(qwk_cpl_v), .cpl_ready_i(qwk_cpl_r), .cpl_o(qwk_cpl), .qwk_o(qwk)
  );
  g6lc_apu_vgpu_qwx #(.Enable(1'b1)) i_qwx (
    .clk_i(clk), .rst_ni, .qwk_i(qwk), .qwd_i(qwd), .qfx_i(qfx),
    .req_valid_i(qwx_req), .req_ready_o(qwx_rdy),
    .cpl_valid_o(qwx_cpl_v), .cpl_ready_i(qwx_cpl_r), .cpl_o(qwx_cpl), .qwx_o(qwx)
  );
  g6lc_apu_vgpu_qwx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qwk_i(qwk), .qwd_i(qwd), .qfx_i(qfx),
    .req_valid_i(qwx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qwx_cpl_r), .cpl_o(off_cpl), .qwx_o(off_qwx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qwd timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_ind) beat[127:96] = APU_VGPU_QWD_IND;
      if (bad_len) beat[95:64] = APU_VGPU_TFB_BYTES;
      if (rd_addr != APU_VGPU_QWD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_ind <= 1'b0;
      bad_len <= 1'b0;
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
    qfx = '0;
    qfx.valid = 1'b1;
    qfx.xfer_addr = APU_VGPU_TFB_CMD;
    qfx.nxt = 16'd2;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qwx == '0 &&
          off_cpl == '0);
  endtask

  task automatic qwd_step(input apu_vgpu_qwd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qwd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qwd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qwd_req = 1'b0;
    while (!qwd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qwd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QWD_OK) begin
      check("desc 2", qwd.valid && qwd.rsp_addr == APU_VGPU_RFW_ADDR &&
            qwd.rsp_addr != APU_VGPU_TFB_CMD &&
            qwd.rsp_len == APU_VGPU_QWD_LEN);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QWD_ADDR && rd_seen != APU_VGPU_QFD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "xfer len") begin
      check("one read failed", nread == n0 + 1 && !qwd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qwd_cpl_v);
    qwd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qwd_cpl_r = 1'b0;
    while (qwd_cpl_v) @(negedge clk);
  endtask

  task automatic qwk_step(input apu_vgpu_qwk_status_e st, input string name);
    @(negedge clk);
    while (!qwk_rdy) @(negedge clk);
    cases++;
    qwk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qwk_req = 1'b0;
    while (!qwk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qwk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qwk_cpl_v);
    qwk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qwk_cpl_r = 1'b0;
    while (qwk_cpl_v) @(negedge clk);
  endtask

  task automatic qwx_step(input apu_vgpu_qwx_status_e st, input string name);
    @(negedge clk);
    while (!qwx_rdy) @(negedge clk);
    cases++;
    qwx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qwx_req = 1'b0;
    while (!qwx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qwx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qwx_cpl_v);
    qwx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qwx_cpl_r = 1'b0;
    while (qwx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qwd_req = 1'b0;
    qwk_req = 1'b0;
    qwx_req = 1'b0;
    qwd_cpl_r = 1'b0;
    qwk_cpl_r = 1'b0;
    qwx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qfx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qwd == '0 && qwk == '0 && qwx == '0);
    check("profiles keep the write peek off",
          !ApuOff.QwdEn && !ApuOff.QwkEn && !ApuOff.QwxEn &&
          !ApuP1Transport.QwdEn && !ApuP1Transport.QwkEn &&
          !ApuP1Transport.QwxEn &&
          !ApuHarness.QwdEn && !ApuHarness.QwkEn && !ApuHarness.QwxEn &&
          !ApuSchedBoth.QwdEn && !ApuSchedBoth.QwkEn && !ApuSchedBoth.QwxEn &&
          !ApuBadVirglGrant.QwdEn && !ApuBadVirglGrant.QwkEn &&
          !ApuBadVirglGrant.QwxEn);
    cfg = ApuP1Transport;
    cfg.QwdEn = 1'b1;
    cfg.QwkEn = 1'b1;
    cfg.QwxEn = 1'b1;
    check("write peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QwdEn = 1'b1;
    cfg.QwkEn = 1'b1;
    cfg.QwxEn = 1'b1;
    check("write peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("write places",
          APU_VGPU_QWD_ADDR == 64'h880D0020 &&
          APU_VGPU_QWD_ADDR == APU_VGPU_TXC_LAST &&
          APU_VGPU_QWD_SCENE == APU_VGPU_NXC_LAST &&
          APU_VGPU_QWD_META == {16'd0, VIRTQ_DESC_F_WRITE} &&
          APU_VGPU_QWD_NXT == {16'd0, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QWD_IND == {16'd0, VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QWD_LEN == VGPU_RESP_HDR_BYTES);

    qwd_step(APU_VGPU_QWD_EMPTY, "read empty");
    qwk_step(APU_VGPU_QWK_EMPTY, "keep empty");
    qwx_step(APU_VGPU_QWX_EMPTY, "check empty");
    good_in();
    qfx.nxt = 16'd1;
    qwd_step(APU_VGPU_QWD_FAULT, "stay");
    good_in();
    fail_rd = 1'b1;
    qwd_step(APU_VGPU_QWD_FAULT, "bad beat");
    bad_ind = 1'b1;
    qwd_step(APU_VGPU_QWD_FAULT, "indirect");
    bad_len = 1'b1;
    qwd_step(APU_VGPU_QWD_FAULT, "xfer len");
    qwd_step(APU_VGPU_QWD_OK, "desc 2");
    qwd_step(APU_VGPU_QWD_FAULT, "desc again");
    check("desc stays", qwd.valid && qwd.rsp_addr == APU_VGPU_RFW_ADDR &&
          qwd.rsp_len == 32'd24);
    qfx.nxt = 16'd1;
    qwk_step(APU_VGPU_QWK_FAULT, "keep stay");
    check("keep rejected", !qwk.valid);
    good_in();
    qwk_step(APU_VGPU_QWK_OK, "keep desc");
    check("desc kept", qwk.valid && qwk.rsp_addr == APU_VGPU_RFW_ADDR &&
          qwk.rsp_len == APU_VGPU_QWD_LEN);
    qwk_step(APU_VGPU_QWK_FAULT, "keep again");
    qfx.nxt = 16'd1;
    qwx_step(APU_VGPU_QWX_FAULT, "check stay");
    check("check rejected", !qwx.valid);
    good_in();
    qwx_step(APU_VGPU_QWX_OK, "check desc");
    check("desc checked", qwx.valid && qwx.rsp_addr == APU_VGPU_RFW_ADDR);
    qwx_step(APU_VGPU_QWX_FAULT, "check again");
    check("check stays", qwx.rsp_addr == qwd.rsp_addr);

    pulse_reset();
    check("reset clears", qwd == '0 && qwk == '0 && qwx == '0);
    qfx = '0;
    qwd_step(APU_VGPU_QWD_EMPTY, "after reset");
    good_in();
    qwd_step(APU_VGPU_QWD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu qwd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qwd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
