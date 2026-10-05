// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ftx;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_tbn_t tbn;
  apu_vgpu_acx_t acx;
  logic ftx_req = 0, ftx_rdy, ftx_cpl_v, ftx_cpl_r = 0;
  apu_vgpu_ftx_cpl_t ftx_cpl;
  apu_vgpu_ftx_t ftx;
  logic ftr_req = 0, ftr_rdy, ftr_cpl_v, ftr_cpl_r = 0;
  apu_vgpu_ftr_cpl_t ftr_cpl;
  apu_vgpu_ftr_t ftr;
  logic ftk_req = 0, ftk_rdy, ftk_cpl_v, ftk_cpl_r = 0;
  apu_vgpu_ftk_cpl_t ftk_cpl, off_cpl;
  apu_vgpu_ftk_t ftk, off_ftk;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_ftx #(.Enable(1'b1)) i_ftx (
    .clk_i(clk), .rst_ni, .tbn_i(tbn), .acx_i(acx),
    .req_valid_i(ftx_req), .req_ready_o(ftx_rdy),
    .cpl_valid_o(ftx_cpl_v), .cpl_ready_i(ftx_cpl_r), .cpl_o(ftx_cpl), .ftx_o(ftx)
  );
  g6lc_apu_vgpu_ftr #(.Enable(1'b1)) i_ftr (
    .clk_i(clk), .rst_ni, .ftx_i(ftx), .tbn_i(tbn), .acx_i(acx),
    .req_valid_i(ftr_req), .req_ready_o(ftr_rdy),
    .cpl_valid_o(ftr_cpl_v), .cpl_ready_i(ftr_cpl_r), .cpl_o(ftr_cpl), .ftr_o(ftr)
  );
  g6lc_apu_vgpu_ftk #(.Enable(1'b1)) i_ftk (
    .clk_i(clk), .rst_ni, .ftr_i(ftr), .ftx_i(ftx), .tbn_i(tbn),
    .req_valid_i(ftk_req), .req_ready_o(ftk_rdy),
    .cpl_valid_o(ftk_cpl_v), .cpl_ready_i(ftk_cpl_r), .cpl_o(ftk_cpl), .ftk_o(ftk)
  );
  g6lc_apu_vgpu_ftk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .ftr_i(ftr), .ftx_i(ftx), .tbn_i(tbn),
    .req_valid_i(ftk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(ftk_cpl_r), .cpl_o(off_cpl), .ftk_o(off_ftk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu ftx timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_in;
    tbn = '0;
    tbn.valid = 1'b1;
    tbn.resource_id = APU_VIRGL_RES_SCAN;
    tbn.view = APU_VIRGL_SV_HANDLE;
    tbn.sampler = APU_VIRGL_SS_HANDLE;
    acx = '0;
    acx.valid = 1'b1;
    acx.format = APU_VIRGL_FMT_B8G8R8X8;
    acx.off0 = APU_VGPU_ACW_AT0;
    acx.off1 = APU_VGPU_ACW_AT1;
    acx.x0 = 7'd0;
    acx.x1 = 7'd1;
    acx.b0 = 8'h00;
    acx.origin = APU_VGPU_FTX_ORIGIN;
    acx.neighbor = APU_VGPU_FTX_NEIGHBOR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_ftk == '0 &&
          off_cpl == '0);
  endtask

  task automatic ftx_step(input apu_vgpu_ftx_status_e st, input string name);
    @(negedge clk);
    while (!ftx_rdy) @(negedge clk);
    cases++;
    ftx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ftx_req = 1'b0;
    while (!ftx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ftx_cpl.status == st);
    quiet();
    if (st == APU_VGPU_FTX_OK) begin
      check("sampled", ftx.valid && ftx.refused == 1'b0 &&
            ftx.origin == APU_VGPU_FTX_ORIGIN &&
            ftx.neighbor == APU_VGPU_FTX_NEIGHBOR &&
            ftx.origin != APU_VGPU_CLEAR_WORD &&
            ftx.view == APU_VIRGL_SV_HANDLE &&
            ftx.resource_id == APU_VIRGL_RES_SCAN);
    end else if (name != "sample again") begin
      check("no sample", !ftx.valid);
    end
    @(negedge clk);
    check($sformatf("%s held", name), ftx_cpl_v);
    ftx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ftx_cpl_r = 1'b0;
    while (ftx_cpl_v) @(negedge clk);
  endtask

  task automatic ftr_step(input apu_vgpu_ftr_status_e st, input string name);
    @(negedge clk);
    while (!ftr_rdy) @(negedge clk);
    cases++;
    ftr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ftr_req = 1'b0;
    while (!ftr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ftr_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), ftr_cpl_v);
    ftr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ftr_cpl_r = 1'b0;
    while (ftr_cpl_v) @(negedge clk);
  endtask

  task automatic ftk_step(input apu_vgpu_ftk_status_e st, input string name);
    @(negedge clk);
    while (!ftk_rdy) @(negedge clk);
    cases++;
    ftk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ftk_req = 1'b0;
    while (!ftk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ftk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), ftk_cpl_v);
    ftk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ftk_cpl_r = 1'b0;
    while (ftk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    ftx_req = 1'b0;
    ftr_req = 1'b0;
    ftk_req = 1'b0;
    ftx_cpl_r = 1'b0;
    ftr_cpl_r = 1'b0;
    ftk_cpl_r = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    tbn = '0;
    acx = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          ftx == '0 && ftr == '0 && ftk == '0);
    check("profiles keep the sample off",
          !ApuOff.FtxEn && !ApuOff.FtrEn && !ApuOff.FtkEn &&
          !ApuP1Transport.FtxEn && !ApuP1Transport.FtrEn && !ApuP1Transport.FtkEn &&
          !ApuHarness.FtxEn && !ApuHarness.FtrEn && !ApuHarness.FtkEn &&
          !ApuSchedBoth.FtxEn && !ApuSchedBoth.FtrEn && !ApuSchedBoth.FtkEn &&
          !ApuBadVirglGrant.FtxEn && !ApuBadVirglGrant.FtrEn &&
          !ApuBadVirglGrant.FtkEn);
    cfg = ApuP1Transport;
    cfg.FtxEn = 1'b1;
    cfg.FtrEn = 1'b1;
    cfg.FtkEn = 1'b1;
    check("sample does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.FtxEn = 1'b1;
    cfg.FtrEn = 1'b1;
    cfg.FtkEn = 1'b1;
    check("sample does not legalize virgl", !apu_cfg_legal(cfg));
    check("known samples",
          APU_VGPU_FTX_ORIGIN != APU_VGPU_CLEAR_WORD &&
          APU_VGPU_FTX_NEIGHBOR != APU_VGPU_CLEAR_WORD &&
          APU_VGPU_FTX_ORIGIN != APU_VGPU_FTX_NEIGHBOR &&
          APU_VGPU_FTX_ORIGIN != {APU_VGPU_CLEAR_A, APU_VGPU_CLEAR_B,
                                 APU_VGPU_CLEAR_G, APU_VGPU_CLEAR_R} &&
          APU_VIRGL_SV_HANDLE == 32'd5 &&
          APU_VIRGL_RES_SCAN == 32'd1);

    ftx_step(APU_VGPU_FTX_EMPTY, "sample empty");
    ftr_step(APU_VGPU_FTR_EMPTY, "keep empty");
    ftk_step(APU_VGPU_FTK_EMPTY, "check empty");
    good_in();
    tbn = '0;
    ftx_step(APU_VGPU_FTX_EMPTY, "bind missing");
    good_in();
    tbn.view = 32'd4;
    ftx_step(APU_VGPU_FTX_FAULT, "bad view");
    good_in();
    acx.origin = APU_VGPU_CLEAR_WORD;
    ftx_step(APU_VGPU_FTX_FAULT, "clear origin");
    good_in();
    acx.neighbor = APU_VGPU_CLEAR_WORD;
    ftx_step(APU_VGPU_FTX_FAULT, "clear neighbor");
    good_in();
    acx.origin = APU_VGPU_FTX_NEIGHBOR;
    ftx_step(APU_VGPU_FTX_FAULT, "same taps");
    good_in();
    acx.b0 = APU_VGPU_CLEAR_R;
    ftx_step(APU_VGPU_FTX_FAULT, "clear red");
    good_in();
    ftx_step(APU_VGPU_FTX_OK, "sample");
    ftx_step(APU_VGPU_FTX_FAULT, "sample again");
    check("sample stays", ftx.valid && ftx.refused == 1'b0 &&
          ftx.origin == APU_VGPU_FTX_ORIGIN);
    acx.origin = APU_VGPU_CLEAR_WORD;
    ftr_step(APU_VGPU_FTR_FAULT, "keep clear origin");
    check("keep rejected", !ftr.valid);
    acx.origin = APU_VGPU_FTX_ORIGIN;
    ftr_step(APU_VGPU_FTR_OK, "keep sample");
    check("sample kept", ftr.valid && ftr.refused == 1'b0 &&
          ftr.origin == APU_VGPU_FTX_ORIGIN &&
          ftr.neighbor == APU_VGPU_FTX_NEIGHBOR);
    ftr_step(APU_VGPU_FTR_FAULT, "keep again");
    tbn.view = 32'd4;
    ftk_step(APU_VGPU_FTK_FAULT, "check bad view");
    check("check rejected", !ftk.valid);
    tbn.view = APU_VIRGL_SV_HANDLE;
    ftk_step(APU_VGPU_FTK_OK, "check sample");
    check("tex kept", ftk.valid && ftk.refused == 1'b0 &&
          ftk.origin == APU_VGPU_FTX_ORIGIN);
    ftk_step(APU_VGPU_FTK_FAULT, "check again");
    check("check stays", ftk.origin == ftx.origin && ftk.refused == 1'b0);

    pulse_reset();
    check("reset clears", ftx == '0 && ftr == '0 && ftk == '0);
    zero_in();
    ftx_step(APU_VGPU_FTX_EMPTY, "after reset");
    good_in();
    ftx_step(APU_VGPU_FTX_OK, "sample after reset");

    if (errors != 0) $fatal(1, "APU vgpu ftx errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ftx cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
