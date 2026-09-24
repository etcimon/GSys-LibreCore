// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_fet;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_chn_t chn;
  logic fet_req = 0, fet_rdy, fet_cpl_v, fet_cpl_r = 0;
  apu_vgpu_fet_cpl_t fet_cpl;
  apu_vgpu_fet_t fet;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic fek_req = 0, fek_rdy, fek_cpl_v, fek_cpl_r = 0;
  apu_vgpu_fek_cpl_t fek_cpl, off_cpl;
  apu_vgpu_fek_t fek, off_fek;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_size = 0, bad_cmd = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [63:0] ExecLast = APU_VGPU_EXEC_ADDR + (64'd29 << 5);

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_fet #(.Enable(1'b1)) i_fet (
    .clk_i(clk), .rst_ni, .chn_i(chn),
    .req_valid_i(fet_req), .req_ready_o(fet_rdy),
    .cpl_valid_o(fet_cpl_v), .cpl_ready_i(fet_cpl_r), .cpl_o(fet_cpl), .fet_o(fet),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_fek #(.Enable(1'b1)) i_fek (
    .clk_i(clk), .rst_ni, .fet_i(fet), .chn_i(chn),
    .req_valid_i(fek_req), .req_ready_o(fek_rdy),
    .cpl_valid_o(fek_cpl_v), .cpl_ready_i(fek_cpl_r), .cpl_o(fek_cpl), .fek_o(fek)
  );
  g6lc_apu_vgpu_fek_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .fet_i(fet), .chn_i(chn),
    .req_valid_i(fek_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(fek_cpl_r), .cpl_o(off_cpl), .fek_o(off_fek)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu fet timeout case=%0d n=%0d", cases, nread); end

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

  task automatic good_chn;
    chn = '0;
    chn.valid = 1'b1;
    chn.head = 16'd0;
    chn.buf_len = APU_VGPU_SCENE_BYTES;
    chn.buf_addr = APU_VGPU_EXEC_ADDR;
    chn.rsp_addr = APU_VGPU_RSP_ADDR;
    chn.device_idx = 16'd1;
  endtask

  task automatic fet_step(input apu_vgpu_fet_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!fet_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    fet_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fet_req = 1'b0;
    while (!fet_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), fet_cpl.status == st);
    if (st == APU_VGPU_FET_OK) begin
      check("fetched", fet.valid && fet.kind == VGPU_CMD_SUBMIT_3D &&
            fet.cmd0 == Cmd0 && fet.beats == APU_VGPU_EXEC_BEATS);
      check("read count", nread == n0 + 31 && !order_bad && seen_last == ExecLast);
    end else if (name == "bad beat" || name == "bad size") begin
      check("header only", nread == n0 + 1 && !fet.valid);
    end else if (name == "bad cmd") begin
      check("header and first", nread == n0 + 2 && !fet.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), fet_cpl_v);
    fet_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fet_cpl_r = 1'b0;
    while (fet_cpl_v) @(negedge clk);
  endtask

  task automatic fek_step(input apu_vgpu_fek_status_e st, input string name);
    @(negedge clk);
    while (!fek_rdy) @(negedge clk);
    cases++;
    fek_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fek_req = 1'b0;
    while (!fek_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), fek_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_fek == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), fek_cpl_v);
    fek_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fek_cpl_r = 1'b0;
    while (fek_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    fet_req = 1'b0;
    fek_req = 1'b0;
    fet_cpl_r = 1'b0;
    fek_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    chn = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && fet == '0 &&
          fek == '0);
    check("profiles keep the fetch off",
          !ApuOff.FetEn && !ApuOff.FekEn &&
          !ApuP1Transport.FetEn && !ApuP1Transport.FekEn &&
          !ApuHarness.FetEn && !ApuHarness.FekEn &&
          !ApuSchedBoth.FetEn && !ApuSchedBoth.FekEn &&
          !ApuBadVirglGrant.FetEn && !ApuBadVirglGrant.FekEn);
    cfg = ApuP1Transport;
    cfg.FetEn = 1'b1;
    cfg.FekEn = 1'b1;
    check("fetch does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.FetEn = 1'b1;
    cfg.FekEn = 1'b1;
    check("fetch does not legalize virgl", !apu_cfg_legal(cfg));
    check("command word", Cmd0 == 32'h00050801 && APU_VGPU_EXEC_BEATS == 6'd30 &&
          ExecLast == 64'h8800B3A0);

    fet_step(APU_VGPU_FET_EMPTY, "fet empty");
    good_chn();
    fail_next = 1'b1;
    fet_step(APU_VGPU_FET_FAULT, "bad beat");
    bad_size = 1'b1;
    fet_step(APU_VGPU_FET_FAULT, "bad size");
    bad_cmd = 1'b1;
    fet_step(APU_VGPU_FET_FAULT, "bad cmd");
    fet_step(APU_VGPU_FET_OK, "scene fetch");
    fek_step(APU_VGPU_FEK_OK, "keep fetch");
    check("fetch kept", fek.valid && fek.kind == VGPU_CMD_SUBMIT_3D &&
          fek.cmd0 == Cmd0);
    fek_step(APU_VGPU_FEK_FAULT, "fetch again");
    check("fetch stays", fek.cmd0 == Cmd0 && chn.buf_len == APU_VGPU_SCENE_BYTES);

    pulse_reset();
    check("reset clears", fet == '0 && fek == '0);
    fek_step(APU_VGPU_FEK_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu fet errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_fet cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
