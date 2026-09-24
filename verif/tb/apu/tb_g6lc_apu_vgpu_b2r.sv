// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_b2r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_b7x_t b7x_in;
  apu_vgpu_cxr_t cxr;
  logic b2r_req = 0, b2r_rdy, b2r_cpl_v, b2r_cpl_r = 0;
  apu_vgpu_b2r_cpl_t b2r_cpl;
  apu_vgpu_b2r_t b2r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic b2k_req = 0, b2k_rdy, b2k_cpl_v, b2k_cpl_r = 0;
  apu_vgpu_b2k_cpl_t b2k_cpl;
  apu_vgpu_b2k_t b2k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic b2x_req = 0, b2x_rdy, b2x_cpl_v, b2x_cpl_r = 0;
  apu_vgpu_b2x_cpl_t b2x_cpl, off_cpl;
  apu_vgpu_b2x_t b2x, off_b2x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, corrupt_hi = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_b2r #(.Enable(1'b1)) i_b2r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .b7x_i(b7x_in), .cxr_i(cxr),
    .req_valid_i(b2r_req), .req_ready_o(b2r_rdy),
    .cpl_valid_o(b2r_cpl_v), .cpl_ready_i(b2r_cpl_r), .cpl_o(b2r_cpl), .b2r_o(b2r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_b2k #(.Enable(1'b1)) i_b2k (
    .clk_i(clk), .rst_ni, .b2r_i(b2r), .gbd_i(gbd),
    .req_valid_i(b2k_req), .req_ready_o(b2k_rdy),
    .cpl_valid_o(b2k_cpl_v), .cpl_ready_i(b2k_cpl_r), .cpl_o(b2k_cpl), .b2k_o(b2k)
  );
  g6lc_apu_vgpu_b2x #(.Enable(1'b1)) i_b2x (
    .clk_i(clk), .rst_ni, .b2k_i(b2k), .b0_i(b0),
    .req_valid_i(b2x_req), .req_ready_o(b2x_rdy),
    .cpl_valid_o(b2x_cpl_v), .cpl_ready_i(b2x_cpl_r), .cpl_o(b2x_cpl), .b2x_o(b2x)
  );
  g6lc_apu_vgpu_b2x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .b2k_i(b2k), .b0_i(b0),
    .req_valid_i(b2x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(b2x_cpl_r), .cpl_o(off_cpl), .b2x_o(off_b2x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu b2r timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_B2R_ADDR ||
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
    b7x_in = '0;
    b7x_in.valid = 1'b1;
    b7x_in.format = APU_VIRGL_FMT_B8G8R8X8;
    b7x_in.off56 = APU_VGPU_B7R_AT56;
    b7x_in.off63 = APU_VGPU_X6R_AT;
    b7x_in.x56 = 7'd56;
    b7x_in.x63 = 7'd63;
    b7x_in.b0 = APU_VGPU_CLEAR_R;
    b7x_in.r = APU_VGPU_CLEAR_R;
    b7x_in.g = APU_VGPU_CLEAR_G;
    b7x_in.b = APU_VGPU_CLEAR_B;
    b7x_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_b2x == '0 &&
          off_cpl == '0);
  endtask

  task automatic b2r_step(input apu_vgpu_b2r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!b2r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    b2r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b2r_req = 1'b0;
    while (!b2r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b2r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_B2R_OK) begin
      check("beat", b2r.valid && b2r.off16 == 16'd64 && b2r.off23 == 16'd92 &&
            b2r.x16 == 7'd16 && b2r.x23 == 7'd23 &&
            b2r.r == 8'h0D && b2r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B2R_ADDR && seen != APU_VGPU_GBW_ADDR &&
            seen != APU_VGPU_B1R_ADDR && seen != APU_VGPU_B7R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_B2R_ADDR && !b2r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), b2r_cpl_v);
    b2r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b2r_cpl_r = 1'b0;
    while (b2r_cpl_v) @(negedge clk);
  endtask

  task automatic b2k_step(input apu_vgpu_b2k_status_e st, input string name);
    @(negedge clk);
    while (!b2k_rdy) @(negedge clk);
    cases++;
    b2k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b2k_req = 1'b0;
    while (!b2k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b2k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b2k_cpl_v);
    b2k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b2k_cpl_r = 1'b0;
    while (b2k_cpl_v) @(negedge clk);
  endtask

  task automatic b2x_step(input apu_vgpu_b2x_status_e st, input string name);
    @(negedge clk);
    while (!b2x_rdy) @(negedge clk);
    cases++;
    b2x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b2x_req = 1'b0;
    while (!b2x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), b2x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), b2x_cpl_v);
    b2x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    b2x_cpl_r = 1'b0;
    while (b2x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    b2r_req = 1'b0;
    b2k_req = 1'b0;
    b2x_req = 1'b0;
    b2r_cpl_r = 1'b0;
    b2k_cpl_r = 1'b0;
    b2x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    b7x_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          b2r == '0 && b2k == '0 && b2x == '0);
    check("profiles keep the beat off",
          !ApuOff.B2rEn && !ApuOff.B2kEn && !ApuOff.B2xEn &&
          !ApuP1Transport.B2rEn && !ApuP1Transport.B2kEn && !ApuP1Transport.B2xEn &&
          !ApuHarness.B2rEn && !ApuHarness.B2kEn && !ApuHarness.B2xEn &&
          !ApuSchedBoth.B2rEn && !ApuSchedBoth.B2kEn && !ApuSchedBoth.B2xEn &&
          !ApuBadVirglGrant.B2rEn && !ApuBadVirglGrant.B2kEn &&
          !ApuBadVirglGrant.B2xEn);
    cfg = ApuP1Transport;
    cfg.B2rEn = 1'b1;
    cfg.B2kEn = 1'b1;
    cfg.B2xEn = 1'b1;
    check("beat does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.B2rEn = 1'b1;
    cfg.B2kEn = 1'b1;
    cfg.B2xEn = 1'b1;
    check("beat does not legalize virgl", !apu_cfg_legal(cfg));
    check("beat address",
          APU_VGPU_B2R_AT16 == 16'd64 &&
          APU_VGPU_B2R_AT23 == 16'd92 &&
          (16'd16 << 2) == APU_VGPU_B2R_AT16 &&
          (16'd23 << 2) == APU_VGPU_B2R_AT23 &&
          APU_VGPU_B2R_AT16 + 16'd28 == APU_VGPU_B2R_AT23 &&
          APU_VGPU_B2R_ADDR == 64'h0000_0000_8803_0040 &&
          APU_VGPU_GBW_ADDR + 64'd64 == APU_VGPU_B2R_ADDR &&
          APU_VGPU_B2R_ADDR != APU_VGPU_GBW_ADDR &&
          APU_VGPU_B2R_ADDR != APU_VGPU_B1R_ADDR &&
          APU_VGPU_B2R_ADDR != APU_VGPU_B7R_ADDR);

    b2r_step(APU_VGPU_B2R_EMPTY, "beat empty");
    b2k_step(APU_VGPU_B2K_EMPTY, "keep empty");
    b2x_step(APU_VGPU_B2X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    b2r_step(APU_VGPU_B2R_FAULT, "bad scissor");
    good_in();
    b7x_in.off56 = 16'd64;
    b2r_step(APU_VGPU_B2R_FAULT, "swapped beat");
    good_in();
    b7x_in.x56 = 7'd16;
    b2r_step(APU_VGPU_B2R_FAULT, "swapped point");
    good_in();
    fail_rd = 1'b1;
    b2r_step(APU_VGPU_B2R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    b2r_step(APU_VGPU_B2R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_hi = 1'b1;
    corrupt_b = 8'h1A;
    b2r_step(APU_VGPU_B2R_FAULT, "blue byte");
    b2r_step(APU_VGPU_B2R_OK, "beat");
    b2r_step(APU_VGPU_B2R_FAULT, "beat again");
    check("beat stays", b2r.off16 == 16'd64 && b2r.off23 == 16'd92 &&
          b2r.x16 == 7'd16 && b2r.x23 == 7'd23 && b2r.r == 8'h0D);
    gbd.bytes = 32'd0;
    b2k_step(APU_VGPU_B2K_FAULT, "keep bad bytes");
    check("keep rejected", !b2k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    b2k_step(APU_VGPU_B2K_OK, "keep beat");
    check("beat kept", b2k.valid && b2k.off16 == 16'd64 && b2k.off23 == 16'd92 &&
          b2k.x16 == 7'd16 && b2k.x23 == 7'd23 &&
          {b2k.a, b2k.b, b2k.g, b2k.r} == APU_VGPU_CLEAR_WORD);
    b2k_step(APU_VGPU_B2K_FAULT, "keep again");
    b0 = 8'h1A;
    b2x_step(APU_VGPU_B2X_FAULT, "blue first");
    check("blue rejected", !b2x.valid);
    b0 = 8'hFF;
    b2x_step(APU_VGPU_B2X_FAULT, "high byte first");
    check("high byte rejected", !b2x.valid);
    b0 = 8'h0D;
    b2x_step(APU_VGPU_B2X_OK, "red first");
    check("red first", b2x.valid && b2x.b0 == 8'h0D && b2x.off16 == 16'd64 &&
          b2x.off23 == 16'd92 && b2x.x16 == 7'd16);
    b2x_step(APU_VGPU_B2X_FAULT, "order again");
    check("order stays", b2x.b0 == 8'h0D && b2x.off23 == 16'd92);

    pulse_reset();
    check("reset clears", b2r == '0 && b2k == '0 && b2x == '0);
    gbd = '0;
    b7x_in = '0;
    cxr = '0;
    b2r_step(APU_VGPU_B2R_EMPTY, "after reset");
    b2k_step(APU_VGPU_B2K_EMPTY, "keep after reset");
    b2x_step(APU_VGPU_B2X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu b2r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_b2r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
