// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tnw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_txx_t txx;
  logic tnw_req = 0, tnw_rdy, tnw_cpl_v, tnw_cpl_r = 0;
  apu_vgpu_tnw_req_t treq;
  apu_vgpu_tnw_cpl_t tnw_cpl;
  apu_vgpu_tnw_t tnw;
  logic [15:0] avail_idx, device_idx;
  logic tnk_req = 0, tnk_rdy, tnk_cpl_v, tnk_cpl_r = 0;
  apu_vgpu_tnk_cpl_t tnk_cpl;
  apu_vgpu_tnk_t tnk;
  logic tnx_req = 0, tnx_rdy, tnx_cpl_v, tnx_cpl_r = 0;
  apu_vgpu_tnx_cpl_t tnx_cpl, off_cpl;
  apu_vgpu_tnx_t tnx, off_tnx;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_tnw #(.Enable(1'b1)) i_tnw (
    .clk_i(clk), .rst_ni, .txx_i(txx),
    .req_valid_i(tnw_req), .req_ready_o(tnw_rdy), .req_i(treq),
    .cpl_valid_o(tnw_cpl_v), .cpl_ready_i(tnw_cpl_r), .cpl_o(tnw_cpl), .tnw_o(tnw),
    .avail_idx_o(avail_idx), .device_idx_o(device_idx)
  );
  g6lc_apu_vgpu_tnk #(.Enable(1'b1)) i_tnk (
    .clk_i(clk), .rst_ni, .tnw_i(tnw), .txx_i(txx),
    .req_valid_i(tnk_req), .req_ready_o(tnk_rdy),
    .cpl_valid_o(tnk_cpl_v), .cpl_ready_i(tnk_cpl_r), .cpl_o(tnk_cpl), .tnk_o(tnk)
  );
  g6lc_apu_vgpu_tnx #(.Enable(1'b1)) i_tnx (
    .clk_i(clk), .rst_ni, .tnk_i(tnk), .tnw_i(tnw), .txx_i(txx),
    .req_valid_i(tnx_req), .req_ready_o(tnx_rdy),
    .cpl_valid_o(tnx_cpl_v), .cpl_ready_i(tnx_cpl_r), .cpl_o(tnx_cpl), .tnx_o(tnx)
  );
  g6lc_apu_vgpu_tnx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .tnk_i(tnk), .tnw_i(tnw), .txx_i(txx),
    .req_valid_i(tnx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(tnx_cpl_r), .cpl_o(off_cpl), .tnx_o(off_tnx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu tnw timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_tnx == '0 &&
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

  task automatic good_txx;
    txx = '0;
    txx.valid = 1'b1;
    txx.head = 16'd0;
    txx.avail_idx = APU_VGPU_TUW_IDXV;
    txx.att_addr = APU_VGPU_RAB_CMD;
  endtask

  task automatic tnw_step(input apu_vgpu_tnw_status_e st, input string name);
    @(negedge clk);
    while (!tnw_rdy) @(negedge clk);
    cases++;
    tnw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tnw_req = 1'b0;
    while (!tnw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tnw_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tnw_cpl_v);
    tnw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tnw_cpl_r = 1'b0;
    while (tnw_cpl_v) @(negedge clk);
  endtask

  task automatic post_desc(
    input logic [15:0] id,
    input apu_vgpu_desc_t d,
    input apu_vgpu_tnw_status_e st,
    input string name
  );
    treq = '0;
    treq.op = APU_VGPU_TNW_POST;
    treq.desc_id = id;
    treq.desc = d;
    tnw_step(st, name);
  endtask

  task automatic post_xfer;
    post_desc(16'd0, dsc(APU_VGPU_RAB_CMD, APU_VGPU_RAB_BYTES, VIRTQ_DESC_F_NEXT, 16'd1),
              APU_VGPU_TNW_OK, "post0");
    post_desc(16'd1, dsc(APU_VGPU_TFB_CMD, APU_VGPU_TFB_BYTES, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_TNW_OK, "post1");
    post_desc(16'd2, dsc(APU_VGPU_RFW_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_TNW_OK, "post2");
  endtask

  task automatic tnk_step(input apu_vgpu_tnk_status_e st, input string name);
    @(negedge clk);
    while (!tnk_rdy) @(negedge clk);
    cases++;
    tnk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tnk_req = 1'b0;
    while (!tnk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tnk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tnk_cpl_v);
    tnk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tnk_cpl_r = 1'b0;
    while (tnk_cpl_v) @(negedge clk);
  endtask

  task automatic tnx_step(input apu_vgpu_tnx_status_e st, input string name);
    @(negedge clk);
    while (!tnx_rdy) @(negedge clk);
    cases++;
    tnx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tnx_req = 1'b0;
    while (!tnx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tnx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tnx_cpl_v);
    tnx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tnx_cpl_r = 1'b0;
    while (tnx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    tnw_req = 1'b0;
    tnk_req = 1'b0;
    tnx_req = 1'b0;
    tnw_cpl_r = 1'b0;
    tnk_cpl_r = 1'b0;
    tnx_cpl_r = 1'b0;
    treq = '0;
    txx = '0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    txx = '0;
    treq = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          tnw == '0 && tnk == '0 && tnx == '0);
    check("device starts after the scene", avail_idx == 16'd1 &&
          device_idx == 16'd1);
    check("profiles keep the walker off",
          !ApuOff.TnwEn && !ApuOff.TnkEn && !ApuOff.TnxEn &&
          !ApuP1Transport.TnwEn && !ApuP1Transport.TnkEn &&
          !ApuP1Transport.TnxEn &&
          !ApuHarness.TnwEn && !ApuHarness.TnkEn && !ApuHarness.TnxEn &&
          !ApuSchedBoth.TnwEn && !ApuSchedBoth.TnkEn && !ApuSchedBoth.TnxEn &&
          !ApuBadVirglGrant.TnwEn && !ApuBadVirglGrant.TnkEn &&
          !ApuBadVirglGrant.TnxEn);
    cfg = ApuP1Transport;
    cfg.TnwEn = 1'b1;
    cfg.TnkEn = 1'b1;
    cfg.TnxEn = 1'b1;
    check("walker does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TnwEn = 1'b1;
    cfg.TnkEn = 1'b1;
    cfg.TnxEn = 1'b1;
    check("walker does not legalize virgl", !apu_cfg_legal(cfg));
    check("transfer places",
          APU_VGPU_RAB_CMD != APU_VGPU_NXC_DESC &&
          APU_VGPU_RAB_CMD != APU_VGPU_HDR_ADDR &&
          APU_VGPU_TUW_IDXV == 16'd2 &&
          APU_VGPU_RAB_BYTES == 32'd64 &&
          APU_VGPU_TFB_BYTES == 32'd96);

    treq = '0;
    treq.op = APU_VGPU_TNW_WALK;
    tnw_step(APU_VGPU_TNW_EMPTY, "walk empty");
    tnk_step(APU_VGPU_TNK_EMPTY, "keep empty");
    tnx_step(APU_VGPU_TNX_EMPTY, "check empty");
    post_desc(16'd2, dsc(APU_VGPU_RFW_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_TNW_FAULT, "post skip");
    check("skip keeps", !tnw.valid && device_idx == 16'd1);
    post_desc(16'd0, dsc(APU_VGPU_RAB_CMD, APU_VGPU_RAB_BYTES,
                         VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT, 16'd1),
              APU_VGPU_TNW_OK, "post indirect");
    post_desc(16'd1, dsc(APU_VGPU_TFB_CMD, 32'd32, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_TNW_OK, "post short");
    post_desc(16'd2, dsc(APU_VGPU_RFW_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_TNW_OK, "post rsp");
    treq = '0;
    treq.op = APU_VGPU_TNW_AVAIL;
    treq.avail_idx = 16'd1;
    treq.desc_id = 16'd0;
    tnw_step(APU_VGPU_TNW_FAULT, "scene index");
    check("scene keeps", avail_idx == 16'd1 && device_idx == 16'd1);
    treq.avail_idx = 16'd5;
    tnw_step(APU_VGPU_TNW_FAULT, "avail jump");
    treq.avail_idx = 16'd2;
    tnw_step(APU_VGPU_TNW_OK, "avail");
    check("avail armed", avail_idx == 16'd2 && device_idx == 16'd1);
    treq = '0;
    treq.op = APU_VGPU_TNW_WALK;
    tnw_step(APU_VGPU_TNW_EMPTY, "walk guest missing");
    good_txx();
    tnw_step(APU_VGPU_TNW_FAULT, "bad chain");
    check("bad keeps", !tnw.valid && device_idx == 16'd1);
    post_xfer();
    treq = '0;
    treq.op = APU_VGPU_TNW_WALK;
    tnw_step(APU_VGPU_TNW_OK, "walk");
    check("chain record", tnw.valid && tnw.head == 16'd0 &&
          tnw.avail_idx == 16'd2 && tnw.device_idx == 16'd2 &&
          tnw.att_addr == APU_VGPU_RAB_CMD &&
          tnw.xfer_addr == APU_VGPU_TFB_CMD &&
          tnw.rsp_addr == APU_VGPU_RFW_ADDR &&
          tnw.att_addr != APU_VGPU_NXC_DESC &&
          device_idx == 16'd2);
    tnw_step(APU_VGPU_TNW_FAULT, "walk again");
    check("chain stays", tnw.valid && tnw.device_idx == 16'd2);
    txx.avail_idx = 16'd1;
    tnk_step(APU_VGPU_TNK_FAULT, "keep scene index");
    check("keep rejected", !tnk.valid);
    good_txx();
    tnk_step(APU_VGPU_TNK_OK, "keep chain");
    check("chain kept", tnk.valid && tnk.avail_idx == 16'd2 &&
          tnk.att_addr == APU_VGPU_RAB_CMD);
    tnk_step(APU_VGPU_TNK_FAULT, "keep again");
    txx.avail_idx = 16'd1;
    tnx_step(APU_VGPU_TNX_FAULT, "check scene index");
    check("check rejected", !tnx.valid);
    good_txx();
    tnx_step(APU_VGPU_TNX_OK, "check chain");
    check("index kept", tnx.valid && tnx.avail_idx == 16'd2 &&
          tnx.device_idx == 16'd2 && tnx.att_addr == APU_VGPU_RAB_CMD);
    tnx_step(APU_VGPU_TNX_FAULT, "check again");
    check("check stays", tnx.avail_idx == tnw.avail_idx);

    pulse_reset();
    check("reset clears", tnw == '0 && tnk == '0 && tnx == '0 &&
          avail_idx == 16'd1 && device_idx == 16'd1);
    treq = '0;
    treq.op = APU_VGPU_TNW_WALK;
    tnw_step(APU_VGPU_TNW_EMPTY, "after reset");
    post_xfer();
    treq = '0;
    treq.op = APU_VGPU_TNW_AVAIL;
    treq.avail_idx = 16'd2;
    treq.desc_id = 16'd0;
    tnw_step(APU_VGPU_TNW_OK, "avail after reset");
    good_txx();
    treq = '0;
    treq.op = APU_VGPU_TNW_WALK;
    tnw_step(APU_VGPU_TNW_OK, "walk after reset");

    if (errors != 0) $fatal(1, "APU vgpu tnw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tnw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
