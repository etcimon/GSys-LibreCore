// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_b3r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_b2x_t b2x_in;
  apu_vgpu_cxr_t cxr;
  logic b3r_req = 0, b3r_rdy, b3r_cpl_v, b3r_cpl_r = 0;
  apu_vgpu_b3r_cpl_t b3r_cpl;
  apu_vgpu_b3r_t b3r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic b3k_req = 0, b3k_rdy, b3k_cpl_v, b3k_cpl_r = 0;
  apu_vgpu_b3k_cpl_t b3k_cpl;
  apu_vgpu_b3k_t b3k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic b3x_req = 0, b3x_rdy, b3x_cpl_v, b3x_cpl_r = 0;
  apu_vgpu_b3x_cpl_t b3x_cpl, off_cpl;
  apu_vgpu_b3x_t b3x, off_b3x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, corrupt_hi = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_b3r #(.Enable(1'b1)) i_b3r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .b2x_i(b2x_in), .cxr_i(cxr),
    .req_valid_i(b3r_req), .req_ready_o(b3r_rdy),
    .cpl_valid_o(b3r_cpl_v), .cpl_ready_i(b3r_cpl_r), .cpl_o(b3r_cpl), .b3r_o(b3r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_b3k #(.Enable(1'b1)) i_b3k (
    .clk_i(clk), .rst_ni, .b3r_i(b3r), .gbd_i(gbd),
    .req_valid_i(b3k_req), .req_ready_o(b3k_rdy),
    .cpl_valid_o(b3k_cpl_v), .cpl_ready_i(b3k_cpl_r), .cpl_o(b3k_cpl), .b3k_o(b3k)
  );
  g6lc_apu_vgpu_b3x #(.Enable(1'b1)) i_b3x (
    .clk_i(clk), .rst_ni, .b3k_i(b3k), .b0_i(b0),
    .req_valid_i(b3x_req), .req_ready_o(b3x_rdy),
    .cpl_valid_o(b3x_cpl_v), .cpl_ready_i(b3x_cpl_r), .cpl_o(b3x_cpl), .b3x_o(b3x)
  );
  g6lc_apu_vgpu_b3x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .b3k_i(b3k), .b0_i(b0),
    .req_valid_i(b3x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(b3x_cpl_r), .cpl_o(off_cpl), .b3x_o(off_b3x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu b3r timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_B3R_ADDR ||
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
    b2x_in = '0;
    b2x_in.valid = 1'b1;
    b2x_in.format = APU_VIRGL_FMT_B8G8R8X8;
    b2x_in.off16 = APU_VGPU_B2R_AT16;
    b2x_in.off23 = APU_VGPU_B2R_AT23;
    b2x_in.x16 = 7'd16;
    b2x_in.x23 = 7'd23;
    b2x_in.b0 = APU_VGPU_CLEAR_R;
    b2x_in.r = APU_VGPU_CLEAR_R;
    b2x_in.g = APU_VGPU_CLEAR_G;
    b2x_in.b = APU_VGPU_CLEAR_B;
    b2x_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_b3x == '0 &&
          off_cpl == '0);
  endtask

  task automatic b3r_step(input apu_vgpu_b3r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!b3r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    b3r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b3r_req = 1'b0;
    while (!b3r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b3r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_B3R_OK) begin
      check("beat", b3r.valid && b3r.off24 == 16'd96 && b3r.off31 == 16'd124 &&
            b3r.x24 == 7'd24 && b3r.x31 == 7'd31 &&
            b3r.r == 8'h0D && b3r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B3R_ADDR && seen != APU_VGPU_GBW_ADDR &&
            seen != APU_VGPU_B2R_ADDR && seen != APU_VGPU_B1R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B3R_ADDR && !b3r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), b3r_cpl_v);
    b3r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b3r_cpl_r = 1'b0;
    while (b3r_cpl_v) @(negedge clk);
  endtask

  task automatic b3k_step(input apu_vgpu_b3k_status_e st, input string name);
    @(negedge clk);
    while (!b3k_rdy) @(negedge clk);
    cases++;
    b3k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b3k_req = 1'b0;
    while (!b3k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b3k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b3k_cpl_v);
    b3k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b3k_cpl_r = 1'b0;
    while (b3k_cpl_v) @(negedge clk);
  endtask

  task automatic b3x_step(input apu_vgpu_b3x_status_e st, input string name);
    @(negedge clk);
    while (!b3x_rdy) @(negedge clk);
    cases++;
    b3x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b3x_req = 1'b0;
    while (!b3x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b3x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b3x_cpl_v);
    b3x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b3x_cpl_r = 1'b0;
    while (b3x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    b3r_req = 1'b0;
    b3k_req = 1'b0;
    b3x_req = 1'b0;
    b3r_cpl_r = 1'b0;
    b3k_cpl_r = 1'b0;
    b3x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    b2x_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          b3r == '0 && b3k == '0 && b3x == '0);
    check("profiles keep the beat off",
          !ApuOff.B3rEn && !ApuOff.B3kEn && !ApuOff.B3xEn &&
          !ApuP1Transport.B3rEn && !ApuP1Transport.B3kEn && !ApuP1Transport.B3xEn &&
          !ApuHarness.B3rEn && !ApuHarness.B3kEn && !ApuHarness.B3xEn &&
          !ApuSchedBoth.B3rEn && !ApuSchedBoth.B3kEn && !ApuSchedBoth.B3xEn &&
          !ApuBadVirglGrant.B3rEn && !ApuBadVirglGrant.B3kEn &&
          !ApuBadVirglGrant.B3xEn);
    cfg = ApuP1Transport;
    cfg.B3rEn = 1'b1;
    cfg.B3kEn = 1'b1;
    cfg.B3xEn = 1'b1;
    check("beat does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.B3rEn = 1'b1;
    cfg.B3kEn = 1'b1;
    cfg.B3xEn = 1'b1;
    check("beat does not legalize virgl", !apu_cfg_legal(cfg));
    check("beat address",
          APU_VGPU_B3R_AT24 == 16'd96 &&
          APU_VGPU_B3R_AT31 == 16'd124 &&
          (16'd24 << 2) == APU_VGPU_B3R_AT24 &&
          (16'd31 << 2) == APU_VGPU_B3R_AT31 &&
          APU_VGPU_B3R_AT24 + 16'd28 == APU_VGPU_B3R_AT31 &&
          APU_VGPU_B3R_ADDR == 64'h0000_0000_8803_0060 &&
          APU_VGPU_GBW_ADDR + 64'd96 == APU_VGPU_B3R_ADDR &&
          APU_VGPU_B3R_ADDR != APU_VGPU_GBW_ADDR &&
          APU_VGPU_B3R_ADDR != APU_VGPU_B2R_ADDR &&
          APU_VGPU_B3R_ADDR != APU_VGPU_B1R_ADDR);

    b3r_step(APU_VGPU_B3R_EMPTY, "beat empty");
    b3k_step(APU_VGPU_B3K_EMPTY, "keep empty");
    b3x_step(APU_VGPU_B3X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    b3r_step(APU_VGPU_B3R_FAULT, "bad scissor");
    good_in();
    b2x_in.off16 = 16'd96;
    b3r_step(APU_VGPU_B3R_FAULT, "swapped beat");
    good_in();
    b2x_in.x16 = 7'd24;
    b3r_step(APU_VGPU_B3R_FAULT, "swapped point");
    good_in();
    fail_rd = 1'b1;
    b3r_step(APU_VGPU_B3R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    b3r_step(APU_VGPU_B3R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_hi = 1'b1;
    corrupt_b = 8'h1A;
    b3r_step(APU_VGPU_B3R_FAULT, "blue byte");
    b3r_step(APU_VGPU_B3R_OK, "beat");
    b3r_step(APU_VGPU_B3R_FAULT, "beat again");
    check("beat stays", b3r.off24 == 16'd96 && b3r.off31 == 16'd124 &&
          b3r.x24 == 7'd24 && b3r.x31 == 7'd31 && b3r.r == 8'h0D);
    gbd.bytes = 32'd0;
    b3k_step(APU_VGPU_B3K_FAULT, "keep bad bytes");
    check("keep rejected", !b3k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    b3k_step(APU_VGPU_B3K_OK, "keep beat");
    check("beat kept", b3k.valid && b3k.off24 == 16'd96 && b3k.off31 == 16'd124 &&
          b3k.x24 == 7'd24 && b3k.x31 == 7'd31 &&
          {b3k.a, b3k.b, b3k.g, b3k.r} == APU_VGPU_CLEAR_WORD);
    b3k_step(APU_VGPU_B3K_FAULT, "keep again");
    b0 = 8'h1A;
    b3x_step(APU_VGPU_B3X_FAULT, "blue first");
    check("blue rejected", !b3x.valid);
    b0 = 8'hFF;
    b3x_step(APU_VGPU_B3X_FAULT, "high byte first");
    check("high byte rejected", !b3x.valid);
    b0 = 8'h0D;
    b3x_step(APU_VGPU_B3X_OK, "red first");
    check("red first", b3x.valid && b3x.b0 == 8'h0D && b3x.off24 == 16'd96 &&
          b3x.off31 == 16'd124 && b3x.x24 == 7'd24);
    b3x_step(APU_VGPU_B3X_FAULT, "order again");
    check("order stays", b3x.b0 == 8'h0D && b3x.off31 == 16'd124);

    pulse_reset();
    check("reset clears", b3r == '0 && b3k == '0 && b3x == '0);
    gbd = '0;
    b2x_in = '0;
    cxr = '0;
    b3r_step(APU_VGPU_B3R_EMPTY, "after reset");
    b3k_step(APU_VGPU_B3K_EMPTY, "keep after reset");
    b3x_step(APU_VGPU_B3X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu b3r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_b3r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
