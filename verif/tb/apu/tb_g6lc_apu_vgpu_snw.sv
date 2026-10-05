// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_snw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qgx_t qgx;
  logic snw_req = 0, snw_rdy, snw_cpl_v, snw_cpl_r = 0;
  apu_vgpu_snw_req_t sreq;
  apu_vgpu_snw_cpl_t snw_cpl;
  apu_vgpu_snw_t snw;
  logic [15:0] avail_idx, device_idx;
  logic snk_req = 0, snk_rdy, snk_cpl_v, snk_cpl_r = 0;
  apu_vgpu_snk_cpl_t snk_cpl;
  apu_vgpu_snk_t snk;
  logic snx_req = 0, snx_rdy, snx_cpl_v, snx_cpl_r = 0;
  apu_vgpu_snx_cpl_t snx_cpl, off_cpl;
  apu_vgpu_snx_t snx, off_snx;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_snw #(.Enable(1'b1)) i_snw (
    .clk_i(clk), .rst_ni, .qgx_i(qgx),
    .req_valid_i(snw_req), .req_ready_o(snw_rdy), .req_i(sreq),
    .cpl_valid_o(snw_cpl_v), .cpl_ready_i(snw_cpl_r), .cpl_o(snw_cpl), .snw_o(snw),
    .avail_idx_o(avail_idx), .device_idx_o(device_idx)
  );
  g6lc_apu_vgpu_snk #(.Enable(1'b1)) i_snk (
    .clk_i(clk), .rst_ni, .snw_i(snw), .qgx_i(qgx),
    .req_valid_i(snk_req), .req_ready_o(snk_rdy),
    .cpl_valid_o(snk_cpl_v), .cpl_ready_i(snk_cpl_r), .cpl_o(snk_cpl), .snk_o(snk)
  );
  g6lc_apu_vgpu_snx #(.Enable(1'b1)) i_snx (
    .clk_i(clk), .rst_ni, .snk_i(snk), .snw_i(snw), .qgx_i(qgx),
    .req_valid_i(snx_req), .req_ready_o(snx_rdy),
    .cpl_valid_o(snx_cpl_v), .cpl_ready_i(snx_cpl_r), .cpl_o(snx_cpl), .snx_o(snx)
  );
  g6lc_apu_vgpu_snx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .snk_i(snk), .snw_i(snw), .qgx_i(qgx),
    .req_valid_i(snx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(snx_cpl_r), .cpl_o(off_cpl), .snx_o(off_snx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu snw timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_snx == '0 &&
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

  task automatic good_qgx;
    qgx = '0;
    qgx.valid = 1'b1;
    qgx.ack = APU_VGPU_QSI_REASON;
    qgx.remain = APU_VGPU_VAW_CLEAR;
    qgx.used_idx = APU_VGPU_QSU_IDXV;
  endtask

  task automatic snw_step(input apu_vgpu_snw_status_e st, input string name);
    @(negedge clk);
    while (!snw_rdy) @(negedge clk);
    cases++;
    snw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snw_req = 1'b0;
    while (!snw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), snw_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), snw_cpl_v);
    snw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snw_cpl_r = 1'b0;
    while (snw_cpl_v) @(negedge clk);
  endtask

  task automatic post_desc(
    input logic [15:0] id,
    input apu_vgpu_desc_t d,
    input apu_vgpu_snw_status_e st,
    input string name
  );
    sreq = '0;
    sreq.op = APU_VGPU_SNW_POST;
    sreq.desc_id = id;
    sreq.desc = d;
    snw_step(st, name);
  endtask

  task automatic post_scene;
    post_desc(16'd0, dsc(APU_VGPU_HDR_ADDR, APU_VGPU_QSD_LEN, VIRTQ_DESC_F_NEXT, 16'd1),
              APU_VGPU_SNW_OK, "post0");
    post_desc(16'd1, dsc(APU_VGPU_EXEC_ADDR, APU_VGPU_SCENE_BYTES, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_SNW_OK, "post1");
    post_desc(16'd2, dsc(APU_VGPU_RSP_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_SNW_OK, "post2");
  endtask

  task automatic snk_step(input apu_vgpu_snk_status_e st, input string name);
    @(negedge clk);
    while (!snk_rdy) @(negedge clk);
    cases++;
    snk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snk_req = 1'b0;
    while (!snk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), snk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), snk_cpl_v);
    snk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snk_cpl_r = 1'b0;
    while (snk_cpl_v) @(negedge clk);
  endtask

  task automatic snx_step(input apu_vgpu_snx_status_e st, input string name);
    @(negedge clk);
    while (!snx_rdy) @(negedge clk);
    cases++;
    snx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snx_req = 1'b0;
    while (!snx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), snx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), snx_cpl_v);
    snx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    snx_cpl_r = 1'b0;
    while (snx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    snw_req = 1'b0;
    snk_req = 1'b0;
    snx_req = 1'b0;
    snw_cpl_r = 1'b0;
    snk_cpl_r = 1'b0;
    snx_cpl_r = 1'b0;
    sreq = '0;
    qgx = '0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qgx = '0;
    sreq = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          snw == '0 && snk == '0 && snx == '0);
    check("device starts before the scene", avail_idx == 16'd0 &&
          device_idx == 16'd0);
    check("profiles keep the walker off",
          !ApuOff.SnwEn && !ApuOff.SnkEn && !ApuOff.SnxEn &&
          !ApuP1Transport.SnwEn && !ApuP1Transport.SnkEn &&
          !ApuP1Transport.SnxEn &&
          !ApuHarness.SnwEn && !ApuHarness.SnkEn && !ApuHarness.SnxEn &&
          !ApuSchedBoth.SnwEn && !ApuSchedBoth.SnkEn && !ApuSchedBoth.SnxEn &&
          !ApuBadVirglGrant.SnwEn && !ApuBadVirglGrant.SnkEn &&
          !ApuBadVirglGrant.SnxEn);
    cfg = ApuP1Transport;
    cfg.SnwEn = 1'b1;
    cfg.SnkEn = 1'b1;
    cfg.SnxEn = 1'b1;
    check("walker does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SnwEn = 1'b1;
    cfg.SnkEn = 1'b1;
    cfg.SnxEn = 1'b1;
    check("walker does not legalize virgl", !apu_cfg_legal(cfg));
    check("scene places",
          APU_VGPU_HDR_ADDR != APU_VGPU_RAB_CMD &&
          APU_VGPU_HDR_ADDR != APU_VGPU_TFB_CMD &&
          APU_VGPU_QSU_IDXV == 16'd1 &&
          APU_VGPU_QSD_LEN == 32'd32 &&
          APU_VGPU_SCENE_BYTES == 32'd960);

    sreq = '0;
    sreq.op = APU_VGPU_SNW_WALK;
    snw_step(APU_VGPU_SNW_EMPTY, "walk empty");
    snk_step(APU_VGPU_SNK_EMPTY, "keep empty");
    snx_step(APU_VGPU_SNX_EMPTY, "check empty");
    post_desc(16'd2, dsc(APU_VGPU_RSP_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_SNW_FAULT, "post skip");
    check("skip keeps", !snw.valid && device_idx == 16'd0);
    post_desc(16'd0, dsc(APU_VGPU_HDR_ADDR, APU_VGPU_QSD_LEN,
                         VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT, 16'd1),
              APU_VGPU_SNW_OK, "post indirect");
    post_desc(16'd1, dsc(APU_VGPU_EXEC_ADDR, 32'd32, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_SNW_OK, "post short");
    post_desc(16'd2, dsc(APU_VGPU_RSP_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_SNW_OK, "post rsp");
    sreq = '0;
    sreq.op = APU_VGPU_SNW_AVAIL;
    sreq.avail_idx = 16'd2;
    sreq.desc_id = 16'd0;
    snw_step(APU_VGPU_SNW_FAULT, "xfer index");
    check("xfer keeps", avail_idx == 16'd0 && device_idx == 16'd0);
    sreq.avail_idx = 16'd5;
    snw_step(APU_VGPU_SNW_FAULT, "avail jump");
    sreq.avail_idx = 16'd1;
    snw_step(APU_VGPU_SNW_OK, "avail");
    check("avail armed", avail_idx == 16'd1 && device_idx == 16'd0);
    sreq = '0;
    sreq.op = APU_VGPU_SNW_WALK;
    snw_step(APU_VGPU_SNW_EMPTY, "walk guest missing");
    good_qgx();
    snw_step(APU_VGPU_SNW_FAULT, "bad chain");
    check("bad keeps", !snw.valid && device_idx == 16'd0);
    post_scene();
    sreq = '0;
    sreq.op = APU_VGPU_SNW_WALK;
    snw_step(APU_VGPU_SNW_OK, "walk");
    check("chain record", snw.valid && snw.head == 16'd0 &&
          snw.avail_idx == 16'd1 && snw.device_idx == 16'd1 &&
          snw.att_addr == APU_VGPU_HDR_ADDR &&
          snw.xfer_addr == APU_VGPU_EXEC_ADDR &&
          snw.rsp_addr == APU_VGPU_RSP_ADDR &&
          snw.att_addr != APU_VGPU_RAB_CMD &&
          device_idx == 16'd1);
    snw_step(APU_VGPU_SNW_FAULT, "walk again");
    check("chain stays", snw.valid && snw.device_idx == 16'd1);
    qgx.used_idx = APU_VGPU_TUW_IDXV;
    snk_step(APU_VGPU_SNK_FAULT, "keep xfer index");
    check("keep rejected", !snk.valid);
    good_qgx();
    snk_step(APU_VGPU_SNK_OK, "keep chain");
    check("chain kept", snk.valid && snk.avail_idx == 16'd1 &&
          snk.att_addr == APU_VGPU_HDR_ADDR);
    snk_step(APU_VGPU_SNK_FAULT, "keep again");
    qgx.used_idx = APU_VGPU_TUW_IDXV;
    snx_step(APU_VGPU_SNX_FAULT, "check xfer index");
    check("check rejected", !snx.valid);
    good_qgx();
    snx_step(APU_VGPU_SNX_OK, "check chain");
    check("index kept", snx.valid && snx.avail_idx == 16'd1 &&
          snx.device_idx == 16'd1 && snx.att_addr == APU_VGPU_HDR_ADDR);
    snx_step(APU_VGPU_SNX_FAULT, "check again");
    check("check stays", snx.avail_idx == snw.avail_idx);

    pulse_reset();
    check("reset clears", snw == '0 && snk == '0 && snx == '0 &&
          avail_idx == 16'd0 && device_idx == 16'd0);
    sreq = '0;
    sreq.op = APU_VGPU_SNW_WALK;
    snw_step(APU_VGPU_SNW_EMPTY, "after reset");
    post_scene();
    sreq = '0;
    sreq.op = APU_VGPU_SNW_AVAIL;
    sreq.avail_idx = 16'd1;
    sreq.desc_id = 16'd0;
    snw_step(APU_VGPU_SNW_OK, "avail after reset");
    good_qgx();
    sreq = '0;
    sreq.op = APU_VGPU_SNW_WALK;
    snw_step(APU_VGPU_SNW_OK, "walk after reset");

    if (errors != 0) $fatal(1, "APU vgpu snw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_snw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
