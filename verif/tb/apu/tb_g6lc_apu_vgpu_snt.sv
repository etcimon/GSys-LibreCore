// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_snt;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_snx_t snx;
  logic snt_req = 0, snt_rdy, snt_cpl_v, snt_cpl_r = 0;
  apu_vgpu_snt_cpl_t snt_cpl;
  apu_vgpu_snt_t snt;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic snr_req = 0, snr_rdy, snr_cpl_v, snr_cpl_r = 0;
  apu_vgpu_snr_cpl_t snr_cpl;
  apu_vgpu_snr_t snr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic sny_req = 0, sny_rdy, sny_cpl_v, sny_cpl_r = 0;
  apu_vgpu_sny_cpl_t sny_cpl, off_cpl;
  apu_vgpu_sny_t sny, off_sny;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_queue = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QNT_QUEUE};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_snt #(.Enable(1'b1)) i_snt (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .snx_i(snx),
    .req_valid_i(snt_req), .req_ready_o(snt_rdy),
    .cpl_valid_o(snt_cpl_v), .cpl_ready_i(snt_cpl_r), .cpl_o(snt_cpl), .snt_o(snt),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_snr #(.Enable(1'b1)) i_snr (
    .clk_i(clk), .rst_ni, .snt_i(snt), .snx_i(snx),
    .req_valid_i(snr_req), .req_ready_o(snr_rdy),
    .cpl_valid_o(snr_cpl_v), .cpl_ready_i(snr_cpl_r), .cpl_o(snr_cpl), .snr_o(snr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_sny #(.Enable(1'b1)) i_sny (
    .clk_i(clk), .rst_ni, .snr_i(snr), .snt_i(snt), .snx_i(snx),
    .req_valid_i(sny_req), .req_ready_o(sny_rdy),
    .cpl_valid_o(sny_cpl_v), .cpl_ready_i(sny_cpl_r), .cpl_o(sny_cpl), .sny_o(sny)
  );
  g6lc_apu_vgpu_sny_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .snr_i(snr), .snt_i(snt), .snx_i(snx),
    .req_valid_i(sny_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sny_cpl_r), .cpl_o(off_cpl), .sny_o(off_sny)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu snt timeout case=%0d", cases); end

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
      if (wr_addr != APU_VGPU_SNT_ADDR || wr_len != 32'd4) order_bad <= 1'b1;
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
      if (rd_addr != APU_VGPU_SNT_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
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
    snx = '0;
    snx.valid = 1'b1;
    snx.avail_idx = APU_VGPU_QSU_IDXV;
    snx.device_idx = APU_VGPU_QSU_IDXV;
    snx.att_addr = APU_VGPU_HDR_ADDR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_sny == '0 &&
          off_cpl == '0);
  endtask

  task automatic snt_step(input apu_vgpu_snt_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!snt_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    snt_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snt_req = 1'b0;
    while (!snt_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), snt_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SNT_OK) begin
      check("doorbell", snt.valid && snt.qid == APU_VGPU_QNT_QUEUE &&
            snt.qid != APU_VGPU_QNT_CURSOR &&
            snt.avail_idx == 16'd1 &&
            snt.addr == APU_VGPU_SNT_ADDR &&
            snt.addr != APU_VGPU_QNT_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_SNT_ADDR);
    end else if (name == "bad beat") begin
      check("one write failed", nwrite == n0 + 1 && !snt.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), snt_cpl_v);
    snt_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snt_cpl_r = 1'b0;
    while (snt_cpl_v) @(negedge clk);
  endtask

  task automatic snr_step(input apu_vgpu_snr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!snr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    snr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snr_req = 1'b0;
    while (!snr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), snr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SNR_OK) begin
      check("echo queue", snr.valid && snr.qid == APU_VGPU_QNT_QUEUE &&
            snr.avail_idx == 16'd1 && snr.addr == APU_VGPU_SNT_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_SNT_ADDR && rd_seen != APU_VGPU_QNT_ADDR);
    end else if (name == "bad read" || name == "cursor queue") begin
      check("one read failed", nread == n0 + 1 && !snr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), snr_cpl_v);
    snr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snr_cpl_r = 1'b0;
    while (snr_cpl_v) @(negedge clk);
  endtask

  task automatic sny_step(input apu_vgpu_sny_status_e st, input string name);
    @(negedge clk);
    while (!sny_rdy) @(negedge clk);
    cases++;
    sny_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sny_req = 1'b0;
    while (!sny_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sny_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), sny_cpl_v);
    sny_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sny_cpl_r = 1'b0;
    while (sny_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    snt_req = 1'b0;
    snr_req = 1'b0;
    sny_req = 1'b0;
    snt_cpl_r = 1'b0;
    snr_cpl_r = 1'b0;
    sny_cpl_r = 1'b0;
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
    snx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          snt == '0 && snr == '0 && sny == '0);
    check("profiles keep the doorbell off",
          !ApuOff.SntEn && !ApuOff.SnrEn && !ApuOff.SnyEn &&
          !ApuP1Transport.SntEn && !ApuP1Transport.SnrEn &&
          !ApuP1Transport.SnyEn &&
          !ApuHarness.SntEn && !ApuHarness.SnrEn && !ApuHarness.SnyEn &&
          !ApuSchedBoth.SntEn && !ApuSchedBoth.SnrEn && !ApuSchedBoth.SnyEn &&
          !ApuBadVirglGrant.SntEn && !ApuBadVirglGrant.SnrEn &&
          !ApuBadVirglGrant.SnyEn);
    cfg = ApuP1Transport;
    cfg.SntEn = 1'b1;
    cfg.SnrEn = 1'b1;
    cfg.SnyEn = 1'b1;
    check("doorbell does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SntEn = 1'b1;
    cfg.SnrEn = 1'b1;
    cfg.SnyEn = 1'b1;
    check("doorbell does not legalize virgl", !apu_cfg_legal(cfg));
    check("notify places",
          APU_VGPU_SNT_ADDR == 64'h8800E220 &&
          APU_VGPU_SNT_ADDR != APU_VGPU_QNT_ADDR &&
          APU_VGPU_QNT_QUEUE == 32'd0 &&
          APU_VGPU_QNT_CURSOR == 32'd1);

    snt_step(APU_VGPU_SNT_EMPTY, "write empty");
    snr_step(APU_VGPU_SNR_EMPTY, "read empty");
    sny_step(APU_VGPU_SNY_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    snt_step(APU_VGPU_SNT_FAULT, "cancel");
    cancel = 1'b0;
    snx.avail_idx = APU_VGPU_TUW_IDXV;
    snt_step(APU_VGPU_SNT_FAULT, "xfer index");
    good_in();
    fail_wr = 1'b1;
    snt_step(APU_VGPU_SNT_FAULT, "bad beat");
    snt_step(APU_VGPU_SNT_OK, "doorbell");
    snt_step(APU_VGPU_SNT_FAULT, "doorbell again");
    check("doorbell stays", snt.valid && snt.qid == 32'd0 &&
          snt.avail_idx == 16'd1);
    fail_rd = 1'b1;
    snr_step(APU_VGPU_SNR_FAULT, "bad read");
    bad_queue = 1'b1;
    snr_step(APU_VGPU_SNR_FAULT, "cursor queue");
    snr_step(APU_VGPU_SNR_OK, "echo queue");
    snr_step(APU_VGPU_SNR_FAULT, "read again");
    snx.avail_idx = APU_VGPU_TUW_IDXV;
    sny_step(APU_VGPU_SNY_FAULT, "keep xfer index");
    check("keep rejected", !sny.valid);
    good_in();
    sny_step(APU_VGPU_SNY_OK, "keep queue");
    check("queue kept", sny.valid && sny.qid == 32'd0 &&
          sny.avail_idx == 16'd1);
    sny_step(APU_VGPU_SNY_FAULT, "keep again");
    check("keep stays", sny.qid == snt.qid);

    pulse_reset();
    check("reset clears", snt == '0 && snr == '0 && sny == '0);
    snx = '0;
    snt_step(APU_VGPU_SNT_EMPTY, "after reset");
    good_in();
    snt_step(APU_VGPU_SNT_OK, "doorbell after reset");

    if (errors != 0) $fatal(1, "APU vgpu snt errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_snt cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
