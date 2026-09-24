// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_vbx;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_bcp_t bcp;
  apu_vgpu_sbk_t sbk;
  apu_vgpu_tbn_t tbn;
  apu_vgpu_ss_t ss;
  apu_vgpu_lnr_t lnr;
  apu_vgpu_spx_t spx;
  apu_vgpu_vlr_t vlr_in;
  logic [15:0] vx, vy;
  logic vbx_req = 0, vbx_rdy, vbx_cpl_v, vbx_cpl_r = 0;
  apu_vgpu_vbx_cpl_t vbx_cpl;
  apu_vgpu_vbx_t vbx;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, prev_addr = 0, last_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic vbr_req = 0, vbr_rdy, vbr_cpl_v, vbr_cpl_r = 0;
  apu_vgpu_vbr_cpl_t vbr_cpl, off_cpl;
  apu_vgpu_vbr_t vbr, off_vbr;
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
  localparam logic [31:0] At2 = 32'h4202_4203;
  localparam logic [31:0] At7 = 32'h1A22_2B33;
  localparam logic [63:0] BaseAddr = 64'h0000_0000_8800_F000;
  localparam logic [63:0] RowAddr = 64'h0000_0000_8800_FA00;
  localparam logic [255:0] Row0Beat = {
    32'h5566_7788, 32'h1122_3344, 32'h0404_0404, 32'h0303_0303,
    32'h0202_0202, 32'h0101_0101, 32'hFF00_FF00, 32'hA500_0000
  };

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_vbx #(.Enable(1'b1)) i_vbx (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .lnr_i(lnr), .spx_i(spx), .vlr_i(vlr_in), .x_i(vx), .y_i(vy),
    .req_valid_i(vbx_req), .req_ready_o(vbx_rdy),
    .cpl_valid_o(vbx_cpl_v), .cpl_ready_i(vbx_cpl_r), .cpl_o(vbx_cpl), .vbx_o(vbx),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_vbr #(.Enable(1'b1)) i_vbr (
    .clk_i(clk), .rst_ni, .vbx_i(vbx), .vlr_i(vlr_in),
    .req_valid_i(vbr_req), .req_ready_o(vbr_rdy),
    .cpl_valid_o(vbr_cpl_v), .cpl_ready_i(vbr_cpl_r), .cpl_o(vbr_cpl), .vbr_o(vbr)
  );
  g6lc_apu_vgpu_vbr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .vbx_i(vbx), .vlr_i(vlr_in),
    .req_valid_i(vbr_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(vbr_cpl_r), .cpl_o(off_cpl), .vbr_o(off_vbr)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu vbx timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      prev_addr <= '0;
      last_addr <= '0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      prev_addr <= last_addr;
      last_addr <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      if (rd_addr == BaseAddr) rsp_data <= Row0Beat;
      else rsp_data <= {192'b0, Row11, Row10};
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
    vlr_in = '0;
    vlr_in.valid = 1'b1;
    vlr_in.at0 = At0;
    vlr_in.at1 = At1;
  endtask

  task automatic vbx_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_vbx_status_e st,
    input logic [31:0] word,
    input int beats,
    input string name
  );
    logic [63:0] held;
    @(negedge clk);
    while (!vbx_rdy) @(negedge clk);
    cases++;
    held = last_addr;
    vx = x;
    vy = y;
    vbx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vbx_req = 1'b0;
    while (!vbx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vbx_cpl.status == st);
    if (st == APU_VGPU_VBX_OK) begin
      check($sformatf("%s word", name), vbx.valid && vbx.x == x[2:0] &&
            vbx.word == word);
      check($sformatf("%s rows", name), prev_addr == BaseAddr &&
            last_addr == RowAddr && rd_addr == RowAddr);
    end else if (beats == 0) begin
      check($sformatf("%s no read", name), last_addr == held);
    end else begin
      check($sformatf("%s one beat", name), last_addr == BaseAddr);
    end
    @(negedge clk);
    check($sformatf("%s held", name), vbx_cpl_v);
    vbx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vbx_cpl_r = 1'b0;
    while (vbx_cpl_v) @(negedge clk);
  endtask

  task automatic vbr_step(input apu_vgpu_vbr_status_e st, input string name);
    @(negedge clk);
    while (!vbr_rdy) @(negedge clk);
    cases++;
    vbr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vbr_req = 1'b0;
    while (!vbr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vbr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vbr == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), vbr_cpl_v);
    vbr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vbr_cpl_r = 1'b0;
    while (vbr_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    vbx_req = 1'b0;
    vbr_req = 1'b0;
    vbx_cpl_r = 1'b0;
    vbr_cpl_r = 1'b0;
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
    vlr_in = '0;
    vx = '0;
    vy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && vbx == '0 && vbr == '0);
    check("profiles keep the row blend off",
          !ApuOff.VbxEn && !ApuOff.VbrEn &&
          !ApuP1Transport.VbxEn && !ApuP1Transport.VbrEn &&
          !ApuHarness.VbxEn && !ApuHarness.VbrEn &&
          !ApuSchedBoth.VbxEn && !ApuSchedBoth.VbrEn &&
          !ApuBadVirglGrant.VbxEn && !ApuBadVirglGrant.VbrEn);
    cfg = ApuP1Transport;
    cfg.VbxEn = 1'b1;
    cfg.VbrEn = 1'b1;
    check("row blend does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VbxEn = 1'b1;
    cfg.VbrEn = 1'b1;
    check("row blend does not legalize virgl", !apu_cfg_legal(cfg));
    check("row bytes", APU_VGPU_SCAN_ROW_BYTES == 32'd2560);
    check("known words", At0 == 32'h53010202 && At1 == 32'h6B024303 &&
          At2 == 32'h42024203 && At7 == 32'h1A222B33);

    vbx_step(16'd0, 16'd1, APU_VGPU_VBX_EMPTY, 32'h0, 0, "vbx empty");
    good_rec();
    vbx_step(16'd0, 16'd0, APU_VGPU_VBX_FAULT, 32'h0, 0, "row 0");
    vbx_step(16'd0, 16'd2, APU_VGPU_VBX_FAULT, 32'h0, 0, "row 2");
    vbx_step(16'd8, 16'd1, APU_VGPU_VBX_FAULT, 32'h0, 0, "x 8");
    fail_next = 1'b1;
    vbx_step(16'd0, 16'd1, APU_VGPU_VBX_FAULT, 32'h0, 1, "bad beat");
    check("beat keeps", !vbx.valid);
    vbx_step(16'd0, 16'd1, APU_VGPU_VBX_OK, At0, 2, "column 0");
    check("column 0 matches the pair", vbx.word == vlr_in.at0);
    vbx_step(16'd1, 16'd1, APU_VGPU_VBX_OK, At1, 2, "column 1");
    check("column 1 matches the pair", vbx.word == vlr_in.at1);
    vbx_step(16'd2, 16'd1, APU_VGPU_VBX_OK, At2, 2, "column 2");
    vbr_step(APU_VGPU_VBR_OK, "keep column 2");
    check("column 2 kept", vbr.valid && vbr.word == At2);
    vbx_step(16'd7, 16'd1, APU_VGPU_VBX_OK, At7, 2, "column 7");
    check("column 2 stays", vbr.word == At2 && lnr.origin == Word0 &&
          vlr_in.at0 == At0 && vlr_in.at1 == At1);
    vbr_step(APU_VGPU_VBR_FAULT, "column 2 again");
    check("store stays", vbr.word == At2 && vbx.word == At7);

    pulse_reset();
    check("reset clears", vbx == '0 && vbr == '0);
    vbr_step(APU_VGPU_VBR_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu vbx errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_vbx cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
