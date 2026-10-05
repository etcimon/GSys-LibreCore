// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qav;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qnx_t qnx;
  logic qav_req = 0, qav_rdy, qav_cpl_v, qav_cpl_r = 0;
  apu_vgpu_qav_cpl_t qav_cpl;
  apu_vgpu_qav_t qav;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qak_req = 0, qak_rdy, qak_cpl_v, qak_cpl_r = 0;
  apu_vgpu_qak_cpl_t qak_cpl;
  apu_vgpu_qak_t qak;
  logic qax_req = 0, qax_rdy, qax_cpl_v, qax_cpl_r = 0;
  apu_vgpu_qax_cpl_t qax_cpl, off_cpl;
  apu_vgpu_qax_t qax, off_qax;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_idx = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QAV_WORD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qav #(.Enable(1'b1)) i_qav (
    .clk_i(clk), .rst_ni, .qnx_i(qnx),
    .req_valid_i(qav_req), .req_ready_o(qav_rdy),
    .cpl_valid_o(qav_cpl_v), .cpl_ready_i(qav_cpl_r), .cpl_o(qav_cpl), .qav_o(qav),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qak #(.Enable(1'b1)) i_qak (
    .clk_i(clk), .rst_ni, .qav_i(qav), .qnx_i(qnx),
    .req_valid_i(qak_req), .req_ready_o(qak_rdy),
    .cpl_valid_o(qak_cpl_v), .cpl_ready_i(qak_cpl_r), .cpl_o(qak_cpl), .qak_o(qak)
  );
  g6lc_apu_vgpu_qax #(.Enable(1'b1)) i_qax (
    .clk_i(clk), .rst_ni, .qak_i(qak), .qav_i(qav), .qnx_i(qnx),
    .req_valid_i(qax_req), .req_ready_o(qax_rdy),
    .cpl_valid_o(qax_cpl_v), .cpl_ready_i(qax_cpl_r), .cpl_o(qax_cpl), .qax_o(qax)
  );
  g6lc_apu_vgpu_qax_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qak_i(qak), .qav_i(qav), .qnx_i(qnx),
    .req_valid_i(qax_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qax_cpl_r), .cpl_o(off_cpl), .qax_o(off_qax)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qav timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_idx) beat[31:0] = APU_VGPU_QAV_SCENE;
      if (rd_addr != APU_VGPU_QAV_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
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
    qnx = '0;
    qnx.valid = 1'b1;
    qnx.qid = APU_VGPU_QNT_QUEUE;
    qnx.avail_idx = APU_VGPU_TUW_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qax == '0 &&
          off_cpl == '0);
  endtask

  task automatic qav_step(input apu_vgpu_qav_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qav_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qav_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qav_req = 1'b0;
    while (!qav_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qav_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QAV_OK) begin
      check("avail idx", qav.valid && qav.avail_idx == 16'd2 &&
            qav.avail_idx != 16'd1 &&
            qav.addr == APU_VGPU_QAV_ADDR &&
            qav.addr != APU_VGPU_NXC_AVAIL);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QAV_ADDR && rd_seen != APU_VGPU_NXC_AVAIL);
    end else if (name == "bad beat" || name == "scene word") begin
      check("one read failed", nread == n0 + 1 && !qav.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qav_cpl_v);
    qav_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qav_cpl_r = 1'b0;
    while (qav_cpl_v) @(negedge clk);
  endtask

  task automatic qak_step(input apu_vgpu_qak_status_e st, input string name);
    @(negedge clk);
    while (!qak_rdy) @(negedge clk);
    cases++;
    qak_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qak_req = 1'b0;
    while (!qak_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qak_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qak_cpl_v);
    qak_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qak_cpl_r = 1'b0;
    while (qak_cpl_v) @(negedge clk);
  endtask

  task automatic qax_step(input apu_vgpu_qax_status_e st, input string name);
    @(negedge clk);
    while (!qax_rdy) @(negedge clk);
    cases++;
    qax_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qax_req = 1'b0;
    while (!qax_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qax_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qax_cpl_v);
    qax_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qax_cpl_r = 1'b0;
    while (qax_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qav_req = 1'b0;
    qak_req = 1'b0;
    qax_req = 1'b0;
    qav_cpl_r = 1'b0;
    qak_cpl_r = 1'b0;
    qax_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qnx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qav == '0 && qak == '0 && qax == '0);
    check("profiles keep the avail peek off",
          !ApuOff.QavEn && !ApuOff.QakEn && !ApuOff.QaxEn &&
          !ApuP1Transport.QavEn && !ApuP1Transport.QakEn &&
          !ApuP1Transport.QaxEn &&
          !ApuHarness.QavEn && !ApuHarness.QakEn && !ApuHarness.QaxEn &&
          !ApuSchedBoth.QavEn && !ApuSchedBoth.QakEn && !ApuSchedBoth.QaxEn &&
          !ApuBadVirglGrant.QavEn && !ApuBadVirglGrant.QakEn &&
          !ApuBadVirglGrant.QaxEn);
    cfg = ApuP1Transport;
    cfg.QavEn = 1'b1;
    cfg.QakEn = 1'b1;
    cfg.QaxEn = 1'b1;
    check("avail peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QavEn = 1'b1;
    cfg.QakEn = 1'b1;
    cfg.QaxEn = 1'b1;
    check("avail peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("avail places",
          APU_VGPU_QAV_ADDR == 64'h880D0100 &&
          APU_VGPU_QAV_ADDR == APU_VGPU_TXC_AVAIL &&
          APU_VGPU_QAV_ADDR != APU_VGPU_NXC_AVAIL &&
          APU_VGPU_QAV_WORD == 32'h00020000 &&
          APU_VGPU_QAV_SCENE == 32'h00010000);

    qav_step(APU_VGPU_QAV_EMPTY, "read empty");
    qak_step(APU_VGPU_QAK_EMPTY, "keep empty");
    qax_step(APU_VGPU_QAX_EMPTY, "check empty");
    good_in();
    qnx.qid = APU_VGPU_QNT_CURSOR;
    qav_step(APU_VGPU_QAV_FAULT, "cursor queue");
    qnx.qid = APU_VGPU_QNT_QUEUE;
    qnx.avail_idx = 16'd1;
    qav_step(APU_VGPU_QAV_FAULT, "scene index");
    good_in();
    fail_rd = 1'b1;
    qav_step(APU_VGPU_QAV_FAULT, "bad beat");
    bad_idx = 1'b1;
    qav_step(APU_VGPU_QAV_FAULT, "scene word");
    qav_step(APU_VGPU_QAV_OK, "avail idx");
    qav_step(APU_VGPU_QAV_FAULT, "avail again");
    check("avail stays", qav.valid && qav.avail_idx == 16'd2 &&
          qav.addr == APU_VGPU_QAV_ADDR);
    qnx.avail_idx = 16'd1;
    qak_step(APU_VGPU_QAK_FAULT, "keep scene index");
    check("keep rejected", !qak.valid);
    good_in();
    qak_step(APU_VGPU_QAK_OK, "keep idx");
    check("idx kept", qak.valid && qak.avail_idx == 16'd2 &&
          qak.addr == APU_VGPU_QAV_ADDR);
    qak_step(APU_VGPU_QAK_FAULT, "keep again");
    qnx.qid = APU_VGPU_QNT_CURSOR;
    qax_step(APU_VGPU_QAX_FAULT, "check cursor");
    check("check rejected", !qax.valid);
    good_in();
    qax_step(APU_VGPU_QAX_OK, "check idx");
    check("idx checked", qax.valid && qax.avail_idx == 16'd2);
    qax_step(APU_VGPU_QAX_FAULT, "check again");
    check("check stays", qax.avail_idx == qav.avail_idx);

    pulse_reset();
    check("reset clears", qav == '0 && qak == '0 && qax == '0);
    qnx = '0;
    qav_step(APU_VGPU_QAV_EMPTY, "after reset");
    good_in();
    qav_step(APU_VGPU_QAV_OK, "avail after reset");

    if (errors != 0) $fatal(1, "APU vgpu qav errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qav cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
