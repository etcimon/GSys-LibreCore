// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AvailNext WRITE-window response. Programmed OK_NODATA bytes, not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_prs;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic resp_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [2:0] resp_idx = 0;
  logic [31:0] resp_wdata = 0, resp_len = 0;
  apu_avn_req_t req;
  apu_prs_cpl_t cpl;
  apu_prs_t rec;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, wr_addr, last_wr_addr = 0;
  logic [31:0] rd_len, rsp_len = 0, wr_len, last_wr_len = 0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0, wr_data, last_wr_data = 0;
  logic off_rdy, off_v, off_rd, off_wr, off_rr, off_wr_r;
  apu_prs_cpl_t off_cpl;
  apu_prs_t off_rec;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0;

  localparam logic [63:0] Avail1 = 64'h0000_0000_0000_0200;
  localparam logic [63:0] BaseA  = 64'h0000_0000_0000_1000;
  localparam logic [63:0] Pay0   = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay1   = 64'h0000_0000_8800_A000;
  localparam logic [63:0] Pay2   = 64'h0000_0000_8800_A800;
  localparam logic [31:0] Len0   = 32'd32;
  localparam logic [31:0] Len1   = 32'd960;
  localparam logic [31:0] Len2   = 32'd24;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;

  g6lc_apu_prs #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .resp_we_i(resp_we), .resp_idx_i(resp_idx),
    .resp_wdata_i(resp_wdata), .resp_len_i(resp_len),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .prs_o(rec),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok)
  );
  g6lc_apu_prs_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .resp_we_i(resp_we), .resp_idx_i(resp_idx),
    .resp_wdata_i(resp_wdata), .resp_len_i(resp_len),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .prs_o(off_rec),
    .rd_valid_o(off_rd), .rd_ready_i(rd_rdy), .rd_addr_o(), .rd_len_o(),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rr), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(off_wr), .wr_ready_i(wr_rdy), .wr_addr_o(), .wr_len_o(),
    .wr_data_o(), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(off_wr_r),
    .wr_rsp_ok_i(wr_ok)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "prs timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 || off_wr !== 1'b0 ||
        off_rec !== '0)
      $fatal(1, "disabled prs active");
  end

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_desc(
      input logic [63:0] addr, input logic [31:0] len,
      input logic [15:0] flags, input logic [15:0] nxt);
    pack_desc = '0;
    pack_desc[63:0] = addr;
    pack_desc[95:64] = len;
    pack_desc[111:96] = flags;
    pack_desc[127:112] = nxt;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_word(input logic [31:0] w);
    pack_word = '0;
    pack_word[31:0] = w;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] lookup(input logic [63:0] addr);
    lookup = '0;
    if (addr == Avail1)
      lookup = pack_word(32'h0001_0000);
    else if (addr == Avail1 + 64'd4)
      lookup = pack_word(32'h0000_0000);
    else if (addr == BaseA + 64'd0)
      lookup = pack_desc(Pay0, Len0, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'd16)
      lookup = pack_desc(Pay1, Len1, VIRTQ_DESC_F_NEXT, 16'd2);
    else if (addr == BaseA + 64'd32)
      lookup = pack_desc(Pay2, Len2, VIRTQ_DESC_F_WRITE, 16'd0);
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
    end else begin
      if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
      else if (rd_v && rd_rdy) begin
        rsp_addr <= rd_addr;
        rsp_len <= rd_len;
        rsp_data <= lookup(rd_addr);
        rsp_ok <= (rd_len == 32'd4) || (rd_len == 32'(APU_CHAIN_DESC_BYTES));
        rsp_v <= 1'b1;
      end
      if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
      else if (wr_v && wr_rdy) begin
        last_wr_addr <= wr_addr;
        last_wr_len <= wr_len;
        last_wr_data <= wr_data;
        wr_ok <= 1'b1;
        nwrite <= nwrite + 1;
        wr_rsp_v <= 1'b1;
      end
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d nw=%0d", name, cases, cycles, nwrite);
    end
  endtask

  task automatic do_reset;
    req_v = 1'b0; cpl_r = 1'b0; resp_we = 1'b0; req = '0; resp_len = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic poke_resp(input int unsigned idx, input logic [31:0] w);
    @(negedge clk);
    resp_we = 1'b1;
    resp_idx = 3'(idx);
    resp_wdata = w;
    @(posedge clk);
    @(negedge clk);
    resp_we = 1'b0;
  endtask

  task automatic fire(input apu_avn_req_t r);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r;
    req_v = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  task automatic ack;
    @(negedge clk);
    cpl_r = 1'b1;
    @(posedge clk);
    while (cpl_v) @(posedge clk);
    @(negedge clk);
    cpl_r = 1'b0;
  endtask

  initial begin
    apu_avn_req_t r;
    apu_cfg_t cfg;
    int unsigned w0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_wr == 1'b0 &&
          req_rdy == 1'b1);
    check("profiles keep prs off",
          !ApuOff.PrsEn && !ApuP1Transport.PrsEn && !ApuHarness.PrsEn);
    cfg = ApuP1Transport;
    cfg.PrsEn = 1'b1;
    check("prs does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.PrsEn = 1'b1;
    check("prs does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    poke_resp(0, VGPU_RESP_OK_NODATA);
    poke_resp(1, 32'd1);
    poke_resp(2, 32'h5566_7788);
    poke_resp(3, 32'h1122_3344);
    poke_resp(4, 32'd1);
    poke_resp(5, 32'd0);
    resp_len = Len2;
    w0 = nwrite;
    r = '0;
    r.avail_base = Avail1;
    r.desc_base = BaseA;
    r.queue_size = 8'd4;
    r.device_idx = 16'd0;
    r.max_chain = 4'd8;
    fire(r);
    check("write ok", cpl.status == APU_PRS_OK && rec.valid && rec.addr == Pay2 &&
          rec.bytes == Len2 && rec.word0 == VGPU_RESP_OK_NODATA);
    check("write beat", (nwrite - w0) == 1 && last_wr_addr == Pay2 &&
          last_wr_len == Len2 && last_wr_data[31:0] == VGPU_RESP_OK_NODATA &&
          last_wr_data[63:32] == 32'd1);
    ack();

    cases++;
    w0 = nwrite;
    r.device_idx = 16'd1;
    fire(r);
    check("empty no write", cpl.status == APU_PRS_EMPTY && !rec.valid &&
          (nwrite - w0) == 0);
    ack();

    cases++;
    do_reset;
    poke_resp(0, VGPU_RESP_OK_NODATA);
    resp_len = 32'd8;
    r.device_idx = 16'd0;
    fire(r);
    check("len mismatch faults", cpl.status == APU_PRS_FAULT && !rec.valid);
    ack();

    if (errors != 0) $fatal(1, "APU prs errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_prs cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
