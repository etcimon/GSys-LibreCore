// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ryr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_byx_t byx_in;
  apu_vgpu_cxr_t cxr;
  logic ryr_req = 0, ryr_rdy, ryr_cpl_v, ryr_cpl_r = 0;
  apu_vgpu_ryr_cpl_t ryr_cpl;
  apu_vgpu_ryr_t ryr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic ryk_req = 0, ryk_rdy, ryk_cpl_v, ryk_cpl_r = 0;
  apu_vgpu_ryk_cpl_t ryk_cpl;
  apu_vgpu_ryk_t ryk;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic ryx_req = 0, ryx_rdy, ryx_cpl_v, ryx_cpl_r = 0;
  apu_vgpu_ryx_cpl_t ryx_cpl, off_cpl;
  apu_vgpu_ryx_t ryx, off_ryx;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_ryr #(.Enable(1'b1)) i_ryr (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .byx_i(byx_in), .cxr_i(cxr),
    .req_valid_i(ryr_req), .req_ready_o(ryr_rdy),
    .cpl_valid_o(ryr_cpl_v), .cpl_ready_i(ryr_cpl_r), .cpl_o(ryr_cpl), .ryr_o(ryr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_ryk #(.Enable(1'b1)) i_ryk (
    .clk_i(clk), .rst_ni, .ryr_i(ryr), .gbd_i(gbd),
    .req_valid_i(ryk_req), .req_ready_o(ryk_rdy),
    .cpl_valid_o(ryk_cpl_v), .cpl_ready_i(ryk_cpl_r), .cpl_o(ryk_cpl), .ryk_o(ryk)
  );
  g6lc_apu_vgpu_ryx #(.Enable(1'b1)) i_ryx (
    .clk_i(clk), .rst_ni, .ryk_i(ryk), .b0_i(b0),
    .req_valid_i(ryx_req), .req_ready_o(ryx_rdy),
    .cpl_valid_o(ryx_cpl_v), .cpl_ready_i(ryx_cpl_r), .cpl_o(ryx_cpl), .ryx_o(ryx)
  );
  g6lc_apu_vgpu_ryx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .ryk_i(ryk), .b0_i(b0),
    .req_valid_i(ryx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(ryx_cpl_r), .cpl_o(off_cpl), .ryx_o(off_ryx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu ryr timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (corrupt) beat[7:0] = corrupt_b;
      if (rd_addr != APU_VGPU_GOF_ROW1_ADDR ||
          rd_len != 32'(APU_VGPU_BEAT_BYTES)) order_bad <= 1'b1;
      seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      corrupt <= 1'b0;
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
    byx_in = '0;
    byx_in.valid = 1'b1;
    byx_in.b0 = APU_VGPU_CLEAR_R;
    byx_in.r = APU_VGPU_CLEAR_R;
    byx_in.g = APU_VGPU_CLEAR_G;
    byx_in.b = APU_VGPU_CLEAR_B;
    byx_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_ryx == '0 &&
          off_cpl == '0);
  endtask

  task automatic ryr_step(input apu_vgpu_ryr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!ryr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    ryr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ryr_req = 1'b0;
    while (!ryr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ryr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RYR_OK) begin
      check("row channels", ryr.valid && ryr.format == APU_VIRGL_FMT_B8G8R8X8 &&
            ryr.r == 8'h0D && ryr.g == 8'h0D && ryr.b == 8'h1A && ryr.a == 8'hFF);
      check("row beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_GOF_ROW1_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_GOF_ROW1_ADDR && !ryr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), ryr_cpl_v);
    ryr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ryr_cpl_r = 1'b0;
    while (ryr_cpl_v) @(negedge clk);
  endtask

  task automatic ryk_step(input apu_vgpu_ryk_status_e st, input string name);
    @(negedge clk);
    while (!ryk_rdy) @(negedge clk);
    cases++;
    ryk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ryk_req = 1'b0;
    while (!ryk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ryk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), ryk_cpl_v);
    ryk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ryk_cpl_r = 1'b0;
    while (ryk_cpl_v) @(negedge clk);
  endtask

  task automatic ryx_step(input apu_vgpu_ryx_status_e st, input string name);
    @(negedge clk);
    while (!ryx_rdy) @(negedge clk);
    cases++;
    ryx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ryx_req = 1'b0;
    while (!ryx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ryx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), ryx_cpl_v);
    ryx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ryx_cpl_r = 1'b0;
    while (ryx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    ryr_req = 1'b0;
    ryk_req = 1'b0;
    ryx_req = 1'b0;
    ryr_cpl_r = 1'b0;
    ryk_cpl_r = 1'b0;
    ryx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    byx_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          ryr == '0 && ryk == '0 && ryx == '0);
    check("profiles keep the row off",
          !ApuOff.RyrEn && !ApuOff.RykEn && !ApuOff.RyxEn &&
          !ApuP1Transport.RyrEn && !ApuP1Transport.RykEn && !ApuP1Transport.RyxEn &&
          !ApuHarness.RyrEn && !ApuHarness.RykEn && !ApuHarness.RyxEn &&
          !ApuSchedBoth.RyrEn && !ApuSchedBoth.RykEn && !ApuSchedBoth.RyxEn &&
          !ApuBadVirglGrant.RyrEn && !ApuBadVirglGrant.RykEn &&
          !ApuBadVirglGrant.RyxEn);
    cfg = ApuP1Transport;
    cfg.RyrEn = 1'b1;
    cfg.RykEn = 1'b1;
    cfg.RyxEn = 1'b1;
    check("row does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RyrEn = 1'b1;
    cfg.RykEn = 1'b1;
    cfg.RyxEn = 1'b1;
    check("row does not legalize virgl", !apu_cfg_legal(cfg));
    check("row address",
          APU_VGPU_GOF_ROW1_ADDR == 64'h0000_0000_8803_0100 &&
          APU_VGPU_GOF_ROW1 == 16'd256 &&
          APU_VIRGL_FMT_B8G8R8X8 == 32'd2 &&
          APU_VGPU_CLEAR_R == 8'h0D && APU_VGPU_CLEAR_B == 8'h1A &&
          APU_VGPU_CLEAR_A == 8'hFF &&
          APU_VGPU_CLEAR_WORD == {APU_VGPU_CLEAR_A, APU_VGPU_CLEAR_B,
                                  APU_VGPU_CLEAR_G, APU_VGPU_CLEAR_R});

    ryr_step(APU_VGPU_RYR_EMPTY, "row empty");
    ryk_step(APU_VGPU_RYK_EMPTY, "keep empty");
    ryx_step(APU_VGPU_RYX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    ryr_step(APU_VGPU_RYR_FAULT, "bad scissor");
    good_in();
    gbd.format = 32'd0;
    ryr_step(APU_VGPU_RYR_FAULT, "bad format");
    good_in();
    gbd.height = 16'd480;
    ryr_step(APU_VGPU_RYR_FAULT, "tall rectangle");
    good_in();
    byx_in.b0 = 8'h1A;
    ryr_step(APU_VGPU_RYR_FAULT, "posted blue");
    good_in();
    fail_rd = 1'b1;
    ryr_step(APU_VGPU_RYR_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    ryr_step(APU_VGPU_RYR_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_b = 8'h1A;
    ryr_step(APU_VGPU_RYR_FAULT, "blue byte");
    ryr_step(APU_VGPU_RYR_OK, "row");
    ryr_step(APU_VGPU_RYR_FAULT, "row again");
    check("row stays", ryr.r == 8'h0D && ryr.a == 8'hFF &&
          ryr.format == 32'd2);
    gbd.stride = 16'd0;
    ryk_step(APU_VGPU_RYK_FAULT, "keep bad stride");
    check("keep rejected", !ryk.valid);
    gbd.stride = APU_VGPU_GBD_STRIDE;
    ryk_step(APU_VGPU_RYK_OK, "keep row");
    check("row kept", ryk.valid && ryk.format == 32'd2 &&
          ryk.r == 8'h0D && ryk.b == 8'h1A &&
          {ryk.a, ryk.b, ryk.g, ryk.r} == APU_VGPU_CLEAR_WORD);
    ryk_step(APU_VGPU_RYK_FAULT, "keep again");
    b0 = 8'h1A;
    ryx_step(APU_VGPU_RYX_FAULT, "blue first");
    check("blue rejected", !ryx.valid);
    b0 = 8'hFF;
    ryx_step(APU_VGPU_RYX_FAULT, "high byte first");
    check("high byte rejected", !ryx.valid);
    b0 = 8'h0D;
    ryx_step(APU_VGPU_RYX_OK, "red first");
    check("red first", ryx.valid && ryx.b0 == 8'h0D && ryx.b0 != 8'h1A &&
          ryx.b0 != 8'hFF && ryx.format == 32'd2 && ryx.r == 8'h0D &&
          ryx.a == 8'hFF);
    ryx_step(APU_VGPU_RYX_FAULT, "order again");
    check("order stays", ryx.b0 == 8'h0D && ryx.format == 32'd2);

    pulse_reset();
    check("reset clears", ryr == '0 && ryk == '0 && ryx == '0);
    gbd = '0;
    byx_in = '0;
    cxr = '0;
    ryr_step(APU_VGPU_RYR_EMPTY, "after reset");
    ryk_step(APU_VGPU_RYK_EMPTY, "keep after reset");
    ryx_step(APU_VGPU_RYX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu ryr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ryr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
