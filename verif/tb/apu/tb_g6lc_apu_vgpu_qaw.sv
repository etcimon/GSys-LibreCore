// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qaw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_qix_t qix;
  logic qaw_req = 0, qaw_rdy, qaw_cpl_v, qaw_cpl_r = 0;
  apu_vgpu_qaw_cpl_t qaw_cpl;
  apu_vgpu_qaw_t qaw;
  logic ard_v, ard_rdy, ard_rsp_v = 0, ard_rsp_rdy, ard_rsp_ok = 0;
  logic [63:0] ard_addr, ard_rsp_addr = 0, aseen = 0;
  logic [31:0] ard_len, ard_rsp_len = 0;
  logic [255:0] ard_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qar_req = 0, qar_rdy, qar_cpl_v, qar_cpl_r = 0;
  apu_vgpu_qar_cpl_t qar_cpl;
  apu_vgpu_qar_t qarq;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qay_req = 0, qay_rdy, qay_cpl_v, qay_cpl_r = 0;
  apu_vgpu_qay_cpl_t qay_cpl, off_cpl;
  apu_vgpu_qay_t qay, off_qay;
  logic off_rdy, off_v;
  logic fail_ard = 0, fail_rd = 0, fail_wr = 0, bad_tail = 0;
  logic a_order = 0, w_order = 0, w_data = 0, rd_order = 0;
  logic [31:0] ack_word = 32'h1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int naread = 0, nwrite = 0, nread = 0, rd_base = 0;

  assign ard_rdy = ard_v && rst_ni && !ard_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qaw #(.Enable(1'b1)) i_qaw (
    .clk_i(clk), .rst_ni, .cancel_i(cancel),
    .qix_i(qix),
    .req_valid_i(qaw_req), .req_ready_o(qaw_rdy),
    .cpl_valid_o(qaw_cpl_v), .cpl_ready_i(qaw_cpl_r), .cpl_o(qaw_cpl), .qaw_o(qaw),
    .rd_valid_o(ard_v), .rd_ready_i(ard_rdy), .rd_addr_o(ard_addr), .rd_len_o(ard_len),
    .rd_rsp_valid_i(ard_rsp_v), .rd_rsp_ready_o(ard_rsp_rdy), .rd_rsp_ok_i(ard_rsp_ok),
    .rd_rsp_addr_i(ard_rsp_addr), .rd_rsp_len_i(ard_rsp_len), .rd_rsp_data_i(ard_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qar #(.Enable(1'b1)) i_qar (
    .clk_i(clk), .rst_ni, .qaw_i(qaw), .qix_i(qix),
    .req_valid_i(qar_req), .req_ready_o(qar_rdy),
    .cpl_valid_o(qar_cpl_v), .cpl_ready_i(qar_cpl_r), .cpl_o(qar_cpl), .qar_o(qarq),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qay #(.Enable(1'b1)) i_qay (
    .clk_i(clk), .rst_ni, .qar_i(qarq), .qaw_i(qaw), .qix_i(qix),
    .req_valid_i(qay_req), .req_ready_o(qay_rdy),
    .cpl_valid_o(qay_cpl_v), .cpl_ready_i(qay_cpl_r), .cpl_o(qay_cpl), .qay_o(qay)
  );
  g6lc_apu_vgpu_qay_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qar_i(qarq), .qaw_i(qaw), .qix_i(qix),
    .req_valid_i(qay_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qay_cpl_r), .cpl_o(off_cpl), .qay_o(off_qay)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qaw timeout case=%0d", cases); end

  function automatic logic [255:0] ack_pat(input logic [31:0] word);
    ack_pat = {224'h0, word};
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      ard_rsp_v <= 1'b0;
      naread <= 0;
      a_order <= 1'b0;
    end else if (ard_rsp_v && ard_rsp_rdy) ard_rsp_v <= 1'b0;
    else if (ard_v && ard_rdy) begin
      if (ard_addr != APU_VGPU_TAW_ADDR || ard_len != 32'd4) a_order <= 1'b1;
      aseen <= ard_addr;
      ard_rsp_addr <= ard_addr;
      ard_rsp_len <= ard_len;
      ard_rsp_data <= ack_pat(ack_word);
      ard_rsp_ok <= !fail_ard;
      fail_ard <= 1'b0;
      naread <= naread + 1;
      ard_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      w_order <= 1'b0;
      w_data <= 1'b0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      if (wr_addr != APU_VGPU_TIW_ADDR || wr_len != 32'd4) w_order <= 1'b1;
      if (wr_data != {224'h0, APU_VGPU_VAW_CLEAR}) w_data <= 1'b1;
      wseen <= wr_addr;
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
      logic [31:0] word;
      idx = nread - rd_base;
      want = idx == 0 ? APU_VGPU_TAW_ADDR : APU_VGPU_TIW_ADDR;
      word = idx == 0 ? APU_VGPU_TIW_REASON : APU_VGPU_VAW_CLEAR;
      if (idx == 1 && bad_tail) word = 32'h1;
      if (rd_addr != want || rd_len != 32'd4) rd_order <= 1'b1;
      if (idx == 0) rd_seen0 <= rd_addr;
      else rd_seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= ack_pat(word);
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
    qix = '0;
    qix.valid = 1'b1;
    qix.reason = APU_VGPU_TIW_REASON;
    qix.used_idx = APU_VGPU_TUW_IDXV;
    qix.addr = APU_VGPU_TIW_ADDR;
    ack_word = APU_VGPU_TIW_REASON;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qay == '0 &&
          off_cpl == '0);
  endtask

  task automatic qaw_step(input apu_vgpu_qaw_status_e st, input string name);
    int nr, nw;
    @(negedge clk);
    while (!qaw_rdy) @(negedge clk);
    cases++;
    nr = naread;
    nw = nwrite;
    qaw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qaw_req = 1'b0;
    while (!qaw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qaw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QAW_OK) begin
      check("acked", qaw.valid && qaw.ack == APU_VGPU_TIW_REASON &&
            qaw.remain == APU_VGPU_VAW_CLEAR &&
            qaw.used_idx == APU_VGPU_TUW_IDXV &&
            qaw.ack_addr == APU_VGPU_TAW_ADDR &&
            qaw.status_addr == APU_VGPU_TIW_ADDR &&
            qaw.ack_addr != APU_VGPU_VAW_ADDR &&
            qaw.status_addr != APU_VGPU_VIW_ADDR);
      check("bus", naread == nr + 1 && nwrite == nw + 1 && !a_order &&
            !w_order && !w_data && aseen == APU_VGPU_TAW_ADDR &&
            wseen == APU_VGPU_TIW_ADDR);
    end else if (name == "bad beat" || name == "config ack" || name == "zero ack") begin
      check("read only", naread == nr + 1 && nwrite == nw && !qaw.valid);
    end else if (name == "bad clear") begin
      check("both beats", naread == nr + 1 && nwrite == nw + 1 && !qaw.valid);
    end else check("no bus", naread == nr && nwrite == nw);
    @(negedge clk);
    check($sformatf("%s held", name), qaw_cpl_v);
    qaw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qaw_cpl_r = 1'b0;
    while (qaw_cpl_v) @(negedge clk);
  endtask

  task automatic qar_step(input apu_vgpu_qar_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qar_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    qar_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qar_req = 1'b0;
    while (!qar_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qar_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QAR_OK) begin
      check("readback", qarq.valid && qarq.ack == qaw.ack &&
            qarq.remain == qaw.remain && qarq.used_idx == qaw.used_idx &&
            qarq.ack != qarq.remain &&
            qarq.ack_addr == APU_VGPU_TAW_ADDR &&
            qarq.status_addr == APU_VGPU_TIW_ADDR);
      check("read count", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_TAW_ADDR && rd_seen1 == APU_VGPU_TIW_ADDR);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !qarq.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !qarq.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qar_cpl_v);
    qar_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qar_cpl_r = 1'b0;
    while (qar_cpl_v) @(negedge clk);
  endtask

  task automatic qay_step(input apu_vgpu_qay_status_e st, input string name);
    @(negedge clk);
    while (!qay_rdy) @(negedge clk);
    cases++;
    qay_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qay_req = 1'b0;
    while (!qay_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qay_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qay_cpl_v);
    qay_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qay_cpl_r = 1'b0;
    while (qay_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qaw_req = 1'b0;
    qar_req = 1'b0;
    qay_req = 1'b0;
    qaw_cpl_r = 1'b0;
    qar_cpl_r = 1'b0;
    qay_cpl_r = 1'b0;
    cancel = 1'b0;
    ard_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    qix = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qaw == '0 && qarq == '0 && qay == '0);
    check("profiles keep the ack off",
          !ApuOff.QawEn && !ApuOff.QarEn && !ApuOff.QayEn &&
          !ApuP1Transport.QawEn && !ApuP1Transport.QarEn && !ApuP1Transport.QayEn &&
          !ApuHarness.QawEn && !ApuHarness.QarEn && !ApuHarness.QayEn &&
          !ApuSchedBoth.QawEn && !ApuSchedBoth.QarEn && !ApuSchedBoth.QayEn &&
          !ApuBadVirglGrant.QawEn && !ApuBadVirglGrant.QarEn &&
          !ApuBadVirglGrant.QayEn);
    cfg = ApuP1Transport;
    cfg.QawEn = 1'b1;
    cfg.QarEn = 1'b1;
    cfg.QayEn = 1'b1;
    check("ack does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QawEn = 1'b1;
    cfg.QarEn = 1'b1;
    cfg.QayEn = 1'b1;
    check("ack does not legalize virgl", !apu_cfg_legal(cfg));
    check("ack places",
          APU_VGPU_TAW_ADDR == 64'h880C0010 &&
          APU_VGPU_VAW_CLEAR == 32'h0 &&
          APU_VGPU_TIW_REASON == 32'h1 &&
          APU_VGPU_TAW_ADDR != APU_VGPU_VAW_ADDR &&
          APU_VGPU_TAW_ADDR != APU_VGPU_TIW_ADDR &&
          APU_VGPU_TAW_ADDR != APU_VGPU_VIW_ADDR &&
          APU_VGPU_TAW_ADDR != 64'h40001000);

    qar_step(APU_VGPU_QAR_EMPTY, "read empty");
    qaw_step(APU_VGPU_QAW_EMPTY, "ack empty");
    qay_step(APU_VGPU_QAY_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    qaw_step(APU_VGPU_QAW_FAULT, "cancel");
    cancel = 1'b0;
    qix.addr = APU_VGPU_VIW_ADDR;
    qaw_step(APU_VGPU_QAW_FAULT, "scene status");
    good_in();
    qix.used_idx = 16'd1;
    qaw_step(APU_VGPU_QAW_FAULT, "scene index");
    good_in();
    fail_ard = 1'b1;
    qaw_step(APU_VGPU_QAW_FAULT, "bad beat");
    good_in();
    ack_word = 32'h2;
    qaw_step(APU_VGPU_QAW_FAULT, "config ack");
    good_in();
    ack_word = 32'h0;
    qaw_step(APU_VGPU_QAW_FAULT, "zero ack");
    good_in();
    fail_wr = 1'b1;
    qaw_step(APU_VGPU_QAW_FAULT, "bad clear");
    qaw_step(APU_VGPU_QAW_OK, "ack");
    qaw_step(APU_VGPU_QAW_FAULT, "ack again");
    check("ack stays", qaw.valid && qaw.ack == 32'h1 && qaw.remain == 32'h0 &&
          qaw.used_idx == 16'd2);
    fail_rd = 1'b1;
    qar_step(APU_VGPU_QAR_FAULT, "bad beat");
    bad_tail = 1'b1;
    qar_step(APU_VGPU_QAR_FAULT, "bad tail");
    qar_step(APU_VGPU_QAR_OK, "read ack");
    qar_step(APU_VGPU_QAR_FAULT, "read ack again");
    check("read stays", qarq.ack == 32'h1 && qarq.remain == 32'h0 &&
          qarq.used_idx == 16'd2);
    qix.used_idx = 16'd1;
    qay_step(APU_VGPU_QAY_FAULT, "keep bad index");
    check("keep rejected", !qay.valid);
    qix.used_idx = APU_VGPU_TUW_IDXV;
    qay_step(APU_VGPU_QAY_OK, "keep ack");
    check("ack kept", qay.valid && qay.ack == 32'h1 && qay.remain == 32'h0 &&
          qay.used_idx == 16'd2);
    qay_step(APU_VGPU_QAY_FAULT, "keep again");
    check("keep stays", qay.ack == qaw.ack && qay.remain == qaw.remain);

    pulse_reset();
    check("reset clears", qaw == '0 && qarq == '0 && qay == '0);
    zero_in();
    qaw_step(APU_VGPU_QAW_EMPTY, "after reset");
    qar_step(APU_VGPU_QAR_EMPTY, "read after reset");
    qay_step(APU_VGPU_QAY_EMPTY, "keep after reset");
    good_in();
    qaw_step(APU_VGPU_QAW_OK, "ack after reset");

    if (errors != 0) $fatal(1, "APU vgpu qaw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qaw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
