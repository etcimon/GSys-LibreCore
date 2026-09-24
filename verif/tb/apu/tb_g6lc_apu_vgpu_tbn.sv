// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tbn;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fst_t fst;
  apu_vgpu_fsb_t fsb;
  apu_vgpu_sv_t sv;
  apu_vgpu_ss_t ss;
  apu_vgpu_svb_t svb;
  apu_vgpu_ssb_t ssb;
  apu_vgpu_cv_t cv;
  logic tbn_req = 0, tbn_rdy, tbn_cpl_v, tbn_cpl_r = 0;
  apu_vgpu_tbn_cpl_t tbn_cpl;
  apu_vgpu_tbn_t tbn;
  logic den_req = 0, den_rdy, den_cpl_v, den_cpl_r = 0;
  apu_vgpu_den_cpl_t den_cpl;
  apu_vgpu_den_t den;
  logic [15:0] dx, dy;
  logic dnr_req = 0, dnr_rdy, dnr_cpl_v, dnr_cpl_r = 0;
  apu_vgpu_dnr_cpl_t dnr_cpl, off_cpl;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_tbn #(.Enable(1'b1)) i_tbn (
    .clk_i(clk), .rst_ni, .fst_i(fst), .fsb_i(fsb), .sv_i(sv), .ss_i(ss),
    .svb_i(svb), .ssb_i(ssb),
    .req_valid_i(tbn_req), .req_ready_o(tbn_rdy),
    .cpl_valid_o(tbn_cpl_v), .cpl_ready_i(tbn_cpl_r), .cpl_o(tbn_cpl), .tbn_o(tbn)
  );
  g6lc_apu_vgpu_den #(.Enable(1'b1)) i_den (
    .clk_i(clk), .rst_ni, .tbn_i(tbn), .cv_i(cv),
    .req_valid_i(den_req), .req_ready_o(den_rdy),
    .cpl_valid_o(den_cpl_v), .cpl_ready_i(den_cpl_r), .cpl_o(den_cpl), .den_o(den)
  );
  g6lc_apu_vgpu_dnr #(.Enable(1'b1)) i_dnr (
    .clk_i(clk), .rst_ni, .den_i(den), .x_i(dx), .y_i(dy),
    .req_valid_i(dnr_req), .req_ready_o(dnr_rdy),
    .cpl_valid_o(dnr_cpl_v), .cpl_ready_i(dnr_cpl_r), .cpl_o(dnr_cpl)
  );
  g6lc_apu_vgpu_dnr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .den_i(den), .x_i(dx), .y_i(dy),
    .req_valid_i(dnr_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(dnr_cpl_r), .cpl_o(off_cpl)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu tbn timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_bind;
    fst = '0;
    fst.valid = 1'b1;
    fst.tex = 1'b1;
    fsb = '0;
    fsb.valid = 1'b1;
    fsb.handle = APU_VIRGL_FS_HANDLE;
    fsb.stage = APU_VIRGL_SHADER_FRAGMENT;
    fsb.next = APU_VIRGL_FSB_NEXT;
    sv = '0;
    sv.valid = 1'b1;
    sv.handle = APU_VIRGL_SV_HANDLE;
    sv.resource_id = APU_VIRGL_RES_SCAN;
    sv.format = 24'h2;
    sv.target = APU_VIRGL_TARGET_2D;
    sv.swizzle = APU_VIRGL_SWIZZLE_IDENTITY;
    sv.next = APU_VIRGL_SV_NEXT;
    ss = '0;
    ss.valid = 1'b1;
    ss.handle = APU_VIRGL_SS_HANDLE;
    ss.s0 = APU_VIRGL_SSTATE_S0;
    ss.max_lod = APU_VIRGL_SSTATE_MAX_LOD;
    ss.next = APU_VIRGL_SS_NEXT;
    ssb = '0;
    ssb.valid = 1'b1;
    ssb.stage = APU_VIRGL_SHADER_FRAGMENT;
    ssb.slot = 32'd0;
    ssb.handle = APU_VIRGL_SS_HANDLE;
    ssb.next = APU_VIRGL_SSB_NEXT;
    svb = '0;
    svb.valid = 1'b1;
    svb.stage = APU_VIRGL_SHADER_FRAGMENT;
    svb.slot = 32'd0;
    svb.handle = APU_VIRGL_SV_HANDLE;
    svb.next = APU_VIRGL_SVB_NEXT;
  endtask

  task automatic good_cv;
    cv = '0;
    cv.valid = 1'b1;
    cv.covered = 1'b1;
    cv.word = APU_VGPU_CLEAR_WORD;
    cv.samples = APU_VGPU_FILL_N;
  endtask

  task automatic tbn_step(input apu_vgpu_tbn_status_e st, input string name);
    @(negedge clk);
    while (!tbn_rdy) @(negedge clk);
    cases++;
    tbn_req = 1;
    @(posedge clk); @(negedge clk); tbn_req = 0;
    while (!tbn_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tbn_cpl.status == st);
    if (st == APU_VGPU_TBN_OK)
      check($sformatf("%s bind", name), tbn.valid &&
            tbn.resource_id == APU_VIRGL_RES_SCAN &&
            tbn.view == APU_VIRGL_SV_HANDLE &&
            tbn.sampler == APU_VIRGL_SS_HANDLE);
    @(negedge clk);
    check($sformatf("%s held", name), tbn_cpl_v);
    tbn_cpl_r = 1;
    @(posedge clk); @(negedge clk); tbn_cpl_r = 0;
    while (tbn_cpl_v) @(negedge clk);
  endtask

  task automatic den_step(input apu_vgpu_den_status_e st, input string name);
    @(negedge clk);
    while (!den_rdy) @(negedge clk);
    cases++;
    den_req = 1;
    @(posedge clk); @(negedge clk); den_req = 0;
    while (!den_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), den_cpl.status == st);
    if (st == APU_VGPU_DEN_OK)
      check($sformatf("%s refuse", name), den.valid && den.refused &&
            den.resource_id == APU_VIRGL_RES_SCAN &&
            den.word == APU_VGPU_CLEAR_WORD && den.samples == APU_VGPU_FILL_N);
    @(negedge clk);
    check($sformatf("%s held", name), den_cpl_v);
    den_cpl_r = 1;
    @(posedge clk); @(negedge clk); den_cpl_r = 0;
    while (den_cpl_v) @(negedge clk);
  endtask

  task automatic dnr_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_dnr_status_e st,
    input logic [13:0] addr,
    input string name
  );
    @(negedge clk);
    while (!dnr_rdy) @(negedge clk);
    cases++;
    dx = x;
    dy = y;
    dnr_req = 1;
    @(posedge clk); @(negedge clk); dnr_req = 0;
    while (!dnr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), dnr_cpl.status == st);
    if (st == APU_VGPU_DNR_OK)
      check($sformatf("%s sample", name), dnr_cpl.refused &&
            dnr_cpl.word == APU_VGPU_CLEAR_WORD && dnr_cpl.addr == addr);
    else
      check($sformatf("%s quiet", name), !dnr_cpl.refused && dnr_cpl.word == 32'h0);
    check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), dnr_cpl_v);
    dnr_cpl_r = 1;
    @(posedge clk); @(negedge clk); dnr_cpl_r = 0;
    while (dnr_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    tbn_req = 0;
    den_req = 0;
    dnr_req = 0;
    tbn_cpl_r = 0;
    den_cpl_r = 0;
    dnr_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    fst = '0;
    fsb = '0;
    sv = '0;
    ss = '0;
    svb = '0;
    ssb = '0;
    cv = '0;
    dx = '0;
    dy = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && tbn == '0 && den == '0);
    check("profiles keep bind off",
          !ApuOff.TbnEn && !ApuOff.DenEn && !ApuOff.DnrEn &&
          !ApuP1Transport.TbnEn && !ApuP1Transport.DenEn && !ApuP1Transport.DnrEn &&
          !ApuHarness.TbnEn && !ApuHarness.DenEn && !ApuHarness.DnrEn &&
          !ApuSchedBoth.TbnEn && !ApuSchedBoth.DenEn && !ApuSchedBoth.DnrEn &&
          !ApuBadVirglGrant.TbnEn && !ApuBadVirglGrant.DenEn && !ApuBadVirglGrant.DnrEn);
    cfg = ApuP1Transport;
    cfg.TbnEn = 1'b1;
    cfg.DenEn = 1'b1;
    cfg.DnrEn = 1'b1;
    check("bind does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.TbnEn = 1'b1;
    cfg.DenEn = 1'b1;
    cfg.DnrEn = 1'b1;
    check("bind does not legalize virgl", !apu_cfg_legal(cfg));
    check("bind offsets",
          APU_VIRGL_SV_NEXT == 32'd408 && APU_VIRGL_SS_NEXT == 32'd448 &&
          APU_VIRGL_FSB_NEXT == 32'd608 && APU_VIRGL_SSB_NEXT == 32'd632 &&
          APU_VIRGL_SVB_NEXT == 32'd648 &&
          APU_VIRGL_SSTATE_S0 == 32'h00002292 &&
          APU_VIRGL_SSTATE_MAX_LOD == 32'h42000000 &&
          APU_VIRGL_SWIZZLE_IDENTITY == 32'h00000688 &&
          APU_VIRGL_RES_SCAN == 32'd1);

    tbn_step(APU_VGPU_TBN_EMPTY, "tbn empty");
    good_bind();
    fst.tex = 1'b0;
    tbn_step(APU_VGPU_TBN_FAULT, "not tex");
    check("tex keeps", !tbn.valid);
    good_bind();
    sv.resource_id = APU_VIRGL_RES_RT;
    tbn_step(APU_VGPU_TBN_FAULT, "other resource");
    check("resource keeps", !tbn.valid);
    good_bind();
    tbn_step(APU_VGPU_TBN_OK, "bind");
    check("bind kept", tbn.valid && tbn.resource_id == 32'd1 &&
          tbn.view == 32'd5 && tbn.sampler == 32'd6);
    tbn_step(APU_VGPU_TBN_FAULT, "bind again");
    check("bind stays", tbn.resource_id == APU_VIRGL_RES_SCAN);

    den_step(APU_VGPU_DEN_EMPTY, "den empty");
    good_cv();
    cv.word = 32'h0;
    den_step(APU_VGPU_DEN_FAULT, "bad color");
    check("color keeps", !den.valid);
    good_cv();
    den_step(APU_VGPU_DEN_OK, "refuse");
    check("still clear", den.refused && den.word == 32'hFF1A0D0D &&
          den.samples == 32'd4096);
    den_step(APU_VGPU_DEN_FAULT, "refuse again");
    check("refuse stays", den.valid && den.refused);

    dnr_step(16'd1, 16'd0, APU_VGPU_DNR_OK, 14'd4, "interior");
    dnr_step(16'd2, 16'd3, APU_VGPU_DNR_OK, 14'd776, "sample 2,3");
    dnr_step(16'd63, 16'd63, APU_VGPU_DNR_OK, APU_VGPU_PIX_XY, "corner");
    dnr_step(16'd64, 16'd0, APU_VGPU_DNR_FAULT, 14'd0, "outside");
    dnr_step(16'd1, 16'd0, APU_VGPU_DNR_OK, 14'd4, "reread");

    pulse_reset();
    check("reset clears", tbn == '0 && den == '0);
    dnr_step(16'd1, 16'd0, APU_VGPU_DNR_EMPTY, 14'd0, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu tbn errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tbn cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
