// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_gnw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sny_t sny;
  logic gnw_req = 0, gnw_rdy, gnw_cpl_v, gnw_cpl_r = 0;
  apu_vgpu_gnw_cpl_t gnw_cpl;
  apu_vgpu_gnw_t gnw;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen0 = 0, seen1 = 0, seen2 = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic gnk_req = 0, gnk_rdy, gnk_cpl_v, gnk_cpl_r = 0;
  apu_vgpu_gnk_cpl_t gnk_cpl;
  apu_vgpu_gnk_t gnk;
  logic gnx_req = 0, gnx_rdy, gnx_cpl_v, gnx_cpl_r = 0;
  apu_vgpu_gnx_cpl_t gnx_cpl, off_cpl;
  apu_vgpu_gnx_t gnx, off_gnx;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_link = 0, bad_ind = 0, bad_len = 0;
  logic bad_write = 0, bad_idx = 0, bad_ring = 0, order_bad = 0;
  logic poison_txc = 0, poison_av = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] D0Meta = {16'd1, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D1Meta = {16'd2, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D2Meta = {16'd0, VIRTQ_DESC_F_WRITE};
  localparam logic [31:0] IndMeta = {16'd1, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT};
  localparam logic [31:0] JumpMeta = {16'd2, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] AvailWord = {16'd1, 16'h0};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_gnw #(.Enable(1'b1)) i_gnw (
    .clk_i(clk), .rst_ni, .sny_i(sny),
    .req_valid_i(gnw_req), .req_ready_o(gnw_rdy),
    .cpl_valid_o(gnw_cpl_v), .cpl_ready_i(gnw_cpl_r), .cpl_o(gnw_cpl), .gnw_o(gnw),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_gnk #(.Enable(1'b1)) i_gnk (
    .clk_i(clk), .rst_ni, .gnw_i(gnw), .sny_i(sny),
    .req_valid_i(gnk_req), .req_ready_o(gnk_rdy),
    .cpl_valid_o(gnk_cpl_v), .cpl_ready_i(gnk_cpl_r), .cpl_o(gnk_cpl), .gnk_o(gnk)
  );
  g6lc_apu_vgpu_gnx #(.Enable(1'b1)) i_gnx (
    .clk_i(clk), .rst_ni, .gnk_i(gnk), .gnw_i(gnw), .sny_i(sny),
    .req_valid_i(gnx_req), .req_ready_o(gnx_rdy),
    .cpl_valid_o(gnx_cpl_v), .cpl_ready_i(gnx_cpl_r), .cpl_o(gnx_cpl), .gnx_o(gnx)
  );
  g6lc_apu_vgpu_gnx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .gnk_i(gnk), .gnw_i(gnw), .sny_i(sny),
    .req_valid_i(gnx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(gnx_cpl_r), .cpl_o(off_cpl), .gnx_o(off_gnx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu gnw timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      beat_data[63:0] = APU_VGPU_HDR_ADDR;
      beat_data[95:64] = VGPU_SUBMIT_BYTES;
      beat_data[127:96] = bad_ind ? IndMeta : (bad_link ? JumpMeta : D0Meta);
      beat_data[191:128] = APU_VGPU_EXEC_ADDR;
      beat_data[223:192] = bad_len ? 32'd32 : APU_VGPU_SCENE_BYTES;
      beat_data[255:224] = D1Meta;
    end else if (idx == 1) begin
      beat_data[63:0] = APU_VGPU_RSP_ADDR;
      beat_data[95:64] = VGPU_RESP_HDR_BYTES;
      beat_data[127:96] = bad_write ? D0Meta : D2Meta;
      beat_data[191:128] = 64'h1;
    end else begin
      beat_data[31:0] = bad_idx ? {16'd2, 16'h0} : AvailWord;
      beat_data[47:32] = bad_ring ? 16'd1 : 16'd0;
      beat_data[63:48] = 16'h7;
      beat_data[95:64] = 32'h1111_1111;
    end
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nread - run_base;
      want = idx == 0 ? APU_VGPU_NXC_DESC :
             idx == 1 ? APU_VGPU_NXC_LAST : APU_VGPU_NXC_AVAIL;
      if (rd_addr != want) order_bad <= 1'b1;
      if (idx == 0) seen0 <= rd_addr;
      if (idx == 1) seen1 <= rd_addr;
      seen2 <= rd_addr;
      rsp_addr <= poison_txc ? APU_VGPU_TXC_DESC :
                  poison_av ? APU_VGPU_TXC_AVAIL : rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data(idx);
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      poison_txc <= 1'b0;
      poison_av <= 1'b0;
      if (idx == 0) begin
        bad_link <= 1'b0;
        bad_ind <= 1'b0;
        bad_len <= 1'b0;
      end
      if (idx == 1) bad_write <= 1'b0;
      if (idx == 2) begin
        bad_idx <= 1'b0;
        bad_ring <= 1'b0;
      end
      nread <= nread + 1;
      rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_gnx == '0 &&
          off_cpl == '0);
  endtask

  task automatic good_in;
    sny = '0;
    sny.valid = 1'b1;
    sny.qid = APU_VGPU_QNT_QUEUE;
    sny.avail_idx = 16'd1;
  endtask

  function automatic logic chain_ok(input apu_vgpu_gnw_t rec);
    chain_ok = rec.valid && rec.head == 16'd0 && rec.avail_idx == 16'd1 &&
               rec.device_idx == 16'd1 &&
               rec.buf_len == APU_VGPU_SCENE_BYTES &&
               rec.buf_addr == APU_VGPU_EXEC_ADDR &&
               rec.rsp_addr == APU_VGPU_RSP_ADDR && rec.head != rec.avail_idx;
  endfunction

  task automatic gnw_step(input apu_vgpu_gnw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gnw_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    gnw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gnw_req = 1'b0;
    while (!gnw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gnw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GNW_OK) begin
      check("scene chain", chain_ok(gnw));
      check("read count", nread == n0 + 3 && !order_bad &&
            seen0 == APU_VGPU_NXC_DESC && seen1 == APU_VGPU_NXC_LAST &&
            seen2 == APU_VGPU_NXC_AVAIL);
    end else if (name == "bad beat" || name == "bad dest" ||
                 name == "bad avail dest" || name == "bad link" ||
                 name == "bad indirect" || name == "bad len") begin
      check("one beat", nread == n0 + 1 && !gnw.valid);
    end else if (name == "bad write") begin
      check("two beats", nread == n0 + 2 && !gnw.valid);
    end else if (name == "bad idx" || name == "bad ring") begin
      check("three beats", nread == n0 + 3 && !gnw.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), gnw_cpl_v);
    gnw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gnw_cpl_r = 1'b0;
    while (gnw_cpl_v) @(negedge clk);
  endtask

  task automatic gnk_step(input apu_vgpu_gnk_status_e st, input string name);
    @(negedge clk);
    while (!gnk_rdy) @(negedge clk);
    cases++;
    gnk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gnk_req = 1'b0;
    while (!gnk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gnk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gnk_cpl_v);
    gnk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gnk_cpl_r = 1'b0;
    while (gnk_cpl_v) @(negedge clk);
  endtask

  task automatic gnx_step(input apu_vgpu_gnx_status_e st, input string name);
    @(negedge clk);
    while (!gnx_rdy) @(negedge clk);
    cases++;
    gnx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gnx_req = 1'b0;
    while (!gnx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gnx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gnx_cpl_v);
    gnx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gnx_cpl_r = 1'b0;
    while (gnx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    gnw_req = 1'b0;
    gnk_req = 1'b0;
    gnx_req = 1'b0;
    gnw_cpl_r = 1'b0;
    gnk_cpl_r = 1'b0;
    gnx_cpl_r = 1'b0;
    rsp_v = 1'b0;
    fail_next = 1'b0;
    poison_txc = 1'b0;
    poison_av = 1'b0;
    bad_link = 1'b0;
    bad_ind = 1'b0;
    bad_len = 1'b0;
    bad_write = 1'b0;
    bad_idx = 1'b0;
    bad_ring = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    sny = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && gnw == '0 &&
          gnk == '0 && gnx == '0);
    check("profiles keep the chain off",
          !ApuOff.GnwEn && !ApuOff.GnkEn && !ApuOff.GnxEn &&
          !ApuP1Transport.GnwEn && !ApuP1Transport.GnkEn &&
          !ApuP1Transport.GnxEn &&
          !ApuHarness.GnwEn && !ApuHarness.GnkEn && !ApuHarness.GnxEn &&
          !ApuSchedBoth.GnwEn && !ApuSchedBoth.GnkEn && !ApuSchedBoth.GnxEn &&
          !ApuBadVirglGrant.GnwEn && !ApuBadVirglGrant.GnkEn &&
          !ApuBadVirglGrant.GnxEn);
    cfg = ApuP1Transport;
    cfg.GnwEn = 1'b1;
    cfg.GnkEn = 1'b1;
    cfg.GnxEn = 1'b1;
    check("chain does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GnwEn = 1'b1;
    cfg.GnkEn = 1'b1;
    cfg.GnxEn = 1'b1;
    check("chain does not legalize virgl", !apu_cfg_legal(cfg));
    check("chain places",
          APU_VGPU_NXC_DESC == 64'h8800E100 &&
          APU_VGPU_NXC_LAST == 64'h8800E120 &&
          APU_VGPU_NXC_AVAIL == 64'h8800E200 &&
          APU_VGPU_TXC_DESC == 64'h880D0000 &&
          APU_VGPU_TXC_AVAIL == 64'h880D0100 &&
          APU_VGPU_QNT_QUEUE == 32'd0 &&
          APU_VGPU_TUW_IDXV == 16'd2 &&
          APU_VGPU_NXC_DESC != APU_VGPU_TXC_DESC &&
          APU_VGPU_NXC_AVAIL != APU_VGPU_TXC_AVAIL &&
          APU_VGPU_NXC_DESC != APU_VGPU_EXEC_ADDR &&
          D0Meta == 32'h00010001 && D1Meta == 32'h00020001 &&
          D2Meta == 32'h00000002 && AvailWord == 32'h00010000 &&
          VGPU_SUBMIT_BYTES == 32'd32 && VGPU_RESP_HDR_BYTES == 32'd24 &&
          APU_VGPU_SCENE_BYTES == 32'd960);

    gnw_step(APU_VGPU_GNW_EMPTY, "chain empty");
    gnk_step(APU_VGPU_GNK_EMPTY, "keep empty");
    gnx_step(APU_VGPU_GNX_EMPTY, "check empty");
    good_in();
    sny = '0;
    gnw_step(APU_VGPU_GNW_EMPTY, "notify missing");
    good_in();
    sny.qid = 32'd1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad queue");
    good_in();
    sny.avail_idx = APU_VGPU_TUW_IDXV;
    gnw_step(APU_VGPU_GNW_FAULT, "transfer idx");
    good_in();
    fail_next = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad beat");
    good_in();
    poison_txc = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad dest");
    good_in();
    poison_av = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad avail dest");
    good_in();
    bad_link = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad link");
    good_in();
    bad_ind = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad indirect");
    good_in();
    bad_len = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad len");
    good_in();
    bad_write = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad write");
    good_in();
    bad_idx = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad idx");
    good_in();
    bad_ring = 1'b1;
    gnw_step(APU_VGPU_GNW_FAULT, "bad ring");
    good_in();
    gnw_step(APU_VGPU_GNW_OK, "scene chain");
    gnw_step(APU_VGPU_GNW_FAULT, "scene chain again");
    check("scene chain stays", chain_ok(gnw) && sny.qid == APU_VGPU_QNT_QUEUE &&
          gnw.device_idx == 16'd1);
    sny.qid = 32'd1;
    gnk_step(APU_VGPU_GNK_FAULT, "keep bad queue");
    check("keep rejected", !gnk.valid);
    sny.qid = APU_VGPU_QNT_QUEUE;
    gnk_step(APU_VGPU_GNK_OK, "keep scene chain");
    check("scene chain kept", gnk.valid && gnk.head == 16'd0 &&
          gnk.avail_idx == 16'd1 && gnk.device_idx == 16'd1 &&
          gnk.buf_addr == APU_VGPU_EXEC_ADDR &&
          gnk.rsp_addr == APU_VGPU_RSP_ADDR);
    gnk_step(APU_VGPU_GNK_FAULT, "scene chain keep again");
    check("scene chain keep stays", gnk.avail_idx == 16'd1 &&
          gnk.device_idx == 16'd1);
    sny.qid = 32'd1;
    gnx_step(APU_VGPU_GNX_FAULT, "check bad queue");
    check("check rejected", !gnx.valid);
    sny.qid = APU_VGPU_QNT_QUEUE;
    gnx_step(APU_VGPU_GNX_OK, "check scene chain");
    check("scene chain checked", gnx.valid && gnx.avail_idx == 16'd1 &&
          gnx.device_idx == 16'd1 && gnx.buf_addr == APU_VGPU_EXEC_ADDR);
    gnx_step(APU_VGPU_GNX_FAULT, "scene chain check again");

    pulse_reset();
    check("reset clears", gnw == '0 && gnk == '0 && gnx == '0);
    zero_in();
    gnw_step(APU_VGPU_GNW_EMPTY, "after reset");
    gnk_step(APU_VGPU_GNK_EMPTY, "keep after reset");
    gnx_step(APU_VGPU_GNX_EMPTY, "check after reset");

    if (errors != 0) $fatal(1, "APU vgpu gnw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_gnw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
