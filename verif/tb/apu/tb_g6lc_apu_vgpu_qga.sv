// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qga;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_qsm_t qsm;
  logic qga_req = 0, qga_rdy, qga_cpl_v, qga_cpl_r = 0;
  apu_vgpu_qga_cpl_t qga_cpl;
  apu_vgpu_qga_t qga;
  logic ard_v, ard_rdy, ard_rsp_v = 0, ard_rsp_rdy, ard_rsp_ok = 0;
  logic [63:0] ard_addr, ard_rsp_addr = 0, aseen = 0;
  logic [31:0] ard_len, ard_rsp_len = 0;
  logic [255:0] ard_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qgk_req = 0, qgk_rdy, qgk_cpl_v, qgk_cpl_r = 0;
  apu_vgpu_qgk_cpl_t qgk_cpl;
  apu_vgpu_qgk_t qgkq;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qgx_req = 0, qgx_rdy, qgx_cpl_v, qgx_cpl_r = 0;
  apu_vgpu_qgx_cpl_t qgx_cpl, off_cpl;
  apu_vgpu_qgx_t qgx, off_qgx;
  logic off_rdy, off_v;
  logic fail_ard = 0, fail_rd = 0, fail_wr = 0, bad_tail = 0;
  logic a_order = 0, w_order = 0, w_data = 0, rd_order = 0;
  logic [31:0] ack_word = 32'h1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int naread = 0, nwrite = 0, nread = 0, rd_base = 0;

  assign ard_rdy = ard_v && rst_ni && !ard_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qga #(.Enable(1'b1)) i_qga (
    .clk_i(clk), .rst_ni, .cancel_i(cancel),
    .qsm_i(qsm),
    .req_valid_i(qga_req), .req_ready_o(qga_rdy),
    .cpl_valid_o(qga_cpl_v), .cpl_ready_i(qga_cpl_r), .cpl_o(qga_cpl), .qga_o(qga),
    .rd_valid_o(ard_v), .rd_ready_i(ard_rdy), .rd_addr_o(ard_addr), .rd_len_o(ard_len),
    .rd_rsp_valid_i(ard_rsp_v), .rd_rsp_ready_o(ard_rsp_rdy), .rd_rsp_ok_i(ard_rsp_ok),
    .rd_rsp_addr_i(ard_rsp_addr), .rd_rsp_len_i(ard_rsp_len), .rd_rsp_data_i(ard_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qgk #(.Enable(1'b1)) i_qgk (
    .clk_i(clk), .rst_ni, .qga_i(qga), .qsm_i(qsm),
    .req_valid_i(qgk_req), .req_ready_o(qgk_rdy),
    .cpl_valid_o(qgk_cpl_v), .cpl_ready_i(qgk_cpl_r), .cpl_o(qgk_cpl), .qgk_o(qgkq),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qgx #(.Enable(1'b1)) i_qgx (
    .clk_i(clk), .rst_ni, .qgk_i(qgkq), .qga_i(qga), .qsm_i(qsm),
    .req_valid_i(qgx_req), .req_ready_o(qgx_rdy),
    .cpl_valid_o(qgx_cpl_v), .cpl_ready_i(qgx_cpl_r), .cpl_o(qgx_cpl), .qgx_o(qgx)
  );
  g6lc_apu_vgpu_qgx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qgk_i(qgkq), .qga_i(qga), .qsm_i(qsm),
    .req_valid_i(qgx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qgx_cpl_r), .cpl_o(off_cpl), .qgx_o(off_qgx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qga timeout case=%0d", cases); end

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
      if (ard_addr != APU_VGPU_QGA_ADDR || ard_len != 32'd4) a_order <= 1'b1;
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
      if (wr_addr != APU_VGPU_QGA_STAT || wr_len != 32'd4) w_order <= 1'b1;
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
      want = idx == 0 ? APU_VGPU_QGA_ADDR : APU_VGPU_QGA_STAT;
      word = idx == 0 ? APU_VGPU_QSI_REASON : APU_VGPU_VAW_CLEAR;
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
    qsm = '0;
    qsm.valid = 1'b1;
    qsm.reason = APU_VGPU_QSI_REASON;
    qsm.used_idx = APU_VGPU_QSU_IDXV;
    qsm.addr = APU_VGPU_QGA_STAT;
    ack_word = APU_VGPU_QSI_REASON;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qgx == '0 &&
          off_cpl == '0);
  endtask

  task automatic qga_step(input apu_vgpu_qga_status_e st, input string name);
    int nr, nw;
    @(negedge clk);
    while (!qga_rdy) @(negedge clk);
    cases++;
    nr = naread;
    nw = nwrite;
    qga_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qga_req = 1'b0;
    while (!qga_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qga_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QGA_OK) begin
      check("acked", qga.valid && qga.ack == APU_VGPU_QSI_REASON &&
            qga.remain == APU_VGPU_VAW_CLEAR &&
            qga.used_idx == APU_VGPU_QSU_IDXV &&
            qga.ack_addr == APU_VGPU_QGA_ADDR &&
            qga.status_addr == APU_VGPU_QGA_STAT &&
            qga.ack_addr != APU_VGPU_TAW_ADDR &&
            qga.status_addr != APU_VGPU_TIW_ADDR);
      check("bus", naread == nr + 1 && nwrite == nw + 1 && !a_order &&
            !w_order && !w_data && aseen == APU_VGPU_QGA_ADDR &&
            wseen == APU_VGPU_QGA_STAT);
    end else if (name == "bad beat" || name == "config ack" || name == "zero ack") begin
      check("read only", naread == nr + 1 && nwrite == nw && !qga.valid);
    end else if (name == "bad clear") begin
      check("both beats", naread == nr + 1 && nwrite == nw + 1 && !qga.valid);
    end else check("no bus", naread == nr && nwrite == nw);
    @(negedge clk);
    check($sformatf("%s held", name), qga_cpl_v);
    qga_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qga_cpl_r = 1'b0;
    while (qga_cpl_v) @(negedge clk);
  endtask

  task automatic qgk_step(input apu_vgpu_qgk_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qgk_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    qgk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qgk_req = 1'b0;
    while (!qgk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qgk_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QGK_OK) begin
      check("readback", qgkq.valid && qgkq.ack == qga.ack &&
            qgkq.remain == qga.remain && qgkq.used_idx == qga.used_idx &&
            qgkq.ack != qgkq.remain &&
            qgkq.ack_addr == APU_VGPU_QGA_ADDR &&
            qgkq.status_addr == APU_VGPU_QGA_STAT);
      check("read count", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_QGA_ADDR && rd_seen1 == APU_VGPU_QGA_STAT);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !qgkq.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !qgkq.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qgk_cpl_v);
    qgk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qgk_cpl_r = 1'b0;
    while (qgk_cpl_v) @(negedge clk);
  endtask

  task automatic qgx_step(input apu_vgpu_qgx_status_e st, input string name);
    @(negedge clk);
    while (!qgx_rdy) @(negedge clk);
    cases++;
    qgx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qgx_req = 1'b0;
    while (!qgx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qgx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qgx_cpl_v);
    qgx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qgx_cpl_r = 1'b0;
    while (qgx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qga_req = 1'b0;
    qgk_req = 1'b0;
    qgx_req = 1'b0;
    qga_cpl_r = 1'b0;
    qgk_cpl_r = 1'b0;
    qgx_cpl_r = 1'b0;
    cancel = 1'b0;
    ard_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    qsm = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qga == '0 && qgkq == '0 && qgx == '0);
    check("profiles keep the ack off",
          !ApuOff.QgaEn && !ApuOff.QgkEn && !ApuOff.QgxEn &&
          !ApuP1Transport.QgaEn && !ApuP1Transport.QgkEn && !ApuP1Transport.QgxEn &&
          !ApuHarness.QgaEn && !ApuHarness.QgkEn && !ApuHarness.QgxEn &&
          !ApuSchedBoth.QgaEn && !ApuSchedBoth.QgkEn && !ApuSchedBoth.QgxEn &&
          !ApuBadVirglGrant.QgaEn && !ApuBadVirglGrant.QgkEn &&
          !ApuBadVirglGrant.QgxEn);
    cfg = ApuP1Transport;
    cfg.QgaEn = 1'b1;
    cfg.QgkEn = 1'b1;
    cfg.QgxEn = 1'b1;
    check("ack does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QgaEn = 1'b1;
    cfg.QgkEn = 1'b1;
    cfg.QgxEn = 1'b1;
    check("ack does not legalize virgl", !apu_cfg_legal(cfg));
    check("ack places",
          APU_VGPU_QGA_ADDR == 64'h8800E510 &&
          APU_VGPU_VAW_CLEAR == 32'h0 &&
          APU_VGPU_QSI_REASON == 32'h1 &&
          APU_VGPU_QGA_ADDR != APU_VGPU_TAW_ADDR &&
          APU_VGPU_QGA_ADDR != APU_VGPU_QGA_STAT &&
          APU_VGPU_QGA_ADDR != APU_VGPU_TIW_ADDR &&
          APU_VGPU_QGA_ADDR != 64'h40001000);

    qgk_step(APU_VGPU_QGK_EMPTY, "read empty");
    qga_step(APU_VGPU_QGA_EMPTY, "ack empty");
    qgx_step(APU_VGPU_QGX_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    qga_step(APU_VGPU_QGA_FAULT, "cancel");
    cancel = 1'b0;
    qsm.addr = APU_VGPU_TIW_ADDR;
    qga_step(APU_VGPU_QGA_FAULT, "xfer status");
    good_in();
    qsm.used_idx = APU_VGPU_TUW_IDXV;
    qga_step(APU_VGPU_QGA_FAULT, "xfer index");
    good_in();
    fail_ard = 1'b1;
    qga_step(APU_VGPU_QGA_FAULT, "bad beat");
    good_in();
    ack_word = 32'h2;
    qga_step(APU_VGPU_QGA_FAULT, "config ack");
    good_in();
    ack_word = 32'h0;
    qga_step(APU_VGPU_QGA_FAULT, "zero ack");
    good_in();
    fail_wr = 1'b1;
    qga_step(APU_VGPU_QGA_FAULT, "bad clear");
    qga_step(APU_VGPU_QGA_OK, "ack");
    qga_step(APU_VGPU_QGA_FAULT, "ack again");
    check("ack stays", qga.valid && qga.ack == 32'h1 && qga.remain == 32'h0 &&
          qga.used_idx == 16'd1);
    fail_rd = 1'b1;
    qgk_step(APU_VGPU_QGK_FAULT, "bad beat");
    bad_tail = 1'b1;
    qgk_step(APU_VGPU_QGK_FAULT, "bad tail");
    qgk_step(APU_VGPU_QGK_OK, "read ack");
    qgk_step(APU_VGPU_QGK_FAULT, "read ack again");
    check("read stays", qgkq.ack == 32'h1 && qgkq.remain == 32'h0 &&
          qgkq.used_idx == 16'd1);
    qsm.used_idx = APU_VGPU_TUW_IDXV;
    qgx_step(APU_VGPU_QGX_FAULT, "keep bad index");
    check("keep rejected", !qgx.valid);
    qsm.used_idx = APU_VGPU_QSU_IDXV;
    qgx_step(APU_VGPU_QGX_OK, "keep ack");
    check("ack kept", qgx.valid && qgx.ack == 32'h1 && qgx.remain == 32'h0 &&
          qgx.used_idx == 16'd1);
    qgx_step(APU_VGPU_QGX_FAULT, "keep again");
    check("keep stays", qgx.ack == qga.ack && qgx.remain == qga.remain);

    pulse_reset();
    check("reset clears", qga == '0 && qgkq == '0 && qgx == '0);
    zero_in();
    qga_step(APU_VGPU_QGA_EMPTY, "after reset");
    qgk_step(APU_VGPU_QGK_EMPTY, "read after reset");
    qgx_step(APU_VGPU_QGX_EMPTY, "keep after reset");
    good_in();
    qga_step(APU_VGPU_QGA_OK, "ack after reset");

    if (errors != 0) $fatal(1, "APU vgpu qga errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qga cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
