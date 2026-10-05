// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_txc;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_tax_t tax;
  apu_vgpu_rax_t rax;
  apu_vgpu_tfx_t tfx;
  logic txc_req = 0, txc_rdy, txc_cpl_v, txc_cpl_r = 0;
  apu_vgpu_txc_cpl_t txc_cpl;
  apu_vgpu_txc_t txc;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen0 = 0, seen1 = 0, seen2 = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic txk_req = 0, txk_rdy, txk_cpl_v, txk_cpl_r = 0;
  apu_vgpu_txk_cpl_t txk_cpl;
  apu_vgpu_txk_t txk;
  logic txx_req = 0, txx_rdy, txx_cpl_v, txx_cpl_r = 0;
  apu_vgpu_txx_cpl_t txx_cpl, off_cpl;
  apu_vgpu_txx_t txx, off_txx;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_link = 0, bad_ind = 0, bad_len = 0;
  logic bad_write = 0, bad_idx = 0, bad_ring = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] D0Meta = {16'd1, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D1Meta = {16'd2, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D2Meta = {16'd0, VIRTQ_DESC_F_WRITE};
  localparam logic [31:0] IndMeta = {16'd1, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT};
  localparam logic [31:0] JumpMeta = {16'd2, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] AvailWord = {16'd2, 16'h0};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_txc #(.Enable(1'b1)) i_txc (
    .clk_i(clk), .rst_ni, .tax_i(tax), .rax_i(rax), .tfx_i(tfx),
    .req_valid_i(txc_req), .req_ready_o(txc_rdy),
    .cpl_valid_o(txc_cpl_v), .cpl_ready_i(txc_cpl_r), .cpl_o(txc_cpl), .txc_o(txc),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_txk #(.Enable(1'b1)) i_txk (
    .clk_i(clk), .rst_ni, .txc_i(txc), .tax_i(tax), .rax_i(rax), .tfx_i(tfx),
    .req_valid_i(txk_req), .req_ready_o(txk_rdy),
    .cpl_valid_o(txk_cpl_v), .cpl_ready_i(txk_cpl_r), .cpl_o(txk_cpl), .txk_o(txk)
  );
  g6lc_apu_vgpu_txx #(.Enable(1'b1)) i_txx (
    .clk_i(clk), .rst_ni, .txk_i(txk), .txc_i(txc), .tax_i(tax),
    .req_valid_i(txx_req), .req_ready_o(txx_rdy),
    .cpl_valid_o(txx_cpl_v), .cpl_ready_i(txx_cpl_r), .cpl_o(txx_cpl), .txx_o(txx)
  );
  g6lc_apu_vgpu_txx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .txk_i(txk), .txc_i(txc), .tax_i(tax),
    .req_valid_i(txx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(txx_cpl_r), .cpl_o(off_cpl), .txx_o(off_txx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu txc timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      beat_data[63:0] = APU_VGPU_RAB_CMD;
      beat_data[95:64] = APU_VGPU_RAB_BYTES;
      beat_data[127:96] = bad_ind ? IndMeta : (bad_link ? JumpMeta : D0Meta);
      beat_data[191:128] = APU_VGPU_TFB_CMD;
      beat_data[223:192] = bad_len ? 32'd32 : APU_VGPU_TFB_BYTES;
      beat_data[255:224] = D1Meta;
    end else if (idx == 1) begin
      beat_data[63:0] = APU_VGPU_RFW_ADDR;
      beat_data[95:64] = VGPU_RESP_HDR_BYTES;
      beat_data[127:96] = bad_write ? D0Meta : D2Meta;
      beat_data[191:128] = 64'h1;
    end else begin
      beat_data[31:0] = bad_idx ? {16'd1, 16'h0} : AvailWord;
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
      want = idx == 0 ? APU_VGPU_TXC_DESC :
             idx == 1 ? APU_VGPU_TXC_LAST : APU_VGPU_TXC_AVAIL;
      if (rd_addr != want) order_bad <= 1'b1;
      if (idx == 0) seen0 <= rd_addr;
      if (idx == 1) seen1 <= rd_addr;
      seen2 <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data(idx);
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
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

  task automatic good_in;
    tax = '0;
    tax.valid = 1'b1;
    tax.ack = APU_VGPU_TIW_REASON;
    tax.remain = APU_VGPU_VAW_CLEAR;
    tax.used_idx = APU_VGPU_TUW_IDXV;
    rax = '0;
    rax.valid = 1'b1;
    rax.length = APU_VGPU_GBD_BYTES;
    rax.addr = APU_VGPU_RPW_DST;
    rax.resource_id = APU_VIRGL_RES_RT;
    tfx = '0;
    tfx.valid = 1'b1;
    tfx.stride = APU_VGPU_TFB_STRIDE;
    tfx.x = 16'd0;
    tfx.y = 16'd0;
    tfx.res_w = APU_VGPU_RT_W;
  endtask

  function automatic logic chain_ok(input apu_vgpu_txc_t rec);
    chain_ok = rec.valid && rec.head == 16'd0 && rec.avail_idx == 16'd2 &&
               rec.att_len == APU_VGPU_RAB_BYTES &&
               rec.att_addr == APU_VGPU_RAB_CMD &&
               rec.xfer_addr == APU_VGPU_TFB_CMD &&
               rec.rsp_addr == APU_VGPU_RFW_ADDR && rec.head != rec.avail_idx;
  endfunction

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_txx == '0 &&
          off_cpl == '0);
  endtask

  task automatic txc_step(input apu_vgpu_txc_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!txc_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    txc_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    txc_req = 1'b0;
    while (!txc_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), txc_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TXC_OK) begin
      check("transfer chain", chain_ok(txc));
      check("read count", nread == n0 + 3 && !order_bad &&
            seen0 == APU_VGPU_TXC_DESC && seen1 == APU_VGPU_TXC_LAST &&
            seen2 == APU_VGPU_TXC_AVAIL);
    end else if (name == "bad beat" || name == "bad link" || name == "bad indirect" ||
                 name == "bad len") begin
      check("one beat", nread == n0 + 1 && !txc.valid);
    end else if (name == "bad write") begin
      check("two beats", nread == n0 + 2 && !txc.valid);
    end else if (name == "bad idx" || name == "bad ring") begin
      check("three beats", nread == n0 + 3 && !txc.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), txc_cpl_v);
    txc_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    txc_cpl_r = 1'b0;
    while (txc_cpl_v) @(negedge clk);
  endtask

  task automatic txk_step(input apu_vgpu_txk_status_e st, input string name);
    @(negedge clk);
    while (!txk_rdy) @(negedge clk);
    cases++;
    txk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    txk_req = 1'b0;
    while (!txk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), txk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), txk_cpl_v);
    txk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    txk_cpl_r = 1'b0;
    while (txk_cpl_v) @(negedge clk);
  endtask

  task automatic txx_step(input apu_vgpu_txx_status_e st, input string name);
    @(negedge clk);
    while (!txx_rdy) @(negedge clk);
    cases++;
    txx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    txx_req = 1'b0;
    while (!txx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), txx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), txx_cpl_v);
    txx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    txx_cpl_r = 1'b0;
    while (txx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    txc_req = 1'b0;
    txk_req = 1'b0;
    txx_req = 1'b0;
    txc_cpl_r = 1'b0;
    txk_cpl_r = 1'b0;
    txx_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    tax = '0;
    rax = '0;
    tfx = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && txc == '0 &&
          txk == '0 && txx == '0);
    check("profiles keep the chain off",
          !ApuOff.TxcEn && !ApuOff.TxkEn && !ApuOff.TxxEn &&
          !ApuP1Transport.TxcEn && !ApuP1Transport.TxkEn && !ApuP1Transport.TxxEn &&
          !ApuHarness.TxcEn && !ApuHarness.TxkEn && !ApuHarness.TxxEn &&
          !ApuSchedBoth.TxcEn && !ApuSchedBoth.TxkEn && !ApuSchedBoth.TxxEn &&
          !ApuBadVirglGrant.TxcEn && !ApuBadVirglGrant.TxkEn &&
          !ApuBadVirglGrant.TxxEn);
    cfg = ApuP1Transport;
    cfg.TxcEn = 1'b1;
    cfg.TxkEn = 1'b1;
    cfg.TxxEn = 1'b1;
    check("chain does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TxcEn = 1'b1;
    cfg.TxkEn = 1'b1;
    cfg.TxxEn = 1'b1;
    check("chain does not legalize virgl", !apu_cfg_legal(cfg));
    check("chain places",
          APU_VGPU_TXC_DESC == 64'h880D0000 &&
          APU_VGPU_TXC_LAST == 64'h880D0020 &&
          APU_VGPU_TXC_AVAIL == 64'h880D0100 &&
          APU_VGPU_TXC_DESC != APU_VGPU_NXC_DESC &&
          APU_VGPU_TXC_AVAIL != APU_VGPU_NXC_AVAIL &&
          APU_VGPU_TXC_DESC != APU_VGPU_RAB_CMD &&
          D0Meta == 32'h00010001 && D1Meta == 32'h00020001 &&
          D2Meta == 32'h00000002 && AvailWord == 32'h00020000 &&
          APU_VGPU_RAB_BYTES == 32'd64 && APU_VGPU_TFB_BYTES == 32'd96 &&
          VGPU_RESP_HDR_BYTES == 32'd24);

    txc_step(APU_VGPU_TXC_EMPTY, "chain empty");
    txk_step(APU_VGPU_TXK_EMPTY, "keep empty");
    txx_step(APU_VGPU_TXX_EMPTY, "check empty");
    good_in();
    tax = '0;
    txc_step(APU_VGPU_TXC_EMPTY, "ack missing");
    good_in();
    tax.used_idx = 16'd1;
    txc_step(APU_VGPU_TXC_FAULT, "scene index");
    good_in();
    tfx.res_w = 32'd64;
    txc_step(APU_VGPU_TXC_FAULT, "egl size");
    good_in();
    fail_next = 1'b1;
    txc_step(APU_VGPU_TXC_FAULT, "bad beat");
    good_in();
    bad_link = 1'b1;
    txc_step(APU_VGPU_TXC_FAULT, "bad link");
    good_in();
    bad_ind = 1'b1;
    txc_step(APU_VGPU_TXC_FAULT, "bad indirect");
    good_in();
    bad_len = 1'b1;
    txc_step(APU_VGPU_TXC_FAULT, "bad len");
    good_in();
    bad_write = 1'b1;
    txc_step(APU_VGPU_TXC_FAULT, "bad write");
    good_in();
    bad_idx = 1'b1;
    txc_step(APU_VGPU_TXC_FAULT, "bad idx");
    good_in();
    bad_ring = 1'b1;
    txc_step(APU_VGPU_TXC_FAULT, "bad ring");
    good_in();
    txc_step(APU_VGPU_TXC_OK, "chain");
    txc_step(APU_VGPU_TXC_FAULT, "chain again");
    check("chain stays", chain_ok(txc));
    rax.length = APU_VGPU_SCAN_BYTES;
    txk_step(APU_VGPU_TXK_FAULT, "keep bad length");
    check("keep rejected", !txk.valid);
    rax.length = APU_VGPU_GBD_BYTES;
    txk_step(APU_VGPU_TXK_OK, "keep chain");
    check("chain kept", txk.valid && txk.avail_idx == 16'd2 &&
          txk.att_addr == APU_VGPU_RAB_CMD &&
          txk.att_addr != APU_VGPU_NXC_DESC);
    txk_step(APU_VGPU_TXK_FAULT, "keep again");
    tax.used_idx = 16'd1;
    txx_step(APU_VGPU_TXX_FAULT, "check scene index");
    check("check rejected", !txx.valid);
    tax.used_idx = APU_VGPU_TUW_IDXV;
    txx_step(APU_VGPU_TXX_OK, "check chain");
    check("index kept", txx.valid && txx.avail_idx == 16'd2 &&
          txx.att_addr == APU_VGPU_RAB_CMD);
    txx_step(APU_VGPU_TXX_FAULT, "check again");
    check("check stays", txx.avail_idx == txc.avail_idx);

    pulse_reset();
    check("reset clears", txc == '0 && txk == '0 && txx == '0);
    zero_in();
    txc_step(APU_VGPU_TXC_EMPTY, "after reset");
    good_in();
    txc_step(APU_VGPU_TXC_OK, "chain after reset");

    if (errors != 0) $fatal(1, "APU vgpu txc errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_txc cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
