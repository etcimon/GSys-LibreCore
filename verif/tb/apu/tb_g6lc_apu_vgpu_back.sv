// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_back;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v;
  logic [383:0] cmd;
  apu_vgpu_res_t slot0, slot1;
  apu_vgpu_cpl_t cpl, off_cpl, snap;
  apu_vgpu_back_t back0, back1, off_b0, off_b1;
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

  localparam logic [63:0] Fence = 64'h1122_3344_5566_7788;
  localparam logic [63:0] BackAddr = 64'h0000_0000_8800_1000;
  localparam logic [31:0] BackLen = 32'd32;
  localparam logic [63:0] BackAddr8 = 64'h0000_0000_8800_2000;
  localparam logic [31:0] BackLen8 = 32'd4;

  g6lc_apu_vgpu_cmd #(.Enable(1'b1)) i_cmd (
    .clk_i(clk), .rst_ni, .req_valid_i(v_v), .req_ready_o(v_rdy), .cmd_i(vcmd),
    .cpl_valid_o(v_cplv), .cpl_ready_i(v_cplr), .cpl_o(vcpl),
    .slot0_o(slot0), .slot1_o(slot1)
  );
  g6lc_apu_vgpu_back #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .cmd_i(cmd),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .back0_o(back0), .back1_o(back1)
  );
  g6lc_apu_vgpu_back_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .cmd_i(cmd),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .back0_o(off_b0), .back1_o(off_b1)
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
  initial begin #200000; $fatal(1, "vgpu back timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_b0 !== '0 || off_b1 !== '0)
      $fatal(1, "disabled vgpu back active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [383:0] back_cmd(
    input logic [31:0] cmd_type,
    input logic [31:0] flags,
    input logic [63:0] fence,
    input logic [31:0] hdr_pad,
    input logic [31:0] rid,
    input logic [31:0] nr,
    input logic [63:0] addr,
    input logic [31:0] len,
    input logic [31:0] ent_pad
  );
    back_cmd = {ent_pad, len, addr, nr, rid, hdr_pad, 32'd3, fence, flags, cmd_type};
  endfunction

  task automatic attach_step(
    input logic [383:0] word,
    input logic [31:0] resp,
    input logic [31:0] flags,
    input logic [63:0] fence,
    input string name
  );
    apu_vgpu_cpl_t seen;
    apu_vgpu_back_t was0, was1;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was0 = back0;
    was1 = back1;
    cmd = word;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    seen = cpl;
    snap = cpl;
    check($sformatf("%s resp", name), cpl.resp_type == resp);
    check($sformatf("%s fence", name), cpl.flags == flags && cpl.fence_id == fence);
    check($sformatf("%s ctx", name), cpl.ctx_id == 32'd3);
    check($sformatf("%s nodata", name), cpl.resource_id == 0 && cpl.format == 0 &&
          cpl.width == 0 && cpl.height == 0);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (resp != VGPU_RESP_OK_NODATA)
      check($sformatf("%s kept", name), back0 == was0 && back1 == was1);
  endtask

  task automatic create_res(
    input logic [31:0] rid,
    input logic [31:0] w,
    input logic [31:0] h,
    input string name
  );
    @(negedge clk);
    while (!v_rdy) @(negedge clk);
    vcmd = {h, w, VGPU_FORMAT_R8G8B8A8_UNORM, rid, 32'h0, 32'd3,
            Fence, VGPU_FLAG_FENCE, VGPU_CMD_RESOURCE_CREATE_2D};
    v_v = 1;
    @(posedge clk); @(negedge clk); v_v = 0;
    while (!v_cplv) @(negedge clk);
    vsnap = vcpl;
    @(negedge clk);
    check($sformatf("%s held", name), v_cplv && !v_rdy && vcpl == vsnap);
    check($sformatf("%s ok", name), vsnap.resp_type == VGPU_RESP_OK_NODATA &&
          vsnap.resource_id == rid && vsnap.width == w && vsnap.height == h);
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

  initial begin
    apu_cfg_t cfg;
    cmd = '0;
    vcmd = '0;
    ureq = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 &&
          back0 == '0 && back1 == '0);
    check("profiles keep back off",
          !ApuOff.BackEn && !ApuP1Transport.BackEn && !ApuHarness.BackEn &&
          !ApuSchedBoth.BackEn && !ApuBadVirglGrant.BackEn);
    cfg = ApuP1Transport;
    cfg.BackEn = 1'b1;
    check("back does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.BackEn = 1'b1;
    check("back does not legalize virgl", !apu_cfg_legal(cfg));

    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, VGPU_FLAG_FENCE, Fence,
                         32'h0, 32'd7, 32'd1, BackAddr, BackLen, 32'h0),
                VGPU_RESP_ERR_INVALID_RESOURCE_ID, VGPU_FLAG_FENCE, Fence, "missing");
    check("missing stores nothing", back0 == '0 && back1 == '0);

    create_res(32'd7, 32'd4, 32'd2, "create7");
    check("slot0", slot0.valid && slot0.resource_id == 32'd7 &&
          slot0.width == 32'd4 && slot0.height == 32'd2 && !slot1.valid);

    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, VGPU_FLAG_FENCE, Fence,
                         32'h0, 32'd7, 32'd1, BackAddr, BackLen, 32'h0),
                VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, Fence, "attach7");
    check("back0", back0.valid && back0.resource_id == 32'd7 &&
          back0.addr == BackAddr && back0.length == BackLen);
    check("back1 empty", back1 == '0);
    check("slot0 stays", slot0.resource_id == 32'd7 && slot0.width == 32'd4);

    publish_used(32'd5);
    check("published idx", u_idx == 16'd1 && irq == 1'b1 && usnap.ok &&
          usnap.desc_id == 32'd5 && usnap.len == VGPU_RESP_HDR_BYTES && usnap.idx == 16'd1);
    peek = 3'd0;
    @(posedge clk);
    check("elem0", peek_id == 32'd5 && peek_len == VGPU_RESP_HDR_BYTES);
    @(negedge clk); ack = 1;
    @(posedge clk); @(negedge clk); ack = 0;
    check("ack drops irq", irq == 1'b0 && u_idx == 16'd1);

    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, VGPU_FLAG_FENCE, Fence,
                         32'h0, 32'd9, 32'd1, BackAddr8, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_RESOURCE_ID, VGPU_FLAG_FENCE, Fence, "unknown");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, VGPU_FLAG_FENCE, Fence,
                         32'h0, 32'd7, 32'd1, BackAddr8, BackLen, 32'h0),
                VGPU_RESP_ERR_UNSPEC, VGPU_FLAG_FENCE, Fence, "dup");
    check("dup keeps addr", back0.addr == BackAddr && back0.length == BackLen);
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h0, 32'd7, 32'd1, BackAddr8, BackLen, 32'h0),
                VGPU_RESP_ERR_UNSPEC, 32'h0, 64'h0, "dup quiet");

    create_res(32'd8, 32'd1, 32'd1, "create8");
    check("slot1", slot1.valid && slot1.resource_id == 32'd8 &&
          slot1.width == 32'd1 && slot1.height == 32'd1 &&
          slot0.resource_id == 32'd7);

    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, VGPU_FLAG_FENCE, Fence,
                         32'h0, 32'd8, 32'd2, BackAddr8, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence, "nr2");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h0, 32'd8, 32'd0, BackAddr8, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "nr0");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h0, 32'd8, 32'd1, BackAddr8, 32'd16, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "short");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h0, 32'd8, 32'd1, BackAddr8, 32'd0, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "zero len");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h0, 32'd8, 32'd1, 64'h0, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "zero addr");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h0, 32'd8, 32'd1, 64'h0000_0000_8800_1002, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "align");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h0, 32'd8, 32'd1, 64'hffff_ffff_ffff_fffc, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "wrap");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h0, 32'd8, 32'd1, BackAddr8, BackLen8, 32'h1),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "entry pad");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h0, Fence,
                         32'h1, 32'd8, 32'd1, BackAddr8, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "hdr pad");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, 32'h3, Fence,
                         32'h0, 32'd8, 32'd1, BackAddr8, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence, "bad flags");
    attach_step(back_cmd(VGPU_CMD_RESOURCE_CREATE_2D, VGPU_FLAG_FENCE, Fence,
                         32'h0, 32'd8, 32'd1, BackAddr8, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence, "create type");
    attach_step(back_cmd(32'h0000_0207, 32'h0, 64'h0,
                         32'h0, 32'd8, 32'd1, BackAddr8, BackLen8, 32'h0),
                VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "submit");
    check("rejects stored nothing", back1 == '0 && back0.addr == BackAddr);

    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, VGPU_FLAG_FENCE, Fence,
                         32'h0, 32'd8, 32'd1, BackAddr8, BackLen8, 32'h0),
                VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, Fence, "attach8");
    check("back1", back1.valid && back1.resource_id == 32'd8 &&
          back1.addr == BackAddr8 && back1.length == BackLen8);
    check("back0 stays", back0.valid && back0.resource_id == 32'd7 &&
          back0.addr == BackAddr && back0.length == BackLen);

    pulse_reset();
    check("reset clears", back0 == '0 && back1 == '0 && slot0 == '0 && slot1 == '0);
    attach_step(back_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, VGPU_FLAG_FENCE, Fence,
                         32'h0, 32'd7, 32'd1, BackAddr, BackLen, 32'h0),
                VGPU_RESP_ERR_INVALID_RESOURCE_ID, VGPU_FLAG_FENCE, Fence, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu back errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_back cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
