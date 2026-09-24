// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_drd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fet_t fet;
  logic drd_req = 0, drd_rdy, drd_cpl_v, drd_cpl_r = 0;
  apu_vgpu_drd_cpl_t drd_cpl;
  apu_vgpu_drd_t drd;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic drk_req = 0, drk_rdy, drk_cpl_v, drk_cpl_r = 0;
  apu_vgpu_drk_cpl_t drk_cpl, off_cpl;
  apu_vgpu_drk_t drk, off_drk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_hdr = 0, bad_count = 0, bad_prim = 0, bad_tail = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_drd #(.Enable(1'b1)) i_drd (
    .clk_i(clk), .rst_ni, .fet_i(fet),
    .req_valid_i(drd_req), .req_ready_o(drd_rdy),
    .cpl_valid_o(drd_cpl_v), .cpl_ready_i(drd_cpl_r), .cpl_o(drd_cpl), .drd_o(drd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_drk #(.Enable(1'b1)) i_drk (
    .clk_i(clk), .rst_ni, .drd_i(drd), .fet_i(fet),
    .req_valid_i(drk_req), .req_ready_o(drk_rdy),
    .cpl_valid_o(drk_cpl_v), .cpl_ready_i(drk_cpl_r), .cpl_o(drk_cpl), .drk_o(drk)
  );
  g6lc_apu_vgpu_drk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .drd_i(drd), .fet_i(fet),
    .req_valid_i(drk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(drk_cpl_r), .cpl_o(off_cpl), .drk_o(off_drk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu drd timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      // Clear tail occupies the low 12 bytes. The draw starts at byte 12.
      beat_data[63:32] = APU_VIRGL_DEPTH_HI;
      beat_data[127:96] = bad_hdr ? 32'h0 : APU_VIRGL_DRAW_HDR;
      beat_data[191:160] = bad_count ? 32'h0 : APU_VIRGL_VERT_COUNT;
      beat_data[223:192] = bad_prim ? 32'h0 : APU_VIRGL_PRIM_STRIP;
    end else if (!bad_tail) begin
      beat_data[31:0] = 32'd1;
      beat_data[223:192] = 32'd3;
    end
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
      want = idx == 0 ? APU_VGPU_DRAW_ADDR : APU_VGPU_DRAW_LAST;
      if (rd_addr != want) order_bad <= 1'b1;
      if (idx == 0) seen_first <= rd_addr;
      seen_last <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data(idx);
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      if (idx == 0) begin
        bad_hdr <= 1'b0;
        bad_count <= 1'b0;
        bad_prim <= 1'b0;
      end
      if (idx == 1) bad_tail <= 1'b0;
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

  task automatic good_fet;
    fet = '0;
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
  endtask

  task automatic drd_step(input apu_vgpu_drd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!drd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    drd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    drd_req = 1'b0;
    while (!drd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), drd_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_drk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_DRD_OK) begin
      check("draw read", drd.valid && drd.count == APU_VIRGL_VERT_COUNT &&
            drd.prim == APU_VIRGL_PRIM_STRIP);
      check("read count", nread == n0 + 2 && !order_bad &&
            seen_first == APU_VGPU_DRAW_ADDR && seen_last == APU_VGPU_DRAW_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad count" ||
                 name == "bad prim") begin
      check("one beat", nread == n0 + 1 && !drd.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !drd.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), drd_cpl_v);
    drd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    drd_cpl_r = 1'b0;
    while (drd_cpl_v) @(negedge clk);
  endtask

  task automatic drk_step(input apu_vgpu_drk_status_e st, input string name);
    @(negedge clk);
    while (!drk_rdy) @(negedge clk);
    cases++;
    drk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    drk_req = 1'b0;
    while (!drk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), drk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_drk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), drk_cpl_v);
    drk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    drk_cpl_r = 1'b0;
    while (drk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    drd_req = 1'b0;
    drk_req = 1'b0;
    drd_cpl_r = 1'b0;
    drk_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    fet = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && drd == '0 &&
          drk == '0);
    check("profiles keep the draw off",
          !ApuOff.DrdEn && !ApuOff.DrkEn &&
          !ApuP1Transport.DrdEn && !ApuP1Transport.DrkEn &&
          !ApuHarness.DrdEn && !ApuHarness.DrkEn &&
          !ApuSchedBoth.DrdEn && !ApuSchedBoth.DrkEn &&
          !ApuBadVirglGrant.DrdEn && !ApuBadVirglGrant.DrkEn);
    cfg = ApuP1Transport;
    cfg.DrdEn = 1'b1;
    cfg.DrkEn = 1'b1;
    check("draw read does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.DrdEn = 1'b1;
    cfg.DrkEn = 1'b1;
    check("draw read does not legalize virgl", !apu_cfg_legal(cfg));
    check("draw place", APU_VGPU_DRAW_BEAT == 6'd28 &&
          APU_VGPU_DRAW_ADDR == 64'h8800B380 &&
          APU_VGPU_DRAW_LAST == 64'h8800B3A0 &&
          APU_VIRGL_DRAW_HDR == 32'h000C0008 &&
          APU_VIRGL_DRAW_AT == 32'd908 &&
          Cmd0 == 32'h00050801);

    drd_step(APU_VGPU_DRD_EMPTY, "drd empty");
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = 6'd0;
    drd_step(APU_VGPU_DRD_FAULT, "bad identity");
    good_fet();
    fail_next = 1'b1;
    drd_step(APU_VGPU_DRD_FAULT, "bad beat");
    bad_hdr = 1'b1;
    drd_step(APU_VGPU_DRD_FAULT, "bad hdr");
    bad_count = 1'b1;
    drd_step(APU_VGPU_DRD_FAULT, "bad count");
    bad_prim = 1'b1;
    drd_step(APU_VGPU_DRD_FAULT, "bad prim");
    bad_tail = 1'b1;
    drd_step(APU_VGPU_DRD_FAULT, "bad tail");
    drd_step(APU_VGPU_DRD_OK, "draw read");
    drd_step(APU_VGPU_DRD_FAULT, "draw again");
    check("draw stays", drd.valid && drd.count == APU_VIRGL_VERT_COUNT &&
          drd.prim == APU_VIRGL_PRIM_STRIP);
    drk_step(APU_VGPU_DRK_OK, "keep draw");
    check("draw kept", drk.valid && drk.count == APU_VIRGL_VERT_COUNT &&
          drk.prim == APU_VIRGL_PRIM_STRIP);
    drk_step(APU_VGPU_DRK_FAULT, "draw keep again");
    check("draw keep stays", drk.count == APU_VIRGL_VERT_COUNT &&
          drk.prim == APU_VIRGL_PRIM_STRIP);

    pulse_reset();
    check("reset clears", drd == '0 && drk == '0);
    fet = '0;
    drd_step(APU_VGPU_DRD_EMPTY, "after reset");
    drk_step(APU_VGPU_DRK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu drd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_drd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
