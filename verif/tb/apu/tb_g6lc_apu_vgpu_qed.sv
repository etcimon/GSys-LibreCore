// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qed;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qsf_t qsf;
  logic qed_req = 0, qed_rdy, qed_cpl_v, qed_cpl_r = 0;
  apu_vgpu_qed_cpl_t qed_cpl;
  apu_vgpu_qed_t qed;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qek_req = 0, qek_rdy, qek_cpl_v, qek_cpl_r = 0;
  apu_vgpu_qek_cpl_t qek_cpl;
  apu_vgpu_qek_t qek;
  logic qex_req = 0, qex_rdy, qex_cpl_v, qex_cpl_r = 0;
  apu_vgpu_qex_cpl_t qex_cpl, off_cpl;
  apu_vgpu_qex_t qex, off_qex;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QFD_META,
                                  APU_VGPU_SCENE_BYTES, APU_VGPU_EXEC_ADDR};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qed #(.Enable(1'b1)) i_qed (
    .clk_i(clk), .rst_ni, .qsf_i(qsf),
    .req_valid_i(qed_req), .req_ready_o(qed_rdy),
    .cpl_valid_o(qed_cpl_v), .cpl_ready_i(qed_cpl_r), .cpl_o(qed_cpl), .qed_o(qed),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qek #(.Enable(1'b1)) i_qek (
    .clk_i(clk), .rst_ni, .qed_i(qed), .qsf_i(qsf),
    .req_valid_i(qek_req), .req_ready_o(qek_rdy),
    .cpl_valid_o(qek_cpl_v), .cpl_ready_i(qek_cpl_r), .cpl_o(qek_cpl), .qek_o(qek)
  );
  g6lc_apu_vgpu_qex #(.Enable(1'b1)) i_qex (
    .clk_i(clk), .rst_ni, .qek_i(qek), .qed_i(qed), .qsf_i(qsf),
    .req_valid_i(qex_req), .req_ready_o(qex_rdy),
    .cpl_valid_o(qex_cpl_v), .cpl_ready_i(qex_cpl_r), .cpl_o(qex_cpl), .qex_o(qex)
  );
  g6lc_apu_vgpu_qex_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qek_i(qek), .qed_i(qed), .qsf_i(qsf),
    .req_valid_i(qex_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qex_cpl_r), .cpl_o(off_cpl), .qex_o(off_qex)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qed timeout case=%0d", cases); end

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
      if (bad_len) beat[95:64] = APU_VGPU_TFB_BYTES;
      if (rd_addr != APU_VGPU_QED_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    qsf = '0;
    qsf.valid = 1'b1;
    qsf.hdr_addr = APU_VGPU_HDR_ADDR;
    qsf.nxt = 16'd1;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qex == '0 &&
          off_cpl == '0);
  endtask

  task automatic qed_step(input apu_vgpu_qed_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qed_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qed_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qed_req = 1'b0;
    while (!qed_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qed_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QED_OK) begin
      check("desc 1", qed.valid && qed.exec_addr == APU_VGPU_EXEC_ADDR &&
            qed.exec_addr != APU_VGPU_HDR_ADDR &&
            qed.exec_len == APU_VGPU_SCENE_BYTES &&
            qed.nxt == 16'd2 && qed.nxt != 16'd1);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QED_ADDR && rd_seen != APU_VGPU_QFD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "xfer len") begin
      check("one read failed", nread == n0 + 1 && !qed.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qed_cpl_v);
    qed_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qed_cpl_r = 1'b0;
    while (qed_cpl_v) @(negedge clk);
  endtask

  task automatic qek_step(input apu_vgpu_qek_status_e st, input string name);
    @(negedge clk);
    while (!qek_rdy) @(negedge clk);
    cases++;
    qek_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qek_req = 1'b0;
    while (!qek_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qek_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qek_cpl_v);
    qek_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qek_cpl_r = 1'b0;
    while (qek_cpl_v) @(negedge clk);
  endtask

  task automatic qex_step(input apu_vgpu_qex_status_e st, input string name);
    @(negedge clk);
    while (!qex_rdy) @(negedge clk);
    cases++;
    qex_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qex_req = 1'b0;
    while (!qex_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qex_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qex_cpl_v);
    qex_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qex_cpl_r = 1'b0;
    while (qex_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qed_req = 1'b0;
    qek_req = 1'b0;
    qex_req = 1'b0;
    qed_cpl_r = 1'b0;
    qek_cpl_r = 1'b0;
    qex_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qsf = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qed == '0 && qek == '0 && qex == '0);
    check("profiles keep the scene exec peek off",
          !ApuOff.QedEn && !ApuOff.QekEn && !ApuOff.QexEn &&
          !ApuP1Transport.QedEn && !ApuP1Transport.QekEn &&
          !ApuP1Transport.QexEn &&
          !ApuHarness.QedEn && !ApuHarness.QekEn && !ApuHarness.QexEn &&
          !ApuSchedBoth.QedEn && !ApuSchedBoth.QekEn && !ApuSchedBoth.QexEn &&
          !ApuBadVirglGrant.QedEn && !ApuBadVirglGrant.QekEn &&
          !ApuBadVirglGrant.QexEn);
    cfg = ApuP1Transport;
    cfg.QedEn = 1'b1;
    cfg.QekEn = 1'b1;
    cfg.QexEn = 1'b1;
    check("scene exec does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QedEn = 1'b1;
    cfg.QekEn = 1'b1;
    cfg.QexEn = 1'b1;
    check("scene exec does not legalize virgl", !apu_cfg_legal(cfg));
    check("scene exec places",
          APU_VGPU_QED_ADDR == 64'h8800E110 &&
          APU_VGPU_QED_ADDR == APU_VGPU_QFD_SCENE &&
          APU_VGPU_QED_ADDR != APU_VGPU_QFD_ADDR &&
          APU_VGPU_EXEC_ADDR == 64'h8800B000 &&
          APU_VGPU_SCENE_BYTES == 32'd960 &&
          APU_VGPU_QFD_META == {16'd2, VIRTQ_DESC_F_NEXT});

    qed_step(APU_VGPU_QED_EMPTY, "read empty");
    qek_step(APU_VGPU_QEK_EMPTY, "keep empty");
    qex_step(APU_VGPU_QEX_EMPTY, "check empty");
    good_in();
    qsf.nxt = 16'd2;
    qed_step(APU_VGPU_QED_FAULT, "jump");
    good_in();
    fail_rd = 1'b1;
    qed_step(APU_VGPU_QED_FAULT, "bad beat");
    bad_ind = 1'b1;
    qed_step(APU_VGPU_QED_FAULT, "indirect");
    bad_len = 1'b1;
    qed_step(APU_VGPU_QED_FAULT, "xfer len");
    qed_step(APU_VGPU_QED_OK, "desc 1");
    qed_step(APU_VGPU_QED_FAULT, "desc again");
    check("desc stays", qed.valid && qed.exec_addr == APU_VGPU_EXEC_ADDR &&
          qed.nxt == 16'd2);
    qsf.nxt = 16'd2;
    qek_step(APU_VGPU_QEK_FAULT, "keep jump");
    check("keep rejected", !qek.valid);
    good_in();
    qek_step(APU_VGPU_QEK_OK, "keep desc");
    check("desc kept", qek.valid && qek.exec_addr == APU_VGPU_EXEC_ADDR &&
          qek.exec_len == APU_VGPU_SCENE_BYTES && qek.nxt == 16'd2);
    qek_step(APU_VGPU_QEK_FAULT, "keep again");
    qsf.nxt = 16'd2;
    qex_step(APU_VGPU_QEX_FAULT, "check jump");
    check("check rejected", !qex.valid);
    good_in();
    qex_step(APU_VGPU_QEX_OK, "check desc");
    check("desc checked", qex.valid && qex.exec_addr == APU_VGPU_EXEC_ADDR &&
          qex.nxt == 16'd2);
    qex_step(APU_VGPU_QEX_FAULT, "check again");
    check("check stays", qex.exec_addr == qed.exec_addr && qex.nxt == qed.nxt);

    pulse_reset();
    check("reset clears", qed == '0 && qek == '0 && qex == '0);
    qsf = '0;
    qed_step(APU_VGPU_QED_EMPTY, "after reset");
    good_in();
    qed_step(APU_VGPU_QED_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu qed errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qed cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
