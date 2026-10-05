// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_sga;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_six_t six;
  logic sga_req = 0, sga_rdy, sga_cpl_v, sga_cpl_r = 0;
  apu_vgpu_sga_cpl_t sga_cpl;
  apu_vgpu_sga_t sga;
  logic ard_v, ard_rdy, ard_rsp_v = 0, ard_rsp_rdy, ard_rsp_ok = 0;
  logic [63:0] ard_addr, ard_rsp_addr = 0, aseen = 0;
  logic [31:0] ard_len, ard_rsp_len = 0;
  logic [255:0] ard_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic sgk_req = 0, sgk_rdy, sgk_cpl_v, sgk_cpl_r = 0;
  apu_vgpu_sgk_cpl_t sgk_cpl;
  apu_vgpu_sgk_t sgkq;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic sgx_req = 0, sgx_rdy, sgx_cpl_v, sgx_cpl_r = 0;
  apu_vgpu_sgx_cpl_t sgx_cpl, off_cpl;
  apu_vgpu_sgx_t sgx, off_sgx;
  logic off_rdy, off_v;
  logic fail_ard = 0, fail_rd = 0, fail_wr = 0, bad_tail = 0;
  logic a_order = 0, w_order = 0, w_data = 0, rd_order = 0;
  logic [31:0] ack_word = 32'h1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int naread = 0, nwrite = 0, nread = 0, rd_base = 0;

  assign ard_rdy = ard_v && rst_ni && !ard_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_sga #(.Enable(1'b1)) i_sga (
    .clk_i(clk), .rst_ni, .cancel_i(cancel),
    .six_i(six),
    .req_valid_i(sga_req), .req_ready_o(sga_rdy),
    .cpl_valid_o(sga_cpl_v), .cpl_ready_i(sga_cpl_r), .cpl_o(sga_cpl), .sga_o(sga),
    .rd_valid_o(ard_v), .rd_ready_i(ard_rdy), .rd_addr_o(ard_addr), .rd_len_o(ard_len),
    .rd_rsp_valid_i(ard_rsp_v), .rd_rsp_ready_o(ard_rsp_rdy), .rd_rsp_ok_i(ard_rsp_ok),
    .rd_rsp_addr_i(ard_rsp_addr), .rd_rsp_len_i(ard_rsp_len), .rd_rsp_data_i(ard_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_sgk #(.Enable(1'b1)) i_sgk (
    .clk_i(clk), .rst_ni, .sga_i(sga), .six_i(six),
    .req_valid_i(sgk_req), .req_ready_o(sgk_rdy),
    .cpl_valid_o(sgk_cpl_v), .cpl_ready_i(sgk_cpl_r), .cpl_o(sgk_cpl), .sgk_o(sgkq),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_sgx #(.Enable(1'b1)) i_sgx (
    .clk_i(clk), .rst_ni, .sgk_i(sgkq), .sga_i(sga), .six_i(six),
    .req_valid_i(sgx_req), .req_ready_o(sgx_rdy),
    .cpl_valid_o(sgx_cpl_v), .cpl_ready_i(sgx_cpl_r), .cpl_o(sgx_cpl), .sgx_o(sgx)
  );
  g6lc_apu_vgpu_sgx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sgk_i(sgkq), .sga_i(sga), .six_i(six),
    .req_valid_i(sgx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sgx_cpl_r), .cpl_o(off_cpl), .sgx_o(off_sgx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu sga timeout case=%0d", cases); end

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
    six = '0;
    six.valid = 1'b1;
    six.reason = APU_VGPU_QSI_REASON;
    six.used_idx = APU_VGPU_QSU_IDXV;
    six.addr = APU_VGPU_QGA_STAT;
    ack_word = APU_VGPU_QSI_REASON;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_sgx == '0 &&
          off_cpl == '0);
  endtask

  task automatic sga_step(input apu_vgpu_sga_status_e st, input string name);
    int nr, nw;
    @(negedge clk);
    while (!sga_rdy) @(negedge clk);
    cases++;
    nr = naread;
    nw = nwrite;
    sga_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sga_req = 1'b0;
    while (!sga_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sga_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SGA_OK) begin
      check("acked", sga.valid && sga.ack == APU_VGPU_QSI_REASON &&
            sga.remain == APU_VGPU_VAW_CLEAR &&
            sga.used_idx == APU_VGPU_QSU_IDXV &&
            sga.ack_addr == APU_VGPU_QGA_ADDR &&
            sga.status_addr == APU_VGPU_QGA_STAT &&
            sga.ack_addr != APU_VGPU_TAW_ADDR &&
            sga.status_addr != APU_VGPU_TIW_ADDR);
      check("bus", naread == nr + 1 && nwrite == nw + 1 && !a_order &&
            !w_order && !w_data && aseen == APU_VGPU_QGA_ADDR &&
            wseen == APU_VGPU_QGA_STAT);
    end else if (name == "bad beat" || name == "config ack" || name == "zero ack") begin
      check("read only", naread == nr + 1 && nwrite == nw && !sga.valid);
    end else if (name == "bad clear") begin
      check("both beats", naread == nr + 1 && nwrite == nw + 1 && !sga.valid);
    end else check("no bus", naread == nr && nwrite == nw);
    @(negedge clk);
    check($sformatf("%s held", name), sga_cpl_v);
    sga_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sga_cpl_r = 1'b0;
    while (sga_cpl_v) @(negedge clk);
  endtask

  task automatic sgk_step(input apu_vgpu_sgk_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!sgk_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    sgk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sgk_req = 1'b0;
    while (!sgk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sgk_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SGK_OK) begin
      check("readback", sgkq.valid && sgkq.ack == sga.ack &&
            sgkq.remain == sga.remain && sgkq.used_idx == sga.used_idx &&
            sgkq.ack != sgkq.remain &&
            sgkq.ack_addr == APU_VGPU_QGA_ADDR &&
            sgkq.status_addr == APU_VGPU_QGA_STAT);
      check("read count", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_QGA_ADDR && rd_seen1 == APU_VGPU_QGA_STAT);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !sgkq.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !sgkq.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), sgk_cpl_v);
    sgk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sgk_cpl_r = 1'b0;
    while (sgk_cpl_v) @(negedge clk);
  endtask

  task automatic sgx_step(input apu_vgpu_sgx_status_e st, input string name);
    @(negedge clk);
    while (!sgx_rdy) @(negedge clk);
    cases++;
    sgx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sgx_req = 1'b0;
    while (!sgx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sgx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), sgx_cpl_v);
    sgx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sgx_cpl_r = 1'b0;
    while (sgx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    sga_req = 1'b0;
    sgk_req = 1'b0;
    sgx_req = 1'b0;
    sga_cpl_r = 1'b0;
    sgk_cpl_r = 1'b0;
    sgx_cpl_r = 1'b0;
    cancel = 1'b0;
    ard_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    six = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          sga == '0 && sgkq == '0 && sgx == '0);
    check("profiles keep the ack off",
          !ApuOff.SgaEn && !ApuOff.SgkEn && !ApuOff.SgxEn &&
          !ApuP1Transport.SgaEn && !ApuP1Transport.SgkEn && !ApuP1Transport.SgxEn &&
          !ApuHarness.SgaEn && !ApuHarness.SgkEn && !ApuHarness.SgxEn &&
          !ApuSchedBoth.SgaEn && !ApuSchedBoth.SgkEn && !ApuSchedBoth.SgxEn &&
          !ApuBadVirglGrant.SgaEn && !ApuBadVirglGrant.SgkEn &&
          !ApuBadVirglGrant.SgxEn);
    cfg = ApuP1Transport;
    cfg.SgaEn = 1'b1;
    cfg.SgkEn = 1'b1;
    cfg.SgxEn = 1'b1;
    check("ack does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SgaEn = 1'b1;
    cfg.SgkEn = 1'b1;
    cfg.SgxEn = 1'b1;
    check("ack does not legalize virgl", !apu_cfg_legal(cfg));
    check("ack places",
          APU_VGPU_QGA_ADDR == 64'h8800E510 &&
          APU_VGPU_VAW_CLEAR == 32'h0 &&
          APU_VGPU_QSI_REASON == 32'h1 &&
          APU_VGPU_QGA_ADDR != APU_VGPU_TAW_ADDR &&
          APU_VGPU_QGA_ADDR != APU_VGPU_QGA_STAT &&
          APU_VGPU_QGA_ADDR != APU_VGPU_TIW_ADDR &&
          APU_VGPU_QGA_ADDR != 64'h40001000);

    sgk_step(APU_VGPU_SGK_EMPTY, "read empty");
    sga_step(APU_VGPU_SGA_EMPTY, "ack empty");
    sgx_step(APU_VGPU_SGX_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    sga_step(APU_VGPU_SGA_FAULT, "cancel");
    cancel = 1'b0;
    six.addr = APU_VGPU_TIW_ADDR;
    sga_step(APU_VGPU_SGA_FAULT, "xfer status");
    good_in();
    six.used_idx = APU_VGPU_TUW_IDXV;
    sga_step(APU_VGPU_SGA_FAULT, "xfer index");
    good_in();
    fail_ard = 1'b1;
    sga_step(APU_VGPU_SGA_FAULT, "bad beat");
    good_in();
    ack_word = 32'h2;
    sga_step(APU_VGPU_SGA_FAULT, "config ack");
    good_in();
    ack_word = 32'h0;
    sga_step(APU_VGPU_SGA_FAULT, "zero ack");
    good_in();
    fail_wr = 1'b1;
    sga_step(APU_VGPU_SGA_FAULT, "bad clear");
    sga_step(APU_VGPU_SGA_OK, "ack");
    sga_step(APU_VGPU_SGA_FAULT, "ack again");
    check("ack stays", sga.valid && sga.ack == 32'h1 && sga.remain == 32'h0 &&
          sga.used_idx == 16'd1);
    fail_rd = 1'b1;
    sgk_step(APU_VGPU_SGK_FAULT, "bad beat");
    bad_tail = 1'b1;
    sgk_step(APU_VGPU_SGK_FAULT, "bad tail");
    sgk_step(APU_VGPU_SGK_OK, "read ack");
    sgk_step(APU_VGPU_SGK_FAULT, "read ack again");
    check("read stays", sgkq.ack == 32'h1 && sgkq.remain == 32'h0 &&
          sgkq.used_idx == 16'd1);
    six.used_idx = APU_VGPU_TUW_IDXV;
    sgx_step(APU_VGPU_SGX_FAULT, "keep bad index");
    check("keep rejected", !sgx.valid);
    six.used_idx = APU_VGPU_QSU_IDXV;
    sgx_step(APU_VGPU_SGX_OK, "keep ack");
    check("ack kept", sgx.valid && sgx.ack == 32'h1 && sgx.remain == 32'h0 &&
          sgx.used_idx == 16'd1);
    sgx_step(APU_VGPU_SGX_FAULT, "keep again");
    check("keep stays", sgx.ack == sga.ack && sgx.remain == sga.remain);

    pulse_reset();
    check("reset clears", sga == '0 && sgkq == '0 && sgx == '0);
    zero_in();
    sga_step(APU_VGPU_SGA_EMPTY, "after reset");
    sgk_step(APU_VGPU_SGK_EMPTY, "read after reset");
    sgx_step(APU_VGPU_SGX_EMPTY, "keep after reset");
    good_in();
    sga_step(APU_VGPU_SGA_OK, "ack after reset");

    if (errors != 0) $fatal(1, "APU vgpu sga errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_sga cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
