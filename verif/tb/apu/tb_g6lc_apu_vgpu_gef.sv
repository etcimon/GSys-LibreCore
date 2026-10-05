// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_gef;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gnx_t gnx;
  logic gef_req = 0, gef_rdy, gef_cpl_v, gef_cpl_r = 0;
  apu_vgpu_gef_cpl_t gef_cpl;
  apu_vgpu_gef_t gef;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic gek_req = 0, gek_rdy, gek_cpl_v, gek_cpl_r = 0;
  apu_vgpu_gek_cpl_t gek_cpl;
  apu_vgpu_gek_t gek;
  logic gex_req = 0, gex_rdy, gex_cpl_v, gex_cpl_r = 0;
  apu_vgpu_gex_cpl_t gex_cpl, off_cpl;
  apu_vgpu_gex_t gex, off_gex;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_size = 0, bad_cmd = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [63:0] ExecLast = APU_VGPU_EXEC_ADDR + (64'd29 << 5);

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_gef #(.Enable(1'b1)) i_gef (
    .clk_i(clk), .rst_ni, .gnx_i(gnx),
    .req_valid_i(gef_req), .req_ready_o(gef_rdy),
    .cpl_valid_o(gef_cpl_v), .cpl_ready_i(gef_cpl_r), .cpl_o(gef_cpl), .gef_o(gef),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_gek #(.Enable(1'b1)) i_gek (
    .clk_i(clk), .rst_ni, .gef_i(gef), .gnx_i(gnx),
    .req_valid_i(gek_req), .req_ready_o(gek_rdy),
    .cpl_valid_o(gek_cpl_v), .cpl_ready_i(gek_cpl_r), .cpl_o(gek_cpl), .gek_o(gek)
  );
  g6lc_apu_vgpu_gex #(.Enable(1'b1)) i_gex (
    .clk_i(clk), .rst_ni, .gek_i(gek), .gef_i(gef), .gnx_i(gnx),
    .req_valid_i(gex_req), .req_ready_o(gex_rdy),
    .cpl_valid_o(gex_cpl_v), .cpl_ready_i(gex_cpl_r), .cpl_o(gex_cpl), .gex_o(gex)
  );
  g6lc_apu_vgpu_gex_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .gek_i(gek), .gef_i(gef), .gnx_i(gnx),
    .req_valid_i(gex_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(gex_cpl_r), .cpl_o(off_cpl), .gex_o(off_gex)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu gef timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] hdr_beat;
    hdr_beat = '0;
    hdr_beat[31:0] = VGPU_CMD_SUBMIT_3D;
    hdr_beat[159:128] = 32'd1;
    hdr_beat[223:192] = bad_size ? 32'h0 : APU_VGPU_SCENE_BYTES;
  endfunction

  function automatic logic [255:0] exec_beat(input int idx);
    exec_beat = '0;
    if (idx == 0) exec_beat[31:0] = bad_cmd ? 32'h0 : Cmd0;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nread - run_base;
      want = idx == 0 ? APU_VGPU_HDR_ADDR : APU_VGPU_EXEC_ADDR + (64'(idx - 1) << 5);
      if (rd_addr != want) order_bad <= 1'b1;
      seen_last <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= idx == 0 ? hdr_beat() : exec_beat(idx - 1);
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      if (idx == 0) bad_size <= 1'b0;
      if (idx == 1) bad_cmd <= 1'b0;
      nread <= nread + 1;
      rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_gex == '0 &&
          off_cpl == '0);
  endtask

  task automatic good_in;
    gnx = '0;
    gnx.valid = 1'b1;
    gnx.avail_idx = 16'd1;
    gnx.device_idx = 16'd1;
    gnx.buf_addr = APU_VGPU_EXEC_ADDR;
  endtask

  task automatic gef_step(input apu_vgpu_gef_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gef_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    gef_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gef_req = 1'b0;
    while (!gef_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gef_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GEF_OK) begin
      check("fetched", gef.valid && gef.kind == VGPU_CMD_SUBMIT_3D &&
            gef.cmd0 == Cmd0 && gef.beats == APU_VGPU_EXEC_BEATS &&
            gef.device_idx == 16'd1);
      check("read count", nread == n0 + 31 && !order_bad && seen_last == ExecLast);
    end else if (name == "bad beat" || name == "bad size") begin
      check("header only", nread == n0 + 1 && !gef.valid);
    end else if (name == "bad cmd") begin
      check("header and first", nread == n0 + 2 && !gef.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), gef_cpl_v);
    gef_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gef_cpl_r = 1'b0;
    while (gef_cpl_v) @(negedge clk);
  endtask

  task automatic gek_step(input apu_vgpu_gek_status_e st, input string name);
    @(negedge clk);
    while (!gek_rdy) @(negedge clk);
    cases++;
    gek_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gek_req = 1'b0;
    while (!gek_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gek_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gek_cpl_v);
    gek_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gek_cpl_r = 1'b0;
    while (gek_cpl_v) @(negedge clk);
  endtask

  task automatic gex_step(input apu_vgpu_gex_status_e st, input string name);
    @(negedge clk);
    while (!gex_rdy) @(negedge clk);
    cases++;
    gex_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gex_req = 1'b0;
    while (!gex_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gex_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gex_cpl_v);
    gex_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gex_cpl_r = 1'b0;
    while (gex_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    gef_req = 1'b0;
    gek_req = 1'b0;
    gex_req = 1'b0;
    gef_cpl_r = 1'b0;
    gek_cpl_r = 1'b0;
    gex_cpl_r = 1'b0;
    rsp_v = 1'b0;
    fail_next = 1'b0;
    bad_size = 1'b0;
    bad_cmd = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gnx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && gef == '0 &&
          gek == '0 && gex == '0);
    check("profiles keep the fetch off",
          !ApuOff.GefEn && !ApuOff.GekEn && !ApuOff.GexEn &&
          !ApuP1Transport.GefEn && !ApuP1Transport.GekEn &&
          !ApuP1Transport.GexEn &&
          !ApuHarness.GefEn && !ApuHarness.GekEn && !ApuHarness.GexEn &&
          !ApuSchedBoth.GefEn && !ApuSchedBoth.GekEn && !ApuSchedBoth.GexEn &&
          !ApuBadVirglGrant.GefEn && !ApuBadVirglGrant.GekEn &&
          !ApuBadVirglGrant.GexEn);
    cfg = ApuP1Transport;
    cfg.GefEn = 1'b1;
    cfg.GekEn = 1'b1;
    cfg.GexEn = 1'b1;
    check("fetch does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GefEn = 1'b1;
    cfg.GekEn = 1'b1;
    cfg.GexEn = 1'b1;
    check("fetch does not legalize virgl", !apu_cfg_legal(cfg));
    check("command word", Cmd0 == 32'h00050801 && APU_VGPU_EXEC_BEATS == 6'd30 &&
          ExecLast == 64'h8800B3A0 && APU_VGPU_TFB_CMD != APU_VGPU_EXEC_ADDR);

    gef_step(APU_VGPU_GEF_EMPTY, "fetch empty");
    gek_step(APU_VGPU_GEK_EMPTY, "keep empty");
    gex_step(APU_VGPU_GEX_EMPTY, "check empty");
    good_in();
    gnx.device_idx = 16'd0;
    gef_step(APU_VGPU_GEF_FAULT, "unconsumed");
    good_in();
    gnx.avail_idx = APU_VGPU_TUW_IDXV;
    gef_step(APU_VGPU_GEF_FAULT, "transfer idx");
    good_in();
    gnx.buf_addr = APU_VGPU_TFB_CMD;
    gef_step(APU_VGPU_GEF_FAULT, "transfer dest");
    good_in();
    fail_next = 1'b1;
    gef_step(APU_VGPU_GEF_FAULT, "bad beat");
    good_in();
    bad_size = 1'b1;
    gef_step(APU_VGPU_GEF_FAULT, "bad size");
    good_in();
    bad_cmd = 1'b1;
    gef_step(APU_VGPU_GEF_FAULT, "bad cmd");
    good_in();
    gef_step(APU_VGPU_GEF_OK, "scene fetch");
    gef_step(APU_VGPU_GEF_FAULT, "scene fetch again");
    gnx.device_idx = 16'd0;
    gek_step(APU_VGPU_GEK_FAULT, "keep unconsumed");
    check("keep rejected", !gek.valid);
    gnx.device_idx = 16'd1;
    gek_step(APU_VGPU_GEK_OK, "keep fetch");
    check("fetch kept", gek.valid && gek.kind == VGPU_CMD_SUBMIT_3D &&
          gek.cmd0 == Cmd0 && gek.device_idx == 16'd1);
    gek_step(APU_VGPU_GEK_FAULT, "keep again");
    gnx.buf_addr = APU_VGPU_TFB_CMD;
    gex_step(APU_VGPU_GEX_FAULT, "check transfer dest");
    check("check rejected", !gex.valid);
    gnx.buf_addr = APU_VGPU_EXEC_ADDR;
    gex_step(APU_VGPU_GEX_OK, "check fetch");
    check("fetch checked", gex.valid && gex.cmd0 == Cmd0 &&
          gex.device_idx == 16'd1);
    gex_step(APU_VGPU_GEX_FAULT, "check again");

    pulse_reset();
    check("reset clears", gef == '0 && gek == '0 && gex == '0);
    gnx = '0;
    gef_step(APU_VGPU_GEF_EMPTY, "after reset");
    gek_step(APU_VGPU_GEK_EMPTY, "keep after reset");
    gex_step(APU_VGPU_GEX_EMPTY, "check after reset");

    if (errors != 0) $fatal(1, "APU vgpu gef errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_gef cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
