// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_buf;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic s_v = 0, s_rdy, s_cplv, s_cplr = 0;
  logic s_rd_v, s_rd_rdy = 0, s_rsp_rdy;
  logic [63:0] s_rd_addr;
  logic [31:0] s_rd_len;
  logic s_rsp_v = 0, s_rsp_ok = 0;
  logic [63:0] s_rsp_addr = '0;
  logic [31:0] s_rsp_len = '0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] s_rsp_data = '0;
  apu_vgpu_sub_req_t sreq;
  apu_vgpu_cpl_t scpl;
  apu_vgpu_sub_t live;

  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v, off_rd_v, off_rsp_rdy;
  logic rd_valid, rd_ready = 0, rd_rsp_ready;
  logic [63:0] rd_addr, off_addr;
  logic [31:0] rd_len, off_len;
  logic rsp_v = 0, rsp_ok = 0;
  logic [63:0] rsp_addr = '0;
  logic [31:0] rsp_len = '0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = '0;
  logic use_force = 0;
  apu_vgpu_sub_t forced, buf_sub;
  apu_vgpu_buf_cpl_t cpl, off_cpl, snap;
  apu_vgpu_buf_t got, off_got;
  logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr = '0;
  logic [31:0] peek_word, off_peek;
  int errors = 0, checks = 0, cycles = 0, cases = 0, reads = 0;

  localparam logic [63:0] Fence = 64'h1122_3344_5566_7788;
  localparam logic [63:0] HdrAddr = 64'h0000_0000_8800_A000;
  localparam logic [63:0] BufAddr = 64'h0000_0000_8800_B000;
  localparam logic [63:0] RspAddr = 64'h0000_0000_8800_A800;
  localparam logic [31:0] TailLen = 32'd40;
  localparam logic [31:0] SceneLen = 32'd960;

  assign buf_sub = use_force ? forced : live;

  g6lc_apu_vgpu_sub #(.Enable(1'b1)) i_sub (
    .clk_i(clk), .rst_ni, .req_valid_i(s_v), .req_ready_o(s_rdy), .req_i(sreq),
    .cpl_valid_o(s_cplv), .cpl_ready_i(s_cplr), .cpl_o(scpl), .sub_o(live),
    .rd_valid_o(s_rd_v), .rd_ready_i(s_rd_rdy), .rd_addr_o(s_rd_addr), .rd_len_o(s_rd_len),
    .rd_rsp_valid_i(s_rsp_v), .rd_rsp_ready_o(s_rsp_rdy), .rd_rsp_ok_i(s_rsp_ok),
    .rd_rsp_addr_i(s_rsp_addr), .rd_rsp_len_i(s_rsp_len), .rd_rsp_data_i(s_rsp_data)
  );
  g6lc_apu_vgpu_buf #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .sub_i(buf_sub),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .buf_o(got),
    .peek_addr_i(peek_addr), .peek_word_o(peek_word),
    .rd_valid_o(rd_valid), .rd_ready_i(rd_ready), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rd_rsp_ready), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_buf_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sub_i(buf_sub),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .buf_o(off_got),
    .peek_addr_i(peek_addr), .peek_word_o(off_peek),
    .rd_valid_o(off_rd_v), .rd_ready_i(rd_ready), .rd_addr_o(off_addr), .rd_len_o(off_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && rd_valid && rd_ready) reads++;
  end
  initial begin #200000; $fatal(1, "vgpu buf timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_got !== '0 ||
        off_peek !== 0 || off_rd_v !== 0 || off_rsp_rdy !== 0 ||
        off_addr !== 0 || off_len !== 0)
      $fatal(1, "disabled vgpu buf active");
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
    input logic [31:0] ctx,
    input logic [31:0] size
  );
    hdr_of = {32'h0, size, 32'h0, ctx, Fence, VGPU_FLAG_FENCE, VGPU_CMD_SUBMIT_3D};
  endfunction

  function automatic logic [31:0] beat_n(
    input logic [31:0] off, input logic [31:0] total
  );
    logic [31:0] remain;
    remain = total - off;
    beat_n = remain > APU_VGPU_BEAT_BYTES ? APU_VGPU_BEAT_BYTES : remain;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] beat_bytes(
    input logic [31:0] off, input logic [31:0] n
  );
    beat_bytes = '0;
    for (int k = 0; k < APU_VGPU_BEAT_BYTES; k++) begin
      if (32'(k) < n)
        beat_bytes[k*8 +: 8] = 8'(off + 32'(k));
    end
  endfunction

  function automatic logic [31:0] word_at(input logic [31:0] off);
    word_at = {8'(off + 32'd3), 8'(off + 32'd2), 8'(off + 32'd1), 8'(off)};
  endfunction

  task automatic look(input logic [31:0] off, input logic [31:0] exp, input string name);
    @(negedge clk);
    peek_addr = off[APU_VGPU_BUF_ADDRW-1:0];
    @(posedge clk);
    check(name, peek_word == exp);
  endtask

  task automatic submit(input logic [31:0] ctx, input logic [31:0] size, input string name);
    @(negedge clk);
    while (!s_rdy) @(negedge clk);
    cases++;
    sreq = chain(size);
    s_v = 1;
    @(posedge clk); @(negedge clk); s_v = 0;
    while (!s_rd_v) @(negedge clk);
    check($sformatf("%s hdr", name), s_rd_addr == HdrAddr && s_rd_len == VGPU_SUBMIT_BYTES);
    s_rd_rdy = 1;
    @(posedge clk); @(negedge clk); s_rd_rdy = 0;
    s_rsp_ok = 1;
    s_rsp_addr = HdrAddr;
    s_rsp_len = VGPU_SUBMIT_BYTES;
    s_rsp_data = hdr_of(ctx, size);
    s_rsp_v = 1;
    @(posedge clk); @(negedge clk); s_rsp_v = 0;
    while (!s_cplv) @(negedge clk);
    check($sformatf("%s ok", name), scpl.resp_type == VGPU_RESP_OK_NODATA &&
          live.valid && live.size == size && live.buf_addr == BufAddr &&
          live.ctx_id == ctx);
    @(negedge clk);
    s_cplr = 1;
    @(posedge clk); @(negedge clk); s_cplr = 0;
    while (s_cplv) @(negedge clk);
  endtask

  task automatic buf_step(
    input apu_vgpu_buf_status_e st,
    input logic do_read,
    input int fail_beat,
    input logic [31:0] exp_size,
    input logic [63:0] exp_base,
    input string name
  );
    apu_vgpu_buf_cpl_t seen;
    apu_vgpu_buf_t was;
    int was_reads, nbeats, b;
    logic [31:0] off, n;
    logic fail;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was = got;
    was_reads = reads;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    if (do_read) begin
      off = '0;
      b = 0;
      fail = 1'b0;
      nbeats = fail_beat >= 0 ? fail_beat + 1 : int'((exp_size + 32'd31) >> 5);
      while (b < nbeats) begin
        while (!rd_valid) @(negedge clk);
        n = beat_n(off, exp_size);
        check($sformatf("%s beat %0d", name, b),
              rd_addr == exp_base + 64'(off) && rd_len == n);
        rd_ready = 1;
        @(posedge clk); @(negedge clk); rd_ready = 0;
        if (rd_rsp_ready !== 1'b1) $fatal(1, "%s response not accepted", name);
        if (b == fail_beat) begin
          rsp_ok = 1'b0;
          rsp_addr = exp_base + 64'(off);
          rsp_len = n;
          rsp_data = '0;
          fail = 1'b1;
        end else begin
          rsp_ok = 1'b1;
          rsp_addr = exp_base + 64'(off);
          rsp_len = n;
          rsp_data = beat_bytes(off, n);
        end
        rsp_v = 1;
        @(posedge clk); @(negedge clk); rsp_v = 0;
        if (fail) b = nbeats;
        else begin
          off = off + n;
          b = b + 1;
        end
      end
    end
    while (!cpl_v) @(negedge clk);
    if (!do_read)
      check($sformatf("%s no read", name), rd_valid == 1'b0 && reads == was_reads);
    seen = cpl;
    snap = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    if (st == APU_VGPU_BUF_OK)
      check($sformatf("%s ids", name), cpl.ctx_id == got.ctx_id && cpl.size == exp_size);
    else
      check($sformatf("%s quiet", name), cpl.ctx_id == 0 && cpl.size == 0);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (do_read) begin
      if (fail_beat >= 0)
        check($sformatf("%s reads", name), reads == was_reads + fail_beat + 1);
      else
        check($sformatf("%s reads", name), reads == was_reads + int'((exp_size + 32'd31) >> 5));
    end
    if (st != APU_VGPU_BUF_OK)
      check($sformatf("%s kept", name), got == was);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    s_v = 0;
    s_cplr = 0;
    s_rd_rdy = 0;
    s_rsp_v = 0;
    req_v = 0;
    cpl_r = 0;
    rd_ready = 0;
    rsp_v = 0;
    use_force = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    sreq = '0;
    forced = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 &&
          got == '0 && rd_valid == 1'b0);
    check("profiles keep buf off",
          !ApuOff.BufEn && !ApuP1Transport.BufEn && !ApuHarness.BufEn &&
          !ApuSchedBoth.BufEn && !ApuBadVirglGrant.BufEn);
    cfg = ApuP1Transport;
    cfg.BufEn = 1'b1;
    check("buf does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.BufEn = 1'b1;
    check("buf does not legalize virgl", !apu_cfg_legal(cfg));

    buf_step(APU_VGPU_BUF_EMPTY, 1'b0, -1, 32'h0, 64'h0, "empty");

    forced = '0;
    forced.valid = 1'b1;
    forced.ctx_id = 32'd3;
    forced.size = 32'd0;
    forced.buf_addr = BufAddr;
    use_force = 1;
    buf_step(APU_VGPU_BUF_FAULT, 1'b0, -1, 32'h0, 64'h0, "zero size");
    forced.size = APU_VGPU_SUB_MAX + 32'd1;
    buf_step(APU_VGPU_BUF_FAULT, 1'b0, -1, 32'h0, 64'h0, "over size");
    forced.size = 32'd32;
    forced.buf_addr = 64'h0;
    buf_step(APU_VGPU_BUF_FAULT, 1'b0, -1, 32'h0, 64'h0, "zero addr");
    forced.buf_addr = 64'h1;
    buf_step(APU_VGPU_BUF_FAULT, 1'b0, -1, 32'h0, 64'h0, "align");
    forced.buf_addr = 64'hffff_ffff_ffff_fff0;
    buf_step(APU_VGPU_BUF_FAULT, 1'b0, -1, 32'h0, 64'h0, "wrap");
    use_force = 0;

    submit(32'd3, TailLen, "submit tail");
    buf_step(APU_VGPU_BUF_BUS, 1'b1, 1, TailLen, BufAddr, "bus later");
    check("bus keeps clear", got.valid == 1'b0);
    buf_step(APU_VGPU_BUF_OK, 1'b1, -1, TailLen, BufAddr, "tail");
    check("tail record", got.valid && got.ctx_id == 32'd3 && got.size == TailLen &&
          got.buf_addr == BufAddr);
    look(32'd0, word_at(32'd0), "tail word0");
    look(32'd36, word_at(32'd36), "tail last");
    look(32'd40, 32'h0, "tail past");
    buf_step(APU_VGPU_BUF_FAULT, 1'b0, -1, 32'h0, 64'h0, "second");
    check("second keeps", got.valid && got.size == TailLen);

    pulse_reset();
    check("reset clears", got == '0 && live == '0);
    submit(32'd1, SceneLen, "submit scene");
    buf_step(APU_VGPU_BUF_OK, 1'b1, -1, SceneLen, BufAddr, "scene");
    check("scene record", got.valid && got.ctx_id == 32'd1 && got.size == SceneLen &&
          got.buf_addr == BufAddr);
    look(32'd0, word_at(32'd0), "scene word0");
    look(32'd956, word_at(32'd956), "scene last");

    if (errors != 0) $fatal(1, "APU vgpu buf errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_buf cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
