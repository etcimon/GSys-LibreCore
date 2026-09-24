// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tap;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_bcp_t bcp;
  apu_vgpu_sbk_t sbk;
  apu_vgpu_tbn_t tbn;
  apu_vgpu_ss_t ss;
  logic [15:0] tx, ty, qx, qy;
  logic tap_req = 0, tap_rdy, tap_cpl_v, tap_cpl_r = 0;
  apu_vgpu_tap_cpl_t tap_cpl;
  apu_vgpu_tap_t tap;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic pxc_req = 0, pxc_rdy, pxc_cpl_v, pxc_cpl_r = 0;
  apu_vgpu_pxc_cpl_t pxc_cpl;
  apu_vgpu_pxc_t pxc;
  logic pxq_req = 0, pxq_rdy, pxq_cpl_v, pxq_cpl_r = 0;
  apu_vgpu_pxq_cpl_t pxq_cpl, off_cpl;
  logic off_rdy, off_v;
  logic fail_next = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [31:0] Word0 = 32'hA500_0000;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_tap #(.Enable(1'b1)) i_tap (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .x_i(tx), .y_i(ty),
    .req_valid_i(tap_req), .req_ready_o(tap_rdy),
    .cpl_valid_o(tap_cpl_v), .cpl_ready_i(tap_cpl_r), .cpl_o(tap_cpl), .tap_o(tap),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_pxc #(.Enable(1'b1)) i_pxc (
    .clk_i(clk), .rst_ni, .tap_i(tap), .bcp_i(bcp),
    .req_valid_i(pxc_req), .req_ready_o(pxc_rdy),
    .cpl_valid_o(pxc_cpl_v), .cpl_ready_i(pxc_cpl_r), .cpl_o(pxc_cpl), .pxc_o(pxc)
  );
  g6lc_apu_vgpu_pxq #(.Enable(1'b1)) i_pxq (
    .clk_i(clk), .rst_ni, .pxc_i(pxc), .x_i(qx), .y_i(qy),
    .req_valid_i(pxq_req), .req_ready_o(pxq_rdy),
    .cpl_valid_o(pxq_cpl_v), .cpl_ready_i(pxq_cpl_r), .cpl_o(pxq_cpl)
  );
  g6lc_apu_vgpu_pxq_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .pxc_i(pxc), .x_i(qx), .y_i(qy),
    .req_valid_i(pxq_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(pxq_cpl_r), .cpl_o(off_cpl)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu tap timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) rsp_v <= 1'b0;
    else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [63:0] delta;
      delta = rd_addr - {32'h0, StandIn};
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= {224'b0, (Word0 ^ delta[17:5])};
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
  endtask

  task automatic tap_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_tap_status_e st,
    input string name
  );
    @(negedge clk);
    while (!tap_rdy) @(negedge clk);
    cases++;
    tx = x;
    ty = y;
    tap_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tap_req = 1'b0;
    while (!tap_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tap_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), tap_cpl_v);
    tap_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tap_cpl_r = 1'b0;
    while (tap_cpl_v) @(negedge clk);
  endtask

  task automatic pxc_step(input apu_vgpu_pxc_status_e st, input string name);
    @(negedge clk);
    while (!pxc_rdy) @(negedge clk);
    cases++;
    pxc_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pxc_req = 1'b0;
    while (!pxc_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), pxc_cpl.status == st);
    if (st == APU_VGPU_PXC_OK)
      check($sformatf("%s word", name), pxc.valid && pxc.word == Word0);
    @(negedge clk);
    check($sformatf("%s held", name), pxc_cpl_v);
    pxc_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pxc_cpl_r = 1'b0;
    while (pxc_cpl_v) @(negedge clk);
  endtask

  task automatic pxq_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_pxq_status_e st,
    input logic replaced,
    input logic [31:0] word,
    input logic [13:0] addr,
    input string name
  );
    @(negedge clk);
    while (!pxq_rdy) @(negedge clk);
    cases++;
    qx = x;
    qy = y;
    pxq_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pxq_req = 1'b0;
    while (!pxq_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), pxq_cpl.status == st);
    if (st == APU_VGPU_PXQ_OK)
      check($sformatf("%s sample", name), pxq_cpl.replaced == replaced &&
            pxq_cpl.word == word && pxq_cpl.addr == addr);
    else
      check($sformatf("%s quiet", name), !pxq_cpl.replaced && pxq_cpl.word == 32'h0);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), pxq_cpl_v);
    pxq_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pxq_cpl_r = 1'b0;
    while (pxq_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    tap_req = 1'b0;
    pxc_req = 1'b0;
    pxq_req = 1'b0;
    tap_cpl_r = 1'b0;
    pxc_cpl_r = 1'b0;
    pxq_cpl_r = 1'b0;
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
    tx = '0;
    ty = '0;
    qx = '0;
    qy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && tap == '0 && pxc == '0);
    check("profiles keep tap off",
          !ApuOff.TapEn && !ApuOff.PxcEn && !ApuOff.PxqEn &&
          !ApuP1Transport.TapEn && !ApuP1Transport.PxcEn && !ApuP1Transport.PxqEn &&
          !ApuHarness.TapEn && !ApuHarness.PxcEn && !ApuHarness.PxqEn &&
          !ApuSchedBoth.TapEn && !ApuSchedBoth.PxcEn && !ApuSchedBoth.PxqEn &&
          !ApuBadVirglGrant.TapEn && !ApuBadVirglGrant.PxcEn && !ApuBadVirglGrant.PxqEn);
    cfg = ApuP1Transport;
    cfg.TapEn = 1'b1;
    cfg.PxcEn = 1'b1;
    cfg.PxqEn = 1'b1;
    check("tap does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.TapEn = 1'b1;
    cfg.PxcEn = 1'b1;
    cfg.PxqEn = 1'b1;
    check("tap does not legalize virgl", !apu_cfg_legal(cfg));

    tap_step(16'd0, 16'd0, APU_VGPU_TAP_EMPTY, "tap empty");
    good_rec();
    tap_step(16'd0, 16'd64, APU_VGPU_TAP_FAULT, "below band");
    check("below keeps", !tap.valid);
    fail_next = 1'b1;
    tap_step(16'd0, 16'd0, APU_VGPU_TAP_FAULT, "bad beat");
    check("beat keeps", !tap.valid);
    tap_step(16'd0, 16'd0, APU_VGPU_TAP_OK, "corner");
    check("corner texel", tap.valid && tap.x == 10'd0 && tap.y == 6'd0 &&
          tap.word == Word0);
    pxc_step(APU_VGPU_PXC_OK, "paint");
    check("painted", pxc.valid && pxc.word == Word0);
    pxc_step(APU_VGPU_PXC_FAULT, "paint again");
    check("paint stays", pxc.word == Word0);
    pxq_step(16'd0, 16'd0, APU_VGPU_PXQ_OK, 1'b1, Word0, 14'd0, "origin");
    pxq_step(16'd1, 16'd0, APU_VGPU_PXQ_OK, 1'b0, 32'hFF1A0D0D, 14'd4, "neighbor");
    pxq_step(16'd63, 16'd63, APU_VGPU_PXQ_OK, 1'b0, 32'hFF1A0D0D, 14'd16380, "far");
    pxq_step(16'd64, 16'd0, APU_VGPU_PXQ_FAULT, 1'b0, 32'h0, 14'd0, "outside");
    tap_step(16'd640, 16'd0, APU_VGPU_TAP_OK, "clamp");
    check("clamped", tap.valid && tap.x == 10'd639 && tap.y == 6'd0 && tap.word == 32'h0);
    check("origin stays", pxc.word == Word0);
    pxq_step(16'd0, 16'd0, APU_VGPU_PXQ_OK, 1'b1, Word0, 14'd0, "origin again");

    pulse_reset();
    check("reset clears", tap == '0 && pxc == '0);
    pxq_step(16'd0, 16'd0, APU_VGPU_PXQ_EMPTY, 1'b0, 32'h0, 14'd0, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu tap errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tap cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
