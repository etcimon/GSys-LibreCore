// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rrg;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_ray_t ray;
  logic rrg_req = 0, rrg_rdy, rrg_cpl_v, rrg_cpl_r = 0;
  apu_vgpu_rrg_cpl_t rrg_cpl;
  apu_vgpu_rrg_t rrg;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rrk_req = 0, rrk_rdy, rrk_cpl_v, rrk_cpl_r = 0;
  apu_vgpu_rrk_cpl_t rrk_cpl;
  apu_vgpu_rrk_t rrk;
  logic rrx_req = 0, rrx_rdy, rrx_cpl_v, rrx_cpl_r = 0;
  apu_vgpu_rrx_cpl_t rrx_cpl, off_cpl;
  apu_vgpu_rrx_t rrx, off_rrx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_desc = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QRG_WORD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rrg #(.Enable(1'b1)) i_rrg (
    .clk_i(clk), .rst_ni, .ray_i(ray),
    .req_valid_i(rrg_req), .req_ready_o(rrg_rdy),
    .cpl_valid_o(rrg_cpl_v), .cpl_ready_i(rrg_cpl_r), .cpl_o(rrg_cpl), .rrg_o(rrg),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rrk #(.Enable(1'b1)) i_rrk (
    .clk_i(clk), .rst_ni, .rrg_i(rrg), .ray_i(ray),
    .req_valid_i(rrk_req), .req_ready_o(rrk_rdy),
    .cpl_valid_o(rrk_cpl_v), .cpl_ready_i(rrk_cpl_r), .cpl_o(rrk_cpl), .rrk_o(rrk)
  );
  g6lc_apu_vgpu_rrx #(.Enable(1'b1)) i_rrx (
    .clk_i(clk), .rst_ni, .rrk_i(rrk), .rrg_i(rrg), .ray_i(ray),
    .req_valid_i(rrx_req), .req_ready_o(rrx_rdy),
    .cpl_valid_o(rrx_cpl_v), .cpl_ready_i(rrx_cpl_r), .cpl_o(rrx_cpl), .rrx_o(rrx)
  );
  g6lc_apu_vgpu_rrx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rrk_i(rrk), .rrg_i(rrg), .ray_i(ray),
    .req_valid_i(rrx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rrx_cpl_r), .cpl_o(off_cpl), .rrx_o(off_rrx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rrg timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_desc) beat[31:0] = APU_VGPU_QRG_BAD;
      if (rd_addr != APU_VGPU_QRG_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_desc <= 1'b0;
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
    ray = '0;
    ray.valid = 1'b1;
    ray.avail_idx = APU_VGPU_TUW_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rrx == '0 &&
          off_cpl == '0);
  endtask

  task automatic rrg_step(input apu_vgpu_rrg_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rrg_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rrg_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rrg_req = 1'b0;
    while (!rrg_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rrg_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RRG_OK) begin
      check("ring name", rrg.valid && rrg.desc_id == 16'd0 &&
            rrg.desc_id != 16'd1 &&
            rrg.addr == APU_VGPU_QRG_ADDR &&
            rrg.addr != APU_VGPU_QRG_SCENE &&
            rrg.addr != APU_VGPU_QAV_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QRG_ADDR && rd_seen != APU_VGPU_QRG_SCENE);
    end else if (name == "bad beat" || name == "bad desc") begin
      check("one read failed", nread == n0 + 1 && !rrg.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rrg_cpl_v);
    rrg_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rrg_cpl_r = 1'b0;
    while (rrg_cpl_v) @(negedge clk);
  endtask

  task automatic rrk_step(input apu_vgpu_rrk_status_e st, input string name);
    @(negedge clk);
    while (!rrk_rdy) @(negedge clk);
    cases++;
    rrk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rrk_req = 1'b0;
    while (!rrk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rrk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rrk_cpl_v);
    rrk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rrk_cpl_r = 1'b0;
    while (rrk_cpl_v) @(negedge clk);
  endtask

  task automatic rrx_step(input apu_vgpu_rrx_status_e st, input string name);
    @(negedge clk);
    while (!rrx_rdy) @(negedge clk);
    cases++;
    rrx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rrx_req = 1'b0;
    while (!rrx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rrx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rrx_cpl_v);
    rrx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rrx_cpl_r = 1'b0;
    while (rrx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rrg_req = 1'b0;
    rrk_req = 1'b0;
    rrx_req = 1'b0;
    rrg_cpl_r = 1'b0;
    rrk_cpl_r = 1'b0;
    rrx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    ray = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rrg == '0 && rrk == '0 && rrx == '0);
    check("profiles keep the ring peek off",
          !ApuOff.RrgEn && !ApuOff.RrkEn && !ApuOff.RrxEn &&
          !ApuP1Transport.RrgEn && !ApuP1Transport.RrkEn &&
          !ApuP1Transport.RrxEn &&
          !ApuHarness.RrgEn && !ApuHarness.RrkEn && !ApuHarness.RrxEn &&
          !ApuSchedBoth.RrgEn && !ApuSchedBoth.RrkEn && !ApuSchedBoth.RrxEn &&
          !ApuBadVirglGrant.RrgEn && !ApuBadVirglGrant.RrkEn &&
          !ApuBadVirglGrant.RrxEn);
    cfg = ApuP1Transport;
    cfg.RrgEn = 1'b1;
    cfg.RrkEn = 1'b1;
    cfg.RrxEn = 1'b1;
    check("ring peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RrgEn = 1'b1;
    cfg.RrkEn = 1'b1;
    cfg.RrxEn = 1'b1;
    check("ring peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("ring places",
          APU_VGPU_QRG_ADDR == 64'h880D0104 &&
          APU_VGPU_QRG_ADDR != APU_VGPU_QAV_ADDR &&
          APU_VGPU_QRG_SCENE == 64'h8800E204 &&
          APU_VGPU_QRG_DESC == 16'd0 &&
          APU_VGPU_QRG_WORD == 32'h00070000 &&
          APU_VGPU_QRG_BAD == 32'h00070001);

    rrg_step(APU_VGPU_RRG_EMPTY, "read empty");
    rrk_step(APU_VGPU_RRK_EMPTY, "keep empty");
    rrx_step(APU_VGPU_RRX_EMPTY, "check empty");
    good_in();
    ray.avail_idx = 16'd1;
    rrg_step(APU_VGPU_RRG_FAULT, "scene index");
    good_in();
    fail_rd = 1'b1;
    rrg_step(APU_VGPU_RRG_FAULT, "bad beat");
    bad_desc = 1'b1;
    rrg_step(APU_VGPU_RRG_FAULT, "bad desc");
    rrg_step(APU_VGPU_RRG_OK, "ring name");
    rrg_step(APU_VGPU_RRG_FAULT, "ring again");
    check("ring stays", rrg.valid && rrg.desc_id == 16'd0 &&
          rrg.addr == APU_VGPU_QRG_ADDR);
    ray.avail_idx = 16'd1;
    rrk_step(APU_VGPU_RRK_FAULT, "keep scene index");
    check("keep rejected", !rrk.valid);
    good_in();
    rrk_step(APU_VGPU_RRK_OK, "keep name");
    check("name kept", rrk.valid && rrk.desc_id == 16'd0 &&
          rrk.addr == APU_VGPU_QRG_ADDR);
    rrk_step(APU_VGPU_RRK_FAULT, "keep again");
    ray.avail_idx = 16'd1;
    rrx_step(APU_VGPU_RRX_FAULT, "check scene index");
    check("check rejected", !rrx.valid);
    good_in();
    rrx_step(APU_VGPU_RRX_OK, "check name");
    check("name checked", rrx.valid && rrx.desc_id == 16'd0);
    rrx_step(APU_VGPU_RRX_FAULT, "check again");
    check("check stays", rrx.desc_id == rrg.desc_id);

    pulse_reset();
    check("reset clears", rrg == '0 && rrk == '0 && rrx == '0);
    ray = '0;
    rrg_step(APU_VGPU_RRG_EMPTY, "after reset");
    good_in();
    rrg_step(APU_VGPU_RRG_OK, "ring after reset");

    if (errors != 0) $fatal(1, "APU vgpu rrg errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rrg cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
