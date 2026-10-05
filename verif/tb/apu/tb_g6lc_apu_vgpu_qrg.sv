// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qrg;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qax_t qax;
  logic qrg_req = 0, qrg_rdy, qrg_cpl_v, qrg_cpl_r = 0;
  apu_vgpu_qrg_cpl_t qrg_cpl;
  apu_vgpu_qrg_t qrg;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qrk_req = 0, qrk_rdy, qrk_cpl_v, qrk_cpl_r = 0;
  apu_vgpu_qrk_cpl_t qrk_cpl;
  apu_vgpu_qrk_t qrk;
  logic qrx_req = 0, qrx_rdy, qrx_cpl_v, qrx_cpl_r = 0;
  apu_vgpu_qrx_cpl_t qrx_cpl, off_cpl;
  apu_vgpu_qrx_t qrx, off_qrx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_desc = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QRG_WORD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qrg #(.Enable(1'b1)) i_qrg (
    .clk_i(clk), .rst_ni, .qax_i(qax),
    .req_valid_i(qrg_req), .req_ready_o(qrg_rdy),
    .cpl_valid_o(qrg_cpl_v), .cpl_ready_i(qrg_cpl_r), .cpl_o(qrg_cpl), .qrg_o(qrg),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qrk #(.Enable(1'b1)) i_qrk (
    .clk_i(clk), .rst_ni, .qrg_i(qrg), .qax_i(qax),
    .req_valid_i(qrk_req), .req_ready_o(qrk_rdy),
    .cpl_valid_o(qrk_cpl_v), .cpl_ready_i(qrk_cpl_r), .cpl_o(qrk_cpl), .qrk_o(qrk)
  );
  g6lc_apu_vgpu_qrx #(.Enable(1'b1)) i_qrx (
    .clk_i(clk), .rst_ni, .qrk_i(qrk), .qrg_i(qrg), .qax_i(qax),
    .req_valid_i(qrx_req), .req_ready_o(qrx_rdy),
    .cpl_valid_o(qrx_cpl_v), .cpl_ready_i(qrx_cpl_r), .cpl_o(qrx_cpl), .qrx_o(qrx)
  );
  g6lc_apu_vgpu_qrx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qrk_i(qrk), .qrg_i(qrg), .qax_i(qax),
    .req_valid_i(qrx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qrx_cpl_r), .cpl_o(off_cpl), .qrx_o(off_qrx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qrg timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_QRG_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
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
    qax = '0;
    qax.valid = 1'b1;
    qax.avail_idx = APU_VGPU_TUW_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qrx == '0 &&
          off_cpl == '0);
  endtask

  task automatic qrg_step(input apu_vgpu_qrg_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qrg_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qrg_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrg_req = 1'b0;
    while (!qrg_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qrg_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QRG_OK) begin
      check("ring name", qrg.valid && qrg.desc_id == 16'd0 &&
            qrg.desc_id != 16'd1 &&
            qrg.addr == APU_VGPU_QRG_ADDR &&
            qrg.addr != APU_VGPU_QRG_SCENE &&
            qrg.addr != APU_VGPU_QAV_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QRG_ADDR && rd_seen != APU_VGPU_QRG_SCENE);
    end else if (name == "bad beat" || name == "bad desc") begin
      check("one read failed", nread == n0 + 1 && !qrg.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qrg_cpl_v);
    qrg_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrg_cpl_r = 1'b0;
    while (qrg_cpl_v) @(negedge clk);
  endtask

  task automatic qrk_step(input apu_vgpu_qrk_status_e st, input string name);
    @(negedge clk);
    while (!qrk_rdy) @(negedge clk);
    cases++;
    qrk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrk_req = 1'b0;
    while (!qrk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qrk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qrk_cpl_v);
    qrk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrk_cpl_r = 1'b0;
    while (qrk_cpl_v) @(negedge clk);
  endtask

  task automatic qrx_step(input apu_vgpu_qrx_status_e st, input string name);
    @(negedge clk);
    while (!qrx_rdy) @(negedge clk);
    cases++;
    qrx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrx_req = 1'b0;
    while (!qrx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qrx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qrx_cpl_v);
    qrx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrx_cpl_r = 1'b0;
    while (qrx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qrg_req = 1'b0;
    qrk_req = 1'b0;
    qrx_req = 1'b0;
    qrg_cpl_r = 1'b0;
    qrk_cpl_r = 1'b0;
    qrx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qax = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qrg == '0 && qrk == '0 && qrx == '0);
    check("profiles keep the ring peek off",
          !ApuOff.QrgEn && !ApuOff.QrkEn && !ApuOff.QrxEn &&
          !ApuP1Transport.QrgEn && !ApuP1Transport.QrkEn &&
          !ApuP1Transport.QrxEn &&
          !ApuHarness.QrgEn && !ApuHarness.QrkEn && !ApuHarness.QrxEn &&
          !ApuSchedBoth.QrgEn && !ApuSchedBoth.QrkEn && !ApuSchedBoth.QrxEn &&
          !ApuBadVirglGrant.QrgEn && !ApuBadVirglGrant.QrkEn &&
          !ApuBadVirglGrant.QrxEn);
    cfg = ApuP1Transport;
    cfg.QrgEn = 1'b1;
    cfg.QrkEn = 1'b1;
    cfg.QrxEn = 1'b1;
    check("ring peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QrgEn = 1'b1;
    cfg.QrkEn = 1'b1;
    cfg.QrxEn = 1'b1;
    check("ring peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("ring places",
          APU_VGPU_QRG_ADDR == 64'h880D0104 &&
          APU_VGPU_QRG_ADDR != APU_VGPU_QAV_ADDR &&
          APU_VGPU_QRG_SCENE == 64'h8800E204 &&
          APU_VGPU_QRG_DESC == 16'd0 &&
          APU_VGPU_QRG_WORD == 32'h00070000 &&
          APU_VGPU_QRG_BAD == 32'h00070001);

    qrg_step(APU_VGPU_QRG_EMPTY, "read empty");
    qrk_step(APU_VGPU_QRK_EMPTY, "keep empty");
    qrx_step(APU_VGPU_QRX_EMPTY, "check empty");
    good_in();
    qax.avail_idx = 16'd1;
    qrg_step(APU_VGPU_QRG_FAULT, "scene index");
    good_in();
    fail_rd = 1'b1;
    qrg_step(APU_VGPU_QRG_FAULT, "bad beat");
    bad_desc = 1'b1;
    qrg_step(APU_VGPU_QRG_FAULT, "bad desc");
    qrg_step(APU_VGPU_QRG_OK, "ring name");
    qrg_step(APU_VGPU_QRG_FAULT, "ring again");
    check("ring stays", qrg.valid && qrg.desc_id == 16'd0 &&
          qrg.addr == APU_VGPU_QRG_ADDR);
    qax.avail_idx = 16'd1;
    qrk_step(APU_VGPU_QRK_FAULT, "keep scene index");
    check("keep rejected", !qrk.valid);
    good_in();
    qrk_step(APU_VGPU_QRK_OK, "keep name");
    check("name kept", qrk.valid && qrk.desc_id == 16'd0 &&
          qrk.addr == APU_VGPU_QRG_ADDR);
    qrk_step(APU_VGPU_QRK_FAULT, "keep again");
    qax.avail_idx = 16'd1;
    qrx_step(APU_VGPU_QRX_FAULT, "check scene index");
    check("check rejected", !qrx.valid);
    good_in();
    qrx_step(APU_VGPU_QRX_OK, "check name");
    check("name checked", qrx.valid && qrx.desc_id == 16'd0);
    qrx_step(APU_VGPU_QRX_FAULT, "check again");
    check("check stays", qrx.desc_id == qrg.desc_id);

    pulse_reset();
    check("reset clears", qrg == '0 && qrk == '0 && qrx == '0);
    qax = '0;
    qrg_step(APU_VGPU_QRG_EMPTY, "after reset");
    good_in();
    qrg_step(APU_VGPU_QRG_OK, "ring after reset");

    if (errors != 0) $fatal(1, "APU vgpu qrg errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qrg cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
