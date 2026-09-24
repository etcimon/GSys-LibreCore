// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_b4r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_b3x_t b3x_in;
  apu_vgpu_cxr_t cxr;
  logic b4r_req = 0, b4r_rdy, b4r_cpl_v, b4r_cpl_r = 0;
  apu_vgpu_b4r_cpl_t b4r_cpl;
  apu_vgpu_b4r_t b4r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic b4k_req = 0, b4k_rdy, b4k_cpl_v, b4k_cpl_r = 0;
  apu_vgpu_b4k_cpl_t b4k_cpl;
  apu_vgpu_b4k_t b4k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic b4x_req = 0, b4x_rdy, b4x_cpl_v, b4x_cpl_r = 0;
  apu_vgpu_b4x_cpl_t b4x_cpl, off_cpl;
  apu_vgpu_b4x_t b4x, off_b4x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, corrupt_hi = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_b4r #(.Enable(1'b1)) i_b4r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .b3x_i(b3x_in), .cxr_i(cxr),
    .req_valid_i(b4r_req), .req_ready_o(b4r_rdy),
    .cpl_valid_o(b4r_cpl_v), .cpl_ready_i(b4r_cpl_r), .cpl_o(b4r_cpl), .b4r_o(b4r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_b4k #(.Enable(1'b1)) i_b4k (
    .clk_i(clk), .rst_ni, .b4r_i(b4r), .gbd_i(gbd),
    .req_valid_i(b4k_req), .req_ready_o(b4k_rdy),
    .cpl_valid_o(b4k_cpl_v), .cpl_ready_i(b4k_cpl_r), .cpl_o(b4k_cpl), .b4k_o(b4k)
  );
  g6lc_apu_vgpu_b4x #(.Enable(1'b1)) i_b4x (
    .clk_i(clk), .rst_ni, .b4k_i(b4k), .b0_i(b0),
    .req_valid_i(b4x_req), .req_ready_o(b4x_rdy),
    .cpl_valid_o(b4x_cpl_v), .cpl_ready_i(b4x_cpl_r), .cpl_o(b4x_cpl), .b4x_o(b4x)
  );
  g6lc_apu_vgpu_b4x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .b4k_i(b4k), .b0_i(b0),
    .req_valid_i(b4x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(b4x_cpl_r), .cpl_o(off_cpl), .b4x_o(off_b4x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu b4r timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_B4R_ADDR ||
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
    b3x_in = '0;
    b3x_in.valid = 1'b1;
    b3x_in.format = APU_VIRGL_FMT_B8G8R8X8;
    b3x_in.off24 = APU_VGPU_B3R_AT24;
    b3x_in.off31 = APU_VGPU_B3R_AT31;
    b3x_in.x24 = 7'd24;
    b3x_in.x31 = 7'd31;
    b3x_in.b0 = APU_VGPU_CLEAR_R;
    b3x_in.r = APU_VGPU_CLEAR_R;
    b3x_in.g = APU_VGPU_CLEAR_G;
    b3x_in.b = APU_VGPU_CLEAR_B;
    b3x_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_b4x == '0 &&
          off_cpl == '0);
  endtask

  task automatic b4r_step(input apu_vgpu_b4r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!b4r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    b4r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b4r_req = 1'b0;
    while (!b4r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b4r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_B4R_OK) begin
      check("beat", b4r.valid && b4r.off32 == 16'd128 && b4r.off39 == 16'd156 &&
            b4r.x32 == 7'd32 && b4r.x39 == 7'd39 &&
            b4r.r == 8'h0D && b4r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B4R_ADDR && seen != APU_VGPU_GBW_ADDR &&
            seen != APU_VGPU_B3R_ADDR && seen != APU_VGPU_B2R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B4R_ADDR && !b4r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), b4r_cpl_v);
    b4r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b4r_cpl_r = 1'b0;
    while (b4r_cpl_v) @(negedge clk);
  endtask

  task automatic b4k_step(input apu_vgpu_b4k_status_e st, input string name);
    @(negedge clk);
    while (!b4k_rdy) @(negedge clk);
    cases++;
    b4k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b4k_req = 1'b0;
    while (!b4k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b4k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b4k_cpl_v);
    b4k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b4k_cpl_r = 1'b0;
    while (b4k_cpl_v) @(negedge clk);
  endtask

  task automatic b4x_step(input apu_vgpu_b4x_status_e st, input string name);
    @(negedge clk);
    while (!b4x_rdy) @(negedge clk);
    cases++;
    b4x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b4x_req = 1'b0;
    while (!b4x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b4x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b4x_cpl_v);
    b4x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b4x_cpl_r = 1'b0;
    while (b4x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    b4r_req = 1'b0;
    b4k_req = 1'b0;
    b4x_req = 1'b0;
    b4r_cpl_r = 1'b0;
    b4k_cpl_r = 1'b0;
    b4x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    b3x_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          b4r == '0 && b4k == '0 && b4x == '0);
    check("profiles keep the beat off",
          !ApuOff.B4rEn && !ApuOff.B4kEn && !ApuOff.B4xEn &&
          !ApuP1Transport.B4rEn && !ApuP1Transport.B4kEn && !ApuP1Transport.B4xEn &&
          !ApuHarness.B4rEn && !ApuHarness.B4kEn && !ApuHarness.B4xEn &&
          !ApuSchedBoth.B4rEn && !ApuSchedBoth.B4kEn && !ApuSchedBoth.B4xEn &&
          !ApuBadVirglGrant.B4rEn && !ApuBadVirglGrant.B4kEn &&
          !ApuBadVirglGrant.B4xEn);
    cfg = ApuP1Transport;
    cfg.B4rEn = 1'b1;
    cfg.B4kEn = 1'b1;
    cfg.B4xEn = 1'b1;
    check("beat does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.B4rEn = 1'b1;
    cfg.B4kEn = 1'b1;
    cfg.B4xEn = 1'b1;
    check("beat does not legalize virgl", !apu_cfg_legal(cfg));
    check("beat address",
          APU_VGPU_B4R_AT32 == 16'd128 &&
          APU_VGPU_B4R_AT39 == 16'd156 &&
          (16'd32 << 2) == APU_VGPU_B4R_AT32 &&
          (16'd39 << 2) == APU_VGPU_B4R_AT39 &&
          APU_VGPU_B4R_AT32 + 16'd28 == APU_VGPU_B4R_AT39 &&
          APU_VGPU_B4R_ADDR == 64'h0000_0000_8803_0080 &&
          APU_VGPU_GBW_ADDR + 64'd128 == APU_VGPU_B4R_ADDR &&
          APU_VGPU_B4R_ADDR != APU_VGPU_GBW_ADDR &&
          APU_VGPU_B4R_ADDR != APU_VGPU_B3R_ADDR &&
          APU_VGPU_B4R_ADDR != APU_VGPU_B2R_ADDR);

    b4r_step(APU_VGPU_B4R_EMPTY, "beat empty");
    b4k_step(APU_VGPU_B4K_EMPTY, "keep empty");
    b4x_step(APU_VGPU_B4X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    b4r_step(APU_VGPU_B4R_FAULT, "bad scissor");
    good_in();
    b3x_in.off24 = 16'd128;
    b4r_step(APU_VGPU_B4R_FAULT, "swapped beat");
    good_in();
    b3x_in.x24 = 7'd32;
    b4r_step(APU_VGPU_B4R_FAULT, "swapped point");
    good_in();
    fail_rd = 1'b1;
    b4r_step(APU_VGPU_B4R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    b4r_step(APU_VGPU_B4R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_hi = 1'b1;
    corrupt_b = 8'h1A;
    b4r_step(APU_VGPU_B4R_FAULT, "blue byte");
    b4r_step(APU_VGPU_B4R_OK, "beat");
    b4r_step(APU_VGPU_B4R_FAULT, "beat again");
    check("beat stays", b4r.off32 == 16'd128 && b4r.off39 == 16'd156 &&
          b4r.x32 == 7'd32 && b4r.x39 == 7'd39 && b4r.r == 8'h0D);
    gbd.bytes = 32'd0;
    b4k_step(APU_VGPU_B4K_FAULT, "keep bad bytes");
    check("keep rejected", !b4k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    b4k_step(APU_VGPU_B4K_OK, "keep beat");
    check("beat kept", b4k.valid && b4k.off32 == 16'd128 && b4k.off39 == 16'd156 &&
          b4k.x32 == 7'd32 && b4k.x39 == 7'd39 &&
          {b4k.a, b4k.b, b4k.g, b4k.r} == APU_VGPU_CLEAR_WORD);
    b4k_step(APU_VGPU_B4K_FAULT, "keep again");
    b0 = 8'h1A;
    b4x_step(APU_VGPU_B4X_FAULT, "blue first");
    check("blue rejected", !b4x.valid);
    b0 = 8'hFF;
    b4x_step(APU_VGPU_B4X_FAULT, "high byte first");
    check("high byte rejected", !b4x.valid);
    b0 = 8'h0D;
    b4x_step(APU_VGPU_B4X_OK, "red first");
    check("red first", b4x.valid && b4x.b0 == 8'h0D && b4x.off32 == 16'd128 &&
          b4x.off39 == 16'd156 && b4x.x32 == 7'd32);
    b4x_step(APU_VGPU_B4X_FAULT, "order again");
    check("order stays", b4x.b0 == 8'h0D && b4x.off39 == 16'd156);

    pulse_reset();
    check("reset clears", b4r == '0 && b4k == '0 && b4x == '0);
    gbd = '0;
    b3x_in = '0;
    cxr = '0;
    b4r_step(APU_VGPU_B4R_EMPTY, "after reset");
    b4k_step(APU_VGPU_B4K_EMPTY, "keep after reset");
    b4x_step(APU_VGPU_B4X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu b4r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_b4r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
