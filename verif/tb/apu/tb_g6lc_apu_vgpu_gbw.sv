// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_gbw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_wfr_t wfr;
  apu_vgpu_wfk_t wfk;
  apu_vgpu_gpk_t gpk;
  apu_vgpu_cwr_t cwr;
  apu_vgpu_cxr_t cxr;
  apu_vgpu_vak_t vak;
  logic gbw_req = 0, gbw_rdy, gbw_cpl_v, gbw_cpl_r = 0;
  apu_vgpu_gbw_cpl_t gbw_cpl;
  apu_vgpu_gbw_t gbw;
  logic srd_v, srd_rdy, srd_rsp_v = 0, srd_rsp_rdy, srd_rsp_ok = 0;
  logic [63:0] srd_addr, srd_rsp_addr = 0, sseen = 0;
  logic [31:0] srd_len, srd_rsp_len = 0;
  logic [255:0] srd_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic gbr_req = 0, gbr_rdy, gbr_cpl_v, gbr_cpl_r = 0;
  apu_vgpu_gbr_cpl_t gbr_cpl;
  apu_vgpu_gbr_t gbr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd0 = 0, rd1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic gbk_req = 0, gbk_rdy, gbk_cpl_v, gbk_cpl_r = 0;
  apu_vgpu_gbk_cpl_t gbk_cpl, off_cpl;
  apu_vgpu_gbk_t gbk, off_gbk;
  logic off_rdy, off_v;
  logic fail_s = 0, fail_w = 0, fail_d = 0, bad_src = 0, bad_tail = 0;
  logic s_order = 0, w_order = 0, w_data = 0, d_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int ns = 0, nw = 0, nd = 0, sbase = 0, wbase = 0, dbase = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign srd_rdy = srd_v && rst_ni && !srd_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_gbw #(.Enable(1'b1)) i_gbw (
    .clk_i(clk), .rst_ni, .wfr_i(wfr), .wfk_i(wfk), .gpk_i(gpk), .cwr_i(cwr),
    .cxr_i(cxr), .vak_i(vak),
    .req_valid_i(gbw_req), .req_ready_o(gbw_rdy),
    .cpl_valid_o(gbw_cpl_v), .cpl_ready_i(gbw_cpl_r), .cpl_o(gbw_cpl), .gbw_o(gbw),
    .rd_valid_o(srd_v), .rd_ready_i(srd_rdy), .rd_addr_o(srd_addr), .rd_len_o(srd_len),
    .rd_rsp_valid_i(srd_rsp_v), .rd_rsp_ready_o(srd_rsp_rdy), .rd_rsp_ok_i(srd_rsp_ok),
    .rd_rsp_addr_i(srd_rsp_addr), .rd_rsp_len_i(srd_rsp_len), .rd_rsp_data_i(srd_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_gbr #(.Enable(1'b1)) i_gbr (
    .clk_i(clk), .rst_ni, .gbw_i(gbw), .wfr_i(wfr),
    .req_valid_i(gbr_req), .req_ready_o(gbr_rdy),
    .cpl_valid_o(gbr_cpl_v), .cpl_ready_i(gbr_cpl_r), .cpl_o(gbr_cpl), .gbr_o(gbr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_gbk #(.Enable(1'b1)) i_gbk (
    .clk_i(clk), .rst_ni, .gbr_i(gbr), .gbw_i(gbw), .wfr_i(wfr), .gpk_i(gpk),
    .req_valid_i(gbk_req), .req_ready_o(gbk_rdy),
    .cpl_valid_o(gbk_cpl_v), .cpl_ready_i(gbk_cpl_r), .cpl_o(gbk_cpl), .gbk_o(gbk)
  );
  g6lc_apu_vgpu_gbk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .gbr_i(gbr), .gbw_i(gbw), .wfr_i(wfr), .gpk_i(gpk),
    .req_valid_i(gbk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(gbk_cpl_r), .cpl_o(off_cpl), .gbk_o(off_gbk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu gbw timeout case=%0d s=%0d", cases, ns); end

  function automatic logic [63:0] at_src(input int idx);
    at_src = APU_VGPU_GPW_ADDR + (64'(idx) << 5);
  endfunction
  function automatic logic [63:0] at_dst(input int idx);
    at_dst = APU_VGPU_GBW_ADDR + (64'(idx) << 5);
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      srd_rsp_v <= 1'b0;
      ns <= 0;
      s_order <= 1'b0;
    end else if (srd_rsp_v && srd_rsp_rdy) srd_rsp_v <= 1'b0;
    else if (srd_v && srd_rdy) begin
      int idx;
      logic [255:0] beat;
      idx = ns - sbase;
      beat = Pat;
      if (idx == 0 && bad_src) beat[31:0] = 32'h0;
      if (srd_addr != at_src(idx) || srd_len != 32'(APU_VGPU_BEAT_BYTES))
        s_order <= 1'b1;
      sseen <= srd_addr;
      srd_rsp_addr <= srd_addr;
      srd_rsp_len <= srd_len;
      srd_rsp_data <= beat;
      srd_rsp_ok <= !fail_s;
      fail_s <= 1'b0;
      if (idx == 0) bad_src <= 1'b0;
      ns <= ns + 1;
      srd_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nw <= 0;
      w_order <= 1'b0;
      w_data <= 1'b0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      int idx;
      idx = nw - wbase;
      if (wr_addr != at_dst(idx) || wr_len != 32'(APU_VGPU_BEAT_BYTES))
        w_order <= 1'b1;
      if (wr_data != Pat) w_data <= 1'b1;
      wseen <= wr_addr;
      wr_rsp_addr <= wr_addr;
      wr_rsp_ok <= !fail_w;
      fail_w <= 1'b0;
      nw <= nw + 1;
      wr_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nd <= 0;
      d_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [255:0] beat;
      logic [63:0] want;
      idx = nd - dbase;
      want = idx == 0 ? APU_VGPU_GBW_ADDR : APU_VGPU_GBW_TAIL;
      beat = Pat;
      if (idx == 1 && bad_tail) beat[31:0] = 32'h0;
      if (rd_addr != want || rd_len != 32'(APU_VGPU_BEAT_BYTES)) d_order <= 1'b1;
      if (idx == 0) rd0 <= rd_addr;
      else rd1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_d;
      fail_d <= 1'b0;
      if (idx == 1) bad_tail <= 1'b0;
      nd <= nd + 1;
      rd_rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_in;
    wfr = '0;
    wfr.valid = 1'b1;
    wfr.word = APU_VGPU_CLEAR_WORD;
    wfr.pix10 = APU_VGPU_CLEAR_WORD;
    wfr.pix63 = APU_VGPU_CLEAR_WORD;
    wfr.beats = APU_VGPU_GPW_BEATS;
    wfr.base = APU_VGPU_GPW_ADDR;
    wfr.tail = APU_VGPU_GPW_TAIL;
    wfk = '0;
    wfk.valid = 1'b1;
    wfk.word = APU_VGPU_CLEAR_WORD;
    wfk.pix10 = APU_VGPU_CLEAR_WORD;
    wfk.pix63 = APU_VGPU_CLEAR_WORD;
    wfk.beats = APU_VGPU_GPW_BEATS;
    gpk = '0;
    gpk.valid = 1'b1;
    gpk.word = APU_VGPU_CLEAR_WORD;
    gpk.first = APU_VGPU_GPW_ADDR;
    gpk.last = APU_VGPU_GPW_TAIL;
    cwr = '0;
    cwr.valid = 1'b1;
    cwr.word = APU_VGPU_CLEAR_WORD;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    vak = '0;
    vak.valid = 1'b1;
    vak.ack = APU_VGPU_VIW_REASON;
    vak.remain = APU_VGPU_VAW_CLEAR;
    vak.used_idx = 16'd1;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_gbk == '0 &&
          off_cpl == '0);
  endtask

  task automatic gbw_step(input apu_vgpu_gbw_status_e st, input string name);
    int rs, rw;
    @(negedge clk);
    while (!gbw_rdy) @(negedge clk);
    cases++;
    rs = ns;
    rw = nw;
    sbase = ns;
    wbase = nw;
    gbw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbw_req = 1'b0;
    while (!gbw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gbw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GBW_OK) begin
      check("copied", gbw.valid && gbw.word == APU_VGPU_CLEAR_WORD &&
            gbw.beats == 16'd512 && gbw.src == APU_VGPU_GPW_ADDR &&
            gbw.dst == APU_VGPU_GBW_ADDR && gbw.src != gbw.dst);
      check("copy count", ns == rs + 512 && nw == rw + 512 && !s_order &&
            !w_order && !w_data && sseen == APU_VGPU_GPW_TAIL &&
            wseen == APU_VGPU_GBW_TAIL);
    end else if (name == "bad source") begin
      check("one read", ns == rs + 1 && nw == rw && !gbw.valid);
    end else if (name == "bad write") begin
      check("one pair", ns == rs + 1 && nw == rw + 1 && !gbw.valid);
    end else check("no bus", ns == rs && nw == rw);
    @(negedge clk);
    check($sformatf("%s held", name), gbw_cpl_v);
    gbw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbw_cpl_r = 1'b0;
    while (gbw_cpl_v) @(negedge clk);
  endtask

  task automatic gbr_step(input apu_vgpu_gbr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gbr_rdy) @(negedge clk);
    cases++;
    n0 = nd;
    dbase = nd;
    gbr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbr_req = 1'b0;
    while (!gbr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gbr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GBR_OK) begin
      check("readback", gbr.valid && gbr.word == gbw.word &&
            gbr.first == APU_VGPU_GBW_ADDR && gbr.last == APU_VGPU_GBW_TAIL &&
            gbr.first != gbr.last);
      check("read count", nd == n0 + 2 && !d_order && rd0 == gbr.first &&
            rd1 == gbr.last);
    end else if (name == "bad beat" || name == "bad tail") begin
      check("stopped", nd == n0 + (name == "bad beat" ? 1 : 2) && !gbr.valid);
    end else check("no read", nd == n0);
    @(negedge clk);
    check($sformatf("%s held", name), gbr_cpl_v);
    gbr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbr_cpl_r = 1'b0;
    while (gbr_cpl_v) @(negedge clk);
  endtask

  task automatic gbk_step(input apu_vgpu_gbk_status_e st, input string name);
    @(negedge clk);
    while (!gbk_rdy) @(negedge clk);
    cases++;
    gbk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbk_req = 1'b0;
    while (!gbk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gbk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gbk_cpl_v);
    gbk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbk_cpl_r = 1'b0;
    while (gbk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    gbw_req = 1'b0;
    gbr_req = 1'b0;
    gbk_req = 1'b0;
    gbw_cpl_r = 1'b0;
    gbr_cpl_r = 1'b0;
    gbk_cpl_r = 1'b0;
    srd_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    wfr = '0;
    wfk = '0;
    gpk = '0;
    cwr = '0;
    cxr = '0;
    vak = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          gbw == '0 && gbr == '0 && gbk == '0);
    check("profiles keep the copy off",
          !ApuOff.GbwEn && !ApuOff.GbrEn && !ApuOff.GbkEn &&
          !ApuP1Transport.GbwEn && !ApuP1Transport.GbrEn && !ApuP1Transport.GbkEn &&
          !ApuHarness.GbwEn && !ApuHarness.GbrEn && !ApuHarness.GbkEn &&
          !ApuSchedBoth.GbwEn && !ApuSchedBoth.GbrEn && !ApuSchedBoth.GbkEn &&
          !ApuBadVirglGrant.GbwEn && !ApuBadVirglGrant.GbrEn &&
          !ApuBadVirglGrant.GbkEn);
    cfg = ApuP1Transport;
    cfg.GbwEn = 1'b1;
    cfg.GbrEn = 1'b1;
    cfg.GbkEn = 1'b1;
    check("copy does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GbwEn = 1'b1;
    cfg.GbrEn = 1'b1;
    cfg.GbkEn = 1'b1;
    check("copy does not legalize virgl", !apu_cfg_legal(cfg));
    check("copy places",
          APU_VGPU_GBW_ADDR == 64'h88030000 &&
          APU_VGPU_GBW_TAIL == 64'h88033FE0 &&
          APU_VGPU_GBW_ADDR != APU_VGPU_GPW_ADDR &&
          APU_VGPU_GBW_ADDR != 64'h88040000);

    gbr_step(APU_VGPU_GBR_EMPTY, "read empty");
    gbw_step(APU_VGPU_GBW_EMPTY, "copy empty");
    gbk_step(APU_VGPU_GBK_EMPTY, "keep empty");
    good_in();
    wfr = '0;
    gbw_step(APU_VGPU_GBW_EMPTY, "scan missing");
    good_in();
    cxr.height = 16'd64;
    gbw_step(APU_VGPU_GBW_FAULT, "bad scissor");
    good_in();
    bad_src = 1'b1;
    gbw_step(APU_VGPU_GBW_FAULT, "bad source");
    fail_w = 1'b1;
    gbw_step(APU_VGPU_GBW_FAULT, "bad write");
    gbw_step(APU_VGPU_GBW_OK, "copy");
    gbw_step(APU_VGPU_GBW_FAULT, "copy again");
    check("copy stays", gbw.valid && gbw.dst == APU_VGPU_GBW_ADDR &&
          gbw.word == APU_VGPU_CLEAR_WORD);
    fail_d = 1'b1;
    gbr_step(APU_VGPU_GBR_FAULT, "bad beat");
    bad_tail = 1'b1;
    gbr_step(APU_VGPU_GBR_FAULT, "bad tail");
    gbr_step(APU_VGPU_GBR_OK, "read copy");
    gbr_step(APU_VGPU_GBR_FAULT, "read copy again");
    check("read stays", gbr.word == APU_VGPU_CLEAR_WORD &&
          gbr.first != gbr.last);
    gpk.word = 32'h0;
    gbk_step(APU_VGPU_GBK_FAULT, "keep bad word");
    check("keep rejected", !gbk.valid);
    gpk.word = APU_VGPU_CLEAR_WORD;
    gbk_step(APU_VGPU_GBK_OK, "keep copy");
    check("copy kept", gbk.valid && gbk.word == APU_VGPU_CLEAR_WORD &&
          gbk.beats == 16'd512 && gbk.src == APU_VGPU_GPW_ADDR &&
          gbk.dst == APU_VGPU_GBW_ADDR);
    gbk_step(APU_VGPU_GBK_FAULT, "keep again");
    check("keep stays", gbk.word == gbw.word && gbk.dst == gbw.dst);

    pulse_reset();
    check("reset clears", gbw == '0 && gbr == '0 && gbk == '0);
    zero_in();
    gbw_step(APU_VGPU_GBW_EMPTY, "after reset");
    gbr_step(APU_VGPU_GBR_EMPTY, "read after reset");
    gbk_step(APU_VGPU_GBK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu gbw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_gbw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
