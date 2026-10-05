// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_crd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_csw_t csw;
  apu_vgpu_csx_t csx;
  logic [15:0] want_w = 0, want_h = 0;
  logic crd_req = 0, crd_rdy, crd_cpl_v, crd_cpl_r = 0;
  apu_vgpu_crd_cpl_t crd_cpl;
  apu_vgpu_crd_t crd;
  logic [6:0] px = 0, py = 0;
  logic crl_req = 0, crl_rdy, crl_cpl_v, crl_cpl_r = 0;
  apu_vgpu_crl_cpl_t crl_cpl;
  apu_vgpu_crl_t crl;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic crx_req = 0, crx_rdy, crx_cpl_v, crx_cpl_r = 0;
  apu_vgpu_crx_cpl_t crx_cpl, off_cpl;
  apu_vgpu_crx_t crx, off_crx;
  logic off_rdy, off_v;
  logic fail_rd = 0, clear_lane = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;
  localparam logic [255:0] Beat0 = {192'b0, Neighbor, Origin};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_crd #(.Enable(1'b1)) i_crd (
    .clk_i(clk), .rst_ni, .csw_i(csw), .csx_i(csx),
    .want_w_i(want_w), .want_h_i(want_h),
    .req_valid_i(crd_req), .req_ready_o(crd_rdy),
    .cpl_valid_o(crd_cpl_v), .cpl_ready_i(crd_cpl_r), .cpl_o(crd_cpl), .crd_o(crd)
  );
  g6lc_apu_vgpu_crl #(.Enable(1'b1)) i_crl (
    .clk_i(clk), .rst_ni, .crd_i(crd), .csx_i(csx), .x_i(px), .y_i(py),
    .req_valid_i(crl_req), .req_ready_o(crl_rdy),
    .cpl_valid_o(crl_cpl_v), .cpl_ready_i(crl_cpl_r), .cpl_o(crl_cpl), .crl_o(crl),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_crx #(.Enable(1'b1)) i_crx (
    .clk_i(clk), .rst_ni, .crl_i(crl), .crd_i(crd), .b0_i(b0),
    .req_valid_i(crx_req), .req_ready_o(crx_rdy),
    .cpl_valid_o(crx_cpl_v), .cpl_ready_i(crx_cpl_r), .cpl_o(crx_cpl), .crx_o(crx)
  );
  g6lc_apu_vgpu_crx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .crl_i(crl), .crd_i(crd), .b0_i(b0),
    .req_valid_i(crx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(crx_cpl_r), .cpl_o(off_cpl), .crx_o(off_crx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu crd timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Beat0;
      if (clear_lane) beat[63:32] = APU_VGPU_CLEAR_WORD;
      if (rd_addr != APU_VGPU_CSW_DST || rd_len != 32'(APU_VGPU_BEAT_BYTES))
        order_bad <= 1'b1;
      seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      clear_lane <= 1'b0;
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
    csw = '0;
    csw.valid = 1'b1;
    csw.origin = Origin;
    csw.neighbor = Neighbor;
    csw.beats = APU_VGPU_GPW_BEATS;
    csw.src = APU_VGPU_CSW_SRC;
    csw.dst = APU_VGPU_CSW_DST;
    csx = '0;
    csx.valid = 1'b1;
    csx.b0 = Neighbor[7:0];
    csx.off0 = APU_VGPU_ACW_AT0;
    csx.off1 = APU_VGPU_ACW_AT1;
    csx.x0 = 7'd0;
    csx.x1 = 7'd1;
    csx.origin = Origin;
    csx.neighbor = Neighbor;
    want_w = APU_VGPU_GBD_W;
    want_h = APU_VGPU_GBD_H;
    px = 7'd1;
    py = 7'd0;
    b0 = Neighbor[7:0];
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_crx == '0 &&
          off_cpl == '0);
  endtask

  task automatic crd_step(input apu_vgpu_crd_status_e st, input string name);
    @(negedge clk);
    while (!crd_rdy) @(negedge clk);
    cases++;
    crd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    crd_req = 1'b0;
    while (!crd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), crd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_CRD_OK) begin
      check("rect", crd.valid && crd.width == 16'd64 && crd.height == 16'd64 &&
            crd.stride == 16'd256 && crd.bytes == 32'd16384 &&
            crd.format == APU_VIRGL_FMT_B8G8R8X8 &&
            crd.base == APU_VGPU_CSW_DST && crd.base != APU_VGPU_GBW_ADDR &&
            crd.origin == Origin && crd.neighbor == Neighbor);
    end
    @(negedge clk);
    check($sformatf("%s held", name), crd_cpl_v);
    crd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    crd_cpl_r = 1'b0;
    while (crd_cpl_v) @(negedge clk);
  endtask

  task automatic crl_step(input apu_vgpu_crl_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!crl_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    crl_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    crl_req = 1'b0;
    while (!crl_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), crl_cpl.status == st);
    quiet();
    if (st == APU_VGPU_CRL_OK) begin
      check("lane", crl.valid && crl.x == 7'd1 && crl.y == 7'd0 &&
            crl.word == Neighbor && crl.word != APU_VGPU_CLEAR_WORD &&
            crl.addr == APU_VGPU_CSW_DST && crl.addr != APU_VGPU_GBW_ADDR);
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_CSW_DST);
    end else if (name == "bad beat" || name == "clear lane") begin
      check("one read failed", nread == n0 + 1 && !crl.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), crl_cpl_v);
    crl_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    crl_cpl_r = 1'b0;
    while (crl_cpl_v) @(negedge clk);
  endtask

  task automatic crx_step(input apu_vgpu_crx_status_e st, input string name);
    @(negedge clk);
    while (!crx_rdy) @(negedge clk);
    cases++;
    crx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    crx_req = 1'b0;
    while (!crx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), crx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), crx_cpl_v);
    crx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    crx_cpl_r = 1'b0;
    while (crx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    crd_req = 1'b0;
    crl_req = 1'b0;
    crx_req = 1'b0;
    crd_cpl_r = 1'b0;
    crl_cpl_r = 1'b0;
    crx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    csw = '0;
    csx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          crd == '0 && crl == '0 && crx == '0);
    check("profiles keep the rectangle off",
          !ApuOff.CrdEn && !ApuOff.CrlEn && !ApuOff.CrxEn &&
          !ApuP1Transport.CrdEn && !ApuP1Transport.CrlEn &&
          !ApuP1Transport.CrxEn &&
          !ApuHarness.CrdEn && !ApuHarness.CrlEn && !ApuHarness.CrxEn &&
          !ApuSchedBoth.CrdEn && !ApuSchedBoth.CrlEn && !ApuSchedBoth.CrxEn &&
          !ApuBadVirglGrant.CrdEn && !ApuBadVirglGrant.CrlEn &&
          !ApuBadVirglGrant.CrxEn);
    cfg = ApuP1Transport;
    cfg.CrdEn = 1'b1;
    cfg.CrlEn = 1'b1;
    cfg.CrxEn = 1'b1;
    check("rect does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.CrdEn = 1'b1;
    cfg.CrlEn = 1'b1;
    cfg.CrxEn = 1'b1;
    check("rect does not legalize virgl", !apu_cfg_legal(cfg));
    check("rect places",
          APU_VGPU_CSW_DST == 64'h0000_0000_8806_0000 &&
          APU_VGPU_CSW_DST != APU_VGPU_GBW_ADDR &&
          APU_VGPU_GBD_W == 16'd64 && APU_VGPU_GBD_H == 16'd64 &&
          APU_VGPU_GBD_BYTES == 32'd16384 &&
          Neighbor != APU_VGPU_CLEAR_WORD &&
          Neighbor[7:0] != APU_VGPU_CLEAR_R);

    crd_step(APU_VGPU_CRD_EMPTY, "rect empty");
    crl_step(APU_VGPU_CRL_EMPTY, "lane empty");
    crx_step(APU_VGPU_CRX_EMPTY, "order empty");
    good_in();
    want_w = 16'd640;
    want_h = 16'd480;
    crd_step(APU_VGPU_CRD_FAULT, "full surface");
    good_in();
    csw.dst = APU_VGPU_GBW_ADDR;
    crd_step(APU_VGPU_CRD_FAULT, "clear buffer");
    good_in();
    csx.neighbor = APU_VGPU_CLEAR_WORD;
    crd_step(APU_VGPU_CRD_FAULT, "clear sample");
    good_in();
    crd_step(APU_VGPU_CRD_OK, "rect");
    crd_step(APU_VGPU_CRD_FAULT, "rect again");
    check("rect stays", crd.base == APU_VGPU_CSW_DST && crd.neighbor == Neighbor &&
          crd.width == 16'd64);
    px = 7'd0;
    py = 7'd0;
    crl_step(APU_VGPU_CRL_FAULT, "origin point");
    check("origin rejected", !crl.valid);
    px = 7'd1;
    py = 7'd1;
    crl_step(APU_VGPU_CRL_FAULT, "next row");
    px = 7'd1;
    py = 7'd0;
    fail_rd = 1'b1;
    crl_step(APU_VGPU_CRL_FAULT, "bad beat");
    clear_lane = 1'b1;
    crl_step(APU_VGPU_CRL_FAULT, "clear lane");
    crl_step(APU_VGPU_CRL_OK, "sample lane");
    crl_step(APU_VGPU_CRL_FAULT, "lane again");
    check("lane stays", crl.word == Neighbor && crl.x == 7'd1 &&
          crl.addr == APU_VGPU_CSW_DST);
    b0 = APU_VGPU_CLEAR_R;
    crx_step(APU_VGPU_CRX_FAULT, "clear red first");
    check("clear red rejected", !crx.valid);
    b0 = APU_VGPU_CLEAR_B;
    crx_step(APU_VGPU_CRX_FAULT, "blue first");
    check("blue rejected", !crx.valid);
    b0 = APU_VGPU_CLEAR_A;
    crx_step(APU_VGPU_CRX_FAULT, "high byte first");
    check("high byte rejected", !crx.valid);
    b0 = Neighbor[7:0];
    crx_step(APU_VGPU_CRX_OK, "sample red first");
    check("sample red", crx.valid && crx.b0 == 8'h00 && crx.x == 7'd1 &&
          crx.word == Neighbor);
    crx_step(APU_VGPU_CRX_FAULT, "order again");
    check("order stays", crx.b0 == 8'h00 && crx.word == Neighbor);

    pulse_reset();
    check("reset clears", crd == '0 && crl == '0 && crx == '0);
    csw = '0;
    csx = '0;
    want_w = 16'd0;
    want_h = 16'd0;
    crd_step(APU_VGPU_CRD_EMPTY, "after reset");
    crl_step(APU_VGPU_CRL_EMPTY, "lane after reset");
    crx_step(APU_VGPU_CRX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu crd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_crd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
