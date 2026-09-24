// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tpr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gbd_t gbd;
  apu_vgpu_ryx_t ryx_in;
  apu_vgpu_cxr_t cxr;
  logic tpr_req = 0, tpr_rdy, tpr_cpl_v, tpr_cpl_r = 0;
  apu_vgpu_tpr_cpl_t tpr_cpl;
  apu_vgpu_tpr_t tpr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen0 = 0, seen1 = 0, seen2 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic tpk_req = 0, tpk_rdy, tpk_cpl_v, tpk_cpl_r = 0;
  apu_vgpu_tpk_cpl_t tpk_cpl;
  apu_vgpu_tpk_t tpk;
  logic [7:0] b0 = 0, corrupt_b = 0;
  logic tpx_req = 0, tpx_rdy, tpx_cpl_v, tpx_cpl_r = 0;
  apu_vgpu_tpx_cpl_t tpx_cpl, off_cpl;
  apu_vgpu_tpx_t tpx, off_tpx;
  logic off_rdy, off_v;
  logic fail_rd = 0, corrupt = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, rd_base = 0;
  int corrupt_idx = 0;

  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_tpr #(.Enable(1'b1)) i_tpr (
    .clk_i(clk), .rst_ni, .gbd_i(gbd), .ryx_i(ryx_in), .cxr_i(cxr),
    .req_valid_i(tpr_req), .req_ready_o(tpr_rdy),
    .cpl_valid_o(tpr_cpl_v), .cpl_ready_i(tpr_cpl_r), .cpl_o(tpr_cpl), .tpr_o(tpr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_tpk #(.Enable(1'b1)) i_tpk (
    .clk_i(clk), .rst_ni, .tpr_i(tpr), .gbd_i(gbd),
    .req_valid_i(tpk_req), .req_ready_o(tpk_rdy),
    .cpl_valid_o(tpk_cpl_v), .cpl_ready_i(tpk_cpl_r), .cpl_o(tpk_cpl), .tpk_o(tpk)
  );
  g6lc_apu_vgpu_tpx #(.Enable(1'b1)) i_tpx (
    .clk_i(clk), .rst_ni, .tpk_i(tpk), .b0_i(b0),
    .req_valid_i(tpx_req), .req_ready_o(tpx_rdy),
    .cpl_valid_o(tpx_cpl_v), .cpl_ready_i(tpx_cpl_r), .cpl_o(tpx_cpl), .tpx_o(tpx)
  );
  g6lc_apu_vgpu_tpx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .tpk_i(tpk), .b0_i(b0),
    .req_valid_i(tpx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(tpx_cpl_r), .cpl_o(off_cpl), .tpx_o(off_tpx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu tpr timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      logic [255:0] beat;
      idx = nread - rd_base;
      if (idx == 0) want = APU_VGPU_GOF_ROW1_ADDR;
      else if (idx == 1) want = APU_VGPU_TPR_AT23_ADDR;
      else want = APU_VGPU_TPR_ROW63_ADDR;
      beat = Pat;
      if (corrupt && idx == corrupt_idx) begin
        if (idx == 0) beat[39:32] = corrupt_b;
        else if (idx == 1) beat[71:64] = corrupt_b;
        else beat[7:0] = corrupt_b;
        corrupt <= 1'b0;
      end
      if (rd_addr != want || rd_len != 32'(APU_VGPU_BEAT_BYTES)) order_bad <= 1'b1;
      if (idx == 0) seen0 <= rd_addr;
      else if (idx == 1) seen1 <= rd_addr;
      else seen2 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
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
    ryx_in = '0;
    ryx_in.valid = 1'b1;
    ryx_in.format = APU_VIRGL_FMT_B8G8R8X8;
    ryx_in.b0 = APU_VGPU_CLEAR_R;
    ryx_in.r = APU_VGPU_CLEAR_R;
    ryx_in.g = APU_VGPU_CLEAR_G;
    ryx_in.b = APU_VGPU_CLEAR_B;
    ryx_in.a = APU_VGPU_CLEAR_A;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = APU_VGPU_CLEAR_R;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_tpx == '0 &&
          off_cpl == '0);
  endtask

  task automatic tpr_step(input apu_vgpu_tpr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!tpr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    tpr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tpr_req = 1'b0;
    while (!tpr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tpr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TPR_OK) begin
      check("points", tpr.valid && tpr.format == 32'd2 &&
            tpr.off11 == 16'd260 && tpr.off23 == 16'd776 &&
            tpr.off063 == 16'd16128 &&
            tpr.r == 8'h0D && tpr.g == 8'h0D && tpr.b == 8'h1A &&
            tpr.a == 8'hFF);
      check("three beats", nread == n0 + 3 && !order_bad &&
            seen0 == APU_VGPU_GOF_ROW1_ADDR &&
            seen1 == APU_VGPU_TPR_AT23_ADDR &&
            seen2 == APU_VGPU_TPR_ROW63_ADDR);
    end else if (name == "bad beat" || name == "bad byte") begin
      check("one read", nread == n0 + 1 && !order_bad &&
            seen0 == APU_VGPU_GOF_ROW1_ADDR && !tpr.valid);
    end else if (name == "mid byte") begin
      check("two reads", nread == n0 + 2 && !order_bad &&
            seen1 == APU_VGPU_TPR_AT23_ADDR && !tpr.valid);
    end else if (name == "last byte") begin
      check("three reads", nread == n0 + 3 && !order_bad &&
            seen2 == APU_VGPU_TPR_ROW63_ADDR && !tpr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), tpr_cpl_v);
    tpr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tpr_cpl_r = 1'b0;
    while (tpr_cpl_v) @(negedge clk);
  endtask

  task automatic tpk_step(input apu_vgpu_tpk_status_e st, input string name);
    @(negedge clk);
    while (!tpk_rdy) @(negedge clk);
    cases++;
    tpk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tpk_req = 1'b0;
    while (!tpk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tpk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tpk_cpl_v);
    tpk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tpk_cpl_r = 1'b0;
    while (tpk_cpl_v) @(negedge clk);
  endtask

  task automatic tpx_step(input apu_vgpu_tpx_status_e st, input string name);
    @(negedge clk);
    while (!tpx_rdy) @(negedge clk);
    cases++;
    tpx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tpx_req = 1'b0;
    while (!tpx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tpx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tpx_cpl_v);
    tpx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tpx_cpl_r = 1'b0;
    while (tpx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    tpr_req = 1'b0;
    tpk_req = 1'b0;
    tpx_req = 1'b0;
    tpr_cpl_r = 1'b0;
    tpk_cpl_r = 1'b0;
    tpx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gbd = '0;
    ryx_in = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          tpr == '0 && tpk == '0 && tpx == '0);
    check("profiles keep the points off",
          !ApuOff.TprEn && !ApuOff.TpkEn && !ApuOff.TpxEn &&
          !ApuP1Transport.TprEn && !ApuP1Transport.TpkEn && !ApuP1Transport.TpxEn &&
          !ApuHarness.TprEn && !ApuHarness.TpkEn && !ApuHarness.TpxEn &&
          !ApuSchedBoth.TprEn && !ApuSchedBoth.TpkEn && !ApuSchedBoth.TpxEn &&
          !ApuBadVirglGrant.TprEn && !ApuBadVirglGrant.TpkEn &&
          !ApuBadVirglGrant.TpxEn);
    cfg = ApuP1Transport;
    cfg.TprEn = 1'b1;
    cfg.TpkEn = 1'b1;
    cfg.TpxEn = 1'b1;
    check("points do not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TprEn = 1'b1;
    cfg.TpkEn = 1'b1;
    cfg.TpxEn = 1'b1;
    check("points do not legalize virgl", !apu_cfg_legal(cfg));
    check("point addresses",
          APU_VGPU_TPR_AT11 == 16'd260 &&
          APU_VGPU_GOF_ROW1 + 16'd4 == APU_VGPU_TPR_AT11 &&
          APU_VGPU_TPR_AT23 == 16'd776 &&
          16'd768 + 16'd8 == APU_VGPU_TPR_AT23 &&
          APU_VGPU_TPR_AT063 == 16'd16128 &&
          APU_VGPU_TPR_AT23_ADDR == 64'h0000_0000_8803_0300 &&
          APU_VGPU_TPR_ROW63_ADDR == 64'h0000_0000_8803_3F00 &&
          APU_VGPU_GBW_ADDR + 64'd768 == APU_VGPU_TPR_AT23_ADDR &&
          APU_VGPU_GBW_ADDR + 64'd16128 == APU_VGPU_TPR_ROW63_ADDR &&
          APU_VGPU_CLEAR_WORD == {APU_VGPU_CLEAR_A, APU_VGPU_CLEAR_B,
                                  APU_VGPU_CLEAR_G, APU_VGPU_CLEAR_R});

    tpr_step(APU_VGPU_TPR_EMPTY, "points empty");
    tpk_step(APU_VGPU_TPK_EMPTY, "keep empty");
    tpx_step(APU_VGPU_TPX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    tpr_step(APU_VGPU_TPR_FAULT, "bad scissor");
    good_in();
    gbd.format = 32'd0;
    tpr_step(APU_VGPU_TPR_FAULT, "bad format");
    good_in();
    gbd.height = 16'd480;
    tpr_step(APU_VGPU_TPR_FAULT, "tall rectangle");
    good_in();
    ryx_in.b0 = 8'h1A;
    tpr_step(APU_VGPU_TPR_FAULT, "posted blue");
    good_in();
    fail_rd = 1'b1;
    tpr_step(APU_VGPU_TPR_FAULT, "bad beat");
    corrupt = 1'b1;
    corrupt_idx = 0;
    corrupt_b = 8'hFF;
    tpr_step(APU_VGPU_TPR_FAULT, "bad byte");
    corrupt = 1'b1;
    corrupt_idx = 1;
    corrupt_b = 8'h1A;
    tpr_step(APU_VGPU_TPR_FAULT, "mid byte");
    corrupt = 1'b1;
    corrupt_idx = 2;
    corrupt_b = 8'hFF;
    tpr_step(APU_VGPU_TPR_FAULT, "last byte");
    tpr_step(APU_VGPU_TPR_OK, "points");
    tpr_step(APU_VGPU_TPR_FAULT, "points again");
    check("points stay", tpr.off11 == 16'd260 && tpr.off23 == 16'd776 &&
          tpr.off063 == 16'd16128 && tpr.r == 8'h0D && tpr.a == 8'hFF);
    gbd.bytes = 32'd0;
    tpk_step(APU_VGPU_TPK_FAULT, "keep bad bytes");
    check("keep rejected", !tpk.valid);
    gbd.bytes = APU_VGPU_GBD_BYTES;
    tpk_step(APU_VGPU_TPK_OK, "keep points");
    check("points kept", tpk.valid && tpk.off11 == 16'd260 &&
          tpk.off23 == 16'd776 && tpk.off063 == 16'd16128 &&
          {tpk.a, tpk.b, tpk.g, tpk.r} == APU_VGPU_CLEAR_WORD);
    tpk_step(APU_VGPU_TPK_FAULT, "keep again");
    b0 = 8'h1A;
    tpx_step(APU_VGPU_TPX_FAULT, "blue first");
    check("blue rejected", !tpx.valid);
    b0 = 8'hFF;
    tpx_step(APU_VGPU_TPX_FAULT, "high byte first");
    check("high byte rejected", !tpx.valid);
    b0 = 8'h0D;
    tpx_step(APU_VGPU_TPX_OK, "red first");
    check("red first", tpx.valid && tpx.b0 == 8'h0D && tpx.b0 != 8'h1A &&
          tpx.b0 != 8'hFF && tpx.off063 == 16'd16128 && tpx.r == 8'h0D);
    tpx_step(APU_VGPU_TPX_FAULT, "order again");
    check("order stays", tpx.b0 == 8'h0D && tpx.off11 == 16'd260 &&
          tpx.off23 == 16'd776);

    pulse_reset();
    check("reset clears", tpr == '0 && tpk == '0 && tpx == '0);
    gbd = '0;
    ryx_in = '0;
    cxr = '0;
    tpr_step(APU_VGPU_TPR_EMPTY, "after reset");
    tpk_step(APU_VGPU_TPK_EMPTY, "keep after reset");
    tpx_step(APU_VGPU_TPX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu tpr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tpr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
