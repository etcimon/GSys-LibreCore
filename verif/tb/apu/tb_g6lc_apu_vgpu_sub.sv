// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_sub;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v, off_rd_v, off_rsp_rdy;
  logic rd_valid, rd_ready = 0, rd_rsp_ready;
  logic [63:0] rd_addr, off_addr;
  logic [31:0] rd_len, off_len;
  logic rsp_v = 0, rsp_ok = 0;
  logic [63:0] rsp_addr = '0;
  logic [31:0] rsp_len = '0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = '0;
  apu_vgpu_sub_req_t req;
  apu_vgpu_cpl_t cpl, off_cpl, snap;
  apu_vgpu_sub_t sub, off_sub;
  int errors = 0, checks = 0, cycles = 0, cases = 0, reads = 0;

  localparam logic [63:0] Fence = 64'h1122_3344_5566_7788;
  localparam logic [63:0] HdrAddr = 64'h0000_0000_8800_A000;
  localparam logic [63:0] BufAddr = 64'h0000_0000_8800_B000;
  localparam logic [63:0] RspAddr = 64'h0000_0000_8800_A800;
  localparam logic [31:0] SceneLen = 32'd960;

  g6lc_apu_vgpu_sub #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .sub_o(sub),
    .rd_valid_o(rd_valid), .rd_ready_i(rd_ready), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rd_rsp_ready), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_sub_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .sub_o(off_sub),
    .rd_valid_o(off_rd_v), .rd_ready_i(rd_ready), .rd_addr_o(off_addr), .rd_len_o(off_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && rd_valid && rd_ready) reads++;
  end
  initial begin #200000; $fatal(1, "vgpu sub timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_sub !== '0 ||
        off_rd_v !== 0 || off_rsp_rdy !== 0 || off_addr !== 0 || off_len !== 0)
      $fatal(1, "disabled vgpu sub active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic apu_vgpu_desc_t desc_of(
    input logic [63:0] addr,
    input logic [31:0] len,
    input logic [15:0] flags,
    input logic [15:0] next
  );
    desc_of.addr = addr;
    desc_of.len = len;
    desc_of.flags = flags;
    desc_of.next = next;
  endfunction

  function automatic apu_vgpu_sub_req_t chain(input logic [31:0] blen);
    chain.d0 = desc_of(HdrAddr, VGPU_SUBMIT_BYTES, VIRTQ_DESC_F_NEXT, 16'd1);
    chain.d1 = desc_of(BufAddr, blen, VIRTQ_DESC_F_NEXT, 16'd2);
    chain.d2 = desc_of(RspAddr, VGPU_RESP_HDR_BYTES, VIRTQ_DESC_F_WRITE, 16'd0);
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] hdr_of(
    input logic [31:0] cmd_type,
    input logic [31:0] flags,
    input logic [63:0] fence,
    input logic [31:0] ctx,
    input logic [31:0] hdr_pad,
    input logic [31:0] size,
    input logic [31:0] tail_pad
  );
    hdr_of = {tail_pad, size, hdr_pad, ctx, fence, flags, cmd_type};
  endfunction

  task automatic sub_step(
    input apu_vgpu_sub_req_t word,
    input logic [31:0] resp,
    input logic [31:0] flags,
    input logic [63:0] fence,
    input logic [31:0] ctx,
    input logic do_read,
    input logic rsp_ok_v,
    input logic [63:0] rsp_addr_v,
    input logic [31:0] rsp_len_v,
    input logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data_v,
    input string name
  );
    apu_vgpu_cpl_t seen;
    apu_vgpu_sub_t was;
    int was_reads;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was = sub;
    was_reads = reads;
    req = word;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    if (do_read) begin
      while (!rd_valid) @(negedge clk);
      check($sformatf("%s addr", name), rd_addr == HdrAddr && rd_len == VGPU_SUBMIT_BYTES);
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
    check($sformatf("%s ctx", name), cpl.ctx_id == ctx);
    check($sformatf("%s quiet ids", name), cpl.resource_id == 0 && cpl.format == 0 &&
          cpl.width == 0 && cpl.height == 0);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (do_read)
      check($sformatf("%s one read", name), reads == was_reads + 1);
    if (resp != VGPU_RESP_OK_NODATA)
      check($sformatf("%s kept", name), sub == was);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    rd_ready = 0;
    rsp_v = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] good, bad_type, bad_size, bad_pad;
    apu_vgpu_sub_req_t word;
    req = '0;
    good = hdr_of(VGPU_CMD_SUBMIT_3D, VGPU_FLAG_FENCE, Fence, 32'd3, 32'h0,
                  32'd32, 32'h0);
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 &&
          sub == '0 && rd_valid == 1'b0);
    check("profiles keep sub off",
          !ApuOff.SubEn && !ApuP1Transport.SubEn && !ApuHarness.SubEn &&
          !ApuSchedBoth.SubEn && !ApuBadVirglGrant.SubEn);
    cfg = ApuP1Transport;
    cfg.SubEn = 1'b1;
    check("sub does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.SubEn = 1'b1;
    check("sub does not legalize virgl", !apu_cfg_legal(cfg));

    sub_step('0, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "empty");
    word = chain(32'd32);
    word.d0.flags = VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT;
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "indirect");
    word = chain(32'd32);
    word.d0.flags = VIRTQ_DESC_F_WRITE;
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "cmd write");
    word = chain(32'd32);
    word.d0.flags = 16'h0;
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "no next");
    word = chain(32'd32);
    word.d0.next = 16'd4;
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "bad link");
    word = chain(32'd0);
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "empty buf");
    word = chain(APU_VGPU_SUB_MAX + 32'd1);
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "buf ceiling");
    word = chain(32'd32);
    word.d2.flags = 16'h0;
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "resp not write");
    word = chain(32'd32);
    word.d2.flags = VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_NEXT;
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "resp next");
    word = chain(32'd32);
    word.d0.addr = 64'h1;
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "align");
    word = chain(32'd32);
    word.d1.addr = 64'hffff_ffff_ffff_fff0;
    word.d1.len = 32'd32;
    sub_step(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "wrap");

    bad_type = hdr_of(VGPU_CMD_RESOURCE_CREATE_2D, VGPU_FLAG_FENCE, Fence, 32'd3,
                      32'h0, 32'd32, 32'h0);
    sub_step(chain(32'd32), VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence,
             32'd3, 1'b1, 1'b1, HdrAddr, VGPU_SUBMIT_BYTES, bad_type, "not submit");
    bad_size = hdr_of(VGPU_CMD_SUBMIT_3D, VGPU_FLAG_FENCE, Fence, 32'd3, 32'h0,
                      32'd16, 32'h0);
    sub_step(chain(32'd32), VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence,
             32'd3, 1'b1, 1'b1, HdrAddr, VGPU_SUBMIT_BYTES, bad_size, "size");
    bad_pad = hdr_of(VGPU_CMD_SUBMIT_3D, 32'h3, Fence, 32'd3, 32'h0, 32'd32, 32'h0);
    sub_step(chain(32'd32), VGPU_RESP_ERR_INVALID_PARAMETER, VGPU_FLAG_FENCE, Fence,
             32'd3, 1'b1, 1'b1, HdrAddr, VGPU_SUBMIT_BYTES, bad_pad, "bad flags");
    sub_step(chain(32'd32), VGPU_RESP_ERR_UNSPEC, 32'h0, 64'h0, 32'h0, 1'b1,
             1'b0, HdrAddr, VGPU_SUBMIT_BYTES, good, "bus");
    sub_step(chain(32'd32), VGPU_RESP_ERR_UNSPEC, 32'h0, 64'h0, 32'h0, 1'b1,
             1'b1, HdrAddr + 64'h10, VGPU_SUBMIT_BYTES, good, "bad rsp addr");
    check("still empty", sub == '0);

    sub_step(chain(32'd32), VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, Fence, 32'd3,
             1'b1, 1'b1, HdrAddr, VGPU_SUBMIT_BYTES, good, "submit");
    check("recorded", sub.valid && sub.ctx_id == 32'd3 && sub.size == 32'd32 &&
          sub.buf_addr == BufAddr && sub.rsp_addr == RspAddr);
    sub_step(chain(32'd32), VGPU_RESP_ERR_UNSPEC, 32'h0, 64'h0, 32'h0, 1'b0,
             1'b0, 64'h0, 32'h0, '0, "second");
    check("second keeps", sub.valid && sub.size == 32'd32 && sub.buf_addr == BufAddr);

    pulse_reset();
    check("reset clears", sub == '0 && rd_valid == 1'b0);
    good = hdr_of(VGPU_CMD_SUBMIT_3D, VGPU_FLAG_FENCE, Fence, 32'd1, 32'h0,
                  SceneLen, 32'h0);
    sub_step(chain(SceneLen), VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, Fence, 32'd1,
             1'b1, 1'b1, HdrAddr, VGPU_SUBMIT_BYTES, good, "scene");
    check("scene buf", sub.valid && sub.ctx_id == 32'd1 && sub.size == SceneLen &&
          sub.buf_addr == BufAddr && sub.rsp_addr == RspAddr);

    if (errors != 0) $fatal(1, "APU vgpu sub errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_sub cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
