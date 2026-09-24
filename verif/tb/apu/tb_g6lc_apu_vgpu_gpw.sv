// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_gpw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_ols_t ols;
  apu_vgpu_nxc_t nxc;
  apu_vgpu_cwr_t cwr;
  apu_vgpu_cxr_t cxr;
  apu_vgpu_fbr_t fbr;
  apu_vgpu_fet_t fet;
  logic gpw_req = 0, gpw_rdy, gpw_cpl_v, gpw_cpl_r = 0;
  apu_vgpu_gpw_cpl_t gpw_cpl;
  apu_vgpu_gpw_t gpw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, seen0 = 0, seen_last = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic gpr_req = 0, gpr_rdy, gpr_cpl_v, gpr_cpl_r = 0;
  apu_vgpu_gpr_cpl_t gpr_cpl;
  apu_vgpu_gpr_t gpr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic gpk_req = 0, gpk_rdy, gpk_cpl_v, gpk_cpl_r = 0;
  apu_vgpu_gpk_cpl_t gpk_cpl, off_cpl;
  apu_vgpu_gpk_t gpk, off_gpk;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_tail = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, wr_base = 0, nread = 0, rd_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_gpw #(.Enable(1'b1)) i_gpw (
    .clk_i(clk), .rst_ni, .ols_i(ols), .nxc_i(nxc), .cwr_i(cwr), .cxr_i(cxr),
    .fbr_i(fbr), .fet_i(fet),
    .req_valid_i(gpw_req), .req_ready_o(gpw_rdy),
    .cpl_valid_o(gpw_cpl_v), .cpl_ready_i(gpw_cpl_r), .cpl_o(gpw_cpl), .gpw_o(gpw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_gpr #(.Enable(1'b1)) i_gpr (
    .clk_i(clk), .rst_ni, .gpw_i(gpw), .cwr_i(cwr), .ols_i(ols), .nxc_i(nxc),
    .req_valid_i(gpr_req), .req_ready_o(gpr_rdy),
    .cpl_valid_o(gpr_cpl_v), .cpl_ready_i(gpr_cpl_r), .cpl_o(gpr_cpl), .gpr_o(gpr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_gpk #(.Enable(1'b1)) i_gpk (
    .clk_i(clk), .rst_ni, .gpr_i(gpr), .gpw_i(gpw), .cwr_i(cwr), .ols_i(ols),
    .fet_i(fet), .req_valid_i(gpk_req), .req_ready_o(gpk_rdy),
    .cpl_valid_o(gpk_cpl_v), .cpl_ready_i(gpk_cpl_r), .cpl_o(gpk_cpl), .gpk_o(gpk)
  );
  g6lc_apu_vgpu_gpk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .gpr_i(gpr), .gpw_i(gpw), .cwr_i(cwr), .ols_i(ols),
    .fet_i(fet), .req_valid_i(gpk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(gpk_cpl_r), .cpl_o(off_cpl), .gpk_o(off_gpk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu gpw timeout case=%0d w=%0d", cases, nwrite); end

  function automatic logic [255:0] rd_beat(input int idx);
    rd_beat = Pat;
    if (idx == 1 && bad_tail) rd_beat[31:0] = 32'h0;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      order_bad <= 1'b0;
      data_bad <= 1'b0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nwrite - wr_base;
      want = APU_VGPU_GPW_ADDR + (64'(idx) << 5);
      if (wr_addr != want || wr_len != 32'(APU_VGPU_BEAT_BYTES)) order_bad <= 1'b1;
      if (wr_data != Pat) data_bad <= 1'b1;
      if (idx == 0) seen0 <= wr_addr;
      seen_last <= wr_addr;
      wr_rsp_addr <= wr_addr;
      wr_rsp_ok <= !fail_wr;
      fail_wr <= 1'b0;
      nwrite <= nwrite + 1;
      wr_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nread - rd_base;
      want = idx == 0 ? APU_VGPU_GPW_ADDR : APU_VGPU_GPW_TAIL;
      if (rd_addr != want) rd_order <= 1'b1;
      if (idx == 0) rd_seen0 <= rd_addr;
      rd_seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= rd_beat(idx);
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 1) bad_tail <= 1'b0;
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
    ols = '0;
    ols.valid = 1'b1;
    ols.count = 32'h0;
    ols.capset_id = 32'h0;
    ols.resp = VGPU_RESP_OK_NODATA;
    nxc = '0;
    nxc.valid = 1'b1;
    nxc.head = 16'd0;
    nxc.avail_idx = 16'd1;
    nxc.buf_len = APU_VGPU_SCENE_BYTES;
    nxc.buf_addr = APU_VGPU_EXEC_ADDR;
    nxc.rsp_addr = APU_VGPU_RSP_ADDR;
    cwr = '0;
    cwr.valid = 1'b1;
    cwr.word = APU_VGPU_CLEAR_WORD;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    fbr = '0;
    fbr.valid = 1'b1;
    fbr.nr_cbufs = 32'd1;
    fbr.surface = APU_VIRGL_SURFACE_HANDLE;
    fbr.word = APU_VGPU_CLEAR_WORD;
    fet = '0;
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_gpk == '0 &&
          off_cpl == '0);
  endtask

  task automatic gpw_step(input apu_vgpu_gpw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gpw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    gpw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gpw_req = 1'b0;
    while (!gpw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gpw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GPW_OK) begin
      check("window", gpw.valid && gpw.beats == 16'd512 &&
            gpw.word == APU_VGPU_CLEAR_WORD && gpw.base == APU_VGPU_GPW_ADDR);
      check("write count", nwrite == n0 + 512 && !order_bad && !data_bad &&
            seen0 == APU_VGPU_GPW_ADDR && seen_last == APU_VGPU_GPW_TAIL);
    end else if (name == "bad beat") begin
      check("one beat", nwrite == n0 + 1 && !gpw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), gpw_cpl_v);
    gpw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gpw_cpl_r = 1'b0;
    while (gpw_cpl_v) @(negedge clk);
  endtask

  task automatic gpr_step(input apu_vgpu_gpr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gpr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    gpr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gpr_req = 1'b0;
    while (!gpr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gpr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GPR_OK) begin
      check("readback", gpr.valid && gpr.word == APU_VGPU_CLEAR_WORD &&
            gpr.first == APU_VGPU_GPW_ADDR && gpr.last == APU_VGPU_GPW_TAIL);
      check("read count", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_GPW_ADDR && rd_seen1 == APU_VGPU_GPW_TAIL);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !gpr.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !gpr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), gpr_cpl_v);
    gpr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gpr_cpl_r = 1'b0;
    while (gpr_cpl_v) @(negedge clk);
  endtask

  task automatic gpk_step(input apu_vgpu_gpk_status_e st, input string name);
    @(negedge clk);
    while (!gpk_rdy) @(negedge clk);
    cases++;
    gpk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gpk_req = 1'b0;
    while (!gpk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gpk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gpk_cpl_v);
    gpk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gpk_cpl_r = 1'b0;
    while (gpk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    gpw_req = 1'b0;
    gpr_req = 1'b0;
    gpk_req = 1'b0;
    gpw_cpl_r = 1'b0;
    gpr_cpl_r = 1'b0;
    gpk_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    ols = '0;
    nxc = '0;
    cwr = '0;
    cxr = '0;
    fbr = '0;
    fet = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && gpw == '0 &&
          gpr == '0 && gpk == '0);
    check("profiles keep the window off",
          !ApuOff.GpwEn && !ApuOff.GprEn && !ApuOff.GpkEn &&
          !ApuP1Transport.GpwEn && !ApuP1Transport.GprEn && !ApuP1Transport.GpkEn &&
          !ApuHarness.GpwEn && !ApuHarness.GprEn && !ApuHarness.GpkEn &&
          !ApuSchedBoth.GpwEn && !ApuSchedBoth.GprEn && !ApuSchedBoth.GpkEn &&
          !ApuBadVirglGrant.GpwEn && !ApuBadVirglGrant.GprEn &&
          !ApuBadVirglGrant.GpkEn);
    cfg = ApuP1Transport;
    cfg.GpwEn = 1'b1;
    cfg.GprEn = 1'b1;
    cfg.GpkEn = 1'b1;
    check("window does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GpwEn = 1'b1;
    cfg.GprEn = 1'b1;
    cfg.GpkEn = 1'b1;
    check("window does not legalize virgl", !apu_cfg_legal(cfg));
    check("window places",
          APU_VGPU_GPW_ADDR == 64'h88020000 &&
          APU_VGPU_GPW_BEATS == 16'd512 &&
          APU_VGPU_GPW_LAST == 9'd511 &&
          APU_VGPU_GPW_TAIL == 64'h88023FE0 &&
          APU_VGPU_GPW_ADDR + 64'd16384 == 64'h88024000 &&
          APU_VGPU_GPW_ADDR[31:0] != APU_VGPU_CEIL_RB &&
          APU_VGPU_CLEAR_WORD == 32'hFF1A0D0D);

    gpr_step(APU_VGPU_GPR_EMPTY, "read empty");
    gpw_step(APU_VGPU_GPW_EMPTY, "window empty");
    good_in();
    nxc = '0;
    gpw_step(APU_VGPU_GPW_EMPTY, "chain missing");
    good_in();
    cxr.height = 16'd64;
    gpw_step(APU_VGPU_GPW_FAULT, "bad scissor");
    good_in();
    fail_wr = 1'b1;
    gpw_step(APU_VGPU_GPW_FAULT, "bad beat");
    gpw_step(APU_VGPU_GPW_OK, "clear window");
    gpw_step(APU_VGPU_GPW_FAULT, "clear window again");
    check("window stays", gpw.valid && gpw.beats == 16'd512 &&
          gpw.word == APU_VGPU_CLEAR_WORD);
    fail_rd = 1'b1;
    gpr_step(APU_VGPU_GPR_FAULT, "bad beat");
    bad_tail = 1'b1;
    gpr_step(APU_VGPU_GPR_FAULT, "bad tail");
    gpr_step(APU_VGPU_GPR_OK, "read window");
    gpr_step(APU_VGPU_GPR_FAULT, "read window again");
    check("read stays", gpr.word == APU_VGPU_CLEAR_WORD &&
          gpr.first != gpr.last && gpr.word == cwr.word);
    gpk_step(APU_VGPU_GPK_OK, "keep window");
    check("window kept", gpk.valid && gpk.word == APU_VGPU_CLEAR_WORD &&
          gpk.first == APU_VGPU_GPW_ADDR && gpk.last == APU_VGPU_GPW_TAIL);
    gpk_step(APU_VGPU_GPK_FAULT, "window keep again");
    check("window keep stays", gpk.word == APU_VGPU_CLEAR_WORD &&
          gpk.last == APU_VGPU_GPW_TAIL);

    pulse_reset();
    check("reset clears", gpw == '0 && gpr == '0 && gpk == '0);
    zero_in();
    gpw_step(APU_VGPU_GPW_EMPTY, "after reset");
    gpr_step(APU_VGPU_GPR_EMPTY, "read after reset");
    gpk_step(APU_VGPU_GPK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu gpw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_gpw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
