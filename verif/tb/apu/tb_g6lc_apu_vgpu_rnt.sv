// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rnt;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_rnx_t rnx;
  logic rnt_req = 0, rnt_rdy, rnt_cpl_v, rnt_cpl_r = 0;
  apu_vgpu_rnt_cpl_t rnt_cpl;
  apu_vgpu_rnt_t rnt;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic rnr_req = 0, rnr_rdy, rnr_cpl_v, rnr_cpl_r = 0;
  apu_vgpu_rnr_cpl_t rnr_cpl;
  apu_vgpu_rnr_t rnr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rny_req = 0, rny_rdy, rny_cpl_v, rny_cpl_r = 0;
  apu_vgpu_rny_cpl_t rny_cpl, off_cpl;
  apu_vgpu_rny_t rny, off_rny;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_queue = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QNT_QUEUE};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rnt #(.Enable(1'b1)) i_rnt (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .rnx_i(rnx),
    .req_valid_i(rnt_req), .req_ready_o(rnt_rdy),
    .cpl_valid_o(rnt_cpl_v), .cpl_ready_i(rnt_cpl_r), .cpl_o(rnt_cpl), .rnt_o(rnt),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rnr #(.Enable(1'b1)) i_rnr (
    .clk_i(clk), .rst_ni, .rnt_i(rnt), .rnx_i(rnx),
    .req_valid_i(rnr_req), .req_ready_o(rnr_rdy),
    .cpl_valid_o(rnr_cpl_v), .cpl_ready_i(rnr_cpl_r), .cpl_o(rnr_cpl), .rnr_o(rnr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rny #(.Enable(1'b1)) i_rny (
    .clk_i(clk), .rst_ni, .rnr_i(rnr), .rnt_i(rnt), .rnx_i(rnx),
    .req_valid_i(rny_req), .req_ready_o(rny_rdy),
    .cpl_valid_o(rny_cpl_v), .cpl_ready_i(rny_cpl_r), .cpl_o(rny_cpl), .rny_o(rny)
  );
  g6lc_apu_vgpu_rny_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rnr_i(rnr), .rnt_i(rnt), .rnx_i(rnx),
    .req_valid_i(rny_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rny_cpl_r), .cpl_o(off_cpl), .rny_o(off_rny)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rnt timeout case=%0d", cases); end

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
    rnx = '0;
    rnx.valid = 1'b1;
    rnx.avail_idx = APU_VGPU_TUW_IDXV;
    rnx.device_idx = APU_VGPU_TUW_IDXV;
    rnx.att_addr = APU_VGPU_RAB_CMD;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rny == '0 &&
          off_cpl == '0);
  endtask

  task automatic rnt_step(input apu_vgpu_rnt_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rnt_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    rnt_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnt_req = 1'b0;
    while (!rnt_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rnt_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RNT_OK) begin
      check("doorbell", rnt.valid && rnt.qid == APU_VGPU_QNT_QUEUE &&
            rnt.qid != APU_VGPU_QNT_CURSOR &&
            rnt.avail_idx == 16'd2 &&
            rnt.addr == APU_VGPU_QNT_ADDR &&
            rnt.addr != APU_VGPU_TXC_AVAIL);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_QNT_ADDR);
    end else if (name == "bad beat") begin
      check("one write failed", nwrite == n0 + 1 && !rnt.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rnt_cpl_v);
    rnt_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnt_cpl_r = 1'b0;
    while (rnt_cpl_v) @(negedge clk);
  endtask

  task automatic rnr_step(input apu_vgpu_rnr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rnr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rnr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnr_req = 1'b0;
    while (!rnr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rnr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RNR_OK) begin
      check("echo queue", rnr.valid && rnr.qid == APU_VGPU_QNT_QUEUE &&
            rnr.avail_idx == 16'd2 && rnr.addr == APU_VGPU_QNT_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QNT_ADDR && rd_seen != APU_VGPU_TXC_AVAIL);
    end else if (name == "bad read" || name == "cursor queue") begin
      check("one read failed", nread == n0 + 1 && !rnr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rnr_cpl_v);
    rnr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnr_cpl_r = 1'b0;
    while (rnr_cpl_v) @(negedge clk);
  endtask

  task automatic rny_step(input apu_vgpu_rny_status_e st, input string name);
    @(negedge clk);
    while (!rny_rdy) @(negedge clk);
    cases++;
    rny_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rny_req = 1'b0;
    while (!rny_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rny_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rny_cpl_v);
    rny_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rny_cpl_r = 1'b0;
    while (rny_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rnt_req = 1'b0;
    rnr_req = 1'b0;
    rny_req = 1'b0;
    rnt_cpl_r = 1'b0;
    rnr_cpl_r = 1'b0;
    rny_cpl_r = 1'b0;
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
    rnx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rnt == '0 && rnr == '0 && rny == '0);
    check("profiles keep the doorbell off",
          !ApuOff.RntEn && !ApuOff.RnrEn && !ApuOff.RnyEn &&
          !ApuP1Transport.RntEn && !ApuP1Transport.RnrEn &&
          !ApuP1Transport.RnyEn &&
          !ApuHarness.RntEn && !ApuHarness.RnrEn && !ApuHarness.RnyEn &&
          !ApuSchedBoth.RntEn && !ApuSchedBoth.RnrEn && !ApuSchedBoth.RnyEn &&
          !ApuBadVirglGrant.RntEn && !ApuBadVirglGrant.RnrEn &&
          !ApuBadVirglGrant.RnyEn);
    cfg = ApuP1Transport;
    cfg.RntEn = 1'b1;
    cfg.RnrEn = 1'b1;
    cfg.RnyEn = 1'b1;
    check("doorbell does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RntEn = 1'b1;
    cfg.RnrEn = 1'b1;
    cfg.RnyEn = 1'b1;
    check("doorbell does not legalize virgl", !apu_cfg_legal(cfg));
    check("notify places",
          APU_VGPU_QNT_ADDR == 64'h880D0200 &&
          APU_VGPU_QNT_ADDR != APU_VGPU_TXC_AVAIL && APU_VGPU_QNT_ADDR != APU_VGPU_SNT_ADDR &&
          APU_VGPU_QNT_QUEUE == 32'd0 &&
          APU_VGPU_QNT_CURSOR == 32'd1);

    rnt_step(APU_VGPU_RNT_EMPTY, "write empty");
    rnr_step(APU_VGPU_RNR_EMPTY, "read empty");
    rny_step(APU_VGPU_RNY_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    rnt_step(APU_VGPU_RNT_FAULT, "cancel");
    cancel = 1'b0;
    rnx.avail_idx = 16'd1;
    rnt_step(APU_VGPU_RNT_FAULT, "scene index");
    good_in();
    fail_wr = 1'b1;
    rnt_step(APU_VGPU_RNT_FAULT, "bad beat");
    rnt_step(APU_VGPU_RNT_OK, "doorbell");
    rnt_step(APU_VGPU_RNT_FAULT, "doorbell again");
    check("doorbell stays", rnt.valid && rnt.qid == 32'd0 &&
          rnt.avail_idx == 16'd2);
    fail_rd = 1'b1;
    rnr_step(APU_VGPU_RNR_FAULT, "bad read");
    bad_queue = 1'b1;
    rnr_step(APU_VGPU_RNR_FAULT, "cursor queue");
    rnr_step(APU_VGPU_RNR_OK, "echo queue");
    rnr_step(APU_VGPU_RNR_FAULT, "read again");
    rnx.avail_idx = 16'd1;
    rny_step(APU_VGPU_RNY_FAULT, "keep scene index");
    check("keep rejected", !rny.valid);
    good_in();
    rny_step(APU_VGPU_RNY_OK, "keep queue");
    check("queue kept", rny.valid && rny.qid == 32'd0 &&
          rny.avail_idx == 16'd2);
    rny_step(APU_VGPU_RNY_FAULT, "keep again");
    check("keep stays", rny.qid == rnt.qid);

    pulse_reset();
    check("reset clears", rnt == '0 && rnr == '0 && rny == '0);
    rnx = '0;
    rnt_step(APU_VGPU_RNT_EMPTY, "after reset");
    good_in();
    rnt_step(APU_VGPU_RNT_OK, "doorbell after reset");

    if (errors != 0) $fatal(1, "APU vgpu rnt errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rnt cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
