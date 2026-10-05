// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qsu;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_qsq_t qsq;
  logic qsu_req = 0, qsu_rdy, qsu_cpl_v, qsu_cpl_r = 0;
  apu_vgpu_qsu_cpl_t qsu_cpl;
  apu_vgpu_qsu_t qsu;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen0 = 0, wr_seen1 = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qst_req = 0, qst_rdy, qst_cpl_v, qst_cpl_r = 0;
  apu_vgpu_qst_cpl_t qst_cpl;
  apu_vgpu_qst_t qst;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qsz_req = 0, qsz_rdy, qsz_cpl_v, qsz_cpl_r = 0;
  apu_vgpu_qsz_cpl_t qsz_cpl, off_cpl;
  apu_vgpu_qsz_t qsz, off_qsz;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_idx = 0, fail_rd = 0, xfer_id = 0, xfer_idx = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored0 = 0, stored1 = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, wr_base = 0, nread = 0, rd_base = 0;

  localparam logic [255:0] ElemBeat = {192'h0, VGPU_RESP_HDR_BYTES, APU_VGPU_QSU_ID};
  localparam logic [255:0] IdxBeat  = {224'h0, APU_VGPU_QSU_IDXV, 16'd0};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qsu #(.Enable(1'b1)) i_qsu (
    .clk_i(clk), .rst_ni, .qsq_i(qsq),
    .req_valid_i(qsu_req), .req_ready_o(qsu_rdy),
    .cpl_valid_o(qsu_cpl_v), .cpl_ready_i(qsu_cpl_r), .cpl_o(qsu_cpl), .qsu_o(qsu),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qst #(.Enable(1'b1)) i_qst (
    .clk_i(clk), .rst_ni, .qsu_i(qsu), .qsq_i(qsq),
    .req_valid_i(qst_req), .req_ready_o(qst_rdy),
    .cpl_valid_o(qst_cpl_v), .cpl_ready_i(qst_cpl_r), .cpl_o(qst_cpl), .qst_o(qst),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qsz #(.Enable(1'b1)) i_qsz (
    .clk_i(clk), .rst_ni, .qst_i(qst), .qsu_i(qsu), .qsq_i(qsq),
    .req_valid_i(qsz_req), .req_ready_o(qsz_rdy),
    .cpl_valid_o(qsz_cpl_v), .cpl_ready_i(qsz_cpl_r), .cpl_o(qsz_cpl), .qsz_o(qsz)
  );
  g6lc_apu_vgpu_qsz_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qst_i(qst), .qsu_i(qsu), .qsq_i(qsq),
    .req_valid_i(qsz_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qsz_cpl_r), .cpl_o(off_cpl), .qsz_o(off_qsz)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qsu timeout case=%0d", cases); end

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
      want = idx == 0 ? APU_VGPU_QSU_ELEM : APU_VGPU_QSU_IDX;
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
      want = idx == 0 ? APU_VGPU_QSU_ELEM : APU_VGPU_QSU_IDX;
      rlen = idx == 0 ? 32'd8 : 32'd4;
      beat = idx == 0 ? stored0 : stored1;
      if (idx == 0 && xfer_id) beat[31:0] = APU_VGPU_TUW_ID;
      if (idx == 1 && xfer_idx) beat[31:16] = APU_VGPU_TUW_IDXV;
      if (rd_addr != want || rd_len != rlen) rd_order <= 1'b1;
      if (idx == 0) rd_seen0 <= rd_addr;
      rd_seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 0) xfer_id <= 1'b0;
      if (idx == 1) xfer_idx <= 1'b0;
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
    qsq = '0;
    qsq.valid = 1'b1;
    qsq.fence = APU_VGPU_SCENE_FENCE;
    qsq.resp = VGPU_RESP_OK_NODATA;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qsz == '0 &&
          off_cpl == '0);
  endtask

  task automatic qsu_step(input apu_vgpu_qsu_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qsu_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    qsu_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsu_req = 1'b0;
    while (!qsu_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsu_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QSU_OK) begin
      check("used", qsu.valid && qsu.elem_id == APU_VGPU_QSU_ID &&
            qsu.elem_id != APU_VGPU_TUW_ID && qsu.elem_len == VGPU_RESP_HDR_BYTES &&
            qsu.used_idx == APU_VGPU_QSU_IDXV && qsu.used_idx != APU_VGPU_TUW_IDXV &&
            qsu.elem_addr == APU_VGPU_QSU_ELEM &&
            qsu.elem_addr != APU_VGPU_TUW_ELEM &&
            qsu.idx_addr == APU_VGPU_QSU_IDX);
      check("two writes", nwrite == n0 + 2 && !order_bad && !data_bad &&
            wr_seen0 == APU_VGPU_QSU_ELEM && wr_seen1 == APU_VGPU_QSU_IDX);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !qsu.valid);
    end else if (name == "bad index write") begin
      check("two writes failed", nwrite == n0 + 2 && !qsu.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qsu_cpl_v);
    qsu_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsu_cpl_r = 1'b0;
    while (qsu_cpl_v) @(negedge clk);
  endtask

  task automatic qst_step(input apu_vgpu_qst_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qst_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    qst_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qst_req = 1'b0;
    while (!qst_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qst_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QST_OK) begin
      check("echo", qst.valid && qst.elem_id == APU_VGPU_QSU_ID &&
            qst.used_idx == APU_VGPU_QSU_IDXV &&
            qst.elem_addr == APU_VGPU_QSU_ELEM);
      check("two reads", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_QSU_ELEM && rd_seen1 == APU_VGPU_QSU_IDX);
    end else if (name == "bad read" || name == "xfer id") begin
      check("one read failed", nread == n0 + 1 && !qst.valid);
    end else if (name == "xfer idx") begin
      check("two reads failed", nread == n0 + 2 && !qst.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qst_cpl_v);
    qst_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qst_cpl_r = 1'b0;
    while (qst_cpl_v) @(negedge clk);
  endtask

  task automatic qsz_step(input apu_vgpu_qsz_status_e st, input string name);
    @(negedge clk);
    while (!qsz_rdy) @(negedge clk);
    cases++;
    qsz_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsz_req = 1'b0;
    while (!qsz_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsz_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qsz_cpl_v);
    qsz_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsz_cpl_r = 1'b0;
    while (qsz_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qsu_req = 1'b0;
    qst_req = 1'b0;
    qsz_req = 1'b0;
    qsu_cpl_r = 1'b0;
    qst_cpl_r = 1'b0;
    qsz_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qsq = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qsu == '0 && qst == '0 && qsz == '0);
    check("profiles keep the used ring off",
          !ApuOff.QsuEn && !ApuOff.QstEn && !ApuOff.QszEn &&
          !ApuP1Transport.QsuEn && !ApuP1Transport.QstEn &&
          !ApuP1Transport.QszEn &&
          !ApuHarness.QsuEn && !ApuHarness.QstEn && !ApuHarness.QszEn &&
          !ApuSchedBoth.QsuEn && !ApuSchedBoth.QstEn && !ApuSchedBoth.QszEn &&
          !ApuBadVirglGrant.QsuEn && !ApuBadVirglGrant.QstEn &&
          !ApuBadVirglGrant.QszEn);
    cfg = ApuP1Transport;
    cfg.QsuEn = 1'b1;
    cfg.QstEn = 1'b1;
    cfg.QszEn = 1'b1;
    check("used ring does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QsuEn = 1'b1;
    cfg.QstEn = 1'b1;
    cfg.QszEn = 1'b1;
    check("used ring does not legalize virgl", !apu_cfg_legal(cfg));
    check("known used",
          APU_VGPU_QSU_ELEM != APU_VGPU_TUW_ELEM &&
          APU_VGPU_QSU_IDX != APU_VGPU_TUW_IDX &&
          APU_VGPU_QSU_IDX == APU_VGPU_GCW_IDX &&
          APU_VGPU_QSU_ID != APU_VGPU_TUW_ID &&
          APU_VGPU_QSU_IDXV != APU_VGPU_TUW_IDXV);

    qsu_step(APU_VGPU_QSU_EMPTY, "write empty");
    qst_step(APU_VGPU_QST_EMPTY, "read empty");
    qsz_step(APU_VGPU_QSZ_EMPTY, "index empty");
    good_in();
    qsq.fence = APU_VGPU_RFW_FENCE;
    qsu_step(APU_VGPU_QSU_FAULT, "xfer fence");
    good_in();
    fail_wr = 1'b1;
    qsu_step(APU_VGPU_QSU_FAULT, "bad write");
    fail_idx = 1'b1;
    qsu_step(APU_VGPU_QSU_FAULT, "bad index write");
    qsu_step(APU_VGPU_QSU_OK, "used element");
    qsu_step(APU_VGPU_QSU_FAULT, "write again");
    fail_rd = 1'b1;
    qst_step(APU_VGPU_QST_FAULT, "bad read");
    xfer_id = 1'b1;
    qst_step(APU_VGPU_QST_FAULT, "xfer id");
    xfer_idx = 1'b1;
    qst_step(APU_VGPU_QST_FAULT, "xfer idx");
    qst_step(APU_VGPU_QST_OK, "echo used");
    qst_step(APU_VGPU_QST_FAULT, "read again");
    qsq.fence = APU_VGPU_RFW_FENCE;
    qsz_step(APU_VGPU_QSZ_FAULT, "check xfer fence");
    check("check rejected", !qsz.valid);
    good_in();
    qsz_step(APU_VGPU_QSZ_OK, "index one");
    check("index one", qsz.valid && qsz.used_idx == 16'd1 &&
          qsz.used_idx != 16'd2 && qsz.elem_id == 32'd0);
    qsz_step(APU_VGPU_QSZ_FAULT, "index again");
    check("index stays", qsz.used_idx == APU_VGPU_QSU_IDXV);

    pulse_reset();
    check("reset clears", qsu == '0 && qst == '0 && qsz == '0);
    qsq = '0;
    qsu_step(APU_VGPU_QSU_EMPTY, "after reset");
    good_in();
    qsu_step(APU_VGPU_QSU_OK, "write after reset");

    if (errors != 0) $fatal(1, "APU vgpu qsu errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qsu cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
