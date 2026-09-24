// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_x6r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_tpx_t tpx_in;
  apu_vgpu_cxr_t cxr;
  logic x6r_req = 0, x6r_rdy, x6r_cpl_v, x6r_cpl_r = 0;
  apu_vgpu_x6r_cpl_t x6r_cpl;
  apu_vgpu_x6r_t x6r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic x6k_req = 0, x6k_rdy, x6k_cpl_v, x6k_cpl_r = 0;
  apu_vgpu_x6k_cpl_t x6k_cpl;
  apu_vgpu_x6k_t x6k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic x6x_req = 0, x6x_rdy, x6x_cpl_v, x6x_cpl_r = 0;
  apu_vgpu_x6x_cpl_t x6x_cpl, off_cpl;
  apu_vgpu_x6x_t x6x, off_x6x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_x6r #(.Enable(1'b1)) i_x6r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .tpx_i(tpx_in), .cxr_i(cxr),
    .req_valid_i(x6r_req), .req_ready_o(x6r_rdy),
    .cpl_valid_o(x6r_cpl_v), .cpl_ready_i(x6r_cpl_r), .cpl_o(x6r_cpl), .x6r_o(x6r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_x6k #(.Enable(1'b1)) i_x6k (
    .clk_i(clk), .rst_ni, .x6r_i(x6r), .gbd_i(gbd),
    .req_valid_i(x6k_req), .req_ready_o(x6k_rdy),
    .cpl_valid_o(x6k_cpl_v), .cpl_ready_i(x6k_cpl_r), .cpl_o(x6k_cpl), .x6k_o(x6k)
  );
  g6lc_apu_vgpu_x6x #(.Enable(1'b1)) i_x6x (
    .clk_i(clk), .rst_ni, .x6k_i(x6k), .b0_i(b0),
    .req_valid_i(x6x_req), .req_ready_o(x6x_rdy),
    .cpl_valid_o(x6x_cpl_v), .cpl_ready_i(x6x_cpl_r), .cpl_o(x6x_cpl), .x6x_o(x6x)
  );
  g6lc_apu_vgpu_x6x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .x6k_i(x6k), .b0_i(b0),
    .req_valid_i(x6x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(x6x_cpl_r), .cpl_o(off_cpl), .x6x_o(off_x6x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu x6r timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (corrupt) beat[231:224] = corrupt_b;
      if (rd_addr != APU_VGPU_X6R_ADDR ||
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
    tpx_in = '0;
    tpx_in.valid = 1'b1;
    tpx_in.format = APU_VIRGL_FMT_B8G8R8X8;
    tpx_in.off11 = APU_VGPU_TPR_AT11;
    tpx_in.off23 = APU_VGPU_TPR_AT23;
    tpx_in.off063 = APU_VGPU_TPR_AT063;
    tpx_in.b0 = APU_VGPU_CLEAR_R;
    tpx_in.r = APU_VGPU_CLEAR_R;
    tpx_in.g = APU_VGPU_CLEAR_G;
    tpx_in.b = APU_VGPU_CLEAR_B;
    tpx_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_x6x == '0 &&
          off_cpl == '0);
  endtask

  task automatic x6r_step(input apu_vgpu_x6r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!x6r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    x6r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    x6r_req = 1'b0;
    while (!x6r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), x6r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_X6R_OK) begin
      check("corner", x6r.valid && x6r.offset == 16'd252 &&
            x6r.x == 7'd63 && x6r.y == 7'd0 &&
            x6r.r == 8'h0D && x6r.g == 8'h0D && x6r.b == 8'h1A &&
            x6r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_X6R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_X6R_ADDR && !x6r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), x6r_cpl_v);
    x6r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    x6r_cpl_r = 1'b0;
    while (x6r_cpl_v) @(negedge clk);
  endtask

  task automatic x6k_step(input apu_vgpu_x6k_status_e st, input string name);
    @(negedge clk);
    while (!x6k_rdy) @(negedge clk);
    cases++;
    x6k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    x6k_req = 1'b0;
    while (!x6k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), x6k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), x6k_cpl_v);
    x6k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    x6k_cpl_r = 1'b0;
    while (x6k_cpl_v) @(negedge clk);
  endtask

  task automatic x6x_step(input apu_vgpu_x6x_status_e st, input string name);
    @(negedge clk);
    while (!x6x_rdy) @(negedge clk);
    cases++;
    x6x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    x6x_req = 1'b0;
    while (!x6x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), x6x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), x6x_cpl_v);
    x6x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    x6x_cpl_r = 1'b0;
    while (x6x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    x6r_req = 1'b0;
    x6k_req = 1'b0;
    x6x_req = 1'b0;
    x6r_cpl_r = 1'b0;
    x6k_cpl_r = 1'b0;
    x6x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    tpx_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          x6r == '0 && x6k == '0 && x6x == '0);
    check("profiles keep the corner off",
          !ApuOff.X6rEn && !ApuOff.X6kEn && !ApuOff.X6xEn &&
          !ApuP1Transport.X6rEn && !ApuP1Transport.X6kEn && !ApuP1Transport.X6xEn &&
          !ApuHarness.X6rEn && !ApuHarness.X6kEn && !ApuHarness.X6xEn &&
          !ApuSchedBoth.X6rEn && !ApuSchedBoth.X6kEn && !ApuSchedBoth.X6xEn &&
          !ApuBadVirglGrant.X6rEn && !ApuBadVirglGrant.X6kEn &&
          !ApuBadVirglGrant.X6xEn);
    cfg = ApuP1Transport;
    cfg.X6rEn = 1'b1;
    cfg.X6kEn = 1'b1;
    cfg.X6xEn = 1'b1;
    check("corner does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.X6rEn = 1'b1;
    cfg.X6kEn = 1'b1;
    cfg.X6xEn = 1'b1;
    check("corner does not legalize virgl", !apu_cfg_legal(cfg));
    check("corner offset",
          APU_VGPU_X6R_AT == 16'd252 &&
          APU_VGPU_X6R_AT == 16'(APU_VGPU_PIX_X) &&
          (16'd63 << 2) == APU_VGPU_X6R_AT &&
          APU_VGPU_TPR_AT063 == 16'd16128 &&
          APU_VGPU_X6R_AT != APU_VGPU_TPR_AT063 &&
          APU_VGPU_GBW_ADDR == 64'h0000_0000_8803_0000 &&
          APU_VGPU_X6R_ADDR == 64'h0000_0000_8803_00E0 &&
          APU_VGPU_GBW_ADDR + 64'd224 == APU_VGPU_X6R_ADDR &&
          APU_VGPU_X6R_ADDR != APU_VGPU_GBW_ADDR);

    x6r_step(APU_VGPU_X6R_EMPTY, "corner empty");
    x6k_step(APU_VGPU_X6K_EMPTY, "keep empty");
    x6x_step(APU_VGPU_X6X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    x6r_step(APU_VGPU_X6R_FAULT, "bad scissor");
    good_in();
    tpx_in.off063 = 16'd252;
    x6r_step(APU_VGPU_X6R_FAULT, "swapped corner");
    good_in();
    gbd.height = 16'd480;
    x6r_step(APU_VGPU_X6R_FAULT, "tall rectangle");
    good_in();
    fail_rd = 1'b1;
    x6r_step(APU_VGPU_X6R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    x6r_step(APU_VGPU_X6R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_b = 8'h1A;
    x6r_step(APU_VGPU_X6R_FAULT, "blue byte");
    x6r_step(APU_VGPU_X6R_OK, "corner");
    x6r_step(APU_VGPU_X6R_FAULT, "corner again");
    check("corner stays", x6r.offset == 16'd252 && x6r.x == 7'd63 &&
          x6r.y == 7'd0 && x6r.r == 8'h0D);
    gbd.bytes = 32'd0;
    x6k_step(APU_VGPU_X6K_FAULT, "keep bad bytes");
    check("keep rejected", !x6k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    x6k_step(APU_VGPU_X6K_OK, "keep corner");
    check("corner kept", x6k.valid && x6k.offset == 16'd252 &&
          x6k.x == 7'd63 && x6k.y == 7'd0 &&
          {x6k.a, x6k.b, x6k.g, x6k.r} == APU_VGPU_CLEAR_WORD);
    x6k_step(APU_VGPU_X6K_FAULT, "keep again");
    b0 = 8'h1A;
    x6x_step(APU_VGPU_X6X_FAULT, "blue first");
    check("blue rejected", !x6x.valid);
    b0 = 8'hFF;
    x6x_step(APU_VGPU_X6X_FAULT, "high byte first");
    check("high byte rejected", !x6x.valid);
    b0 = 8'h0D;
    x6x_step(APU_VGPU_X6X_OK, "red first");
    check("red first", x6x.valid && x6x.b0 == 8'h0D && x6x.b0 != 8'h1A &&
          x6x.offset == 16'd252 && x6x.x == 7'd63 && x6x.y == 7'd0);
    x6x_step(APU_VGPU_X6X_FAULT, "order again");
    check("order stays", x6x.b0 == 8'h0D && x6x.offset == 16'd252);

    pulse_reset();
    check("reset clears", x6r == '0 && x6k == '0 && x6x == '0);
    gbd = '0;
    tpx_in = '0;
    cxr = '0;
    x6r_step(APU_VGPU_X6R_EMPTY, "after reset");
    x6k_step(APU_VGPU_X6K_EMPTY, "keep after reset");
    x6x_step(APU_VGPU_X6X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu x6r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_x6r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
