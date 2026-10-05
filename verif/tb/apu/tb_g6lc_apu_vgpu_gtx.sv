// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_gtx;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_ftk_t ftk;
  apu_vgpu_rgx_t rgx;
  logic gtx_req = 0, gtx_rdy, gtx_cpl_v, gtx_cpl_r = 0;
  apu_vgpu_gtx_cpl_t gtx_cpl;
  apu_vgpu_gtx_t gtx;
  logic gtr_req = 0, gtr_rdy, gtr_cpl_v, gtr_cpl_r = 0;
  apu_vgpu_gtr_cpl_t gtr_cpl;
  apu_vgpu_gtr_t gtr;
  logic gtk_req = 0, gtk_rdy, gtk_cpl_v, gtk_cpl_r = 0;
  apu_vgpu_gtk_cpl_t gtk_cpl, off_cpl;
  apu_vgpu_gtk_t gtk, off_gtk;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_gtx #(.Enable(1'b1)) i_gtx (
    .clk_i(clk), .rst_ni, .ftk_i(ftk), .rgx_i(rgx),
    .req_valid_i(gtx_req), .req_ready_o(gtx_rdy),
    .cpl_valid_o(gtx_cpl_v), .cpl_ready_i(gtx_cpl_r), .cpl_o(gtx_cpl), .gtx_o(gtx)
  );
  g6lc_apu_vgpu_gtr #(.Enable(1'b1)) i_gtr (
    .clk_i(clk), .rst_ni, .gtx_i(gtx), .ftk_i(ftk), .rgx_i(rgx),
    .req_valid_i(gtr_req), .req_ready_o(gtr_rdy),
    .cpl_valid_o(gtr_cpl_v), .cpl_ready_i(gtr_cpl_r), .cpl_o(gtr_cpl), .gtr_o(gtr)
  );
  g6lc_apu_vgpu_gtk #(.Enable(1'b1)) i_gtk (
    .clk_i(clk), .rst_ni, .gtr_i(gtr), .gtx_i(gtx), .ftk_i(ftk),
    .req_valid_i(gtk_req), .req_ready_o(gtk_rdy),
    .cpl_valid_o(gtk_cpl_v), .cpl_ready_i(gtk_cpl_r), .cpl_o(gtk_cpl), .gtk_o(gtk)
  );
  g6lc_apu_vgpu_gtk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .gtr_i(gtr), .gtx_i(gtx), .ftk_i(ftk),
    .req_valid_i(gtk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(gtk_cpl_r), .cpl_o(off_cpl), .gtk_o(off_gtk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu gtx timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_in;
    ftk = '0;
    ftk.valid = 1'b1;
    ftk.refused = 1'b0;
    ftk.origin = APU_VGPU_FTX_ORIGIN;
    ftk.neighbor = APU_VGPU_FTX_NEIGHBOR;
    rgx = '0;
    rgx.valid = 1'b1;
    rgx.ack = APU_VGPU_TIW_REASON;
    rgx.remain = APU_VGPU_VAW_CLEAR;
    rgx.used_idx = APU_VGPU_TUW_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_gtk == '0 &&
          off_cpl == '0);
  endtask

  task automatic gtx_step(input apu_vgpu_gtx_status_e st, input string name);
    @(negedge clk);
    while (!gtx_rdy) @(negedge clk);
    cases++;
    gtx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gtx_req = 1'b0;
    while (!gtx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gtx_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GTX_OK) begin
      check("sampled", gtx.valid && gtx.refused == 1'b0 &&
            gtx.origin == APU_VGPU_FTX_ORIGIN &&
            gtx.neighbor == APU_VGPU_FTX_NEIGHBOR &&
            gtx.origin != APU_VGPU_CLEAR_WORD &&
            gtx.used_idx == APU_VGPU_TUW_IDXV &&
            gtx.used_idx != APU_VGPU_QSU_IDXV);
    end else if (name != "sample again") begin
      check("no sample", !gtx.valid);
    end
    @(negedge clk);
    check($sformatf("%s held", name), gtx_cpl_v);
    gtx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gtx_cpl_r = 1'b0;
    while (gtx_cpl_v) @(negedge clk);
  endtask

  task automatic gtr_step(input apu_vgpu_gtr_status_e st, input string name);
    @(negedge clk);
    while (!gtr_rdy) @(negedge clk);
    cases++;
    gtr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gtr_req = 1'b0;
    while (!gtr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gtr_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gtr_cpl_v);
    gtr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gtr_cpl_r = 1'b0;
    while (gtr_cpl_v) @(negedge clk);
  endtask

  task automatic gtk_step(input apu_vgpu_gtk_status_e st, input string name);
    @(negedge clk);
    while (!gtk_rdy) @(negedge clk);
    cases++;
    gtk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gtk_req = 1'b0;
    while (!gtk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gtk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gtk_cpl_v);
    gtk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gtk_cpl_r = 1'b0;
    while (gtk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    gtx_req = 1'b0;
    gtr_req = 1'b0;
    gtk_req = 1'b0;
    gtx_cpl_r = 1'b0;
    gtr_cpl_r = 1'b0;
    gtk_cpl_r = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    ftk = '0;
    rgx = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          gtx == '0 && gtr == '0 && gtk == '0);
    check("profiles keep the sample off",
          !ApuOff.GtxEn && !ApuOff.GtrEn && !ApuOff.GtkEn &&
          !ApuP1Transport.GtxEn && !ApuP1Transport.GtrEn && !ApuP1Transport.GtkEn &&
          !ApuHarness.GtxEn && !ApuHarness.GtrEn && !ApuHarness.GtkEn &&
          !ApuSchedBoth.GtxEn && !ApuSchedBoth.GtrEn && !ApuSchedBoth.GtkEn &&
          !ApuBadVirglGrant.GtxEn && !ApuBadVirglGrant.GtrEn &&
          !ApuBadVirglGrant.GtkEn);
    cfg = ApuP1Transport;
    cfg.GtxEn = 1'b1;
    cfg.GtrEn = 1'b1;
    cfg.GtkEn = 1'b1;
    check("sample does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GtxEn = 1'b1;
    cfg.GtrEn = 1'b1;
    cfg.GtkEn = 1'b1;
    check("sample does not legalize virgl", !apu_cfg_legal(cfg));
    check("known samples",
          APU_VGPU_FTX_ORIGIN != APU_VGPU_CLEAR_WORD &&
          APU_VGPU_FTX_NEIGHBOR != APU_VGPU_CLEAR_WORD &&
          APU_VGPU_TUW_IDXV != APU_VGPU_QSU_IDXV &&
          APU_VGPU_TIW_REASON == 32'h1);

    gtx_step(APU_VGPU_GTX_EMPTY, "sample empty");
    gtr_step(APU_VGPU_GTR_EMPTY, "keep empty");
    gtk_step(APU_VGPU_GTK_EMPTY, "check empty");
    good_in();
    ftk = '0;
    gtx_step(APU_VGPU_GTX_EMPTY, "tex missing");
    good_in();
    rgx = '0;
    gtx_step(APU_VGPU_GTX_EMPTY, "ack missing");
    good_in();
    ftk.refused = 1'b1;
    gtx_step(APU_VGPU_GTX_FAULT, "refused tex");
    good_in();
    ftk.origin = APU_VGPU_CLEAR_WORD;
    gtx_step(APU_VGPU_GTX_FAULT, "clear origin");
    good_in();
    rgx.used_idx = APU_VGPU_QSU_IDXV;
    gtx_step(APU_VGPU_GTX_FAULT, "scene idx");
    good_in();
    gtx_step(APU_VGPU_GTX_OK, "sample");
    gtx_step(APU_VGPU_GTX_FAULT, "sample again");
    check("sample stays", gtx.valid && gtx.refused == 1'b0 &&
          gtx.origin == APU_VGPU_FTX_ORIGIN &&
          gtx.used_idx == APU_VGPU_TUW_IDXV);
    ftk.origin = APU_VGPU_CLEAR_WORD;
    gtr_step(APU_VGPU_GTR_FAULT, "keep clear origin");
    check("keep rejected", !gtr.valid);
    ftk.origin = APU_VGPU_FTX_ORIGIN;
    gtr_step(APU_VGPU_GTR_OK, "keep sample");
    check("sample kept", gtr.valid && gtr.refused == 1'b0 &&
          gtr.origin == APU_VGPU_FTX_ORIGIN &&
          gtr.used_idx == APU_VGPU_TUW_IDXV);
    gtr_step(APU_VGPU_GTR_FAULT, "keep again");
    ftk.refused = 1'b1;
    gtk_step(APU_VGPU_GTK_FAULT, "check refused");
    check("check rejected", !gtk.valid);
    ftk.refused = 1'b0;
    gtk_step(APU_VGPU_GTK_OK, "check sample");
    check("tex kept", gtk.valid && gtk.refused == 1'b0 &&
          gtk.origin == APU_VGPU_FTX_ORIGIN &&
          gtk.used_idx == APU_VGPU_TUW_IDXV);
    gtk_step(APU_VGPU_GTK_FAULT, "check again");
    check("check stays", gtk.origin == gtx.origin && gtk.refused == 1'b0);

    pulse_reset();
    check("reset clears", gtx == '0 && gtr == '0 && gtk == '0);
    zero_in();
    gtx_step(APU_VGPU_GTX_EMPTY, "after reset");
    good_in();
    gtx_step(APU_VGPU_GTX_OK, "sample after reset");

    if (errors != 0) $fatal(1, "APU vgpu gtx errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_gtx cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
