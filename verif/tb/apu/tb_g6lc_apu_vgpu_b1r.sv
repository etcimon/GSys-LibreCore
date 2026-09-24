// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_b1r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_p7x_t p7x_in;
  apu_vgpu_cxr_t cxr;
  logic b1r_req = 0, b1r_rdy, b1r_cpl_v, b1r_cpl_r = 0;
  apu_vgpu_b1r_cpl_t b1r_cpl;
  apu_vgpu_b1r_t b1r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic b1k_req = 0, b1k_rdy, b1k_cpl_v, b1k_cpl_r = 0;
  apu_vgpu_b1k_cpl_t b1k_cpl;
  apu_vgpu_b1k_t b1k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic b1x_req = 0, b1x_rdy, b1x_cpl_v, b1x_cpl_r = 0;
  apu_vgpu_b1x_cpl_t b1x_cpl, off_cpl;
  apu_vgpu_b1x_t b1x, off_b1x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, corrupt_hi = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_b1r #(.Enable(1'b1)) i_b1r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .p7x_i(p7x_in), .cxr_i(cxr),
    .req_valid_i(b1r_req), .req_ready_o(b1r_rdy),
    .cpl_valid_o(b1r_cpl_v), .cpl_ready_i(b1r_cpl_r), .cpl_o(b1r_cpl), .b1r_o(b1r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_b1k #(.Enable(1'b1)) i_b1k (
    .clk_i(clk), .rst_ni, .b1r_i(b1r), .gbd_i(gbd),
    .req_valid_i(b1k_req), .req_ready_o(b1k_rdy),
    .cpl_valid_o(b1k_cpl_v), .cpl_ready_i(b1k_cpl_r), .cpl_o(b1k_cpl), .b1k_o(b1k)
  );
  g6lc_apu_vgpu_b1x #(.Enable(1'b1)) i_b1x (
    .clk_i(clk), .rst_ni, .b1k_i(b1k), .b0_i(b0),
    .req_valid_i(b1x_req), .req_ready_o(b1x_rdy),
    .cpl_valid_o(b1x_cpl_v), .cpl_ready_i(b1x_cpl_r), .cpl_o(b1x_cpl), .b1x_o(b1x)
  );
  g6lc_apu_vgpu_b1x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .b1k_i(b1k), .b0_i(b0),
    .req_valid_i(b1x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(b1x_cpl_r), .cpl_o(off_cpl), .b1x_o(off_b1x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu b1r timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_B1R_ADDR ||
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
    p7x_in = '0;
    p7x_in.valid = 1'b1;
    p7x_in.format = APU_VIRGL_FMT_B8G8R8X8;
    p7x_in.offset = APU_VGPU_P7R_AT;
    p7x_in.x = 7'd7;
    p7x_in.y = 7'd0;
    p7x_in.b0 = APU_VGPU_CLEAR_R;
    p7x_in.r = APU_VGPU_CLEAR_R;
    p7x_in.g = APU_VGPU_CLEAR_G;
    p7x_in.b = APU_VGPU_CLEAR_B;
    p7x_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_b1x == '0 &&
          off_cpl == '0);
  endtask

  task automatic b1r_step(input apu_vgpu_b1r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!b1r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    b1r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b1r_req = 1'b0;
    while (!b1r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b1r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_B1R_OK) begin
      check("beat", b1r.valid && b1r.off8 == 16'd32 && b1r.off15 == 16'd60 &&
            b1r.x8 == 7'd8 && b1r.x15 == 7'd15 &&
            b1r.r == 8'h0D && b1r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B1R_ADDR && seen != APU_VGPU_GBW_ADDR &&
            seen != APU_VGPU_X6R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B1R_ADDR && !b1r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), b1r_cpl_v);
    b1r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b1r_cpl_r = 1'b0;
    while (b1r_cpl_v) @(negedge clk);
  endtask

  task automatic b1k_step(input apu_vgpu_b1k_status_e st, input string name);
    @(negedge clk);
    while (!b1k_rdy) @(negedge clk);
    cases++;
    b1k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b1k_req = 1'b0;
    while (!b1k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b1k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b1k_cpl_v);
    b1k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b1k_cpl_r = 1'b0;
    while (b1k_cpl_v) @(negedge clk);
  endtask

  task automatic b1x_step(input apu_vgpu_b1x_status_e st, input string name);
    @(negedge clk);
    while (!b1x_rdy) @(negedge clk);
    cases++;
    b1x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b1x_req = 1'b0;
    while (!b1x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b1x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b1x_cpl_v);
    b1x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b1x_cpl_r = 1'b0;
    while (b1x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    b1r_req = 1'b0;
    b1k_req = 1'b0;
    b1x_req = 1'b0;
    b1r_cpl_r = 1'b0;
    b1k_cpl_r = 1'b0;
    b1x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    p7x_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          b1r == '0 && b1k == '0 && b1x == '0);
    check("profiles keep the beat off",
          !ApuOff.B1rEn && !ApuOff.B1kEn && !ApuOff.B1xEn &&
          !ApuP1Transport.B1rEn && !ApuP1Transport.B1kEn && !ApuP1Transport.B1xEn &&
          !ApuHarness.B1rEn && !ApuHarness.B1kEn && !ApuHarness.B1xEn &&
          !ApuSchedBoth.B1rEn && !ApuSchedBoth.B1kEn && !ApuSchedBoth.B1xEn &&
          !ApuBadVirglGrant.B1rEn && !ApuBadVirglGrant.B1kEn &&
          !ApuBadVirglGrant.B1xEn);
    cfg = ApuP1Transport;
    cfg.B1rEn = 1'b1;
    cfg.B1kEn = 1'b1;
    cfg.B1xEn = 1'b1;
    check("beat does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.B1rEn = 1'b1;
    cfg.B1kEn = 1'b1;
    cfg.B1xEn = 1'b1;
    check("beat does not legalize virgl", !apu_cfg_legal(cfg));
    check("beat address",
          APU_VGPU_B1R_AT8 == 16'd32 &&
          APU_VGPU_B1R_AT15 == 16'd60 &&
          (16'd8 << 2) == APU_VGPU_B1R_AT8 &&
          (16'd15 << 2) == APU_VGPU_B1R_AT15 &&
          APU_VGPU_B1R_ADDR == 64'h0000_0000_8803_0020 &&
          APU_VGPU_GBW_ADDR + 64'd32 == APU_VGPU_B1R_ADDR &&
          APU_VGPU_B1R_ADDR != APU_VGPU_GBW_ADDR &&
          APU_VGPU_B1R_ADDR != APU_VGPU_X6R_ADDR &&
          APU_VGPU_B1R_AT8 != APU_VGPU_P7R_AT);

    b1r_step(APU_VGPU_B1R_EMPTY, "beat empty");
    b1k_step(APU_VGPU_B1K_EMPTY, "keep empty");
    b1x_step(APU_VGPU_B1X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    b1r_step(APU_VGPU_B1R_FAULT, "bad scissor");
    good_in();
    p7x_in.offset = 16'd32;
    b1r_step(APU_VGPU_B1R_FAULT, "swapped beat");
    good_in();
    gbd.height = 16'd480;
    b1r_step(APU_VGPU_B1R_FAULT, "tall rectangle");
    good_in();
    fail_rd = 1'b1;
    b1r_step(APU_VGPU_B1R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    b1r_step(APU_VGPU_B1R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_hi = 1'b1;
    corrupt_b = 8'h1A;
    b1r_step(APU_VGPU_B1R_FAULT, "blue byte");
    b1r_step(APU_VGPU_B1R_OK, "beat");
    b1r_step(APU_VGPU_B1R_FAULT, "beat again");
    check("beat stays", b1r.off8 == 16'd32 && b1r.off15 == 16'd60 &&
          b1r.x8 == 7'd8 && b1r.x15 == 7'd15 && b1r.r == 8'h0D);
    gbd.bytes = 32'd0;
    b1k_step(APU_VGPU_B1K_FAULT, "keep bad bytes");
    check("keep rejected", !b1k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    b1k_step(APU_VGPU_B1K_OK, "keep beat");
    check("beat kept", b1k.valid && b1k.off8 == 16'd32 && b1k.off15 == 16'd60 &&
          b1k.x8 == 7'd8 && b1k.x15 == 7'd15 &&
          {b1k.a, b1k.b, b1k.g, b1k.r} == APU_VGPU_CLEAR_WORD);
    b1k_step(APU_VGPU_B1K_FAULT, "keep again");
    b0 = 8'h1A;
    b1x_step(APU_VGPU_B1X_FAULT, "blue first");
    check("blue rejected", !b1x.valid);
    b0 = 8'hFF;
    b1x_step(APU_VGPU_B1X_FAULT, "high byte first");
    check("high byte rejected", !b1x.valid);
    b0 = 8'h0D;
    b1x_step(APU_VGPU_B1X_OK, "red first");
    check("red first", b1x.valid && b1x.b0 == 8'h0D && b1x.off8 == 16'd32 &&
          b1x.off15 == 16'd60 && b1x.x8 == 7'd8);
    b1x_step(APU_VGPU_B1X_FAULT, "order again");
    check("order stays", b1x.b0 == 8'h0D && b1x.off15 == 16'd60);

    pulse_reset();
    check("reset clears", b1r == '0 && b1k == '0 && b1x == '0);
    gbd = '0;
    p7x_in = '0;
    cxr = '0;
    b1r_step(APU_VGPU_B1R_EMPTY, "after reset");
    b1k_step(APU_VGPU_B1K_EMPTY, "keep after reset");
    b1x_step(APU_VGPU_B1X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu b1r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_b1r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
