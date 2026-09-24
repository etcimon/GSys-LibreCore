// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_vln;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_bcp_t bcp;
  apu_vgpu_sbk_t sbk;
  apu_vgpu_tbn_t tbn;
  apu_vgpu_ss_t ss;
  apu_vgpu_lnr_t lnr;
  apu_vgpu_spx_t spx;
  logic [15:0] vx, vy;
  logic vln_req = 0, vln_rdy, vln_cpl_v, vln_cpl_r = 0;
  apu_vgpu_vln_cpl_t vln_cpl;
  apu_vgpu_vln_t vln;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic vlr_req = 0, vlr_rdy, vlr_cpl_v, vlr_cpl_r = 0;
  apu_vgpu_vlr_cpl_t vlr_cpl, off_cpl;
  apu_vgpu_vlr_t vlr, off_vlr;
  logic off_rdy, off_v;
  logic fail_next = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [31:0] Word0 = 32'hA500_0000;
  localparam logic [31:0] Half01 = 32'hD200_8000;
  localparam logic [31:0] Row10 = 32'h0102_0304;
  localparam logic [31:0] Row11 = 32'h0506_0708;
  localparam logic [31:0] At0 = 32'h5301_0202;
  localparam logic [31:0] At1 = 32'h6B02_4303;
  localparam logic [63:0] RowAddr = 64'h0000_0000_8800_FA00;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_vln #(.Enable(1'b1)) i_vln (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .lnr_i(lnr), .spx_i(spx), .x_i(vx), .y_i(vy),
    .req_valid_i(vln_req), .req_ready_o(vln_rdy),
    .cpl_valid_o(vln_cpl_v), .cpl_ready_i(vln_cpl_r), .cpl_o(vln_cpl), .vln_o(vln),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_vlr #(.Enable(1'b1)) i_vlr (
    .clk_i(clk), .rst_ni, .vln_i(vln), .lnr_i(lnr),
    .req_valid_i(vlr_req), .req_ready_o(vlr_rdy),
    .cpl_valid_o(vlr_cpl_v), .cpl_ready_i(vlr_cpl_r), .cpl_o(vlr_cpl), .vlr_o(vlr)
  );
  g6lc_apu_vgpu_vlr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .vln_i(vln), .lnr_i(lnr),
    .req_valid_i(vlr_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(vlr_cpl_r), .cpl_o(off_cpl), .vlr_o(off_vlr)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu vln timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) rsp_v <= 1'b0;
    else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= {192'b0, Row11, Row10};
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
    spx = '0;
    spx.valid = 1'b1;
    spx.word = 32'h8091_A2B3;
  endtask

  task automatic vln_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_vln_status_e st,
    input logic [31:0] word,
    input string name
  );
    @(negedge clk);
    while (!vln_rdy) @(negedge clk);
    cases++;
    vx = x;
    vy = y;
    vln_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vln_req = 1'b0;
    while (!vln_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vln_cpl.status == st);
    if (st == APU_VGPU_VLN_OK) begin
      check($sformatf("%s word", name), vln.valid && vln.x == x[1:0] &&
            vln.word == word);
      check($sformatf("%s addr", name), rd_addr == RowAddr);
    end
    @(negedge clk);
    check($sformatf("%s held", name), vln_cpl_v);
    vln_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vln_cpl_r = 1'b0;
    while (vln_cpl_v) @(negedge clk);
  endtask

  task automatic vlr_step(input apu_vgpu_vlr_status_e st, input string name);
    @(negedge clk);
    while (!vlr_rdy) @(negedge clk);
    cases++;
    vlr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vlr_req = 1'b0;
    while (!vlr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vlr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vlr == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), vlr_cpl_v);
    vlr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vlr_cpl_r = 1'b0;
    while (vlr_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    vln_req = 1'b0;
    vlr_req = 1'b0;
    vln_cpl_r = 1'b0;
    vlr_cpl_r = 1'b0;
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
    spx = '0;
    vx = '0;
    vy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && vln == '0 && vlr == '0);
    check("profiles keep vertical off",
          !ApuOff.VlnEn && !ApuOff.VlrEn &&
          !ApuP1Transport.VlnEn && !ApuP1Transport.VlrEn &&
          !ApuHarness.VlnEn && !ApuHarness.VlrEn &&
          !ApuSchedBoth.VlnEn && !ApuSchedBoth.VlrEn &&
          !ApuBadVirglGrant.VlnEn && !ApuBadVirglGrant.VlrEn);
    cfg = ApuP1Transport;
    cfg.VlnEn = 1'b1;
    cfg.VlrEn = 1'b1;
    check("vertical does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VlnEn = 1'b1;
    cfg.VlrEn = 1'b1;
    check("vertical does not legalize virgl", !apu_cfg_legal(cfg));
    check("row bytes", APU_VGPU_SCAN_ROW_BYTES == 32'd2560);
    check("vertical words", At0 == 32'h53010202 && At1 == 32'h6B024303);

    vln_step(16'd0, 16'd1, APU_VGPU_VLN_EMPTY, 32'h0, "vln empty");
    good_rec();
    vln_step(16'd0, 16'd0, APU_VGPU_VLN_FAULT, 32'h0, "row 0");
    vln_step(16'd0, 16'd2, APU_VGPU_VLN_FAULT, 32'h0, "row 2");
    vln_step(16'd2, 16'd1, APU_VGPU_VLN_FAULT, 32'h0, "x 2");
    fail_next = 1'b1;
    vln_step(16'd0, 16'd1, APU_VGPU_VLN_FAULT, 32'h0, "bad beat");
    check("beat keeps", !vln.valid);
    vln_step(16'd0, 16'd1, APU_VGPU_VLN_OK, At0, "column 0");
    vlr_step(APU_VGPU_VLR_OK, "keep column 0");
    check("column 0 kept", !vlr.valid && vlr.at0 == At0);
    vln_step(16'd1, 16'd1, APU_VGPU_VLN_OK, At1, "column 1");
    vlr_step(APU_VGPU_VLR_OK, "keep column 1");
    check("pair", vlr.valid && vlr.at0 == At0 && vlr.at1 == At1 &&
          vlr.at0 != Word0 && vlr.at1 != Half01);
    vlr_step(APU_VGPU_VLR_FAULT, "pair again");
    check("pair stays", vlr.at0 == At0 && vlr.at1 == At1 &&
          lnr.origin == Word0 && lnr.neighbor == Half01);

    pulse_reset();
    check("reset clears", vln == '0 && vlr == '0);
    vlr_step(APU_VGPU_VLR_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu vln errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_vln cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
