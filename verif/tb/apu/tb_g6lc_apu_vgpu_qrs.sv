// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qrs;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qex_t qex;
  logic qrs_req = 0, qrs_rdy, qrs_cpl_v, qrs_cpl_r = 0;
  apu_vgpu_qrs_cpl_t qrs_cpl;
  apu_vgpu_qrs_t qrs;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qrt_req = 0, qrt_rdy, qrt_cpl_v, qrt_cpl_r = 0;
  apu_vgpu_qrt_cpl_t qrt_cpl;
  apu_vgpu_qrt_t qrt;
  logic qru_req = 0, qru_rdy, qru_cpl_v, qru_cpl_r = 0;
  apu_vgpu_qru_cpl_t qru_cpl, off_cpl;
  apu_vgpu_qru_t qru, off_qru;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QWD_META,
                                  APU_VGPU_QWD_LEN, APU_VGPU_RSP_ADDR};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qrs #(.Enable(1'b1)) i_qrs (
    .clk_i(clk), .rst_ni, .qex_i(qex),
    .req_valid_i(qrs_req), .req_ready_o(qrs_rdy),
    .cpl_valid_o(qrs_cpl_v), .cpl_ready_i(qrs_cpl_r), .cpl_o(qrs_cpl), .qrs_o(qrs),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qrt #(.Enable(1'b1)) i_qrt (
    .clk_i(clk), .rst_ni, .qrs_i(qrs), .qex_i(qex),
    .req_valid_i(qrt_req), .req_ready_o(qrt_rdy),
    .cpl_valid_o(qrt_cpl_v), .cpl_ready_i(qrt_cpl_r), .cpl_o(qrt_cpl), .qrt_o(qrt)
  );
  g6lc_apu_vgpu_qru #(.Enable(1'b1)) i_qru (
    .clk_i(clk), .rst_ni, .qrt_i(qrt), .qrs_i(qrs), .qex_i(qex),
    .req_valid_i(qru_req), .req_ready_o(qru_rdy),
    .cpl_valid_o(qru_cpl_v), .cpl_ready_i(qru_cpl_r), .cpl_o(qru_cpl), .qru_o(qru)
  );
  g6lc_apu_vgpu_qru_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qrt_i(qrt), .qrs_i(qrs), .qex_i(qex),
    .req_valid_i(qru_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qru_cpl_r), .cpl_o(off_cpl), .qru_o(off_qru)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qrs timeout case=%0d", cases); end

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
      if (bad_len) beat[95:64] = APU_VGPU_SCENE_BYTES;
      if (rd_addr != APU_VGPU_QRS_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    qex = '0;
    qex.valid = 1'b1;
    qex.exec_addr = APU_VGPU_EXEC_ADDR;
    qex.nxt = 16'd2;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qru == '0 &&
          off_cpl == '0);
  endtask

  task automatic qrs_step(input apu_vgpu_qrs_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qrs_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qrs_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrs_req = 1'b0;
    while (!qrs_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qrs_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QRS_OK) begin
      check("desc 2", qrs.valid && qrs.rsp_addr == APU_VGPU_RSP_ADDR &&
            qrs.rsp_addr != APU_VGPU_RFW_ADDR &&
            qrs.rsp_len == APU_VGPU_QWD_LEN);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QRS_ADDR && rd_seen != APU_VGPU_QWD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "exec len") begin
      check("one read failed", nread == n0 + 1 && !qrs.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qrs_cpl_v);
    qrs_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrs_cpl_r = 1'b0;
    while (qrs_cpl_v) @(negedge clk);
  endtask

  task automatic qrt_step(input apu_vgpu_qrt_status_e st, input string name);
    @(negedge clk);
    while (!qrt_rdy) @(negedge clk);
    cases++;
    qrt_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrt_req = 1'b0;
    while (!qrt_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qrt_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qrt_cpl_v);
    qrt_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qrt_cpl_r = 1'b0;
    while (qrt_cpl_v) @(negedge clk);
  endtask

  task automatic qru_step(input apu_vgpu_qru_status_e st, input string name);
    @(negedge clk);
    while (!qru_rdy) @(negedge clk);
    cases++;
    qru_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qru_req = 1'b0;
    while (!qru_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qru_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qru_cpl_v);
    qru_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qru_cpl_r = 1'b0;
    while (qru_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qrs_req = 1'b0;
    qrt_req = 1'b0;
    qru_req = 1'b0;
    qrs_cpl_r = 1'b0;
    qrt_cpl_r = 1'b0;
    qru_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qex = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qrs == '0 && qrt == '0 && qru == '0);
    check("profiles keep the scene write peek off",
          !ApuOff.QrsEn && !ApuOff.QrtEn && !ApuOff.QruEn &&
          !ApuP1Transport.QrsEn && !ApuP1Transport.QrtEn &&
          !ApuP1Transport.QruEn &&
          !ApuHarness.QrsEn && !ApuHarness.QrtEn && !ApuHarness.QruEn &&
          !ApuSchedBoth.QrsEn && !ApuSchedBoth.QrtEn && !ApuSchedBoth.QruEn &&
          !ApuBadVirglGrant.QrsEn && !ApuBadVirglGrant.QrtEn &&
          !ApuBadVirglGrant.QruEn);
    cfg = ApuP1Transport;
    cfg.QrsEn = 1'b1;
    cfg.QrtEn = 1'b1;
    cfg.QruEn = 1'b1;
    check("scene write does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QrsEn = 1'b1;
    cfg.QrtEn = 1'b1;
    cfg.QruEn = 1'b1;
    check("scene write does not legalize virgl", !apu_cfg_legal(cfg));
    check("scene write places",
          APU_VGPU_QRS_ADDR == 64'h8800E120 &&
          APU_VGPU_QRS_ADDR == APU_VGPU_QWD_SCENE &&
          APU_VGPU_QRS_ADDR != APU_VGPU_QWD_ADDR &&
          APU_VGPU_RSP_ADDR == 64'h8800A800 &&
          APU_VGPU_QWD_LEN == 32'd24 &&
          APU_VGPU_QWD_META == {16'd0, VIRTQ_DESC_F_WRITE});

    qrs_step(APU_VGPU_QRS_EMPTY, "read empty");
    qrt_step(APU_VGPU_QRT_EMPTY, "keep empty");
    qru_step(APU_VGPU_QRU_EMPTY, "check empty");
    good_in();
    qex.nxt = 16'd1;
    qrs_step(APU_VGPU_QRS_FAULT, "stay");
    good_in();
    fail_rd = 1'b1;
    qrs_step(APU_VGPU_QRS_FAULT, "bad beat");
    bad_ind = 1'b1;
    qrs_step(APU_VGPU_QRS_FAULT, "indirect");
    bad_len = 1'b1;
    qrs_step(APU_VGPU_QRS_FAULT, "exec len");
    qrs_step(APU_VGPU_QRS_OK, "desc 2");
    qrs_step(APU_VGPU_QRS_FAULT, "desc again");
    check("desc stays", qrs.valid && qrs.rsp_addr == APU_VGPU_RSP_ADDR &&
          qrs.rsp_len == 32'd24);
    qex.nxt = 16'd1;
    qrt_step(APU_VGPU_QRT_FAULT, "keep stay");
    check("keep rejected", !qrt.valid);
    good_in();
    qrt_step(APU_VGPU_QRT_OK, "keep desc");
    check("desc kept", qrt.valid && qrt.rsp_addr == APU_VGPU_RSP_ADDR &&
          qrt.rsp_len == APU_VGPU_QWD_LEN);
    qrt_step(APU_VGPU_QRT_FAULT, "keep again");
    qex.nxt = 16'd1;
    qru_step(APU_VGPU_QRU_FAULT, "check stay");
    check("check rejected", !qru.valid);
    good_in();
    qru_step(APU_VGPU_QRU_OK, "check desc");
    check("desc checked", qru.valid && qru.rsp_addr == APU_VGPU_RSP_ADDR);
    qru_step(APU_VGPU_QRU_FAULT, "check again");
    check("check stays", qru.rsp_addr == qrs.rsp_addr);

    pulse_reset();
    check("reset clears", qrs == '0 && qrt == '0 && qru == '0);
    qex = '0;
    qrs_step(APU_VGPU_QRS_EMPTY, "after reset");
    good_in();
    qrs_step(APU_VGPU_QRS_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu qrs errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qrs cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
