// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_cyr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_wlk_t wlk;
  logic cyr_req = 0, cyr_rdy, cyr_cpl_v, cyr_cpl_r = 0;
  apu_vgpu_cyr_cpl_t cyr_cpl;
  apu_vgpu_cyr_t cyr;
  logic cyk_req = 0, cyk_rdy, cyk_cpl_v, cyk_cpl_r = 0;
  apu_vgpu_cyk_cpl_t cyk_cpl;
  apu_vgpu_cyk_t cyk;
  logic cyx_req = 0, cyx_rdy, cyx_cpl_v, cyx_cpl_r = 0;
  apu_vgpu_cyx_cpl_t cyx_cpl, off_cpl;
  apu_vgpu_cyx_t cyx, off_cyx;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_cyr #(.Enable(1'b1)) i_cyr (
    .clk_i(clk), .rst_ni, .wlk_i(wlk),
    .req_valid_i(cyr_req), .req_ready_o(cyr_rdy),
    .cpl_valid_o(cyr_cpl_v), .cpl_ready_i(cyr_cpl_r), .cpl_o(cyr_cpl), .cyr_o(cyr)
  );
  g6lc_apu_vgpu_cyk #(.Enable(1'b1)) i_cyk (
    .clk_i(clk), .rst_ni, .cyr_i(cyr), .wlk_i(wlk),
    .req_valid_i(cyk_req), .req_ready_o(cyk_rdy),
    .cpl_valid_o(cyk_cpl_v), .cpl_ready_i(cyk_cpl_r), .cpl_o(cyk_cpl), .cyk_o(cyk)
  );
  g6lc_apu_vgpu_cyx #(.Enable(1'b1)) i_cyx (
    .clk_i(clk), .rst_ni, .cyk_i(cyk), .cyr_i(cyr), .wlk_i(wlk),
    .req_valid_i(cyx_req), .req_ready_o(cyx_rdy),
    .cpl_valid_o(cyx_cpl_v), .cpl_ready_i(cyx_cpl_r), .cpl_o(cyx_cpl), .cyx_o(cyx)
  );
  g6lc_apu_vgpu_cyx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cyk_i(cyk), .cyr_i(cyr), .wlk_i(wlk),
    .req_valid_i(cyx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cyx_cpl_r), .cpl_o(off_cpl), .cyx_o(off_cyx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu cyr timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_in;
    wlk = '0;
    wlk.valid = 1'b1;
    wlk.refused = 1'b0;
    wlk.word = APU_VGPU_FTX_ORIGIN;
    wlk.addr = 14'd0;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_cyx == '0 &&
          off_cpl == '0);
  endtask

  task automatic cyr_step(input apu_vgpu_cyr_status_e st, input string name);
    @(negedge clk);
    while (!cyr_rdy) @(negedge clk);
    cases++;
    cyr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cyr_req = 1'b0;
    while (!cyr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cyr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_CYR_OK) begin
      check("channels", cyr.valid && cyr.r == wlk.word[7:0] &&
            cyr.g == wlk.word[15:8] && cyr.b == wlk.word[23:16] &&
            cyr.a == wlk.word[31:24] && cyr.r != APU_VGPU_CLEAR_R &&
            cyr.word == wlk.word);
    end else if (name != "sample again") begin
      check("no sample", !cyr.valid);
    end
    @(negedge clk);
    check($sformatf("%s held", name), cyr_cpl_v);
    cyr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cyr_cpl_r = 1'b0;
    while (cyr_cpl_v) @(negedge clk);
  endtask

  task automatic cyk_step(input apu_vgpu_cyk_status_e st, input string name);
    @(negedge clk);
    while (!cyk_rdy) @(negedge clk);
    cases++;
    cyk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cyk_req = 1'b0;
    while (!cyk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cyk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), cyk_cpl_v);
    cyk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cyk_cpl_r = 1'b0;
    while (cyk_cpl_v) @(negedge clk);
  endtask

  task automatic cyx_step(input apu_vgpu_cyx_status_e st, input string name);
    @(negedge clk);
    while (!cyx_rdy) @(negedge clk);
    cases++;
    cyx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cyx_req = 1'b0;
    while (!cyx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cyx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), cyx_cpl_v);
    cyx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cyx_cpl_r = 1'b0;
    while (cyx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    cyr_req = 1'b0;
    cyk_req = 1'b0;
    cyx_req = 1'b0;
    cyr_cpl_r = 1'b0;
    cyk_cpl_r = 1'b0;
    cyx_cpl_r = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    wlk = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          cyr == '0 && cyk == '0 && cyx == '0);
    check("profiles keep the sample off",
          !ApuOff.CyrEn && !ApuOff.CykEn && !ApuOff.CyxEn &&
          !ApuP1Transport.CyrEn && !ApuP1Transport.CykEn && !ApuP1Transport.CyxEn &&
          !ApuHarness.CyrEn && !ApuHarness.CykEn && !ApuHarness.CyxEn &&
          !ApuSchedBoth.CyrEn && !ApuSchedBoth.CykEn && !ApuSchedBoth.CyxEn &&
          !ApuBadVirglGrant.CyrEn && !ApuBadVirglGrant.CykEn &&
          !ApuBadVirglGrant.CyxEn);
    cfg = ApuP1Transport;
    cfg.CyrEn = 1'b1;
    cfg.CykEn = 1'b1;
    cfg.CyxEn = 1'b1;
    check("sample does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.CyrEn = 1'b1;
    cfg.CykEn = 1'b1;
    cfg.CyxEn = 1'b1;
    check("sample does not legalize virgl", !apu_cfg_legal(cfg));
    check("known channels",
          APU_VGPU_FTX_ORIGIN[7:0] == 8'h00 &&
          APU_VGPU_FTX_ORIGIN[31:24] == 8'hA5 &&
          APU_VGPU_FTX_NEIGHBOR[7:0] == 8'h00 &&
          APU_VGPU_FTX_NEIGHBOR[15:8] == 8'h80 &&
          APU_VGPU_CLEAR_R == 8'h0D &&
          APU_VGPU_CLEAR_A == 8'hFF);

    cyr_step(APU_VGPU_CYR_EMPTY, "sample empty");
    cyk_step(APU_VGPU_CYK_EMPTY, "keep empty");
    cyx_step(APU_VGPU_CYX_EMPTY, "check empty");
    good_in();
    wlk = '0;
    cyr_step(APU_VGPU_CYR_EMPTY, "held missing");
    good_in();
    wlk.word = APU_VGPU_CLEAR_WORD;
    cyr_step(APU_VGPU_CYR_FAULT, "clear word");
    good_in();
    wlk.addr = 14'd8;
    cyr_step(APU_VGPU_CYR_FAULT, "bad addr");
    good_in();
    cyr_step(APU_VGPU_CYR_OK, "origin channels");
    cyr_step(APU_VGPU_CYR_FAULT, "sample again");
    check("origin stays", cyr.valid && cyr.r == 8'h00 && cyr.a == 8'hA5 &&
          cyr.word == APU_VGPU_FTX_ORIGIN);
    wlk.word = APU_VGPU_CLEAR_WORD;
    cyk_step(APU_VGPU_CYK_FAULT, "keep clear word");
    check("keep rejected", !cyk.valid);
    wlk.word = APU_VGPU_FTX_ORIGIN;
    cyk_step(APU_VGPU_CYK_OK, "keep origin");
    check("channels kept", cyk.valid && cyk.r == 8'h00 && cyk.a == 8'hA5);
    cyk_step(APU_VGPU_CYK_FAULT, "keep again");
    wlk.word = APU_VGPU_CLEAR_WORD;
    cyx_step(APU_VGPU_CYX_FAULT, "check clear word");
    check("check rejected", !cyx.valid);
    wlk.word = APU_VGPU_FTX_ORIGIN;
    cyx_step(APU_VGPU_CYX_OK, "check red");
    check("red kept", cyx.valid && cyx.b0 == 8'h00 &&
          cyx.a == 8'hA5 && cyx.word == APU_VGPU_FTX_ORIGIN);
    cyx_step(APU_VGPU_CYX_FAULT, "check again");

    pulse_reset();
    check("reset clears", cyr == '0 && cyk == '0 && cyx == '0);
    good_in();
    wlk.word = APU_VGPU_FTX_NEIGHBOR;
    wlk.addr = 14'd4;
    cyr_step(APU_VGPU_CYR_OK, "neighbor channels");
    check("neighbor sample", cyr.r == 8'h00 && cyr.g == 8'h80 &&
          cyr.a == 8'hD2 && cyr.addr == 14'd4);

    if (errors != 0) $fatal(1, "APU vgpu cyr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_cyr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
