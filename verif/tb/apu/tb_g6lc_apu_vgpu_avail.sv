// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_avail;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v;
  logic [15:0] avail_idx, device_idx, off_avail, off_dev;
  apu_vgpu_avail_req_t req;
  apu_vgpu_avail_cpl_t cpl, off_cpl, snap;
  logic [319:0] walked;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  logic v_v = 0, v_rdy, v_cplv, v_cplr = 0;
  logic [319:0] vcmd;
  apu_vgpu_cpl_t vcpl, vsnap;
  logic cancel = 0, ack = 0, u_v = 0, u_rdy, u_cplv, u_cplr = 0, pending, irq;
  logic [15:0] u_idx;
  logic [2:0] peek = 0;
  logic [31:0] peek_id, peek_len;
  apu_vgpu_used_req_t ureq;
  apu_vgpu_used_cpl_t ucpl, usnap;

  localparam logic [319:0] CreateCmd = {32'd2, 32'd4, VGPU_FORMAT_R8G8B8A8_UNORM, 32'd7,
    32'h0, 32'd3, 64'h1122_3344_5566_7788, VGPU_FLAG_FENCE, VGPU_CMD_RESOURCE_CREATE_2D};

  g6lc_apu_vgpu_avail #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .avail_idx_o(avail_idx), .device_idx_o(device_idx)
  );
  g6lc_apu_vgpu_avail_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .avail_idx_o(off_avail), .device_idx_o(off_dev)
  );
  g6lc_apu_vgpu_cmd #(.Enable(1'b1)) i_cmd (
    .clk_i(clk), .rst_ni, .req_valid_i(v_v), .req_ready_o(v_rdy), .cmd_i(vcmd),
    .cpl_valid_o(v_cplv), .cpl_ready_i(v_cplr), .cpl_o(vcpl),
    .slot0_o(), .slot1_o()
  );
  g6lc_apu_vgpu_used #(.Enable(1'b1)) i_used (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(ack),
    .req_valid_i(u_v), .req_ready_o(u_rdy), .req_i(ureq),
    .cpl_valid_o(u_cplv), .cpl_ready_i(u_cplr), .cpl_o(ucpl),
    .idx_o(u_idx), .irq_o(irq), .pending_o(pending),
    .peek_i(peek), .peek_id_o(peek_id), .peek_len_o(peek_len)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vgpu avail timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_avail !== 0 || off_dev !== 0)
      $fatal(1, "disabled vgpu avail active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic avail_step(
    input apu_vgpu_avail_req_t r,
    input apu_vgpu_avail_status_e st,
    input string name
  );
    apu_vgpu_avail_cpl_t seen;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    req = r;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    seen = cpl;
    snap = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    if (st != APU_VGPU_AVAIL_OK)
      check($sformatf("%s quiet cmd", name), cpl.cmd == '0);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
  endtask

  function automatic apu_vgpu_avail_req_t post_of(
    input logic [15:0] next_idx,
    input logic [15:0] id,
    input logic [15:0] flags,
    input logic [31:0] len,
    input logic [319:0] cmd
  );
    post_of = '0;
    post_of.op = APU_VGPU_AVAIL_POST;
    post_of.avail_idx = next_idx;
    post_of.desc_id = id;
    post_of.flags = flags;
    post_of.len = len;
    post_of.cmd = cmd;
  endfunction

  function automatic apu_vgpu_avail_req_t walk_of();
    walk_of = '0;
    walk_of.op = APU_VGPU_AVAIL_WALK;
  endfunction

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    v_v = 0;
    v_cplr = 0;
    u_v = 0;
    u_cplr = 0;
    cancel = 0;
    ack = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  task automatic decode_walked(input logic [319:0] word);
    @(negedge clk);
    while (!v_rdy) @(negedge clk);
    vcmd = word;
    v_v = 1;
    @(posedge clk); @(negedge clk); v_v = 0;
    while (!v_cplv) @(negedge clk);
    vsnap = vcpl;
    @(negedge clk);
    check("cmd held", v_cplv && !v_rdy && vcpl == vsnap);
    v_cplr = 1;
    @(posedge clk); @(negedge clk); v_cplr = 0;
    while (v_cplv) @(negedge clk);
  endtask

  task automatic publish_used(input logic [31:0] desc);
    logic [15:0] was;
    @(negedge clk);
    while (!u_rdy) @(negedge clk);
    was = u_idx;
    ureq = '{idx: was, desc_id: desc, len: VGPU_RESP_HDR_BYTES};
    u_v = 1;
    @(posedge clk); @(negedge clk); u_v = 0;
    check("used pending", pending && u_idx == was && irq == 1'b0);
    peek = was[2:0];
    @(posedge clk);
    check("used stored", peek_id == desc && peek_len == VGPU_RESP_HDR_BYTES);
    while (!u_cplv) @(negedge clk);
    usnap = ucpl;
    check("used ok", ucpl.ok == 1'b1);
    @(negedge clk);
    check("used held", u_cplv && !u_rdy && ucpl == usnap);
    u_cplr = 1;
    @(posedge clk); @(negedge clk); u_cplr = 0;
    while (u_cplv) @(negedge clk);
  endtask

  task automatic fault_head(
    input logic [15:0] flags,
    input logic [31:0] len,
    input string name
  );
    pulse_reset();
    avail_step(post_of(16'd1, 16'd1, flags, len, CreateCmd), APU_VGPU_AVAIL_OK,
               $sformatf("%s post", name));
    check($sformatf("%s posted", name), avail_idx == 16'd1 && device_idx == 16'd0 &&
          snap.desc_id == 16'd0 && snap.cmd == '0 && snap.device_idx == 16'd0);
    avail_step(walk_of(), APU_VGPU_AVAIL_FAULT, $sformatf("%s walk", name));
    check($sformatf("%s stays", name), device_idx == 16'd0 && avail_idx == 16'd1 &&
          snap.device_idx == 16'd0 && snap.desc_id == 16'd0 && snap.cmd == '0);
  endtask

  initial begin
    apu_cfg_t cfg;
    req = '0;
    ureq = '0;
    vcmd = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 &&
          avail_idx == 0 && device_idx == 0);
    check("profiles keep avail off",
          !ApuOff.AvailEn && !ApuP1Transport.AvailEn && !ApuHarness.AvailEn &&
          !ApuSchedBoth.AvailEn && !ApuBadVirglGrant.AvailEn);
    cfg = ApuP1Transport;
    cfg.AvailEn = 1'b1;
    check("avail does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.AvailEn = 1'b1;
    check("avail does not legalize virgl", !apu_cfg_legal(cfg));

    avail_step(walk_of(), APU_VGPU_AVAIL_EMPTY, "empty");
    check("empty idx", avail_idx == 0 && device_idx == 0 && snap.device_idx == 0 &&
          snap.desc_id == 0);

    avail_step(post_of(16'd2, 16'd4, 16'h0, VGPU_CMD_BYTES, CreateCmd),
               APU_VGPU_AVAIL_FAULT, "jump");
    check("jump writes nothing", avail_idx == 0 && device_idx == 0 && snap.device_idx == 0);
    avail_step(walk_of(), APU_VGPU_AVAIL_EMPTY, "jump still empty");
    check("jump idx", avail_idx == 0 && device_idx == 0);

    avail_step(post_of(16'd1, 16'd8, 16'h0, VGPU_CMD_BYTES, CreateCmd),
               APU_VGPU_AVAIL_FAULT, "bad id");
    check("bad id writes nothing", avail_idx == 0 && device_idx == 0);

    avail_step(post_of(16'd1, 16'd4, 16'h0, VGPU_CMD_BYTES, CreateCmd),
               APU_VGPU_AVAIL_OK, "post create");
    check("posted create", avail_idx == 16'd1 && device_idx == 16'd0 &&
          snap.desc_id == 16'd0 && snap.cmd == '0 && snap.device_idx == 16'd0);

    avail_step(walk_of(), APU_VGPU_AVAIL_OK, "walk create");
    check("walked desc", snap.desc_id == 16'd4 && snap.device_idx == 16'd1 &&
          snap.cmd == CreateCmd);
    check("walked idx", avail_idx == 16'd1 && device_idx == 16'd1);
    walked = snap.cmd;

    avail_step(walk_of(), APU_VGPU_AVAIL_EMPTY, "drained");
    check("drained idx", avail_idx == 16'd1 && device_idx == 16'd1 && snap.device_idx == 16'd1);

    decode_walked(walked);
    check("create ok", vsnap.resp_type == VGPU_RESP_OK_NODATA);
    check("create fence", vsnap.flags == VGPU_FLAG_FENCE &&
          vsnap.fence_id == 64'h1122_3344_5566_7788);
    check("create resource", vsnap.resource_id == 32'd7 &&
          vsnap.format == VGPU_FORMAT_R8G8B8A8_UNORM &&
          vsnap.width == 32'd4 && vsnap.height == 32'd2 && vsnap.ctx_id == 32'd3);

    publish_used(32'd4);
    check("published idx", u_idx == 16'd1 && irq == 1'b1 && usnap.ok &&
          usnap.desc_id == 32'd4 && usnap.len == VGPU_RESP_HDR_BYTES && usnap.idx == 16'd1);
    peek = 3'd0;
    @(posedge clk);
    check("elem0", peek_id == 32'd4 && peek_len == VGPU_RESP_HDR_BYTES);
    @(negedge clk); ack = 1;
    @(posedge clk); @(negedge clk); ack = 0;
    check("ack drops irq", irq == 1'b0 && u_idx == 16'd1);

    avail_step(post_of(16'd2, 16'd5, VIRTQ_DESC_F_NEXT, VGPU_CMD_BYTES, CreateCmd),
               APU_VGPU_AVAIL_OK, "post next");
    check("next posted", avail_idx == 16'd2 && device_idx == 16'd1);
    avail_step(walk_of(), APU_VGPU_AVAIL_FAULT, "walk next");
    check("next unconsumed", avail_idx == 16'd2 && device_idx == 16'd1 &&
          snap.device_idx == 16'd1 && snap.desc_id == 16'd0 && snap.cmd == '0);

    avail_step(post_of(16'd3, 16'd6, 16'h0, 32'd8, CreateCmd),
               APU_VGPU_AVAIL_OK, "post short");
    check("short posted behind", avail_idx == 16'd3 && device_idx == 16'd1);
    avail_step(walk_of(), APU_VGPU_AVAIL_FAULT, "walk blocked");
    check("head still next", avail_idx == 16'd3 && device_idx == 16'd1 &&
          snap.device_idx == 16'd1 && snap.cmd == '0);

    fault_head(VIRTQ_DESC_F_WRITE, VGPU_CMD_BYTES, "write");
    fault_head(VIRTQ_DESC_F_INDIRECT, VGPU_CMD_BYTES, "indirect");
    fault_head(16'h0, 32'd8, "short");

    if (errors != 0) $fatal(1, "APU vgpu avail errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_avail cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
