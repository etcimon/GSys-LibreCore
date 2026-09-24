// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_gof;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_gbk_t gbk;
  logic [6:0] px = 0, py = 0;
  logic gof_req = 0, gof_rdy, gof_cpl_v, gof_cpl_r = 0;
  apu_vgpu_gof_cpl_t gof_cpl;
  apu_vgpu_gof_t gof;
  logic gbo_req = 0, gbo_rdy, gbo_cpl_v, gbo_cpl_r = 0;
  apu_vgpu_gbo_cpl_t gbo_cpl;
  apu_vgpu_gbo_t gbo;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic gbz_req = 0, gbz_rdy, gbz_cpl_v, gbz_cpl_r = 0;
  apu_vgpu_gbz_cpl_t gbz_cpl, off_cpl;
  apu_vgpu_gbz_t gbz, off_gbz;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_lane = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_gof #(.Enable(1'b1)) i_gof (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .gbk_i(gbk), .x_i(px), .y_i(py),
    .req_valid_i(gof_req), .req_ready_o(gof_rdy),
    .cpl_valid_o(gof_cpl_v), .cpl_ready_i(gof_cpl_r), .cpl_o(gof_cpl), .gof_o(gof)
  );
  g6lc_apu_vgpu_gbo #(.Enable(1'b1)) i_gbo (
    .clk_i(clk), .rst_ni, .gof_i(gof), .gbd_i(gbd), .gbk_i(gbk),
    .req_valid_i(gbo_req), .req_ready_o(gbo_rdy),
    .cpl_valid_o(gbo_cpl_v), .cpl_ready_i(gbo_cpl_r), .cpl_o(gbo_cpl), .gbo_o(gbo),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_gbz #(.Enable(1'b1)) i_gbz (
    .clk_i(clk), .rst_ni, .gbo_i(gbo), .gof_i(gof), .gbd_i(gbd),
    .req_valid_i(gbz_req), .req_ready_o(gbz_rdy),
    .cpl_valid_o(gbz_cpl_v), .cpl_ready_i(gbz_cpl_r), .cpl_o(gbz_cpl), .gbz_o(gbz)
  );
  g6lc_apu_vgpu_gbz_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .gbo_i(gbo), .gof_i(gof), .gbd_i(gbd),
    .req_valid_i(gbz_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(gbz_cpl_r), .cpl_o(off_cpl), .gbz_o(off_gbz)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu gof timeout case=%0d", cases); end

  function automatic logic [15:0] pix_off(input logic [6:0] x, input logic [6:0] y);
    pix_off = {2'b0, y[5:0], 8'h00} + {8'h00, x[5:0], 2'b00};
  endfunction

  function automatic logic [255:0] beat_of(input logic [2:0] lane, input logic corrupt);
    logic [255:0] beat;
    beat = Pat;
    if (corrupt) begin
      case (lane)
        3'd0: beat[31:0] = 32'h0;
        3'd1: beat[63:32] = 32'h0;
        3'd2: beat[95:64] = 32'h0;
        3'd3: beat[127:96] = 32'h0;
        3'd4: beat[159:128] = 32'h0;
        3'd5: beat[191:160] = 32'h0;
        3'd6: beat[223:192] = 32'h0;
        default: beat[255:224] = 32'h0;
      endcase
    end
    beat_of = beat;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      if (rd_addr != gof.addr || rd_len != 32'(APU_VGPU_BEAT_BYTES))
        order_bad <= 1'b1;
      seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat_of(gof.offset[4:2], bad_lane);
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_lane <= 1'b0;
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
    gbd = '0;
    gbd.valid = 1'b1;
    gbd.width = APU_VGPU_GBD_W;
    gbd.height = APU_VGPU_GBD_H;
    gbd.stride = APU_VGPU_GBD_STRIDE;
    gbd.bytes = APU_VGPU_GBD_BYTES;
    gbd.format = APU_VIRGL_FMT_B8G8R8X8;
    gbd.base = APU_VGPU_GBW_ADDR;
    gbk = '0;
    gbk.valid = 1'b1;
    gbk.word = APU_VGPU_CLEAR_WORD;
    gbk.beats = APU_VGPU_GPW_BEATS;
    gbk.src = APU_VGPU_GPW_ADDR;
    gbk.dst = APU_VGPU_GBW_ADDR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_gbz == '0 &&
          off_cpl == '0);
  endtask

  task automatic gof_step(input apu_vgpu_gof_status_e st, input string name);
    @(negedge clk);
    while (!gof_rdy) @(negedge clk);
    cases++;
    gof_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gof_req = 1'b0;
    while (!gof_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gof_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GOF_OK) begin
      check("offset", gof.valid && gof.x == px && gof.y == py &&
            gof.offset == pix_off(px, py));
    end
    @(negedge clk);
    check($sformatf("%s held", name), gof_cpl_v);
    gof_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gof_cpl_r = 1'b0;
    while (gof_cpl_v) @(negedge clk);
  endtask

  task automatic gbo_step(input apu_vgpu_gbo_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gbo_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    gbo_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbo_req = 1'b0;
    while (!gbo_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gbo_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GBO_OK) begin
      check("lane", gbo.valid && gbo.word == APU_VGPU_CLEAR_WORD &&
            gbo.offset == gof.offset && gbo.x == gof.x && gbo.y == gof.y &&
            seen == gof.addr && !order_bad);
      check("one read", nread == n0 + 1);
    end else if (name == "bad beat" || name == "bad lane") begin
      check("one read", nread == n0 + 1 && !gbo.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), gbo_cpl_v);
    gbo_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbo_cpl_r = 1'b0;
    while (gbo_cpl_v) @(negedge clk);
  endtask

  task automatic gbz_step(input apu_vgpu_gbz_status_e st, input string name);
    @(negedge clk);
    while (!gbz_rdy) @(negedge clk);
    cases++;
    gbz_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbz_req = 1'b0;
    while (!gbz_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gbz_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gbz_cpl_v);
    gbz_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gbz_cpl_r = 1'b0;
    while (gbz_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    gof_req = 1'b0;
    gbo_req = 1'b0;
    gbz_req = 1'b0;
    gof_cpl_r = 1'b0;
    gbo_cpl_r = 1'b0;
    gbz_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    gbk = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          gof == '0 && gbo == '0 && gbz == '0);
    check("profiles keep the offset off",
          !ApuOff.GofEn && !ApuOff.GboEn && !ApuOff.GbzEn &&
          !ApuP1Transport.GofEn && !ApuP1Transport.GboEn && !ApuP1Transport.GbzEn &&
          !ApuHarness.GofEn && !ApuHarness.GboEn && !ApuHarness.GbzEn &&
          !ApuSchedBoth.GofEn && !ApuSchedBoth.GboEn && !ApuSchedBoth.GbzEn &&
          !ApuBadVirglGrant.GofEn && !ApuBadVirglGrant.GboEn &&
          !ApuBadVirglGrant.GbzEn);
    cfg = ApuP1Transport;
    cfg.GofEn = 1'b1;
    cfg.GboEn = 1'b1;
    cfg.GbzEn = 1'b1;
    check("offset does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GofEn = 1'b1;
    cfg.GboEn = 1'b1;
    cfg.GbzEn = 1'b1;
    check("offset does not legalize virgl", !apu_cfg_legal(cfg));
    check("known offsets",
          APU_VGPU_GOF_AT10 == 16'd4 &&
          APU_VGPU_GOF_ROW1 == 16'd256 &&
          APU_VGPU_GOF_LAST == 16'd16380 &&
          APU_VGPU_GOF_ROW1_ADDR == 64'h88030100 &&
          pix_off(7'd1, 7'd0) == APU_VGPU_GOF_AT10 &&
          pix_off(7'd0, 7'd1) == APU_VGPU_GOF_ROW1 &&
          pix_off(7'd63, 7'd63) == APU_VGPU_GOF_LAST &&
          32'(APU_VGPU_GOF_LAST) + 32'd4 == APU_VGPU_GBD_BYTES);

    gbo_step(APU_VGPU_GBO_EMPTY, "lane empty");
    gof_step(APU_VGPU_GOF_EMPTY, "offset empty");
    gbz_step(APU_VGPU_GBZ_EMPTY, "keep empty");
    good_in();
    px = 7'd64;
    py = 7'd0;
    gof_step(APU_VGPU_GOF_FAULT, "x past");
    px = 7'd0;
    py = 7'd64;
    gof_step(APU_VGPU_GOF_FAULT, "y past");
    px = 7'd0;
    py = 7'd1;
    gof_step(APU_VGPU_GOF_OK, "row 1");
    check("row address", gof.offset == 16'd256 && gof.addr == 64'h88030100);
    gof_step(APU_VGPU_GOF_FAULT, "row again");
    fail_rd = 1'b1;
    gbo_step(APU_VGPU_GBO_FAULT, "bad beat");
    bad_lane = 1'b1;
    gbo_step(APU_VGPU_GBO_FAULT, "bad lane");
    gbo_step(APU_VGPU_GBO_OK, "read row");
    gbo_step(APU_VGPU_GBO_FAULT, "read again");
    check("row stays", gbo.offset == 16'd256 && gbo.word == APU_VGPU_CLEAR_WORD &&
          gbo.y == 7'd1);
    gbd.bytes = 32'd0;
    gbz_step(APU_VGPU_GBZ_FAULT, "keep bad bytes");
    check("keep rejected", !gbz.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    gbz_step(APU_VGPU_GBZ_OK, "keep offset");
    check("offset kept", gbz.valid && gbz.offset == 16'd256 &&
          gbz.bytes == 32'd16384 && gbz.word == APU_VGPU_CLEAR_WORD &&
          gbz.x == 7'd0 && gbz.y == 7'd1);
    gbz_step(APU_VGPU_GBZ_FAULT, "keep again");
    check("keep stays", gbz.offset == gbo.offset && gbz.word == gbo.word);

    pulse_reset();
    check("reset clears", gof == '0 && gbo == '0 && gbz == '0);
    gbd = '0;
    gof_step(APU_VGPU_GOF_EMPTY, "after reset");
    good_in();
    px = 7'd1;
    py = 7'd0;
    gof_step(APU_VGPU_GOF_OK, "pixel 1 0");
    check("byte 4", gof.offset == 16'd4 && gof.addr == APU_VGPU_GBW_ADDR);
    gbo_step(APU_VGPU_GBO_OK, "read byte 4");
    check("byte 4 word", gbo.word == APU_VGPU_CLEAR_WORD && gbo.x == 7'd1);

    pulse_reset();
    good_in();
    px = 7'd63;
    py = 7'd63;
    gof_step(APU_VGPU_GOF_OK, "pixel 63 63");
    check("last byte", gof.offset == 16'd16380 && gof.addr == APU_VGPU_GBW_TAIL);
    gbo_step(APU_VGPU_GBO_OK, "read last");
    check("last word", gbo.word == APU_VGPU_CLEAR_WORD &&
          32'(gbo.offset) + 32'd4 == 32'd16384);

    if (errors != 0) $fatal(1, "APU vgpu gof errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_gof cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
