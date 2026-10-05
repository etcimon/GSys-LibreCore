// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qso;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qru_t qru;
  logic qso_req = 0, qso_rdy, qso_cpl_v, qso_cpl_r = 0;
  apu_vgpu_qso_cpl_t qso_cpl;
  apu_vgpu_qso_t qso;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qsp_req = 0, qsp_rdy, qsp_cpl_v, qsp_cpl_r = 0;
  apu_vgpu_qsp_cpl_t qsp_cpl;
  apu_vgpu_qsp_t qsp;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qsq_req = 0, qsq_rdy, qsq_cpl_v, qsq_cpl_r = 0;
  apu_vgpu_qsq_cpl_t qsq_cpl, off_cpl;
  apu_vgpu_qsq_t qsq, off_qsq;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, xfer_fence = 0, no_flag = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] RespBeat = {64'h0, 32'h0, APU_VGPU_CTX_ID,
                                       APU_VGPU_SCENE_FENCE, VGPU_FLAG_FENCE,
                                       VGPU_RESP_OK_NODATA};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qso #(.Enable(1'b1)) i_qso (
    .clk_i(clk), .rst_ni, .qru_i(qru),
    .req_valid_i(qso_req), .req_ready_o(qso_rdy),
    .cpl_valid_o(qso_cpl_v), .cpl_ready_i(qso_cpl_r), .cpl_o(qso_cpl), .qso_o(qso),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qsp #(.Enable(1'b1)) i_qsp (
    .clk_i(clk), .rst_ni, .qso_i(qso), .qru_i(qru),
    .req_valid_i(qsp_req), .req_ready_o(qsp_rdy),
    .cpl_valid_o(qsp_cpl_v), .cpl_ready_i(qsp_cpl_r), .cpl_o(qsp_cpl), .qsp_o(qsp),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qsq #(.Enable(1'b1)) i_qsq (
    .clk_i(clk), .rst_ni, .qsp_i(qsp), .qso_i(qso), .qru_i(qru),
    .req_valid_i(qsq_req), .req_ready_o(qsq_rdy),
    .cpl_valid_o(qsq_cpl_v), .cpl_ready_i(qsq_cpl_r), .cpl_o(qsq_cpl), .qsq_o(qsq)
  );
  g6lc_apu_vgpu_qsq_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qsp_i(qsp), .qso_i(qso), .qru_i(qru),
    .req_valid_i(qsq_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qsq_cpl_r), .cpl_o(off_cpl), .qsq_o(off_qsq)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qso timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      order_bad <= 1'b0;
      data_bad <= 1'b0;
      stored_v <= 1'b0;
      stored <= '0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      if (wr_addr != APU_VGPU_RSP_ADDR || wr_len != VGPU_RESP_HDR_BYTES)
        order_bad <= 1'b1;
      if (wr_data[191:0] != RespBeat[191:0]) data_bad <= 1'b1;
      wr_seen <= wr_addr;
      stored <= wr_data;
      stored_v <= 1'b1;
      wr_rsp_addr <= wr_addr;
      wr_rsp_ok <= !fail_wr;
      fail_wr <= 1'b0;
      nwrite <= nwrite + 1;
      wr_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = stored_v ? stored : RespBeat;
      if (xfer_fence) beat[127:64] = APU_VGPU_RFW_FENCE;
      if (no_flag) beat[63:32] = 32'h0;
      if (rd_addr != APU_VGPU_RSP_ADDR || rd_len != VGPU_RESP_HDR_BYTES)
        rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      xfer_fence <= 1'b0;
      no_flag <= 1'b0;
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
    qru = '0;
    qru.valid = 1'b1;
    qru.rsp_addr = APU_VGPU_RSP_ADDR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qsq == '0 &&
          off_cpl == '0);
  endtask

  task automatic qso_step(input apu_vgpu_qso_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qso_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    qso_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qso_req = 1'b0;
    while (!qso_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qso_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QSO_OK) begin
      check("response", qso.valid && qso.resp == VGPU_RESP_OK_NODATA &&
            qso.fence == APU_VGPU_SCENE_FENCE &&
            qso.fence != APU_VGPU_RFW_FENCE &&
            qso.addr == APU_VGPU_RSP_ADDR && qso.addr != APU_VGPU_RFW_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_RSP_ADDR && wr_seen != APU_VGPU_QRS_ADDR);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !qso.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qso_cpl_v);
    qso_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qso_cpl_r = 1'b0;
    while (qso_cpl_v) @(negedge clk);
  endtask

  task automatic qsp_step(input apu_vgpu_qsp_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qsp_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qsp_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsp_req = 1'b0;
    while (!qsp_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsp_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QSP_OK) begin
      check("echo", qsp.valid && qsp.fence == APU_VGPU_SCENE_FENCE &&
            qsp.fence != APU_VGPU_RFW_FENCE &&
            qsp.flg == VGPU_FLAG_FENCE &&
            qsp.resp == VGPU_RESP_OK_NODATA &&
            qsp.addr == APU_VGPU_RSP_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_RSP_ADDR);
    end else if (name == "bad read" || name == "xfer fence" ||
                 name == "no flag") begin
      check("one read failed", nread == n0 + 1 && !qsp.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qsp_cpl_v);
    qsp_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsp_cpl_r = 1'b0;
    while (qsp_cpl_v) @(negedge clk);
  endtask

  task automatic qsq_step(input apu_vgpu_qsq_status_e st, input string name);
    @(negedge clk);
    while (!qsq_rdy) @(negedge clk);
    cases++;
    qsq_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsq_req = 1'b0;
    while (!qsq_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsq_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qsq_cpl_v);
    qsq_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsq_cpl_r = 1'b0;
    while (qsq_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qso_req = 1'b0;
    qsp_req = 1'b0;
    qsq_req = 1'b0;
    qso_cpl_r = 1'b0;
    qsp_cpl_r = 1'b0;
    qsq_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    stored_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qru = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qso == '0 && qsp == '0 && qsq == '0);
    check("profiles keep the nodata off",
          !ApuOff.QsoEn && !ApuOff.QspEn && !ApuOff.QsqEn &&
          !ApuP1Transport.QsoEn && !ApuP1Transport.QspEn &&
          !ApuP1Transport.QsqEn &&
          !ApuHarness.QsoEn && !ApuHarness.QspEn && !ApuHarness.QsqEn &&
          !ApuSchedBoth.QsoEn && !ApuSchedBoth.QspEn && !ApuSchedBoth.QsqEn &&
          !ApuBadVirglGrant.QsoEn && !ApuBadVirglGrant.QspEn &&
          !ApuBadVirglGrant.QsqEn);
    cfg = ApuP1Transport;
    cfg.QsoEn = 1'b1;
    cfg.QspEn = 1'b1;
    cfg.QsqEn = 1'b1;
    check("nodata does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QsoEn = 1'b1;
    cfg.QspEn = 1'b1;
    cfg.QsqEn = 1'b1;
    check("nodata does not legalize virgl", !apu_cfg_legal(cfg));
    check("nodata places",
          APU_VGPU_RSP_ADDR != APU_VGPU_RFW_ADDR &&
          APU_VGPU_RSP_ADDR != APU_VGPU_QRS_ADDR &&
          APU_VGPU_SCENE_FENCE != 64'd2 &&
          APU_VGPU_SCENE_FENCE != APU_VGPU_RFW_FENCE &&
          VGPU_RESP_HDR_BYTES == 32'd24);

    qso_step(APU_VGPU_QSO_EMPTY, "write empty");
    qsp_step(APU_VGPU_QSP_EMPTY, "read empty");
    qsq_step(APU_VGPU_QSQ_EMPTY, "check empty");
    good_in();
    qru.rsp_addr = APU_VGPU_RFW_ADDR;
    qso_step(APU_VGPU_QSO_FAULT, "xfer dest");
    good_in();
    fail_wr = 1'b1;
    qso_step(APU_VGPU_QSO_FAULT, "bad write");
    qso_step(APU_VGPU_QSO_OK, "ok nodata");
    qso_step(APU_VGPU_QSO_FAULT, "write again");
    fail_rd = 1'b1;
    qsp_step(APU_VGPU_QSP_FAULT, "bad read");
    xfer_fence = 1'b1;
    qsp_step(APU_VGPU_QSP_FAULT, "xfer fence");
    no_flag = 1'b1;
    qsp_step(APU_VGPU_QSP_FAULT, "no flag");
    qsp_step(APU_VGPU_QSP_OK, "echo fence");
    qsp_step(APU_VGPU_QSP_FAULT, "read again");
    qru.rsp_addr = APU_VGPU_RFW_ADDR;
    qsq_step(APU_VGPU_QSQ_FAULT, "check xfer dest");
    check("check rejected", !qsq.valid);
    good_in();
    qsq_step(APU_VGPU_QSQ_OK, "check fence");
    check("fence checked", qsq.valid && qsq.fence == APU_VGPU_SCENE_FENCE &&
          qsq.resp == VGPU_RESP_OK_NODATA);
    qsq_step(APU_VGPU_QSQ_FAULT, "check again");
    check("check stays", qsq.fence == qso.fence);

    pulse_reset();
    check("reset clears", qso == '0 && qsp == '0 && qsq == '0);
    qru = '0;
    qso_step(APU_VGPU_QSO_EMPTY, "after reset");
    good_in();
    qso_step(APU_VGPU_QSO_OK, "nodata after reset");

    if (errors != 0) $fatal(1, "APU vgpu qso errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qso cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
