// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_y2b;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_bcp_t bcp;
  apu_vgpu_sbk_t sbk;
  apu_vgpu_tbn_t tbn;
  apu_vgpu_ss_t ss;
  apu_vgpu_lnr_t lnr;
  apu_vgpu_spx_t spx_in;
  apu_vgpu_vlr_t vlr_in;
  apu_vgpu_vbr_t vbr_in;
  apu_vgpu_vsx_t vsx_in;
  logic [15:0] vx, vy;
  logic y2b_req = 0, y2b_rdy, y2b_cpl_v, y2b_cpl_r = 0;
  apu_vgpu_y2b_cpl_t y2b_cpl;
  apu_vgpu_y2b_t y2b;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [63:0] a0 = 0, a1 = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic y2r_req = 0, y2r_rdy, y2r_cpl_v, y2r_cpl_r = 0;
  apu_vgpu_y2r_cpl_t y2r_cpl, off_cpl;
  apu_vgpu_y2r_t y2r, off_y2r;
  logic off_rdy, off_v;
  logic fail_next = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nseen = 0;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [31:0] Word0 = 32'hA500_0000;
  localparam logic [31:0] Half01 = 32'hD200_8000;
  localparam logic [31:0] Span = 32'h8091_A2B3;
  localparam logic [31:0] At8 = 32'h434C_545D;
  localparam logic [31:0] Row10 = 32'h0102_0304;
  localparam logic [31:0] Row11 = 32'h0506_0708;
  localparam logic [31:0] At0 = 32'h5301_0202;
  localparam logic [31:0] At1 = 32'h6B02_4303;
  localparam logic [31:0] At2 = 32'h4202_4203;
  localparam logic [31:0] Y0 = 32'h7979_7A7A;
  localparam logic [31:0] Y1 = 32'h4242_4343;
  localparam logic [31:0] Y7 = 32'h3C3C_3C3C;
  localparam logic [63:0] RowAddr = 64'h0000_0000_8800_FA00;
  localparam logic [63:0] Row2Addr = 64'h0000_0000_8801_0400;
  localparam logic [255:0] Row2Beat = {
    32'h5050_5050, 32'hA0A0_A0A0, 32'h0, 32'h0, 32'h0, 32'h0,
    32'h0F0F_0F0F, 32'hF0F0_F0F0
  };

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_y2b #(.Enable(1'b1)) i_y2b (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .lnr_i(lnr), .spx_i(spx_in), .vlr_i(vlr_in), .vbr_i(vbr_in), .vsx_i(vsx_in),
    .x_i(vx), .y_i(vy),
    .req_valid_i(y2b_req), .req_ready_o(y2b_rdy),
    .cpl_valid_o(y2b_cpl_v), .cpl_ready_i(y2b_cpl_r), .cpl_o(y2b_cpl), .y2b_o(y2b),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_y2r #(.Enable(1'b1)) i_y2r (
    .clk_i(clk), .rst_ni, .y2b_i(y2b), .vlr_i(vlr_in), .vsx_i(vsx_in),
    .req_valid_i(y2r_req), .req_ready_o(y2r_rdy),
    .cpl_valid_o(y2r_cpl_v), .cpl_ready_i(y2r_cpl_r), .cpl_o(y2r_cpl), .y2r_o(y2r)
  );
  g6lc_apu_vgpu_y2r_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .y2b_i(y2b), .vlr_i(vlr_in), .vsx_i(vsx_in),
    .req_valid_i(y2r_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(y2r_cpl_r), .cpl_o(off_cpl), .y2r_o(off_y2r)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu y2b timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      a0 <= '0;
      a1 <= '0;
      nseen <= 0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      a1 <= a0;
      a0 <= rd_addr;
      nseen <= nseen + 1;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      if (rd_addr == RowAddr) rsp_data <= {192'b0, Row11, Row10};
      else rsp_data <= Row2Beat;
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
    spx_in = '0;
    spx_in.valid = 1'b1;
    spx_in.word = Span;
    vlr_in = '0;
    vlr_in.valid = 1'b1;
    vlr_in.at0 = At0;
    vlr_in.at1 = At1;
    vbr_in = '0;
    vbr_in.valid = 1'b1;
    vbr_in.word = At2;
    vsx_in = '0;
    vsx_in.valid = 1'b1;
    vsx_in.word = At8;
  endtask

  task automatic y2b_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_y2b_status_e st,
    input logic [31:0] word,
    input int beats,
    input string name
  );
    int n0;
    @(negedge clk);
    while (!y2b_rdy) @(negedge clk);
    cases++;
    n0 = nseen;
    vx = x;
    vy = y;
    y2b_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    y2b_req = 1'b0;
    while (!y2b_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), y2b_cpl.status == st);
    check($sformatf("%s beats", name), nseen == n0 + beats);
    if (st == APU_VGPU_Y2B_OK) begin
      check($sformatf("%s word", name), y2b.valid && y2b.x == x[2:0] &&
            y2b.word == word);
      check($sformatf("%s addr", name), a1 == RowAddr && a0 == Row2Addr &&
            rd_addr == Row2Addr);
    end else if (beats == 1) begin
      check($sformatf("%s addr", name), a0 == RowAddr);
    end
    @(negedge clk);
    check($sformatf("%s held", name), y2b_cpl_v);
    y2b_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    y2b_cpl_r = 1'b0;
    while (y2b_cpl_v) @(negedge clk);
  endtask

  task automatic y2r_step(input apu_vgpu_y2r_status_e st, input string name);
    @(negedge clk);
    while (!y2r_rdy) @(negedge clk);
    cases++;
    y2r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    y2r_req = 1'b0;
    while (!y2r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), y2r_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_y2r == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), y2r_cpl_v);
    y2r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    y2r_cpl_r = 1'b0;
    while (y2r_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    y2b_req = 1'b0;
    y2r_req = 1'b0;
    y2b_cpl_r = 1'b0;
    y2r_cpl_r = 1'b0;
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
    spx_in = '0;
    vlr_in = '0;
    vbr_in = '0;
    vsx_in = '0;
    vx = '0;
    vy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && y2b == '0 &&
          y2r == '0);
    check("profiles keep row 2 off",
          !ApuOff.Y2bEn && !ApuOff.Y2rEn &&
          !ApuP1Transport.Y2bEn && !ApuP1Transport.Y2rEn &&
          !ApuHarness.Y2bEn && !ApuHarness.Y2rEn &&
          !ApuSchedBoth.Y2bEn && !ApuSchedBoth.Y2rEn &&
          !ApuBadVirglGrant.Y2bEn && !ApuBadVirglGrant.Y2rEn);
    cfg = ApuP1Transport;
    cfg.Y2bEn = 1'b1;
    cfg.Y2rEn = 1'b1;
    check("row 2 does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.Y2bEn = 1'b1;
    cfg.Y2rEn = 1'b1;
    check("row 2 does not legalize virgl", !apu_cfg_legal(cfg));
    check("row 2 words", Y0 == 32'h79797A7A && Y1 == 32'h42424343 &&
          Y7 == 32'h3C3C3C3C && Y0 != At0 && Y1 != At1);
    check("row 2 address", Row2Addr == 64'h8800F000 + 64'd5120);

    y2b_step(16'd0, 16'd2, APU_VGPU_Y2B_EMPTY, 32'h0, 0, "y2b empty");
    good_rec();
    y2b_step(16'd0, 16'd1, APU_VGPU_Y2B_FAULT, 32'h0, 0, "row 1");
    y2b_step(16'd0, 16'd3, APU_VGPU_Y2B_FAULT, 32'h0, 0, "row 3");
    y2b_step(16'd8, 16'd2, APU_VGPU_Y2B_FAULT, 32'h0, 0, "x 8");
    fail_next = 1'b1;
    y2b_step(16'd0, 16'd2, APU_VGPU_Y2B_FAULT, 32'h0, 1, "bad beat");
    check("beat keeps", !y2b.valid);
    y2b_step(16'd0, 16'd2, APU_VGPU_Y2B_OK, Y0, 2, "column 0");
    y2r_step(APU_VGPU_Y2R_OK, "keep column 0");
    check("column 0 kept", !y2r.valid && y2r.at0 == Y0 && y2r.at0 != At0);
    y2b_step(16'd1, 16'd2, APU_VGPU_Y2B_OK, Y1, 2, "column 1");
    y2r_step(APU_VGPU_Y2R_OK, "keep column 1");
    check("pair", y2r.valid && y2r.at0 == Y0 && y2r.at1 == Y1 &&
          y2r.at1 != At1);
    y2b_step(16'd7, 16'd2, APU_VGPU_Y2B_OK, Y7, 2, "column 7");
    check("pair stays", y2r.at0 == Y0 && y2r.at1 == Y1 &&
          vlr_in.at0 == At0 && vsx_in.word == At8);
    y2r_step(APU_VGPU_Y2R_FAULT, "pair again");
    check("store stays", y2r.at0 == Y0 && y2r.at1 == Y1 && y2b.word == Y7);

    pulse_reset();
    check("reset clears", y2b == '0 && y2r == '0);
    y2r_step(APU_VGPU_Y2R_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu y2b errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_y2b cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
