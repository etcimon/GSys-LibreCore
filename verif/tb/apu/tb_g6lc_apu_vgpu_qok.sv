// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qok;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qwx_t qwx;
  logic qok_req = 0, qok_rdy, qok_cpl_v, qok_cpl_r = 0;
  apu_vgpu_qok_cpl_t qok_cpl;
  apu_vgpu_qok_t qok;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qol_req = 0, qol_rdy, qol_cpl_v, qol_cpl_r = 0;
  apu_vgpu_qol_cpl_t qol_cpl;
  apu_vgpu_qol_t qol;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qox_req = 0, qox_rdy, qox_cpl_v, qox_cpl_r = 0;
  apu_vgpu_qox_cpl_t qox_cpl, off_cpl;
  apu_vgpu_qox_t qox, off_qox;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, scene_fence = 0, no_flag = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] RespBeat = {64'h0, 32'h0, APU_VGPU_CTX_ID,
                                       APU_VGPU_RFW_FENCE, VGPU_FLAG_FENCE,
                                       VGPU_RESP_OK_NODATA};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qok #(.Enable(1'b1)) i_qok (
    .clk_i(clk), .rst_ni, .qwx_i(qwx),
    .req_valid_i(qok_req), .req_ready_o(qok_rdy),
    .cpl_valid_o(qok_cpl_v), .cpl_ready_i(qok_cpl_r), .cpl_o(qok_cpl), .qok_o(qok),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qol #(.Enable(1'b1)) i_qol (
    .clk_i(clk), .rst_ni, .qok_i(qok), .qwx_i(qwx),
    .req_valid_i(qol_req), .req_ready_o(qol_rdy),
    .cpl_valid_o(qol_cpl_v), .cpl_ready_i(qol_cpl_r), .cpl_o(qol_cpl), .qol_o(qol),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qox #(.Enable(1'b1)) i_qox (
    .clk_i(clk), .rst_ni, .qol_i(qol), .qok_i(qok), .qwx_i(qwx),
    .req_valid_i(qox_req), .req_ready_o(qox_rdy),
    .cpl_valid_o(qox_cpl_v), .cpl_ready_i(qox_cpl_r), .cpl_o(qox_cpl), .qox_o(qox)
  );
  g6lc_apu_vgpu_qox_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qol_i(qol), .qok_i(qok), .qwx_i(qwx),
    .req_valid_i(qox_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qox_cpl_r), .cpl_o(off_cpl), .qox_o(off_qox)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qok timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      order_bad <= 1'b0;
      data_bad <= 1'b0;
      stored_v <= 1'b0;
      stored <= '0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      if (wr_addr != APU_VGPU_RFW_ADDR || wr_len != VGPU_RESP_HDR_BYTES)
        order_bad <= 1'b1;
      if (wr_data[191:0] != RespBeat[191:0]) data_bad <= 1'b1;
      wr_seen <= wr_addr;
      stored <= wr_data;
      stored_v <= 1'b1;
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
      logic [255:0] beat;
      beat = stored_v ? stored : RespBeat;
      if (scene_fence) beat[127:64] = APU_VGPU_SCENE_FENCE;
      if (no_flag) beat[63:32] = 32'h0;
      if (rd_addr != APU_VGPU_RFW_ADDR || rd_len != VGPU_RESP_HDR_BYTES)
        rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      scene_fence <= 1'b0;
      no_flag <= 1'b0;
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
    qwx = '0;
    qwx.valid = 1'b1;
    qwx.rsp_addr = APU_VGPU_RFW_ADDR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qox == '0 &&
          off_cpl == '0);
  endtask

  task automatic qok_step(input apu_vgpu_qok_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qok_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    qok_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qok_req = 1'b0;
    while (!qok_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qok_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QOK_OK) begin
      check("response", qok.valid && qok.resp == VGPU_RESP_OK_NODATA &&
            qok.fence == APU_VGPU_RFW_FENCE &&
            qok.fence != APU_VGPU_SCENE_FENCE &&
            qok.addr == APU_VGPU_RFW_ADDR && qok.addr != APU_VGPU_RSP_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_RFW_ADDR && wr_seen != APU_VGPU_QWD_ADDR);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !qok.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qok_cpl_v);
    qok_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qok_cpl_r = 1'b0;
    while (qok_cpl_v) @(negedge clk);
  endtask

  task automatic qol_step(input apu_vgpu_qol_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qol_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qol_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qol_req = 1'b0;
    while (!qol_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qol_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QOL_OK) begin
      check("echo", qol.valid && qol.fence == APU_VGPU_RFW_FENCE &&
            qol.fence != APU_VGPU_SCENE_FENCE &&
            qol.flg == VGPU_FLAG_FENCE &&
            qol.resp == VGPU_RESP_OK_NODATA &&
            qol.addr == APU_VGPU_RFW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_RFW_ADDR);
    end else if (name == "bad read" || name == "scene fence" ||
                 name == "no flag") begin
      check("one read failed", nread == n0 + 1 && !qol.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qol_cpl_v);
    qol_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qol_cpl_r = 1'b0;
    while (qol_cpl_v) @(negedge clk);
  endtask

  task automatic qox_step(input apu_vgpu_qox_status_e st, input string name);
    @(negedge clk);
    while (!qox_rdy) @(negedge clk);
    cases++;
    qox_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qox_req = 1'b0;
    while (!qox_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qox_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qox_cpl_v);
    qox_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qox_cpl_r = 1'b0;
    while (qox_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qok_req = 1'b0;
    qol_req = 1'b0;
    qox_req = 1'b0;
    qok_cpl_r = 1'b0;
    qol_cpl_r = 1'b0;
    qox_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    stored_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qwx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qok == '0 && qol == '0 && qox == '0);
    check("profiles keep the nodata off",
          !ApuOff.QokEn && !ApuOff.QolEn && !ApuOff.QoxEn &&
          !ApuP1Transport.QokEn && !ApuP1Transport.QolEn &&
          !ApuP1Transport.QoxEn &&
          !ApuHarness.QokEn && !ApuHarness.QolEn && !ApuHarness.QoxEn &&
          !ApuSchedBoth.QokEn && !ApuSchedBoth.QolEn && !ApuSchedBoth.QoxEn &&
          !ApuBadVirglGrant.QokEn && !ApuBadVirglGrant.QolEn &&
          !ApuBadVirglGrant.QoxEn);
    cfg = ApuP1Transport;
    cfg.QokEn = 1'b1;
    cfg.QolEn = 1'b1;
    cfg.QoxEn = 1'b1;
    check("nodata does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QokEn = 1'b1;
    cfg.QolEn = 1'b1;
    cfg.QoxEn = 1'b1;
    check("nodata does not legalize virgl", !apu_cfg_legal(cfg));
    check("nodata places",
          APU_VGPU_RFW_ADDR != APU_VGPU_RSP_ADDR &&
          APU_VGPU_RFW_ADDR != APU_VGPU_QWD_ADDR &&
          APU_VGPU_RFW_FENCE == 64'd2 &&
          APU_VGPU_RFW_FENCE != APU_VGPU_SCENE_FENCE &&
          VGPU_RESP_HDR_BYTES == 32'd24);

    qok_step(APU_VGPU_QOK_EMPTY, "write empty");
    qol_step(APU_VGPU_QOL_EMPTY, "read empty");
    qox_step(APU_VGPU_QOX_EMPTY, "check empty");
    good_in();
    qwx.rsp_addr = APU_VGPU_RSP_ADDR;
    qok_step(APU_VGPU_QOK_FAULT, "scene dest");
    good_in();
    fail_wr = 1'b1;
    qok_step(APU_VGPU_QOK_FAULT, "bad write");
    qok_step(APU_VGPU_QOK_OK, "ok nodata");
    qok_step(APU_VGPU_QOK_FAULT, "write again");
    fail_rd = 1'b1;
    qol_step(APU_VGPU_QOL_FAULT, "bad read");
    scene_fence = 1'b1;
    qol_step(APU_VGPU_QOL_FAULT, "scene fence");
    no_flag = 1'b1;
    qol_step(APU_VGPU_QOL_FAULT, "no flag");
    qol_step(APU_VGPU_QOL_OK, "echo fence");
    qol_step(APU_VGPU_QOL_FAULT, "read again");
    qwx.rsp_addr = APU_VGPU_RSP_ADDR;
    qox_step(APU_VGPU_QOX_FAULT, "check scene dest");
    check("check rejected", !qox.valid);
    good_in();
    qox_step(APU_VGPU_QOX_OK, "check fence");
    check("fence checked", qox.valid && qox.fence == 64'd2 &&
          qox.resp == VGPU_RESP_OK_NODATA);
    qox_step(APU_VGPU_QOX_FAULT, "check again");
    check("check stays", qox.fence == qok.fence);

    pulse_reset();
    check("reset clears", qok == '0 && qol == '0 && qox == '0);
    qwx = '0;
    qok_step(APU_VGPU_QOK_EMPTY, "after reset");
    good_in();
    qok_step(APU_VGPU_QOK_OK, "nodata after reset");

    if (errors != 0) $fatal(1, "APU vgpu qok errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qok cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
