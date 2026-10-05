// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qhd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qrx_t qrx;
  logic qhd_req = 0, qhd_rdy, qhd_cpl_v, qhd_cpl_r = 0;
  apu_vgpu_qhd_cpl_t qhd_cpl;
  apu_vgpu_qhd_t qhd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qhk_req = 0, qhk_rdy, qhk_cpl_v, qhk_cpl_r = 0;
  apu_vgpu_qhk_cpl_t qhk_cpl;
  apu_vgpu_qhk_t qhk;
  logic qhx_req = 0, qhx_rdy, qhx_cpl_v, qhx_cpl_r = 0;
  apu_vgpu_qhx_cpl_t qhx_cpl, off_cpl;
  apu_vgpu_qhx_t qhx, off_qhx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QHD_META,
                                  APU_VGPU_RAB_BYTES, APU_VGPU_RAB_CMD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qhd #(.Enable(1'b1)) i_qhd (
    .clk_i(clk), .rst_ni, .qrx_i(qrx),
    .req_valid_i(qhd_req), .req_ready_o(qhd_rdy),
    .cpl_valid_o(qhd_cpl_v), .cpl_ready_i(qhd_cpl_r), .cpl_o(qhd_cpl), .qhd_o(qhd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qhk #(.Enable(1'b1)) i_qhk (
    .clk_i(clk), .rst_ni, .qhd_i(qhd), .qrx_i(qrx),
    .req_valid_i(qhk_req), .req_ready_o(qhk_rdy),
    .cpl_valid_o(qhk_cpl_v), .cpl_ready_i(qhk_cpl_r), .cpl_o(qhk_cpl), .qhk_o(qhk)
  );
  g6lc_apu_vgpu_qhx #(.Enable(1'b1)) i_qhx (
    .clk_i(clk), .rst_ni, .qhk_i(qhk), .qhd_i(qhd), .qrx_i(qrx),
    .req_valid_i(qhx_req), .req_ready_o(qhx_rdy),
    .cpl_valid_o(qhx_cpl_v), .cpl_ready_i(qhx_cpl_r), .cpl_o(qhx_cpl), .qhx_o(qhx)
  );
  g6lc_apu_vgpu_qhx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qhk_i(qhk), .qhd_i(qhd), .qrx_i(qrx),
    .req_valid_i(qhx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qhx_cpl_r), .cpl_o(off_cpl), .qhx_o(off_qhx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qhd timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_ind) beat[127:96] = APU_VGPU_QHD_IND;
      if (bad_len) beat[95:64] = APU_VGPU_TFB_BYTES;
      if (rd_addr != APU_VGPU_QHD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    qrx = '0;
    qrx.valid = 1'b1;
    qrx.desc_id = APU_VGPU_QRG_DESC;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qhx == '0 &&
          off_cpl == '0);
  endtask

  task automatic qhd_step(input apu_vgpu_qhd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qhd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qhd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qhd_req = 1'b0;
    while (!qhd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qhd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QHD_OK) begin
      check("desc 0", qhd.valid && qhd.att_addr == APU_VGPU_RAB_CMD &&
            qhd.att_addr != APU_VGPU_NXC_DESC &&
            qhd.att_len == APU_VGPU_RAB_BYTES &&
            qhd.nxt == 16'd1 && qhd.nxt != 16'd2);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QHD_ADDR && rd_seen != APU_VGPU_QHD_SCENE);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "short len") begin
      check("one read failed", nread == n0 + 1 && !qhd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qhd_cpl_v);
    qhd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qhd_cpl_r = 1'b0;
    while (qhd_cpl_v) @(negedge clk);
  endtask

  task automatic qhk_step(input apu_vgpu_qhk_status_e st, input string name);
    @(negedge clk);
    while (!qhk_rdy) @(negedge clk);
    cases++;
    qhk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qhk_req = 1'b0;
    while (!qhk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qhk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qhk_cpl_v);
    qhk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qhk_cpl_r = 1'b0;
    while (qhk_cpl_v) @(negedge clk);
  endtask

  task automatic qhx_step(input apu_vgpu_qhx_status_e st, input string name);
    @(negedge clk);
    while (!qhx_rdy) @(negedge clk);
    cases++;
    qhx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qhx_req = 1'b0;
    while (!qhx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qhx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qhx_cpl_v);
    qhx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qhx_cpl_r = 1'b0;
    while (qhx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qhd_req = 1'b0;
    qhk_req = 1'b0;
    qhx_req = 1'b0;
    qhd_cpl_r = 1'b0;
    qhk_cpl_r = 1'b0;
    qhx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qrx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qhd == '0 && qhk == '0 && qhx == '0);
    check("profiles keep the desc peek off",
          !ApuOff.QhdEn && !ApuOff.QhkEn && !ApuOff.QhxEn &&
          !ApuP1Transport.QhdEn && !ApuP1Transport.QhkEn &&
          !ApuP1Transport.QhxEn &&
          !ApuHarness.QhdEn && !ApuHarness.QhkEn && !ApuHarness.QhxEn &&
          !ApuSchedBoth.QhdEn && !ApuSchedBoth.QhkEn && !ApuSchedBoth.QhxEn &&
          !ApuBadVirglGrant.QhdEn && !ApuBadVirglGrant.QhkEn &&
          !ApuBadVirglGrant.QhxEn);
    cfg = ApuP1Transport;
    cfg.QhdEn = 1'b1;
    cfg.QhkEn = 1'b1;
    cfg.QhxEn = 1'b1;
    check("desc peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QhdEn = 1'b1;
    cfg.QhkEn = 1'b1;
    cfg.QhxEn = 1'b1;
    check("desc peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("desc places",
          APU_VGPU_QHD_ADDR == 64'h880D0000 &&
          APU_VGPU_QHD_ADDR == APU_VGPU_TXC_DESC &&
          APU_VGPU_QHD_SCENE == APU_VGPU_NXC_DESC &&
          APU_VGPU_QHD_META == {16'd1, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QHD_IND == {16'd1, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QHD_JUMP == {16'd2, VIRTQ_DESC_F_NEXT});

    qhd_step(APU_VGPU_QHD_EMPTY, "read empty");
    qhk_step(APU_VGPU_QHK_EMPTY, "keep empty");
    qhx_step(APU_VGPU_QHX_EMPTY, "check empty");
    good_in();
    qrx.desc_id = 16'd1;
    qhd_step(APU_VGPU_QHD_FAULT, "bad id");
    good_in();
    fail_rd = 1'b1;
    qhd_step(APU_VGPU_QHD_FAULT, "bad beat");
    bad_ind = 1'b1;
    qhd_step(APU_VGPU_QHD_FAULT, "indirect");
    bad_len = 1'b1;
    qhd_step(APU_VGPU_QHD_FAULT, "short len");
    qhd_step(APU_VGPU_QHD_OK, "desc 0");
    qhd_step(APU_VGPU_QHD_FAULT, "desc again");
    check("desc stays", qhd.valid && qhd.att_addr == APU_VGPU_RAB_CMD &&
          qhd.nxt == 16'd1);
    qrx.desc_id = 16'd1;
    qhk_step(APU_VGPU_QHK_FAULT, "keep bad id");
    check("keep rejected", !qhk.valid);
    good_in();
    qhk_step(APU_VGPU_QHK_OK, "keep desc");
    check("desc kept", qhk.valid && qhk.att_addr == APU_VGPU_RAB_CMD &&
          qhk.att_len == APU_VGPU_RAB_BYTES && qhk.nxt == 16'd1);
    qhk_step(APU_VGPU_QHK_FAULT, "keep again");
    qrx.desc_id = 16'd1;
    qhx_step(APU_VGPU_QHX_FAULT, "check bad id");
    check("check rejected", !qhx.valid);
    good_in();
    qhx_step(APU_VGPU_QHX_OK, "check desc");
    check("desc checked", qhx.valid && qhx.att_addr == APU_VGPU_RAB_CMD &&
          qhx.nxt == 16'd1);
    qhx_step(APU_VGPU_QHX_FAULT, "check again");
    check("check stays", qhx.att_addr == qhd.att_addr && qhx.nxt == qhd.nxt);

    pulse_reset();
    check("reset clears", qhd == '0 && qhk == '0 && qhx == '0);
    qrx = '0;
    qhd_step(APU_VGPU_QHD_EMPTY, "after reset");
    good_in();
    qhd_step(APU_VGPU_QHD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu qhd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qhd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
