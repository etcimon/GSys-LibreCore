// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qnt;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_tnx_t tnx;
  logic qnt_req = 0, qnt_rdy, qnt_cpl_v, qnt_cpl_r = 0;
  apu_vgpu_qnt_cpl_t qnt_cpl;
  apu_vgpu_qnt_t qnt;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qnr_req = 0, qnr_rdy, qnr_cpl_v, qnr_cpl_r = 0;
  apu_vgpu_qnr_cpl_t qnr_cpl;
  apu_vgpu_qnr_t qnr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qnx_req = 0, qnx_rdy, qnx_cpl_v, qnx_cpl_r = 0;
  apu_vgpu_qnx_cpl_t qnx_cpl, off_cpl;
  apu_vgpu_qnx_t qnx, off_qnx;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_queue = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QNT_QUEUE};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qnt #(.Enable(1'b1)) i_qnt (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .tnx_i(tnx),
    .req_valid_i(qnt_req), .req_ready_o(qnt_rdy),
    .cpl_valid_o(qnt_cpl_v), .cpl_ready_i(qnt_cpl_r), .cpl_o(qnt_cpl), .qnt_o(qnt),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qnr #(.Enable(1'b1)) i_qnr (
    .clk_i(clk), .rst_ni, .qnt_i(qnt), .tnx_i(tnx),
    .req_valid_i(qnr_req), .req_ready_o(qnr_rdy),
    .cpl_valid_o(qnr_cpl_v), .cpl_ready_i(qnr_cpl_r), .cpl_o(qnr_cpl), .qnr_o(qnr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qnx #(.Enable(1'b1)) i_qnx (
    .clk_i(clk), .rst_ni, .qnr_i(qnr), .qnt_i(qnt), .tnx_i(tnx),
    .req_valid_i(qnx_req), .req_ready_o(qnx_rdy),
    .cpl_valid_o(qnx_cpl_v), .cpl_ready_i(qnx_cpl_r), .cpl_o(qnx_cpl), .qnx_o(qnx)
  );
  g6lc_apu_vgpu_qnx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qnr_i(qnr), .qnt_i(qnt), .tnx_i(tnx),
    .req_valid_i(qnx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qnx_cpl_r), .cpl_o(off_cpl), .qnx_o(off_qnx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qnt timeout case=%0d", cases); end

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
      if (wr_addr != APU_VGPU_QNT_ADDR || wr_len != 32'd4) order_bad <= 1'b1;
      if (wr_data != Pat) data_bad <= 1'b1;
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
      beat = stored_v ? stored : 256'b0;
      if (bad_queue) beat[31:0] = APU_VGPU_QNT_CURSOR;
      if (rd_addr != APU_VGPU_QNT_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_queue <= 1'b0;
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
    tnx = '0;
    tnx.valid = 1'b1;
    tnx.avail_idx = APU_VGPU_TUW_IDXV;
    tnx.device_idx = APU_VGPU_TUW_IDXV;
    tnx.att_addr = APU_VGPU_RAB_CMD;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qnx == '0 &&
          off_cpl == '0);
  endtask

  task automatic qnt_step(input apu_vgpu_qnt_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qnt_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    qnt_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qnt_req = 1'b0;
    while (!qnt_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qnt_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QNT_OK) begin
      check("doorbell", qnt.valid && qnt.qid == APU_VGPU_QNT_QUEUE &&
            qnt.qid != APU_VGPU_QNT_CURSOR &&
            qnt.avail_idx == 16'd2 &&
            qnt.addr == APU_VGPU_QNT_ADDR &&
            qnt.addr != APU_VGPU_TXC_AVAIL);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_QNT_ADDR);
    end else if (name == "bad beat") begin
      check("one write failed", nwrite == n0 + 1 && !qnt.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qnt_cpl_v);
    qnt_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qnt_cpl_r = 1'b0;
    while (qnt_cpl_v) @(negedge clk);
  endtask

  task automatic qnr_step(input apu_vgpu_qnr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qnr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qnr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qnr_req = 1'b0;
    while (!qnr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qnr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QNR_OK) begin
      check("echo queue", qnr.valid && qnr.qid == APU_VGPU_QNT_QUEUE &&
            qnr.avail_idx == 16'd2 && qnr.addr == APU_VGPU_QNT_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QNT_ADDR && rd_seen != APU_VGPU_TXC_AVAIL);
    end else if (name == "bad read" || name == "cursor queue") begin
      check("one read failed", nread == n0 + 1 && !qnr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qnr_cpl_v);
    qnr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qnr_cpl_r = 1'b0;
    while (qnr_cpl_v) @(negedge clk);
  endtask

  task automatic qnx_step(input apu_vgpu_qnx_status_e st, input string name);
    @(negedge clk);
    while (!qnx_rdy) @(negedge clk);
    cases++;
    qnx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qnx_req = 1'b0;
    while (!qnx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qnx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qnx_cpl_v);
    qnx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qnx_cpl_r = 1'b0;
    while (qnx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qnt_req = 1'b0;
    qnr_req = 1'b0;
    qnx_req = 1'b0;
    qnt_cpl_r = 1'b0;
    qnr_cpl_r = 1'b0;
    qnx_cpl_r = 1'b0;
    cancel = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    stored_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    tnx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qnt == '0 && qnr == '0 && qnx == '0);
    check("profiles keep the doorbell off",
          !ApuOff.QntEn && !ApuOff.QnrEn && !ApuOff.QnxEn &&
          !ApuP1Transport.QntEn && !ApuP1Transport.QnrEn &&
          !ApuP1Transport.QnxEn &&
          !ApuHarness.QntEn && !ApuHarness.QnrEn && !ApuHarness.QnxEn &&
          !ApuSchedBoth.QntEn && !ApuSchedBoth.QnrEn && !ApuSchedBoth.QnxEn &&
          !ApuBadVirglGrant.QntEn && !ApuBadVirglGrant.QnrEn &&
          !ApuBadVirglGrant.QnxEn);
    cfg = ApuP1Transport;
    cfg.QntEn = 1'b1;
    cfg.QnrEn = 1'b1;
    cfg.QnxEn = 1'b1;
    check("doorbell does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QntEn = 1'b1;
    cfg.QnrEn = 1'b1;
    cfg.QnxEn = 1'b1;
    check("doorbell does not legalize virgl", !apu_cfg_legal(cfg));
    check("notify places",
          APU_VGPU_QNT_ADDR == 64'h880D0200 &&
          APU_VGPU_QNT_ADDR != APU_VGPU_TXC_AVAIL &&
          APU_VGPU_QNT_QUEUE == 32'd0 &&
          APU_VGPU_QNT_CURSOR == 32'd1);

    qnt_step(APU_VGPU_QNT_EMPTY, "write empty");
    qnr_step(APU_VGPU_QNR_EMPTY, "read empty");
    qnx_step(APU_VGPU_QNX_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    qnt_step(APU_VGPU_QNT_FAULT, "cancel");
    cancel = 1'b0;
    tnx.avail_idx = 16'd1;
    qnt_step(APU_VGPU_QNT_FAULT, "scene index");
    good_in();
    fail_wr = 1'b1;
    qnt_step(APU_VGPU_QNT_FAULT, "bad beat");
    qnt_step(APU_VGPU_QNT_OK, "doorbell");
    qnt_step(APU_VGPU_QNT_FAULT, "doorbell again");
    check("doorbell stays", qnt.valid && qnt.qid == 32'd0 &&
          qnt.avail_idx == 16'd2);
    fail_rd = 1'b1;
    qnr_step(APU_VGPU_QNR_FAULT, "bad read");
    bad_queue = 1'b1;
    qnr_step(APU_VGPU_QNR_FAULT, "cursor queue");
    qnr_step(APU_VGPU_QNR_OK, "echo queue");
    qnr_step(APU_VGPU_QNR_FAULT, "read again");
    tnx.avail_idx = 16'd1;
    qnx_step(APU_VGPU_QNX_FAULT, "keep scene index");
    check("keep rejected", !qnx.valid);
    good_in();
    qnx_step(APU_VGPU_QNX_OK, "keep queue");
    check("queue kept", qnx.valid && qnx.qid == 32'd0 &&
          qnx.avail_idx == 16'd2);
    qnx_step(APU_VGPU_QNX_FAULT, "keep again");
    check("keep stays", qnx.qid == qnt.qid);

    pulse_reset();
    check("reset clears", qnt == '0 && qnr == '0 && qnx == '0);
    tnx = '0;
    qnt_step(APU_VGPU_QNT_EMPTY, "after reset");
    good_in();
    qnt_step(APU_VGPU_QNT_OK, "doorbell after reset");

    if (errors != 0) $fatal(1, "APU vgpu qnt errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qnt cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
