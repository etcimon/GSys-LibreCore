// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rbf;
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
  logic rbf_req = 0, rbf_rdy, rbf_cpl_v, rbf_cpl_r = 0;
  apu_vgpu_rbf_cpl_t rbf_cpl;
  apu_vgpu_rbf_t rbf;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic [255:0] beat0 = 0, beat24 = 0, beat_last = 0;
  logic [63:0] seen_last = 0;
  logic rbk_req = 0, rbk_rdy, rbk_cpl_v, rbk_cpl_r = 0;
  apu_vgpu_rbk_cpl_t rbk_cpl, off_cpl;
  apu_vgpu_rbk_t rbk, off_rbk;
  logic off_rdy, off_v;
  logic fail_rd = 0, fail_wr = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nw = 0, run_base = 0;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [63:0] TexBase = 64'h0000_0000_8800_F000;
  localparam logic [63:0] RbBase = 64'h0000_0000_8804_0000;
  localparam logic [63:0] RbLast = 64'h0000_0000_8804_3FE0;
  localparam logic [63:0] RbY3 = 64'h0000_0000_8804_0300;
  localparam logic [31:0] Word0 = 32'hA500_0000;
  localparam logic [31:0] Half01 = 32'hD200_8000;
  localparam logic [255:0] Beat0 = {
    32'h3344_5566, 32'h0B13_1C24, 32'h0404_0404, 32'h0303_0303,
    32'h0202_0202, 32'h8001_8001, 32'hD200_8000, 32'hA500_0000
  };

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;

  g6lc_apu_vgpu_rbf #(.Enable(1'b1)) i_rbf (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sbk_i(sbk), .tbn_i(tbn), .ss_i(ss),
    .lnr_i(lnr), .spx_i(spx_in), .vlr_i(vlr_in), .vbr_i(vbr_in), .vsx_i(vsx_in),
    .y2r_i(y2r_in),
    .req_valid_i(rbf_req), .req_ready_o(rbf_rdy),
    .cpl_valid_o(rbf_cpl_v), .cpl_ready_i(rbf_cpl_r), .cpl_o(rbf_cpl), .rbf_o(rbf),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data),
    .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy), .wr_rsp_ok_i(wr_rsp_ok),
    .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rbk #(.Enable(1'b1)) i_rbk (
    .clk_i(clk), .rst_ni, .rbf_i(rbf), .lnr_i(lnr),
    .req_valid_i(rbk_req), .req_ready_o(rbk_rdy),
    .cpl_valid_o(rbk_cpl_v), .cpl_ready_i(rbk_cpl_r), .cpl_o(rbk_cpl), .rbk_o(rbk)
  );
  g6lc_apu_vgpu_rbk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rbf_i(rbf), .lnr_i(lnr),
    .req_valid_i(rbk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rbk_cpl_r), .cpl_o(off_cpl), .rbk_o(off_rbk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #20000000; $fatal(1, "APU vgpu rbf timeout case=%0d nw=%0d", cases, nw); end

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
    end else if (row == 6'd0 && beat == 3'd1 && lane == 3'd0) gtexel = 32'hAABB_CCDD;
    else if (row == 6'd1 && beat == 3'd0 && lane == 3'd0) gtexel = 32'h0102_0304;
    else if (row == 6'd1 && beat == 3'd0 && lane == 3'd1) gtexel = 32'h0506_0708;
    else if (row == 6'd1 && beat == 3'd1 && lane == 3'd0) gtexel = 32'h0A0B_0C0D;
    else if (row == 6'd2 && beat == 3'd0 && lane == 3'd0) gtexel = 32'hF0F0_F0F0;
    else if (row == 6'd2 && beat == 3'd0 && lane == 3'd1) gtexel = 32'h0F0F_0F0F;
    else if (row == 6'd2 && beat == 3'd0 && lane == 3'd6) gtexel = 32'hA0A0_A0A0;
    else if (row == 6'd2 && beat == 3'd0 && lane == 3'd7) gtexel = 32'h5050_5050;
  endfunction

  function automatic logic [255:0] gbeat_row(
    input logic [5:0] row,
    input logic [2:0] beat
  );
    gbeat_row = {gtexel(row, {beat, 3'd7}), gtexel(row, {beat, 3'd6}),
                 gtexel(row, {beat, 3'd5}), gtexel(row, {beat, 3'd4}),
                 gtexel(row, {beat, 3'd3}), gtexel(row, {beat, 3'd2}),
                 gtexel(row, {beat, 3'd1}), gtexel(row, {beat, 3'd0})};
  endfunction

  function automatic logic [255:0] gdata(input logic [63:0] addr);
    logic [63:0] off, row64, rem64, beat64;
    off = addr - TexBase;
    row64 = off / 64'd2560;
    rem64 = off % 64'd2560;
    beat64 = rem64 / 64'd32;
    if (row64 <= 64'd63 && beat64 <= 64'd7 && rem64 == beat64 * 64'd32)
      gdata = gbeat_row(row64[5:0], beat64[2:0]);
    else gdata = '0;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) rd_rsp_v <= 1'b0;
    else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= gdata(rd_addr);
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      rd_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nw <= 0;
      order_bad <= 1'b0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      if (wr_addr != RbBase + (64'(nw - run_base) << 5)) order_bad <= 1'b1;
      if ((nw - run_base) == 0) beat0 <= wr_data;
      if ((nw - run_base) == 24) beat24 <= wr_data;
      if ((nw - run_base) == 511) beat_last <= wr_data;
      seen_last <= wr_addr;
      nw <= nw + 1;
      wr_rsp_addr <= wr_addr;
      wr_rsp_ok <= !fail_wr;
      fail_wr <= 1'b0;
      wr_rsp_v <= 1'b1;
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
    spx_in.word = 32'h8091_A2B3;
    vlr_in = '0;
    vlr_in.valid = 1'b1;
    vlr_in.at0 = 32'h5301_0202;
    vlr_in.at1 = 32'h6B02_4303;
    vbr_in = '0;
    vbr_in.valid = 1'b1;
    vbr_in.word = 32'h4202_4203;
    vsx_in = '0;
    vsx_in.valid = 1'b1;
    vsx_in.word = 32'h434C_545D;
    y2r_in = '0;
    y2r_in.valid = 1'b1;
    y2r_in.at0 = 32'h7979_7A7A;
    y2r_in.at1 = 32'h4242_4343;
  endtask

  task automatic rbf_step(input apu_vgpu_rbf_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rbf_rdy) @(negedge clk);
    cases++;
    n0 = nw;
    run_base = nw;
    rbf_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rbf_req = 1'b0;
    while (!rbf_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rbf_cpl.status == st);
    if (st == APU_VGPU_RBF_OK) begin
      check("readback record", rbf.valid && rbf.word0 == Word0 &&
            rbf.bytes == 32'd16384 && rbf.beats == 10'd512 &&
            rbf.last_addr == RbLast);
      check("write count", nw == n0 + 512 && !order_bad);
      check("beat 0", beat0 == Beat0);
      check("beat 24", beat24[31:0] == 32'h7878_7878 && seen_last == RbLast);
      check("last beat", beat_last == '0);
    end else if (st == APU_VGPU_RBF_FAULT && name == "bad write") begin
      check("one write", nw == n0 + 1);
    end else begin
      check("no write", nw == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), rbf_cpl_v);
    rbf_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rbf_cpl_r = 1'b0;
    while (rbf_cpl_v) @(negedge clk);
  endtask

  task automatic rbk_step(input apu_vgpu_rbk_status_e st, input string name);
    @(negedge clk);
    while (!rbk_rdy) @(negedge clk);
    cases++;
    rbk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rbk_req = 1'b0;
    while (!rbk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rbk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rbk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), rbk_cpl_v);
    rbk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rbk_cpl_r = 1'b0;
    while (rbk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rbf_req = 1'b0;
    rbk_req = 1'b0;
    rbf_cpl_r = 1'b0;
    rbk_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
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
    y2r_in = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && rbf == '0 &&
          rbk == '0);
    check("profiles keep the readback off",
          !ApuOff.RbfEn && !ApuOff.RbkEn &&
          !ApuP1Transport.RbfEn && !ApuP1Transport.RbkEn &&
          !ApuHarness.RbfEn && !ApuHarness.RbkEn &&
          !ApuSchedBoth.RbfEn && !ApuSchedBoth.RbkEn &&
          !ApuBadVirglGrant.RbfEn && !ApuBadVirglGrant.RbkEn);
    cfg = ApuP1Transport;
    cfg.RbfEn = 1'b1;
    cfg.RbkEn = 1'b1;
    check("readback does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.RbfEn = 1'b1;
    cfg.RbkEn = 1'b1;
    check("readback does not legalize virgl", !apu_cfg_legal(cfg));
    check("readback shape", APU_VGPU_CEIL_BYTES == 32'd16384 &&
          APU_VGPU_CEIL_BEATS == 10'd512 && APU_VGPU_CEIL_RB == 32'h88040000 &&
          RbLast == RbBase + (64'd511 << 5) && RbY3 == RbBase + (64'd24 << 5));

    rbf_step(APU_VGPU_RBF_EMPTY, "rbf empty");
    good_rec();
    fail_rd = 1'b1;
    rbf_step(APU_VGPU_RBF_FAULT, "bad read");
    check("read keeps", !rbf.valid);
    fail_wr = 1'b1;
    rbf_step(APU_VGPU_RBF_FAULT, "bad write");
    check("write keeps", !rbf.valid);
    rbf_step(APU_VGPU_RBF_OK, "ceiling");
    rbk_step(APU_VGPU_RBK_OK, "keep readback");
    check("record kept", rbk.valid && rbk.word0 == Word0 && rbk.beats == 10'd512 &&
          rbk.last_addr == RbLast);
    rbk_step(APU_VGPU_RBK_FAULT, "readback again");
    check("record stays", rbk.word0 == Word0 && rbk.last_addr == RbLast &&
          lnr.origin == Word0);

    pulse_reset();
    check("reset clears", rbf == '0 && rbk == '0);
    rbk_step(APU_VGPU_RBK_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu rbf errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rbf cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
