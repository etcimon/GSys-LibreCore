// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rnw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sgx_t sgx;
  logic rnw_req = 0, rnw_rdy, rnw_cpl_v, rnw_cpl_r = 0;
  apu_vgpu_rnw_req_t treq;
  apu_vgpu_rnw_cpl_t rnw_cpl;
  apu_vgpu_rnw_t rnw;
  logic [15:0] avail_idx, device_idx;
  logic rnk_req = 0, rnk_rdy, rnk_cpl_v, rnk_cpl_r = 0;
  apu_vgpu_rnk_cpl_t rnk_cpl;
  apu_vgpu_rnk_t rnk;
  logic rnx_req = 0, rnx_rdy, rnx_cpl_v, rnx_cpl_r = 0;
  apu_vgpu_rnx_cpl_t rnx_cpl, off_cpl;
  apu_vgpu_rnx_t rnx, off_rnx;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_rnw #(.Enable(1'b1)) i_rnw (
    .clk_i(clk), .rst_ni, .sgx_i(sgx),
    .req_valid_i(rnw_req), .req_ready_o(rnw_rdy), .req_i(treq),
    .cpl_valid_o(rnw_cpl_v), .cpl_ready_i(rnw_cpl_r), .cpl_o(rnw_cpl), .rnw_o(rnw),
    .avail_idx_o(avail_idx), .device_idx_o(device_idx)
  );
  g6lc_apu_vgpu_rnk #(.Enable(1'b1)) i_rnk (
    .clk_i(clk), .rst_ni, .rnw_i(rnw), .sgx_i(sgx),
    .req_valid_i(rnk_req), .req_ready_o(rnk_rdy),
    .cpl_valid_o(rnk_cpl_v), .cpl_ready_i(rnk_cpl_r), .cpl_o(rnk_cpl), .rnk_o(rnk)
  );
  g6lc_apu_vgpu_rnx #(.Enable(1'b1)) i_rnx (
    .clk_i(clk), .rst_ni, .rnk_i(rnk), .rnw_i(rnw), .sgx_i(sgx),
    .req_valid_i(rnx_req), .req_ready_o(rnx_rdy),
    .cpl_valid_o(rnx_cpl_v), .cpl_ready_i(rnx_cpl_r), .cpl_o(rnx_cpl), .rnx_o(rnx)
  );
  g6lc_apu_vgpu_rnx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rnk_i(rnk), .rnw_i(rnw), .sgx_i(sgx),
    .req_valid_i(rnx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rnx_cpl_r), .cpl_o(off_cpl), .rnx_o(off_rnx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rnw timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rnx == '0 &&
          off_cpl == '0);
  endtask

  function automatic apu_vgpu_desc_t dsc(
    input logic [63:0] addr,
    input logic [31:0] len,
    input logic [15:0] flags,
    input logic [15:0] nxt
  );
    dsc = '0;
    dsc.addr = addr;
    dsc.len = len;
    dsc.flags = flags;
    dsc.next = nxt;
  endfunction

  task automatic good_sgx;
    sgx = '0;
    sgx.valid = 1'b1;
    sgx.ack = APU_VGPU_QSI_REASON;
    sgx.remain = APU_VGPU_VAW_CLEAR;
    sgx.used_idx = APU_VGPU_QSU_IDXV;
  endtask

  task automatic rnw_step(input apu_vgpu_rnw_status_e st, input string name);
    @(negedge clk);
    while (!rnw_rdy) @(negedge clk);
    cases++;
    rnw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnw_req = 1'b0;
    while (!rnw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rnw_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rnw_cpl_v);
    rnw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnw_cpl_r = 1'b0;
    while (rnw_cpl_v) @(negedge clk);
  endtask

  task automatic post_desc(
    input logic [15:0] id,
    input apu_vgpu_desc_t d,
    input apu_vgpu_rnw_status_e st,
    input string name
  );
    treq = '0;
    treq.op = APU_VGPU_RNW_POST;
    treq.desc_id = id;
    treq.desc = d;
    rnw_step(st, name);
  endtask

  task automatic post_xfer;
    post_desc(16'd0, dsc(APU_VGPU_RAB_CMD, APU_VGPU_RAB_BYTES, VIRTQ_DESC_F_NEXT, 16'd1),
              APU_VGPU_RNW_OK, "post0");
    post_desc(16'd1, dsc(APU_VGPU_TFB_CMD, APU_VGPU_TFB_BYTES, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_RNW_OK, "post1");
    post_desc(16'd2, dsc(APU_VGPU_RFW_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_RNW_OK, "post2");
  endtask

  task automatic rnk_step(input apu_vgpu_rnk_status_e st, input string name);
    @(negedge clk);
    while (!rnk_rdy) @(negedge clk);
    cases++;
    rnk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnk_req = 1'b0;
    while (!rnk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rnk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rnk_cpl_v);
    rnk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnk_cpl_r = 1'b0;
    while (rnk_cpl_v) @(negedge clk);
  endtask

  task automatic rnx_step(input apu_vgpu_rnx_status_e st, input string name);
    @(negedge clk);
    while (!rnx_rdy) @(negedge clk);
    cases++;
    rnx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnx_req = 1'b0;
    while (!rnx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rnx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rnx_cpl_v);
    rnx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rnx_cpl_r = 1'b0;
    while (rnx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rnw_req = 1'b0;
    rnk_req = 1'b0;
    rnx_req = 1'b0;
    rnw_cpl_r = 1'b0;
    rnk_cpl_r = 1'b0;
    rnx_cpl_r = 1'b0;
    treq = '0;
    sgx = '0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    sgx = '0;
    treq = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rnw == '0 && rnk == '0 && rnx == '0);
    check("device starts after the scene", avail_idx == 16'd1 &&
          device_idx == 16'd1);
    check("profiles keep the walker off",
          !ApuOff.RnwEn && !ApuOff.RnkEn && !ApuOff.RnxEn &&
          !ApuP1Transport.RnwEn && !ApuP1Transport.RnkEn &&
          !ApuP1Transport.RnxEn &&
          !ApuHarness.RnwEn && !ApuHarness.RnkEn && !ApuHarness.RnxEn &&
          !ApuSchedBoth.RnwEn && !ApuSchedBoth.RnkEn && !ApuSchedBoth.RnxEn &&
          !ApuBadVirglGrant.RnwEn && !ApuBadVirglGrant.RnkEn &&
          !ApuBadVirglGrant.RnxEn);
    cfg = ApuP1Transport;
    cfg.RnwEn = 1'b1;
    cfg.RnkEn = 1'b1;
    cfg.RnxEn = 1'b1;
    check("walker does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RnwEn = 1'b1;
    cfg.RnkEn = 1'b1;
    cfg.RnxEn = 1'b1;
    check("walker does not legalize virgl", !apu_cfg_legal(cfg));
    check("transfer places",
          APU_VGPU_RAB_CMD != APU_VGPU_NXC_DESC &&
          APU_VGPU_RAB_CMD != APU_VGPU_HDR_ADDR &&
          APU_VGPU_TUW_IDXV == 16'd2 &&
          APU_VGPU_RAB_BYTES == 32'd64 &&
          APU_VGPU_TFB_BYTES == 32'd96);

    treq = '0;
    treq.op = APU_VGPU_RNW_WALK;
    rnw_step(APU_VGPU_RNW_EMPTY, "walk empty");
    rnk_step(APU_VGPU_RNK_EMPTY, "keep empty");
    rnx_step(APU_VGPU_RNX_EMPTY, "check empty");
    post_desc(16'd2, dsc(APU_VGPU_RFW_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_RNW_FAULT, "post skip");
    check("skip keeps", !rnw.valid && device_idx == 16'd1);
    post_desc(16'd0, dsc(APU_VGPU_RAB_CMD, APU_VGPU_RAB_BYTES,
                         VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT, 16'd1),
              APU_VGPU_RNW_OK, "post indirect");
    post_desc(16'd1, dsc(APU_VGPU_TFB_CMD, 32'd32, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_RNW_OK, "post short");
    post_desc(16'd2, dsc(APU_VGPU_RFW_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_RNW_OK, "post rsp");
    treq = '0;
    treq.op = APU_VGPU_RNW_AVAIL;
    treq.avail_idx = 16'd1;
    treq.desc_id = 16'd0;
    rnw_step(APU_VGPU_RNW_FAULT, "scene index");
    check("scene keeps", avail_idx == 16'd1 && device_idx == 16'd1);
    treq.avail_idx = 16'd5;
    rnw_step(APU_VGPU_RNW_FAULT, "avail jump");
    treq.avail_idx = 16'd2;
    rnw_step(APU_VGPU_RNW_OK, "avail");
    check("avail armed", avail_idx == 16'd2 && device_idx == 16'd1);
    treq = '0;
    treq.op = APU_VGPU_RNW_WALK;
    rnw_step(APU_VGPU_RNW_EMPTY, "walk guest missing");
    good_sgx();
    rnw_step(APU_VGPU_RNW_FAULT, "bad chain");
    check("bad keeps", !rnw.valid && device_idx == 16'd1);
    post_xfer();
    treq = '0;
    treq.op = APU_VGPU_RNW_WALK;
    rnw_step(APU_VGPU_RNW_OK, "walk");
    check("chain record", rnw.valid && rnw.head == 16'd0 &&
          rnw.avail_idx == 16'd2 && rnw.device_idx == 16'd2 &&
          rnw.att_addr == APU_VGPU_RAB_CMD &&
          rnw.xfer_addr == APU_VGPU_TFB_CMD &&
          rnw.rsp_addr == APU_VGPU_RFW_ADDR &&
          rnw.att_addr != APU_VGPU_NXC_DESC &&
          device_idx == 16'd2);
    rnw_step(APU_VGPU_RNW_FAULT, "walk again");
    check("chain stays", rnw.valid && rnw.device_idx == 16'd2);
    sgx.used_idx = APU_VGPU_TUW_IDXV;
    rnk_step(APU_VGPU_RNK_FAULT, "keep scene index");
    check("keep rejected", !rnk.valid);
    good_sgx();
    rnk_step(APU_VGPU_RNK_OK, "keep chain");
    check("chain kept", rnk.valid && rnk.avail_idx == 16'd2 &&
          rnk.att_addr == APU_VGPU_RAB_CMD);
    rnk_step(APU_VGPU_RNK_FAULT, "keep again");
    sgx.used_idx = APU_VGPU_TUW_IDXV;
    rnx_step(APU_VGPU_RNX_FAULT, "check scene index");
    check("check rejected", !rnx.valid);
    good_sgx();
    rnx_step(APU_VGPU_RNX_OK, "check chain");
    check("index kept", rnx.valid && rnx.avail_idx == 16'd2 &&
          rnx.device_idx == 16'd2 && rnx.att_addr == APU_VGPU_RAB_CMD);
    rnx_step(APU_VGPU_RNX_FAULT, "check again");
    check("check stays", rnx.avail_idx == rnw.avail_idx);

    pulse_reset();
    check("reset clears", rnw == '0 && rnk == '0 && rnx == '0 &&
          avail_idx == 16'd1 && device_idx == 16'd1);
    treq = '0;
    treq.op = APU_VGPU_RNW_WALK;
    rnw_step(APU_VGPU_RNW_EMPTY, "after reset");
    post_xfer();
    treq = '0;
    treq.op = APU_VGPU_RNW_AVAIL;
    treq.avail_idx = 16'd2;
    treq.desc_id = 16'd0;
    rnw_step(APU_VGPU_RNW_OK, "avail after reset");
    good_sgx();
    treq = '0;
    treq.op = APU_VGPU_RNW_WALK;
    rnw_step(APU_VGPU_RNW_OK, "walk after reset");

    if (errors != 0) $fatal(1, "APU vgpu rnw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rnw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
