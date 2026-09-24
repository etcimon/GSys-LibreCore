// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_xfer;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v, off_rd_v, off_rsp_rdy;
  logic [447:0] xcmd;
  logic [63:0] rd_addr, off_addr;
  logic [31:0] rd_len, off_len;
  logic rd_valid, rd_ready = 0, rd_rsp_ready;
  logic rsp_v = 0, rsp_ok = 0;
  logic [63:0] rsp_addr = '0;
  logic [31:0] rsp_len = '0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = '0;
  logic xpeek_slot = 0;
  logic [APU_FRAG_ADDR_BITS-1:0] xpeek_addr = '0;
  logic [31:0] xpeek_word, off_xpeek;
  apu_vgpu_res_t slot0, slot1;
  apu_vgpu_back_t back0, back1;
  apu_vgpu_cpl_t cpl, off_cpl, snap;
  apu_vgpu_img_t img0, img1, off_img0, off_img1;
  int errors = 0, checks = 0, cycles = 0, cases = 0, reads = 0;

  logic v_v = 0, v_rdy, v_cplv, v_cplr = 0;
  logic [319:0] vcmd;
  apu_vgpu_cpl_t vcpl, vsnap;
  logic b_v = 0, b_rdy, b_cplv, b_cplr = 0;
  logic [383:0] bcmd;
  apu_vgpu_cpl_t bcpl, bsnap;
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
  localparam logic [255:0] Dirty4 = {{7{32'hDEADBEEF}}, 32'h44332211};

  g6lc_apu_vgpu_cmd #(.Enable(1'b1)) i_cmd (
    .clk_i(clk), .rst_ni, .req_valid_i(v_v), .req_ready_o(v_rdy), .cmd_i(vcmd),
    .cpl_valid_o(v_cplv), .cpl_ready_i(v_cplr), .cpl_o(vcpl),
    .slot0_o(slot0), .slot1_o(slot1)
  );
  g6lc_apu_vgpu_back #(.Enable(1'b1)) i_back (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .req_valid_i(b_v), .req_ready_o(b_rdy), .cmd_i(bcmd),
    .cpl_valid_o(b_cplv), .cpl_ready_i(b_cplr), .cpl_o(bcpl),
    .back0_o(back0), .back1_o(back1)
  );
  g6lc_apu_vgpu_xfer #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .back0_i(back0), .back1_i(back1),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .cmd_i(xcmd),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .img0_o(img0), .img1_o(img1),
    .peek_slot_i(xpeek_slot), .peek_addr_i(xpeek_addr), .peek_word_o(xpeek_word),
    .rd_valid_o(rd_valid), .rd_ready_i(rd_ready), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rd_rsp_ready), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_xfer_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .slot0_i(slot0), .slot1_i(slot1),
    .back0_i(back0), .back1_i(back1),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .cmd_i(xcmd),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .img0_o(off_img0), .img1_o(off_img1),
    .peek_slot_i(xpeek_slot), .peek_addr_i(xpeek_addr), .peek_word_o(off_xpeek),
    .rd_valid_o(off_rd_v), .rd_ready_i(rd_ready), .rd_addr_o(off_addr), .rd_len_o(off_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_used #(.Enable(1'b1)) i_used (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(ack),
    .req_valid_i(u_v), .req_ready_o(u_rdy), .req_i(ureq),
    .cpl_valid_o(u_cplv), .cpl_ready_i(u_cplr), .cpl_o(ucpl),
    .idx_o(u_idx), .irq_o(irq), .pending_o(pending),
    .peek_i(peek), .peek_id_o(peek_id), .peek_len_o(peek_len)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && rd_valid && rd_ready) reads++;
  end
  initial begin #200000; $fatal(1, "vgpu xfer timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_img0 !== '0 ||
        off_img1 !== '0 || off_rd_v !== 0 || off_rsp_rdy !== 0 ||
        off_addr !== 0 || off_len !== 0 || off_xpeek !== 0)
      $fatal(1, "disabled vgpu xfer active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] ramp();
    ramp = '0;
    for (int i = 0; i < 32; i++)
      ramp[i*8 +: 8] = 8'hA0 + i[7:0];
  endfunction

  function automatic logic [383:0] attach_cmd(
    input logic [31:0] rid,
    input logic [31:0] nr,
    input logic [63:0] addr,
    input logic [31:0] len
  );
    attach_cmd = {32'h0, len, addr, nr, rid, 32'h0, 32'd3, Fence,
                  VGPU_FLAG_FENCE, VGPU_CMD_RESOURCE_ATTACH_BACKING};
  endfunction

  function automatic logic [447:0] xfer_cmd(
    input logic [31:0] cmd_type,
    input logic [31:0] flags,
    input logic [63:0] fence,
    input logic [31:0] hdr_pad,
    input logic [31:0] x,
    input logic [31:0] y,
    input logic [31:0] w,
    input logic [31:0] h,
    input logic [63:0] offset,
    input logic [31:0] rid,
    input logic [31:0] tail_pad
  );
    xfer_cmd = {tail_pad, rid, offset, h, w, y, x, hdr_pad, 32'd3, fence, flags, cmd_type};
  endfunction

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

  task automatic attach_res(
    input logic [31:0] rid,
    input logic [63:0] addr,
    input logic [31:0] len,
    input string name
  );
    @(negedge clk);
    while (!b_rdy) @(negedge clk);
    bcmd = attach_cmd(rid, 32'd1, addr, len);
    b_v = 1;
    @(posedge clk); @(negedge clk); b_v = 0;
    while (!b_cplv) @(negedge clk);
    bsnap = bcpl;
    @(negedge clk);
    check($sformatf("%s held", name), b_cplv && !b_rdy && bcpl == bsnap);
    check($sformatf("%s ok", name), bsnap.resp_type == VGPU_RESP_OK_NODATA);
    b_cplr = 1;
    @(posedge clk); @(negedge clk); b_cplr = 0;
    while (b_cplv) @(negedge clk);
  endtask

  task automatic xfer_step(
    input logic [447:0] word,
    input logic [31:0] resp,
    input logic [31:0] flags,
    input logic [63:0] fence,
    input logic do_read,
    input logic [63:0] exp_addr,
    input logic [31:0] exp_len,
    input logic rsp_ok_v,
    input logic [63:0] rsp_addr_v,
    input logic [31:0] rsp_len_v,
    input logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data_v,
    input string name
  );
    apu_vgpu_cpl_t seen;
    apu_vgpu_img_t was0, was1;
    int was_reads;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was0 = img0;
    was1 = img1;
    was_reads = reads;
    xcmd = word;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    if (do_read) begin
      while (!rd_valid) @(negedge clk);
      check($sformatf("%s addr", name), rd_addr == exp_addr && rd_len == exp_len);
      rd_ready = 1;
      @(posedge clk); @(negedge clk); rd_ready = 0;
      if (rd_rsp_ready !== 1'b1) $fatal(1, "%s response not accepted", name);
      rsp_ok = rsp_ok_v;
      rsp_addr = rsp_addr_v;
      rsp_len = rsp_len_v;
      rsp_data = rsp_data_v;
      rsp_v = 1;
      @(posedge clk); @(negedge clk); rsp_v = 0;
    end
    while (!cpl_v) @(negedge clk);
    if (!do_read)
      check($sformatf("%s no read", name), rd_valid == 1'b0 && reads == was_reads);
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
    if (do_read)
      check($sformatf("%s one read", name), reads == was_reads + 1);
    if (resp != VGPU_RESP_OK_NODATA)
      check($sformatf("%s kept", name), img0 == was0 && img1 == was1);
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
    b_v = 0;
    b_cplr = 0;
    u_v = 0;
    u_cplr = 0;
    rd_ready = 0;
    rsp_v = 0;
    cancel = 0;
    ack = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  task automatic check_words(
    input logic slot,
    input logic [APU_VGPU_BEAT_BYTES*8-1:0] exp,
    input logic [31:0] nbytes,
    input string name
  );
    logic [31:0] got;
    int nwords;
    nwords = int'((nbytes + 32'd3) >> 2);
    for (int i = 0; i < nwords; i++) begin
      @(negedge clk);
      xpeek_slot = slot;
      xpeek_addr = APU_FRAG_ADDR_BITS'(i * 4);
      @(posedge clk);
      got = xpeek_word;
      check($sformatf("%s w%0d", name, i), got == exp[i*32 +: 32]);
    end
  endtask

  task automatic peek_at(
    input logic slot,
    input logic [31:0] addr,
    output logic [31:0] got
  );
    @(negedge clk);
    xpeek_slot = slot;
    xpeek_addr = addr[APU_FRAG_ADDR_BITS-1:0];
    @(posedge clk);
    got = xpeek_word;
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] pixels;
    logic [31:0] hi;
    xcmd = '0;
    vcmd = '0;
    bcmd = '0;
    ureq = '0;
    pixels = ramp();
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 &&
          img0 == '0 && img1 == '0 && rd_valid == 1'b0);
    check("profiles keep xfer off",
          !ApuOff.XferEn && !ApuP1Transport.XferEn && !ApuHarness.XferEn &&
          !ApuSchedBoth.XferEn && !ApuBadVirglGrant.XferEn);
    cfg = ApuP1Transport;
    cfg.XferEn = 1'b1;
    check("xfer does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.XferEn = 1'b1;
    check("xfer does not legalize virgl", !apu_cfg_legal(cfg));

    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_ERR_INVALID_RESOURCE_ID, VGPU_FLAG_FENCE, Fence, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "missing");

    create_res(32'd7, 32'd4, 32'd2, "create7");
    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "no backing");

    attach_res(32'd7, BackAddr, BackLen, "attach7");
    check("backing7", back0.valid && back0.addr == BackAddr && back0.length == BackLen);

    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'd1, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "origin");
    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, 32'h0, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h8, 32'd7, 32'h0),
              VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "offset");
    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, 32'h3, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "bad flags");
    xfer_step(xfer_cmd(VGPU_CMD_RESOURCE_ATTACH_BACKING, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "attach type");

    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, Fence, 1'b1,
              BackAddr, BackLen, 1'b1, BackAddr, BackLen, pixels, "read7");
    check("img0", img0.valid && img0.resource_id == 32'd7 && img0.length == BackLen);
    check_words(1'b0, pixels, BackLen, "img0");
    check("img1 empty", img1 == '0);

    publish_used(32'd6);
    check("published idx", u_idx == 16'd1 && irq == 1'b1 && usnap.ok &&
          usnap.desc_id == 32'd6 && usnap.len == VGPU_RESP_HDR_BYTES);
    peek = 3'd0;
    @(posedge clk);
    check("elem0", peek_id == 32'd6 && peek_len == VGPU_RESP_HDR_BYTES);
    @(negedge clk); ack = 1;
    @(posedge clk); @(negedge clk); ack = 0;
    check("ack drops irq", irq == 1'b0 && u_idx == 16'd1);

    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_ERR_UNSPEC, VGPU_FLAG_FENCE, Fence, 1'b1,
              BackAddr, BackLen, 1'b1, BackAddr + 64'h10, BackLen, pixels, "bad addr");
    check("bad addr keeps", img0.length == BackLen);
    check_words(1'b0, pixels, BackLen, "bad addr");
    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_ERR_UNSPEC, VGPU_FLAG_FENCE, Fence, 1'b1,
              BackAddr, BackLen, 1'b0, BackAddr, BackLen, pixels, "bus err");
    check("bus err keeps", img0.length == BackLen);
    check_words(1'b0, pixels, BackLen, "bus err");

    create_res(32'd8, 32'd1, 32'd1, "create8");
    attach_res(32'd8, BackAddr8, BackLen8, "attach8");
    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'h0, 32'h0, 32'd1, 32'd1, 64'h0, 32'd8, 32'h0),
              VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, Fence, 1'b1,
              BackAddr8, BackLen8, 1'b1, BackAddr8, BackLen8, Dirty4, "read8");
    check("img1 low", img1.valid && img1.resource_id == 32'd8 && img1.length == BackLen8);
    check_words(1'b1, Dirty4, BackLen8, "img1");
    peek_at(1'b1, 32'd4, hi);
    check("img1 high clear", hi == 32'h0);
    check("img0 stays", img0.valid && img0.resource_id == 32'd7);
    check_words(1'b0, pixels, BackLen, "img0 stays");

    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, 32'h0, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd8, 32'h1),
              VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "tail");
    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, 32'h0, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd8, 32'h0),
              VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "rect");

    pulse_reset();
    check("reset clears", img0 == '0 && img1 == '0 && back0 == '0 && slot0 == '0);
    xfer_step(xfer_cmd(VGPU_CMD_TRANSFER_TO_HOST_2D, VGPU_FLAG_FENCE, Fence,
                       32'h0, 32'h0, 32'h0, 32'd4, 32'd2, 64'h0, 32'd7, 32'h0),
              VGPU_RESP_ERR_INVALID_RESOURCE_ID, VGPU_FLAG_FENCE, Fence, 1'b0,
              64'h0, 32'h0, 1'b0, 64'h0, 32'h0, '0, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu xfer errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_xfer cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
