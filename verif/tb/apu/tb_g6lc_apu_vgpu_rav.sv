// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rav;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rny_t rny;
  logic rav_req = 0, rav_rdy, rav_cpl_v, rav_cpl_r = 0;
  apu_vgpu_rav_cpl_t rav_cpl;
  apu_vgpu_rav_t rav;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rak_req = 0, rak_rdy, rak_cpl_v, rak_cpl_r = 0;
  apu_vgpu_rak_cpl_t rak_cpl;
  apu_vgpu_rak_t rak;
  logic ray_req = 0, ray_rdy, ray_cpl_v, ray_cpl_r = 0;
  apu_vgpu_ray_cpl_t ray_cpl, off_cpl;
  apu_vgpu_ray_t ray, off_ray;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_idx = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QAV_WORD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rav #(.Enable(1'b1)) i_rav (
    .clk_i(clk), .rst_ni, .rny_i(rny),
    .req_valid_i(rav_req), .req_ready_o(rav_rdy),
    .cpl_valid_o(rav_cpl_v), .cpl_ready_i(rav_cpl_r), .cpl_o(rav_cpl), .rav_o(rav),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rak #(.Enable(1'b1)) i_rak (
    .clk_i(clk), .rst_ni, .rav_i(rav), .rny_i(rny),
    .req_valid_i(rak_req), .req_ready_o(rak_rdy),
    .cpl_valid_o(rak_cpl_v), .cpl_ready_i(rak_cpl_r), .cpl_o(rak_cpl), .rak_o(rak)
  );
  g6lc_apu_vgpu_ray #(.Enable(1'b1)) i_ray (
    .clk_i(clk), .rst_ni, .rak_i(rak), .rav_i(rav), .rny_i(rny),
    .req_valid_i(ray_req), .req_ready_o(ray_rdy),
    .cpl_valid_o(ray_cpl_v), .cpl_ready_i(ray_cpl_r), .cpl_o(ray_cpl), .ray_o(ray)
  );
  g6lc_apu_vgpu_ray_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rak_i(rak), .rav_i(rav), .rny_i(rny),
    .req_valid_i(ray_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(ray_cpl_r), .cpl_o(off_cpl), .ray_o(off_ray)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rav timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_idx) beat[31:0] = APU_VGPU_QAV_SCENE;
      if (rd_addr != APU_VGPU_QAV_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_idx <= 1'b0;
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
    rny = '0;
    rny.valid = 1'b1;
    rny.qid = APU_VGPU_QNT_QUEUE;
    rny.avail_idx = APU_VGPU_TUW_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_ray == '0 &&
          off_cpl == '0);
  endtask

  task automatic rav_step(input apu_vgpu_rav_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rav_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rav_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rav_req = 1'b0;
    while (!rav_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rav_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RAV_OK) begin
      check("avail idx", rav.valid && rav.avail_idx == 16'd2 &&
            rav.avail_idx != 16'd1 &&
            rav.addr == APU_VGPU_QAV_ADDR &&
            rav.addr != APU_VGPU_NXC_AVAIL);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QAV_ADDR && rd_seen != APU_VGPU_NXC_AVAIL);
    end else if (name == "bad beat" || name == "scene word") begin
      check("one read failed", nread == n0 + 1 && !rav.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rav_cpl_v);
    rav_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rav_cpl_r = 1'b0;
    while (rav_cpl_v) @(negedge clk);
  endtask

  task automatic rak_step(input apu_vgpu_rak_status_e st, input string name);
    @(negedge clk);
    while (!rak_rdy) @(negedge clk);
    cases++;
    rak_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rak_req = 1'b0;
    while (!rak_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rak_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rak_cpl_v);
    rak_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rak_cpl_r = 1'b0;
    while (rak_cpl_v) @(negedge clk);
  endtask

  task automatic ray_step(input apu_vgpu_ray_status_e st, input string name);
    @(negedge clk);
    while (!ray_rdy) @(negedge clk);
    cases++;
    ray_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ray_req = 1'b0;
    while (!ray_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ray_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), ray_cpl_v);
    ray_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ray_cpl_r = 1'b0;
    while (ray_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rav_req = 1'b0;
    rak_req = 1'b0;
    ray_req = 1'b0;
    rav_cpl_r = 1'b0;
    rak_cpl_r = 1'b0;
    ray_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rny = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rav == '0 && rak == '0 && ray == '0);
    check("profiles keep the avail peek off",
          !ApuOff.RavEn && !ApuOff.RakEn && !ApuOff.RayEn &&
          !ApuP1Transport.RavEn && !ApuP1Transport.RakEn &&
          !ApuP1Transport.RayEn &&
          !ApuHarness.RavEn && !ApuHarness.RakEn && !ApuHarness.RayEn &&
          !ApuSchedBoth.RavEn && !ApuSchedBoth.RakEn && !ApuSchedBoth.RayEn &&
          !ApuBadVirglGrant.RavEn && !ApuBadVirglGrant.RakEn &&
          !ApuBadVirglGrant.RayEn);
    cfg = ApuP1Transport;
    cfg.RavEn = 1'b1;
    cfg.RakEn = 1'b1;
    cfg.RayEn = 1'b1;
    check("avail peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RavEn = 1'b1;
    cfg.RakEn = 1'b1;
    cfg.RayEn = 1'b1;
    check("avail peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("avail places",
          APU_VGPU_QAV_ADDR == 64'h880D0100 &&
          APU_VGPU_QAV_ADDR == APU_VGPU_TXC_AVAIL &&
          APU_VGPU_QAV_ADDR != APU_VGPU_NXC_AVAIL &&
          APU_VGPU_QAV_WORD == 32'h00020000 &&
          APU_VGPU_QAV_SCENE == 32'h00010000);

    rav_step(APU_VGPU_RAV_EMPTY, "read empty");
    rak_step(APU_VGPU_RAK_EMPTY, "keep empty");
    ray_step(APU_VGPU_RAY_EMPTY, "check empty");
    good_in();
    rny.qid = APU_VGPU_QNT_CURSOR;
    rav_step(APU_VGPU_RAV_FAULT, "cursor queue");
    rny.qid = APU_VGPU_QNT_QUEUE;
    rny.avail_idx = 16'd1;
    rav_step(APU_VGPU_RAV_FAULT, "scene index");
    good_in();
    fail_rd = 1'b1;
    rav_step(APU_VGPU_RAV_FAULT, "bad beat");
    bad_idx = 1'b1;
    rav_step(APU_VGPU_RAV_FAULT, "scene word");
    rav_step(APU_VGPU_RAV_OK, "avail idx");
    rav_step(APU_VGPU_RAV_FAULT, "avail again");
    check("avail stays", rav.valid && rav.avail_idx == 16'd2 &&
          rav.addr == APU_VGPU_QAV_ADDR);
    rny.avail_idx = 16'd1;
    rak_step(APU_VGPU_RAK_FAULT, "keep scene index");
    check("keep rejected", !rak.valid);
    good_in();
    rak_step(APU_VGPU_RAK_OK, "keep idx");
    check("idx kept", rak.valid && rak.avail_idx == 16'd2 &&
          rak.addr == APU_VGPU_QAV_ADDR);
    rak_step(APU_VGPU_RAK_FAULT, "keep again");
    rny.qid = APU_VGPU_QNT_CURSOR;
    ray_step(APU_VGPU_RAY_FAULT, "check cursor");
    check("check rejected", !ray.valid);
    good_in();
    ray_step(APU_VGPU_RAY_OK, "check idx");
    check("idx checked", ray.valid && ray.avail_idx == 16'd2);
    ray_step(APU_VGPU_RAY_FAULT, "check again");
    check("check stays", ray.avail_idx == rav.avail_idx);

    pulse_reset();
    check("reset clears", rav == '0 && rak == '0 && ray == '0);
    rny = '0;
    rav_step(APU_VGPU_RAV_EMPTY, "after reset");
    good_in();
    rav_step(APU_VGPU_RAV_OK, "avail after reset");

    if (errors != 0) $fatal(1, "APU vgpu rav errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rav cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
