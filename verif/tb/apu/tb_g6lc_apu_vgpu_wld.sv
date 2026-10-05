// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_wld;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_hcx_t hcx;
  logic [15:0] x, y;
  logic wld_req = 0, wld_rdy, wld_cpl_v, wld_cpl_r = 0;
  apu_vgpu_wld_cpl_t wld_cpl;
  apu_vgpu_wld_t wld;
  logic wlr_req = 0, wlr_rdy, wlr_cpl_v, wlr_cpl_r = 0;
  apu_vgpu_wlr_cpl_t wlr_cpl;
  apu_vgpu_wlr_t wlr;
  logic wlk_req = 0, wlk_rdy, wlk_cpl_v, wlk_cpl_r = 0;
  apu_vgpu_wlk_cpl_t wlk_cpl, off_cpl;
  apu_vgpu_wlk_t wlk, off_wlk;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_wld #(.Enable(1'b1)) i_wld (
    .clk_i(clk), .rst_ni, .hcx_i(hcx), .x_i(x), .y_i(y),
    .req_valid_i(wld_req), .req_ready_o(wld_rdy),
    .cpl_valid_o(wld_cpl_v), .cpl_ready_i(wld_cpl_r), .cpl_o(wld_cpl), .wld_o(wld)
  );
  g6lc_apu_vgpu_wlr #(.Enable(1'b1)) i_wlr (
    .clk_i(clk), .rst_ni, .wld_i(wld), .hcx_i(hcx),
    .req_valid_i(wlr_req), .req_ready_o(wlr_rdy),
    .cpl_valid_o(wlr_cpl_v), .cpl_ready_i(wlr_cpl_r), .cpl_o(wlr_cpl), .wlr_o(wlr)
  );
  g6lc_apu_vgpu_wlk #(.Enable(1'b1)) i_wlk (
    .clk_i(clk), .rst_ni, .wlr_i(wlr), .wld_i(wld), .hcx_i(hcx),
    .req_valid_i(wlk_req), .req_ready_o(wlk_rdy),
    .cpl_valid_o(wlk_cpl_v), .cpl_ready_i(wlk_cpl_r), .cpl_o(wlk_cpl), .wlk_o(wlk)
  );
  g6lc_apu_vgpu_wlk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .wlr_i(wlr), .wld_i(wld), .hcx_i(hcx),
    .req_valid_i(wlk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(wlk_cpl_r), .cpl_o(off_cpl), .wlk_o(off_wlk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu wld timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_in;
    hcx = '0;
    hcx.valid = 1'b1;
    hcx.format = APU_VIRGL_FMT_B8G8R8X8;
    hcx.off0 = APU_VGPU_ACW_AT0;
    hcx.off1 = APU_VGPU_ACW_AT1;
    hcx.x0 = 7'd0;
    hcx.x1 = 7'd1;
    hcx.b0 = 8'h00;
    hcx.origin = APU_VGPU_FTX_ORIGIN;
    hcx.neighbor = APU_VGPU_FTX_NEIGHBOR;
    x = 16'd0;
    y = 16'd0;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_wlk == '0 &&
          off_cpl == '0);
  endtask

  task automatic wld_step(input apu_vgpu_wld_status_e st, input string name);
    @(negedge clk);
    while (!wld_rdy) @(negedge clk);
    cases++;
    wld_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wld_req = 1'b0;
    while (!wld_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), wld_cpl.status == st);
    quiet();
    if (st == APU_VGPU_WLD_OK) begin
      check("sampled", wld.valid && wld.refused == 1'b0 &&
            wld.word != APU_VGPU_CLEAR_WORD &&
            ((x == 16'd0 && y == 16'd0 &&
              wld.word == APU_VGPU_FTX_ORIGIN && wld.addr == 14'd0) ||
             (x == 16'd1 && y == 16'd0 &&
              wld.word == APU_VGPU_FTX_NEIGHBOR && wld.addr == 14'd4)));
    end else if (name != "sample again") begin
      check("no sample", !wld.valid);
    end
    @(negedge clk);
    check($sformatf("%s held", name), wld_cpl_v);
    wld_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wld_cpl_r = 1'b0;
    while (wld_cpl_v) @(negedge clk);
  endtask

  task automatic wlr_step(input apu_vgpu_wlr_status_e st, input string name);
    @(negedge clk);
    while (!wlr_rdy) @(negedge clk);
    cases++;
    wlr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wlr_req = 1'b0;
    while (!wlr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), wlr_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), wlr_cpl_v);
    wlr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wlr_cpl_r = 1'b0;
    while (wlr_cpl_v) @(negedge clk);
  endtask

  task automatic wlk_step(input apu_vgpu_wlk_status_e st, input string name);
    @(negedge clk);
    while (!wlk_rdy) @(negedge clk);
    cases++;
    wlk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wlk_req = 1'b0;
    while (!wlk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), wlk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), wlk_cpl_v);
    wlk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wlk_cpl_r = 1'b0;
    while (wlk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    wld_req = 1'b0;
    wlr_req = 1'b0;
    wlk_req = 1'b0;
    wld_cpl_r = 1'b0;
    wlr_cpl_r = 1'b0;
    wlk_cpl_r = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    hcx = '0;
    x = 16'd0;
    y = 16'd0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          wld == '0 && wlr == '0 && wlk == '0);
    check("profiles keep the sample off",
          !ApuOff.WldEn && !ApuOff.WlrEn && !ApuOff.WlkEn &&
          !ApuP1Transport.WldEn && !ApuP1Transport.WlrEn && !ApuP1Transport.WlkEn &&
          !ApuHarness.WldEn && !ApuHarness.WlrEn && !ApuHarness.WlkEn &&
          !ApuSchedBoth.WldEn && !ApuSchedBoth.WlrEn && !ApuSchedBoth.WlkEn &&
          !ApuBadVirglGrant.WldEn && !ApuBadVirglGrant.WlrEn &&
          !ApuBadVirglGrant.WlkEn);
    cfg = ApuP1Transport;
    cfg.WldEn = 1'b1;
    cfg.WlrEn = 1'b1;
    cfg.WlkEn = 1'b1;
    check("sample does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.WldEn = 1'b1;
    cfg.WlrEn = 1'b1;
    cfg.WlkEn = 1'b1;
    check("sample does not legalize virgl", !apu_cfg_legal(cfg));
    check("known samples",
          APU_VGPU_FTX_ORIGIN != APU_VGPU_CLEAR_WORD &&
          APU_VGPU_FTX_NEIGHBOR != APU_VGPU_CLEAR_WORD &&
          APU_VGPU_FTX_ORIGIN[7:0] == 8'h00);

    wld_step(APU_VGPU_WLD_EMPTY, "sample empty");
    wlr_step(APU_VGPU_WLR_EMPTY, "keep empty");
    wlk_step(APU_VGPU_WLK_EMPTY, "check empty");
    good_in();
    hcx = '0;
    wld_step(APU_VGPU_WLD_EMPTY, "pair missing");
    good_in();
    hcx.origin = APU_VGPU_CLEAR_WORD;
    wld_step(APU_VGPU_WLD_FAULT, "clear origin");
    good_in();
    x = 16'd2;
    wld_step(APU_VGPU_WLD_FAULT, "x 2");
    good_in();
    y = 16'd1;
    wld_step(APU_VGPU_WLD_FAULT, "y 1");
    good_in();
    x = 16'd64;
    wld_step(APU_VGPU_WLD_FAULT, "outside");
    good_in();
    wld_step(APU_VGPU_WLD_OK, "origin");
    wld_step(APU_VGPU_WLD_FAULT, "sample again");
    check("origin stays", wld.valid && wld.word == APU_VGPU_FTX_ORIGIN &&
          wld.addr == 14'd0 && wld.refused == 1'b0);
    hcx.origin = APU_VGPU_CLEAR_WORD;
    wlr_step(APU_VGPU_WLR_FAULT, "keep clear origin");
    check("keep rejected", !wlr.valid);
    hcx.origin = APU_VGPU_FTX_ORIGIN;
    wlr_step(APU_VGPU_WLR_OK, "keep origin");
    check("origin kept", wlr.valid && wlr.word == APU_VGPU_FTX_ORIGIN &&
          wlr.addr == 14'd0);
    wlr_step(APU_VGPU_WLR_FAULT, "keep again");
    hcx.origin = APU_VGPU_CLEAR_WORD;
    wlk_step(APU_VGPU_WLK_FAULT, "check clear origin");
    check("check rejected", !wlk.valid);
    hcx.origin = APU_VGPU_FTX_ORIGIN;
    wlk_step(APU_VGPU_WLK_OK, "check origin");
    check("tex kept", wlk.valid && wlk.refused == 1'b0 &&
          wlk.word == APU_VGPU_FTX_ORIGIN && wlk.addr == 14'd0);
    wlk_step(APU_VGPU_WLK_FAULT, "check again");

    pulse_reset();
    check("reset clears", wld == '0 && wlr == '0 && wlk == '0);
    good_in();
    x = 16'd1;
    wld_step(APU_VGPU_WLD_OK, "neighbor");
    check("neighbor sample", wld.word == APU_VGPU_FTX_NEIGHBOR &&
          wld.addr == 14'd4 && wld.x == 7'd1);

    if (errors != 0) $fatal(1, "APU vgpu wld errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_wld cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
