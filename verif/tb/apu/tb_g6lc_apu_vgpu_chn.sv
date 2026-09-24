// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_chn;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic chn_req = 0, chn_rdy, chn_cpl_v, chn_cpl_r = 0;
  apu_vgpu_chn_req_t creq;
  apu_vgpu_chn_cpl_t chn_cpl;
  apu_vgpu_chn_t chn;
  logic [15:0] avail_idx, device_idx;
  logic cmx_req = 0, cmx_rdy, cmx_cpl_v, cmx_cpl_r = 0;
  apu_vgpu_cmx_cpl_t cmx_cpl;
  apu_vgpu_cmx_t cmx;
  apu_vgpu_sub_t sub;
  apu_vgpu_rsp_t rsp;
  logic cancel = 0, irq_ack = 0;
  logic sun_req = 0, sun_rdy, sun_cpl_v, sun_cpl_r = 0;
  apu_vgpu_sun_cpl_t sun_cpl, off_cpl;
  apu_vgpu_sun_t sun, off_sun;
  logic [15:0] sun_idx, off_idx;
  logic sun_irq, off_irq, sun_pend, off_pend, off_rdy, off_v;
  logic [31:0] elem_id, elem_len, off_id, off_len;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_chn #(.Enable(1'b1)) i_chn (
    .clk_i(clk), .rst_ni, .req_valid_i(chn_req), .req_ready_o(chn_rdy), .req_i(creq),
    .cpl_valid_o(chn_cpl_v), .cpl_ready_i(chn_cpl_r), .cpl_o(chn_cpl), .chn_o(chn),
    .avail_idx_o(avail_idx), .device_idx_o(device_idx)
  );
  g6lc_apu_vgpu_cmx #(.Enable(1'b1)) i_cmx (
    .clk_i(clk), .rst_ni, .chn_i(chn), .sub_i(sub), .rsp_i(rsp),
    .req_valid_i(cmx_req), .req_ready_o(cmx_rdy),
    .cpl_valid_o(cmx_cpl_v), .cpl_ready_i(cmx_cpl_r), .cpl_o(cmx_cpl), .cmx_o(cmx)
  );
  g6lc_apu_vgpu_sun #(.Enable(1'b1)) i_sun (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(irq_ack), .cmx_i(cmx),
    .req_valid_i(sun_req), .req_ready_o(sun_rdy),
    .cpl_valid_o(sun_cpl_v), .cpl_ready_i(sun_cpl_r), .cpl_o(sun_cpl), .sun_o(sun),
    .idx_o(sun_idx), .irq_o(sun_irq), .pending_o(sun_pend),
    .elem_id_o(elem_id), .elem_len_o(elem_len)
  );
  g6lc_apu_vgpu_sun_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(irq_ack), .cmx_i(cmx),
    .req_valid_i(sun_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sun_cpl_r), .cpl_o(off_cpl), .sun_o(off_sun),
    .idx_o(off_idx), .irq_o(off_irq), .pending_o(off_pend),
    .elem_id_o(off_id), .elem_len_o(off_len)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu chn timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
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

  task automatic chn_step(input apu_vgpu_chn_status_e st, input string name);
    @(negedge clk);
    while (!chn_rdy) @(negedge clk);
    cases++;
    chn_req = 1;
    @(posedge clk); @(negedge clk); chn_req = 0;
    while (!chn_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), chn_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), chn_cpl_v && chn_cpl.status == st);
    chn_cpl_r = 1;
    @(posedge clk); @(negedge clk); chn_cpl_r = 0;
    while (chn_cpl_v) @(negedge clk);
  endtask

  task automatic post_desc(
    input logic [15:0] id,
    input apu_vgpu_desc_t d,
    input apu_vgpu_chn_status_e st,
    input string name
  );
    creq = '0;
    creq.op = APU_VGPU_CHN_POST;
    creq.desc_id = id;
    creq.desc = d;
    chn_step(st, name);
  endtask

  task automatic post_scene;
    post_desc(16'd0, dsc(APU_VGPU_HDR_ADDR, VGPU_SUBMIT_BYTES, VIRTQ_DESC_F_NEXT, 16'd1),
              APU_VGPU_CHN_OK, "post0");
    post_desc(16'd1, dsc(APU_VGPU_EXEC_ADDR, APU_VGPU_SCENE_BYTES, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_CHN_OK, "post1");
    post_desc(16'd2, dsc(APU_VGPU_RSP_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_CHN_OK, "post2");
  endtask

  task automatic cmx_step(input apu_vgpu_cmx_status_e st, input string name);
    @(negedge clk);
    while (!cmx_rdy) @(negedge clk);
    cases++;
    cmx_req = 1;
    @(posedge clk); @(negedge clk); cmx_req = 0;
    while (!cmx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cmx_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), cmx_cpl_v);
    cmx_cpl_r = 1;
    @(posedge clk); @(negedge clk); cmx_cpl_r = 0;
    while (cmx_cpl_v) @(negedge clk);
  endtask

  task automatic sun_step(input apu_vgpu_sun_status_e st, input logic do_cancel, input string name);
    @(negedge clk);
    while (!sun_rdy) @(negedge clk);
    cases++;
    sun_req = 1;
    @(posedge clk); @(negedge clk); sun_req = 0;
    if (do_cancel) begin
      while (!sun_pend) @(negedge clk);
      check($sformatf("%s pending quiet", name), sun_irq == 1'b0 && sun_idx == 16'd0);
      cancel = 1;
    end
    while (!sun_cpl_v) @(negedge clk);
    cancel = 0;
    check($sformatf("%s status", name), sun_cpl.status == st);
    check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_irq == 0 && off_sun == '0);
    @(negedge clk);
    check($sformatf("%s held", name), sun_cpl_v);
    sun_cpl_r = 1;
    @(posedge clk); @(negedge clk); sun_cpl_r = 0;
    while (sun_cpl_v) @(negedge clk);
  endtask

  task automatic scene_pair;
    sub = '0;
    sub.valid = 1'b1;
    sub.ctx_id = APU_VGPU_CTX_ID;
    sub.size = APU_VGPU_SCENE_BYTES;
    sub.buf_addr = APU_VGPU_EXEC_ADDR;
    sub.rsp_addr = APU_VGPU_RSP_ADDR;
    rsp = '0;
    rsp.valid = 1'b1;
    rsp.addr = APU_VGPU_RSP_ADDR;
    rsp.ctx_id = APU_VGPU_CTX_ID;
    rsp.fence = APU_VGPU_SCENE_FENCE;
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    chn_req = 0;
    cmx_req = 0;
    sun_req = 0;
    cancel = 0;
    irq_ack = 0;
    chn_cpl_r = 0;
    cmx_cpl_r = 0;
    sun_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    creq = '0;
    sub = '0;
    rsp = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && off_irq == 0 && chn == '0 && sun == '0);
    check("profiles keep chain off",
          !ApuOff.ChnEn && !ApuOff.CmxEn && !ApuOff.SunEn &&
          !ApuP1Transport.ChnEn && !ApuP1Transport.CmxEn && !ApuP1Transport.SunEn &&
          !ApuHarness.ChnEn && !ApuHarness.CmxEn && !ApuHarness.SunEn &&
          !ApuSchedBoth.ChnEn && !ApuSchedBoth.CmxEn && !ApuSchedBoth.SunEn &&
          !ApuBadVirglGrant.ChnEn && !ApuBadVirglGrant.CmxEn && !ApuBadVirglGrant.SunEn);
    cfg = ApuP1Transport;
    cfg.ChnEn = 1'b1;
    cfg.CmxEn = 1'b1;
    cfg.SunEn = 1'b1;
    check("chain does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.ChnEn = 1'b1;
    cfg.CmxEn = 1'b1;
    cfg.SunEn = 1'b1;
    check("chain does not legalize virgl", !apu_cfg_legal(cfg));

    creq = '0;
    creq.op = APU_VGPU_CHN_WALK;
    chn_step(APU_VGPU_CHN_EMPTY, "walk empty");
    post_desc(16'd2, dsc(APU_VGPU_RSP_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_CHN_FAULT, "post skip");
    check("skip keeps", !chn.valid && device_idx == 16'd0);
    post_desc(16'd0, dsc(APU_VGPU_HDR_ADDR, VGPU_SUBMIT_BYTES,
                         VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT, 16'd1),
              APU_VGPU_CHN_OK, "post indirect");
    post_desc(16'd1, dsc(APU_VGPU_EXEC_ADDR, 32'd32, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_CHN_OK, "post short");
    post_desc(16'd2, dsc(APU_VGPU_RSP_ADDR, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0),
              APU_VGPU_CHN_OK, "post rsp");
    creq = '0;
    creq.op = APU_VGPU_CHN_AVAIL;
    creq.avail_idx = 16'd5;
    creq.desc_id = 16'd0;
    chn_step(APU_VGPU_CHN_FAULT, "avail jump");
    check("jump keeps", avail_idx == 16'd0 && device_idx == 16'd0);
    creq.avail_idx = 16'd1;
    chn_step(APU_VGPU_CHN_OK, "avail");
    check("avail armed", avail_idx == 16'd1 && device_idx == 16'd0);
    creq = '0;
    creq.op = APU_VGPU_CHN_WALK;
    chn_step(APU_VGPU_CHN_FAULT, "bad chain");
    check("bad keeps", !chn.valid && device_idx == 16'd0);
    post_desc(16'd0, dsc(APU_VGPU_HDR_ADDR, VGPU_SUBMIT_BYTES, VIRTQ_DESC_F_NEXT, 16'd1),
              APU_VGPU_CHN_OK, "fix0");
    post_desc(16'd1, dsc(APU_VGPU_EXEC_ADDR, APU_VGPU_SCENE_BYTES, VIRTQ_DESC_F_NEXT, 16'd2),
              APU_VGPU_CHN_OK, "fix1");
    creq = '0;
    creq.op = APU_VGPU_CHN_WALK;
    chn_step(APU_VGPU_CHN_OK, "walk");
    check("chain record", chn.valid && chn.head == 16'd0 && chn.buf_len == APU_VGPU_SCENE_BYTES &&
          chn.buf_addr == APU_VGPU_EXEC_ADDR && chn.rsp_addr == APU_VGPU_RSP_ADDR &&
          chn.device_idx == 16'd1 && device_idx == 16'd1);
    creq.op = APU_VGPU_CHN_WALK;
    chn_step(APU_VGPU_CHN_FAULT, "walk again");
    check("chain kept", chn.valid && chn.device_idx == 16'd1);

    scene_pair();
    sub = '0;
    rsp = '0;
    cmx_step(APU_VGPU_CMX_EMPTY, "link empty");
    scene_pair();
    sub.size = 32'd32;
    cmx_step(APU_VGPU_CMX_FAULT, "link size");
    check("size keeps", !cmx.linked);
    scene_pair();
    cmx_step(APU_VGPU_CMX_OK, "link");
    check("linked", cmx.linked);
    cmx_step(APU_VGPU_CMX_FAULT, "link again");
    check("link kept", cmx.linked);

    pulse_reset();
    check("reset clears", chn == '0 && cmx == '0 && sun == '0 && device_idx == 16'd0);
    sun_step(APU_VGPU_SUN_EMPTY, 1'b0, "sun empty");
    post_scene();
    creq = '0;
    creq.op = APU_VGPU_CHN_AVAIL;
    creq.avail_idx = 16'd1;
    creq.desc_id = 16'd0;
    chn_step(APU_VGPU_CHN_OK, "avail2");
    creq = '0;
    creq.op = APU_VGPU_CHN_WALK;
    chn_step(APU_VGPU_CHN_OK, "walk2");
    scene_pair();
    cmx_step(APU_VGPU_CMX_OK, "link2");
    sun_step(APU_VGPU_SUN_FAULT, 1'b1, "cancel");
    check("cancel keeps", !sun.valid && sun_idx == 16'd0 && sun_irq == 1'b0);
    sun_step(APU_VGPU_SUN_OK, 1'b0, "publish");
    check("used element", sun.valid && sun.idx == 16'd1 && sun.desc_id == 32'd0 &&
          sun.len == VGPU_RESP_HDR_BYTES && sun_idx == 16'd1 && sun_irq == 1'b1 &&
          elem_id == 32'd0 && elem_len == VGPU_RESP_HDR_BYTES);
    irq_ack = 1;
    @(posedge clk); @(negedge clk); irq_ack = 0;
    check("ack drops irq", sun_irq == 1'b0 && sun.valid);
    sun_step(APU_VGPU_SUN_FAULT, 1'b0, "sun again");
    check("sun kept", sun.valid && sun.idx == 16'd1);

    if (errors != 0) $fatal(1, "APU vgpu chn errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_chn cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
