// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_b7r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_x6x_t x6x_in;
  apu_vgpu_b1x_t b1x_in;
  apu_vgpu_cxr_t cxr;
  logic b7r_req = 0, b7r_rdy, b7r_cpl_v, b7r_cpl_r = 0;
  apu_vgpu_b7r_cpl_t b7r_cpl;
  apu_vgpu_b7r_t b7r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic b7k_req = 0, b7k_rdy, b7k_cpl_v, b7k_cpl_r = 0;
  apu_vgpu_b7k_cpl_t b7k_cpl;
  apu_vgpu_b7k_t b7k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic b7x_req = 0, b7x_rdy, b7x_cpl_v, b7x_cpl_r = 0;
  apu_vgpu_b7x_cpl_t b7x_cpl, off_cpl;
  apu_vgpu_b7x_t b7x, off_b7x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, corrupt_hi = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_b7r #(.Enable(1'b1)) i_b7r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .x6x_i(x6x_in), .b1x_i(b1x_in), .cxr_i(cxr),
    .req_valid_i(b7r_req), .req_ready_o(b7r_rdy),
    .cpl_valid_o(b7r_cpl_v), .cpl_ready_i(b7r_cpl_r), .cpl_o(b7r_cpl), .b7r_o(b7r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_b7k #(.Enable(1'b1)) i_b7k (
    .clk_i(clk), .rst_ni, .b7r_i(b7r), .gbd_i(gbd),
    .req_valid_i(b7k_req), .req_ready_o(b7k_rdy),
    .cpl_valid_o(b7k_cpl_v), .cpl_ready_i(b7k_cpl_r), .cpl_o(b7k_cpl), .b7k_o(b7k)
  );
  g6lc_apu_vgpu_b7x #(.Enable(1'b1)) i_b7x (
    .clk_i(clk), .rst_ni, .b7k_i(b7k), .b0_i(b0),
    .req_valid_i(b7x_req), .req_ready_o(b7x_rdy),
    .cpl_valid_o(b7x_cpl_v), .cpl_ready_i(b7x_cpl_r), .cpl_o(b7x_cpl), .b7x_o(b7x)
  );
  g6lc_apu_vgpu_b7x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .b7k_i(b7k), .b0_i(b0),
    .req_valid_i(b7x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(b7x_cpl_r), .cpl_o(off_cpl), .b7x_o(off_b7x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu b7r timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_B7R_ADDR ||
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
    x6x_in = '0;
    x6x_in.valid = 1'b1;
    x6x_in.format = APU_VIRGL_FMT_B8G8R8X8;
    x6x_in.offset = APU_VGPU_X6R_AT;
    x6x_in.x = 7'd63;
    x6x_in.y = 7'd0;
    x6x_in.b0 = APU_VGPU_CLEAR_R;
    x6x_in.r = APU_VGPU_CLEAR_R;
    x6x_in.g = APU_VGPU_CLEAR_G;
    x6x_in.b = APU_VGPU_CLEAR_B;
    x6x_in.a = APU_VGPU_CLEAR_A;
    b1x_in = '0;
    b1x_in.valid = 1'b1;
    b1x_in.format = APU_VIRGL_FMT_B8G8R8X8;
    b1x_in.off8 = APU_VGPU_B1R_AT8;
    b1x_in.off15 = APU_VGPU_B1R_AT15;
    b1x_in.x8 = 7'd8;
    b1x_in.x15 = 7'd15;
    b1x_in.b0 = APU_VGPU_CLEAR_R;
    b1x_in.r = APU_VGPU_CLEAR_R;
    b1x_in.g = APU_VGPU_CLEAR_G;
    b1x_in.b = APU_VGPU_CLEAR_B;
    b1x_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_b7x == '0 &&
          off_cpl == '0);
  endtask

  task automatic b7r_step(input apu_vgpu_b7r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!b7r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    b7r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b7r_req = 1'b0;
    while (!b7r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b7r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_B7R_OK) begin
      check("beat", b7r.valid && b7r.off56 == 16'd224 && b7r.off63 == 16'd252 &&
            b7r.x56 == 7'd56 && b7r.x63 == 7'd63 &&
            b7r.r == 8'h0D && b7r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B7R_ADDR && seen == APU_VGPU_X6R_ADDR &&
            seen != APU_VGPU_GBW_ADDR && seen != APU_VGPU_B1R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B7R_ADDR && !b7r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), b7r_cpl_v);
    b7r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b7r_cpl_r = 1'b0;
    while (b7r_cpl_v) @(negedge clk);
  endtask

  task automatic b7k_step(input apu_vgpu_b7k_status_e st, input string name);
    @(negedge clk);
    while (!b7k_rdy) @(negedge clk);
    cases++;
    b7k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b7k_req = 1'b0;
    while (!b7k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b7k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b7k_cpl_v);
    b7k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b7k_cpl_r = 1'b0;
    while (b7k_cpl_v) @(negedge clk);
  endtask

  task automatic b7x_step(input apu_vgpu_b7x_status_e st, input string name);
    @(negedge clk);
    while (!b7x_rdy) @(negedge clk);
    cases++;
    b7x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b7x_req = 1'b0;
    while (!b7x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b7x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b7x_cpl_v);
    b7x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b7x_cpl_r = 1'b0;
    while (b7x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    b7r_req = 1'b0;
    b7k_req = 1'b0;
    b7x_req = 1'b0;
    b7r_cpl_r = 1'b0;
    b7k_cpl_r = 1'b0;
    b7x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    x6x_in = '0;
    b1x_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          b7r == '0 && b7k == '0 && b7x == '0);
    check("profiles keep the beat off",
          !ApuOff.B7rEn && !ApuOff.B7kEn && !ApuOff.B7xEn &&
          !ApuP1Transport.B7rEn && !ApuP1Transport.B7kEn && !ApuP1Transport.B7xEn &&
          !ApuHarness.B7rEn && !ApuHarness.B7kEn && !ApuHarness.B7xEn &&
          !ApuSchedBoth.B7rEn && !ApuSchedBoth.B7kEn && !ApuSchedBoth.B7xEn &&
          !ApuBadVirglGrant.B7rEn && !ApuBadVirglGrant.B7kEn &&
          !ApuBadVirglGrant.B7xEn);
    cfg = ApuP1Transport;
    cfg.B7rEn = 1'b1;
    cfg.B7kEn = 1'b1;
    cfg.B7xEn = 1'b1;
    check("beat does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.B7rEn = 1'b1;
    cfg.B7kEn = 1'b1;
    cfg.B7xEn = 1'b1;
    check("beat does not legalize virgl", !apu_cfg_legal(cfg));
    check("beat address",
          APU_VGPU_B7R_AT56 == 16'd224 &&
          (16'd56 << 2) == APU_VGPU_B7R_AT56 &&
          APU_VGPU_B7R_AT56 + 16'd28 == APU_VGPU_X6R_AT &&
          APU_VGPU_B7R_ADDR == 64'h0000_0000_8803_00E0 &&
          APU_VGPU_B7R_ADDR == APU_VGPU_X6R_ADDR &&
          APU_VGPU_GBW_ADDR + 64'd224 == APU_VGPU_B7R_ADDR &&
          APU_VGPU_B7R_ADDR != APU_VGPU_GBW_ADDR &&
          APU_VGPU_B7R_ADDR != APU_VGPU_B1R_ADDR);

    b7r_step(APU_VGPU_B7R_EMPTY, "beat empty");
    b7k_step(APU_VGPU_B7K_EMPTY, "keep empty");
    b7x_step(APU_VGPU_B7X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    b7r_step(APU_VGPU_B7R_FAULT, "bad scissor");
    good_in();
    x6x_in.offset = 16'd224;
    b7r_step(APU_VGPU_B7R_FAULT, "swapped corner");
    good_in();
    b1x_in.off8 = 16'd224;
    b7r_step(APU_VGPU_B7R_FAULT, "swapped beat");
    good_in();
    fail_rd = 1'b1;
    b7r_step(APU_VGPU_B7R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    b7r_step(APU_VGPU_B7R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_hi = 1'b1;
    corrupt_b = 8'h1A;
    b7r_step(APU_VGPU_B7R_FAULT, "blue byte");
    b7r_step(APU_VGPU_B7R_OK, "beat");
    b7r_step(APU_VGPU_B7R_FAULT, "beat again");
    check("beat stays", b7r.off56 == 16'd224 && b7r.off63 == 16'd252 &&
          b7r.x56 == 7'd56 && b7r.x63 == 7'd63 && b7r.r == 8'h0D);
    gbd.bytes = 32'd0;
    b7k_step(APU_VGPU_B7K_FAULT, "keep bad bytes");
    check("keep rejected", !b7k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    b7k_step(APU_VGPU_B7K_OK, "keep beat");
    check("beat kept", b7k.valid && b7k.off56 == 16'd224 && b7k.off63 == 16'd252 &&
          b7k.x56 == 7'd56 && b7k.x63 == 7'd63 &&
          {b7k.a, b7k.b, b7k.g, b7k.r} == APU_VGPU_CLEAR_WORD);
    b7k_step(APU_VGPU_B7K_FAULT, "keep again");
    b0 = 8'h1A;
    b7x_step(APU_VGPU_B7X_FAULT, "blue first");
    check("blue rejected", !b7x.valid);
    b0 = 8'hFF;
    b7x_step(APU_VGPU_B7X_FAULT, "high byte first");
    check("high byte rejected", !b7x.valid);
    b0 = 8'h0D;
    b7x_step(APU_VGPU_B7X_OK, "red first");
    check("red first", b7x.valid && b7x.b0 == 8'h0D && b7x.off56 == 16'd224 &&
          b7x.off63 == 16'd252 && b7x.x56 == 7'd56);
    b7x_step(APU_VGPU_B7X_FAULT, "order again");
    check("order stays", b7x.b0 == 8'h0D && b7x.off63 == 16'd252);

    pulse_reset();
    check("reset clears", b7r == '0 && b7k == '0 && b7x == '0);
    gbd = '0;
    x6x_in = '0;
    b1x_in = '0;
    cxr = '0;
    b7r_step(APU_VGPU_B7R_EMPTY, "after reset");
    b7k_step(APU_VGPU_B7K_EMPTY, "keep after reset");
    b7x_step(APU_VGPU_B7X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu b7r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_b7r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
