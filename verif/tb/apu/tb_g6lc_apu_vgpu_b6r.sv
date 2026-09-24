// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_b6r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_b5x_t b5x_in;
  apu_vgpu_cxr_t cxr;
  logic b6r_req = 0, b6r_rdy, b6r_cpl_v, b6r_cpl_r = 0;
  apu_vgpu_b6r_cpl_t b6r_cpl;
  apu_vgpu_b6r_t b6r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic b6k_req = 0, b6k_rdy, b6k_cpl_v, b6k_cpl_r = 0;
  apu_vgpu_b6k_cpl_t b6k_cpl;
  apu_vgpu_b6k_t b6k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic b6x_req = 0, b6x_rdy, b6x_cpl_v, b6x_cpl_r = 0;
  apu_vgpu_b6x_cpl_t b6x_cpl, off_cpl;
  apu_vgpu_b6x_t b6x, off_b6x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, corrupt_hi = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_b6r #(.Enable(1'b1)) i_b6r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .b5x_i(b5x_in), .cxr_i(cxr),
    .req_valid_i(b6r_req), .req_ready_o(b6r_rdy),
    .cpl_valid_o(b6r_cpl_v), .cpl_ready_i(b6r_cpl_r), .cpl_o(b6r_cpl), .b6r_o(b6r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_b6k #(.Enable(1'b1)) i_b6k (
    .clk_i(clk), .rst_ni, .b6r_i(b6r), .gbd_i(gbd),
    .req_valid_i(b6k_req), .req_ready_o(b6k_rdy),
    .cpl_valid_o(b6k_cpl_v), .cpl_ready_i(b6k_cpl_r), .cpl_o(b6k_cpl), .b6k_o(b6k)
  );
  g6lc_apu_vgpu_b6x #(.Enable(1'b1)) i_b6x (
    .clk_i(clk), .rst_ni, .b6k_i(b6k), .b0_i(b0),
    .req_valid_i(b6x_req), .req_ready_o(b6x_rdy),
    .cpl_valid_o(b6x_cpl_v), .cpl_ready_i(b6x_cpl_r), .cpl_o(b6x_cpl), .b6x_o(b6x)
  );
  g6lc_apu_vgpu_b6x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .b6k_i(b6k), .b0_i(b0),
    .req_valid_i(b6x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(b6x_cpl_r), .cpl_o(off_cpl), .b6x_o(off_b6x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu b6r timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_B6R_ADDR ||
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
    b5x_in = '0;
    b5x_in.valid = 1'b1;
    b5x_in.format = APU_VIRGL_FMT_B8G8R8X8;
    b5x_in.off40 = APU_VGPU_B5R_AT40;
    b5x_in.off47 = APU_VGPU_B5R_AT47;
    b5x_in.x40 = 7'd40;
    b5x_in.x47 = 7'd47;
    b5x_in.b0 = APU_VGPU_CLEAR_R;
    b5x_in.r = APU_VGPU_CLEAR_R;
    b5x_in.g = APU_VGPU_CLEAR_G;
    b5x_in.b = APU_VGPU_CLEAR_B;
    b5x_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_b6x == '0 &&
          off_cpl == '0);
  endtask

  task automatic b6r_step(input apu_vgpu_b6r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!b6r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    b6r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b6r_req = 1'b0;
    while (!b6r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b6r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_B6R_OK) begin
      check("beat", b6r.valid && b6r.off48 == 16'd192 && b6r.off55 == 16'd220 &&
            b6r.x48 == 7'd48 && b6r.x55 == 7'd55 &&
            b6r.r == 8'h0D && b6r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B6R_ADDR && seen != APU_VGPU_GBW_ADDR &&
            seen != APU_VGPU_B5R_ADDR && seen != APU_VGPU_B4R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B6R_ADDR && !b6r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), b6r_cpl_v);
    b6r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b6r_cpl_r = 1'b0;
    while (b6r_cpl_v) @(negedge clk);
  endtask

  task automatic b6k_step(input apu_vgpu_b6k_status_e st, input string name);
    @(negedge clk);
    while (!b6k_rdy) @(negedge clk);
    cases++;
    b6k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b6k_req = 1'b0;
    while (!b6k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b6k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b6k_cpl_v);
    b6k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b6k_cpl_r = 1'b0;
    while (b6k_cpl_v) @(negedge clk);
  endtask

  task automatic b6x_step(input apu_vgpu_b6x_status_e st, input string name);
    @(negedge clk);
    while (!b6x_rdy) @(negedge clk);
    cases++;
    b6x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b6x_req = 1'b0;
    while (!b6x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b6x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b6x_cpl_v);
    b6x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b6x_cpl_r = 1'b0;
    while (b6x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    b6r_req = 1'b0;
    b6k_req = 1'b0;
    b6x_req = 1'b0;
    b6r_cpl_r = 1'b0;
    b6k_cpl_r = 1'b0;
    b6x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    b5x_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          b6r == '0 && b6k == '0 && b6x == '0);
    check("profiles keep the beat off",
          !ApuOff.B6rEn && !ApuOff.B6kEn && !ApuOff.B6xEn &&
          !ApuP1Transport.B6rEn && !ApuP1Transport.B6kEn && !ApuP1Transport.B6xEn &&
          !ApuHarness.B6rEn && !ApuHarness.B6kEn && !ApuHarness.B6xEn &&
          !ApuSchedBoth.B6rEn && !ApuSchedBoth.B6kEn && !ApuSchedBoth.B6xEn &&
          !ApuBadVirglGrant.B6rEn && !ApuBadVirglGrant.B6kEn &&
          !ApuBadVirglGrant.B6xEn);
    cfg = ApuP1Transport;
    cfg.B6rEn = 1'b1;
    cfg.B6kEn = 1'b1;
    cfg.B6xEn = 1'b1;
    check("beat does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.B6rEn = 1'b1;
    cfg.B6kEn = 1'b1;
    cfg.B6xEn = 1'b1;
    check("beat does not legalize virgl", !apu_cfg_legal(cfg));
    check("beat address",
          APU_VGPU_B6R_AT48 == 16'd192 &&
          APU_VGPU_B6R_AT55 == 16'd220 &&
          (16'd48 << 2) == APU_VGPU_B6R_AT48 &&
          (16'd55 << 2) == APU_VGPU_B6R_AT55 &&
          APU_VGPU_B6R_AT48 + 16'd28 == APU_VGPU_B6R_AT55 &&
          APU_VGPU_B6R_ADDR == 64'h0000_0000_8803_00C0 &&
          APU_VGPU_GBW_ADDR + 64'd192 == APU_VGPU_B6R_ADDR &&
          APU_VGPU_B6R_ADDR != APU_VGPU_GBW_ADDR &&
          APU_VGPU_B6R_ADDR != APU_VGPU_B5R_ADDR &&
          APU_VGPU_B6R_ADDR != APU_VGPU_B4R_ADDR);

    b6r_step(APU_VGPU_B6R_EMPTY, "beat empty");
    b6k_step(APU_VGPU_B6K_EMPTY, "keep empty");
    b6x_step(APU_VGPU_B6X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    b6r_step(APU_VGPU_B6R_FAULT, "bad scissor");
    good_in();
    b5x_in.off40 = 16'd192;
    b6r_step(APU_VGPU_B6R_FAULT, "swapped beat");
    good_in();
    b5x_in.x40 = 7'd48;
    b6r_step(APU_VGPU_B6R_FAULT, "swapped point");
    good_in();
    fail_rd = 1'b1;
    b6r_step(APU_VGPU_B6R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    b6r_step(APU_VGPU_B6R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_hi = 1'b1;
    corrupt_b = 8'h1A;
    b6r_step(APU_VGPU_B6R_FAULT, "blue byte");
    b6r_step(APU_VGPU_B6R_OK, "beat");
    b6r_step(APU_VGPU_B6R_FAULT, "beat again");
    check("beat stays", b6r.off48 == 16'd192 && b6r.off55 == 16'd220 &&
          b6r.x48 == 7'd48 && b6r.x55 == 7'd55 && b6r.r == 8'h0D);
    gbd.bytes = 32'd0;
    b6k_step(APU_VGPU_B6K_FAULT, "keep bad bytes");
    check("keep rejected", !b6k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    b6k_step(APU_VGPU_B6K_OK, "keep beat");
    check("beat kept", b6k.valid && b6k.off48 == 16'd192 && b6k.off55 == 16'd220 &&
          b6k.x48 == 7'd48 && b6k.x55 == 7'd55 &&
          {b6k.a, b6k.b, b6k.g, b6k.r} == APU_VGPU_CLEAR_WORD);
    b6k_step(APU_VGPU_B6K_FAULT, "keep again");
    b0 = 8'h1A;
    b6x_step(APU_VGPU_B6X_FAULT, "blue first");
    check("blue rejected", !b6x.valid);
    b0 = 8'hFF;
    b6x_step(APU_VGPU_B6X_FAULT, "high byte first");
    check("high byte rejected", !b6x.valid);
    b0 = 8'h0D;
    b6x_step(APU_VGPU_B6X_OK, "red first");
    check("red first", b6x.valid && b6x.b0 == 8'h0D && b6x.off48 == 16'd192 &&
          b6x.off55 == 16'd220 && b6x.x48 == 7'd48);
    b6x_step(APU_VGPU_B6X_FAULT, "order again");
    check("order stays", b6x.b0 == 8'h0D && b6x.off55 == 16'd220);

    pulse_reset();
    check("reset clears", b6r == '0 && b6k == '0 && b6x == '0);
    gbd = '0;
    b5x_in = '0;
    cxr = '0;
    b6r_step(APU_VGPU_B6R_EMPTY, "after reset");
    b6k_step(APU_VGPU_B6K_EMPTY, "keep after reset");
    b6x_step(APU_VGPU_B6X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu b6r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_b6r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
