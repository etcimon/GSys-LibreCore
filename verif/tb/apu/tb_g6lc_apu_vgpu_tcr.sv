// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tcr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_x6x_t x6x_in;
  apu_vgpu_tpx_t tpx_in;
  apu_vgpu_cxr_t cxr;
  logic tcr_req = 0, tcr_rdy, tcr_cpl_v, tcr_cpl_r = 0;
  apu_vgpu_tcr_cpl_t tcr_cpl;
  apu_vgpu_tcr_t tcr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic tck_req = 0, tck_rdy, tck_cpl_v, tck_cpl_r = 0;
  apu_vgpu_tck_cpl_t tck_cpl;
  apu_vgpu_tck_t tck;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic tcx_req = 0, tcx_rdy, tcx_cpl_v, tcx_cpl_r = 0;
  apu_vgpu_tcx_cpl_t tcx_cpl, off_cpl;
  apu_vgpu_tcx_t tcx, off_tcx;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_tcr #(.Enable(1'b1)) i_tcr (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .x6x_i(x6x_in), .tpx_i(tpx_in), .cxr_i(cxr),
    .req_valid_i(tcr_req), .req_ready_o(tcr_rdy),
    .cpl_valid_o(tcr_cpl_v), .cpl_ready_i(tcr_cpl_r), .cpl_o(tcr_cpl), .tcr_o(tcr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_tck #(.Enable(1'b1)) i_tck (
    .clk_i(clk), .rst_ni, .tcr_i(tcr), .gbd_i(gbd),
    .req_valid_i(tck_req), .req_ready_o(tck_rdy),
    .cpl_valid_o(tck_cpl_v), .cpl_ready_i(tck_cpl_r), .cpl_o(tck_cpl), .tck_o(tck)
  );
  g6lc_apu_vgpu_tcx #(.Enable(1'b1)) i_tcx (
    .clk_i(clk), .rst_ni, .tck_i(tck), .b0_i(b0),
    .req_valid_i(tcx_req), .req_ready_o(tcx_rdy),
    .cpl_valid_o(tcx_cpl_v), .cpl_ready_i(tcx_cpl_r), .cpl_o(tcx_cpl), .tcx_o(tcx)
  );
  g6lc_apu_vgpu_tcx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .tck_i(tck), .b0_i(b0),
    .req_valid_i(tcx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(tcx_cpl_r), .cpl_o(off_cpl), .tcx_o(off_tcx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu tcr timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_GBW_TAIL ||
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
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_tcx == '0 &&
          off_cpl == '0);
  endtask

  task automatic tcr_step(input apu_vgpu_tcr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!tcr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    tcr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tcr_req = 1'b0;
    while (!tcr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tcr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TCR_OK) begin
      check("corner", tcr.valid && tcr.offset == 16'd16380 &&
            tcr.x == 7'd63 && tcr.y == 7'd63 &&
            tcr.r == 8'h0D && tcr.g == 8'h0D && tcr.b == 8'h1A &&
            tcr.a == 8'hFF);
      check("one beat", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_GBW_TAIL);
    end else if (name == "bad beat" || name == "bad byte" || name == "blue byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_GBW_TAIL && !tcr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), tcr_cpl_v);
    tcr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tcr_cpl_r = 1'b0;
    while (tcr_cpl_v) @(negedge clk);
  endtask

  task automatic tck_step(input apu_vgpu_tck_status_e st, input string name);
    @(negedge clk);
    while (!tck_rdy) @(negedge clk);
    cases++;
    tck_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tck_req = 1'b0;
    while (!tck_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tck_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tck_cpl_v);
    tck_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tck_cpl_r = 1'b0;
    while (tck_cpl_v) @(negedge clk);
  endtask

  task automatic tcx_step(input apu_vgpu_tcx_status_e st, input string name);
    @(negedge clk);
    while (!tcx_rdy) @(negedge clk);
    cases++;
    tcx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tcx_req = 1'b0;
    while (!tcx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tcx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tcx_cpl_v);
    tcx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tcx_cpl_r = 1'b0;
    while (tcx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    tcr_req = 1'b0;
    tck_req = 1'b0;
    tcx_req = 1'b0;
    tcr_cpl_r = 1'b0;
    tck_cpl_r = 1'b0;
    tcx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    x6x_in = '0;
    tpx_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          tcr == '0 && tck == '0 && tcx == '0);
    check("profiles keep the corner off",
          !ApuOff.TcrEn && !ApuOff.TckEn && !ApuOff.TcxEn &&
          !ApuP1Transport.TcrEn && !ApuP1Transport.TckEn && !ApuP1Transport.TcxEn &&
          !ApuHarness.TcrEn && !ApuHarness.TckEn && !ApuHarness.TcxEn &&
          !ApuSchedBoth.TcrEn && !ApuSchedBoth.TckEn && !ApuSchedBoth.TcxEn &&
          !ApuBadVirglGrant.TcrEn && !ApuBadVirglGrant.TckEn &&
          !ApuBadVirglGrant.TcxEn);
    cfg = ApuP1Transport;
    cfg.TcrEn = 1'b1;
    cfg.TckEn = 1'b1;
    cfg.TcxEn = 1'b1;
    check("corner does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TcrEn = 1'b1;
    cfg.TckEn = 1'b1;
    cfg.TcxEn = 1'b1;
    check("corner does not legalize virgl", !apu_cfg_legal(cfg));
    check("corner offset",
          APU_VGPU_GOF_LAST == 16'd16380 &&
          APU_VGPU_TPR_AT063 + APU_VGPU_X6R_AT == APU_VGPU_GOF_LAST &&
          32'(APU_VGPU_GOF_LAST) + 32'd4 == APU_VGPU_GBD_BYTES &&
          APU_VGPU_GBW_TAIL == 64'h0000_0000_8803_3FE0 &&
          APU_VGPU_GBW_ADDR + 64'd16352 == APU_VGPU_GBW_TAIL &&
          APU_VGPU_GOF_LAST != APU_VGPU_X6R_AT &&
          APU_VGPU_GOF_LAST != APU_VGPU_TPR_AT063);

    tcr_step(APU_VGPU_TCR_EMPTY, "corner empty");
    tck_step(APU_VGPU_TCK_EMPTY, "keep empty");
    tcx_step(APU_VGPU_TCX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    tcr_step(APU_VGPU_TCR_FAULT, "bad scissor");
    good_in();
    x6x_in.offset = 16'd16380;
    tcr_step(APU_VGPU_TCR_FAULT, "swapped corner");
    good_in();
    tpx_in.off063 = 16'd252;
    tcr_step(APU_VGPU_TCR_FAULT, "swapped row");
    good_in();
    gbd.height = 16'd480;
    tcr_step(APU_VGPU_TCR_FAULT, "tall rectangle");
    good_in();
    fail_rd = 1'b1;
    tcr_step(APU_VGPU_TCR_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_b = 8'hFF;
    tcr_step(APU_VGPU_TCR_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_b = 8'h1A;
    tcr_step(APU_VGPU_TCR_FAULT, "blue byte");
    tcr_step(APU_VGPU_TCR_OK, "corner");
    tcr_step(APU_VGPU_TCR_FAULT, "corner again");
    check("corner stays", tcr.offset == 16'd16380 && tcr.x == 7'd63 &&
          tcr.y == 7'd63 && tcr.r == 8'h0D);
    gbd.bytes = 32'd0;
    tck_step(APU_VGPU_TCK_FAULT, "keep bad bytes");
    check("keep rejected", !tck.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    tck_step(APU_VGPU_TCK_OK, "keep corner");
    check("corner kept", tck.valid && tck.offset == 16'd16380 &&
          tck.x == 7'd63 && tck.y == 7'd63 &&
          {tck.a, tck.b, tck.g, tck.r} == APU_VGPU_CLEAR_WORD);
    tck_step(APU_VGPU_TCK_FAULT, "keep again");
    b0 = 8'h1A;
    tcx_step(APU_VGPU_TCX_FAULT, "blue first");
    check("blue rejected", !tcx.valid);
    b0 = 8'hFF;
    tcx_step(APU_VGPU_TCX_FAULT, "high byte first");
    check("high byte rejected", !tcx.valid);
    b0 = 8'h0D;
    tcx_step(APU_VGPU_TCX_OK, "red first");
    check("red first", tcx.valid && tcx.b0 == 8'h0D && tcx.b0 != 8'h1A &&
          tcx.offset == 16'd16380 && tcx.x == 7'd63 && tcx.y == 7'd63);
    tcx_step(APU_VGPU_TCX_FAULT, "order again");
    check("order stays", tcx.b0 == 8'h0D && tcx.offset == 16'd16380);

    pulse_reset();
    check("reset clears", tcr == '0 && tck == '0 && tcx == '0);
    gbd = '0;
    x6x_in = '0;
    tpx_in = '0;
    cxr = '0;
    tcr_step(APU_VGPU_TCR_EMPTY, "after reset");
    tck_step(APU_VGPU_TCK_EMPTY, "keep after reset");
    tcx_step(APU_VGPU_TCX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu tcr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tcr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
