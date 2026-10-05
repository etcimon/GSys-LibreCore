// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qsr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qsx_t qsx;
  logic qsr_req = 0, qsr_rdy, qsr_cpl_v, qsr_cpl_r = 0;
  apu_vgpu_qsr_cpl_t qsr_cpl;
  apu_vgpu_qsr_t qsr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qsl_req = 0, qsl_rdy, qsl_cpl_v, qsl_cpl_r = 0;
  apu_vgpu_qsl_cpl_t qsl_cpl;
  apu_vgpu_qsl_t qsl;
  logic qsy_req = 0, qsy_rdy, qsy_cpl_v, qsy_cpl_r = 0;
  apu_vgpu_qsy_cpl_t qsy_cpl, off_cpl;
  apu_vgpu_qsy_t qsy, off_qsy;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_desc = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QRG_WORD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qsr #(.Enable(1'b1)) i_qsr (
    .clk_i(clk), .rst_ni, .qsx_i(qsx),
    .req_valid_i(qsr_req), .req_ready_o(qsr_rdy),
    .cpl_valid_o(qsr_cpl_v), .cpl_ready_i(qsr_cpl_r), .cpl_o(qsr_cpl), .qsr_o(qsr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qsl #(.Enable(1'b1)) i_qsl (
    .clk_i(clk), .rst_ni, .qsr_i(qsr), .qsx_i(qsx),
    .req_valid_i(qsl_req), .req_ready_o(qsl_rdy),
    .cpl_valid_o(qsl_cpl_v), .cpl_ready_i(qsl_cpl_r), .cpl_o(qsl_cpl), .qsl_o(qsl)
  );
  g6lc_apu_vgpu_qsy #(.Enable(1'b1)) i_qsy (
    .clk_i(clk), .rst_ni, .qsl_i(qsl), .qsr_i(qsr), .qsx_i(qsx),
    .req_valid_i(qsy_req), .req_ready_o(qsy_rdy),
    .cpl_valid_o(qsy_cpl_v), .cpl_ready_i(qsy_cpl_r), .cpl_o(qsy_cpl), .qsy_o(qsy)
  );
  g6lc_apu_vgpu_qsy_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qsl_i(qsl), .qsr_i(qsr), .qsx_i(qsx),
    .req_valid_i(qsy_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qsy_cpl_r), .cpl_o(off_cpl), .qsy_o(off_qsy)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qsr timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_desc) beat[31:0] = APU_VGPU_QRG_BAD;
      if (rd_addr != APU_VGPU_QSR_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_desc <= 1'b0;
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
    qsx = '0;
    qsx.valid = 1'b1;
    qsx.avail_idx = APU_VGPU_QSV_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qsy == '0 &&
          off_cpl == '0);
  endtask

  task automatic qsr_step(input apu_vgpu_qsr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qsr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qsr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsr_req = 1'b0;
    while (!qsr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QSR_OK) begin
      check("ring name", qsr.valid && qsr.desc_id == 16'd0 &&
            qsr.desc_id != 16'd1 &&
            qsr.addr == APU_VGPU_QSR_ADDR &&
            qsr.addr != APU_VGPU_QRG_ADDR &&
            qsr.addr != APU_VGPU_QSV_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QSR_ADDR && rd_seen != APU_VGPU_QRG_ADDR);
    end else if (name == "bad beat" || name == "bad desc") begin
      check("one read failed", nread == n0 + 1 && !qsr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qsr_cpl_v);
    qsr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsr_cpl_r = 1'b0;
    while (qsr_cpl_v) @(negedge clk);
  endtask

  task automatic qsl_step(input apu_vgpu_qsl_status_e st, input string name);
    @(negedge clk);
    while (!qsl_rdy) @(negedge clk);
    cases++;
    qsl_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsl_req = 1'b0;
    while (!qsl_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsl_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qsl_cpl_v);
    qsl_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsl_cpl_r = 1'b0;
    while (qsl_cpl_v) @(negedge clk);
  endtask

  task automatic qsy_step(input apu_vgpu_qsy_status_e st, input string name);
    @(negedge clk);
    while (!qsy_rdy) @(negedge clk);
    cases++;
    qsy_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsy_req = 1'b0;
    while (!qsy_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsy_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qsy_cpl_v);
    qsy_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsy_cpl_r = 1'b0;
    while (qsy_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qsr_req = 1'b0;
    qsl_req = 1'b0;
    qsy_req = 1'b0;
    qsr_cpl_r = 1'b0;
    qsl_cpl_r = 1'b0;
    qsy_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qsx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qsr == '0 && qsl == '0 && qsy == '0);
    check("profiles keep the scene ring peek off",
          !ApuOff.QsrEn && !ApuOff.QslEn && !ApuOff.QsyEn &&
          !ApuP1Transport.QsrEn && !ApuP1Transport.QslEn &&
          !ApuP1Transport.QsyEn &&
          !ApuHarness.QsrEn && !ApuHarness.QslEn && !ApuHarness.QsyEn &&
          !ApuSchedBoth.QsrEn && !ApuSchedBoth.QslEn && !ApuSchedBoth.QsyEn &&
          !ApuBadVirglGrant.QsrEn && !ApuBadVirglGrant.QslEn &&
          !ApuBadVirglGrant.QsyEn);
    cfg = ApuP1Transport;
    cfg.QsrEn = 1'b1;
    cfg.QslEn = 1'b1;
    cfg.QsyEn = 1'b1;
    check("scene ring does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QsrEn = 1'b1;
    cfg.QslEn = 1'b1;
    cfg.QsyEn = 1'b1;
    check("scene ring does not legalize virgl", !apu_cfg_legal(cfg));
    check("scene ring places",
          APU_VGPU_QSR_ADDR == 64'h8800E204 &&
          APU_VGPU_QSR_ADDR == APU_VGPU_QRG_SCENE &&
          APU_VGPU_QSR_ADDR != APU_VGPU_QRG_ADDR &&
          APU_VGPU_QSR_ADDR != APU_VGPU_QSV_ADDR &&
          APU_VGPU_QRG_DESC == 16'd0 &&
          APU_VGPU_QRG_WORD == 32'h00070000 &&
          APU_VGPU_QRG_BAD == 32'h00070001);

    qsr_step(APU_VGPU_QSR_EMPTY, "read empty");
    qsl_step(APU_VGPU_QSL_EMPTY, "keep empty");
    qsy_step(APU_VGPU_QSY_EMPTY, "check empty");
    good_in();
    qsx.avail_idx = 16'd2;
    qsr_step(APU_VGPU_QSR_FAULT, "xfer index");
    good_in();
    fail_rd = 1'b1;
    qsr_step(APU_VGPU_QSR_FAULT, "bad beat");
    bad_desc = 1'b1;
    qsr_step(APU_VGPU_QSR_FAULT, "bad desc");
    qsr_step(APU_VGPU_QSR_OK, "ring name");
    qsr_step(APU_VGPU_QSR_FAULT, "ring again");
    check("ring stays", qsr.valid && qsr.desc_id == 16'd0 &&
          qsr.addr == APU_VGPU_QSR_ADDR);
    qsx.avail_idx = 16'd2;
    qsl_step(APU_VGPU_QSL_FAULT, "keep xfer index");
    check("keep rejected", !qsl.valid);
    good_in();
    qsl_step(APU_VGPU_QSL_OK, "keep name");
    check("name kept", qsl.valid && qsl.desc_id == 16'd0 &&
          qsl.addr == APU_VGPU_QSR_ADDR);
    qsl_step(APU_VGPU_QSL_FAULT, "keep again");
    qsx.avail_idx = 16'd2;
    qsy_step(APU_VGPU_QSY_FAULT, "check xfer index");
    check("check rejected", !qsy.valid);
    good_in();
    qsy_step(APU_VGPU_QSY_OK, "check name");
    check("name checked", qsy.valid && qsy.desc_id == 16'd0);
    qsy_step(APU_VGPU_QSY_FAULT, "check again");
    check("check stays", qsy.desc_id == qsr.desc_id);

    pulse_reset();
    check("reset clears", qsr == '0 && qsl == '0 && qsy == '0);
    qsx = '0;
    qsr_step(APU_VGPU_QSR_EMPTY, "after reset");
    good_in();
    qsr_step(APU_VGPU_QSR_OK, "ring after reset");

    if (errors != 0) $fatal(1, "APU vgpu qsr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qsr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
