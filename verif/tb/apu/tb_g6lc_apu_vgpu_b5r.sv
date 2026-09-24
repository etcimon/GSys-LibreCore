// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_b5r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_b4x_t b4x_in;
  apu_vgpu_cxr_t cxr;
  logic b5r_req = 0, b5r_rdy, b5r_cpl_v, b5r_cpl_r = 0;
  apu_vgpu_b5r_cpl_t b5r_cpl;
  apu_vgpu_b5r_t b5r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic b5k_req = 0, b5k_rdy, b5k_cpl_v, b5k_cpl_r = 0;
  apu_vgpu_b5k_cpl_t b5k_cpl;
  apu_vgpu_b5k_t b5k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic b5x_req = 0, b5x_rdy, b5x_cpl_v, b5x_cpl_r = 0;
  apu_vgpu_b5x_cpl_t b5x_cpl, off_cpl;
  apu_vgpu_b5x_t b5x, off_b5x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, corrupt_hi = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_b5r #(.Enable(1'b1)) i_b5r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .b4x_i(b4x_in), .cxr_i(cxr),
    .req_valid_i(b5r_req), .req_ready_o(b5r_rdy),
    .cpl_valid_o(b5r_cpl_v), .cpl_ready_i(b5r_cpl_r), .cpl_o(b5r_cpl), .b5r_o(b5r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_b5k #(.Enable(1'b1)) i_b5k (
    .clk_i(clk), .rst_ni, .b5r_i(b5r), .gbd_i(gbd),
    .req_valid_i(b5k_req), .req_ready_o(b5k_rdy),
    .cpl_valid_o(b5k_cpl_v), .cpl_ready_i(b5k_cpl_r), .cpl_o(b5k_cpl), .b5k_o(b5k)
  );
  g6lc_apu_vgpu_b5x #(.Enable(1'b1)) i_b5x (
    .clk_i(clk), .rst_ni, .b5k_i(b5k), .b0_i(b0),
    .req_valid_i(b5x_req), .req_ready_o(b5x_rdy),
    .cpl_valid_o(b5x_cpl_v), .cpl_ready_i(b5x_cpl_r), .cpl_o(b5x_cpl), .b5x_o(b5x)
  );
  g6lc_apu_vgpu_b5x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .b5k_i(b5k), .b0_i(b0),
    .req_valid_i(b5x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(b5x_cpl_r), .cpl_o(off_cpl), .b5x_o(off_b5x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu b5r timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (corrupt) begin
        if (corrupt_hi) beat[231:224] = corrupt_b;
        else beat[7:0] = corrupt_b;
      end
      if (rd_addr != APU_VGPU_B5R_ADDR ||
          rd_len != 32'(APU_VGPU_BEAT_BYTES)) order_bad <= 1'b1;
      seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      corrupt <= 1'b0;
      corrupt_hi <= 1'b0;
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
    b4x_in = '0;
    b4x_in.valid = 1'b1;
    b4x_in.format = APU_VIRGL_FMT_B8G8R8X8;
    b4x_in.off32 = APU_VGPU_B4R_AT32;
    b4x_in.off39 = APU_VGPU_B4R_AT39;
    b4x_in.x32 = 7'd32;
    b4x_in.x39 = 7'd39;
    b4x_in.b0 = APU_VGPU_CLEAR_R;
    b4x_in.r = APU_VGPU_CLEAR_R;
    b4x_in.g = APU_VGPU_CLEAR_G;
    b4x_in.b = APU_VGPU_CLEAR_B;
    b4x_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_b5x == '0 &&
          off_cpl == '0);
  endtask

  task automatic b5r_step(input apu_vgpu_b5r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!b5r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    b5r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b5r_req = 1'b0;
    while (!b5r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b5r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_B5R_OK) begin
      check("beat", b5r.valid && b5r.off40 == 16'd160 && b5r.off47 == 16'd188 &&
            b5r.x40 == 7'd40 && b5r.x47 == 7'd47 &&
            b5r.r == 8'h0D && b5r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B5R_ADDR && seen != APU_VGPU_GBW_ADDR &&
            seen != APU_VGPU_B4R_ADDR && seen != APU_VGPU_B3R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B5R_ADDR && !b5r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), b5r_cpl_v);
    b5r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b5r_cpl_r = 1'b0;
    while (b5r_cpl_v) @(negedge clk);
  endtask

  task automatic b5k_step(input apu_vgpu_b5k_status_e st, input string name);
    @(negedge clk);
    while (!b5k_rdy) @(negedge clk);
    cases++;
    b5k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b5k_req = 1'b0;
    while (!b5k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b5k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b5k_cpl_v);
    b5k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b5k_cpl_r = 1'b0;
    while (b5k_cpl_v) @(negedge clk);
  endtask

  task automatic b5x_step(input apu_vgpu_b5x_status_e st, input string name);
    @(negedge clk);
    while (!b5x_rdy) @(negedge clk);
    cases++;
    b5x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b5x_req = 1'b0;
    while (!b5x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b5x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b5x_cpl_v);
    b5x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b5x_cpl_r = 1'b0;
    while (b5x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    b5r_req = 1'b0;
    b5k_req = 1'b0;
    b5x_req = 1'b0;
    b5r_cpl_r = 1'b0;
    b5k_cpl_r = 1'b0;
    b5x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    b4x_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          b5r == '0 && b5k == '0 && b5x == '0);
    check("profiles keep the beat off",
          !ApuOff.B5rEn && !ApuOff.B5kEn && !ApuOff.B5xEn &&
          !ApuP1Transport.B5rEn && !ApuP1Transport.B5kEn && !ApuP1Transport.B5xEn &&
          !ApuHarness.B5rEn && !ApuHarness.B5kEn && !ApuHarness.B5xEn &&
          !ApuSchedBoth.B5rEn && !ApuSchedBoth.B5kEn && !ApuSchedBoth.B5xEn &&
          !ApuBadVirglGrant.B5rEn && !ApuBadVirglGrant.B5kEn &&
          !ApuBadVirglGrant.B5xEn);
    cfg = ApuP1Transport;
    cfg.B5rEn = 1'b1;
    cfg.B5kEn = 1'b1;
    cfg.B5xEn = 1'b1;
    check("beat does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.B5rEn = 1'b1;
    cfg.B5kEn = 1'b1;
    cfg.B5xEn = 1'b1;
    check("beat does not legalize virgl", !apu_cfg_legal(cfg));
    check("beat address",
          APU_VGPU_B5R_AT40 == 16'd160 &&
          APU_VGPU_B5R_AT47 == 16'd188 &&
          (16'd40 << 2) == APU_VGPU_B5R_AT40 &&
          (16'd47 << 2) == APU_VGPU_B5R_AT47 &&
          APU_VGPU_B5R_AT40 + 16'd28 == APU_VGPU_B5R_AT47 &&
          APU_VGPU_B5R_ADDR == 64'h0000_0000_8803_00A0 &&
          APU_VGPU_GBW_ADDR + 64'd160 == APU_VGPU_B5R_ADDR &&
          APU_VGPU_B5R_ADDR != APU_VGPU_GBW_ADDR &&
          APU_VGPU_B5R_ADDR != APU_VGPU_B4R_ADDR &&
          APU_VGPU_B5R_ADDR != APU_VGPU_B3R_ADDR);

    b5r_step(APU_VGPU_B5R_EMPTY, "beat empty");
    b5k_step(APU_VGPU_B5K_EMPTY, "keep empty");
    b5x_step(APU_VGPU_B5X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    b5r_step(APU_VGPU_B5R_FAULT, "bad scissor");
    good_in();
    b4x_in.off32 = 16'd160;
    b5r_step(APU_VGPU_B5R_FAULT, "swapped beat");
    good_in();
    b4x_in.x32 = 7'd40;
    b5r_step(APU_VGPU_B5R_FAULT, "swapped point");
    good_in();
    fail_rd = 1'b1;
    b5r_step(APU_VGPU_B5R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    b5r_step(APU_VGPU_B5R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_hi = 1'b1;
    corrupt_b = 8'h1A;
    b5r_step(APU_VGPU_B5R_FAULT, "blue byte");
    b5r_step(APU_VGPU_B5R_OK, "beat");
    b5r_step(APU_VGPU_B5R_FAULT, "beat again");
    check("beat stays", b5r.off40 == 16'd160 && b5r.off47 == 16'd188 &&
          b5r.x40 == 7'd40 && b5r.x47 == 7'd47 && b5r.r == 8'h0D);
    gbd.bytes = 32'd0;
    b5k_step(APU_VGPU_B5K_FAULT, "keep bad bytes");
    check("keep rejected", !b5k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    b5k_step(APU_VGPU_B5K_OK, "keep beat");
    check("beat kept", b5k.valid && b5k.off40 == 16'd160 && b5k.off47 == 16'd188 &&
          b5k.x40 == 7'd40 && b5k.x47 == 7'd47 &&
          {b5k.a, b5k.b, b5k.g, b5k.r} == APU_VGPU_CLEAR_WORD);
    b5k_step(APU_VGPU_B5K_FAULT, "keep again");
    b0 = 8'h1A;
    b5x_step(APU_VGPU_B5X_FAULT, "blue first");
    check("blue rejected", !b5x.valid);
    b0 = 8'hFF;
    b5x_step(APU_VGPU_B5X_FAULT, "high byte first");
    check("high byte rejected", !b5x.valid);
    b0 = 8'h0D;
    b5x_step(APU_VGPU_B5X_OK, "red first");
    check("red first", b5x.valid && b5x.b0 == 8'h0D && b5x.off40 == 16'd160 &&
          b5x.off47 == 16'd188 && b5x.x40 == 7'd40);
    b5x_step(APU_VGPU_B5X_FAULT, "order again");
    check("order stays", b5x.b0 == 8'h0D && b5x.off47 == 16'd188);

    pulse_reset();
    check("reset clears", b5r == '0 && b5k == '0 && b5x == '0);
    gbd = '0;
    b4x_in = '0;
    cxr = '0;
    b5r_step(APU_VGPU_B5R_EMPTY, "after reset");
    b5k_step(APU_VGPU_B5K_EMPTY, "keep after reset");
    b5x_step(APU_VGPU_B5X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu b5r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_b5r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
