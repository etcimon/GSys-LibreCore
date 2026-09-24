// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_smp;
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
  apu_vgpu_y2r_t y2r_in;
  logic [15:0] vx, vy;
  logic smp_req = 0, smp_rdy, smp_cpl_v, smp_cpl_r = 0;
  apu_vgpu_smp_cpl_t smp_cpl;
  apu_vgpu_smp_t smp;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, a0 = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic smx_req = 0, smx_rdy, smx_cpl_v, smx_cpl_r = 0;
  apu_vgpu_smx_cpl_t smx_cpl, off_cpl;
  apu_vgpu_smx_t smx, off_smx;
  logic off_rdy, off_v;
  logic fail_next = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nseen = 0;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [63:0] BaseAddr = 64'h0000_0000_8800_F000;
  localparam logic [31:0] Word0 = 32'hA500_0000;
  localparam logic [31:0] Half01 = 32'hD200_8000;
  localparam logic [31:0] Span = 32'h8091_A2B3;
  localparam logic [31:0] At0 = 32'h5301_0202;
  localparam logic [31:0] At1 = 32'h6B02_4303;
  localparam logic [31:0] At2 = 32'h4202_4203;
  localparam logic [31:0] At8 = 32'h434C_545D;
  localparam logic [31:0] Y0 = 32'h7979_7A7A;
  localparam logic [31:0] Y1 = 32'h4242_4343;
  localparam logic [31:0] AtX9 = 32'h555E_666F;
  localparam logic [31:0] At28 = 32'h1717_1718;
  localparam logic [31:0] At30 = 32'h7878_7878;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_smp #(.Enable(1'b1)) i_smp (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .lnr_i(lnr), .spx_i(spx_in), .vlr_i(vlr_in), .vbr_i(vbr_in), .vsx_i(vsx_in),
    .y2r_i(y2r_in), .x_i(vx), .y_i(vy),
    .req_valid_i(smp_req), .req_ready_o(smp_rdy),
    .cpl_valid_o(smp_cpl_v), .cpl_ready_i(smp_cpl_r), .cpl_o(smp_cpl), .smp_o(smp),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_smx #(.Enable(1'b1)) i_smx (
    .clk_i(clk), .rst_ni, .smp_i(smp), .y2r_i(y2r_in),
    .req_valid_i(smx_req), .req_ready_o(smx_rdy),
    .cpl_valid_o(smx_cpl_v), .cpl_ready_i(smx_cpl_r), .cpl_o(smx_cpl), .smx_o(smx)
  );
  g6lc_apu_vgpu_smx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .smp_i(smp), .y2r_i(y2r_in),
    .req_valid_i(smx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(smx_cpl_r), .cpl_o(off_cpl), .smx_o(off_smx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #8000000; $fatal(1, "APU vgpu smp timeout case=%0d", cases); end

  function automatic logic [31:0] gtexel(
    input logic [5:0] row,
    input logic [5:0] col
  );
    logic [2:0] beat, lane;
    beat = col[5:3];
    lane = col[2:0];
    gtexel = '0;
    if (row == 6'd0 && beat == 3'd0) begin
      case (lane)
        3'd0: gtexel = 32'hA500_0000;
        3'd1: gtexel = 32'hFF00_FF00;
        3'd2: gtexel = 32'h0101_0101;
        3'd3: gtexel = 32'h0202_0202;
        3'd4: gtexel = 32'h0303_0303;
        3'd5: gtexel = 32'h0404_0404;
        3'd6: gtexel = 32'h1122_3344;
        default: gtexel = 32'h5566_7788;
      endcase
    end else if (row == 6'd0 && beat == 3'd1 && lane == 3'd0) begin
      gtexel = 32'hAABB_CCDD;
    end else if (row == 6'd1 && beat == 3'd0 && lane == 3'd0) begin
      gtexel = 32'h0102_0304;
    end else if (row == 6'd1 && beat == 3'd0 && lane == 3'd1) begin
      gtexel = 32'h0506_0708;
    end else if (row == 6'd1 && beat == 3'd1 && lane == 3'd0) begin
      gtexel = 32'h0A0B_0C0D;
    end else if (row == 6'd2 && beat == 3'd0 && lane == 3'd0) begin
      gtexel = 32'hF0F0_F0F0;
    end else if (row == 6'd2 && beat == 3'd0 && lane == 3'd1) begin
      gtexel = 32'h0F0F_0F0F;
    end else if (row == 6'd2 && beat == 3'd0 && lane == 3'd6) begin
      gtexel = 32'hA0A0_A0A0;
    end else if (row == 6'd2 && beat == 3'd0 && lane == 3'd7) begin
      gtexel = 32'h5050_5050;
    end
  endfunction

  function automatic logic [255:0] gbeat(
    input logic [5:0] row,
    input logic [2:0] beat
  );
    gbeat = {gtexel(row, {beat, 3'd7}), gtexel(row, {beat, 3'd6}),
             gtexel(row, {beat, 3'd5}), gtexel(row, {beat, 3'd4}),
             gtexel(row, {beat, 3'd3}), gtexel(row, {beat, 3'd2}),
             gtexel(row, {beat, 3'd1}), gtexel(row, {beat, 3'd0})};
  endfunction

  function automatic logic [7:0] gavg(input logic [7:0] a, input logic [7:0] b);
    gavg = 8'((9'(a) + 9'(b) + 9'd1) >> 1);
  endfunction

  function automatic logic [31:0] gmix(input logic [31:0] a, input logic [31:0] b);
    gmix = {gavg(a[31:24], b[31:24]), gavg(a[23:16], b[23:16]),
            gavg(a[15:8], b[15:8]), gavg(a[7:0], b[7:0])};
  endfunction

  function automatic logic [31:0] ghoriz(
    input logic [5:0] row,
    input logic [5:0] x
  );
    if (x == 6'd0) ghoriz = gtexel(row, 6'd0);
    else ghoriz = gmix(gtexel(row, x - 6'd1), gtexel(row, x));
  endfunction

  function automatic logic [31:0] gsample(
    input logic [5:0] x,
    input logic [5:0] y
  );
    if (y == 6'd0) gsample = ghoriz(6'd0, x);
    else gsample = gmix(ghoriz(y - 6'd1, x), ghoriz(y, x));
  endfunction

  function automatic logic [255:0] gdata(input logic [63:0] addr);
    logic [63:0] off, row64, rem64, beat64;
    off = addr - BaseAddr;
    row64 = off / 64'd2560;
    rem64 = off % 64'd2560;
    beat64 = rem64 / 64'd32;
    if (row64 <= 64'd63 && beat64 <= 64'd7 && rem64 == beat64 * 64'd32)
      gdata = gbeat(row64[5:0], beat64[2:0]);
    else gdata = '0;
  endfunction

  function automatic logic [63:0] gaddr(
    input logic [5:0] row,
    input logic [2:0] beat
  );
    gaddr = BaseAddr + (64'(row) << 11) + (64'(row) << 9) + (64'(beat) << 5);
  endfunction

  function automatic int gbeats(input logic [15:0] x, input logic [15:0] y);
    logic [5:0] ta, tb;
    int nx, ny;
    ta = x == 16'd0 ? 6'd0 : x[5:0] - 6'd1;
    tb = x == 16'd0 ? 6'd0 : x[5:0];
    nx = (x != 16'd0 && ta[5:3] != tb[5:3]) ? 1 : 0;
    ny = y != 16'd0 ? 1 : 0;
    gbeats = (1 + nx) * (1 + ny);
  endfunction

  function automatic logic [63:0] glast(input logic [15:0] x, input logic [15:0] y);
    logic [5:0] ta, tb, row;
    logic [2:0] beat;
    ta = x == 16'd0 ? 6'd0 : x[5:0] - 6'd1;
    tb = x == 16'd0 ? 6'd0 : x[5:0];
    row = y == 16'd0 ? 6'd0 : y[5:0];
    beat = (x != 16'd0 && ta[5:3] != tb[5:3]) ? tb[5:3] : ta[5:3];
    glast = gaddr(row, beat);
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      a0 <= '0;
      nseen <= 0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      a0 <= rd_addr;
      nseen <= nseen + 1;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= gdata(rd_addr);
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
    y2r_in = '0;
    y2r_in.valid = 1'b1;
    y2r_in.at0 = Y0;
    y2r_in.at1 = Y1;
  endtask

  task automatic smp_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_smp_status_e st,
    input logic [31:0] word,
    input int beats,
    input string name
  );
    int n0;
    @(negedge clk);
    while (!smp_rdy) @(negedge clk);
    cases++;
    n0 = nseen;
    vx = x;
    vy = y;
    smp_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    smp_req = 1'b0;
    while (!smp_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), smp_cpl.status == st);
    check($sformatf("%s beats", name), nseen == n0 + beats);
    if (st == APU_VGPU_SMP_OK) begin
      check($sformatf("%s word", name), smp.valid && smp.x == x[5:0] &&
            smp.y == y[5:0] && smp.word == word && a0 == glast(x, y) &&
            rd_addr == glast(x, y));
    end else if (beats == 1) begin
      check($sformatf("%s addr", name), a0 == BaseAddr);
    end
    @(negedge clk);
    check($sformatf("%s held", name), smp_cpl_v);
    smp_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    smp_cpl_r = 1'b0;
    while (smp_cpl_v) @(negedge clk);
  endtask

  task automatic smx_step(input apu_vgpu_smx_status_e st, input string name);
    @(negedge clk);
    while (!smx_rdy) @(negedge clk);
    cases++;
    smx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    smx_req = 1'b0;
    while (!smx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), smx_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_smx == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), smx_cpl_v);
    smx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    smx_cpl_r = 1'b0;
    while (smx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    smp_req = 1'b0;
    smx_req = 1'b0;
    smp_cpl_r = 1'b0;
    smx_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [15:0] gx, gy;
    bcp = '0;
    sbk = '0;
    tbn = '0;
    ss = '0;
    lnr = '0;
    spx_in = '0;
    vlr_in = '0;
    vbr_in = '0;
    vsx_in = '0;
    y2r_in = '0;
    vx = '0;
    vy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && smp == '0 &&
          smx == '0);
    check("profiles keep the ceiling sample off",
          !ApuOff.SmpEn && !ApuOff.SmxEn &&
          !ApuP1Transport.SmpEn && !ApuP1Transport.SmxEn &&
          !ApuHarness.SmpEn && !ApuHarness.SmxEn &&
          !ApuSchedBoth.SmpEn && !ApuSchedBoth.SmxEn &&
          !ApuBadVirglGrant.SmpEn && !ApuBadVirglGrant.SmxEn);
    cfg = ApuP1Transport;
    cfg.SmpEn = 1'b1;
    cfg.SmxEn = 1'b1;
    check("ceiling sample does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.SmpEn = 1'b1;
    cfg.SmxEn = 1'b1;
    check("ceiling sample does not legalize virgl", !apu_cfg_legal(cfg));
    check("golden pins",
          gsample(6'd0, 6'd0) == Word0 && gsample(6'd1, 6'd0) == Half01 &&
          gsample(6'd8, 6'd0) == Span && gsample(6'd0, 6'd1) == At0 &&
          gsample(6'd1, 6'd1) == At1 && gsample(6'd2, 6'd1) == At2 &&
          gsample(6'd8, 6'd1) == At8 && gsample(6'd0, 6'd2) == Y0 &&
          gsample(6'd1, 6'd2) == Y1 && gsample(6'd9, 6'd0) == AtX9 &&
          gsample(6'd8, 6'd2) == At28 && gsample(6'd0, 6'd3) == At30 &&
          gsample(6'd63, 6'd63) == 32'h0);

    smp_step(16'd0, 16'd0, APU_VGPU_SMP_EMPTY, 32'h0, 0, "smp empty");
    good_rec();
    smp_step(16'd0, 16'd64, APU_VGPU_SMP_FAULT, 32'h0, 0, "y 64");
    smp_step(16'd64, 16'd0, APU_VGPU_SMP_FAULT, 32'h0, 0, "x 64");
    fail_next = 1'b1;
    smp_step(16'd0, 16'd0, APU_VGPU_SMP_FAULT, 32'h0, 1, "bad beat");
    check("beat keeps", !smp.valid);
    smp_step(16'd0, 16'd0, APU_VGPU_SMP_OK, Word0, 1, "origin");
    smp_step(16'd1, 16'd0, APU_VGPU_SMP_OK, Half01, 1, "neighbor");
    smp_step(16'd8, 16'd0, APU_VGPU_SMP_OK, Span, 2, "row0 span");
    smp_step(16'd9, 16'd0, APU_VGPU_SMP_OK, AtX9, 1, "row0 x9");
    smp_step(16'd0, 16'd1, APU_VGPU_SMP_OK, At0, 2, "y1 x0");
    smp_step(16'd2, 16'd1, APU_VGPU_SMP_OK, At2, 2, "y1 x2");
    smp_step(16'd8, 16'd1, APU_VGPU_SMP_OK, At8, 4, "y1 span");
    smp_step(16'd0, 16'd2, APU_VGPU_SMP_OK, Y0, 2, "y2 x0");
    smp_step(16'd1, 16'd2, APU_VGPU_SMP_OK, Y1, 2, "y2 x1");
    smp_step(16'd8, 16'd2, APU_VGPU_SMP_OK, At28, 4, "y2 span");
    smp_step(16'd0, 16'd3, APU_VGPU_SMP_OK, At30, 2, "y3 x0");
    smx_step(APU_VGPU_SMX_OK, "keep y3");
    check("y3 kept", smx.valid && smx.word == At30 && smx.word != Y0);
    smp_step(16'd63, 16'd0, APU_VGPU_SMP_OK, 32'h0, 1, "x63");
    smp_step(16'd0, 16'd63, APU_VGPU_SMP_OK, 32'h0, 2, "y63");
    smp_step(16'd63, 16'd63, APU_VGPU_SMP_OK, 32'h0, 2, "corner");
    if (errors == 0) begin
      for (gy = 16'd0; gy < 16'd64 && errors == 0; gy++) begin
        for (gx = 16'd0; gx < 16'd64 && errors == 0; gx++) begin
          smp_step(gx, gy, APU_VGPU_SMP_OK, gsample(gx[5:0], gy[5:0]),
                   gbeats(gx, gy), $sformatf("grid %0d %0d", gx, gy));
        end
      end
    end
    check("store stays", smx.word == At30 && y2r_in.at0 == Y0 &&
          vlr_in.at0 == At0 && vsx_in.word == At8);
    smx_step(APU_VGPU_SMX_FAULT, "y3 again");
    check("store still", smx.word == At30);

    pulse_reset();
    check("reset clears", smp == '0 && smx == '0);
    smx_step(APU_VGPU_SMX_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu smp errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_smp cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
