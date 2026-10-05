// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qfd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qhx_t qhx;
  logic qfd_req = 0, qfd_rdy, qfd_cpl_v, qfd_cpl_r = 0;
  apu_vgpu_qfd_cpl_t qfd_cpl;
  apu_vgpu_qfd_t qfd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qfk_req = 0, qfk_rdy, qfk_cpl_v, qfk_cpl_r = 0;
  apu_vgpu_qfk_cpl_t qfk_cpl;
  apu_vgpu_qfk_t qfk;
  logic qfx_req = 0, qfx_rdy, qfx_cpl_v, qfx_cpl_r = 0;
  apu_vgpu_qfx_cpl_t qfx_cpl, off_cpl;
  apu_vgpu_qfx_t qfx, off_qfx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QFD_META,
                                  APU_VGPU_TFB_BYTES, APU_VGPU_TFB_CMD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qfd #(.Enable(1'b1)) i_qfd (
    .clk_i(clk), .rst_ni, .qhx_i(qhx),
    .req_valid_i(qfd_req), .req_ready_o(qfd_rdy),
    .cpl_valid_o(qfd_cpl_v), .cpl_ready_i(qfd_cpl_r), .cpl_o(qfd_cpl), .qfd_o(qfd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qfk #(.Enable(1'b1)) i_qfk (
    .clk_i(clk), .rst_ni, .qfd_i(qfd), .qhx_i(qhx),
    .req_valid_i(qfk_req), .req_ready_o(qfk_rdy),
    .cpl_valid_o(qfk_cpl_v), .cpl_ready_i(qfk_cpl_r), .cpl_o(qfk_cpl), .qfk_o(qfk)
  );
  g6lc_apu_vgpu_qfx #(.Enable(1'b1)) i_qfx (
    .clk_i(clk), .rst_ni, .qfk_i(qfk), .qfd_i(qfd), .qhx_i(qhx),
    .req_valid_i(qfx_req), .req_ready_o(qfx_rdy),
    .cpl_valid_o(qfx_cpl_v), .cpl_ready_i(qfx_cpl_r), .cpl_o(qfx_cpl), .qfx_o(qfx)
  );
  g6lc_apu_vgpu_qfx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qfk_i(qfk), .qfd_i(qfd), .qhx_i(qhx),
    .req_valid_i(qfx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qfx_cpl_r), .cpl_o(off_cpl), .qfx_o(off_qfx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qfd timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_ind) beat[127:96] = APU_VGPU_QFD_IND;
      if (bad_len) beat[95:64] = APU_VGPU_RAB_BYTES;
      if (rd_addr != APU_VGPU_QFD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    qhx = '0;
    qhx.valid = 1'b1;
    qhx.att_addr = APU_VGPU_RAB_CMD;
    qhx.nxt = 16'd1;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qfx == '0 &&
          off_cpl == '0);
  endtask

  task automatic qfd_step(input apu_vgpu_qfd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qfd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qfd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qfd_req = 1'b0;
    while (!qfd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qfd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QFD_OK) begin
      check("desc 1", qfd.valid && qfd.xfer_addr == APU_VGPU_TFB_CMD &&
            qfd.xfer_addr != APU_VGPU_RAB_CMD &&
            qfd.xfer_len == APU_VGPU_TFB_BYTES &&
            qfd.nxt == 16'd2 && qfd.nxt != 16'd1);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QFD_ADDR && rd_seen != APU_VGPU_QHD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "attach len") begin
      check("one read failed", nread == n0 + 1 && !qfd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qfd_cpl_v);
    qfd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qfd_cpl_r = 1'b0;
    while (qfd_cpl_v) @(negedge clk);
  endtask

  task automatic qfk_step(input apu_vgpu_qfk_status_e st, input string name);
    @(negedge clk);
    while (!qfk_rdy) @(negedge clk);
    cases++;
    qfk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qfk_req = 1'b0;
    while (!qfk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qfk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qfk_cpl_v);
    qfk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qfk_cpl_r = 1'b0;
    while (qfk_cpl_v) @(negedge clk);
  endtask

  task automatic qfx_step(input apu_vgpu_qfx_status_e st, input string name);
    @(negedge clk);
    while (!qfx_rdy) @(negedge clk);
    cases++;
    qfx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qfx_req = 1'b0;
    while (!qfx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qfx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qfx_cpl_v);
    qfx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qfx_cpl_r = 1'b0;
    while (qfx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qfd_req = 1'b0;
    qfk_req = 1'b0;
    qfx_req = 1'b0;
    qfd_cpl_r = 1'b0;
    qfk_cpl_r = 1'b0;
    qfx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qhx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qfd == '0 && qfk == '0 && qfx == '0);
    check("profiles keep the follow peek off",
          !ApuOff.QfdEn && !ApuOff.QfkEn && !ApuOff.QfxEn &&
          !ApuP1Transport.QfdEn && !ApuP1Transport.QfkEn &&
          !ApuP1Transport.QfxEn &&
          !ApuHarness.QfdEn && !ApuHarness.QfkEn && !ApuHarness.QfxEn &&
          !ApuSchedBoth.QfdEn && !ApuSchedBoth.QfkEn && !ApuSchedBoth.QfxEn &&
          !ApuBadVirglGrant.QfdEn && !ApuBadVirglGrant.QfkEn &&
          !ApuBadVirglGrant.QfxEn);
    cfg = ApuP1Transport;
    cfg.QfdEn = 1'b1;
    cfg.QfkEn = 1'b1;
    cfg.QfxEn = 1'b1;
    check("follow peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QfdEn = 1'b1;
    cfg.QfkEn = 1'b1;
    cfg.QfxEn = 1'b1;
    check("follow peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("follow places",
          APU_VGPU_QFD_ADDR == 64'h880D0010 &&
          APU_VGPU_QFD_ADDR != APU_VGPU_QHD_ADDR &&
          APU_VGPU_QFD_SCENE == 64'h8800E110 &&
          APU_VGPU_QFD_META == {16'd2, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QFD_IND == {16'd2, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QFD_WR == {16'd2, VIRTQ_DESC_F_WRITE});

    qfd_step(APU_VGPU_QFD_EMPTY, "read empty");
    qfk_step(APU_VGPU_QFK_EMPTY, "keep empty");
    qfx_step(APU_VGPU_QFX_EMPTY, "check empty");
    good_in();
    qhx.nxt = 16'd2;
    qfd_step(APU_VGPU_QFD_FAULT, "jump");
    good_in();
    fail_rd = 1'b1;
    qfd_step(APU_VGPU_QFD_FAULT, "bad beat");
    bad_ind = 1'b1;
    qfd_step(APU_VGPU_QFD_FAULT, "indirect");
    bad_len = 1'b1;
    qfd_step(APU_VGPU_QFD_FAULT, "attach len");
    qfd_step(APU_VGPU_QFD_OK, "desc 1");
    qfd_step(APU_VGPU_QFD_FAULT, "desc again");
    check("desc stays", qfd.valid && qfd.xfer_addr == APU_VGPU_TFB_CMD &&
          qfd.nxt == 16'd2);
    qhx.nxt = 16'd2;
    qfk_step(APU_VGPU_QFK_FAULT, "keep jump");
    check("keep rejected", !qfk.valid);
    good_in();
    qfk_step(APU_VGPU_QFK_OK, "keep desc");
    check("desc kept", qfk.valid && qfk.xfer_addr == APU_VGPU_TFB_CMD &&
          qfk.xfer_len == APU_VGPU_TFB_BYTES && qfk.nxt == 16'd2);
    qfk_step(APU_VGPU_QFK_FAULT, "keep again");
    qhx.nxt = 16'd2;
    qfx_step(APU_VGPU_QFX_FAULT, "check jump");
    check("check rejected", !qfx.valid);
    good_in();
    qfx_step(APU_VGPU_QFX_OK, "check desc");
    check("desc checked", qfx.valid && qfx.xfer_addr == APU_VGPU_TFB_CMD &&
          qfx.nxt == 16'd2);
    qfx_step(APU_VGPU_QFX_FAULT, "check again");
    check("check stays", qfx.xfer_addr == qfd.xfer_addr && qfx.nxt == qfd.nxt);

    pulse_reset();
    check("reset clears", qfd == '0 && qfk == '0 && qfx == '0);
    qhx = '0;
    qfd_step(APU_VGPU_QFD_EMPTY, "after reset");
    good_in();
    qfd_step(APU_VGPU_QFD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu qfd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qfd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
