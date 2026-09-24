// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_p7r;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_x6x_t x6x_in;
  apu_vgpu_tcx_t tcx_in;
  apu_vgpu_cxr_t cxr;
  logic p7r_req = 0, p7r_rdy, p7r_cpl_v, p7r_cpl_r = 0;
  apu_vgpu_p7r_cpl_t p7r_cpl;
  apu_vgpu_p7r_t p7r;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic p7k_req = 0, p7k_rdy, p7k_cpl_v, p7k_cpl_r = 0;
  apu_vgpu_p7k_cpl_t p7k_cpl;
  apu_vgpu_p7k_t p7k;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic p7x_req = 0, p7x_rdy, p7x_cpl_v, p7x_cpl_r = 0;
  apu_vgpu_p7x_cpl_t p7x_cpl, off_cpl;
  apu_vgpu_p7x_t p7x, off_p7x;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_p7r #(.Enable(1'b1)) i_p7r (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .x6x_i(x6x_in), .tcx_i(tcx_in), .cxr_i(cxr),
    .req_valid_i(p7r_req), .req_ready_o(p7r_rdy),
    .cpl_valid_o(p7r_cpl_v), .cpl_ready_i(p7r_cpl_r), .cpl_o(p7r_cpl), .p7r_o(p7r),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_p7k #(.Enable(1'b1)) i_p7k (
    .clk_i(clk), .rst_ni, .p7r_i(p7r), .gbd_i(gbd),
    .req_valid_i(p7k_req), .req_ready_o(p7k_rdy),
    .cpl_valid_o(p7k_cpl_v), .cpl_ready_i(p7k_cpl_r), .cpl_o(p7k_cpl), .p7k_o(p7k)
  );
  g6lc_apu_vgpu_p7x #(.Enable(1'b1)) i_p7x (
    .clk_i(clk), .rst_ni, .p7k_i(p7k), .b0_i(b0),
    .req_valid_i(p7x_req), .req_ready_o(p7x_rdy),
    .cpl_valid_o(p7x_cpl_v), .cpl_ready_i(p7x_cpl_r), .cpl_o(p7x_cpl), .p7x_o(p7x)
  );
  g6lc_apu_vgpu_p7x_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .p7k_i(p7k), .b0_i(b0),
    .req_valid_i(p7x_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(p7x_cpl_r), .cpl_o(off_cpl), .p7x_o(off_p7x)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu p7r timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_P7R_ADDR ||
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
    tcx_in = '0;
    tcx_in.valid = 1'b1;
    tcx_in.format = APU_VIRGL_FMT_B8G8R8X8;
    tcx_in.offset = APU_VGPU_GOF_LAST;
    tcx_in.x = 7'd63;
    tcx_in.y = 7'd63;
    tcx_in.b0 = APU_VGPU_CLEAR_R;
    tcx_in.r = APU_VGPU_CLEAR_R;
    tcx_in.g = APU_VGPU_CLEAR_G;
    tcx_in.b = APU_VGPU_CLEAR_B;
    tcx_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_p7x == '0 &&
          off_cpl == '0);
  endtask

  task automatic p7r_step(input apu_vgpu_p7r_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!p7r_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    p7r_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    p7r_req = 1'b0;
    while (!p7r_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), p7r_cpl.status == st);
    quiet();
    if (st == APU_VGPU_P7R_OK) begin
      check("point", p7r.valid && p7r.offset == 16'd28 &&
            p7r.x == 7'd7 && p7r.y == 7'd0 &&
            p7r.r == 8'h0D && p7r.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_GBW_ADDR && seen != APU_VGPU_X6R_ADDR);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_P7R_ADDR && !p7r.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), p7r_cpl_v);
    p7r_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    p7r_cpl_r = 1'b0;
    while (p7r_cpl_v) @(negedge clk);
  endtask

  task automatic p7k_step(input apu_vgpu_p7k_status_e st, input string name);
    @(negedge clk);
    while (!p7k_rdy) @(negedge clk);
    cases++;
    p7k_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    p7k_req = 1'b0;
    while (!p7k_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), p7k_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), p7k_cpl_v);
    p7k_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    p7k_cpl_r = 1'b0;
    while (p7k_cpl_v) @(negedge clk);
  endtask

  task automatic p7x_step(input apu_vgpu_p7x_status_e st, input string name);
    @(negedge clk);
    while (!p7x_rdy) @(negedge clk);
    cases++;
    p7x_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    p7x_req = 1'b0;
    while (!p7x_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), p7x_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), p7x_cpl_v);
    p7x_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    p7x_cpl_r = 1'b0;
    while (p7x_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    p7r_req = 1'b0;
    p7k_req = 1'b0;
    p7x_req = 1'b0;
    p7r_cpl_r = 1'b0;
    p7k_cpl_r = 1'b0;
    p7x_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    x6x_in = '0;
    tcx_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          p7r == '0 && p7k == '0 && p7x == '0);
    check("profiles keep the point off",
          !ApuOff.P7rEn && !ApuOff.P7kEn && !ApuOff.P7xEn &&
          !ApuP1Transport.P7rEn && !ApuP1Transport.P7kEn && !ApuP1Transport.P7xEn &&
          !ApuHarness.P7rEn && !ApuHarness.P7kEn && !ApuHarness.P7xEn &&
          !ApuSchedBoth.P7rEn && !ApuSchedBoth.P7kEn && !ApuSchedBoth.P7xEn &&
          !ApuBadVirglGrant.P7rEn && !ApuBadVirglGrant.P7kEn &&
          !ApuBadVirglGrant.P7xEn);
    cfg = ApuP1Transport;
    cfg.P7rEn = 1'b1;
    cfg.P7kEn = 1'b1;
    cfg.P7xEn = 1'b1;
    check("point does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.P7rEn = 1'b1;
    cfg.P7kEn = 1'b1;
    cfg.P7xEn = 1'b1;
    check("point does not legalize virgl", !apu_cfg_legal(cfg));
    check("point offset",
          APU_VGPU_P7R_AT == 16'd28 &&
          (16'd7 << 2) == APU_VGPU_P7R_AT &&
          APU_VGPU_P7R_ADDR == APU_VGPU_GBW_ADDR &&
          APU_VGPU_P7R_ADDR == 64'h0000_0000_8803_0000 &&
          APU_VGPU_X6R_ADDR == 64'h0000_0000_8803_00E0 &&
          APU_VGPU_P7R_ADDR != APU_VGPU_X6R_ADDR &&
          APU_VGPU_P7R_AT != APU_VGPU_X6R_AT);

    p7r_step(APU_VGPU_P7R_EMPTY, "point empty");
    p7k_step(APU_VGPU_P7K_EMPTY, "keep empty");
    p7x_step(APU_VGPU_P7X_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    p7r_step(APU_VGPU_P7R_FAULT, "bad scissor");
    good_in();
    x6x_in.offset = 16'd28;
    p7r_step(APU_VGPU_P7R_FAULT, "swapped beat");
    good_in();
    tcx_in.y = 7'd0;
    p7r_step(APU_VGPU_P7R_FAULT, "swapped row");
    good_in();
    fail_rd = 1'b1;
    p7r_step(APU_VGPU_P7R_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    p7r_step(APU_VGPU_P7R_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_b = 8'h1A;
    p7r_step(APU_VGPU_P7R_FAULT, "blue byte");
    p7r_step(APU_VGPU_P7R_OK, "point");
    p7r_step(APU_VGPU_P7R_FAULT, "point again");
    check("point stays", p7r.offset == 16'd28 && p7r.x == 7'd7 &&
          p7r.y == 7'd0 && p7r.r == 8'h0D);
    gbd.bytes = 32'd0;
    p7k_step(APU_VGPU_P7K_FAULT, "keep bad bytes");
    check("keep rejected", !p7k.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    p7k_step(APU_VGPU_P7K_OK, "keep point");
    check("point kept", p7k.valid && p7k.offset == 16'd28 &&
          p7k.x == 7'd7 && p7k.y == 7'd0 &&
          {p7k.a, p7k.b, p7k.g, p7k.r} == APU_VGPU_CLEAR_WORD);
    p7k_step(APU_VGPU_P7K_FAULT, "keep again");
    b0 = 8'h1A;
    p7x_step(APU_VGPU_P7X_FAULT, "blue first");
    check("blue rejected", !p7x.valid);
    b0 = 8'hFF;
    p7x_step(APU_VGPU_P7X_FAULT, "high byte first");
    check("high byte rejected", !p7x.valid);
    b0 = 8'h0D;
    p7x_step(APU_VGPU_P7X_OK, "red first");
    check("red first", p7x.valid && p7x.b0 == 8'h0D && p7x.offset == 16'd28 &&
          p7x.x == 7'd7 && p7x.y == 7'd0);
    p7x_step(APU_VGPU_P7X_FAULT, "order again");
    check("order stays", p7x.b0 == 8'h0D && p7x.offset == 16'd28);

    pulse_reset();
    check("reset clears", p7r == '0 && p7k == '0 && p7x == '0);
    gbd = '0;
    x6x_in = '0;
    tcx_in = '0;
    cxr = '0;
    p7r_step(APU_VGPU_P7R_EMPTY, "after reset");
    p7k_step(APU_VGPU_P7K_EMPTY, "keep after reset");
    p7x_step(APU_VGPU_P7X_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu p7r errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_p7r cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
