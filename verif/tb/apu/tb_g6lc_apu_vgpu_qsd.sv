// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qsd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qsy_t qsy;
  logic qsd_req = 0, qsd_rdy, qsd_cpl_v, qsd_cpl_r = 0;
  apu_vgpu_qsd_cpl_t qsd_cpl;
  apu_vgpu_qsd_t qsd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qse_req = 0, qse_rdy, qse_cpl_v, qse_cpl_r = 0;
  apu_vgpu_qse_cpl_t qse_cpl;
  apu_vgpu_qse_t qse;
  logic qsf_req = 0, qsf_rdy, qsf_cpl_v, qsf_cpl_r = 0;
  apu_vgpu_qsf_cpl_t qsf_cpl, off_cpl;
  apu_vgpu_qsf_t qsf, off_qsf;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QHD_META,
                                  APU_VGPU_QSD_LEN, APU_VGPU_HDR_ADDR};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qsd #(.Enable(1'b1)) i_qsd (
    .clk_i(clk), .rst_ni, .qsy_i(qsy),
    .req_valid_i(qsd_req), .req_ready_o(qsd_rdy),
    .cpl_valid_o(qsd_cpl_v), .cpl_ready_i(qsd_cpl_r), .cpl_o(qsd_cpl), .qsd_o(qsd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qse #(.Enable(1'b1)) i_qse (
    .clk_i(clk), .rst_ni, .qsd_i(qsd), .qsy_i(qsy),
    .req_valid_i(qse_req), .req_ready_o(qse_rdy),
    .cpl_valid_o(qse_cpl_v), .cpl_ready_i(qse_cpl_r), .cpl_o(qse_cpl), .qse_o(qse)
  );
  g6lc_apu_vgpu_qsf #(.Enable(1'b1)) i_qsf (
    .clk_i(clk), .rst_ni, .qse_i(qse), .qsd_i(qsd), .qsy_i(qsy),
    .req_valid_i(qsf_req), .req_ready_o(qsf_rdy),
    .cpl_valid_o(qsf_cpl_v), .cpl_ready_i(qsf_cpl_r), .cpl_o(qsf_cpl), .qsf_o(qsf)
  );
  g6lc_apu_vgpu_qsf_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qse_i(qse), .qsd_i(qsd), .qsy_i(qsy),
    .req_valid_i(qsf_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qsf_cpl_r), .cpl_o(off_cpl), .qsf_o(off_qsf)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qsd timeout case=%0d", cases); end

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
      if (bad_len) beat[95:64] = APU_VGPU_RAB_BYTES;
      if (rd_addr != APU_VGPU_QSD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    qsy = '0;
    qsy.valid = 1'b1;
    qsy.desc_id = APU_VGPU_QRG_DESC;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qsf == '0 &&
          off_cpl == '0);
  endtask

  task automatic qsd_step(input apu_vgpu_qsd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qsd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qsd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsd_req = 1'b0;
    while (!qsd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QSD_OK) begin
      check("desc 0", qsd.valid && qsd.hdr_addr == APU_VGPU_HDR_ADDR &&
            qsd.hdr_addr != APU_VGPU_RAB_CMD &&
            qsd.hdr_len == APU_VGPU_QSD_LEN &&
            qsd.nxt == 16'd1 && qsd.nxt != 16'd2);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QSD_ADDR && rd_seen != APU_VGPU_QHD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "attach len") begin
      check("one read failed", nread == n0 + 1 && !qsd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qsd_cpl_v);
    qsd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsd_cpl_r = 1'b0;
    while (qsd_cpl_v) @(negedge clk);
  endtask

  task automatic qse_step(input apu_vgpu_qse_status_e st, input string name);
    @(negedge clk);
    while (!qse_rdy) @(negedge clk);
    cases++;
    qse_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qse_req = 1'b0;
    while (!qse_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qse_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qse_cpl_v);
    qse_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qse_cpl_r = 1'b0;
    while (qse_cpl_v) @(negedge clk);
  endtask

  task automatic qsf_step(input apu_vgpu_qsf_status_e st, input string name);
    @(negedge clk);
    while (!qsf_rdy) @(negedge clk);
    cases++;
    qsf_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsf_req = 1'b0;
    while (!qsf_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsf_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qsf_cpl_v);
    qsf_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsf_cpl_r = 1'b0;
    while (qsf_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qsd_req = 1'b0;
    qse_req = 1'b0;
    qsf_req = 1'b0;
    qsd_cpl_r = 1'b0;
    qse_cpl_r = 1'b0;
    qsf_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qsy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qsd == '0 && qse == '0 && qsf == '0);
    check("profiles keep the scene desc peek off",
          !ApuOff.QsdEn && !ApuOff.QseEn && !ApuOff.QsfEn &&
          !ApuP1Transport.QsdEn && !ApuP1Transport.QseEn &&
          !ApuP1Transport.QsfEn &&
          !ApuHarness.QsdEn && !ApuHarness.QseEn && !ApuHarness.QsfEn &&
          !ApuSchedBoth.QsdEn && !ApuSchedBoth.QseEn && !ApuSchedBoth.QsfEn &&
          !ApuBadVirglGrant.QsdEn && !ApuBadVirglGrant.QseEn &&
          !ApuBadVirglGrant.QsfEn);
    cfg = ApuP1Transport;
    cfg.QsdEn = 1'b1;
    cfg.QseEn = 1'b1;
    cfg.QsfEn = 1'b1;
    check("scene desc does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QsdEn = 1'b1;
    cfg.QseEn = 1'b1;
    cfg.QsfEn = 1'b1;
    check("scene desc does not legalize virgl", !apu_cfg_legal(cfg));
    check("scene desc places",
          APU_VGPU_QSD_ADDR == 64'h8800E100 &&
          APU_VGPU_QSD_ADDR == APU_VGPU_NXC_DESC &&
          APU_VGPU_QSD_ADDR != APU_VGPU_QHD_ADDR &&
          APU_VGPU_HDR_ADDR == 64'h8800A000 &&
          APU_VGPU_QSD_LEN == 32'd32 &&
          APU_VGPU_QHD_META == {16'd1, VIRTQ_DESC_F_NEXT});

    qsd_step(APU_VGPU_QSD_EMPTY, "read empty");
    qse_step(APU_VGPU_QSE_EMPTY, "keep empty");
    qsf_step(APU_VGPU_QSF_EMPTY, "check empty");
    good_in();
    qsy.desc_id = 16'd1;
    qsd_step(APU_VGPU_QSD_FAULT, "bad id");
    good_in();
    fail_rd = 1'b1;
    qsd_step(APU_VGPU_QSD_FAULT, "bad beat");
    bad_ind = 1'b1;
    qsd_step(APU_VGPU_QSD_FAULT, "indirect");
    bad_len = 1'b1;
    qsd_step(APU_VGPU_QSD_FAULT, "attach len");
    qsd_step(APU_VGPU_QSD_OK, "desc 0");
    qsd_step(APU_VGPU_QSD_FAULT, "desc again");
    check("desc stays", qsd.valid && qsd.hdr_addr == APU_VGPU_HDR_ADDR &&
          qsd.nxt == 16'd1);
    qsy.desc_id = 16'd1;
    qse_step(APU_VGPU_QSE_FAULT, "keep bad id");
    check("keep rejected", !qse.valid);
    good_in();
    qse_step(APU_VGPU_QSE_OK, "keep desc");
    check("desc kept", qse.valid && qse.hdr_addr == APU_VGPU_HDR_ADDR &&
          qse.hdr_len == APU_VGPU_QSD_LEN && qse.nxt == 16'd1);
    qse_step(APU_VGPU_QSE_FAULT, "keep again");
    qsy.desc_id = 16'd1;
    qsf_step(APU_VGPU_QSF_FAULT, "check bad id");
    check("check rejected", !qsf.valid);
    good_in();
    qsf_step(APU_VGPU_QSF_OK, "check desc");
    check("desc checked", qsf.valid && qsf.hdr_addr == APU_VGPU_HDR_ADDR &&
          qsf.nxt == 16'd1);
    qsf_step(APU_VGPU_QSF_FAULT, "check again");
    check("check stays", qsf.hdr_addr == qsd.hdr_addr && qsf.nxt == qsd.nxt);

    pulse_reset();
    check("reset clears", qsd == '0 && qse == '0 && qsf == '0);
    qsy = '0;
    qsd_step(APU_VGPU_QSD_EMPTY, "after reset");
    good_in();
    qsd_step(APU_VGPU_QSD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu qsd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qsd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
