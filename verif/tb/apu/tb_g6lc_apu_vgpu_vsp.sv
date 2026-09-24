// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_vsp;
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
  logic [15:0] vx, vy;
  logic vsp_req = 0, vsp_rdy, vsp_cpl_v, vsp_cpl_r = 0;
  apu_vgpu_vsp_cpl_t vsp_cpl;
  apu_vgpu_vsp_t vsp;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [63:0] a0 = 0, a1 = 0, a2 = 0, a3 = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic vsx_req = 0, vsx_rdy, vsx_cpl_v, vsx_cpl_r = 0;
  apu_vgpu_vsx_cpl_t vsx_cpl, off_cpl;
  apu_vgpu_vsx_t vsx, off_vsx;
  logic off_rdy, off_v;
  logic fail_next = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nseen = 0;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [31:0] Word0 = 32'hA500_0000;
  localparam logic [31:0] Half01 = 32'hD200_8000;
  localparam logic [31:0] Word7 = 32'h5566_7788;
  localparam logic [31:0] Word8 = 32'hAABB_CCDD;
  localparam logic [31:0] Span = 32'h8091_A2B3;
  localparam logic [31:0] Row10 = 32'h0102_0304;
  localparam logic [31:0] Row11 = 32'h0506_0708;
  localparam logic [31:0] Row18 = 32'h0A0B_0C0D;
  localparam logic [31:0] At0 = 32'h5301_0202;
  localparam logic [31:0] At1 = 32'h6B02_4303;
  localparam logic [31:0] At2 = 32'h4202_4203;
  localparam logic [31:0] At8 = 32'h434C_545D;
  localparam logic [63:0] BaseAddr = 64'h0000_0000_8800_F000;
  localparam logic [63:0] Beat1 = 64'h0000_0000_8800_F020;
  localparam logic [63:0] RowAddr = 64'h0000_0000_8800_FA00;
  localparam logic [63:0] RowBeat = 64'h0000_0000_8800_FA20;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_vsp #(.Enable(1'b1)) i_vsp (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .lnr_i(lnr), .spx_i(spx_in), .vlr_i(vlr_in), .vbr_i(vbr_in),
    .x_i(vx), .y_i(vy),
    .req_valid_i(vsp_req), .req_ready_o(vsp_rdy),
    .cpl_valid_o(vsp_cpl_v), .cpl_ready_i(vsp_cpl_r), .cpl_o(vsp_cpl), .vsp_o(vsp),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_vsx #(.Enable(1'b1)) i_vsx (
    .clk_i(clk), .rst_ni, .vsp_i(vsp), .spx_i(spx_in), .vlr_i(vlr_in),
    .vbr_i(vbr_in),
    .req_valid_i(vsx_req), .req_ready_o(vsx_rdy),
    .cpl_valid_o(vsx_cpl_v), .cpl_ready_i(vsx_cpl_r), .cpl_o(vsx_cpl), .vsx_o(vsx)
  );
  g6lc_apu_vgpu_vsx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .vsp_i(vsp), .spx_i(spx_in), .vlr_i(vlr_in),
    .vbr_i(vbr_in),
    .req_valid_i(vsx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(vsx_cpl_r), .cpl_o(off_cpl), .vsx_o(off_vsx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu vsp timeout case=%0d", cases); end

  function automatic logic [255:0] beat_data(input logic [63:0] addr);
    if (addr == BaseAddr) beat_data = {Word7, 32'h1122_3344, 32'h0404_0404,
      32'h0303_0303, 32'h0202_0202, 32'h0101_0101, 32'hFF00_FF00, Word0};
    else if (addr == Beat1) beat_data = {224'b0, Word8};
    else if (addr == RowAddr) beat_data = {192'b0, Row11, Row10};
    else beat_data = {224'b0, Row18};
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      a0 <= '0;
      a1 <= '0;
      a2 <= '0;
      a3 <= '0;
      nseen <= 0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      a3 <= a2;
      a2 <= a1;
      a1 <= a0;
      a0 <= rd_addr;
      nseen <= nseen + 1;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data(rd_addr);
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
  endtask

  task automatic vsp_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_vsp_status_e st,
    input logic [31:0] word,
    input int beats,
    input string name
  );
    int n0;
    @(negedge clk);
    while (!vsp_rdy) @(negedge clk);
    cases++;
    n0 = nseen;
    vx = x;
    vy = y;
    vsp_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vsp_req = 1'b0;
    while (!vsp_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vsp_cpl.status == st);
    check($sformatf("%s beats", name), nseen == n0 + beats);
    if (st == APU_VGPU_VSP_OK) begin
      check($sformatf("%s word", name), vsp.valid && vsp.x == x[3:0] &&
            vsp.word == word);
      if (beats == 4) begin
        check($sformatf("%s addr", name), a3 == BaseAddr && a2 == Beat1 &&
              a1 == RowAddr && a0 == RowBeat);
      end else if (x == 16'd15) begin
        check($sformatf("%s addr", name), a1 == Beat1 && a0 == RowBeat);
      end else begin
        check($sformatf("%s addr", name), a1 == BaseAddr && a0 == RowAddr);
      end
    end else if (beats == 1) begin
      check($sformatf("%s addr", name), a0 == BaseAddr);
    end
    @(negedge clk);
    check($sformatf("%s held", name), vsp_cpl_v);
    vsp_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vsp_cpl_r = 1'b0;
    while (vsp_cpl_v) @(negedge clk);
  endtask

  task automatic vsx_step(input apu_vgpu_vsx_status_e st, input string name);
    @(negedge clk);
    while (!vsx_rdy) @(negedge clk);
    cases++;
    vsx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vsx_req = 1'b0;
    while (!vsx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vsx_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vsx == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), vsx_cpl_v);
    vsx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vsx_cpl_r = 1'b0;
    while (vsx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    vsp_req = 1'b0;
    vsx_req = 1'b0;
    vsp_cpl_r = 1'b0;
    vsx_cpl_r = 1'b0;
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
    vx = '0;
    vy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && vsp == '0 &&
          vsx == '0);
    check("profiles keep the span off",
          !ApuOff.VspEn && !ApuOff.VsxEn &&
          !ApuP1Transport.VspEn && !ApuP1Transport.VsxEn &&
          !ApuHarness.VspEn && !ApuHarness.VsxEn &&
          !ApuSchedBoth.VspEn && !ApuSchedBoth.VsxEn &&
          !ApuBadVirglGrant.VspEn && !ApuBadVirglGrant.VsxEn);
    cfg = ApuP1Transport;
    cfg.VspEn = 1'b1;
    cfg.VsxEn = 1'b1;
    check("span does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VspEn = 1'b1;
    cfg.VsxEn = 1'b1;
    check("span does not legalize virgl", !apu_cfg_legal(cfg));
    check("span word", At8 == 32'h434C545D && Span == 32'h8091A2B3 &&
          At8 != Span);

    vsp_step(16'd0, 16'd1, APU_VGPU_VSP_EMPTY, 32'h0, 0, "vsp empty");
    good_rec();
    vsp_step(16'd0, 16'd0, APU_VGPU_VSP_FAULT, 32'h0, 0, "row 0");
    vsp_step(16'd0, 16'd2, APU_VGPU_VSP_FAULT, 32'h0, 0, "row 2");
    vsp_step(16'd16, 16'd1, APU_VGPU_VSP_FAULT, 32'h0, 0, "x 16");
    fail_next = 1'b1;
    vsp_step(16'd0, 16'd1, APU_VGPU_VSP_FAULT, 32'h0, 1, "bad beat");
    check("beat keeps", !vsp.valid);
    vsp_step(16'd0, 16'd1, APU_VGPU_VSP_OK, At0, 2, "column 0");
    check("column 0 matches the pair", vsp.word == vlr_in.at0);
    vsp_step(16'd1, 16'd1, APU_VGPU_VSP_OK, At1, 2, "column 1");
    vsp_step(16'd2, 16'd1, APU_VGPU_VSP_OK, At2, 2, "column 2");
    check("column 2 matches the store", vsp.word == vbr_in.word);
    vsp_step(16'd8, 16'd1, APU_VGPU_VSP_OK, At8, 4, "column 8");
    check("column 8 differs from row 0", vsp.word != spx_in.word);
    vsx_step(APU_VGPU_VSX_OK, "keep column 8");
    check("column 8 kept", vsx.valid && vsx.word == At8);
    vsp_step(16'd15, 16'd1, APU_VGPU_VSP_OK, 32'h0, 2, "column 15");
    check("column 8 stays", vsx.word == At8 && vbr_in.word == At2 &&
          vlr_in.at0 == At0 && spx_in.word == Span);
    vsx_step(APU_VGPU_VSX_FAULT, "column 8 again");
    check("store stays", vsx.word == At8 && vsp.word == 32'h0);

    pulse_reset();
    check("reset clears", vsp == '0 && vsx == '0);
    vsx_step(APU_VGPU_VSX_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu vsp errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_vsp cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
