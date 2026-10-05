// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rab;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_tfx_t tfx;
  apu_vgpu_rpw_t rpw;
  apu_vgpu_grd_t grd;
  apu_vgpu_c3d_t c3d;
  logic [63:0] want_addr = 0;
  logic [31:0] want_len = 0;
  logic rab_req = 0, rab_rdy, rab_cpl_v, rab_cpl_r = 0;
  apu_vgpu_rab_cpl_t rab_cpl;
  apu_vgpu_rab_t rab;
  logic rar_req = 0, rar_rdy, rar_cpl_v, rar_cpl_r = 0;
  apu_vgpu_rar_cpl_t rar_cpl;
  apu_vgpu_rar_t rar;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen0 = 0, seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rax_req = 0, rax_rdy, rax_cpl_v, rax_cpl_r = 0;
  apu_vgpu_rax_cpl_t rax_cpl, off_cpl;
  apu_vgpu_rax_t rax, off_rax;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_rid = 0, bad_nr = 0, bad_addr = 0, bad_len = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rab #(.Enable(1'b1)) i_rab (
    .clk_i(clk), .rst_ni, .tfx_i(tfx), .rpw_i(rpw), .grd_i(grd), .c3d_i(c3d),
    .want_addr_i(want_addr), .want_len_i(want_len),
    .req_valid_i(rab_req), .req_ready_o(rab_rdy),
    .cpl_valid_o(rab_cpl_v), .cpl_ready_i(rab_cpl_r), .cpl_o(rab_cpl), .rab_o(rab)
  );
  g6lc_apu_vgpu_rar #(.Enable(1'b1)) i_rar (
    .clk_i(clk), .rst_ni, .rab_i(rab), .tfx_i(tfx),
    .req_valid_i(rar_req), .req_ready_o(rar_rdy),
    .cpl_valid_o(rar_cpl_v), .cpl_ready_i(rar_cpl_r), .cpl_o(rar_cpl), .rar_o(rar),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rax #(.Enable(1'b1)) i_rax (
    .clk_i(clk), .rst_ni, .rar_i(rar), .rab_i(rab), .tfx_i(tfx),
    .req_valid_i(rax_req), .req_ready_o(rax_rdy),
    .cpl_valid_o(rax_cpl_v), .cpl_ready_i(rax_cpl_r), .cpl_o(rax_cpl), .rax_o(rax)
  );
  g6lc_apu_vgpu_rax_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rar_i(rar), .rab_i(rab), .tfx_i(tfx),
    .req_valid_i(rax_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rax_cpl_r), .cpl_o(off_cpl), .rax_o(off_rax)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rab timeout case=%0d", cases); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      beat_data[31:0] = VGPU_CMD_RESOURCE_ATTACH_BACKING;
      beat_data[159:128] = APU_VGPU_CTX_ID;
      beat_data[223:192] = bad_rid ? APU_VIRGL_RES_SCAN : APU_VIRGL_RES_RT;
      beat_data[255:224] = bad_nr ? 32'd2 : 32'd1;
    end else begin
      beat_data[63:0] = bad_addr ? APU_VGPU_CSW_DST : APU_VGPU_RPW_DST;
      beat_data[95:64] = bad_len ? APU_VGPU_SCAN_BYTES : APU_VGPU_GBD_BYTES;
    end
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nread - run_base;
      want = idx == 0 ? APU_VGPU_RAB_CMD : APU_VGPU_RAB_B1;
      if (rd_addr != want || rd_len != 32'(APU_VGPU_BEAT_BYTES))
        order_bad <= 1'b1;
      if (idx == 0) seen0 <= rd_addr;
      seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat_data(idx);
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 0) begin
        bad_rid <= 1'b0;
        bad_nr <= 1'b0;
      end
      if (idx == 1) begin
        bad_addr <= 1'b0;
        bad_len <= 1'b0;
      end
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
    tfx = '0;
    tfx.valid = 1'b1;
    tfx.stride = APU_VGPU_TFB_STRIDE;
    tfx.x = 16'd0;
    tfx.y = 16'd0;
    tfx.res_w = APU_VGPU_RT_W;
    rpw = '0;
    rpw.valid = 1'b1;
    rpw.origin = Origin;
    rpw.neighbor = Neighbor;
    rpw.beats = APU_VGPU_GPW_BEATS;
    rpw.src = APU_VGPU_CSW_DST;
    rpw.dst = APU_VGPU_RPW_DST;
    rpw.cmd = VGPU_CMD_TRANSFER_FROM_HOST_3D;
    rpw.resource_id = APU_VIRGL_RES_RT;
    grd = '0;
    grd.valid = 1'b1;
    grd.width = APU_VGPU_GBD_W;
    grd.height = APU_VGPU_GBD_H;
    grd.stride = APU_VGPU_GBD_STRIDE;
    grd.bytes = APU_VGPU_GBD_BYTES;
    grd.format = APU_VIRGL_FMT_B8G8R8X8;
    grd.base = APU_VGPU_RPW_DST;
    grd.origin = Origin;
    grd.neighbor = Neighbor;
    grd.cmd = VGPU_CMD_TRANSFER_FROM_HOST_3D;
    c3d = '0;
    c3d.rt_valid = 1'b1;
    c3d.rt_w = APU_VGPU_RT_W;
    c3d.rt_h = APU_VGPU_RT_H;
    want_addr = APU_VGPU_RPW_DST;
    want_len = APU_VGPU_GBD_BYTES;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rax == '0 &&
          off_cpl == '0);
  endtask

  task automatic rab_step(input apu_vgpu_rab_status_e st, input string name);
    @(negedge clk);
    while (!rab_rdy) @(negedge clk);
    cases++;
    rab_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rab_req = 1'b0;
    while (!rab_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rab_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RAB_OK) begin
      check("attach", rab.valid && rab.addr == APU_VGPU_RPW_DST &&
            rab.length == APU_VGPU_GBD_BYTES &&
            rab.length != APU_VGPU_SCAN_BYTES &&
            rab.resource_id == APU_VIRGL_RES_RT &&
            rab.cmd == VGPU_CMD_RESOURCE_ATTACH_BACKING);
    end
    @(negedge clk);
    check($sformatf("%s held", name), rab_cpl_v);
    rab_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rab_cpl_r = 1'b0;
    while (rab_cpl_v) @(negedge clk);
  endtask

  task automatic rar_step(input apu_vgpu_rar_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rar_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    rar_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rar_req = 1'b0;
    while (!rar_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rar_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RAR_OK) begin
      check("command", rar.valid && rar.addr == APU_VGPU_RPW_DST &&
            rar.length == APU_VGPU_GBD_BYTES &&
            rar.length != APU_VGPU_SCAN_BYTES &&
            rar.resource_id == APU_VIRGL_RES_RT &&
            rar.cmd == VGPU_CMD_RESOURCE_ATTACH_BACKING &&
            rar.cmd_addr == APU_VGPU_RAB_CMD);
      check("two reads", nread == n0 + 2 && !order_bad &&
            seen0 == APU_VGPU_RAB_CMD && seen1 == APU_VGPU_RAB_B1);
    end else if (name == "bad beat" || name == "scan resource" ||
                 name == "two entries") begin
      check("one beat", nread == n0 + 1 && !rar.valid);
    end else if (name == "color window" || name == "full surface") begin
      check("two beats", nread == n0 + 2 && !rar.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rar_cpl_v);
    rar_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rar_cpl_r = 1'b0;
    while (rar_cpl_v) @(negedge clk);
  endtask

  task automatic rax_step(input apu_vgpu_rax_status_e st, input string name);
    @(negedge clk);
    while (!rax_rdy) @(negedge clk);
    cases++;
    rax_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rax_req = 1'b0;
    while (!rax_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rax_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rax_cpl_v);
    rax_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rax_cpl_r = 1'b0;
    while (rax_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rab_req = 1'b0;
    rar_req = 1'b0;
    rax_req = 1'b0;
    rab_cpl_r = 1'b0;
    rar_cpl_r = 1'b0;
    rax_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    tfx = '0;
    rpw = '0;
    grd = '0;
    c3d = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rab == '0 && rar == '0 && rax == '0);
    check("profiles keep the attach off",
          !ApuOff.RabEn && !ApuOff.RarEn && !ApuOff.RaxEn &&
          !ApuP1Transport.RabEn && !ApuP1Transport.RarEn &&
          !ApuP1Transport.RaxEn &&
          !ApuHarness.RabEn && !ApuHarness.RarEn && !ApuHarness.RaxEn &&
          !ApuSchedBoth.RabEn && !ApuSchedBoth.RarEn && !ApuSchedBoth.RaxEn &&
          !ApuBadVirglGrant.RabEn && !ApuBadVirglGrant.RarEn &&
          !ApuBadVirglGrant.RaxEn);
    cfg = ApuP1Transport;
    cfg.RabEn = 1'b1;
    cfg.RarEn = 1'b1;
    cfg.RaxEn = 1'b1;
    check("attach does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RabEn = 1'b1;
    cfg.RarEn = 1'b1;
    cfg.RaxEn = 1'b1;
    check("attach does not legalize virgl", !apu_cfg_legal(cfg));
    check("known attach",
          APU_VGPU_RAB_B1 == APU_VGPU_RAB_CMD + 64'd32 &&
          APU_VGPU_RAB_CMD != APU_VGPU_TFB_CMD &&
          APU_VGPU_RAB_CMD != APU_VGPU_RPW_DST &&
          APU_VGPU_GBD_BYTES != APU_VGPU_SCAN_BYTES &&
          APU_VGPU_SCAN_BYTES == APU_VGPU_RT_W * APU_VGPU_RT_H * 32'd4);

    rab_step(APU_VGPU_RAB_EMPTY, "attach empty");
    rar_step(APU_VGPU_RAR_EMPTY, "command empty");
    rax_step(APU_VGPU_RAX_EMPTY, "length empty");
    good_in();
    want_len = APU_VGPU_SCAN_BYTES;
    rab_step(APU_VGPU_RAB_FAULT, "full surface");
    want_len = 32'd32;
    rab_step(APU_VGPU_RAB_FAULT, "lab length");
    want_len = APU_VGPU_GBD_BYTES;
    want_addr = APU_VGPU_CSW_DST;
    rab_step(APU_VGPU_RAB_FAULT, "color window");
    want_addr = APU_VGPU_RPW_DST;
    rab_step(APU_VGPU_RAB_OK, "readpixels backing");
    rab_step(APU_VGPU_RAB_FAULT, "attach again");
    fail_rd = 1'b1;
    rar_step(APU_VGPU_RAR_FAULT, "bad beat");
    bad_rid = 1'b1;
    rar_step(APU_VGPU_RAR_FAULT, "scan resource");
    bad_nr = 1'b1;
    rar_step(APU_VGPU_RAR_FAULT, "two entries");
    bad_addr = 1'b1;
    rar_step(APU_VGPU_RAR_FAULT, "color window");
    bad_len = 1'b1;
    rar_step(APU_VGPU_RAR_FAULT, "full surface");
    rar_step(APU_VGPU_RAR_OK, "guest command");
    rar_step(APU_VGPU_RAR_FAULT, "command again");
    rax_step(APU_VGPU_RAX_OK, "crop length");
    check("crop length", rax.valid && rax.length == APU_VGPU_GBD_BYTES &&
          rax.length != APU_VGPU_SCAN_BYTES && rax.addr == APU_VGPU_RPW_DST);
    rax_step(APU_VGPU_RAX_FAULT, "length again");
    check("length stays", rax.length == APU_VGPU_GBD_BYTES);

    pulse_reset();
    check("reset clears", rab == '0 && rar == '0 && rax == '0);
    tfx = '0;
    rpw = '0;
    grd = '0;
    c3d = '0;
    rab_step(APU_VGPU_RAB_EMPTY, "after reset");
    good_in();
    rab_step(APU_VGPU_RAB_OK, "attach after reset");

    if (errors != 0) $fatal(1, "APU vgpu rab errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rab cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
