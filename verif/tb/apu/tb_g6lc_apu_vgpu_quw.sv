// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_quw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qox_t qox;
  logic quw_req = 0, quw_rdy, quw_cpl_v, quw_cpl_r = 0;
  apu_vgpu_quw_cpl_t quw_cpl;
  apu_vgpu_quw_t quw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen0 = 0, wr_seen1 = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qul_req = 0, qul_rdy, qul_cpl_v, qul_cpl_r = 0;
  apu_vgpu_qul_cpl_t qul_cpl;
  apu_vgpu_qul_t qul;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qux_req = 0, qux_rdy, qux_cpl_v, qux_cpl_r = 0;
  apu_vgpu_qux_cpl_t qux_cpl, off_cpl;
  apu_vgpu_qux_t qux, off_qux;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_idx = 0, fail_rd = 0, scene_id = 0, scene_idx = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored0 = 0, stored1 = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, wr_base = 0, nread = 0, rd_base = 0;

  localparam logic [255:0] ElemBeat = {192'h0, VGPU_RESP_HDR_BYTES, APU_VGPU_TUW_ID};
  localparam logic [255:0] IdxBeat  = {224'h0, APU_VGPU_TUW_IDXV, 16'd0};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_quw #(.Enable(1'b1)) i_quw (
    .clk_i(clk), .rst_ni, .qox_i(qox),
    .req_valid_i(quw_req), .req_ready_o(quw_rdy),
    .cpl_valid_o(quw_cpl_v), .cpl_ready_i(quw_cpl_r), .cpl_o(quw_cpl), .quw_o(quw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qul #(.Enable(1'b1)) i_qul (
    .clk_i(clk), .rst_ni, .quw_i(quw), .qox_i(qox),
    .req_valid_i(qul_req), .req_ready_o(qul_rdy),
    .cpl_valid_o(qul_cpl_v), .cpl_ready_i(qul_cpl_r), .cpl_o(qul_cpl), .qul_o(qul),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qux #(.Enable(1'b1)) i_qux (
    .clk_i(clk), .rst_ni, .qul_i(qul), .quw_i(quw), .qox_i(qox),
    .req_valid_i(qux_req), .req_ready_o(qux_rdy),
    .cpl_valid_o(qux_cpl_v), .cpl_ready_i(qux_cpl_r), .cpl_o(qux_cpl), .qux_o(qux)
  );
  g6lc_apu_vgpu_qux_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qul_i(qul), .quw_i(quw), .qox_i(qox),
    .req_valid_i(qux_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qux_cpl_r), .cpl_o(off_cpl), .qux_o(off_qux)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu quw timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      order_bad <= 1'b0;
      data_bad <= 1'b0;
      stored0 <= '0;
      stored1 <= '0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      int idx;
      logic [63:0] want;
      logic [31:0] wlen;
      logic [255:0] wdat;
      idx = nwrite - wr_base;
      want = idx == 0 ? APU_VGPU_TUW_ELEM : APU_VGPU_TUW_IDX;
      wlen = idx == 0 ? 32'd8 : 32'd4;
      wdat = idx == 0 ? ElemBeat : IdxBeat;
      if (wr_addr != want || wr_len != wlen) order_bad <= 1'b1;
      if (idx == 0 && wr_data[63:0] != wdat[63:0]) data_bad <= 1'b1;
      if (idx == 1 && wr_data[31:0] != wdat[31:0]) data_bad <= 1'b1;
      if (idx == 0) begin
        wr_seen0 <= wr_addr;
        stored0 <= wr_data;
      end
      wr_seen1 <= wr_addr;
      stored1 <= wr_data;
      wr_rsp_addr <= wr_addr;
      wr_rsp_ok <= !(idx == 0 ? fail_wr : fail_idx);
      if (idx == 0) fail_wr <= 1'b0;
      else fail_idx <= 1'b0;
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
      logic [31:0] rlen;
      logic [255:0] beat;
      idx = nread - rd_base;
      want = idx == 0 ? APU_VGPU_TUW_ELEM : APU_VGPU_TUW_IDX;
      rlen = idx == 0 ? 32'd8 : 32'd4;
      beat = idx == 0 ? stored0 : stored1;
      if (idx == 0 && scene_id) beat[31:0] = 32'd0;
      if (idx == 1 && scene_idx) beat[31:16] = 16'd1;
      if (rd_addr != want || rd_len != rlen) rd_order <= 1'b1;
      if (idx == 0) rd_seen0 <= rd_addr;
      rd_seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 0) scene_id <= 1'b0;
      if (idx == 1) scene_idx <= 1'b0;
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
    qox = '0;
    qox.valid = 1'b1;
    qox.fence = APU_VGPU_RFW_FENCE;
    qox.resp = VGPU_RESP_OK_NODATA;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qux == '0 &&
          off_cpl == '0);
  endtask

  task automatic quw_step(input apu_vgpu_quw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!quw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    quw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    quw_req = 1'b0;
    while (!quw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), quw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QUW_OK) begin
      check("used", quw.valid && quw.elem_id == APU_VGPU_TUW_ID &&
            quw.elem_id != 32'd0 && quw.elem_len == VGPU_RESP_HDR_BYTES &&
            quw.used_idx == APU_VGPU_TUW_IDXV && quw.used_idx != 16'd1 &&
            quw.elem_addr == APU_VGPU_TUW_ELEM &&
            quw.elem_addr != APU_VGPU_GCW_ELEM &&
            quw.idx_addr == APU_VGPU_TUW_IDX);
      check("two writes", nwrite == n0 + 2 && !order_bad && !data_bad &&
            wr_seen0 == APU_VGPU_TUW_ELEM && wr_seen1 == APU_VGPU_TUW_IDX);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !quw.valid);
    end else if (name == "bad index write") begin
      check("two writes failed", nwrite == n0 + 2 && !quw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), quw_cpl_v);
    quw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    quw_cpl_r = 1'b0;
    while (quw_cpl_v) @(negedge clk);
  endtask

  task automatic qul_step(input apu_vgpu_qul_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qul_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    qul_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qul_req = 1'b0;
    while (!qul_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qul_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QUL_OK) begin
      check("echo", qul.valid && qul.elem_id == APU_VGPU_TUW_ID &&
            qul.used_idx == APU_VGPU_TUW_IDXV &&
            qul.elem_addr == APU_VGPU_TUW_ELEM);
      check("two reads", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_TUW_ELEM && rd_seen1 == APU_VGPU_TUW_IDX);
    end else if (name == "bad read" || name == "scene id") begin
      check("one read failed", nread == n0 + 1 && !qul.valid);
    end else if (name == "scene idx") begin
      check("two reads failed", nread == n0 + 2 && !qul.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qul_cpl_v);
    qul_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qul_cpl_r = 1'b0;
    while (qul_cpl_v) @(negedge clk);
  endtask

  task automatic qux_step(input apu_vgpu_qux_status_e st, input string name);
    @(negedge clk);
    while (!qux_rdy) @(negedge clk);
    cases++;
    qux_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qux_req = 1'b0;
    while (!qux_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qux_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qux_cpl_v);
    qux_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qux_cpl_r = 1'b0;
    while (qux_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    quw_req = 1'b0;
    qul_req = 1'b0;
    qux_req = 1'b0;
    quw_cpl_r = 1'b0;
    qul_cpl_r = 1'b0;
    qux_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qox = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          quw == '0 && qul == '0 && qux == '0);
    check("profiles keep the used ring off",
          !ApuOff.QuwEn && !ApuOff.QulEn && !ApuOff.QuxEn &&
          !ApuP1Transport.QuwEn && !ApuP1Transport.QulEn &&
          !ApuP1Transport.QuxEn &&
          !ApuHarness.QuwEn && !ApuHarness.QulEn && !ApuHarness.QuxEn &&
          !ApuSchedBoth.QuwEn && !ApuSchedBoth.QulEn && !ApuSchedBoth.QuxEn &&
          !ApuBadVirglGrant.QuwEn && !ApuBadVirglGrant.QulEn &&
          !ApuBadVirglGrant.QuxEn);
    cfg = ApuP1Transport;
    cfg.QuwEn = 1'b1;
    cfg.QulEn = 1'b1;
    cfg.QuxEn = 1'b1;
    check("used ring does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QuwEn = 1'b1;
    cfg.QulEn = 1'b1;
    cfg.QuxEn = 1'b1;
    check("used ring does not legalize virgl", !apu_cfg_legal(cfg));
    check("known used",
          APU_VGPU_TUW_ELEM != APU_VGPU_GCW_ELEM &&
          APU_VGPU_TUW_IDX != APU_VGPU_GCW_IDX &&
          APU_VGPU_TUW_IDX == APU_VGPU_TUW_ELEM + 64'd8 &&
          APU_VGPU_TUW_ID != 32'd0 &&
          APU_VGPU_TUW_IDXV != 16'd1);

    quw_step(APU_VGPU_QUW_EMPTY, "write empty");
    qul_step(APU_VGPU_QUL_EMPTY, "read empty");
    qux_step(APU_VGPU_QUX_EMPTY, "index empty");
    good_in();
    qox.fence = APU_VGPU_SCENE_FENCE;
    quw_step(APU_VGPU_QUW_FAULT, "scene fence");
    good_in();
    fail_wr = 1'b1;
    quw_step(APU_VGPU_QUW_FAULT, "bad write");
    fail_idx = 1'b1;
    quw_step(APU_VGPU_QUW_FAULT, "bad index write");
    quw_step(APU_VGPU_QUW_OK, "used element");
    quw_step(APU_VGPU_QUW_FAULT, "write again");
    fail_rd = 1'b1;
    qul_step(APU_VGPU_QUL_FAULT, "bad read");
    scene_id = 1'b1;
    qul_step(APU_VGPU_QUL_FAULT, "scene id");
    scene_idx = 1'b1;
    qul_step(APU_VGPU_QUL_FAULT, "scene idx");
    qul_step(APU_VGPU_QUL_OK, "echo used");
    qul_step(APU_VGPU_QUL_FAULT, "read again");
    qox.fence = APU_VGPU_SCENE_FENCE;
    qux_step(APU_VGPU_QUX_FAULT, "check scene fence");
    check("check rejected", !qux.valid);
    good_in();
    qux_step(APU_VGPU_QUX_OK, "index two");
    check("index two", qux.valid && qux.used_idx == 16'd2 &&
          qux.used_idx != 16'd1 && qux.elem_id == 32'd1);
    qux_step(APU_VGPU_QUX_FAULT, "index again");
    check("index stays", qux.used_idx == APU_VGPU_TUW_IDXV);

    pulse_reset();
    check("reset clears", quw == '0 && qul == '0 && qux == '0);
    qox = '0;
    quw_step(APU_VGPU_QUW_EMPTY, "after reset");
    good_in();
    quw_step(APU_VGPU_QUW_OK, "write after reset");

    if (errors != 0) $fatal(1, "APU vgpu quw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_quw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
