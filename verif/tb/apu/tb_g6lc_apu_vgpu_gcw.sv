// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_gcw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gpk_t gpk;
  apu_vgpu_ols_t ols;
  apu_vgpu_nxc_t nxc;
  apu_vgpu_cwr_t cwr;
  apu_vgpu_cxr_t cxr;
  logic gcw_req = 0, gcw_rdy, gcw_cpl_v, gcw_cpl_r = 0;
  apu_vgpu_gcw_cpl_t gcw_cpl;
  apu_vgpu_gcw_t gcw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, seen0 = 0, seen1 = 0, seen2 = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic gcr_req = 0, gcr_rdy, gcr_cpl_v, gcr_cpl_r = 0;
  apu_vgpu_gcr_cpl_t gcr_cpl;
  apu_vgpu_gcr_t gcr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0, rd_seen2 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic gck_req = 0, gck_rdy, gck_cpl_v, gck_cpl_r = 0;
  apu_vgpu_gck_cpl_t gck_cpl, off_cpl;
  apu_vgpu_gck_t gck, off_gck;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_elem = 0, bad_idx = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, wr_base = 0, nread = 0, rd_base = 0;

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_gcw #(.Enable(1'b1)) i_gcw (
    .clk_i(clk), .rst_ni, .gpk_i(gpk), .ols_i(ols), .nxc_i(nxc),
    .cwr_i(cwr), .cxr_i(cxr),
    .req_valid_i(gcw_req), .req_ready_o(gcw_rdy),
    .cpl_valid_o(gcw_cpl_v), .cpl_ready_i(gcw_cpl_r), .cpl_o(gcw_cpl), .gcw_o(gcw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_gcr #(.Enable(1'b1)) i_gcr (
    .clk_i(clk), .rst_ni, .gcw_i(gcw), .gpk_i(gpk), .ols_i(ols), .nxc_i(nxc),
    .cwr_i(cwr), .cxr_i(cxr),
    .req_valid_i(gcr_req), .req_ready_o(gcr_rdy),
    .cpl_valid_o(gcr_cpl_v), .cpl_ready_i(gcr_cpl_r), .cpl_o(gcr_cpl), .gcr_o(gcr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_gck #(.Enable(1'b1)) i_gck (
    .clk_i(clk), .rst_ni, .gcr_i(gcr), .gcw_i(gcw), .gpk_i(gpk), .ols_i(ols),
    .nxc_i(nxc), .cwr_i(cwr), .cxr_i(cxr),
    .req_valid_i(gck_req), .req_ready_o(gck_rdy),
    .cpl_valid_o(gck_cpl_v), .cpl_ready_i(gck_cpl_r), .cpl_o(gck_cpl), .gck_o(gck)
  );
  g6lc_apu_vgpu_gck_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .gcr_i(gcr), .gcw_i(gcw), .gpk_i(gpk), .ols_i(ols),
    .nxc_i(nxc), .cwr_i(cwr), .cxr_i(cxr),
    .req_valid_i(gck_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(gck_cpl_r), .cpl_o(off_cpl), .gck_o(off_gck)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu gcw timeout case=%0d w=%0d", cases, nwrite); end

  function automatic logic [63:0] step_at(input int idx);
    if (idx == 0) step_at = APU_VGPU_RSP_ADDR;
    else if (idx == 1) step_at = APU_VGPU_GCW_ELEM;
    else step_at = APU_VGPU_GCW_IDX;
  endfunction

  function automatic logic [31:0] step_n(input int idx);
    if (idx == 0) step_n = VGPU_RESP_HDR_BYTES;
    else if (idx == 1) step_n = 32'd8;
    else step_n = 32'd4;
  endfunction

  function automatic logic [255:0] wr_pat(input int idx);
    if (idx == 0)
      wr_pat = {64'h0, 32'h0, APU_VGPU_CTX_ID, APU_VGPU_SCENE_FENCE,
                VGPU_FLAG_FENCE, VGPU_RESP_OK_NODATA};
    else if (idx == 1)
      wr_pat = {192'h0, VGPU_RESP_HDR_BYTES, 32'd0};
    else
      wr_pat = {224'h0, 16'd1, 16'd0};
  endfunction

  function automatic logic [255:0] rd_pat(input int idx);
    logic [255:0] beat;
    beat = wr_pat(idx);
    if (idx == 0) beat[255:192] = 64'h1;
    else if (idx == 1) begin
      beat[255:64] = 192'h1;
      if (bad_elem) beat[31:0] = 32'h1;
    end else begin
      beat[255:32] = 224'h1;
      if (bad_idx) beat[31:0] = 32'h0;
    end
    rd_pat = beat;
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
      idx = nwrite - wr_base;
      if (wr_addr != step_at(idx) || wr_len != step_n(idx)) order_bad <= 1'b1;
      if (wr_data != wr_pat(idx)) data_bad <= 1'b1;
      if (idx == 0) seen0 <= wr_addr;
      else if (idx == 1) seen1 <= wr_addr;
      else seen2 <= wr_addr;
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
      idx = nread - rd_base;
      if (rd_addr != step_at(idx) || rd_len != step_n(idx)) rd_order <= 1'b1;
      if (idx == 0) rd_seen0 <= rd_addr;
      else if (idx == 1) rd_seen1 <= rd_addr;
      else rd_seen2 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= rd_pat(idx);
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 1) bad_elem <= 1'b0;
      if (idx == 2) bad_idx <= 1'b0;
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
    gpk = '0;
    gpk.valid = 1'b1;
    gpk.word = APU_VGPU_CLEAR_WORD;
    gpk.first = APU_VGPU_GPW_ADDR;
    gpk.last = APU_VGPU_GPW_TAIL;
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
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_gck == '0 &&
          off_cpl == '0);
  endtask

  task automatic gcw_step(input apu_vgpu_gcw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gcw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    gcw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gcw_req = 1'b0;
    while (!gcw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gcw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GCW_OK) begin
      check("completion", gcw.valid && gcw.resp == VGPU_RESP_OK_NODATA &&
            gcw.fence == APU_VGPU_SCENE_FENCE && gcw.elem_id == 32'd0 &&
            gcw.elem_len == VGPU_RESP_HDR_BYTES && gcw.used_idx == 16'd1);
      check("write count", nwrite == n0 + 3 && !order_bad && !data_bad &&
            seen0 == APU_VGPU_RSP_ADDR && seen1 == APU_VGPU_GCW_ELEM &&
            seen2 == APU_VGPU_GCW_IDX);
    end else if (name == "bad beat") begin
      check("one beat", nwrite == n0 + 1 && !gcw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), gcw_cpl_v);
    gcw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gcw_cpl_r = 1'b0;
    while (gcw_cpl_v) @(negedge clk);
  endtask

  task automatic gcr_step(input apu_vgpu_gcr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!gcr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    gcr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gcr_req = 1'b0;
    while (!gcr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gcr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_GCR_OK) begin
      check("readback", gcr.valid && gcr.resp == gcw.resp &&
            gcr.fence == gcw.fence && gcr.elem_id == gcw.elem_id &&
            gcr.elem_len == gcw.elem_len && gcr.used_idx == gcw.used_idx);
      check("read count", nread == n0 + 3 && !rd_order &&
            rd_seen0 == APU_VGPU_RSP_ADDR && rd_seen1 == APU_VGPU_GCW_ELEM &&
            rd_seen2 == APU_VGPU_GCW_IDX);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !gcr.valid);
    end else if (name == "bad element") begin
      check("two beats", nread == n0 + 2 && !gcr.valid);
    end else if (name == "bad index") begin
      check("three beats", nread == n0 + 3 && !gcr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), gcr_cpl_v);
    gcr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gcr_cpl_r = 1'b0;
    while (gcr_cpl_v) @(negedge clk);
  endtask

  task automatic gck_step(input apu_vgpu_gck_status_e st, input string name);
    @(negedge clk);
    while (!gck_rdy) @(negedge clk);
    cases++;
    gck_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gck_req = 1'b0;
    while (!gck_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), gck_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), gck_cpl_v);
    gck_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    gck_cpl_r = 1'b0;
    while (gck_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    gcw_req = 1'b0;
    gcr_req = 1'b0;
    gck_req = 1'b0;
    gcw_cpl_r = 1'b0;
    gcr_cpl_r = 1'b0;
    gck_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    gpk = '0;
    ols = '0;
    nxc = '0;
    cwr = '0;
    cxr = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && gcw == '0 &&
          gcr == '0 && gck == '0);
    check("profiles keep the completion off",
          !ApuOff.GcwEn && !ApuOff.GcrEn && !ApuOff.GckEn &&
          !ApuP1Transport.GcwEn && !ApuP1Transport.GcrEn && !ApuP1Transport.GckEn &&
          !ApuHarness.GcwEn && !ApuHarness.GcrEn && !ApuHarness.GckEn &&
          !ApuSchedBoth.GcwEn && !ApuSchedBoth.GcrEn && !ApuSchedBoth.GckEn &&
          !ApuBadVirglGrant.GcwEn && !ApuBadVirglGrant.GcrEn &&
          !ApuBadVirglGrant.GckEn);
    cfg = ApuP1Transport;
    cfg.GcwEn = 1'b1;
    cfg.GcrEn = 1'b1;
    cfg.GckEn = 1'b1;
    check("completion does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GcwEn = 1'b1;
    cfg.GcrEn = 1'b1;
    cfg.GckEn = 1'b1;
    check("completion does not legalize virgl", !apu_cfg_legal(cfg));
    check("completion places",
          APU_VGPU_RSP_ADDR == 64'h8800A800 &&
          APU_VGPU_GCW_ELEM == 64'h8800E400 &&
          APU_VGPU_GCW_IDX == 64'h8800E480 &&
          APU_VGPU_GCW_LAST == 2'd2 &&
          APU_VGPU_GCW_ELEM != APU_VGPU_SUN_ELEM &&
          APU_VGPU_GCW_IDX != APU_VGPU_SUN_IDX &&
          APU_VGPU_GCW_ELEM != APU_VGPU_OLS_ADDR &&
          APU_VGPU_GCW_ELEM != APU_VGPU_GPW_ADDR &&
          VGPU_RESP_OK_NODATA == 32'h00001100 &&
          VGPU_RESP_HDR_BYTES == 32'd24 &&
          APU_VGPU_SCENE_FENCE == 64'h1122334455667788);

    gcr_step(APU_VGPU_GCR_EMPTY, "read empty");
    gcw_step(APU_VGPU_GCW_EMPTY, "completion empty");
    gck_step(APU_VGPU_GCK_EMPTY, "keep empty");
    good_in();
    gpk = '0;
    gcw_step(APU_VGPU_GCW_EMPTY, "window missing");
    good_in();
    nxc.rsp_addr = 64'h0;
    gcw_step(APU_VGPU_GCW_FAULT, "bad response");
    good_in();
    ols.count = 32'd1;
    gcw_step(APU_VGPU_GCW_FAULT, "bad count");
    good_in();
    cxr.height = 16'd64;
    gcw_step(APU_VGPU_GCW_FAULT, "bad scissor");
    good_in();
    gpk.word = 32'h0;
    gcw_step(APU_VGPU_GCW_FAULT, "bad word");
    good_in();
    fail_wr = 1'b1;
    gcw_step(APU_VGPU_GCW_FAULT, "bad beat");
    gcw_step(APU_VGPU_GCW_OK, "completion");
    gcw_step(APU_VGPU_GCW_FAULT, "completion again");
    check("completion stays", gcw.valid && gcw.resp == VGPU_RESP_OK_NODATA &&
          gcw.fence == APU_VGPU_SCENE_FENCE && gcw.used_idx == 16'd1);
    fail_rd = 1'b1;
    gcr_step(APU_VGPU_GCR_FAULT, "bad beat");
    bad_elem = 1'b1;
    gcr_step(APU_VGPU_GCR_FAULT, "bad element");
    bad_idx = 1'b1;
    gcr_step(APU_VGPU_GCR_FAULT, "bad index");
    gcr_step(APU_VGPU_GCR_OK, "read completion");
    gcr_step(APU_VGPU_GCR_FAULT, "read completion again");
    check("read stays", gcr.resp == VGPU_RESP_OK_NODATA &&
          gcr.fence == APU_VGPU_SCENE_FENCE && gcr.elem_len == 32'd24 &&
          gcr.used_idx == 16'd1);
    gpk.word = 32'h0;
    gck_step(APU_VGPU_GCK_FAULT, "keep bad word");
    check("keep rejected", !gck.valid);
    gpk.word = APU_VGPU_CLEAR_WORD;
    gck_step(APU_VGPU_GCK_OK, "keep completion");
    check("completion kept", gck.valid && gck.resp == VGPU_RESP_OK_NODATA &&
          gck.fence == APU_VGPU_SCENE_FENCE && gck.elem_id == 32'd0 &&
          gck.elem_len == VGPU_RESP_HDR_BYTES && gck.used_idx == 16'd1);
    gck_step(APU_VGPU_GCK_FAULT, "keep again");
    check("keep stays", gck.resp == VGPU_RESP_OK_NODATA && gck.used_idx == 16'd1 &&
          gck.fence == gcw.fence);

    pulse_reset();
    check("reset clears", gcw == '0 && gcr == '0 && gck == '0);
    zero_in();
    gcw_step(APU_VGPU_GCW_EMPTY, "after reset");
    gcr_step(APU_VGPU_GCR_EMPTY, "read after reset");
    gck_step(APU_VGPU_GCK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu gcw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_gcw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
