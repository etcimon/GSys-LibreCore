// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_spn;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_bcp_t bcp;
  apu_vgpu_sbk_t sbk;
  apu_vgpu_tbn_t tbn;
  apu_vgpu_ss_t ss;
  apu_vgpu_lnr_t lnr;
  logic [15:0] sx, sy;
  logic spn_req = 0, spn_rdy, spn_cpl_v, spn_cpl_r = 0;
  apu_vgpu_spn_cpl_t spn_cpl;
  apu_vgpu_spn_t spn;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic spx_req = 0, spx_rdy, spx_cpl_v, spx_cpl_r = 0;
  apu_vgpu_spx_cpl_t spx_cpl, off_cpl;
  apu_vgpu_spx_t spx, off_spx;
  logic off_rdy, off_v;
  logic fail_next = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [31:0] Word0 = 32'hA500_0000;
  localparam logic [31:0] Word1 = 32'hFF00_FF00;
  localparam logic [31:0] Half01 = 32'hD200_8000;
  localparam logic [31:0] Word7 = 32'h5566_7788;
  localparam logic [31:0] Word8 = 32'hAABB_CCDD;
  localparam logic [31:0] Span = 32'h8091_A2B3;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_spn #(.Enable(1'b1)) i_spn (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .lnr_i(lnr), .x_i(sx), .y_i(sy),
    .req_valid_i(spn_req), .req_ready_o(spn_rdy),
    .cpl_valid_o(spn_cpl_v), .cpl_ready_i(spn_cpl_r), .cpl_o(spn_cpl), .spn_o(spn),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_spx #(.Enable(1'b1)) i_spx (
    .clk_i(clk), .rst_ni, .spn_i(spn), .lnr_i(lnr),
    .req_valid_i(spx_req), .req_ready_o(spx_rdy),
    .cpl_valid_o(spx_cpl_v), .cpl_ready_i(spx_cpl_r), .cpl_o(spx_cpl), .spx_o(spx)
  );
  g6lc_apu_vgpu_spx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .spn_i(spn), .lnr_i(lnr),
    .req_valid_i(spx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(spx_cpl_r), .cpl_o(off_cpl), .spx_o(off_spx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu spn timeout case=%0d", cases); end

  function automatic logic [255:0] beat_of(input logic second);
    if (second) beat_of = {224'b0, Word8};
    else beat_of = {Word7, 32'h1122_3344, 32'h0404_0404, 32'h0303_0303,
                    32'h0202_0202, 32'h0101_0101, Word1, Word0};
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) rsp_v <= 1'b0;
    else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_of(rd_addr != {32'h0, StandIn});
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_rec;
    bcp = '0;
    bcp.valid = 1'b1;
    bcp.beats = 13'd5120;
    bcp.bytes = 32'd163840;
    bcp.word = Word0;
    sbk = '0;
    sbk.valid = 1'b1;
    sbk.resource_id = APU_VIRGL_RES_SCAN;
    sbk.addr = StandIn;
    sbk.length = APU_VGPU_SCAN_BYTES;
    tbn = '0;
    tbn.valid = 1'b1;
    tbn.resource_id = APU_VIRGL_RES_SCAN;
    tbn.view = APU_VIRGL_SV_HANDLE;
    tbn.sampler = APU_VIRGL_SS_HANDLE;
    ss = '0;
    ss.valid = 1'b1;
    ss.handle = APU_VIRGL_SS_HANDLE;
    ss.s0 = APU_VIRGL_SSTATE_S0;
    lnr = '0;
    lnr.valid = 1'b1;
    lnr.origin = Word0;
    lnr.neighbor = Half01;
  endtask

  task automatic spn_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_spn_status_e st,
    input logic [31:0] word,
    input string name
  );
    @(negedge clk);
    while (!spn_rdy) @(negedge clk);
    cases++;
    sx = x;
    sy = y;
    spn_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    spn_req = 1'b0;
    while (!spn_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), spn_cpl.status == st);
    if (st == APU_VGPU_SPN_OK)
      check($sformatf("%s word", name), spn.valid && spn.x == x[3:0] &&
            spn.word == word);
    @(negedge clk);
    check($sformatf("%s held", name), spn_cpl_v);
    spn_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    spn_cpl_r = 1'b0;
    while (spn_cpl_v) @(negedge clk);
  endtask

  task automatic spx_step(input apu_vgpu_spx_status_e st, input string name);
    @(negedge clk);
    while (!spx_rdy) @(negedge clk);
    cases++;
    spx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    spx_req = 1'b0;
    while (!spx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), spx_cpl.status == st);
    if (st == APU_VGPU_SPX_OK)
      check($sformatf("%s word", name), spx.valid && spx.word == Span);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_spx == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), spx_cpl_v);
    spx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    spx_cpl_r = 1'b0;
    while (spx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    spn_req = 1'b0;
    spx_req = 1'b0;
    spn_cpl_r = 1'b0;
    spx_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    bcp = '0;
    sbk = '0;
    tbn = '0;
    ss = '0;
    lnr = '0;
    sx = '0;
    sy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && spn == '0 && spx == '0);
    check("profiles keep span off",
          !ApuOff.SpnEn && !ApuOff.SpxEn &&
          !ApuP1Transport.SpnEn && !ApuP1Transport.SpxEn &&
          !ApuHarness.SpnEn && !ApuHarness.SpxEn &&
          !ApuSchedBoth.SpnEn && !ApuSchedBoth.SpxEn &&
          !ApuBadVirglGrant.SpnEn && !ApuBadVirglGrant.SpxEn);
    cfg = ApuP1Transport;
    cfg.SpnEn = 1'b1;
    cfg.SpxEn = 1'b1;
    check("span does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.SpnEn = 1'b1;
    cfg.SpxEn = 1'b1;
    check("span does not legalize virgl", !apu_cfg_legal(cfg));
    check("span word", Span == 32'h8091A2B3);

    spn_step(16'd0, 16'd0, APU_VGPU_SPN_EMPTY, 32'h0, "spn empty");
    good_rec();
    spn_step(16'd0, 16'd1, APU_VGPU_SPN_FAULT, 32'h0, "next row");
    spn_step(16'd16, 16'd0, APU_VGPU_SPN_FAULT, 32'h0, "past two beats");
    fail_next = 1'b1;
    spn_step(16'd0, 16'd0, APU_VGPU_SPN_FAULT, 32'h0, "bad beat");
    check("beat keeps", !spn.valid);
    spn_step(16'd0, 16'd0, APU_VGPU_SPN_OK, Word0, "origin");
    spn_step(16'd1, 16'd0, APU_VGPU_SPN_OK, Half01, "neighbor");
    spn_step(16'd8, 16'd0, APU_VGPU_SPN_OK, Span, "span");
    spx_step(APU_VGPU_SPX_OK, "keep span");
    spx_step(APU_VGPU_SPX_FAULT, "span again");
    check("span stays", spx.word == Span && lnr.origin == Word0 &&
          lnr.neighbor == Half01);
    spn_step(16'd15, 16'd0, APU_VGPU_SPN_OK, 32'h0, "beat one");
    check("span held", spx.word == Span);

    pulse_reset();
    check("reset clears", spn == '0 && spx == '0);
    spx_step(APU_VGPU_SPX_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu spn errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_spn cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
