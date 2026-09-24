// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_lin;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_bcp_t bcp;
  apu_vgpu_sbk_t sbk;
  apu_vgpu_tbn_t tbn;
  apu_vgpu_ss_t ss;
  apu_vgpu_pxc_t pxc;
  logic [15:0] lx, ly;
  logic lin_req = 0, lin_rdy, lin_cpl_v, lin_cpl_r = 0;
  apu_vgpu_lin_cpl_t lin_cpl;
  apu_vgpu_lin_t lin;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic lnr_req = 0, lnr_rdy, lnr_cpl_v, lnr_cpl_r = 0;
  apu_vgpu_lnr_cpl_t lnr_cpl, off_cpl;
  apu_vgpu_lnr_t lnr, off_lnr;
  logic off_rdy, off_v;
  logic fail_next = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [31:0] Word0 = 32'hA500_0000;
  localparam logic [31:0] Word1 = 32'hFF00_FF00;
  localparam logic [31:0] Half01 = 32'hD200_8000;
  localparam logic [31:0] Word6 = 32'h1122_3344;
  localparam logic [31:0] Word7 = 32'h5566_7788;
  localparam logic [31:0] Half67 = 32'h3344_5566;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_lin #(.Enable(1'b1)) i_lin (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .pxc_i(pxc), .x_i(lx), .y_i(ly),
    .req_valid_i(lin_req), .req_ready_o(lin_rdy),
    .cpl_valid_o(lin_cpl_v), .cpl_ready_i(lin_cpl_r), .cpl_o(lin_cpl), .lin_o(lin),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_lnr #(.Enable(1'b1)) i_lnr (
    .clk_i(clk), .rst_ni, .lin_i(lin), .bcp_i(bcp), .pxc_i(pxc),
    .req_valid_i(lnr_req), .req_ready_o(lnr_rdy),
    .cpl_valid_o(lnr_cpl_v), .cpl_ready_i(lnr_cpl_r), .cpl_o(lnr_cpl), .lnr_o(lnr)
  );
  g6lc_apu_vgpu_lnr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .lin_i(lin), .bcp_i(bcp), .pxc_i(pxc),
    .req_valid_i(lnr_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(lnr_cpl_r), .cpl_o(off_cpl), .lnr_o(off_lnr)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu lin timeout case=%0d", cases); end

  function automatic logic [255:0] beat0;
    beat0 = {Word7, Word6, 32'h0404_0404, 32'h0303_0303,
             32'h0202_0202, 32'h0101_0101, Word1, Word0};
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) rsp_v <= 1'b0;
    else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat0();
      rsp_ok <= !(fail_next && rd_addr == {32'h0, StandIn});
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
    pxc = '0;
    pxc.valid = 1'b1;
    pxc.word = Word0;
  endtask

  task automatic lin_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_lin_status_e st,
    input logic [31:0] word,
    input string name
  );
    @(negedge clk);
    while (!lin_rdy) @(negedge clk);
    cases++;
    lx = x;
    ly = y;
    lin_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    lin_req = 1'b0;
    while (!lin_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), lin_cpl.status == st);
    if (st == APU_VGPU_LIN_OK)
      check($sformatf("%s word", name), lin.valid && lin.x == x[2:0] &&
            lin.word == word);
    @(negedge clk);
    check($sformatf("%s held", name), lin_cpl_v);
    lin_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    lin_cpl_r = 1'b0;
    while (lin_cpl_v) @(negedge clk);
  endtask

  task automatic lnr_step(input apu_vgpu_lnr_status_e st, input string name);
    @(negedge clk);
    while (!lnr_rdy) @(negedge clk);
    cases++;
    lnr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    lnr_req = 1'b0;
    while (!lnr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), lnr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_lnr == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), lnr_cpl_v);
    lnr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    lnr_cpl_r = 1'b0;
    while (lnr_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    lin_req = 1'b0;
    lnr_req = 1'b0;
    lin_cpl_r = 1'b0;
    lnr_cpl_r = 1'b0;
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
    pxc = '0;
    lx = '0;
    ly = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && lin == '0 && lnr == '0);
    check("profiles keep blend off",
          !ApuOff.LinEn && !ApuOff.LnrEn &&
          !ApuP1Transport.LinEn && !ApuP1Transport.LnrEn &&
          !ApuHarness.LinEn && !ApuHarness.LnrEn &&
          !ApuSchedBoth.LinEn && !ApuSchedBoth.LnrEn &&
          !ApuBadVirglGrant.LinEn && !ApuBadVirglGrant.LnrEn);
    cfg = ApuP1Transport;
    cfg.LinEn = 1'b1;
    cfg.LnrEn = 1'b1;
    check("blend does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.LinEn = 1'b1;
    cfg.LnrEn = 1'b1;
    check("blend does not legalize virgl", !apu_cfg_legal(cfg));
    check("half words", Half01 == 32'hD2008000 && Half67 == 32'h33445566);

    lin_step(16'd0, 16'd0, APU_VGPU_LIN_EMPTY, 32'h0, "lin empty");
    good_rec();
    lin_step(16'd0, 16'd1, APU_VGPU_LIN_FAULT, 32'h0, "next row");
    check("row keeps", !lin.valid);
    lin_step(16'd8, 16'd0, APU_VGPU_LIN_FAULT, 32'h0, "next beat");
    fail_next = 1'b1;
    lin_step(16'd0, 16'd0, APU_VGPU_LIN_FAULT, 32'h0, "bad beat");
    check("beat keeps", !lin.valid);
    lin_step(16'd0, 16'd0, APU_VGPU_LIN_OK, Word0, "origin");
    lnr_step(APU_VGPU_LNR_OK, "keep origin");
    check("origin kept", !lnr.valid && lnr.origin == Word0);
    lin_step(16'd1, 16'd0, APU_VGPU_LIN_OK, Half01, "neighbor");
    lnr_step(APU_VGPU_LNR_OK, "keep neighbor");
    check("pair", lnr.valid && lnr.origin == Word0 && lnr.neighbor == Half01 &&
          lnr.neighbor != 32'hFF1A0D0D);
    lnr_step(APU_VGPU_LNR_FAULT, "pair again");
    check("pair stays", lnr.origin == Word0 && lnr.neighbor == Half01);
    lin_step(16'd7, 16'd0, APU_VGPU_LIN_OK, Half67, "far tap");
    check("origin stays", lnr.origin == Word0 && lnr.neighbor == Half01);

    pulse_reset();
    check("reset clears", lin == '0 && lnr == '0);
    lnr_step(APU_VGPU_LNR_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu lin errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_lin cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
