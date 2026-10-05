// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_sav;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sny_t sny;
  logic sav_req = 0, sav_rdy, sav_cpl_v, sav_cpl_r = 0;
  apu_vgpu_sav_cpl_t sav_cpl;
  apu_vgpu_sav_t sav;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic sak_req = 0, sak_rdy, sak_cpl_v, sak_cpl_r = 0;
  apu_vgpu_sak_cpl_t sak_cpl;
  apu_vgpu_sak_t sak;
  logic sax_req = 0, sax_rdy, sax_cpl_v, sax_cpl_r = 0;
  apu_vgpu_sax_cpl_t sax_cpl, off_cpl;
  apu_vgpu_sax_t sax, off_sax;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_idx = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QAV_SCENE};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_sav #(.Enable(1'b1)) i_sav (
    .clk_i(clk), .rst_ni, .sny_i(sny),
    .req_valid_i(sav_req), .req_ready_o(sav_rdy),
    .cpl_valid_o(sav_cpl_v), .cpl_ready_i(sav_cpl_r), .cpl_o(sav_cpl), .sav_o(sav),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_sak #(.Enable(1'b1)) i_sak (
    .clk_i(clk), .rst_ni, .sav_i(sav), .sny_i(sny),
    .req_valid_i(sak_req), .req_ready_o(sak_rdy),
    .cpl_valid_o(sak_cpl_v), .cpl_ready_i(sak_cpl_r), .cpl_o(sak_cpl), .sak_o(sak)
  );
  g6lc_apu_vgpu_sax #(.Enable(1'b1)) i_sax (
    .clk_i(clk), .rst_ni, .sak_i(sak), .sav_i(sav), .sny_i(sny),
    .req_valid_i(sax_req), .req_ready_o(sax_rdy),
    .cpl_valid_o(sax_cpl_v), .cpl_ready_i(sax_cpl_r), .cpl_o(sax_cpl), .sax_o(sax)
  );
  g6lc_apu_vgpu_sax_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sak_i(sak), .sav_i(sav), .sny_i(sny),
    .req_valid_i(sax_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sax_cpl_r), .cpl_o(off_cpl), .sax_o(off_sax)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu sav timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_idx) beat[31:0] = APU_VGPU_QAV_WORD;
      if (rd_addr != APU_VGPU_SAV_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_idx <= 1'b0;
      nread <= nread + 1;
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
    sny = '0;
    sny.valid = 1'b1;
    sny.qid = APU_VGPU_QNT_QUEUE;
    sny.avail_idx = APU_VGPU_QSU_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_sax == '0 &&
          off_cpl == '0);
  endtask

  task automatic sav_step(input apu_vgpu_sav_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!sav_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    sav_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sav_req = 1'b0;
    while (!sav_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sav_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SAV_OK) begin
      check("avail idx", sav.valid && sav.avail_idx == 16'd1 &&
            sav.avail_idx != 16'd2 &&
            sav.addr == APU_VGPU_SAV_ADDR &&
            sav.addr != APU_VGPU_QAV_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_SAV_ADDR && rd_seen != APU_VGPU_QAV_ADDR);
    end else if (name == "bad beat" || name == "xfer word") begin
      check("one read failed", nread == n0 + 1 && !sav.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), sav_cpl_v);
    sav_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sav_cpl_r = 1'b0;
    while (sav_cpl_v) @(negedge clk);
  endtask

  task automatic sak_step(input apu_vgpu_sak_status_e st, input string name);
    @(negedge clk);
    while (!sak_rdy) @(negedge clk);
    cases++;
    sak_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sak_req = 1'b0;
    while (!sak_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sak_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), sak_cpl_v);
    sak_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sak_cpl_r = 1'b0;
    while (sak_cpl_v) @(negedge clk);
  endtask

  task automatic sax_step(input apu_vgpu_sax_status_e st, input string name);
    @(negedge clk);
    while (!sax_rdy) @(negedge clk);
    cases++;
    sax_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sax_req = 1'b0;
    while (!sax_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sax_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), sax_cpl_v);
    sax_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sax_cpl_r = 1'b0;
    while (sax_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    sav_req = 1'b0;
    sak_req = 1'b0;
    sax_req = 1'b0;
    sav_cpl_r = 1'b0;
    sak_cpl_r = 1'b0;
    sax_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    sny = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          sav == '0 && sak == '0 && sax == '0);
    check("profiles keep the avail peek off",
          !ApuOff.SavEn && !ApuOff.SakEn && !ApuOff.SaxEn &&
          !ApuP1Transport.SavEn && !ApuP1Transport.SakEn &&
          !ApuP1Transport.SaxEn &&
          !ApuHarness.SavEn && !ApuHarness.SakEn && !ApuHarness.SaxEn &&
          !ApuSchedBoth.SavEn && !ApuSchedBoth.SakEn && !ApuSchedBoth.SaxEn &&
          !ApuBadVirglGrant.SavEn && !ApuBadVirglGrant.SakEn &&
          !ApuBadVirglGrant.SaxEn);
    cfg = ApuP1Transport;
    cfg.SavEn = 1'b1;
    cfg.SakEn = 1'b1;
    cfg.SaxEn = 1'b1;
    check("avail peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SavEn = 1'b1;
    cfg.SakEn = 1'b1;
    cfg.SaxEn = 1'b1;
    check("avail peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("avail places",
          APU_VGPU_SAV_ADDR == 64'h8800E200 &&
          APU_VGPU_SAV_ADDR == APU_VGPU_NXC_AVAIL &&
          APU_VGPU_SAV_ADDR != APU_VGPU_QAV_ADDR &&
          APU_VGPU_QAV_SCENE == 32'h00010000 &&
          APU_VGPU_QAV_WORD == 32'h00020000);

    sav_step(APU_VGPU_SAV_EMPTY, "read empty");
    sak_step(APU_VGPU_SAK_EMPTY, "keep empty");
    sax_step(APU_VGPU_SAX_EMPTY, "check empty");
    good_in();
    sny.qid = APU_VGPU_QNT_CURSOR;
    sav_step(APU_VGPU_SAV_FAULT, "cursor queue");
    sny.qid = APU_VGPU_QNT_QUEUE;
    sny.avail_idx = APU_VGPU_TUW_IDXV;
    sav_step(APU_VGPU_SAV_FAULT, "xfer index");
    good_in();
    fail_rd = 1'b1;
    sav_step(APU_VGPU_SAV_FAULT, "bad beat");
    bad_idx = 1'b1;
    sav_step(APU_VGPU_SAV_FAULT, "xfer word");
    sav_step(APU_VGPU_SAV_OK, "avail idx");
    sav_step(APU_VGPU_SAV_FAULT, "avail again");
    check("avail stays", sav.valid && sav.avail_idx == 16'd1 &&
          sav.addr == APU_VGPU_SAV_ADDR);
    sny.avail_idx = APU_VGPU_TUW_IDXV;
    sak_step(APU_VGPU_SAK_FAULT, "keep xfer index");
    check("keep rejected", !sak.valid);
    good_in();
    sak_step(APU_VGPU_SAK_OK, "keep idx");
    check("idx kept", sak.valid && sak.avail_idx == 16'd1 &&
          sak.addr == APU_VGPU_SAV_ADDR);
    sak_step(APU_VGPU_SAK_FAULT, "keep again");
    sny.qid = APU_VGPU_QNT_CURSOR;
    sax_step(APU_VGPU_SAX_FAULT, "check cursor");
    check("check rejected", !sax.valid);
    good_in();
    sax_step(APU_VGPU_SAX_OK, "check idx");
    check("idx checked", sax.valid && sax.avail_idx == 16'd1);
    sax_step(APU_VGPU_SAX_FAULT, "check again");
    check("check stays", sax.avail_idx == sav.avail_idx);

    pulse_reset();
    check("reset clears", sav == '0 && sak == '0 && sax == '0);
    sny = '0;
    sav_step(APU_VGPU_SAV_EMPTY, "after reset");
    good_in();
    sav_step(APU_VGPU_SAV_OK, "avail after reset");

    if (errors != 0) $fatal(1, "APU vgpu sav errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_sav cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
